public with sharing class DocGenSignatureSenderController {
    public class SignerResult {
        @AuraEnabled
        public String signerName;
        @AuraEnabled
        public String roleName;
        @AuraEnabled
        public String signerUrl;
        @AuraEnabled
        public String signerEmail;
        @AuraEnabled
        public Id signerId; // 1.49 — LWC uses this for in-person PIN bypass
    }

    /**
     * Parses a JSON array of template IDs and returns it deduped, preserving order.
     * The LWC sender's template picker can append the same templateId twice when a
     * user clicks faster than the awaited getTemplateSignaturePlacements call resolves —
     * the dropdown's "filter already-selected" check runs against pre-await state.
     */
    @TestVisible
    private static List<Id> parseAndDedupTemplateIds(String templateIdsJson) {
        List<Object> raw = (List<Object>) JSON.deserializeUntyped(templateIdsJson);
        List<Id> deduped = new List<Id>();
        Set<Id> seen = new Set<Id>();
        for (Object t : raw) {
            Id tid = (Id) t;
            if (seen.add(tid)) {
                deduped.add(tid);
            }
        }
        return deduped;
    }

    /**
     * Returns all active Portwood templates for the signature sender template picker.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getDocGenTemplates() {
        return getDocGenTemplatesForRecord(null);
    }

    /**
     * Returns templates filtered by audience (Required_Permission_Sets__c) and optionally
     * by per-record visibility (Specific_Record_Ids__c). Pass relatedRecordId to enable
     * per-record filtering; pass null to apply only the audience filter.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getDocGenTemplatesForRecord(String relatedRecordId) {
        // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
        // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
        // calls Schema.SObjectField.getDescribe().isAccessible() on every field
        // the SELECT lists; throws DocGenException with the offending field name
        // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
        // package-build @TestSetup FLS-propagation issue documented in
        // DocGenFlsGuard.cls.
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{
                'Name',
                'Category__c',
                'Sort_Order__c',
                'Specific_Record_Ids__c',
                'Required_Permission_Sets__c',
                'Record_Filter__c',
                'Base_Object_API__c',
                'Default_Email_Message__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> all = [
            SELECT
                Id,
                Name,
                Category__c,
                Sort_Order__c,
                Specific_Record_Ids__c,
                Required_Permission_Sets__c,
                Record_Filter__c,
                Base_Object_API__c,
                Default_Email_Message__c
            FROM DocGen_Template__c
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC NULLS LAST, Name ASC
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets

        return DocGenController.filterTemplatesForSender(all, relatedRecordId);
    }

    /**
     * Data class for a parsed signature placement from template tags.
     */
    public class PlacementInfo implements Comparable {
        @AuraEnabled
        public String role;
        @AuraEnabled
        public Integer sequence;
        @AuraEnabled
        public String placementType; // Full, Initials, Date, DatePick
        @AuraEnabled
        public String tagText; // Original tag for reference
        // true → render a compact in-place mark (no DocuSign stamp card) regardless of
        // surrounding whitespace, for tight templates where the card would overlap a
        // label. Set from an `:inline` style suffix on the tag (e.g. {@Signature_Buyer:1:Full:inline}).
        @AuraEnabled
        public Boolean renderInline = false;

        public PlacementInfo(String role, Integer sequence, String placementType, String tagText) {
            this.role = role;
            this.sequence = sequence;
            this.placementType = placementType;
            this.tagText = tagText;
        }

        public Integer compareTo(Object other) {
            PlacementInfo o = (PlacementInfo) other;
            return this.sequence - o.sequence;
        }
    }

    /**
     * Scans a Portwood template's pre-decomposed XML for {@Signature_XXX} placeholders.
     * Returns deduplicated role names (backward-compatible).
     */
    @AuraEnabled
    public static List<String> getTemplateSignatureRoles(Id templateId) {
        List<PlacementInfo> placements = getTemplateSignaturePlacements(templateId);
        List<String> roles = new List<String>();
        for (PlacementInfo p : placements) {
            if (!roles.contains(p.role)) {
                roles.add(p.role);
            }
        }
        return roles;
    }

    /**
     * Scans a Portwood template for all v3 signature placements.
     * Supports both v2 ({@Signature_Role}) and v3 ({@Signature_Role:Order:Type}) syntax.
     * Returns ordered list of PlacementInfo with role, sequence, type, and original tag.
     */
    @AuraEnabled
    public static List<PlacementInfo> getTemplateSignaturePlacements(Id templateId) {
        String plainText = extractTemplatePlainText(templateId);
        if (plainText == null)
            return new List<PlacementInfo>();
        return parseSignaturePlacements(plainText);
    }

    /**
     * Re-applies the send-time {@Signature_*} → @@SIG-n@@ sentinel substitution to an
     * already-merged document body, in document order. Used by the signature finalizer
     * when a request has no Frozen_Document__c (oversized snapshot — the body exceeds the
     * 131072-char freeze cap — or a legacy request): that path LIVE re-merges, so the body
     * carries the ORIGINAL {@Signature_*} tags rather than the @@SIG-n@@ sentinels the
     * placements key on. Without this re-substitution, DocGenSignatureService.stampSignaturesInXml
     * matches nothing (placement Tag_Text__c = @@SIG-n@@) and the signature silently never
     * stamps — the unstamped tags are then stripped at render, leaving a blank signature line.
     *
     * Mirrors the substitution in createGuidedPdfSignatureRequest exactly (same regex set,
     * same document order, same per-occurrence replaceFirst), but sources the tags from the
     * merged BODY instead of re-reading the template — the template's pre-decomposed XML CVs
     * read WITH USER_MODE, which returns empty in the async (Automated Process) finalize
     * context. Idempotent: a body that already carries @@SIG-n@@ (the frozen path) is a no-op.
     */
    public static String resentinelSignatureBody(String body) {
        if (String.isBlank(body) || body.contains('@@SIG-')) {
            return body;
        }
        // Role-scoped tags first ({@Signature_Role[:order:type]}), in document order — this is
        // the placement set createGuidedPdfSignatureRequest sentinel-indexes. Only when none
        // exist does the bare {@Signature} fallback apply (mirrors parseSignaturePlacements).
        List<String> tagsInOrder = new List<String>();
        Matcher roleMatch = Pattern.compile('\\{@Signature_[^}]*\\}').matcher(body);
        while (roleMatch.find()) {
            tagsInOrder.add(roleMatch.group());
        }
        if (tagsInOrder.isEmpty()) {
            Matcher bareMatch = Pattern.compile('\\{@Signature\\}').matcher(body);
            while (bareMatch.find()) {
                tagsInOrder.add(bareMatch.group());
            }
        }
        for (Integer i = 0; i < tagsInOrder.size(); i++) {
            body = body.replaceFirst(Pattern.quote(tagsInOrder[i]), '@@SIG-' + i + '@@');
        }
        return body;
    }

    /**
     * True when the template body contains the reserved {#Signatures} variable-signer
     * loop block. Drives the canonical-entry dispatch in createGuidedPdfSignatureRequest:
     * a loop-only template (no {@Signature_*} tags) routes to the snapshot render
     * strategy, because the guided frozen-body path freezes the loop empty at send and
     * can't repopulate it with signed rows at completion.
     */
    @TestVisible
    private static Boolean templateHasSignaturesLoopBlock(Id templateId) {
        String plain = extractTemplatePlainText(templateId);
        return plain != null && plain.contains('{#Signatures}');
    }

    /**
     * Extracts concatenated plain text from a template's pre-decomposed document.xml.
     * Reads from stored XML ContentVersions — no ZIP decompression needed.
     */
    private static String extractTemplatePlainText(Id templateId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Template__c', 'Is_Active__c', 'Content_Version_Id__c' }
        );
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title', 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id, Content_Version_Id__c, Template__r.Type__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (activeVersions.isEmpty())
            return null;

        DocGen_Template_Version__c activeVersion = activeVersions[0];
        if (DocGenService.isHtmlBacked(activeVersion.Template__r.Type__c)) {
            if (String.isBlank(activeVersion.Content_Version_Id__c))
                return null;

            Id bodyCvId = (Id) activeVersion.Content_Version_Id__c;
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentVersion> htmlCvs = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Id = :bodyCvId
                WITH USER_MODE
                LIMIT 1
            ];
            return htmlCvs.isEmpty() || htmlCvs[0].VersionData == null ? null : htmlCvs[0].VersionData.toString();
        }

        String xmlPrefix = 'docgen_tmpl_xml_' + activeVersion.Id + '_';
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> xmlCvs = [
            SELECT Title, VersionData
            FROM ContentVersion
            WHERE Title LIKE :(xmlPrefix + '%')
            WITH USER_MODE
        ];

        String documentXml = null;
        for (ContentVersion cv : xmlCvs) {
            String key = cv.Title.substring(xmlPrefix.length());
            String originalPath = key.replace('__', '/');
            if (originalPath == 'word/document.xml') {
                documentXml = cv.VersionData.toString();
                break;
            }
        }
        if (documentXml == null) {
            // No pre-decomposed document.xml CV — the async decomposition never ran for
            // this active version (e.g. the docx was replaced/re-saved during org build-out
            // and the new version wasn't re-decomposed). Read document.xml on-demand from the
            // raw template CV so placement parsing still finds the {@Signature_*:inline} tags
            // instead of returning empty and silently falling back to the synthetic
            // "Signatures" block (which leaks the inline tags as raw text). See SHWaiver bug.
            documentXml = DocGenService.getActiveTemplateDocumentXml(templateId);
        }
        if (documentXml == null)
            return null;

        // Extract text from <w:t> elements
        String plainText = '';
        Pattern wtPat = Pattern.compile('<w:t[^>]*>([^<]*)</w:t>');
        Matcher wtMatch = wtPat.matcher(documentXml);
        while (wtMatch.find()) {
            plainText += wtMatch.group(1);
        }
        return plainText;
    }

    /**
     * Parses signature placement tags from plain text.
     * v2: {@Signature_Role} → role="Role", sequence=1, type="Full"
     * v3: {@Signature_Role:Order:Type} → role="Role", sequence=Order, type=Type
     * Generic: {@Signature} → role="Signer", sequence=1, type="Full"
     */
    @TestVisible
    private static List<PlacementInfo> parseSignaturePlacements(String plainText) {
        List<PlacementInfo> placements = new List<PlacementInfo>();

        // v3 regex: captures role, optional :order, optional :type
        Pattern sigPat = Pattern.compile('\\{@Signature_([^:}]+)(?::(\\d+))?(?::([^}]+))?\\}');
        Matcher sigMatch = sigPat.matcher(plainText);
        while (sigMatch.find()) {
            String roleName = sigMatch.group(1).replaceAll('_', ' ');
            Integer seq = sigMatch.group(2) != null ? Integer.valueOf(sigMatch.group(2)) : 1;

            // The type segment (group 3) may carry a colon-joined render-style suffix,
            // e.g. "Full:inline" or "Date:inline" (the regex's [^}]+ keeps the inner
            // colons). First token = the placement type; an "inline" token anywhere
            // after it forces the compact in-place mark.
            String typeRaw = sigMatch.group(3) != null ? sigMatch.group(3) : 'Full';
            Boolean renderInline = false;
            String pType = 'Full';
            List<String> typeParts = typeRaw.split(':');
            if (!typeParts.isEmpty() && String.isNotBlank(typeParts[0])) {
                pType = typeParts[0].trim();
            }
            for (Integer ti = 1; ti < typeParts.size(); ti++) {
                if (typeParts[ti].trim().equalsIgnoreCase('inline')) {
                    renderInline = true;
                }
            }

            // Normalize type
            if (pType != 'Full' && pType != 'Initials' && pType != 'Date' && pType != 'DatePick') {
                pType = 'Full';
            }

            PlacementInfo pi = new PlacementInfo(roleName, seq, pType, sigMatch.group(0));
            pi.renderInline = renderInline;
            placements.add(pi);
        }

        // Fallback: generic {@Signature} tag (no role)
        if (placements.isEmpty() && plainText.contains('{@Signature}')) {
            placements.add(new PlacementInfo('Signer', 1, 'Full', '{@Signature}'));
        }

        // Sort by sequence order
        placements.sort();

        return placements;
    }

    /**
     * Replaces {@Signature_*} tags in preview HTML with interactive styled spans.
     * Each span carries data attributes for the guided signing JS to find and manipulate.
     * Inline styles ensure the highlights render in both browser preview and Blob.toPdf() unsigned PDF.
     */
    /**
     * Browsers do NOT honor CSS @page background-image (paged-media spec only fires
     * during PDF rendering). For signature previews — both the sender modal and the
     * customer signing page — we inject a screen-only overlay so the watermark is
     * visible before signing. The overlay is suppressed via @media print so
     * Blob.toPdf() doesn't double-render it on top of the @page background.
     *
     * Two non-obvious constraints drove the implementation:
     *   1. The sender LWC injects preview HTML via innerHTML (no iframe), so a
     *      position:fixed overlay would escape the modal and cover the whole page.
     *      We wrap content in .docgen-preview-wrap (position:relative) and position
     *      the overlay absolutely inside it.
     *   2. The customer signing page runs as guest user; /sfc/ URLs don't resolve
     *      and the page's image proxy only rewrites <img src>, not CSS background-image.
     *      We embed the watermark as a base64 data URI so it loads in any context.
     */
    /**
     * without-sharing helper so guest signers (who have no sharing access to the watermark
     * CV or the template version field) can still resolve the watermark bytes. The outer
     * class is `with sharing` for AppExchange compliance — only this CV/version lookup
     * needs to bypass sharing, gated by the request token validation upstream.
     */
    private without sharing class WatermarkResolver {
        public Map<String, Object> resolve(Id templateId) {
            Map<String, Object> out = new Map<String, Object>();
            try {
                List<DocGen_Template_Version__c> vs = [
                    SELECT Watermark_Image_CV_Id__c
                    FROM DocGen_Template_Version__c
                    WHERE Template__c = :templateId AND Is_Active__c = TRUE
                    LIMIT 1
                ];
                if (vs.isEmpty() || String.isBlank(vs[0].Watermark_Image_CV_Id__c))
                    return null;
                Id wmCvId = vs[0].Watermark_Image_CV_Id__c;
                List<ContentVersion> cvs = [
                    SELECT VersionData, FileExtension
                    FROM ContentVersion
                    WHERE Id = :wmCvId
                    LIMIT 1
                ];
                if (cvs.isEmpty())
                    return null;
                out.put('data', cvs[0].VersionData);
                out.put('ext', String.isNotBlank(cvs[0].FileExtension) ? cvs[0].FileExtension.toLowerCase() : 'png');
                return out;
            } catch (Exception e) {
                return null;
            }
        }
    }

    @TestVisible
    public static String injectPreviewWatermarkOverlay(String html, Id templateId) {
        if (String.isBlank(html))
            return html;

        String overlayDiv = '';
        if (templateId != null) {
            Map<String, Object> wm = new WatermarkResolver().resolve(templateId);
            if (wm != null) {
                Blob wmData = (Blob) wm.get('data');
                String wmExt = (String) wm.get('ext');
                if (wmData != null) {
                    String mime = (wmExt == 'jpg' ||
                        wmExt == 'jpeg')
                        ? 'image/jpeg'
                        : (wmExt == 'gif') ? 'image/gif' : 'image/png';
                    String dataUri = 'data:' + mime + ';base64,' + EncodingUtil.base64Encode(wmData);
                    overlayDiv =
                        '<div class="docgen-preview-watermark" aria-hidden="true">' +
                        '<img src="' +
                        dataUri +
                        '" alt=""/>' +
                        '</div>';
                }
            }
        }

        // Render the watermark as a real <img> element with explicit max-height. Using a
        // CSS background-image inside an absolutely-positioned overlay collapses to the
        // wrap's content height — a one-line preview leaves the image rendered at ~50px,
        // effectively invisible. An <img> sizes from its intrinsic dimensions and respects
        // max-height, so it shows at a usable size regardless of how short the document is.
        // The same screen-only CSS keeps running footer boxes visible in browser previews.
        // Flying Saucer pulls them into @page margin boxes, but browsers leave them in flow;
        // flex ordering moves them after the preview body instead of before page one.
        String overlay =
            '<style>' +
            '@media screen {' +
            ' .docgen-preview-wrap { position: relative; min-height: 400px; display: flex; flex-direction: column; }' +
            ' .docgen-preview-wrap #docgen-footer, .docgen-preview-wrap #docgen-footer-first { display: block !important; order: 999; margin-top: 18pt; }' +
            ' .docgen-preview-watermark { position: absolute; top: 0; left: 0; right: 0; ' +
            'text-align: center; opacity: 0.35; pointer-events: none; z-index: 0; }' +
            ' .docgen-preview-watermark img { width: 90% !important; max-width: 90% !important; ' +
            'height: auto !important; max-height: none !important; display: inline-block !important; }' +
            ' .docgen-preview-wrap > *:not(.docgen-preview-watermark) { position: relative; z-index: 1; }' +
            '}' +
            '@media print { .docgen-preview-watermark { display: none !important; } }' +
            '</style>';

        Integer bodyOpen = html.indexOf('<body');
        Integer bodyClose = html.lastIndexOf('</body>');
        if (bodyOpen >= 0 && bodyClose > bodyOpen) {
            Integer openEnd = html.indexOf('>', bodyOpen);
            if (openEnd > bodyOpen) {
                String prefix = html.substring(0, openEnd + 1);
                String middle = html.substring(openEnd + 1, bodyClose);
                String suffix = html.substring(bodyClose);
                return prefix + overlay + '<div class="docgen-preview-wrap">' + overlayDiv + middle + '</div>' + suffix;
            }
        }
        return overlay + '<div class="docgen-preview-wrap">' + overlayDiv + html + '</div>';
    }

    @TestVisible
    private static String injectPlacementSpans(String html) {
        if (String.isBlank(html))
            return html;

        // Match v3 tags: {@Signature_Role:Order:Type} and v2: {@Signature_Role}
        Pattern sigPat = Pattern.compile('\\{@Signature_([^:}]+)(?::(\\d+))?(?::([^}]+))?\\}');
        Matcher sigMatch = sigPat.matcher(html);

        // Track per-role occurrence count for unique span IDs
        Map<String, Integer> roleCounters = new Map<String, Integer>();
        String result = html;

        // Process matches in reverse order to preserve string positions
        List<Integer[]> matchPositions = new List<Integer[]>();
        List<String[]> matchData = new List<String[]>();

        // Reset matcher to scan all matches
        sigMatch.reset();
        while (sigMatch.find()) {
            matchPositions.add(new List<Integer>{ sigMatch.start(), sigMatch.end() });
            String role = sigMatch.group(1).replaceAll('_', ' ');
            String order = sigMatch.group(2) != null ? sigMatch.group(2) : '1';
            // group 3 may carry a render-style suffix (e.g. "Full:inline"); the preview
            // chip only cares about the base placement type.
            String pTypeRaw = sigMatch.group(3) != null ? sigMatch.group(3) : 'Full';
            String pType = pTypeRaw.contains(':') ? pTypeRaw.substringBefore(':').trim() : pTypeRaw.trim();
            matchData.add(new List<String>{ role, order, pType, sigMatch.group(0) });
        }

        // Replace in reverse order so positions stay valid
        for (Integer i = matchPositions.size() - 1; i >= 0; i--) {
            Integer startPos = matchPositions[i][0];
            Integer endPos = matchPositions[i][1];
            String role = matchData[i][0];
            String order = matchData[i][1];
            String pType = matchData[i][2];
            String originalTag = matchData[i][3];

            String label;
            if (pType == 'Full')
                label = 'SIGN HERE';
            else if (pType == 'Initials')
                label = 'INITIAL HERE';
            else if (pType == 'Date' || pType == 'DatePick')
                label = 'DATE';
            else
                label = 'SIGN HERE';

            String span =
                '<span class="docgen-sig"' +
                ' data-role="' +
                role.escapeHtml4() +
                '"' +
                ' data-order="' +
                order +
                '"' +
                ' data-type="' +
                pType +
                '"' +
                ' data-tag="' +
                originalTag.escapeHtml4() +
                '"' +
                ' style="display:inline-block;background:#fff8c5;border:2px dashed #f59e0b;' +
                'padding:2px 10px;border-radius:4px;font-weight:bold;color:#92400e;font-size:0.85em;">' +
                label +
                ' — ' +
                role.escapeHtml4() +
                '</span>';

            result = result.substring(0, startPos) + span + result.substring(endPos);
        }

        // Also handle bare {@Signature} tag
        if (result.contains('{@Signature}')) {
            String span =
                '<span class="docgen-sig"' +
                ' data-role="Signer" data-order="1" data-type="Full" data-tag="{@Signature}"' +
                ' style="display:inline-block;background:#fff8c5;border:2px dashed #f59e0b;' +
                'padding:2px 10px;border-radius:4px;font-weight:bold;color:#92400e;font-size:0.85em;">' +
                'SIGN HERE — Signer</span>';
            result = result.replace('{@Signature}', span);
        }

        return result;
    }

    /**
     * Creates a template-based multi-signer signature request.
     * No pre-generated DOCX needed — PDF is merged from template at signing time.
     */
    @AuraEnabled
    public static List<SignerResult> createTemplateSignerRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson
    ) {
        return createTemplateSignerRequestWithOrder(templateId, relatedRecordId, signersJson, 'Parallel');
    }

    /**
     * Mints an unguessable 64-hex request-level verification token (256-bit CSPRNG
     * via Crypto.generateAesKey, SHA-256 digested). Used as the capability on the
     * certificate's post-signing verification link (?token=). It is NOT a signing
     * token — it only gates read access to the signature audit roster.
     */
    private static String generateRequestVerificationToken() {
        Blob randomBytes = Crypto.generateAesKey(256);
        Blob hash = Crypto.generateDigest('SHA-256', randomBytes);
        return EncodingUtil.convertToHex(hash);
    }

    @AuraEnabled
    public static List<SignerResult> createTemplateSignerRequestWithOrder(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder
    ) {
        return createTemplateSignerRequestWithTitle(templateId, relatedRecordId, signersJson, signingOrder, null);
    }

    @AuraEnabled
    public static List<SignerResult> createTemplateSignerRequestWithTitle(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat
    ) {
        // Validate template exists
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Name', 'Document_Title_Format__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT Id, Name, Document_Title_Format__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (templates.isEmpty()) {
            throw new AuraHandledException('Template not found.');
        }

        // Inherit the template's document-naming pattern for the SIGNED PDF when the
        // caller didn't pass an override, so signing matches normal generation (#2).
        if (String.isBlank(documentTitleFormat) && String.isNotBlank(templates[0].Document_Title_Format__c)) {
            documentTitleFormat = templates[0].Document_Title_Format__c;
        }

        // Parse signers JSON
        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }

        // Create parent request with template reference (no Source_Document_Id__c)
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Template__c = templateId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        req.Signing_Order__c = String.isNotBlank(signingOrder) ? signingOrder : 'Parallel';
        if (String.isNotBlank(documentTitleFormat)) {
            req.Document_Title_Format__c = documentTitleFormat;
        }
        // SECURITY: unguessable request-level token used as the capability for the
        // post-signing verification link (?token=) printed on the certificate.
        // Distinct from signer signing tokens — this only gates audit-roster reads.
        req.Secure_Token__c = generateRequestVerificationToken();
        req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(null);
        // Package-internal object — CRUD controlled by Portwood permission sets
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.assertCreateable(
            req,
            new Set<String>{
                'Template__c',
                'Related_Record_Id__c',
                'Status__c',
                'Signing_Order__c',
                'Document_Title_Format__c',
                'Secure_Token__c',
                'Expires_At__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(req, AccessLevel.SYSTEM_MODE);

        // Pre-compute everything while we have admin access.
        // Guest users can't query template data or ContentVersions (content sharing).
        // Store on the request record which the guest accesses via token + SYSTEM_MODE.
        try {
            Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, relatedRecordId);
            Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');

            String mergedHtml = (String) mergeData.get('combinedDocumentXml');
            if (String.isBlank(mergedHtml)) {
                mergedHtml = (String) mergeData.get('documentXml');
            }
            Map<String, String> previewImageMap = buildSignaturePreviewImageMap(pdfImageMap, mergedHtml);

            // Render preview HTML using public URLs (small, no base64 bloat)
            String previewHtml = renderMergedSignatureHtml(mergeData, templateId, previewImageMap);

            // Inject interactive placement spans for the guided signing UI.
            // Watermark overlay is NOT injected here — base64-embedded image would blow
            // past Signature_Data__c's LongTextArea limit. Overlay is added at read time
            // in DocGenSignatureController.fetchDocumentData instead.
            previewHtml = injectPlacementSpans(previewHtml);

            // 1.49 (#28): pre-extract compact style maps while we're in admin context.
            // The signed-PDF queueable runs as Automated Process which can't query the
            // pre-decomposed styles.xml ContentVersion regardless of sharing model — so we
            // cache just the attributes the renderer needs for async fallback.
            Map<String, String> tableBordersMap = DocGenHtmlRenderer.extractTableStyleBorderMap(
                DocGenHtmlRenderer.stylesXml
            );
            Map<String, Map<String, String>> textAttrsMap = DocGenHtmlRenderer.extractStyleTextAttributeMap(
                DocGenHtmlRenderer.stylesXml
            );

            // Store image map (for Queueable) + preview HTML (for guest VF page) + style maps (for async render)
            Map<String, Object> cachedData = new Map<String, Object>{
                'imageMap' => pdfImageMap,
                'previewHtml' => previewHtml,
                'tableBordersMap' => tableBordersMap,
                'styleTextAttrsMap' => textAttrsMap
            };
            req.Signature_Data__c = JSON.serialize(cachedData);

            // INTEGRITY: freeze the merged document body now, while we're in admin context
            // with the live record. The signed PDF is rendered from THIS snapshot, not a
            // re-merge at sign time, so the signer signs exactly what was reviewed. #156:
            // the snapshot is stored in a ContentVersion (no size cap), so even large/
            // image-heavy templates are frozen rather than degrading to a live merge.
            Set<String> snapshotFields = new Set<String>{ 'Signature_Data__c' };
            String frozenJson = DocGenSignatureService.buildFrozenDocumentJson(
                new List<Map<String, Object>>{ mergeData },
                new List<Id>{ templateId }
            );
            if (String.isNotBlank(frozenJson)) {
                req.Frozen_Document_CV_Id__c = DocGenSignatureService.saveFrozenSnapshotCv(frozenJson);
                req.Snapshot_Hash__c = DocGenSignatureService.hashFrozenDocument(frozenJson);
                req.Snapshot_Taken_At__c = System.now();
                snapshotFields.addAll(
                    new Set<String>{ 'Frozen_Document_CV_Id__c', 'Snapshot_Hash__c', 'Snapshot_Taken_At__c' }
                );
            } else {
                System.debug(
                    LoggingLevel.WARN,
                    'Portwood: no document body to freeze; request ' + req.Id + ' will live-merge at sign time.'
                );
            }
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            DocGenFlsGuard.assertUpdateable(req, snapshotFields);
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(req, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: Failed to pre-compute signature data: ' + e.getMessage());
        }

        // Create individual signer records + send emails (shared logic)
        return createSignersAndNotify(req.Id, templateId, templates[0].Name, signerInputs);
    }

    /**
     * Creates a multi-template packet signature request.
     * All templates are merged, preview HTML is concatenated with page breaks,
     * and placements are created across documents with Document_Index__c.
     */
    @AuraEnabled
    public static List<SignerResult> createPacketSignerRequest(
        String templateIdsJson,
        String relatedRecordId,
        String signersJson,
        String signingOrder
    ) {
        return createPacketSignerRequestWithTitle(templateIdsJson, relatedRecordId, signersJson, signingOrder, null);
    }

    @AuraEnabled
    public static List<SignerResult> createPacketSignerRequestWithTitle(
        String templateIdsJson,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat
    ) {
        List<Id> templateIds = parseAndDedupTemplateIds(templateIdsJson);
        if (templateIds.isEmpty()) {
            throw new AuraHandledException('At least one template is required.');
        }

        // #170 consolidation: all packet signing routes through the guided PDF path
        // (combined viewing PDF + cross-document sentinel placements), replacing the
        // classic preview page. Single template -> guided single-template path.
        if (templateIds.size() == 1) {
            return createGuidedPdfSignatureRequest(
                templateIds[0],
                relatedRecordId,
                signersJson,
                signingOrder,
                documentTitleFormat
            );
        }
        return createGuidedPacketSignatureRequest(
            templateIdsJson,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat
        );
    }

    /**
     * Creates signers and sends emails WITHOUT creating placements.
     * Used by packet flow which creates placements separately per document.
     */
    private static List<SignerResult> createSignersAndNotifyWithoutPlacements(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs
    ) {
        // Temporarily null the templateId to skip placement creation in createSignersAndNotify
        return createSignersAndNotify(requestId, null, documentTitle, signerInputs, true);
    }

    @AuraEnabled
    public static List<ContentVersion> getRelatedDocuments(Id recordId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
            WITH USER_MODE
        ];
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links)
            docIds.add(link.ContentDocumentId);

        return [
            SELECT Id, Title, FileExtension, ContentDocumentId
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = TRUE AND FileExtension = 'docx'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Creates a multi-signer signature request with individual tokens per signer.
     * Legacy DOCX-based flow — requires a pre-generated DOCX on the record.
     * signersJson: [{roleName, contactId, signerName, signerEmail}, ...]
     */
    @AuraEnabled
    public static List<SignerResult> createMultiSignerRequest(
        Id contentDocumentId,
        String relatedRecordId,
        String signersJson
    ) {
        // Resolve latest ContentVersionId
        List<ContentDocument> docs = [
            SELECT LatestPublishedVersionId
            FROM ContentDocument
            WHERE Id = :contentDocumentId
            WITH USER_MODE
            LIMIT 1
        ];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        // Parse signers JSON
        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }

        // Create parent request
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(null);
        // Package-internal object — CRUD controlled by Portwood permission sets
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.assertCreateable(
            req,
            new Set<String>{ 'Source_Document_Id__c', 'Related_Record_Id__c', 'Status__c', 'Expires_At__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(req, AccessLevel.SYSTEM_MODE);

        String documentTitle = getDocumentTitle(contentVersionId);
        return createSignersAndNotify(req.Id, null, documentTitle, signerInputs);
    }

    /**
     * Milestone 1 — "send an already-generated document for signature".
     *
     * Creates a Template__c-null signature request bound directly to a
     * pre-generated ContentVersion (Source_Document_Id__c). The signer URLs
     * point at the new flat-PDF signing page (getSigningPdfPagePath), which
     * renders the real PDF and captures a name+consent signature → audit +
     * Status='Signed'. No template merge, no placements (Template__c is null,
     * so createPlacementsForSigners early-returns cleanly), no DOCX-XML
     * stamping.
     *
     * signersJson: [{signerName, signerEmail, roleName, contactId}, ...]
     */
    /**
     * @deprecated REMOVED (v3.18) — sending a pre-generated PDF (ContentVersion) for
     * signature is no longer supported. A flat PDF carries no parseable {@Signature_*}
     * placement tags, so it can never drive guided/field-by-field signing or stamp
     * signatures back into the document (it could only ever flat-sign + append a
     * certificate). E-signature now always starts from a TEMPLATE, which Portwood
     * re-renders and tags at send time. Kept (managed-package immutability) only to
     * fail fast with guidance; callers should use createGuidedPdfSignatureRequest /
     * createTemplateSnapshotRequest with a Template Id instead.
     */
    @AuraEnabled
    public static List<SignerResult> createRequestFromContentVersion(
        Id contentVersionId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat
    ) {
        throw new AuraHandledException(
            'Sending a pre-generated PDF for signature is no longer supported. Send the template for ' +
                'signature instead — Portwood renders and tags the document automatically so signatures can ' +
                'be placed in the document and stamped on completion.'
        );
    }

    /**
     * Milestone 2 — "send a template for signature with a data snapshot".
     *
     * NOTE: no longer a primary entry point. createGuidedPdfSignatureRequest is the
     * single canonical send method; it dispatches here ONLY for templates that use the
     * {#Signatures} variable-signer loop block and carry no {@Signature_*} placement
     * tags, because the loop needs this snapshot/re-render strategy to repopulate signed
     * rows at completion. Still @AuraEnabled (a thin direct caller + its test remain).
     *
     * Captures the template's resolved merge data for the record as JSON at
     * send-time (Render_Data_Snapshot__c) and generates the viewing PDF from that
     * SAME snapshot, so what the signer reviews is byte-identical to what the
     * completion finalizer re-renders. On completion the finalizer re-renders from
     * the snapshot (not the live record) and appends the signing-certificate page —
     * immune to edits made to the record between send and sign — then links the
     * completed PDF to the related record.
     *
     * signersJson: [{signerName, signerEmail, roleName, contactId}, ...]
     */
    // 5-arg overload — existing Apex/test/script callers. No send-time message/subject
    // (#193); inherits template/org verification config (#verification).
    public static List<SignerResult> createTemplateSnapshotRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat
    ) {
        return createTemplateSnapshotRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            null,
            null,
            null,
            null
        );
    }

    // 6-arg overload (message only) — #193.
    public static List<SignerResult> createTemplateSnapshotRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage
    ) {
        return createTemplateSnapshotRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            emailMessage,
            null,
            null,
            null
        );
    }

    // 7-arg overload (message + subject) — #193.
    public static List<SignerResult> createTemplateSnapshotRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage,
        String emailSubject
    ) {
        return createTemplateSnapshotRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            emailMessage,
            emailSubject,
            null,
            null
        );
    }

    @AuraEnabled
    public static List<SignerResult> createTemplateSnapshotRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage,
        String emailSubject,
        Boolean requireVerification,
        Boolean prefillSignerEmail
    ) {
        return createTemplateSnapshotRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            emailMessage,
            emailSubject,
            requireVerification,
            prefillSignerEmail,
            null
        );
    }

    /** 10-arg overload — pre-expirationDays callers. */
    public static List<SignerResult> createTemplateSnapshotRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage,
        String emailSubject,
        Boolean requireVerification,
        Boolean prefillSignerEmail,
        Boolean sendEmails
    ) {
        return createTemplateSnapshotRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            emailMessage,
            emailSubject,
            requireVerification,
            prefillSignerEmail,
            sendEmails,
            null
        );
    }

    /** 11-arg canonical — #195/expirationDays: see createGuidedPdfSignatureRequest. */
    public static List<SignerResult> createTemplateSnapshotRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage,
        String emailSubject,
        Boolean requireVerification,
        Boolean prefillSignerEmail,
        Boolean sendEmails,
        Integer expirationDays
    ) {
        if (templateId == null) {
            throw new AuraHandledException('A template Id is required.');
        }
        if (String.isBlank(relatedRecordId)) {
            throw new AuraHandledException('A related record Id is required for snapshot signing.');
        }

        // Load the template's data-binding config.
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Name', 'Base_Object_API__c', 'Query_Config__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Template__c> tpls = [
            SELECT Name, Base_Object_API__c, Query_Config__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (tpls.isEmpty()) {
            throw new AuraHandledException('Template not found.');
        }
        DocGen_Template__c tpl = tpls[0];
        if (String.isBlank(tpl.Base_Object_API__c) || String.isBlank(tpl.Query_Config__c)) {
            throw new AuraHandledException(
                'Snapshot signing requires a template with a base object and query configuration.'
            );
        }

        // Snapshot the record's merge data at send-time.
        Map<String, Object> snapshot = DocGenDataRetriever.getRecordData(
            relatedRecordId,
            tpl.Base_Object_API__c,
            tpl.Query_Config__c
        );
        String snapshotJson = JSON.serialize(snapshot);
        if (snapshotJson.length() > 131072) {
            throw new AuraHandledException(
                'This document\'s data is too large for snapshot signing (over 131,072 characters). ' +
                'Use a smaller template/dataset or the send-existing-document path.'
            );
        }

        // Parse signer inputs once — reused for the preview render below and for
        // signer creation at the end of this method.
        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }

        // Generate the viewing PDF from the SAME snapshot so the signer sees exactly
        // what the completion finalizer will re-render. M3 — the viewing render gets a
        // COPY of the snapshot with the pending {#Signatures} loop rows injected, so the
        // signer previews the signature layout (invited names, "Pending" status). The
        // stored snapshot (snapshotJson) stays record-data-only; the finalizer injects
        // the signed rows at completion.
        Map<String, Object> viewData = new Map<String, Object>(snapshot);
        viewData.put('Signatures', DocGenSignatureService.buildPendingSignerLoopData(signerInputs));
        Map<String, Object> gen = DocGenService.generatePdfBlobFromData(templateId, viewData);
        Blob viewingBlob = (Blob) gen.get('blob');
        String genTitle = (String) gen.get('title');
        String fileTitle = String.isNotBlank(genTitle) ? genTitle : tpl.Name;

        // Standalone viewing ContentVersion (not linked to the record — the final
        // signed + certificate PDF is what lands on the record at completion).
        ContentVersion viewCv = new ContentVersion();
        viewCv.Title = fileTitle;
        viewCv.PathOnClient = fileTitle + '.pdf';
        viewCv.VersionData = viewingBlob;
        DocGenFlsGuard.assertCreateable(viewCv, new Set<String>{ 'Title', 'PathOnClient', 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(viewCv, AccessLevel.SYSTEM_MODE);

        // Create the snapshot-backed request: Template__c + Render_Data_Snapshot__c
        // drive the completion re-render; Source_Document_Id__c is the viewing CV.
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Template__c = templateId;
        req.Render_Data_Snapshot__c = snapshotJson;
        req.Source_Document_Id__c = viewCv.Id;
        req.Related_Record_Id__c = relatedRecordId;
        req.Status__c = 'Sent';
        req.Signing_Order__c = String.isNotBlank(signingOrder) ? signingOrder : 'Parallel';
        if (String.isNotBlank(documentTitleFormat)) {
            req.Document_Title_Format__c = documentTitleFormat;
        }
        req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(expirationDays);
        DocGenFlsGuard.assertCreateable(
            req,
            new Set<String>{
                'Template__c',
                'Render_Data_Snapshot__c',
                'Source_Document_Id__c',
                'Related_Record_Id__c',
                'Status__c',
                'Signing_Order__c',
                'Document_Title_Format__c',
                'Expires_At__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(req, AccessLevel.SYSTEM_MODE);

        // Share the standalone viewing CV with the guest signer so the signing-page
        // preview (getSourcePdfBase64) can read it. Without this link the guest's
        // SYSTEM_MODE read returns 0 rows → "Document not found" → blank preview.
        shareViewingDocumentWithGuest(viewCv.Id, req.Id);

        // Create signer records + emails, URLs at the flat-PDF page (signerInputs parsed above).
        // templateId=null → skip {@Signature} placement creation (snapshot signing has no tags).
        return createSignersAndNotify(
            req.Id,
            null,
            fileTitle,
            signerInputs,
            sendEmails !=
            false, // #195 — null/true sends; explicit false suppresses
            getSigningPdfPagePath(),
            emailMessage,
            emailSubject,
            requireVerification,
            prefillSignerEmail
        );
    }

    /**
     * Creates a GUIDED PDF-signing request from a template that carries
     * {@Signature_Role:Order:Type} placement tags. The signer reviews a flat PDF
     * in the PDF.js viewer with positioned sign-spot chips (vs. the classic HTML
     * signing page).
     *
     * Each placement tag is swapped to a UNIQUE invisible sentinel (@@SIG-n@@):
     *  - VIEWING body wraps it white (invisible on the page) but PDF.js can still
     *    extract it from the text layer to position a chip;
     *  - FROZEN body keeps the bare sentinel, and the placement's Tag_Text__c is
     *    that sentinel, so the completion finalizer's stampSignaturesInHtml
     *    replaces it with the signed value in the authoritative PDF.
     *
     * Scope: HTML templates (the recommended signature format). DOCX tags can
     * split across runs and need a different substitution strategy — deferred (#167).
     */
    /**
     * Option (b) for tag-less legacy templates (#170): synthesize one Full + one
     * Date placement per signer so the template signs through the guided PDF path
     * with zero author change. Roles are de-duplicated so each maps to one signer.
     */
    private static List<PlacementInfo> buildSyntheticSignaturePlacements(List<Map<String, Object>> signerInputs) {
        List<PlacementInfo> out = new List<PlacementInfo>();
        Set<String> usedRoles = new Set<String>();
        for (Integer i = 0; i < signerInputs.size(); i++) {
            String role = (String) signerInputs[i].get('roleName');
            if (String.isBlank(role) || usedRoles.contains(role)) {
                role = 'Signer ' + (i + 1);
            }
            usedRoles.add(role);
            String slug = role.replaceAll('[^A-Za-z0-9]+', '_');
            out.add(new PlacementInfo(role, 1, 'Full', '{@Signature_' + slug + ':1:Full}'));
            out.add(new PlacementInfo(role, 1, 'Date', '{@Signature_' + slug + ':1:Date}'));
        }
        return out;
    }

    /**
     * Appends a clean "Signatures" block carrying each synthetic placement's tag
     * text to the merged body so the guided pipeline (frozen sentinels + white-text
     * positioning) finds and positions them. Handles HTML and merged-DOCX bodies.
     * Placements arrive as (Full, Date) pairs per signer.
     */
    private static String appendSyntheticSignatureBlock(
        String body,
        String templateType,
        List<PlacementInfo> placements
    ) {
        if (DocGenService.isHtmlBacked(templateType)) {
            String block =
                '<div style="margin-top:40px;border-top:1px solid #999;padding-top:14px;">' +
                '<div style="font-weight:bold;font-size:12pt;margin-bottom:10px;">Signatures</div>';
            for (Integer i = 0; i < placements.size(); i += 2) {
                PlacementInfo full = placements[i];
                PlacementInfo dt = (i + 1 < placements.size()) ? placements[i + 1] : null;
                block +=
                    '<div style="margin-bottom:26px;">' +
                    '<div>' +
                    String.valueOf(full.role).escapeHtml4() +
                    ' signature: ' +
                    full.tagText +
                    '</div>' +
                    (dt != null ? '<div style="margin-top:6px;">Date: ' + dt.tagText + '</div>' : '') +
                    '</div>';
            }
            block += '</div>';
            Integer bodyClose = body.toLowerCase().lastIndexOf('</body>');
            return (bodyClose != -1)
                ? (body.substring(0, bodyClose) + block + body.substring(bodyClose))
                : (body + block);
        }
        // Merged DOCX document.xml: build <w:p> paragraphs; insert before the body-level
        // <w:sectPr> (which must remain the last child of <w:body>), else before </w:body>.
        String para = '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Signatures</w:t></w:r></w:p>';
        for (Integer i = 0; i < placements.size(); i += 2) {
            PlacementInfo full = placements[i];
            PlacementInfo dt = (i + 1 < placements.size()) ? placements[i + 1] : null;
            para +=
                '<w:p><w:r><w:t xml:space="preserve">' +
                String.valueOf(full.role).escapeHtml4() +
                ' signature: </w:t></w:r>' +
                '<w:r><w:t xml:space="preserve">' +
                full.tagText +
                '</w:t></w:r></w:p>';
            if (dt != null) {
                para +=
                    '<w:p><w:r><w:t xml:space="preserve">Date: </w:t></w:r>' +
                    '<w:r><w:t xml:space="preserve">' +
                    dt.tagText +
                    '</w:t></w:r></w:p>';
            }
        }
        Integer sectPr = body.lastIndexOf('<w:sectPr');
        if (sectPr != -1) {
            return body.substring(0, sectPr) + para + body.substring(sectPr);
        }
        Integer bodyClose = body.indexOf('</w:body>');
        return (bodyClose != -1) ? (body.substring(0, bodyClose) + para + body.substring(bodyClose)) : (body + para);
    }

    /**
     * Signer form-field tags {?key} (optional {?key|fallback}) on the guided PDF path.
     * Rewrites them in the VIEWING html to white (invisible) @@FF-<key>@@ sentinels: the
     * literal tag never shows to the signer, yet the PDF.js text layer can still locate the
     * position so the drawn-signature client stamps the collected value there (mirrors the
     * @@SIG-n@@ signature sentinels). The FROZEN body deliberately keeps the bare {?key}
     * tag, so the typed-name finalize re-render resolves it server-side
     * (DocGenService.resolveFormFields). Key grammar matches DocGenFieldWritebackService.
     */
    @TestVisible
    private static String applyFormFieldViewingSentinels(String viewingHtml) {
        if (String.isBlank(viewingHtml) || !viewingHtml.contains('{?')) {
            return viewingHtml;
        }
        return viewingHtml.replaceAll(
            '\\{\\?([A-Za-z0-9_]+)(?:\\|[^}]*)?\\}',
            '<span style="color:#ffffff">@@FF-$1@@</span>'
        );
    }

    // 5-arg overload — existing Apex/test/script callers. No send-time message/subject
    // (#193); inherits template/org verification config (#verification).
    public static List<SignerResult> createGuidedPdfSignatureRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat
    ) {
        return createGuidedPdfSignatureRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            null,
            null,
            null,
            null
        );
    }

    // 6-arg overload (message only) — #193.
    public static List<SignerResult> createGuidedPdfSignatureRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage
    ) {
        return createGuidedPdfSignatureRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            emailMessage,
            null,
            null,
            null
        );
    }

    // 7-arg overload (message + subject) — #193.
    public static List<SignerResult> createGuidedPdfSignatureRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage,
        String emailSubject
    ) {
        return createGuidedPdfSignatureRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            emailMessage,
            emailSubject,
            null,
            null
        );
    }

    // 7-arg overload (verification config only) — #verification. For callers that pass
    // per-send require/prefill without a custom message (e.g. the verification UAT path).
    public static List<SignerResult> createGuidedPdfSignatureRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        Boolean requireVerification,
        Boolean prefillSignerEmail
    ) {
        return createGuidedPdfSignatureRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            null,
            null,
            requireVerification,
            prefillSignerEmail
        );
    }

    public static List<SignerResult> createGuidedPdfSignatureRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage,
        String emailSubject,
        Boolean requireVerification,
        Boolean prefillSignerEmail
    ) {
        return createGuidedPdfSignatureRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            emailMessage,
            emailSubject,
            requireVerification,
            prefillSignerEmail,
            null
        );
    }

    /** 10-arg overload — #195: pre-expirationDays callers. */
    public static List<SignerResult> createGuidedPdfSignatureRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage,
        String emailSubject,
        Boolean requireVerification,
        Boolean prefillSignerEmail,
        Boolean sendEmails
    ) {
        return createGuidedPdfSignatureRequest(
            templateId,
            relatedRecordId,
            signersJson,
            signingOrder,
            documentTitleFormat,
            emailMessage,
            emailSubject,
            requireVerification,
            prefillSignerEmail,
            sendEmails,
            null
        );
    }

    /**
     * 11-arg canonical. sendEmails=false (#195) suppresses the branded invitation
     * emails so a Flow can send its own using the returned signer URLs; null/true
     * sends (the long-standing behavior; every pre-existing caller delegates null).
     * expirationDays overrides the org-default signing window for this request
     * (null → DocGen_Settings__c.Signature_Expiration_Days__c, fallback 2 days).
     */
    @AuraEnabled
    public static List<SignerResult> createGuidedPdfSignatureRequest(
        Id templateId,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat,
        String emailMessage,
        String emailSubject,
        Boolean requireVerification,
        Boolean prefillSignerEmail,
        Boolean sendEmails,
        Integer expirationDays
    ) {
        List<DocGen_Template__c> tpls = [
            SELECT Id, Name, Document_Title_Format__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (tpls.isEmpty()) {
            throw new AuraHandledException('Template not found.');
        }

        // Inherit the template's document-naming pattern so the SIGNED PDF follows the
        // same name the template uses for normal generation (e.g. "Waiver - {Name}
        // {Today: MM/DD/YYYY}"). Only when the caller didn't pass an explicit override.
        // Without this, signed docs fell back to "<Template> - Signed" regardless of the
        // template's configured name (Sarah's #2).
        if (String.isBlank(documentTitleFormat) && String.isNotBlank(tpls[0].Document_Title_Format__c)) {
            documentTitleFormat = tpls[0].Document_Title_Format__c;
        }

        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }

        // ── Single canonical signature-send entry point ─────────────────────────
        // Every send action (the runner LWC, "Portwood: Create Signature Request", and
        // the deprecated "Portwood: Send Existing Document for Signature") funnels
        // through here. Dispatch by template shape:
        //   • {@Signature_*} placement tags  → guided sentinel path below (inline-aware)
        //   • tag-less                        → guided synthetic "Signatures" block (#170)
        //   • {#Signatures} loop block ONLY   → snapshot render strategy (this branch)
        // The {#Signatures} variable-signer loop is repopulated with the SIGNED rows at
        // completion (buildSignerLoopData). The guided frozen-body path freezes the loop
        // empty at send and can't reproduce that, so loop-only templates must use the
        // snapshot mechanism to stay backwards-compatible. A template that has BOTH tags
        // and a loop block keeps the guided path (tags win); the loop renders empty — a
        // rare, documented edge.
        List<PlacementInfo> placements = getTemplateSignaturePlacements(templateId);
        if (placements.isEmpty() && templateHasSignaturesLoopBlock(templateId)) {
            DocGenFlsGuard.assertAccessible(
                DocGen_Template__c.sObjectType,
                new Set<String>{ 'Base_Object_API__c', 'Query_Config__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> shape = [
                SELECT Base_Object_API__c, Query_Config__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets
            if (
                !shape.isEmpty() &&
                String.isNotBlank(shape[0].Base_Object_API__c) &&
                String.isNotBlank(shape[0].Query_Config__c)
            ) {
                return createTemplateSnapshotRequest(
                    templateId,
                    relatedRecordId,
                    signersJson,
                    signingOrder,
                    documentTitleFormat,
                    emailMessage,
                    emailSubject,
                    requireVerification,
                    prefillSignerEmail,
                    sendEmails,
                    expirationDays
                );
            }
        }

        // Merge the template against the live record (point-in-time body).
        Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, relatedRecordId);
        String templateType = (String) mergeData.get('templateType');
        // Word (DOCX) and HTML are both supported. PowerPoint has no signing surface.
        if (templateType == 'PowerPoint') {
            throw new AuraHandledException('Guided signing supports Word and HTML templates, not PowerPoint.');
        }
        String body = (String) mergeData.get('combinedDocumentXml');
        if (String.isBlank(body)) {
            body = (String) mergeData.get('documentXml');
        }

        if (placements.isEmpty()) {
            // Option (b) for tag-less legacy templates (#170): synthesize a "Signatures"
            // block (one Full + Date per signer) and append it to the merged body so the
            // template signs through the guided path — one signing path for all templates,
            // zero author change. Tag-ful templates skip this entirely.
            placements = buildSyntheticSignaturePlacements(signerInputs);
            body = appendSyntheticSignatureBlock(body, templateType, placements);
        }

        // FROZEN body: replace each placement's tag (in document order) with a unique
        // bare sentinel. The tags are contiguous in both HTML and merged DOCX (the merge
        // engine heals run-split tags — the same reason stampSignaturesInXml can find
        // them), so one substitution covers both types. This is what the finalizer stamps.
        String frozenBody = body;
        List<String> sentinels = new List<String>();
        for (Integer i = 0; i < placements.size(); i++) {
            String sentinel = '@@SIG-' + i + '@@';
            sentinels.add(sentinel);
            frozenBody = frozenBody.replaceFirst(Pattern.quote(placements[i].tagText), sentinel);
        }

        // Freeze the sentinel body so completion re-renders + stamps it (per type).
        Map<String, Object> frozenMerge = new Map<String, Object>(mergeData);
        frozenMerge.put('combinedDocumentXml', frozenBody);
        frozenMerge.put('documentXml', frozenBody);
        String frozenJson = DocGenSignatureService.buildFrozenDocumentJson(
            new List<Map<String, Object>>{ frozenMerge },
            new List<Id>{ templateId }
        );

        // VIEWING render: produce the HTML the signer's PDF is rendered from. HTML
        // templates ARE that HTML; Word/DOCX is converted through the same pipeline the
        // signed-PDF finalizer uses. Either way the sentinels land as plain text in the
        // HTML, which we then wrap white — invisible on the page, still extractable by the
        // PDF.js text layer for sign-spot positioning.
        Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
        if (pdfImageMap == null) {
            pdfImageMap = new Map<String, String>();
        }
        String viewingHtml;
        if (DocGenService.isHtmlBacked(templateType)) {
            viewingHtml = frozenBody;
        } else {
            // Re-prime the renderer context (mergeTemplateForSignature set it, but be
            // explicit) and convert the sentinel-bearing DOCX body to HTML.
            DocGenHtmlRenderer.stylesXml = (String) mergeData.get('stylesXml');
            DocGenHtmlRenderer.numberingXml = (String) mergeData.get('numberingXml');
            DocGenService.applyWatermarkOverride(templateId);
            viewingHtml = DocGenHtmlRenderer.convertToHtml(frozenBody, pdfImageMap);
        }
        for (String sentinel : sentinels) {
            viewingHtml = viewingHtml.replace(sentinel, '<span style="color:#ffffff">' + sentinel + '</span>');
        }
        // Signer form-field tags {?key}: hide the literal tag and leave a locatable
        // @@FF-<key>@@ sentinel for the drawn-path client to stamp the value onto.
        viewingHtml = applyFormFieldViewingSentinels(viewingHtml);

        // Render the viewing PDF (invisible sentinels) → standalone ContentVersion.
        Blob viewingBlob = Blob.toPdf(viewingHtml);
        String fileTitle = tpls[0].Name;
        ContentVersion viewCv = new ContentVersion();
        viewCv.Title = fileTitle;
        viewCv.PathOnClient = fileTitle + '.pdf';
        viewCv.VersionData = viewingBlob;
        DocGenFlsGuard.assertCreateable(viewCv, new Set<String>{ 'Title', 'PathOnClient', 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(viewCv, AccessLevel.SYSTEM_MODE);

        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Template__c = templateId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Source_Document_Id__c = viewCv.Id;
        req.Status__c = 'Sent';
        req.Signing_Order__c = String.isNotBlank(signingOrder) ? signingOrder : 'Parallel';
        if (String.isNotBlank(documentTitleFormat)) {
            req.Document_Title_Format__c = documentTitleFormat;
        }
        req.Secure_Token__c = generateRequestVerificationToken();
        req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(expirationDays);
        Set<String> reqFields = new Set<String>{
            'Template__c',
            'Related_Record_Id__c',
            'Source_Document_Id__c',
            'Status__c',
            'Signing_Order__c',
            'Document_Title_Format__c',
            'Secure_Token__c',
            'Expires_At__c'
        };
        if (String.isNotBlank(frozenJson)) {
            // #156: snapshot persisted to a ContentVersion (no 131072-char cap) and referenced
            // by Id, so large templates get a true frozen snapshot instead of a live re-merge.
            req.Frozen_Document_CV_Id__c = DocGenSignatureService.saveFrozenSnapshotCv(frozenJson);
            req.Snapshot_Hash__c = DocGenSignatureService.hashFrozenDocument(frozenJson);
            req.Snapshot_Taken_At__c = System.now();
            reqFields.addAll(new Set<String>{ 'Frozen_Document_CV_Id__c', 'Snapshot_Hash__c', 'Snapshot_Taken_At__c' });
        }
        DocGenFlsGuard.assertCreateable(req, reqFields);
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(req, AccessLevel.SYSTEM_MODE);

        // Share the standalone viewing CV with the guest signer so the signing-page
        // preview (getSourcePdfBase64) can read it (see shareViewingDocumentWithGuest).
        shareViewingDocumentWithGuest(viewCv.Id, req.Id);

        // Create signers at the PDF-viewer page (templateId=null skips the classic
        // placement creation — we create sentinel-keyed placements below).
        List<SignerResult> results = createSignersAndNotify(
            req.Id,
            null,
            fileTitle,
            signerInputs,
            sendEmails !=
            false, // #195 — null/true sends; explicit false suppresses
            getSigningPdfPagePath(),
            emailMessage,
            emailSubject,
            requireVerification,
            prefillSignerEmail
        );

        // Map placements → signers by role (fallback: first signer), Tag_Text__c = sentinel.
        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Role_Name__c', 'Signature_Request__c', 'Sort_Order__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signer__c> signerRecs = [
            SELECT Id, Role_Name__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :req.Id
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];
        Map<String, DocGen_Signer__c> roleSignerMap = new Map<String, DocGen_Signer__c>();
        for (DocGen_Signer__c s : signerRecs) {
            if (String.isNotBlank(s.Role_Name__c)) {
                roleSignerMap.put(s.Role_Name__c, s);
            }
        }
        DocGen_Signer__c fallbackSigner = signerRecs.isEmpty() ? null : signerRecs[0];

        List<DocGen_Signature_Placement__c> placementRecords = new List<DocGen_Signature_Placement__c>();
        for (Integer i = 0; i < placements.size(); i++) {
            PlacementInfo p = placements[i];
            DocGen_Signer__c signer = roleSignerMap.containsKey(p.role) ? roleSignerMap.get(p.role) : fallbackSigner;
            if (signer == null) {
                continue;
            }
            placementRecords.add(
                new DocGen_Signature_Placement__c(
                    Signer__c = signer.Id,
                    Signature_Request__c = req.Id,
                    Document_Index__c = 0,
                    Sequence_Order__c = p.sequence,
                    Placement_Type__c = p.placementType,
                    Render_Inline__c = p.renderInline,
                    Status__c = 'Pending',
                    Tag_Text__c = sentinels[i]
                )
            );
        }
        if (!placementRecords.isEmpty()) {
            DocGenFlsGuard.assertCreateable(
                placementRecords,
                new Set<String>{
                    'Signer__c',
                    'Signature_Request__c',
                    'Document_Index__c',
                    'Sequence_Order__c',
                    'Placement_Type__c',
                    'Render_Inline__c',
                    'Status__c',
                    'Tag_Text__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(placementRecords, AccessLevel.SYSTEM_MODE);
        }

        return results;
    }

    /**
     * Guided PDF signing for a MULTI-TEMPLATE packet (#170 consolidation). Renders
     * every selected template into ONE combined viewing PDF (page-broken, with a
     * "Document N of M" header), positions sentinel sign-spots across all documents
     * (Document_Index__c per doc), and routes signers to the guided PDF page — the
     * same single path single-template signing uses. Tag-less documents get an
     * auto-appended "Signatures" block (option b). The guided finalizer stores the
     * client-composited multi-page PDF as-is, so no server-side multi-doc stamping
     * is needed. Single-template callers should use createGuidedPdfSignatureRequest.
     */
    @AuraEnabled
    public static List<SignerResult> createGuidedPacketSignatureRequest(
        String templateIdsJson,
        String relatedRecordId,
        String signersJson,
        String signingOrder,
        String documentTitleFormat
    ) {
        List<Id> templateIds = parseAndDedupTemplateIds(templateIdsJson);
        if (templateIds.isEmpty()) {
            throw new AuraHandledException('At least one template is required.');
        }
        if (templateIds.size() == 1) {
            return createGuidedPdfSignatureRequest(
                templateIds[0],
                relatedRecordId,
                signersJson,
                signingOrder,
                documentTitleFormat
            );
        }

        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Name', 'Document_Title_Format__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Map<Id, DocGen_Template__c> templateMap = new Map<Id, DocGen_Template__c>(
            [
                SELECT Id, Name, Document_Title_Format__c
                FROM DocGen_Template__c
                WHERE Id IN :templateIds
                WITH SYSTEM_MODE
            ]
        );
        for (Id tid : templateIds) {
            if (!templateMap.containsKey(tid)) {
                throw new AuraHandledException('Template not found: ' + tid);
            }
        }
        if (
            String.isBlank(documentTitleFormat) &&
            String.isNotBlank(templateMap.get(templateIds[0]).Document_Title_Format__c)
        ) {
            documentTitleFormat = templateMap.get(templateIds[0]).Document_Title_Format__c;
        }

        List<Object> rawInputs = (List<Object>) JSON.deserializeUntyped(signersJson);
        List<Map<String, Object>> signerInputs = new List<Map<String, Object>>();
        for (Object item : rawInputs) {
            signerInputs.add((Map<String, Object>) item);
        }

        // Per-doc: merge → (synthesize tag-less, option b) → sentinel-substitute → build
        // the frozen body + viewing HTML. Sentinels are globally unique across the packet.
        List<Map<String, Object>> frozenMergeOutputs = new List<Map<String, Object>>();
        Map<String, String> combinedPdfImageMap = new Map<String, String>();
        List<String> viewingParts = new List<String>();
        List<String> allSentinels = new List<String>();
        List<PlacementInfo> allPlacementInfos = new List<PlacementInfo>();
        List<Integer> placementDocIdx = new List<Integer>();
        Integer sentinelCounter = 0;

        for (Integer docIdx = 0; docIdx < templateIds.size(); docIdx++) {
            Id tid = templateIds[docIdx];
            Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(tid, relatedRecordId);
            String templateType = (String) mergeData.get('templateType');
            if (templateType == 'PowerPoint') {
                throw new AuraHandledException('Guided signing supports Word and HTML templates, not PowerPoint.');
            }
            String body = (String) mergeData.get('combinedDocumentXml');
            if (String.isBlank(body)) {
                body = (String) mergeData.get('documentXml');
            }
            Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
            if (pdfImageMap == null) {
                pdfImageMap = new Map<String, String>();
            }
            combinedPdfImageMap.putAll(pdfImageMap);

            List<PlacementInfo> placements = getTemplateSignaturePlacements(tid);
            if (placements.isEmpty()) {
                placements = buildSyntheticSignaturePlacements(signerInputs);
                body = appendSyntheticSignatureBlock(body, templateType, placements);
            }

            String frozenBody = body;
            List<String> docSentinels = new List<String>();
            for (Integer i = 0; i < placements.size(); i++) {
                String sentinel = '@@SIG-' + (sentinelCounter++) + '@@';
                docSentinels.add(sentinel);
                allSentinels.add(sentinel);
                allPlacementInfos.add(placements[i]);
                placementDocIdx.add(docIdx);
                frozenBody = frozenBody.replaceFirst(Pattern.quote(placements[i].tagText), sentinel);
            }

            Map<String, Object> frozenMerge = new Map<String, Object>(mergeData);
            frozenMerge.put('combinedDocumentXml', frozenBody);
            frozenMerge.put('documentXml', frozenBody);
            frozenMergeOutputs.add(frozenMerge);

            String docViewing;
            if (DocGenService.isHtmlBacked(templateType)) {
                docViewing = frozenBody;
            } else {
                DocGenHtmlRenderer.stylesXml = (String) mergeData.get('stylesXml');
                DocGenHtmlRenderer.numberingXml = (String) mergeData.get('numberingXml');
                DocGenService.applyWatermarkOverride(tid);
                docViewing = DocGenHtmlRenderer.convertToHtml(frozenBody, pdfImageMap);
            }
            for (String sentinel : docSentinels) {
                docViewing = docViewing.replace(sentinel, '<span style="color:#ffffff">' + sentinel + '</span>');
            }
            // Signer form-field tags {?key} → locatable white @@FF-<key>@@ sentinel (per doc).
            docViewing = applyFormFieldViewingSentinels(docViewing);
            String titleHeader =
                '<div style="background:#f8fafc;border:1px solid #e5e5e5;border-radius:6px;padding:12px 16px;margin-bottom:16px;text-align:center;">' +
                '<strong style="font-size:14px;color:#3e3e3c;">Document ' +
                (docIdx + 1) +
                ' of ' +
                templateIds.size() +
                ': ' +
                templateMap.get(tid).Name.escapeHtml4() +
                '</strong></div>';
            if (docIdx > 0) {
                viewingParts.add('<div style="page-break-before:always"></div>');
            }
            viewingParts.add(titleHeader + docViewing);
        }

        Blob viewingBlob = Blob.toPdf(String.join(viewingParts, ''));
        String fileTitle = templateMap.get(templateIds[0]).Name + ' (+' + (templateIds.size() - 1) + ' more)';
        ContentVersion viewCv = new ContentVersion();
        viewCv.Title = fileTitle;
        viewCv.PathOnClient = fileTitle + '.pdf';
        viewCv.VersionData = viewingBlob;
        DocGenFlsGuard.assertCreateable(viewCv, new Set<String>{ 'Title', 'PathOnClient', 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(viewCv, AccessLevel.SYSTEM_MODE);

        String frozenJson = DocGenSignatureService.buildFrozenDocumentJson(frozenMergeOutputs, templateIds);

        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Template__c = templateIds[0];
        req.Template_Ids__c = JSON.serialize(templateIds);
        req.Related_Record_Id__c = relatedRecordId;
        req.Source_Document_Id__c = viewCv.Id;
        req.Status__c = 'Sent';
        req.Signing_Order__c = String.isNotBlank(signingOrder) ? signingOrder : 'Parallel';
        if (String.isNotBlank(documentTitleFormat)) {
            req.Document_Title_Format__c = documentTitleFormat;
        }
        req.Secure_Token__c = generateRequestVerificationToken();
        req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(null);
        Set<String> reqFields = new Set<String>{
            'Template__c',
            'Template_Ids__c',
            'Related_Record_Id__c',
            'Source_Document_Id__c',
            'Status__c',
            'Signing_Order__c',
            'Document_Title_Format__c',
            'Secure_Token__c',
            'Expires_At__c'
        };
        if (String.isNotBlank(frozenJson)) {
            // #156: multi-document packet snapshot persisted to a ContentVersion (no size cap).
            req.Frozen_Document_CV_Id__c = DocGenSignatureService.saveFrozenSnapshotCv(frozenJson);
            req.Snapshot_Hash__c = DocGenSignatureService.hashFrozenDocument(frozenJson);
            req.Snapshot_Taken_At__c = System.now();
            reqFields.addAll(new Set<String>{ 'Frozen_Document_CV_Id__c', 'Snapshot_Hash__c', 'Snapshot_Taken_At__c' });
        }
        DocGenFlsGuard.assertCreateable(req, reqFields);
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(req, AccessLevel.SYSTEM_MODE);

        // Share the standalone viewing CV with the guest signer so the signing-page
        // preview (getSourcePdfBase64) can read it (see shareViewingDocumentWithGuest).
        shareViewingDocumentWithGuest(viewCv.Id, req.Id);

        List<SignerResult> results = createSignersAndNotify(
            req.Id,
            null,
            fileTitle,
            signerInputs,
            true,
            getSigningPdfPagePath()
        );

        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Role_Name__c', 'Signature_Request__c', 'Sort_Order__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signer__c> signerRecs = [
            SELECT Id, Role_Name__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :req.Id
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];
        Map<String, DocGen_Signer__c> roleSignerMap = new Map<String, DocGen_Signer__c>();
        for (DocGen_Signer__c s : signerRecs) {
            if (String.isNotBlank(s.Role_Name__c)) {
                roleSignerMap.put(s.Role_Name__c, s);
            }
        }
        DocGen_Signer__c fallbackSigner = signerRecs.isEmpty() ? null : signerRecs[0];

        List<DocGen_Signature_Placement__c> placementRecords = new List<DocGen_Signature_Placement__c>();
        for (Integer i = 0; i < allPlacementInfos.size(); i++) {
            PlacementInfo p = allPlacementInfos[i];
            DocGen_Signer__c signer = roleSignerMap.containsKey(p.role) ? roleSignerMap.get(p.role) : fallbackSigner;
            if (signer == null) {
                continue;
            }
            placementRecords.add(
                new DocGen_Signature_Placement__c(
                    Signer__c = signer.Id,
                    Signature_Request__c = req.Id,
                    Document_Index__c = placementDocIdx[i],
                    Sequence_Order__c = p.sequence,
                    Placement_Type__c = p.placementType,
                    Render_Inline__c = p.renderInline,
                    Status__c = 'Pending',
                    Tag_Text__c = allSentinels[i]
                )
            );
        }
        if (!placementRecords.isEmpty()) {
            DocGenFlsGuard.assertCreateable(
                placementRecords,
                new Set<String>{
                    'Signer__c',
                    'Signature_Request__c',
                    'Document_Index__c',
                    'Sequence_Order__c',
                    'Placement_Type__c',
                    'Render_Inline__c',
                    'Status__c',
                    'Tag_Text__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(placementRecords, AccessLevel.SYSTEM_MODE);
        }

        return results;
    }

    /**
     * Legacy single-signer request creation (backward compat).
     */
    @AuraEnabled
    public static String createSignatureRequest(
        Id contentDocumentId,
        String relatedRecordId,
        String signerName,
        String signerEmail
    ) {
        List<ContentDocument> docs = [
            SELECT LatestPublishedVersionId
            FROM ContentDocument
            WHERE Id = :contentDocumentId
            WITH USER_MODE
            LIMIT 1
        ];
        if (docs.isEmpty()) {
            throw new AuraHandledException('Document not found or has been deleted.');
        }
        Id contentVersionId = docs[0].LatestPublishedVersionId;

        Blob randomBytes = Crypto.generateAesKey(256);
        Blob hash = Crypto.generateDigest(
            'SHA-256',
            Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + signerEmail)
        );
        String token = EncodingUtil.convertToHex(hash);
        String signingPageUrl = getSiteBaseUrl() + getSigningPagePath() + '?token=' + token;

        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c();
        req.Signer_Name__c = signerName;
        req.Signer_Email__c = signerEmail;
        req.Source_Document_Id__c = contentVersionId;
        req.Related_Record_Id__c = relatedRecordId;
        req.Secure_Token__c = token;
        req.Status__c = 'Sent';
        req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(null);
        // Package-internal object — CRUD controlled by Portwood permission sets
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.assertCreateable(
            req,
            new Set<String>{
                'Signer_Name__c',
                'Signer_Email__c',
                'Source_Document_Id__c',
                'Related_Record_Id__c',
                'Secure_Token__c',
                'Status__c',
                'Expires_At__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(req, AccessLevel.SYSTEM_MODE);

        // Send branded signature request email automatically
        String documentTitle = getDocumentTitle(contentVersionId);
        DocGenSignatureEmailService.sendSignatureRequestEmails(
            new List<DocGenSignatureEmailService.SignerEmail>{
                new DocGenSignatureEmailService.SignerEmail(signerName, signerEmail, null, signingPageUrl, null)
            },
            documentTitle
        );

        return signingPageUrl;
    }

    /**
     * Returns available signer role picklist values.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getSignerRolePicklistValues() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        Schema.DescribeFieldResult fieldResult = DocGen_Signer__c.Role_Name__c.getDescribe();
        for (Schema.PicklistEntry entry : fieldResult.getPicklistValues()) {
            if (entry.isActive()) {
                options.add(new Map<String, String>{ 'label' => entry.getLabel(), 'value' => entry.getValue() });
            }
        }
        return options;
    }

    /**
     * Marks a signer's PIN as verified without requiring email PIN entry.
     * Admin-only — gated by the DocGen_Admin permission set assignment. Intended for
     * in-person signing: the admin has verified the signer's identity face-to-face,
     * so the email PIN step is redundant. Writes a signature audit record capturing
     * who bypassed, when, and the attestation string so compliance has a trail.
     *
     * @param signerId The DocGen_Signer__c record Id to mark verified
     * @return Signing URL (same URL that would arrive via email) ready to use immediately
     */
    @AuraEnabled
    public static String markSignerVerifiedInPerson(Id signerId) {
        // Permission check — only DocGen_Admin users can bypass PIN
        Boolean isAdmin = false;
        for (PermissionSetAssignment psa : [
            SELECT PermissionSet.Name
            FROM PermissionSetAssignment
            WHERE AssigneeId = :UserInfo.getUserId()
            WITH USER_MODE
        ]) {
            if (psa.PermissionSet.Name == 'DocGen_Admin') {
                isAdmin = true;
                break;
            }
        }
        if (!isAdmin) {
            throw new AuraHandledException('Only Portwood Admin users can mark signers as verified in person.');
        }

        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Signature_Request__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Secure_Token__c',
                'Status__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Signature_Request__c, Signer_Name__c, Signer_Email__c, Secure_Token__c, Status__c
            FROM DocGen_Signer__c
            WHERE Id = :signerId
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets
        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }
        DocGen_Signer__c signer = signers[0];
        if (signer.Status__c == 'Signed' || signer.Status__c == 'Cancelled' || signer.Status__c == 'Declined') {
            throw new AuraHandledException('Cannot verify a signer whose status is ' + signer.Status__c + '.');
        }

        signer.PIN_Verified_At__c = System.now();
        signer.Status__c = 'Viewed';
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.assertUpdateable(signer, new Set<String>{ 'PIN_Verified_At__c', 'Status__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(signer, AccessLevel.SYSTEM_MODE);

        // Audit record — capture the bypass for compliance
        try {
            DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c(
                Signature_Request__c = signer.Signature_Request__c,
                Signer__c = signer.Id,
                Signer_Name__c = signer.Signer_Name__c,
                Signer_Email__c = signer.Signer_Email__c,
                PIN_Verified_At__c = System.now(),
                IP_Address__c = 'in-person-bypass:' + UserInfo.getUserId(),
                User_Agent__c = 'PIN bypassed for in-person signing by ' +
                    UserInfo.getName() +
                    ' (' +
                    UserInfo.getUserEmail() +
                    ')',
                Consent_Captured__c = true,
                Verification_Method__c = 'In-Person'
            );
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
            DocGenFlsGuard.assertCreateable(
                audit,
                new Set<String>{
                    'Signature_Request__c',
                    'Signer__c',
                    'Signer_Name__c',
                    'Signer_Email__c',
                    'PIN_Verified_At__c',
                    'IP_Address__c',
                    'User_Agent__c',
                    'Consent_Captured__c',
                    'Verification_Method__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(audit, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            // Audit failure shouldn't block the admin's bypass action — log and continue
            System.debug(LoggingLevel.WARN, 'Portwood: In-person audit write failed: ' + e.getMessage());
        }

        // #170 consolidation: this LWC only creates guided requests, so route the
        // in-person signer to the flat-PDF guided page (not the legacy DOCX/HTML page).
        return getSiteBaseUrl() + getSigningPdfPagePath() + '?token=' + signer.Secure_Token__c;
    }

    /**
     * Returns Contact Name and Email for auto-filling signer fields.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getContactInfo(Id contactId) {
        List<Contact> contacts = [SELECT Name, Email FROM Contact WHERE Id = :contactId WITH USER_MODE LIMIT 1];
        Map<String, String> result = new Map<String, String>();
        if (!contacts.isEmpty()) {
            result.put('name', contacts[0].Name);
            result.put('email', contacts[0].Email != null ? contacts[0].Email : '');
        }
        return result;
    }

    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
    /**
     * Returns existing signature requests for a record, with signer details and URLs.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getPendingSignatureRequests(String relatedRecordId) {
        String siteUrl = getSiteBaseUrl();
        List<Map<String, Object>> results = new List<Map<String, Object>>();

        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Name', 'Status__c', 'Source_Document_Id__c', 'CreatedDate', 'Related_Record_Id__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signature_Request__c> requests = [
            SELECT
                Id,
                Name,
                Status__c,
                Source_Document_Id__c,
                CreatedDate,
                (
                    SELECT Id, Signer_Name__c, Signer_Email__c, Role_Name__c, Status__c, Secure_Token__c, Sort_Order__c
                    FROM Signers__r
                    ORDER BY Sort_Order__c ASC
                )
            FROM DocGen_Signature_Request__c
            WHERE Related_Record_Id__c = :relatedRecordId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];

        // Bulkify: collect all Source_Document_Id__c values and query titles in one SOQL
        Set<Id> sourceDocIds = new Set<Id>();
        for (DocGen_Signature_Request__c req : requests) {
            if (req.Source_Document_Id__c != null) {
                sourceDocIds.add(req.Source_Document_Id__c);
            }
        }
        Map<Id, String> docTitleMap = new Map<Id, String>();
        if (!sourceDocIds.isEmpty()) {
            for (ContentVersion cv : [SELECT Id, Title FROM ContentVersion WHERE Id IN :sourceDocIds WITH USER_MODE]) {
                docTitleMap.put(cv.Id, cv.Title);
            }
        }

        for (DocGen_Signature_Request__c req : requests) {
            Map<String, Object> reqMap = new Map<String, Object>();
            reqMap.put('id', req.Id);
            reqMap.put('name', req.Name);
            reqMap.put('status', req.Status__c);
            reqMap.put('createdDate', req.CreatedDate);

            // Get document title from pre-fetched map
            if (req.Source_Document_Id__c != null) {
                reqMap.put(
                    'documentTitle',
                    docTitleMap.containsKey(req.Source_Document_Id__c)
                        ? docTitleMap.get(req.Source_Document_Id__c)
                        : 'Unknown'
                );
            }

            List<Map<String, Object>> signerList = new List<Map<String, Object>>();
            for (DocGen_Signer__c signer : req.Signers__r) {
                Map<String, Object> signerMap = new Map<String, Object>();
                // 3.42 — carry the signer record Id + eligibility so the "Sign In
                // Person" (PIN bypass) action works for historical requests and
                // after a page refresh, not just the freshly-created result list.
                // markSignerVerifiedInPerson stays DocGen_Admin-gated + audited.
                signerMap.put('signerId', signer.Id);
                signerMap.put(
                    'canVerifyInPerson',
                    signer.Status__c != 'Signed' && signer.Status__c != 'Cancelled' && signer.Status__c != 'Declined'
                );
                signerMap.put('signerName', signer.Signer_Name__c);
                signerMap.put('signerEmail', signer.Signer_Email__c);
                signerMap.put('roleName', signer.Role_Name__c);
                signerMap.put('status', signer.Status__c);
                // #170 consolidation: requests from this LWC are guided — surface the
                // flat-PDF guided page in the "previous requests" copy-links, matching
                // the freshly-created results above (getSigningPdfPagePath at creation).
                signerMap.put('signerUrl', siteUrl + getSigningPdfPagePath() + '?token=' + signer.Secure_Token__c);
                signerList.add(signerMap);
            }
            reqMap.put('signers', signerList);
            results.add(reqMap);
        }

        return results;
    }

    /**
     * Scans a DOCX for {@Signature_XXX} placeholders and returns the role names.
     // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
     * Used by the LWC to auto-populate signer rows when a document is selected.
     */
    @AuraEnabled
    public static List<String> getDocumentSignatureRoles(Id contentDocumentId) {
        List<ContentDocument> docs = [
            SELECT LatestPublishedVersionId
            FROM ContentDocument
            WHERE Id = :contentDocumentId
            WITH USER_MODE
            LIMIT 1
        ];
        if (docs.isEmpty())
            return new List<String>();

        ContentVersion cv = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :docs[0].LatestPublishedVersionId
            WITH USER_MODE
            LIMIT 1
        ];
        if (cv == null || cv.VersionData == null)
            return new List<String>();

        // Extract document.xml from the DOCX ZIP
        Compression.ZipReader reader = new Compression.ZipReader(cv.VersionData);
        String documentXml = null;
        for (Compression.ZipEntry entry : reader.getEntries()) {
            if (entry.getName() == 'word/document.xml') {
                documentXml = reader.extract(entry.getName()).toString();
                break;
            }
        }
        if (documentXml == null)
            return new List<String>();

        // Extract all text from <w:t> elements (handles tags split across runs)
        String plainText = '';
        Pattern wtPat = Pattern.compile('<w:t[^>]*>([^<]*)</w:t>');
        Matcher wtMatch = wtPat.matcher(documentXml);
        while (wtMatch.find()) {
            plainText += wtMatch.group(1);
        }

        // Find {@Signature_RoleName} placeholders
        List<String> roles = new List<String>();
        Pattern sigPat = Pattern.compile('\\{@Signature_([^}]+)\\}');
        Matcher sigMatch = sigPat.matcher(plainText);
        while (sigMatch.find()) {
            String roleName = sigMatch.group(1).replaceAll('_', ' ');
            if (!roles.contains(roleName)) {
                roles.add(roleName);
            }
        }

        // Check for generic {@Signature} (single signer, no named role)
        if (roles.isEmpty() && plainText.contains('{@Signature}')) {
            roles.add('Signer');
        }

        return roles;
    }

    /**
     * Shared logic: creates DocGen_Signer__c records and sends notification emails.
     * Used by both createMultiSignerRequest (DOCX) and createTemplateSignerRequest (template).
     */
    /**
     * Creates DocGen_Signature_Placement__c records for each signer based on template tags.
     * Maps v3 tags ({@Signature_Role:Order:Type}) to signer records by role name.
     */
    private static void createPlacementsForSigners(
        Id requestId,
        Id templateId,
        List<DocGen_Signer__c> signerRecords,
        List<Map<String, Object>> signerInputs
    ) {
        List<PlacementInfo> placements = getTemplateSignaturePlacements(templateId);
        if (placements.isEmpty())
            return;

        // Build role → signer record map
        Map<String, DocGen_Signer__c> roleSignerMap = new Map<String, DocGen_Signer__c>();
        for (Integer i = 0; i < signerRecords.size(); i++) {
            String roleName = (String) signerInputs[i].get('roleName');
            if (String.isNotBlank(roleName)) {
                roleSignerMap.put(roleName, signerRecords[i]);
            }
        }

        List<DocGen_Signature_Placement__c> placementRecords = new List<DocGen_Signature_Placement__c>();
        for (PlacementInfo p : placements) {
            DocGen_Signer__c signer = roleSignerMap.get(p.role);
            if (signer == null)
                continue; // No signer assigned for this role

            DocGen_Signature_Placement__c plc = new DocGen_Signature_Placement__c();
            plc.Signer__c = signer.Id;
            plc.Signature_Request__c = requestId;
            plc.Document_Index__c = 0;
            plc.Sequence_Order__c = p.sequence;
            plc.Placement_Type__c = p.placementType;
            plc.Render_Inline__c = p.renderInline;
            plc.Status__c = 'Pending';
            plc.Tag_Text__c = p.tagText;
            placementRecords.add(plc);
        }

        if (!placementRecords.isEmpty()) {
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
            DocGenFlsGuard.assertCreateable(
                placementRecords,
                new Set<String>{
                    'Signer__c',
                    'Signature_Request__c',
                    'Document_Index__c',
                    'Sequence_Order__c',
                    'Placement_Type__c',
                    'Render_Inline__c',
                    'Status__c',
                    'Tag_Text__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(placementRecords, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * Shares a standalone viewing ContentVersion with the guest signer.
     *
     * The guided/snapshot send paths insert the viewing PDF as a standalone
     * ContentVersion (no FirstPublishLocationId, no ContentDocumentLink), so it
     * lands in the sending user's private library. A guest signer therefore has
     * no access route to it, and the signing page's SYSTEM_MODE read in
     * DocGenSignatureController.getSourcePdfBase64 returns 0 rows → the catch
     * surfaces "Document not found" and the preview goes blank (signing itself
     * still works because it never reads this CV).
     *
     * Linking the document to the DocGen_Signature_Request__c record with
     * Visibility='AllUsers' makes it guest-readable — the same mechanism
     * saveSignedDocument uses for the completed document — while keeping the
     * unsigned preview OFF the customer's business record (only the final signed
     * + certificate PDF lands there at completion). Best-effort: a failure here
     * must not block the send (the signer can still proceed without the preview).
     */
    private static void shareViewingDocumentWithGuest(Id viewCvId, Id linkedEntityId) {
        if (viewCvId == null || linkedEntityId == null) {
            return;
        }
        try {
            DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'ContentDocumentId' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Id contentDocId = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE Id = :viewCvId
                WITH SYSTEM_MODE
                LIMIT 1
            ]
            .ContentDocumentId;

            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = contentDocId;
            cdl.LinkedEntityId = linkedEntityId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            DocGenFlsGuard.assertCreateable(
                cdl,
                new Set<String>{ 'ContentDocumentId', 'LinkedEntityId', 'ShareType', 'Visibility' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(cdl, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                'Portwood: failed to share viewing document with guest signer: ' + e.getMessage()
            );
        }
    }

    private static List<SignerResult> createSignersAndNotify(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs
    ) {
        return createSignersAndNotify(requestId, templateId, documentTitle, signerInputs, true);
    }

    private static List<SignerResult> createSignersAndNotify(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs,
        Boolean sendEmails
    ) {
        // Default to the legacy DOCX/HTML signing page. The flat-PDF path
        // (createRequestFromContentVersion) calls the pagePath overload below.
        return createSignersAndNotify(
            requestId,
            templateId,
            documentTitle,
            signerInputs,
            sendEmails,
            getSigningPagePath()
        );
    }

    /**
     * #verification — resolves the email-verification + email-prefill config for a request
     * (per-send override → template default → org default → hard default of required/no-prefill)
     * and stamps the resolved values on the request. Runs in sender (internal) context.
     */
    private static void applyVerificationConfig(
        Id requestId,
        Id templateId,
        Boolean perSendRequire,
        Boolean perSendPrefill
    ) {
        if (requestId == null) {
            return;
        }
        // The guided/snapshot paths call createSignersAndNotify with templateId=null
        // (placements are created separately), so fall back to the request's Template__c
        // for the template-level cascade read.
        Id effectiveTemplateId = templateId;
        if (effectiveTemplateId == null && (perSendRequire == null || perSendPrefill == null)) {
            try {
                DocGenFlsGuard.assertAccessible(
                    DocGen_Signature_Request__c.sObjectType,
                    new Set<String>{ 'Template__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<DocGen_Signature_Request__c> rs = [
                    SELECT Template__c
                    FROM DocGen_Signature_Request__c
                    WHERE Id = :requestId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ]; // NOPMD
                if (!rs.isEmpty()) {
                    effectiveTemplateId = rs[0].Template__c;
                }
            } catch (Exception e) {
                // Fall through to org default.
            }
        }
        String tmplVerif = null;
        String tmplPrefill = null;
        if ((perSendRequire == null || perSendPrefill == null) && effectiveTemplateId != null) {
            try {
                DocGenFlsGuard.assertAccessible(
                    DocGen_Template__c.sObjectType,
                    new Set<String>{ 'Signer_Verification__c', 'Prefill_Signer_Email__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<DocGen_Template__c> tpls = [
                    SELECT Signer_Verification__c, Prefill_Signer_Email__c
                    FROM DocGen_Template__c
                    WHERE Id = :effectiveTemplateId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ]; // NOPMD
                if (!tpls.isEmpty()) {
                    tmplVerif = tpls[0].Signer_Verification__c;
                    tmplPrefill = tpls[0].Prefill_Signer_Email__c;
                }
            } catch (Exception e) {
                // Fall through to org default.
            }
        }
        DocGen_Settings__c s = DocGen_Settings__c.getOrgDefaults();

        Boolean require;
        if (perSendRequire != null) {
            require = perSendRequire;
        } else if (tmplVerif == 'Required') {
            require = true;
        } else if (tmplVerif == 'Off') {
            require = false;
        } else {
            // Inverted "skip" semantics: required unless the org EXPLICITLY set skip=true.
            // A checkbox can't represent "unset", so the safe default (required) is the
            // field's natural false state — upgrade-safe for orgs with an existing settings row.
            require = !(s != null && s.Signature_Skip_Email_Verification__c == true);
        }

        Boolean prefill;
        if (perSendPrefill != null) {
            prefill = perSendPrefill;
        } else if (tmplPrefill == 'Yes') {
            prefill = true;
        } else if (tmplPrefill == 'No') {
            prefill = false;
        } else {
            prefill = (s == null || s.Id == null) ? false : s.Signature_Prefill_Signer_Email__c;
        }

        DocGen_Signature_Request__c upd = new DocGen_Signature_Request__c(
            Id = requestId,
            Require_Email_Verification__c = require,
            Prefill_Signer_Email__c = prefill
        );
        DocGenFlsGuard.assertUpdateable(
            upd,
            new Set<String>{ 'Require_Email_Verification__c', 'Prefill_Signer_Email__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(upd, AccessLevel.SYSTEM_MODE);
    }

    private static List<SignerResult> createSignersAndNotify(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs,
        Boolean sendEmails,
        String pagePath
    ) {
        return createSignersAndNotify(
            requestId,
            templateId,
            documentTitle,
            signerInputs,
            sendEmails,
            pagePath,
            null,
            null,
            null,
            null
        );
    }

    // 7-arg overload (message only) — #193.
    private static List<SignerResult> createSignersAndNotify(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs,
        Boolean sendEmails,
        String pagePath,
        String messageOverride
    ) {
        return createSignersAndNotify(
            requestId,
            templateId,
            documentTitle,
            signerInputs,
            sendEmails,
            pagePath,
            messageOverride,
            null,
            null,
            null
        );
    }

    /**
     * @param messageOverride optional send-time custom message (#193). Replaces the
     *        {Message} token in the request email for this send only; null = template default.
     * @param subjectOverride optional send-time custom subject (#193); null = template default.
     */
    private static List<SignerResult> createSignersAndNotify(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs,
        Boolean sendEmails,
        String pagePath,
        String messageOverride,
        String subjectOverride
    ) {
        return createSignersAndNotify(
            requestId,
            templateId,
            documentTitle,
            signerInputs,
            sendEmails,
            pagePath,
            messageOverride,
            subjectOverride,
            null,
            null
        );
    }

    /**
     * Canonical send entry — #193 message/subject overrides + #verification per-send config.
     * @param messageOverride optional send-time custom message (#193); null = template default.
     * @param subjectOverride optional send-time custom subject (#193); null = template default.
     * @param perSendRequire optional per-send override for email verification (#verification);
     *        null = inherit from template/org. perSendPrefill likewise for email pre-fill.
     */
    private static List<SignerResult> createSignersAndNotify(
        Id requestId,
        Id templateId,
        String documentTitle,
        List<Map<String, Object>> signerInputs,
        Boolean sendEmails,
        String pagePath,
        String messageOverride,
        String subjectOverride,
        Boolean perSendRequire,
        Boolean perSendPrefill
    ) {
        // #verification — resolve email-verification config (per-send → template → org default)
        // and stamp it on the request so the signing page + saveSignature/signPlacement gates
        // read a single point-in-time record. Field defaults keep the request "required" if this
        // is never reached.
        applyVerificationConfig(requestId, templateId, perSendRequire, perSendPrefill);

        String siteUrl = getSiteBaseUrl();
        List<DocGen_Signer__c> signerRecords = new List<DocGen_Signer__c>();
        List<SignerResult> results = new List<SignerResult>();

        for (Integer i = 0; i < signerInputs.size(); i++) {
            Map<String, Object> input = signerInputs[i];
            String signerName = (String) input.get('signerName');
            String signerEmail = (String) input.get('signerEmail');
            String roleName = (String) input.get('roleName');
            String contactId = (String) input.get('contactId');

            Blob randomBytes = Crypto.generateAesKey(256);
            Blob hash = Crypto.generateDigest(
                'SHA-256',
                Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + signerEmail + i)
            );
            String token = EncodingUtil.convertToHex(hash);

            DocGen_Signer__c signer = new DocGen_Signer__c();
            signer.Signature_Request__c = requestId;
            signer.Role_Name__c = roleName;
            signer.Signer_Name__c = signerName;
            signer.Signer_Email__c = signerEmail;
            signer.Secure_Token__c = token;
            signer.Status__c = 'Pending';
            signer.Sort_Order__c = i + 1;
            if (String.isNotBlank(contactId)) {
                signer.Contact__c = contactId;
            }
            signerRecords.add(signer);

            SignerResult sr = new SignerResult();
            sr.signerName = signerName;
            sr.roleName = roleName;
            sr.signerEmail = signerEmail;
            sr.signerUrl = siteUrl + pagePath + '?token=' + token;
            results.add(sr);
        }

        // Package-internal object — CRUD controlled by Portwood permission sets
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.assertCreateable(
            signerRecords,
            new Set<String>{
                'Signature_Request__c',
                'Role_Name__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Secure_Token__c',
                'Status__c',
                'Sort_Order__c',
                'Contact__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(signerRecords, AccessLevel.SYSTEM_MODE);

        // 1.49 — back-fill signer record Ids onto the SignerResult DTOs so the LWC
        // can use the "Mark Verified (In-Person)" action without a second SOQL.
        for (Integer i = 0; i < signerRecords.size() && i < results.size(); i++) {
            results[i].signerId = signerRecords[i].Id;
        }

        // Create signature placements from template tags (v3 tag support)
        if (templateId != null) {
            createPlacementsForSigners(requestId, templateId, signerRecords, signerInputs);
        }

        // Send branded signature request emails (unless caller opts out, e.g. Flow sending its own emails)
        if (sendEmails) {
            // Check signing order — Sequential sends only to first signer
            Boolean isSequential = false;
            try {
                DocGenFlsGuard.assertAccessible(
                    DocGen_Signature_Request__c.sObjectType,
                    new Set<String>{ 'Signing_Order__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                DocGen_Signature_Request__c reqCheck = [
                    SELECT Signing_Order__c
                    FROM DocGen_Signature_Request__c
                    WHERE Id = :requestId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ]; // NOPMD
                isSequential = reqCheck.Signing_Order__c == 'Sequential';
            } catch (Exception e) {
                // Default to parallel
            }

            List<DocGenSignatureEmailService.SignerEmail> emailList = new List<DocGenSignatureEmailService.SignerEmail>();
            for (Integer i = 0; i < results.size(); i++) {
                // Sequential: only send to first signer (Sort_Order 1)
                if (isSequential && i > 0)
                    break;

                SignerResult sr = results[i];
                Id cId = null;
                for (Map<String, Object> input : signerInputs) {
                    if (
                        sr.signerEmail == (String) input.get('signerEmail') &&
                        String.isNotBlank((String) input.get('contactId'))
                    ) {
                        cId = (Id) input.get('contactId');
                        break;
                    }
                }
                emailList.add(
                    new DocGenSignatureEmailService.SignerEmail(
                        sr.signerName,
                        sr.signerEmail,
                        sr.roleName,
                        sr.signerUrl,
                        cId
                    )
                );
            }
            DocGenSignatureEmailService.sendSignatureRequestEmails(
                emailList,
                documentTitle,
                requestId,
                messageOverride,
                subjectOverride
            );
        }

        return results;
    }

    /**
     * Resends signature request emails to all pending/viewed signers on a request.
     * Generates new tokens for security (old links become invalid).
     */
    @AuraEnabled
    public static void resendSignatureRequest(Id requestId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Status__c', 'Template__c', 'Source_Document_Id__c', 'Render_Data_Snapshot__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        DocGen_Signature_Request__c req = [
            SELECT Id, Status__c, Template__r.Name, Source_Document_Id__c, Render_Data_Snapshot__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (req.Status__c == 'Signed' || req.Status__c == 'Cancelled') {
            throw new AuraHandledException('Cannot resend a ' + req.Status__c.toLowerCase() + ' request.');
        }

        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Signer_Name__c',
                'Signer_Email__c',
                'Role_Name__c',
                'Contact__c',
                'Status__c',
                'Signature_Request__c',
                'Sort_Order__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Signer_Name__c, Signer_Email__c, Role_Name__c, Contact__c, Status__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId AND Status__c != 'Signed'
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];

        if (signers.isEmpty()) {
            throw new AuraHandledException('All signers have already signed.');
        }

        String siteUrl = getSiteBaseUrl();
        String documentTitle = req.Template__r != null ? req.Template__r.Name : 'Document';
        if (String.isBlank(documentTitle) && req.Source_Document_Id__c != null) {
            documentTitle = getDocumentTitle(req.Source_Document_Id__c);
        }

        List<DocGenSignatureEmailService.SignerEmail> emailList = new List<DocGenSignatureEmailService.SignerEmail>();

        String signingPath = resolveSigningPath(req);

        for (DocGen_Signer__c s : signers) {
            // Generate new token
            Blob randomBytes = Crypto.generateAesKey(256);
            Blob hash = Crypto.generateDigest(
                'SHA-256',
                Blob.valueOf(EncodingUtil.convertToHex(randomBytes) + s.Signer_Email__c + System.now())
            );
            String newToken = EncodingUtil.convertToHex(hash);
            s.Secure_Token__c = newToken;
            s.Status__c = 'Pending';
            s.PIN_Hash__c = null;
            s.PIN_Expires_At__c = null;
            s.PIN_Attempts__c = 0;
            s.PIN_Verified_At__c = null;

            String sigUrl = siteUrl + signingPath + '?token=' + newToken;
            emailList.add(
                new DocGenSignatureEmailService.SignerEmail(
                    s.Signer_Name__c,
                    s.Signer_Email__c,
                    s.Role_Name__c,
                    sigUrl,
                    s.Contact__c
                )
            );
        }

        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.assertUpdateable(
            signers,
            new Set<String>{
                'Secure_Token__c',
                'Status__c',
                'PIN_Hash__c',
                'PIN_Expires_At__c',
                'PIN_Attempts__c',
                'PIN_Verified_At__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(signers, false, AccessLevel.SYSTEM_MODE);
        req.Status__c = 'Sent';
        // Resend opens a fresh signing window (org default) alongside the new tokens.
        req.Expires_At__c = DocGenSignatureExpiry.computeExpiry(null);
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.assertUpdateable(req, new Set<String>{ 'Status__c', 'Expires_At__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(req, false, AccessLevel.SYSTEM_MODE);

        // requestId so {ExpirationHours} reflects the fresh signing window.
        DocGenSignatureEmailService.sendSignatureRequestEmails(emailList, documentTitle, req.Id);
    }

    /**
     * PDF-viewer requests (snapshot re-render or send-existing-CV) set
     * Render_Data_Snapshot__c or Source_Document_Id__c; the classic typed-name
     * flow sets neither. Same predicate as the sequential-signer routing in
     * DocGenSignaturePdfTrigger — resend and reminders with the legacy page path
     * would email guided-PDF signers a broken link.
     */
    public static String resolveSigningPath(DocGen_Signature_Request__c req) {
        Boolean isPdfViewer = req.Render_Data_Snapshot__c != null || req.Source_Document_Id__c != null;
        return isPdfViewer ? getSigningPdfPagePath() : getSigningPagePath();
    }

    /**
     * Cancels a signature request. All pending signers are marked cancelled.
     * Already-signed signers are preserved in the audit trail.
     */
    @AuraEnabled
    public static void cancelSignatureRequest(Id requestId) {
        DocGenFlsGuard.assertAccessible(DocGen_Signature_Request__c.sObjectType, new Set<String>{ 'Status__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        DocGen_Signature_Request__c req = [
            SELECT Id, Status__c, Frozen_Document_CV_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (req.Status__c == 'Signed') {
            throw new AuraHandledException('Cannot cancel a completed signature request.');
        }
        if (req.Status__c == 'Cancelled') {
            throw new AuraHandledException('This request is already cancelled.');
        }

        // #156: a cancelled request will never be signed, so reclaim the frozen-snapshot CV.
        Id frozenCvToPurge = (Id) req.Frozen_Document_CV_Id__c;
        req.Status__c = 'Cancelled';
        req.Frozen_Document_CV_Id__c = null;
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.assertUpdateable(req, new Set<String>{ 'Status__c', 'Frozen_Document_CV_Id__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(req, false, AccessLevel.SYSTEM_MODE);
        DocGenSignatureService.purgeFrozenSnapshotCv(frozenCvToPurge);

        // Invalidate all unsigned signers
        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Status__c', 'Signature_Request__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signer__c> unsignedSigners = [
            SELECT Id, Status__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId AND Status__c != 'Signed'
            WITH SYSTEM_MODE
        ];
        for (DocGen_Signer__c s : unsignedSigners) {
            s.Status__c = 'Cancelled';
            s.Secure_Token__c = null; // Invalidate token
        }
        if (!unsignedSigners.isEmpty()) {
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            DocGenFlsGuard.assertUpdateable(unsignedSigners, new Set<String>{ 'Status__c', 'Secure_Token__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(unsignedSigners, false, AccessLevel.SYSTEM_MODE);
        }
    }

    private static String getDocumentTitle(Id contentVersionId) {
        List<ContentVersion> cvs = [
            SELECT Title
            FROM ContentVersion
            WHERE Id = :contentVersionId
            WITH USER_MODE
            LIMIT 1
        ];
        return !cvs.isEmpty() ? cvs[0].Title : 'Document';
    }

    /**
     * Generates a preview of the merged document HTML for the sender to review before sending.
     * Merges the template with record data, converts to HTML, and injects placement spans.
     * Does NOT create a signature request — purely a read-only preview.
     */
    @AuraEnabled
    public static String getDocumentPreviewHtml(Id templateId, String relatedRecordId) {
        try {
            Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, relatedRecordId);
            Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
            String html = renderMergedSignatureHtml(mergeData, templateId, pdfImageMap);
            html = injectPlacementSpans(html);
            return injectPreviewWatermarkOverlay(html, templateId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: Preview generation failed: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Generates a paginated PDF preview for the sender modal. Unlike the HTML preview,
     * this uses Blob.toPdf(), so Word headers/footers, @page margin boxes, counters,
     * and page breaks are evaluated by the same renderer used for the final signed PDF.
     */
    @AuraEnabled
    public static String getDocumentPreviewPdfBase64(Id templateId, String relatedRecordId) {
        try {
            Blob pdfBlob = buildDocumentPreviewPdfBlob(templateId, relatedRecordId);
            return pdfBlob == null ? null : EncodingUtil.base64Encode(pdfBlob);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: PDF preview generation failed: ' + e.getMessage());
            throw new AuraHandledException('PDF preview generation failed: ' + e.getMessage());
        }
    }

    private static Blob buildDocumentPreviewPdfBlob(Id templateId, String relatedRecordId) {
        Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, relatedRecordId);
        Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
        String html = renderMergedSignatureHtml(mergeData, templateId, pdfImageMap);
        if (String.isBlank(html)) {
            return null;
        }
        html = injectPlacementSpans(html);

        return Test.isRunningTest() ? Blob.valueOf('test-preview-pdf') : Blob.toPdf(html);
    }

    @TestVisible
    private static String renderMergedSignatureHtml(
        Map<String, Object> mergeData,
        Id templateId,
        Map<String, String> imageMap
    ) {
        if (mergeData == null) {
            return null;
        }
        String docXml = (String) mergeData.get('combinedDocumentXml');
        if (String.isBlank(docXml)) {
            docXml = (String) mergeData.get('documentXml');
        }
        if (String.isBlank(docXml)) {
            return null;
        }

        if (DocGenService.isHtmlBacked((String) mergeData.get('templateType'))) {
            return rewriteHtmlImageSources(docXml, imageMap);
        }

        DocGenService.applyWatermarkOverride(templateId);
        return DocGenHtmlRenderer.convertToHtml(docXml, imageMap);
    }

    @TestVisible
    private static Map<String, String> buildSignaturePreviewImageMap(Map<String, String> pdfImageMap, String html) {
        Map<String, String> previewImageMap = new Map<String, String>();
        if (pdfImageMap != null) {
            for (String relId : pdfImageMap.keySet()) {
                addSignaturePreviewImage(previewImageMap, relId, pdfImageMap.get(relId));
            }
        }
        for (String src : extractHtmlImageSources(html)) {
            addSignaturePreviewImage(previewImageMap, src, src);
        }
        return previewImageMap;
    }

    private static void addSignaturePreviewImage(Map<String, String> previewImageMap, String key, String sourceUrl) {
        String cvId = extractContentVersionIdFromImageUrl(sourceUrl);
        if (String.isBlank(cvId)) {
            return;
        }
        if (previewImageMap.containsKey(cvId)) {
            if (String.isNotBlank(key)) {
                previewImageMap.put(key, previewImageMap.get(cvId));
            }
            previewImageMap.put('/sfc/servlet.shepherd/version/download/' + cvId, previewImageMap.get(cvId));
            return;
        }
        // Content Deliveries disabled (issue #384): preview images stay on their
        // relative /sfc/servlet.shepherd URLs.
        if (!DocGenContentDelivery.isAvailable()) {
            return;
        }
        try {
            SObject dist = DocGenContentDelivery.newDistribution(
                new Map<String, Object>{
                    'Name' => 'sig_preview_' + (String.isBlank(key) ? cvId : key).left(80),
                    'ContentVersionId' => (Id) cvId,
                    'PreferencesAllowViewInBrowser' => true,
                    'PreferencesLinkLatestVersion' => false,
                    'PreferencesExpires' => false
                }
            );
            Database.insert(dist, AccessLevel.USER_MODE);
            SObject reloaded = DocGenContentDelivery.reload((Id) dist.get('Id'));
            String downloadUrl = reloaded == null ? null : (String) reloaded.get('ContentDownloadUrl');
            if (String.isNotBlank(key)) {
                previewImageMap.put(key, downloadUrl);
            }
            previewImageMap.put(cvId, downloadUrl);
            previewImageMap.put('/sfc/servlet.shepherd/version/download/' + cvId, downloadUrl);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                'Portwood: Could not create public signature preview image link for ' + cvId + ': ' + e.getMessage()
            );
        }
    }

    @TestVisible
    private static String rewriteHtmlImageSources(String html, Map<String, String> imageMap) {
        if (String.isBlank(html) || imageMap == null || imageMap.isEmpty()) {
            return html;
        }

        String rewritten = html;
        for (String src : extractHtmlImageSources(html)) {
            String replacement = imageMap.get(src);
            if (String.isBlank(replacement)) {
                replacement = imageMap.get(extractContentVersionIdFromImageUrl(src));
            }
            if (String.isBlank(replacement)) {
                continue;
            }
            rewritten = rewritten.replace('"' + src + '"', '"' + replacement.escapeHtml4() + '"');
            rewritten = rewritten.replace('\'' + src + '\'', '\'' + replacement.escapeHtml4() + '\'');
        }
        return rewritten;
    }

    private static List<String> extractHtmlImageSources(String html) {
        List<String> sources = new List<String>();
        if (String.isBlank(html) || !html.containsIgnoreCase('<img')) {
            return sources;
        }
        String lower = html.toLowerCase();
        Integer cursor = 0;
        while (cursor < html.length()) {
            Integer imgStart = lower.indexOf('<img', cursor);
            if (imgStart == -1) {
                break;
            }
            Integer imgEnd = html.indexOf('>', imgStart);
            if (imgEnd == -1) {
                break;
            }
            Integer srcIdx = lower.indexOf('src=', imgStart);
            if (srcIdx == -1 || srcIdx > imgEnd) {
                cursor = imgEnd + 1;
                continue;
            }
            srcIdx += 4;
            while (srcIdx < imgEnd && html.substring(srcIdx, srcIdx + 1) == ' ') {
                srcIdx++;
            }
            if (srcIdx >= imgEnd) {
                cursor = imgEnd + 1;
                continue;
            }
            String quoteChar = html.substring(srcIdx, srcIdx + 1);
            if (quoteChar != '"' && quoteChar != '\'') {
                cursor = imgEnd + 1;
                continue;
            }
            Integer valueStart = srcIdx + 1;
            Integer valueEnd = html.indexOf(quoteChar, valueStart);
            if (valueEnd != -1 && valueEnd <= imgEnd) {
                String src = html.substring(valueStart, valueEnd);
                if (String.isNotBlank(src)) {
                    sources.add(src.replace('&amp;', '&'));
                }
            }
            cursor = imgEnd + 1;
        }
        return sources;
    }

    private static String extractContentVersionIdFromImageUrl(String url) {
        if (String.isBlank(url) || !url.contains('/version/download/')) {
            return null;
        }
        String cvId = url.substringAfterLast('/version/download/');
        cvId = cvId.substringBefore('?').substringBefore('#');
        return cvId.startsWith('068') ? cvId : null;
    }

    public static String getSigningPagePath() {
        // In managed packages, VF pages need the namespace prefix in subscriber orgs
        String ns = DocGenSignatureSenderController.class.getName().substringBefore('.');
        if (String.isNotBlank(ns) && ns != 'DocGenSignatureSenderController') {
            return '/apex/' + ns + '__DocGenSignature';
        }
        return '/apex/DocGenSignature';
    }

    /**
     * Milestone 1 — path to the new flat-PDF signing page (DocGenSignaturePdf.page).
     * Same namespace-prefix rule as getSigningPagePath; used only by the
     * "send existing ContentVersion" path (createRequestFromContentVersion).
     */
    public static String getSigningPdfPagePath() {
        String ns = DocGenSignatureSenderController.class.getName().substringBefore('.');
        if (String.isNotBlank(ns) && ns != 'DocGenSignatureSenderController') {
            return '/apex/' + ns + '__DocGenSignaturePdf';
        }
        return '/apex/DocGenSignaturePdf';
    }

    public static String getSiteBaseUrl() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String siteUrl = settings.Experience_Site_Url__c;

        if (String.isBlank(siteUrl)) {
            List<Site> sites = [SELECT Id FROM Site WHERE Status = 'Active' WITH USER_MODE LIMIT 1];
            if (!sites.isEmpty()) {
                SiteDetail sd = [
                    SELECT SecureUrl
                    FROM SiteDetail
                    WHERE DurableId = :sites[0].Id
                    WITH USER_MODE
                    LIMIT 1
                ];
                siteUrl = sd.SecureUrl;
            }
        }

        if (String.isBlank(siteUrl)) {
            siteUrl = 'https://<CONFIGURE_SITE_URL_IN_SETUP>';
        }

        if (siteUrl.endsWith('/')) {
            siteUrl = siteUrl.substring(0, siteUrl.length() - 1);
        }

        return siteUrl;
    }
}
