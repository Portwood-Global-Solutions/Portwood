/**
 * "Generate with Agentforce" — the Designer endpoint.
 *
 *   authoring prompt (built client-side by docGenAuthoringKit.buildAiPrompt)
 *     -> provider (Einstein via ConnectApi, or the stub)
 *     -> DocGen_Template__c.Draft_Body__c        raw model output, kept for diffing
 *     -> DocGenAiHtmlValidator                   strip / repair, and say what changed
 *     -> ContentVersion 'docgen_html_body_<templateId>_<ts>'
 *     -> the Designer opens it
 *
 * The prompt is assembled in the LWC rather than here on purpose: buildAiPrompt
 * already owns the schema, the tag cheat sheet and the rendering constraints,
 * and it is the same text "Copy AI Prompt" hands to an external assistant. One
 * prompt, two destinations — the in-org path must not drift from the one authors
 * have been pasting into ChatGPT.
 */
public with sharing class DocGenAiTemplateController {
    public class AiGenerationException extends Exception {
    }

    public class GenerationResult {
        /** Validated HTML, already saved and ready for the canvas. */
        @AuraEnabled
        public String html { get; set; }
        @AuraEnabled
        public String summary { get; set; }
        @AuraEnabled
        public List<DocGenAiHtmlValidator.Finding> findings { get; set; }
        @AuraEnabled
        public Integer repairedCount { get; set; }
        @AuraEnabled
        public Integer removedCount { get; set; }
        @AuraEnabled
        public Integer warningCount { get; set; }
        @AuraEnabled
        public Id contentVersionId { get; set; }
        @AuraEnabled
        public String providerName { get; set; }
        /** Characters of raw model output, before sanitizing. */
        @AuraEnabled
        public Integer rawLength { get; set; }
        /** True when this revised an existing body rather than writing a new one. */
        @AuraEnabled
        public Boolean wasEdit { get; set; }
    }

    /**
     * Lets the Designer hide the button rather than let someone click into an
     * error. The feature must degrade to the existing copy-paste prompt when AI
     * is not available, never fail loudly.
     */
    @AuraEnabled(cacheable=false)
    public static Boolean isAiAvailable() {
        try {
            return DocGenAiProviderFactory.get().isAvailable();
        } catch (Exception e) {
            return false;
        }
    }

    @AuraEnabled
    public static Map<String, Object> getAiCapabilities() {
        Map<String, Object> result = new Map<String, Object>{
            'available' => false,
            'fileReferences' => false,
            'queryPlanning' => false
        };
        try {
            DocGenAiProvider provider = DocGenAiProviderFactory.get();
            result.put('available', provider.isAvailable());
            result.put('providerName', provider.getName());
            if (provider instanceof Callable) {
                Map<String, Object> capabilities = (Map<String, Object>) ((Callable) provider)
                    .call('capabilities', new Map<String, Object>());
                result.put('fileReferences', capabilities.get('fileReferences') == true);
                result.put('queryPlanning', capabilities.get('queryPlanning') == true);
            }
        } catch (Exception e) {
            /* An older optional extension remains usable for text-only authoring. */
        }
        return result;
    }

    @AuraEnabled
    public static GenerationResult generateReferencePreview(String prompt, Id documentId) {
        try {
            if (String.isBlank(prompt) || prompt.length() > 120000)
                throw new DocGenException(
                    'Describe the document, and keep the complete authoring prompt under 120,000 characters.'
                );
            ContentVersion file = DocGenAiReferenceController.readableFile(documentId);
            if (file.FileExtension != 'pdf')
                throw new DocGenException('Prepare the DOCX example before generating.');
            DocGenAiProvider provider = DocGenAiProviderFactory.get();
            if (!(provider instanceof Callable))
                throw new DocGenException(
                    'Update the Portwood Agentforce extension to use PDF examples. You can still generate from a description.'
                );
            String raw = (String) ((Callable) provider)
                .call(
                    'generateWithReference',
                    new Map<String, Object>{ 'prompt' => prompt, 'documentId' => documentId }
                );
            assertLooksLikeDocument(raw, null);
            GenerationResult result = validateOnly(raw);
            result.providerName = provider.getName();
            result.wasEdit = false;
            return result;
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Agentforce could not use this example.');
        }
    }

    /**
     * @param templateId   HTML-type DocGen_Template__c to write the body onto.
     * @param prompt       Fully assembled authoring prompt from buildAiPrompt().
     *                     In edit mode it already CONTAINS the current body —
     *                     the prompt is built in one place so the create and
     *                     edit paths cannot drift.
     * @param previousBody The body sent for editing, or null when generating
     *                     fresh. Passed separately ONLY so this method can
     *                     diff what went in against what came back; it is
     *                     deliberately not re-derived from the prompt.
     */
    @AuraEnabled
    public static GenerationResult generateTemplateBody(Id templateId, String prompt, String previousBody) {
        if (templateId == null) {
            throw new AuraHandledException(
                'Save the template first — there is nothing to write the generated body onto.'
            );
        }
        if (String.isBlank(prompt)) {
            throw new AuraHandledException('Describe the document you want before generating.');
        }

        try {
            DocGenAiProvider provider = DocGenAiProviderFactory.get();
            String raw = provider.generateHtml(prompt);
            if (String.isBlank(raw)) {
                throw new AiGenerationException(
                    'The model returned an empty response. Try again, or add more detail to your description.'
                );
            }

            // Stage the RAW output first, so a validator bug can never lose what
            // the model actually said, and the two can be compared afterwards.
            // A refusal is not a document. Check BEFORE anything is written.
            assertLooksLikeDocument(raw, previousBody);

            // Stage the RAW output first, so a validator bug can never lose what
            // the model actually said, and the two can be compared afterwards.
            stageDraftBody(templateId, raw);

            DocGenAiHtmlValidator.Result checked = DocGenAiHtmlValidator.sanitize(raw);

            // An edit that quietly drops a merge tag or truncates the document
            // looks perfectly fine in the canvas. Say so before it is saved.
            Boolean wasEdit = String.isNotBlank(previousBody);
            // Compare like with like. The guard runs against the SANITIZED
            // previous body, not the raw one, because the validator legitimately
            // removes and rewrites tags of its own accord — an empty {!} it
            // stripped, or a {!Field} it converted, would otherwise be reported
            // as "lost in the edit" when the edit had nothing to do with it.
            List<DocGenAiHtmlValidator.Finding> editFindings = wasEdit
                ? DocGenAiEditGuard.compare(DocGenAiHtmlValidator.sanitize(previousBody).html, checked.html)
                : new List<DocGenAiHtmlValidator.Finding>();
            for (DocGenAiHtmlValidator.Finding f : editFindings) {
                checked.findings.add(f);
                checked.warningCount += f.occurrences;
            }

            Map<String, Object> saved = DocGenController.saveHtmlTemplateBody(
                templateId,
                wasEdit ? 'agentforce-edited.html' : 'agentforce-generated.html',
                checked.html
            );

            GenerationResult out = new GenerationResult();
            out.html = checked.html;
            out.summary = wasEdit ? summariseEdit(checked, editFindings) : checked.summary;
            out.findings = checked.findings;
            out.repairedCount = checked.repairedCount;
            out.removedCount = checked.removedCount;
            out.warningCount = checked.warningCount;
            out.contentVersionId = (Id) saved.get('contentVersionId');
            out.providerName = provider.getName();
            out.rawLength = raw.length();
            out.wasEdit = wasEdit;
            return out;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            AuraHandledException wrapped = new AuraHandledException(e.getMessage());
            wrapped.setMessage(e.getMessage());
            throw wrapped;
        }
    }

    /** Lead with the integrity check on an edit — it is what the author needs to see. */
    private static String summariseEdit(
        DocGenAiHtmlValidator.Result checked,
        List<DocGenAiHtmlValidator.Finding> editFindings
    ) {
        if (editFindings.isEmpty()) {
            return checked.findings.isEmpty()
                ? 'Edit applied. Nothing was lost — every merge tag and table survived.'
                : 'Edit applied, every merge tag and table survived. ' + checked.summary;
        }
        return 'Edit applied, but check it: ' + editFindings[0].rule.toLowerCase() + '. ' + checked.summary;
    }

    /**
     * Re-run the validator over whatever is currently staged. Useful after a
     * hand edit, and it makes the rule set inspectable without spending a
     * generation.
     */
    @AuraEnabled
    public static GenerationResult validateOnly(String html) {
        DocGenAiHtmlValidator.Result checked = DocGenAiHtmlValidator.sanitize(html);
        GenerationResult out = new GenerationResult();
        out.html = checked.html;
        out.summary = checked.summary;
        out.findings = checked.findings;
        out.repairedCount = checked.repairedCount;
        out.removedCount = checked.removedCount;
        out.warningCount = checked.warningCount;
        out.rawLength = String.isBlank(html) ? 0 : html.length();
        return out;
    }

    /**
     * Generate and validate WITHOUT saving anything.
     *
     * The wizard needs this: the template record does not exist yet at the point
     * the author is describing what they want, so there is nothing to write a
     * ContentVersion onto. The returned HTML is handed back to the wizard, which
     * stages it exactly as it stages HTML pasted from an external assistant —
     * one create path, not two.
     */
    @AuraEnabled
    public static GenerationResult generateBodyPreview(String prompt) {
        if (String.isBlank(prompt)) {
            throw new AuraHandledException('Describe the document you want before generating.');
        }
        if (prompt.length() > 120000)
            throw DocGenService.ahe(
                'The complete authoring prompt exceeds 120,000 characters. Use fewer fields or a shorter example.'
            );
        try {
            DocGenAiProvider provider = DocGenAiProviderFactory.get();
            String raw = provider.generateHtml(prompt);
            if (String.isBlank(raw)) {
                throw new AiGenerationException(
                    'The model returned an empty response. Try again, or add more detail to your description.'
                );
            }
            assertLooksLikeDocument(raw, null);
            DocGenAiHtmlValidator.Result checked = DocGenAiHtmlValidator.sanitize(raw);

            GenerationResult out = new GenerationResult();
            out.html = checked.html;
            out.summary = checked.summary;
            out.findings = checked.findings;
            out.repairedCount = checked.repairedCount;
            out.removedCount = checked.removedCount;
            out.warningCount = checked.warningCount;
            out.providerName = provider.getName();
            out.rawLength = raw.length();
            out.wasEdit = false;
            return out;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            AuraHandledException wrapped = new AuraHandledException(e.getMessage());
            wrapped.setMessage(e.getMessage());
            throw wrapped;
        }
    }

    /**
     * Refuse to persist anything that is not a document.
     *
     * Einstein INTERMITTENTLY answers a perfectly good prompt with a refusal —
     * literally "I don't know." — and the old code saved it, replacing a 6,883
     * character template with 13 characters. Measured 2026-07-26: the same
     * prompt that produced this failure succeeded on a later attempt, so it is
     * model non-determinism, not a malformed request. Nothing downstream can
     * recover from it either: the validator happily sanitizes plain prose, and
     * the edit guard reports every merge tag as "lost" — technically true and
     * completely unhelpful.
     *
     * So the check belongs here, before the staging field, before the
     * ContentVersion, before anything the author would have to undo.
     *
     * The test is for MARKUP, not length. A refusal is prose; a template is
     * markup, however short. An earlier version also imposed a 200-character
     * floor and rejected perfectly valid small templates — the length of a
     * document is not evidence of anything.
     */
    private static void assertLooksLikeDocument(String raw, String previousBody) {
        String probe = raw == null ? '' : raw.trim();
        Boolean looksLikeMarkup =
            probe.containsIgnoreCase('<html') ||
            probe.containsIgnoreCase('<!doctype') ||
            probe.containsIgnoreCase('<body') ||
            probe.containsIgnoreCase('<table') ||
            probe.containsIgnoreCase('<div');
        if (looksLikeMarkup) {
            assertFontPlacement(probe);
            // A positive .records section changes list context; nesting the same
            // relationship's row loop inside it produces headers with no data.
            Matcher arrays = Pattern.compile('(?s)\\{#([A-Za-z_][A-Za-z0-9_]*)\\.records\\}(.*?)\\{/\\1\\.records\\}')
                .matcher(probe);
            while (arrays.find()) {
                if (arrays.group(2).contains('{#' + arrays.group(1) + '}'))
                    throw new AiGenerationException(
                        'The draft nested the same related-list loop twice, which would hide its data rows. Generate again: keep one table and put the loop only inside its data row.'
                    );
            }
            return;
        }
        String quoted = probe.length() > 200 ? probe.substring(0, 200) + '…' : probe;
        throw new AiGenerationException(
            (String.isNotBlank(previousBody)
                    ? 'Agentforce did not return a document, so your template has NOT been changed. '
                    : 'Agentforce did not return a document, so nothing was saved. ') +
                'It replied: "' +
                quoted +
                '". This happens intermittently even with a good instruction — try again, and if it repeats, make the instruction more specific.'
        );
    }

    /** Catch unusable AI font placement before staging, without resolving asset revisions. */
    @TestVisible
    private static void assertFontPlacement(String html) {
        if (!html.containsIgnoreCase('%font:'))
            return;
        String outsideStyles = DocGenService.decodeBraceEntities(html).replaceAll('(?is)<!--.*?-->', '');
        Matcher elements = Pattern.compile('(?is)<[^>]+>').matcher(outsideStyles);
        List<String> parts = new List<String>();
        Integer cursor = 0;
        while (elements.find()) {
            String element = elements.group(0);
            Matcher styles = Pattern.compile('(?is)\\sstyle\\s*=\\s*(["\'])(.*?)\\1').matcher(element);
            if (styles.find())
                element = element.substring(0, styles.start()) + element.substring(styles.end());
            parts.add(outsideStyles.substring(cursor, elements.start()) + element);
            cursor = elements.end();
        }
        parts.add(outsideStyles.substring(cursor));
        if (String.join(parts, '').containsIgnoreCase('{%font:'))
            throw new AiGenerationException(
                'Agentforce placed a font tag outside an inline style. Generate again: put each approved font tag in an element\'s quoted style attribute, never in a stylesheet or CSS class rule. Nothing was saved.'
            );
    }

    /** Raw model output onto the staging field. Never fatal — this is an audit trail. */
    private static void stageDraftBody(Id templateId, String raw) {
        try {
            DocGen_Template__c t = new DocGen_Template__c(Id = templateId);
            // Long Text Area caps at 131,072; a real body is 5-70KB, so this is
            // headroom rather than a limit, but truncate rather than throw.
            t.Draft_Body__c = raw.length() > 131072 ? raw.substring(0, 131072) : raw;
            DocGenFlsGuard.assertUpdateable(t, new Set<String>{ 'Draft_Body__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(t, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            // Staging is a convenience. Losing it must not lose the generation.
            System.debug(LoggingLevel.WARN, 'Portwood: could not stage Draft_Body__c: ' + e.getMessage());
        }
    }
}
