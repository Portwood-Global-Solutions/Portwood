/**
 * Einstein / Prompt Builder implementation of DocGenAiProvider.
 *
 * Ships in the **Portwood DocGen Agentforce Extension** package, separately from
 * DocGen itself, and that separation is not stylistic. This class references
 * `ConnectApi.EinsteinLLM`, which is not a visible Apex type in an org without
 * the Einstein entitlement. A base package containing it BUILDS fine but is
 * REFUSED AT INSTALL for every customer who does not have Einstein:
 *
 *   ApexClass Type is not visible: ConnectApi.EinsteinLLM
 *
 * The prompt template alongside it is worse — a packaged `GenAiPromptTemplate`
 * makes the whole package require the "Generative AI Prompt Templates" feature,
 * gating install for everyone. Both measured 2026-07-26. Keeping them in this
 * extension is what lets DocGen stay installable everywhere.
 *
 * The extension shares the `portwoodglobal` namespace with the base package, so
 * `DocGenAiProviderFactory.get()` finds this class through its existing
 * `Type.forName('portwoodglobal', className)` fallback — the base package needs
 * no knowledge of the extension at all.
 *
 * A subscriber can still supply their own provider instead: implement
 * `portwoodglobal.DocGenAiProvider` and name the class in
 * DocGen Settings > AI Provider Class. See UserGuide section 5.7.11.
 *
 * MUST BE `global`, NOT `public`. The base package instantiates this class by
 * name via Type.forName + newInstance. A `public` class is invisible across a
 * 2GP package boundary EVEN IN THE SAME NAMESPACE, so with `public` both
 * Type.forName('DocGenEinsteinProvider') and
 * Type.forName('portwoodglobal', 'DocGenEinsteinProvider') return null, the
 * factory falls through to DocGenUnavailableProvider, and the Designer hides the
 * button with everything correctly installed. Measured 2026-07-26 in a real
 * two-package install (extension v1.0.0.1). The same rule bit the build in the
 * other direction: the test could not call the base package's `public` factory.
 *
 * MEASURED QUIRKS (2026-07-26)
 * ----------------------------
 *  - `additionalConfig.applicationName` is REQUIRED. Leave additionalConfig null
 *    and the call fails with the useless "Failed to generate Einstein LLM
 *    generations response", a null cause, and "(System Code)" as the entire
 *    stack trace. 'PromptBuilderPreview' is accepted; most other names are
 *    rejected with "Application Name is a required field providing existing
 *    registered ai applicaton".
 *  - This is NOT an HTTP callout — Limits.getCallouts() stays 0 — which is what
 *    avoids a separate Portwood-hosted AI integration. Salesforce routes the
 *    request to the model configured by the org administrator.
 *  - Budget 10-25 seconds for a 5KB document.
 */
global with sharing class DocGenEinsteinProvider implements DocGenAiProvider, Callable {
    /** Optional capability seam; preserves the shipped DocGenAiProvider interface. */
    global Object call(String action, Map<String, Object> args) {
        if (action == 'capabilities')
            return new Map<String, Object>{ 'fileReferences' => true, 'queryPlanning' => true };
        if (action == 'planQuery')
            return planQuery((String) args.get('prompt'), (Id) args.get('documentId'));
        if (action != 'generateWithReference')
            throw new DocGenAiException('Unsupported Agentforce authoring action.');
        String prompt = (String) args.get('prompt');
        Id documentId = (Id) args.get('documentId');
        if (String.isBlank(prompt) || documentId == null)
            throw new DocGenAiException('Choose an example and describe the document before generating.');
        // Files stay private. Resolve by the calling user's access; never fetch arbitrary file bytes in system mode.
        List<ContentDocument> files = [
            SELECT Id, FileExtension, ContentSize
            FROM ContentDocument
            WHERE Id = :documentId
            WITH USER_MODE
            LIMIT 1
        ];
        if (files.isEmpty() || files[0].FileExtension != 'pdf' || files[0].ContentSize > 15 * 1024 * 1024)
            throw new DocGenAiException('Choose an accessible PDF example up to the 15 MB Agentforce file budget.');
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        ConnectApi.EinsteinLlmAdditionalConfigInput cfg = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        cfg.applicationName = APPLICATION_NAME;
        input.additionalConfig = cfg;
        ConnectApi.WrappedValue instructions = new ConnectApi.WrappedValue();
        instructions.value = prompt;
        ConnectApi.WrappedValue example = new ConnectApi.WrappedValue();
        example.value = new Map<String, Object>{ 'id' => documentId };
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{
            INPUT_KEY => instructions,
            'Input:ExampleFile' => example
        };
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                'DocGen_HTML_Reference',
                input
            );
            if (response == null || response.generations == null || response.generations.isEmpty())
                throw new DocGenAiException(
                    'Agentforce returned no document. Confirm DocGen HTML Reference is active in Prompt Builder.'
                );
            return response.generations[0].text;
        } catch (Exception e) {
            throw new DocGenAiException(
                'Agentforce could not read the example. Check that DocGen HTML Reference is active, its model supports PDF inputs, and you can execute prompt templates. ' +
                e.getMessage()
            );
        }
    }

    private String planQuery(String prompt, Id documentId) {
        if (String.isBlank(prompt) || prompt.length() > 120000)
            throw new DocGenAiException('The planning request is empty or exceeds the Agentforce authoring context.');
        String templateName = documentId == null ? 'DocGen_Query_Plan' : 'DocGen_Query_Reference';
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        ConnectApi.EinsteinLlmAdditionalConfigInput cfg = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        cfg.applicationName = APPLICATION_NAME;
        input.additionalConfig = cfg;
        ConnectApi.WrappedValue instructions = new ConnectApi.WrappedValue();
        instructions.value = prompt;
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ INPUT_KEY => instructions };
        if (documentId != null) {
            List<ContentDocument> files = [
                SELECT Id, FileExtension, ContentSize
                FROM ContentDocument
                WHERE Id = :documentId
                WITH USER_MODE
                LIMIT 1
            ];
            if (files.isEmpty() || files[0].FileExtension != 'pdf' || files[0].ContentSize > 15 * 1024 * 1024)
                throw new DocGenAiException('Choose an accessible PDF example within the 15 MB Agentforce budget.');
            ConnectApi.WrappedValue example = new ConnectApi.WrappedValue();
            example.value = new Map<String, Object>{ 'id' => documentId };
            input.inputParams.put('Input:ExampleFile', example);
        }
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                templateName,
                input
            );
            if (response == null || response.generations == null || response.generations.isEmpty())
                throw new DocGenAiException('Agentforce returned no planning reply.');
            return response.generations[0].text;
        } catch (Exception e) {
            throw new DocGenAiException(
                'Agentforce could not continue the conversation. Check that ' +
                    templateName +
                    ' is active in Prompt Builder and your model has available usage. ' +
                    e.getMessage()
            );
        }
    }

    /** Free Text input on the Flex template. Both 'Input:X' and 'Input.X' work. */
    private static final String INPUT_KEY = 'Input:Instructions';

    /**
     * Must name an AI application the org already has registered. Empty string
     * is also accepted by the platform, but a named value is clearer in logs.
     */
    private static final String APPLICATION_NAME = 'PromptBuilderPreview';

    /** Fallback when the DocGen setting is blank. @TestVisible so tests assert on it rather than a duplicated literal. */
    @TestVisible
    private static final String TEMPLATE_FALLBACK = 'DocGen_HTML_Body';

    global String getName() {
        return 'Einstein';
    }

    /**
     * There is no cheap capability probe for Prompt Builder — no SObject to
     * query (GenAiPromptTemplate is metadata-only) and no describe. The only
     * honest test is a generation, which costs real time and credits. So report
     * that the code path exists and let generateHtml surface an actionable
     * message. Must never throw: DocGen calls this to decide whether to show
     * the button.
     */
    global Boolean isAvailable() {
        return !Test.isRunningTest();
    }

    global String generateHtml(String prompt) {
        if (String.isBlank(prompt)) {
            throw new DocGenAiException('Nothing to send — the authoring prompt was empty.');
        }
        String templateName = resolveTemplateName();

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;

        // Required. Omitting this is the single most common cause of the opaque
        // "Failed to generate Einstein LLM generations response".
        ConnectApi.EinsteinLlmAdditionalConfigInput cfg = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        cfg.applicationName = APPLICATION_NAME;
        input.additionalConfig = cfg;

        ConnectApi.WrappedValue wrapped = new ConnectApi.WrappedValue();
        wrapped.value = prompt;
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ INPUT_KEY => wrapped };

        try {
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                templateName,
                input
            );
            if (response == null || response.generations == null || response.generations.isEmpty()) {
                throw new DocGenAiException(
                    'Einstein returned no content. Check that the "' +
                        templateName +
                        '" prompt template has an ACTIVE version.'
                );
            }
            return response.generations[0].text;
        } catch (DocGenAiException e) {
            throw e;
        } catch (Exception e) {
            // ConnectApiException messages here are frequently generic, so name
            // what the admin should go and look at rather than echoing it alone.
            throw new DocGenAiException(
                'Einstein could not generate the template: ' +
                    e.getMessage() +
                    ' — confirm the "' +
                    templateName +
                    '" prompt template exists and is Activated, and that you hold an Einstein Generative AI permission set.',
                e
            );
        }
    }

    /**
     * Prefer the DocGen setting so an admin can rename the template without
     * editing Apex; fall back to the constant.
     *
     * Reads the packaged CUSTOM SETTING directly rather than calling
     * DocGenAiProviderFactory. That class is `public`, so it is NOT visible
     * across a namespace boundary — a subscriber class calling it fails to
     * compile with "Type is not visible: portwoodglobal.DocGenAiProviderFactory".
     * Measured against a real managed install, 2026-07-26. The custom setting is
     * Public and IS readable, which is why this route works.
     */
    private String resolveTemplateName() {
        try {
            // Same namespace as the base package, so no prefix is needed here.
            DocGen_Settings__c s = DocGen_Settings__c.getOrgDefaults();
            String configured = s == null ? null : s.AI_Prompt_Template__c;
            if (String.isNotBlank(configured)) {
                return configured.trim();
            }
        } catch (Exception e) {
            // Older DocGen, or the setting is unreadable — the constant is fine.
        }
        return TEMPLATE_FALLBACK;
    }

    global class DocGenAiException extends Exception {
    }
}
