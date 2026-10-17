/**
 * Interface for AI text generation in Portwood. Implement this to let the
 * Designer's "Generate with Agentforce" button write and revise HTML templates.
 *
 * WHY YOU IMPLEMENT THIS RATHER THAN US SHIPPING IT
 * -------------------------------------------------
 * The Einstein implementation references `ConnectApi.EinsteinLLM`, which is not
 * a visible Apex type in an org without the Einstein entitlement. That makes it
 * impossible to BUILD a package version containing it — the build org has no
 * Einstein, so the Apex fails to compile long before anyone installs anything.
 * Measured, not assumed. So Portwood ships everything except the final hop, and
 * the class that makes the call lives in YOUR org, where your entitlement
 * applies. This mirrors {@link DocGenDataProvider}, which works the same way and
 * for a similar reason.
 *
 * Without an implementation present, Portwood degrades quietly: the Designer hides
 * the Agentforce button and the existing "Copy AI Prompt" workflow is unchanged.
 *
 * REFERENCE IMPLEMENTATION
 * ------------------------
 * `DocGenEinsteinProvider.cls` in the Portwood repository is a complete, working
 * Einstein/Prompt Builder implementation — deploy it as-is into your own org.
 * See docs/AGENTFORCE_SETUP.md for the four setup steps.
 *
 * EXAMPLE
 * -------
 *   public with sharing class MyAiProvider implements portwoodglobal.DocGenAiProvider {
 *       public Boolean isAvailable() {
 *           return true;
 *       }
 *       public String getName() {
 *           return 'My AI';
 *       }
 *       public String generateHtml(String prompt) {
 *           // Return a complete HTML document. Portwood validates it against the
 *           // PDF engine's constraints before anything is saved, so you do not
 *           // need to sanitize it yourself.
 *           return callMyModel(prompt);
 *       }
 *   }
 *
 * Then point Portwood at it: Setup > Custom Settings > Portwood Settings >
 * AI Provider Class = MyAiProvider.
 *
 * CONTRACT NOTES
 * --------------
 * - `generateHtml` receives a fully assembled prompt: the record's schema, the
 *   Portwood merge-tag syntax, the PDF engine's CSS constraints, and what the
 *   author asked for. Send it verbatim; do not summarise it. On an edit it also
 *   contains the current template.
 * - Return the model's raw output in the format requested by the prompt.
 *   Designer conversations request a JSON reply or an edit with complete HTML;
 *   other authoring requests return HTML directly. Portwood validates all HTML
 *   before saving it, and discussion replies never change the document.
 * - Do NOT make an HTTP callout. Portwood is a 100% native package and reaches
 *   Einstein through ConnectApi precisely so that stays true. A provider that
 *   calls out breaks that guarantee for the whole product.
 * - Expect to be called synchronously from a Lightning component, and to take
 *   10-25 seconds.
 */
global interface DocGenAiProvider {
    /**
     * True when this org can actually generate. The Designer calls this to
     * decide whether to show the button at all, so it must never throw — return
     * false rather than raising if configuration is missing.
     */
    Boolean isAvailable();

    /** Short name for logs and the UI, e.g. 'Einstein'. */
    String getName();

    /**
     * @param prompt Fully assembled authoring prompt. Send it as-is.
     * @return Raw model output in the requested HTML or conversational JSON format.
     */
    String generateHtml(String prompt);
}
