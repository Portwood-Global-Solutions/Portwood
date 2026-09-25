// CxSAST: without sharing required for guest user signing context; access gated by cryptographic token
public without sharing class DocGenSignatureService {
    public class SignatureException extends Exception {
    }

    /**
     * Data wrapper for multi-signer typed name stamping.
     */
    public class SignerData {
        public String roleName;
        public String typedName;
        public Datetime signedDate;
        public SignerData(String roleName, String typedName) {
            this.roleName = roleName;
            this.typedName = typedName;
            this.signedDate = System.now();
        }
        public SignerData(String roleName, String typedName, Datetime signedDate) {
            this.roleName = roleName;
            this.typedName = typedName;
            this.signedDate = signedDate;
        }
    }

    /**
     * Data wrapper for template-based signature stamping (typed name, no images).
     */
    public class SignerImageData {
        public String roleName;
        public Id contentVersionId;
        public String typedName;
        public Datetime signedDate;
        public SignerImageData(String roleName, Id contentVersionId) {
            this.roleName = roleName;
            this.contentVersionId = contentVersionId;
        }
        public SignerImageData(String roleName, String typedName, Datetime signedDate) {
            this.roleName = roleName;
            this.typedName = typedName;
            this.signedDate = signedDate;
        }
    }

    /**
     * Result of stamping signatures into XML strings.
     */
    public class StampResult {
        public String documentXml;
        public String relsXml;
        public String contentTypesXml;
        public Map<String, String> signatureImageUrls;
        public StampResult(
            String documentXml,
            String relsXml,
            String contentTypesXml,
            Map<String, String> signatureImageUrls
        ) {
            this.documentXml = documentXml;
            this.relsXml = relsXml;
            this.contentTypesXml = contentTypesXml;
            this.signatureImageUrls = signatureImageUrls;
        }
    }

    /**
     * Inserts the verification block immediately before the LAST </body> tag in
     * an HTML document. Critical for packet PDFs — renderPacketSignaturePdf
     * concatenates one full <html>...</html> per template, so the document has
     * a </body> per template. Using String.replace would inject the block after
     * EVERY template (the v1.77 packet bug Dustin reported). If no </body> is
     * found, appends to the end as a safe fallback.
     */
    @TestVisible
    private static String injectVerifyBlockBeforeLastBody(String fullHtml, String verifyBlock) {
        if (String.isBlank(fullHtml)) {
            return verifyBlock == null ? '' : verifyBlock;
        }
        if (String.isBlank(verifyBlock)) {
            return fullHtml;
        }
        Integer lastBodyIdx = fullHtml.lastIndexOf('</body>');
        if (lastBodyIdx >= 0) {
            return fullHtml.substring(0, lastBodyIdx) + verifyBlock + fullHtml.substring(lastBodyIdx);
        }
        return fullHtml + verifyBlock;
    }

    /**
     * Issue #407 output-integrity guard. The server-rendered PDF source must not
     * reach Blob.toPdf while it still contains an unresolved placement sentinel.
     */
    @TestVisible
    private static void assertNoUnresolvedSignatureSentinels(String outputHtml) {
        if (String.isNotBlank(outputHtml) && Pattern.compile('@@SIG-\\d+@@').matcher(outputHtml).find()) {
            throw new SignatureException('Signed document still contains an unresolved signature field.');
        }
    }

    /**
     * Defense in depth for asynchronous finalization. Controller endpoints
     * validate the completing signer, but the queueable must also reject a
     * request whose persisted placement state is inconsistent.
     */
    @TestVisible
    private static void assertRequestPlacementsComplete(Id requestId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Placement__c.sObjectType,
            new Set<String>{ 'Signature_Request__c', 'Status__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Integer unsignedCount = [
            SELECT COUNT()
            FROM DocGen_Signature_Placement__c
            WHERE Signature_Request__c = :requestId AND Status__c != 'Signed'
            WITH SYSTEM_MODE
        ];
        if (unsignedCount > 0) {
            throw new SignatureException('Signature request contains unsigned required placements.');
        }
    }

    private static void requireDmlSuccess(Database.SaveResult saveResult, String operation, Id recordId) {
        if (saveResult != null && saveResult.isSuccess()) {
            return;
        }
        List<String> details = new List<String>();
        if (saveResult != null) {
            for (Database.Error err : saveResult.getErrors()) {
                details.add(String.valueOf(err.getStatusCode()) + ': ' + err.getMessage());
            }
        }
        String detail = details.isEmpty() ? 'No database error detail was returned.' : String.join(details, '; ');
        DocGenErrorLogger.Entry entry = new DocGenErrorLogger.Entry();
        entry.context = 'Signature Finalize';
        entry.operation = operation;
        entry.recordId = recordId == null ? null : String.valueOf(recordId);
        entry.message = detail;
        DocGenErrorLogger.log(entry);
        throw new SignatureException(operation + ' failed: ' + detail);
    }

    /**
     * Builds the HTML verification block appended to the end of the signed PDF.
     * Includes signer details, timestamps, and a verification URL. Back-compat
     * 2-arg signature — delegates to the form-field-aware overload with no fields.
     */
    public static String buildVerificationBlockHtml(Id requestId, List<DocGen_Signer__c> signers) {
        return buildVerificationBlockHtml(requestId, signers, null, null);
    }

    /**
     * Form-field-aware overload: additionally renders a "Form Field Responses"
     * section listing every configured field where listOnCertificate==true, with
     * the value collected during signing. Reuses the existing inline-style table.
     * `certFields` may be null/empty (no extra section); `formValues` is the
     * collected {key:value} map (DocGenFieldWritebackService.collectValues).
     */
    public static String buildVerificationBlockHtml(
        Id requestId,
        List<DocGen_Signer__c> signers,
        List<DocGenFieldWritebackService.FormFieldDef> certFields,
        Map<String, Object> formValues
    ) {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String siteUrl = resolveSiteUrl(settings);

        String brandColor = String.isNotBlank(settings.Signature_Email_Brand_Color__c)
            ? settings.Signature_Email_Brand_Color__c
            : '#0176D3';
        String companyName = String.isNotBlank(settings.Company_Name__c) ? settings.Company_Name__c : 'Portwood';

        // Query audit records for IP addresses and timestamps
        Map<Id, DocGen_Signature_Audit__c> signerAuditMap = new Map<Id, DocGen_Signature_Audit__c>();
        try {
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Audit__c.sObjectType,
                new Set<String>{
                    'Signer__c',
                    'IP_Address__c',
                    'User_Agent__c',
                    'Signed_Date__c',
                    'Consent_Captured__c',
                    'Signature_Request__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Audit__c> audits = [
                SELECT Signer__c, IP_Address__c, User_Agent__c, Signed_Date__c, Consent_Captured__c
                FROM DocGen_Signature_Audit__c
                WHERE Signature_Request__c = :requestId AND Signer__c != NULL
                WITH SYSTEM_MODE
            ]; // NOPMD
            for (DocGen_Signature_Audit__c a : audits) {
                signerAuditMap.put(a.Signer__c, a);
            }
        } catch (Exception e) {
            // Audit query failed — continue without IP data
        }

        String html =
            '<div style="page-break-before:always;margin-top:40px;padding-top:16px;border-top:3px solid ' +
            brandColor +
            ';">';
        html += '<table style="width:100%;font-family:Helvetica,Arial,sans-serif;font-size:9pt;color:#333;border-collapse:collapse;">';

        // Header
        html +=
            '<tr><td colspan="2" style="padding-bottom:12px;font-size:12pt;font-weight:bold;color:' +
            brandColor +
            ';">';
        html += 'ELECTRONIC SIGNATURE CERTIFICATE</td></tr>';

        // Document info
        html += '<tr><td style="width:140px;padding:3px 0;font-weight:bold;color:#555;">Document ID:</td>';
        html += '<td style="padding:3px 0;">' + String.valueOf(requestId).escapeHtml4() + '</td></tr>';

        // INTEGRITY PROOF: surface when the document was frozen for signing and the hash of
        // that frozen content, so the certificate proves the signed document is exactly what
        // the signer reviewed (point-in-time, not a live re-merge).
        DocGen_Signature_Request__c snapInfo = lookupRequestSnapshotInfo(requestId);
        if (snapInfo != null && String.isNotBlank(snapInfo.Snapshot_Hash__c)) {
            if (snapInfo.Snapshot_Taken_At__c != null) {
                html += '<tr><td style="padding:3px 0;font-weight:bold;color:#555;">Document frozen:</td>';
                html +=
                    '<td style="padding:3px 0;">' +
                    snapInfo.Snapshot_Taken_At__c.format('MMMM d, yyyy \'at\' h:mm a z') +
                    '</td></tr>';
            }
            html += '<tr><td style="padding:3px 0;font-weight:bold;color:#555;">Snapshot hash:</td>';
            html +=
                '<td style="padding:3px 0;font-family:monospace;font-size:7pt;word-break:break-all;">' +
                snapInfo.Snapshot_Hash__c.escapeHtml4() +
                '</td></tr>';
        }

        html += '<tr><td style="padding:3px 0;font-weight:bold;color:#555;">Completed:</td>';
        html += '<td style="padding:3px 0;">' + System.now().format('MMMM d, yyyy \'at\' h:mm a z') + '</td></tr>';

        // Signer details
        html += '<tr><td colspan="2" style="padding-top:16px;padding-bottom:6px;font-size:10pt;font-weight:bold;border-bottom:1px solid #ddd;">Signer Details</td></tr>';

        for (DocGen_Signer__c s : signers) {
            DocGen_Signature_Audit__c audit = signerAuditMap.get(s.Id);
            String role = String.isNotBlank(s.Role_Name__c) ? s.Role_Name__c : 'Signer';

            html += '<tr><td colspan="2" style="padding:8px 0 2px 0;border-bottom:1px solid #eee;">';

            // Signature name + Role. The name the signer actually typed at signing
            // (Signature_Data__c) is their electronic signature; fall back to the
            // invited name (Signer_Name__c) when no typed value was captured.
            // Read Signature_Data__c defensively AND namespace-safely: accessing the
            // field directly lets Apex resolve the managed-package namespace (a hardcoded
            // getPopulatedFieldsAsMap().get('Signature_Data__c') is null in a namespaced
            // org, where the map keys are prefixed). The try/catch preserves the
            // defensive behavior for callers that didn't query the field.
            String typedSig;
            try {
                typedSig = s.Signature_Data__c;
            } catch (System.SObjectException fieldNotQueried) {
                typedSig = null;
            }
            String signatureName = String.isNotBlank(typedSig) ? typedSig : s.Signer_Name__c;
            html += '<span style="font-weight:bold;font-size:10pt;">' + signatureName.escapeHtml4() + '</span>';
            html +=
                ' <span style="background:' +
                brandColor +
                ';color:#fff;font-size:7pt;font-weight:bold;padding:1px 6px;border-radius:8px;">' +
                role.escapeHtml4() +
                '</span><br/>';

            // Email
            html += '<span style="color:#555;">' + s.Signer_Email__c.escapeHtml4() + '</span><br/>';

            // If the signer amended their name at signing, also show the invited name.
            if (String.isNotBlank(typedSig) && typedSig != s.Signer_Name__c) {
                html += '<span style="color:#555;">Registered as: ' + s.Signer_Name__c.escapeHtml4() + '</span><br/>';
            }

            // Audit details
            if (audit != null) {
                if (audit.Signed_Date__c != null) {
                    html +=
                        '<span style="color:#555;">Signed: ' +
                        audit.Signed_Date__c.format('MMMM d, yyyy \'at\' h:mm a z') +
                        '</span><br/>';
                }
                if (String.isNotBlank(audit.IP_Address__c)) {
                    html +=
                        '<span style="color:#555;">IP Address: ' +
                        audit.IP_Address__c.escapeHtml4() +
                        '</span><br/>';
                }
                if (audit.Consent_Captured__c) {
                    html += '<span style="color:#2e844a;">&#10003; Consent captured</span><br/>';
                }
            }
            if (s.PIN_Verified_At__c != null) {
                html +=
                    '<span style="color:#2e844a;">&#10003; Email verified ' +
                    s.PIN_Verified_At__c.format('MMM d, yyyy h:mm a z') +
                    '</span>';
            }

            html += '</td></tr>';
        }

        // Form Field Responses — list configured fields flagged listOnCertificate,
        // attributed PER SIGNER. Each signer fills the same template-scoped fields
        // independently (their values live on DocGen_Signer__c.Field_Data_Json__c), so
        // the certificate shows each signer's own answers. Single signer → a flat
        // label:value list with no signer header (unchanged appearance). Multiple
        // signers → a per-signer sub-heading before each set. The merged formValues
        // param is intentionally not used here (it would be ambiguous across signers).
        if (certFields != null && !certFields.isEmpty() && signers != null && !signers.isEmpty()) {
            List<DocGenFieldWritebackService.FormFieldDef> shown = new List<DocGenFieldWritebackService.FormFieldDef>();
            for (DocGenFieldWritebackService.FormFieldDef def : certFields) {
                if (def.listOnCertificate == true) {
                    shown.add(def);
                }
            }
            if (!shown.isEmpty()) {
                Boolean multi = signers.size() > 1;
                Boolean anyRendered = false;
                String fieldRows = '';
                for (DocGen_Signer__c sgn : signers) {
                    Map<String, Object> sVals = new Map<String, Object>();
                    if (String.isNotBlank(sgn.Field_Data_Json__c)) {
                        try {
                            Object parsed = JSON.deserializeUntyped(sgn.Field_Data_Json__c);
                            if (parsed instanceof Map<String, Object>) {
                                sVals = (Map<String, Object>) parsed;
                            }
                        } catch (Exception e) {
                            // Unparseable signer payload — skip this signer's answers.
                        }
                    }
                    if (multi) {
                        // Skip signers who answered none of the listed fields.
                        Boolean hasAny = false;
                        for (DocGenFieldWritebackService.FormFieldDef def : shown) {
                            if (sVals.get(def.key) != null) {
                                hasAny = true;
                                break;
                            }
                        }
                        if (!hasAny) {
                            continue;
                        }
                        String who = String.isNotBlank(sgn.Signer_Name__c)
                            ? sgn.Signer_Name__c
                            : (String.isNotBlank(sgn.Signer_Email__c) ? sgn.Signer_Email__c : 'Signer');
                        if (String.isNotBlank(sgn.Role_Name__c)) {
                            who += ' (' + sgn.Role_Name__c + ')';
                        }
                        fieldRows +=
                            '<tr><td colspan="2" style="padding-top:8px;padding-bottom:2px;font-size:9pt;font-weight:bold;color:#333;">' +
                            who.escapeHtml4() +
                            '</td></tr>';
                    }
                    for (DocGenFieldWritebackService.FormFieldDef def : shown) {
                        Object raw = sVals.get(def.key);
                        String display;
                        if (def.type == 'checkbox') {
                            Boolean checked = raw instanceof Boolean
                                ? (Boolean) raw
                                : (raw != null && String.valueOf(raw).equalsIgnoreCase('true'));
                            display = checked ? 'Yes' : 'No';
                        } else {
                            display = raw == null ? '' : String.valueOf(raw);
                        }
                        String fieldLabel = String.isNotBlank(def.label) ? def.label : def.key;
                        fieldRows +=
                            '<tr><td style="width:140px;padding:3px 0;font-weight:bold;color:#555;vertical-align:top;">' +
                            fieldLabel.escapeHtml4() +
                            ':</td>';
                        fieldRows += '<td style="padding:3px 0;">' + display.escapeHtml4() + '</td></tr>';
                    }
                    anyRendered = true;
                }
                if (anyRendered) {
                    html += '<tr><td colspan="2" style="padding-top:16px;padding-bottom:6px;font-size:10pt;font-weight:bold;border-bottom:1px solid #ddd;">Form Field Responses</td></tr>';
                    html += fieldRows;
                }
            }
        }

        // Verification footer
        html += '<tr><td colspan="2" style="padding-top:16px;font-size:8pt;color:#706e6b;">';
        html += 'This document was electronically signed using ' + companyName.escapeHtml4() + '. ';
        // Legal attestation — kept identical to the drawn/guided certificate
        // (DocGenSignaturePdf.page addCertificatePage) so both signing paths emit the
        // same statement. See docs/certificate-unification-plan.md.
        html += 'This certificate evidences an electronic signature under the US ESIGN Act and UETA. ';
        html += 'The SHA-256 hash of the signed PDF is stored in a tamper-evident audit record with field history tracking enabled. ';
        // SECURITY: the verify link carries the request's unguessable Secure_Token__c,
        // not the enumerable record Id. buildVerifyUrl returns null (link omitted) when
        // no Site URL is configured or the token is absent — document-upload
        // verification on DocGenVerify still works without the link.
        String verifyUrl = buildVerifyUrl(requestId, siteUrl);
        if (String.isNotBlank(verifyUrl)) {
            html += 'Verify this document at: ' + verifyUrl.escapeHtml4();
        }
        html += '</td></tr>';

        html += '</table></div>';
        return html;
    }

    /**
     * Loads the parsed signer form-field config for a template (SYSTEM_MODE; async
     * finalize context). Returns an empty list when the template has none or can't
     * be read — the certificate then renders without a Form Field Responses section.
     */
    private static List<DocGenFieldWritebackService.FormFieldDef> loadCertFieldDefs(Id templateId) {
        if (templateId == null) {
            return new List<DocGenFieldWritebackService.FormFieldDef>();
        }
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Form_Fields_Config__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Template__c> tmpls = [
                SELECT Form_Fields_Config__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets
            if (!tmpls.isEmpty()) {
                return DocGenFieldWritebackService.parseConfig(tmpls[0].Form_Fields_Config__c);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: cert field defs load failed: ' + e.getMessage());
        }
        return new List<DocGenFieldWritebackService.FormFieldDef>();
    }

    /**
     * Returns the request's unguessable verification token (Secure_Token__c) used
     * as the capability on the certificate verify link. Runs in the async
     * (Automated Process) finalize context, so SYSTEM_MODE is required. Returns
     * null when absent (e.g. legacy requests created before this hotfix) — the
     * caller then omits the link, leaving document-upload verification intact.
     */
    /**
     * Resolves the public Salesforce Site base URL used for certificate verify links:
     * the configured DocGen_Settings__c.Experience_Site_Url__c, else the first Active
     * Site's SecureUrl. Returns null when neither is available (the caller then omits
     * the verify link). SYSTEM_MODE sidesteps the guest/@TestSetup FLS-propagation
     * issue documented in DocGenFlsGuard.cls.
     */
    private static String resolveSiteUrl(DocGen_Settings__c settings) {
        String siteUrl = settings != null ? settings.Experience_Site_Url__c : null;
        if (String.isBlank(siteUrl)) {
            try {
                DocGenFlsGuard.assertAccessible(Site.sObjectType, new Set<String>{ 'Status' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<Site> sites = [SELECT Id FROM Site WHERE Status = 'Active' WITH SYSTEM_MODE LIMIT 1];
                if (!sites.isEmpty()) {
                    DocGenFlsGuard.assertAccessible(
                        SiteDetail.sObjectType,
                        new Set<String>{ 'SecureUrl', 'DurableId' }
                    );
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    SiteDetail sd = [
                        SELECT SecureUrl
                        FROM SiteDetail
                        WHERE DurableId = :sites[0].Id
                        WITH SYSTEM_MODE
                        LIMIT 1
                    ];
                    siteUrl = sd.SecureUrl;
                }
            } catch (Exception e) {
                // Site query may fail in some contexts — verify link is then omitted.
            }
        }
        return siteUrl;
    }

    /**
     * Builds the namespace-aware certificate verify-page URL for a request:
     * {siteUrl}/apex/[ns__]DocGenVerify?token={request Secure_Token__c}. Both signing
     * paths use this so the typed/server certificate and the drawn/guided certificate
     * (DocGenSignaturePdf.page, surfaced via getSignatureCertificate) carry the SAME
     * verify link. Returns null when no Site URL is configured or the request has no
     * token (legacy requests) — document-upload verification on DocGenVerify still
     * works without a printed link. See docs/certificate-unification-plan.md.
     */
    public static String buildVerifyUrl(Id requestId) {
        return buildVerifyUrl(requestId, resolveSiteUrl(DocGen_Settings__c.getOrgDefaults()));
    }

    /**
     * Overload for callers that already resolved the Site URL (avoids a second
     * Site/SiteDetail query within buildVerificationBlockHtml).
     */
    public static String buildVerifyUrl(Id requestId, String siteUrl) {
        if (String.isBlank(siteUrl)) {
            return null;
        }
        if (siteUrl.endsWith('/')) {
            siteUrl = siteUrl.substring(0, siteUrl.length() - 1);
        }
        String ns = DocGenSignatureService.class.getName().substringBefore('.');
        String verifyPage = (String.isNotBlank(ns) && ns != 'DocGenSignatureService')
            ? '/apex/' + ns + '__DocGenVerify'
            : '/apex/DocGenVerify';
        String verifyToken = lookupRequestVerificationToken(requestId);
        return String.isNotBlank(verifyToken) ? siteUrl + verifyPage + '?token=' + verifyToken : null;
    }

    private static String lookupRequestVerificationToken(Id requestId) {
        if (requestId == null) {
            return null;
        }
        DocGenFlsGuard.assertAccessible(DocGen_Signature_Request__c.sObjectType, new Set<String>{ 'Secure_Token__c' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> reqs = [
            SELECT Secure_Token__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return reqs.isEmpty() ? null : reqs[0].Secure_Token__c;
    }

    /**
     * Reads the snapshot integrity fields (hash + frozen-at timestamp) for the certificate.
     * Runs in the async (Automated Process) finalize context, so SYSTEM_MODE is required.
     * Returns null when absent (legacy/oversized requests) — the cert simply omits the rows.
     */
    private static DocGen_Signature_Request__c lookupRequestSnapshotInfo(Id requestId) {
        if (requestId == null) {
            return null;
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Snapshot_Hash__c', 'Snapshot_Taken_At__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> reqs = [
            SELECT Snapshot_Hash__c, Snapshot_Taken_At__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return reqs.isEmpty() ? null : reqs[0];
    }

    /**
     * Deserializes the point-in-time document snapshot frozen at request creation
     * (Frozen_Document__c JSON) into per-document merge maps shaped like
     * DocGenService.mergeTemplateForSignature's output, so the sign path can render
     * from the reviewed content instead of re-merging the live record.
     *
     * Returns one entry per template (index-aligned to Template_Ids__c for packets),
     * or null when no snapshot exists (legacy requests created before this shipped, or
     * documents too large for the field) — callers then live-merge as before. A corrupt
     * snapshot also returns null so signing degrades to live-merge rather than failing.
     *
     * pdfImageMap is intentionally empty here; the caller fills it from the image map
     * cached in Signature_Data__c at the same creation moment. styles/numbering come
     * from the snapshot when present, else the cached style maps drive rendering.
     */
    @TestVisible
    private static List<Map<String, Object>> loadFrozenMergeData(String frozenJson) {
        if (String.isBlank(frozenJson)) {
            return null;
        }
        try {
            Map<String, Object> snap = (Map<String, Object>) JSON.deserializeUntyped(frozenJson);
            Object docsObj = snap.get('docs');
            if (!(docsObj instanceof List<Object>)) {
                return null;
            }
            String templateType = (String) snap.get('templateType');
            List<Map<String, Object>> out = new List<Map<String, Object>>();
            for (Object dObj : (List<Object>) docsObj) {
                if (!(dObj instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> d = (Map<String, Object>) dObj;
                String body = (String) d.get('combinedDocumentXml');
                out.add(
                    new Map<String, Object>{
                        'combinedDocumentXml' => body,
                        'documentXml' => body,
                        'relsXml' => (String) d.get('relsXml'),
                        'contentTypesXml' => (String) d.get('contentTypesXml'),
                        'templateType' => templateType,
                        'docTitle' => (String) d.get('docTitle'),
                        'stylesXml' => (String) d.get('stylesXml'),
                        'numberingXml' => (String) d.get('numberingXml'),
                        'pdfImageMap' => new Map<String, String>()
                    }
                );
            }
            return out.isEmpty() ? null : out;
        } catch (Exception e) {
            // Corrupt/unreadable snapshot — fall back to live merge rather than fail signing.
            System.debug(
                LoggingLevel.WARN,
                'Portwood: frozen snapshot unreadable, falling back to live merge: ' + e.getMessage()
            );
            return null;
        }
    }

    /**
     * Serializes per-template merge outputs into the frozen-document snapshot JSON captured
     * at request creation. Stores only the static, point-in-time document body
     * (combinedDocumentXml/relsXml/contentTypesXml/docTitle + styles/numbering) — the part
     * that reflects live record data and must not drift before signing. The caller persists
     * the result via saveFrozenSnapshotCv (#156, ContentVersion-backed, no size cap).
     * `global`/`public` visibility kept minimal: callers are in the same namespace.
     */
    public static String buildFrozenDocumentJson(List<Map<String, Object>> mergeOutputs, List<Id> templateIds) {
        if (mergeOutputs == null || mergeOutputs.isEmpty()) {
            return null;
        }
        String templateType = null;
        List<Object> docs = new List<Object>();
        for (Integer i = 0; i < mergeOutputs.size(); i++) {
            Map<String, Object> m = mergeOutputs[i];
            if (m == null) {
                return null;
            }
            if (templateType == null) {
                templateType = (String) m.get('templateType');
            }
            String body = (String) m.get('combinedDocumentXml');
            if (String.isBlank(body)) {
                body = (String) m.get('documentXml');
            }
            docs.add(
                new Map<String, Object>{
                    'templateId' => (templateIds != null &&
                        i < templateIds.size())
                        ? String.valueOf(templateIds[i])
                        : null,
                    'combinedDocumentXml' => body,
                    'relsXml' => (String) m.get('relsXml'),
                    'contentTypesXml' => (String) m.get('contentTypesXml'),
                    'docTitle' => (String) m.get('docTitle'),
                    'stylesXml' => (String) m.get('stylesXml'),
                    'numberingXml' => (String) m.get('numberingXml')
                }
            );
        }
        // #156: no size cap — the snapshot is persisted to a ContentVersion
        // (saveFrozenSnapshotCv), not the 131072-char Frozen_Document__c LongTextArea, so
        // documents of any size get a true point-in-time snapshot instead of degrading to a
        // live re-merge. The hash is still computed over this full JSON.
        return JSON.serialize(new Map<String, Object>{ 'v' => 1, 'templateType' => templateType, 'docs' => docs });
    }

    /**
     * #156: persists the frozen-document snapshot JSON to a ContentVersion and returns its
     * Id (stored on Frozen_Document_CV_Id__c). This removes the 131072-char ceiling that the
     * Frozen_Document__c LongTextArea imposed — large/image-heavy templates previously
     * couldn't be frozen at all and silently fell back to a live re-merge at sign time
     * (integrity gap + the #189 stamp mismatch). The CV is internal (no record link);
     * the async finalizer reads it WITH SYSTEM_MODE. Returns null for a blank snapshot.
     */
    public static Id saveFrozenSnapshotCv(String frozenJson) {
        if (String.isBlank(frozenJson)) {
            return null;
        }
        ContentVersion cv = new ContentVersion();
        cv.Title = 'docgen_sig_frozen';
        cv.PathOnClient = 'docgen_sig_frozen.json';
        cv.VersionData = Blob.valueOf(frozenJson);
        DocGenFlsGuard.assertCreateable(cv, new Set<String>{ 'Title', 'PathOnClient', 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(cv, AccessLevel.SYSTEM_MODE);
        return cv.Id;
    }

    /**
     * #156 storage lifecycle: deletes a frozen-snapshot ContentVersion once its request reaches
     * a terminal state (Signed/Declined/Cancelled). The snapshot has done its job — the signed
     * PDF and the Snapshot_Hash__c remain as the tamper-evidence record (the hash still proves
     * the signed document equals what was reviewed), so the bulky body is reclaimed. Best-effort:
     * a cleanup failure is logged, never thrown — it must not break signing or cancellation.
     * Callers should also null Frozen_Document_CV_Id__c so the reference doesn't dangle.
     */
    public static void purgeFrozenSnapshotCv(Id frozenCvId) {
        if (frozenCvId == null) {
            return;
        }
        try {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<ContentDocument> docs = [
                SELECT Id
                FROM ContentDocument
                WHERE LatestPublishedVersionId = :frozenCvId
                WITH SYSTEM_MODE
            ];
            if (!docs.isEmpty()) {
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.delete(docs, false, AccessLevel.SYSTEM_MODE);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: frozen snapshot purge skipped: ' + e.getMessage());
        }
    }

    /**
     * #156 read path: loads + parses the frozen snapshot from its ContentVersion. Runs in the
     * async (Automated Process) finalize context, so the CV is read WITH SYSTEM_MODE (internal
     * CV, ContentDocumentLink Visibility=InternalUsers → USER_MODE returns empty). Returns null
     * (→ legacy field / live-merge fallback) when the CV is missing or empty.
     */
    private static List<Map<String, Object>> loadFrozenMergeDataFromCv(Id cvId) {
        if (cvId == null) {
            return null;
        }
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<ContentVersion> cvs = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :cvId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cvs.isEmpty() || cvs[0].VersionData == null) {
            return null;
        }
        return loadFrozenMergeData(cvs[0].VersionData.toString());
    }

    /**
     * Resolves the frozen merge data for a request, preferring the CV-backed snapshot (#156,
     * no size cap) and falling back to the legacy inline Frozen_Document__c field for requests
     * created before the CV migration. Returns null when neither is present (→ live re-merge).
     */
    private static List<Map<String, Object>> resolveFrozenMergeData(DocGen_Signature_Request__c reqData) {
        if (String.isNotBlank(reqData.Frozen_Document_CV_Id__c)) {
            List<Map<String, Object>> fromCv = loadFrozenMergeDataFromCv((Id) reqData.Frozen_Document_CV_Id__c);
            if (fromCv != null) {
                return fromCv;
            }
        }
        return loadFrozenMergeData(reqData.Frozen_Document__c);
    }

    /**
     * SHA-256 hex of the frozen snapshot JSON — stored on the request and surfaced on the
     * certificate so the audit proves the signed document equals what the signer reviewed.
     */
    public static String hashFrozenDocument(String frozenJson) {
        if (String.isBlank(frozenJson)) {
            return null;
        }
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(frozenJson)));
    }

    /**
     * Resolves the signed-PDF file name for a request, in priority order:
     *   1. Document_Title_Format__c (admin naming pattern, issue #42) resolved against
     *      the related record — wins when set.
     *   2. The template Name + " - Signed" — when the request has a Template__c.
     *   3. The provided fallback (e.g. the source document's "<title> - Signed").
     * Centralizes naming so the document-based and template-based signature queueables
     * can't diverge again (the divergence was the "signed files ignore template name" bug).
     */
    @TestVisible
    private static String resolveSignedFileName(DocGen_Signature_Request__c req, String fallbackBase) {
        String fileName = fallbackBase;
        if (req.Template__c != null) {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Name' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Template__c> tpls = [
                SELECT Name
                FROM DocGen_Template__c
                WHERE Id = :req.Template__c
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!tpls.isEmpty() && String.isNotBlank(tpls[0].Name)) {
                fileName = tpls[0].Name + ' - Signed';
            }
        }
        if (String.isNotBlank(req.Document_Title_Format__c) && String.isNotBlank(req.Related_Record_Id__c)) {
            try {
                Map<String, Object> recordData = DocGenService.loadRecordDataForTitle(
                    req.Related_Record_Id__c,
                    req.Document_Title_Format__c
                );
                String resolved = DocGenService.generateDocTitle(
                    req.Document_Title_Format__c,
                    recordData != null ? recordData : new Map<String, Object>()
                );
                if (String.isNotBlank(resolved)) {
                    fileName = resolved.trim();
                }
            } catch (Exception titleErr) {
                // Title resolution is best-effort — keep the template/fallback name.
                System.debug(LoggingLevel.WARN, 'Portwood signed-file title format failed: ' + titleErr.getMessage());
            }
        }
        return fileName;
    }

    /**
     * M3 — signature loop block.
     *
     * Builds the per-signer collection injected under the reserved {#Signatures}
     * render-data key. A template author writes ONE signature layout wrapped in
     * {#Signatures}...{/Signatures} (anywhere in the document) and it renders once
     * per signer, for any signer count — no per-count templates and no orphan role
     * tags. Each row exposes:
     *   {Name}           the typed e-signature (Signature_Data__c) or, if none was
     *                    captured, the invited name (Signer_Name__c)
     *   {RegisteredName} the invited name
     *   {Role}           Role_Name__c (defaults to "Signer")
     *   {Email}          Signer_Email__c
     *   {SignedDate}     formatted signed date from the audit record (blank if unsigned)
     *   {Status}         Status__c
     *
     * Purely additive: this list is only present when the finalizer/sender inject it,
     * so templates without a {#Signatures} block are unaffected and role-tag
     * ({@Signature_Role}) stamping is untouched. This is the completion (signed)
     * variant; buildPendingSignerLoopData builds the pre-signing preview variant.
     */
    public static List<Map<String, Object>> buildSignerLoopData(Id requestId) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();

        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Signer_Name__c',
                'Signature_Data__c',
                'Signer_Email__c',
                'Role_Name__c',
                'Status__c',
                'Signature_Request__c',
                'Sort_Order__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Signer_Name__c, Signature_Data__c, Signer_Email__c, Role_Name__c, Status__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];
        if (signers.isEmpty()) {
            return rows;
        }

        // Signed dates come from the audit records — the same source the certificate
        // block uses (one audit per signer; keep the earliest signed timestamp).
        Map<Id, Datetime> signedDates = new Map<Id, Datetime>();
        try {
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Audit__c.sObjectType,
                new Set<String>{ 'Signer__c', 'Signed_Date__c', 'Signature_Request__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Audit__c> audits = [
                SELECT Signer__c, Signed_Date__c
                FROM DocGen_Signature_Audit__c
                WHERE Signature_Request__c = :requestId AND Signer__c != NULL
                WITH SYSTEM_MODE
            ];
            for (DocGen_Signature_Audit__c a : audits) {
                if (a.Signed_Date__c != null && !signedDates.containsKey(a.Signer__c)) {
                    signedDates.put(a.Signer__c, a.Signed_Date__c);
                }
            }
        } catch (Exception e) {
            // Signed-date enrichment is best-effort — fall back to blank dates.
        }

        for (DocGen_Signer__c s : signers) {
            rows.add(
                buildSignerLoopRow(
                    String.isNotBlank(s.Signature_Data__c) ? s.Signature_Data__c : s.Signer_Name__c,
                    s.Signer_Name__c,
                    s.Role_Name__c,
                    s.Signer_Email__c,
                    signedDates.get(s.Id),
                    s.Status__c
                )
            );
        }
        return rows;
    }

    /**
     * M3 — pre-signing preview variant of the {#Signatures} loop collection. Built
     * from the raw signer inputs (signerName/signerEmail/roleName) at send-time,
     * before any DocGen_Signer__c rows exist, so the viewing PDF shows the signature
     * layout with the invited signers and a "Pending" status (no typed name/date yet).
     */
    public static List<Map<String, Object>> buildPendingSignerLoopData(List<Map<String, Object>> signerInputs) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        if (signerInputs == null) {
            return rows;
        }
        for (Map<String, Object> input : signerInputs) {
            String name = (String) input.get('signerName');
            rows.add(
                buildSignerLoopRow(
                    '', // pending: signature line stays BLANK until the signer actually signs
                    name, // RegisteredName = the invited (printed) name
                    (String) input.get('roleName'),
                    (String) input.get('signerEmail'),
                    null,
                    'Pending'
                )
            );
        }
        return rows;
    }

    /**
     * Shared row shape for the {#Signatures} loop so the signed (completion) and
     * pending (preview) variants always expose identical field keys.
     */
    private static Map<String, Object> buildSignerLoopRow(
        String name,
        String registeredName,
        String role,
        String email,
        Datetime signedDate,
        String status
    ) {
        return new Map<String, Object>{
            'Name' => String.isNotBlank(name) ? name : '',
            'RegisteredName' => String.isNotBlank(registeredName) ? registeredName : '',
            'Role' => String.isNotBlank(role) ? role : 'Signer',
            'Email' => String.isNotBlank(email) ? email : '',
            'SignedDate' => signedDate != null ? signedDate.format('MMMM d, yyyy') : '',
            'Status' => String.isNotBlank(status) ? status : ''
        };
    }

    /**
     * Builds the OOXML text run that replaces a {@Signature_Role} placeholder.
     * Renders as: "Electronically signed by [Name] on [Date]"
     * Uses italic styling with a subtle border to visually distinguish the signature block.
     */
    private static String buildSignatureTextXml(String typedName, Datetime signedDate) {
        String safeName = escapeXml(typedName);
        String dateStr = signedDate != null
            ? signedDate.format('yyyy-MM-dd HH:mm:ss z')
            : System.now().format('yyyy-MM-dd HH:mm:ss z');

        return '</w:t></w:r>' +
            '<w:r><w:rPr><w:i/><w:sz w:val="20"/></w:rPr>' +
            '<w:t xml:space="preserve">Electronically signed by ' +
            safeName +
            ' on ' +
            dateStr +
            '</w:t></w:r>' +
            '<w:r><w:t xml:space="preserve">';
    }

    /**
     * Escapes special XML characters in a string.
     */
    private static String escapeXml(String input) {
        if (input == null)
            return '';
        return input
            .replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;')
            .replace('\'', '&apos;');
    }

    /**
     * Stamps typed-name signatures into already-merged XML strings using placement records.
     * Pure string operations — no ZIP, no blob loading, no heap pressure.
     * Used by the template-based signature flow for direct PDF rendering.
     *
     * The `signers` parameter is retained for API compatibility but is not used — all stamping
     * is driven by the v3 placement records. Bare `{@Signature_Role}` tags are handled
     * automatically by parseSignaturePlacements, which treats them as `{@Signature_Role:1:Full}`.
     */
    public static StampResult stampSignaturesInXml(
        String documentXml,
        String relsXml,
        String contentTypesXml,
        List<SignerImageData> signers
    ) {
        return stampSignaturesInXml(documentXml, relsXml, contentTypesXml, signers, null);
    }

    public static StampResult stampSignaturesInXml(
        String documentXml,
        String relsXml,
        String contentTypesXml,
        List<SignerImageData> signers,
        List<DocGen_Signature_Placement__c> placements
    ) {
        Map<String, String> signatureImageUrls = new Map<String, String>();

        if (placements != null && !placements.isEmpty()) {
            for (DocGen_Signature_Placement__c plc : placements) {
                if (plc.Status__c != 'Signed' || String.isBlank(plc.Tag_Text__c))
                    continue;

                String replacement = buildPlacementText(plc);
                if (documentXml.contains(plc.Tag_Text__c)) {
                    // Replace only the FIRST occurrence of this exact tag
                    documentXml = documentXml.replaceFirst(Pattern.quote(plc.Tag_Text__c), escapeXml(replacement));
                }
            }
        }

        return new StampResult(documentXml, relsXml, contentTypesXml, signatureImageUrls);
    }

    @TestVisible
    private static String stampSignaturesInHtml(String html, List<DocGen_Signature_Placement__c> placements) {
        if (String.isBlank(html) || placements == null || placements.isEmpty()) {
            return html;
        }

        for (DocGen_Signature_Placement__c plc : placements) {
            if (plc.Status__c != 'Signed' || String.isBlank(plc.Tag_Text__c))
                continue;

            if (html.contains(plc.Tag_Text__c)) {
                html = html.replaceFirst(Pattern.quote(plc.Tag_Text__c), buildPlacementText(plc).escapeHtml4());
            }
        }
        return html;
    }

    /**
     * Builds the replacement text for a signed placement based on its type.
     */
    private static String buildPlacementText(DocGen_Signature_Placement__c plc) {
        String value = plc.Signed_Value__c;
        String pType = plc.Placement_Type__c;

        if (pType == 'Full') {
            String dateStr = plc.Signed_At__c != null
                ? plc.Signed_At__c.format('yyyy-MM-dd HH:mm:ss z')
                : System.now().format('yyyy-MM-dd HH:mm:ss z');
            return 'Electronically signed by ' + value + ' on ' + dateStr;
        } else if (pType == 'Initials') {
            return value; // Just the initials
        } else if (pType == 'Date') {
            // Auto server timestamp
            DateTime dt = plc.Signed_At__c != null ? plc.Signed_At__c : System.now();
            return dt.format('MMMM d, yyyy');
        } else if (pType == 'DatePick') {
            return value; // Signer-picked date string
        }
        return value != null ? value : '';
    }

    /**
     * Stamps ALL signer typed-name signatures into a DOCX at their named placeholders.
     * Each signer's role maps to {@Signature_RoleName} in the document.
     * Falls back to legacy {@Signature} for single signer with blank role.
     */
    public static Blob stampAllSignaturesToBlob(Id sourceCvId, List<SignerData> signers) {
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData', 'Title' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        ContentVersion cv = [
            SELECT Id, VersionData, Title
            FROM ContentVersion
            WHERE Id = :sourceCvId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cv == null || cv.VersionData == null) {
            throw new SignatureException('Source document not found or has no content.');
        }

        Blob docxBlob = cv.VersionData;
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        Compression.ZipWriter writer = new Compression.ZipWriter();

        for (Compression.ZipEntry entry : reader.getEntries()) {
            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
            String name = entry.getName();

            if (name == 'word/document.xml') {
                String docXml = reader.extract(name).toString();

                for (SignerData sd : signers) {
                    String placeholder;
                    if (String.isBlank(sd.roleName)) {
                        placeholder = '{@Signature}';
                    } else {
                        placeholder = '{@Signature_' + sd.roleName.replaceAll(' ', '_') + '}';
                    }

                    String safeName = escapeXml(sd.typedName);
                    String dateStr = sd.signedDate != null
                        ? sd.signedDate.format('yyyy-MM-dd HH:mm:ss z')
                        : System.now().format('yyyy-MM-dd HH:mm:ss z');
                    String sigText = 'Electronically signed by ' + safeName + ' on ' + dateStr;
                    if (docXml.contains(placeholder)) {
                        docXml = docXml.replace(placeholder, sigText);
                    } else {
                        // Append at end of document as fallback
                        String fallbackLabel = String.isNotBlank(sd.roleName) ? sd.roleName : 'Signature';
                        docXml = docXml.replace(
                            '</w:body>',
                            '<w:p><w:r><w:t xml:space="preserve">Electronically signed by ' +
                                safeName +
                                ' (' +
                                escapeXml(fallbackLabel) +
                                ') on ' +
                                dateStr +
                                '</w:t></w:r></w:p></w:body>'
                        );
                    }
                }
                writer.addEntry(name, Blob.valueOf(docXml));
            } else {
                writer.addEntry(name, reader.extract(name));
            }
        }

        return writer.getArchive();
    }

    /**
     * Stamps a single typed-name signature into a DOCX and saves to DB.
     */
    public static Id stampSignature(Id sourceCvId, String typedName, String requestNumber, String relatedRecordId) {
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        ContentVersion source = [SELECT Title FROM ContentVersion WHERE Id = :sourceCvId WITH SYSTEM_MODE LIMIT 1];
        List<SignerData> signers = new List<SignerData>{ new SignerData(null, typedName) };
        Blob resultBlob = stampAllSignaturesToBlob(sourceCvId, signers);

        ContentVersion newCv = new ContentVersion();
        newCv.Title = source.Title + ' - Signed';
        newCv.PathOnClient = newCv.Title + '.docx';
        newCv.VersionData = resultBlob;
        newCv.IsMajorVersion = true;
        SObjectAccessDecision cvDecision = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<ContentVersion>{ newCv }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        insert cvDecision.getRecords();
        Id savedCvId = cvDecision.getRecords()[0].Id;

        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'ContentDocumentId' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Id newDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH SYSTEM_MODE]
        .ContentDocumentId;

        if (String.isNotBlank(relatedRecordId)) {
            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = newDocId;
            cdl.LinkedEntityId = relatedRecordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            SObjectAccessDecision cdlDecision = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<ContentDocumentLink>{ cdl }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            insert cdlDecision.getRecords();
        }

        return savedCvId;
    }

    /**
     * Privileged entry point called by Flow invocable actions.
     * Saves signature data, then enqueues PDF generation via Blob.toPdf().
     */
    public static void handleSignatureSubmission(String token, String typedName) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new SignatureException('Invalid security token format.');
        }

        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{
                'Status__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Source_Document_Id__c',
                'Related_Record_Id__c',
                'CreatedDate',
                'Secure_Token__c',
                'Expires_At__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> requests = [
            SELECT
                Id,
                Status__c,
                Signer_Name__c,
                Signer_Email__c,
                Source_Document_Id__c,
                Related_Record_Id__c,
                CreatedDate,
                Expires_At__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            return;
        }

        if (DocGenSignatureExpiry.isExpired(requests[0].Expires_At__c, requests[0].CreatedDate)) {
            throw new SignatureException('This signature link has expired.');
        }

        DocGen_Signature_Request__c req = requests[0];
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        req.Signature_Data__c = typedName;
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        req.Status__c = 'In Progress';
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        update req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets

        if (Test.isRunningTest()) {
            try {
                Blob pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed Document</p></body></html>');
                DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<ContentVersion> sources = [
                    SELECT Title
                    FROM ContentVersion
                    WHERE Id = :req.Source_Document_Id__c
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                String fileName = !sources.isEmpty() ? sources[0].Title + ' - Signed' : 'Document - Signed';
                DocGenController.saveGeneratedDocument(
                    req.Related_Record_Id__c,
                    fileName,
                    EncodingUtil.base64Encode(pdfBlob),
                    'pdf'
                );
                // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
                req.Status__c = 'Signed';
                // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
                req.Signature_Data__c = null;
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                update req; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Portwood: Test path signature error: ' + e.getMessage());
            }
        } else {
            System.enqueueJob(new SignaturePdfQueueable(req.Id));
        }
    }

    /**
     * Queueable: Stamps typed-name signatures into DOCX, renders PDF.
     * Much simpler than the old 2-stage pipeline since there are no image blobs to manage.
     */
    // CxSAST: without sharing required for guest user signing context; access gated by cryptographic token
    public class SignaturePdfQueueable implements Queueable, Database.AllowsCallouts {
        private Id requestId;

        public SignaturePdfQueueable(Id requestId) {
            this.requestId = requestId;
        }

        public void execute(QueueableContext ctx) {
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{
                    'Source_Document_Id__c',
                    'Related_Record_Id__c',
                    'Template__c',
                    'Document_Title_Format__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> requests = [
                SELECT Id, Source_Document_Id__c, Related_Record_Id__c, Template__c, Document_Title_Format__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (requests.isEmpty())
                return;

            DocGen_Signature_Request__c req = requests[0];

            DocGenService.applyWatermarkOverride(req.Template__c);

            try {
                assertRequestPlacementsComplete(requestId);
                // Get signature data from signers
                DocGenFlsGuard.assertAccessible(
                    DocGen_Signer__c.sObjectType,
                    new Set<String>{
                        'Role_Name__c',
                        'Signature_Data__c',
                        'Signer_Name__c',
                        'Signer_Email__c',
                        'Contact__c',
                        'Signature_Request__c',
                        'Status__c',
                        'Sort_Order__c'
                    }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<DocGen_Signer__c> signers = [
                    SELECT Id, Role_Name__c, Signature_Data__c, Signer_Name__c, Signer_Email__c, Contact__c
                    FROM DocGen_Signer__c
                    WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
                    WITH SYSTEM_MODE
                    ORDER BY Sort_Order__c ASC
                ];

                List<SignerData> signerDataList = new List<SignerData>();
                for (DocGen_Signer__c s : signers) {
                    if (String.isNotBlank(s.Signature_Data__c)) {
                        signerDataList.add(new SignerData(s.Role_Name__c, s.Signature_Data__c));
                    }
                }

                Blob stampedBlob;
                Blob pdfBlob;
                if (Test.isRunningTest()) {
                    pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed</p></body></html>');
                } else {
                    // Stamp typed names into DOCX
                    stampedBlob = stampAllSignaturesToBlob(req.Source_Document_Id__c, signerDataList);

                    // Convert stamped DOCX to HTML then PDF
                    Map<String, Object> parts = DocGenSignatureController.extractDocxParts(stampedBlob);
                    String documentXml = (String) parts.get('documentXml');
                    Map<String, String> imagesByRelId = (Map<String, String>) parts.get('imagesByRelId');

                    // Build image URL map for template images (no signature images needed)
                    Map<String, String> imageUrlMap = new Map<String, String>();
                    if (imagesByRelId != null) {
                        for (String relId : imagesByRelId.keySet()) {
                            // For non-signature images, save as CV and use relative URL
                            String base64Val = imagesByRelId.get(relId);
                            String ext = (base64Val.startsWith('/9j/') || base64Val.startsWith('/9J/'))
                                ? 'jpeg'
                                : 'png';
                            ContentVersion imgCv = new ContentVersion();
                            imgCv.Title = 'docgen_sig_img_' + relId;
                            imgCv.PathOnClient = 'docgen_sig_img_' + relId + '.' + ext;
                            imgCv.VersionData = EncodingUtil.base64Decode(base64Val);
                            imgCv.FirstPublishLocationId = requestId;
                            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
                            DocGenFlsGuard.assertCreateable(
                                imgCv,
                                new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId' }
                            );
                            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                            Database.insert(new List<ContentVersion>{ imgCv }, false, AccessLevel.SYSTEM_MODE);
                            imageUrlMap.put(relId, '/sfc/servlet.shepherd/version/download/' + imgCv.Id);
                        }
                    }

                    String html = DocGenHtmlRenderer.convertToHtml(documentXml, imageUrlMap);
                    assertNoUnresolvedSignatureSentinels(html);
                    pdfBlob = Blob.toPdf(html);
                }

                // Save PDF to related record
                DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                ContentVersion source = [
                    SELECT Title
                    FROM ContentVersion
                    WHERE Id = :req.Source_Document_Id__c
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                // BUGFIX: the signed PDF now respects the template name / configured title
                // format, not just the source file's title. Previously this hardcoded
                // `source.Title + ' - Signed'`, so signed documents inherited the uploaded/
                // pre-generated source name instead of the template name — while the
                // template signature queueable named correctly. Shared resolver keeps the
                // two paths from diverging again.
                String fileName = resolveSignedFileName(req, source.Title + ' - Signed');

                if (String.isNotBlank(req.Related_Record_Id__c)) {
                    ContentVersion pdfCv = new ContentVersion();
                    pdfCv.Title = fileName;
                    pdfCv.PathOnClient = fileName + '.pdf';
                    pdfCv.VersionData = pdfBlob;
                    pdfCv.FirstPublishLocationId = req.Related_Record_Id__c;
                    // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
                    DocGenFlsGuard.assertCreateable(
                        pdfCv,
                        new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId' }
                    );
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    Database.SaveResult cvRes = Database.insert(
                        new List<ContentVersion>{ pdfCv },
                        false,
                        AccessLevel.SYSTEM_MODE
                    )[0];
                    // Surface a silent finalize failure — previously a failed save left the
                    // request "Signed" with NO attached PDF and no trace (the bug Sarah hit:
                    // signing completes but the signed document never appears).
                    if (!cvRes.isSuccess()) {
                        throw new DocGenException(
                            'Signed PDF could not be saved to ' +
                                req.Related_Record_Id__c +
                                ': ' +
                                cvRes.getErrors()[0].getMessage()
                        );
                    }
                }

                // Update document hash on existing audit records
                String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
                DocGenFlsGuard.assertAccessible(
                    DocGen_Signature_Audit__c.sObjectType,
                    new Set<String>{ 'Signature_Request__c', 'Document_Hash_SHA256__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<DocGen_Signature_Audit__c> audits = [
                    SELECT Id
                    FROM DocGen_Signature_Audit__c
                    WHERE Signature_Request__c = :requestId AND Document_Hash_SHA256__c = NULL
                    WITH SYSTEM_MODE
                ];
                for (DocGen_Signature_Audit__c a : audits) {
                    // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
                    a.Document_Hash_SHA256__c = pdfHash;
                }
                if (!audits.isEmpty()) {
                    // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
                    DocGenFlsGuard.assertUpdateable(audits, new Set<String>{ 'Document_Hash_SHA256__c' });
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    List<Database.SaveResult> auditResults = Database.update(audits, false, AccessLevel.SYSTEM_MODE);
                    for (Integer i = 0; i < auditResults.size(); i++) {
                        requireDmlSuccess(auditResults[i], 'Update signed-document audit hash', audits[i].Id);
                    }
                }

                // Mark request as signed
                // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
                req.Status__c = 'Signed';
                // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
                DocGenFlsGuard.assertUpdateable(req, new Set<String>{ 'Status__c' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                requireDmlSuccess(
                    Database.update(req, false, AccessLevel.SYSTEM_MODE),
                    'Complete signature request',
                    req.Id
                );

                // Completion emails (moved here from DocGenSignaturePdfTrigger so the
                // finalized PDF can be attached — it doesn't exist yet in the trigger).
                // Each send is individually guarded: an email failure must never reach
                // the outer catch, which would reset a signed request back to Viewed.
                try {
                    DocGenSignatureEmailService.sendAllSignedNotification(requestId, pdfBlob, fileName);
                } catch (Exception notifEx) {
                    System.debug(
                        LoggingLevel.WARN,
                        'Portwood: All-signed notification failed: ' + notifEx.getMessage()
                    );
                }
                try {
                    DocGenSignatureEmailService.sendSignerCompletionEmails(requestId, pdfBlob, fileName);
                } catch (Exception notifEx) {
                    System.debug(
                        LoggingLevel.WARN,
                        'Portwood: Signer completion email failed: ' + notifEx.getMessage()
                    );
                }

                // Clean up temp images
                cleanupTempImages(requestId);
            } catch (Exception e) {
                String errMsg = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
                System.debug(LoggingLevel.ERROR, 'Portwood: Signature PDF failed for ' + req.Id + ': ' + errMsg);
                DocGen_Signature_Audit__c errAudit = new DocGen_Signature_Audit__c();
                errAudit.Signature_Request__c = req.Id;
                errAudit.Signer_Name__c = 'SYSTEM';
                errAudit.Error_Message__c = errMsg;
                errAudit.Signed_Date__c = System.now();
                // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
                DocGenFlsGuard.assertCreateable(
                    errAudit,
                    new Set<String>{ 'Signature_Request__c', 'Signer_Name__c', 'Error_Message__c', 'Signed_Date__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
                // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
                req.Status__c = 'Viewed';
                // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
                DocGenFlsGuard.assertUpdateable(req, new Set<String>{ 'Status__c' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.update(req, false, AccessLevel.SYSTEM_MODE);
            }
        }

        private void cleanupTempImages(Id reqId) {
            try {
                DocGenFlsGuard.assertAccessible(
                    ContentDocumentLink.sObjectType,
                    new Set<String>{ 'ContentDocumentId', 'LinkedEntityId' }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<ContentDocumentLink> tempCdls = [
                    SELECT ContentDocumentId
                    FROM ContentDocumentLink
                    WHERE
                        LinkedEntityId = :reqId
                        AND (ContentDocument.Title LIKE 'docgen_sig_img_%'
                        OR ContentDocument.Title LIKE 'docgen_sig_xml_%')
                    WITH SYSTEM_MODE
                ];
                if (!tempCdls.isEmpty()) {
                    Set<Id> docIds = new Set<Id>();
                    for (ContentDocumentLink cdl : tempCdls)
                        docIds.add(cdl.ContentDocumentId);
                    if (Schema.sObjectType.ContentDocument.isDeletable()) {
                        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                        delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds]; // NOPMD ApexCRUDViolation — CRUD checked above
                    }
                }
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.ERROR,
                    'Portwood: Failed to clean up temp signature images: ' + e.getMessage()
                );
            }
        }
    }

    /**
     * Template-based signature PDF Queueable: single transaction, no DOCX intermediate.
     * Merges template with record data, stamps typed-name signatures into XML, renders PDF.
     */
    // CxSAST: without sharing required for guest user signing context; access gated by cryptographic token
    public class TemplateSignaturePdfQueueable implements Queueable, Database.AllowsCallouts {
        private Id requestId;

        public TemplateSignaturePdfQueueable(Id requestId) {
            this.requestId = requestId;
        }

        public void execute(QueueableContext ctx) {
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{
                    'Template__c',
                    'Template_Ids__c',
                    'Related_Record_Id__c',
                    'Document_Title_Format__c',
                    'Render_Data_Snapshot__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> requests = [
                SELECT
                    Id,
                    Template__c,
                    Template_Ids__c,
                    Related_Record_Id__c,
                    Document_Title_Format__c,
                    Render_Data_Snapshot__c,
                    Frozen_Document_CV_Id__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (requests.isEmpty())
                return;

            DocGen_Signature_Request__c req = requests[0];

            // Signer form fields: resolve preserved {?key} tokens at their template
            // positions during this finalize re-render. The flag is process-static,
            // so flip it true only for this execution and reset in finally (a leaked
            // true would make a later send-time merge resolve {?key} too early). The
            // collected values are aggregated once and injected into the merge data.
            Boolean formFieldsResolvedHere = false;
            Map<String, Object> formValues = DocGenFieldWritebackService.collectValues(requestId);

            try {
                assertRequestPlacementsComplete(requestId);
                DocGenService.resolveFormFields = true;
                formFieldsResolvedHere = true;
                Blob pdfBlob;
                if (Test.isRunningTest()) {
                    pdfBlob = Blob.toPdf('<html><body><p>Test PDF - Signed</p></body></html>');
                } else if (String.isNotBlank(req.Render_Data_Snapshot__c) && req.Template__c != null) {
                    // M2 snapshot-backed: re-render the document from the send-time
                    // data snapshot (not the live record), then append the cert page.
                    Map<String, Object> snap = (Map<String, Object>) JSON.deserializeUntyped(
                        req.Render_Data_Snapshot__c
                    );
                    // M3 — inject the signed-signer loop collection under the reserved
                    // {#Signatures} key. The stored snapshot stays record-data-only, so
                    // these signed rows are re-derived fresh at finalize (keeps M2's
                    // deterministic re-render). Templates without a {#Signatures} block
                    // simply ignore the extra key.
                    snap.put('Signatures', buildSignerLoopData(requestId));
                    // Signer form-field values resolve the preserved {?key} tokens at
                    // their template positions in this re-render. Injected alongside
                    // {#Signatures}; templates without {?key} tags ignore the key.
                    snap.put('__formFields', formValues);
                    // Pass formValues through (5-arg overload) so the signing
                    // certificate's "Form Field Responses" section is populated —
                    // the snap carries __formFields for the {?key} re-render, but the
                    // cert builder reads the formValues param, not the merge data.
                    pdfBlob = renderTemplateSignaturePdf(requestId, req.Template__c, null, snap, formValues);
                } else if (String.isNotBlank(req.Template_Ids__c)) {
                    // Multi-template packet
                    pdfBlob = renderPacketSignaturePdf(
                        requestId,
                        req.Template_Ids__c,
                        req.Related_Record_Id__c,
                        formValues
                    );
                } else {
                    pdfBlob = renderTemplateSignaturePdf(
                        requestId,
                        req.Template__c,
                        req.Related_Record_Id__c,
                        null,
                        formValues
                    );
                }

                DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Name' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<DocGen_Template__c> templates = [
                    SELECT Name
                    FROM DocGen_Template__c
                    WHERE Id = :req.Template__c
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                String fileName = (!templates.isEmpty() ? templates[0].Name : 'Document') + ' - Signed';

                // Optional admin-supplied naming pattern (issue #42). Tokens like
                // {Account.Name} resolve against the related record. Falls back
                // to "<first template> - Signed" when blank or when the related
                // record can't be loaded.
                if (String.isNotBlank(req.Document_Title_Format__c) && String.isNotBlank(req.Related_Record_Id__c)) {
                    try {
                        Map<String, Object> recordData = DocGenService.loadRecordDataForTitle(
                            req.Related_Record_Id__c,
                            req.Document_Title_Format__c
                        );
                        String resolved = DocGenService.generateDocTitle(
                            req.Document_Title_Format__c,
                            recordData != null ? recordData : new Map<String, Object>()
                        );
                        if (String.isNotBlank(resolved)) {
                            fileName = resolved.trim();
                        }
                    } catch (Exception titleErr) {
                        // Title resolution is best-effort — fall back to the default file name
                        System.debug(
                            LoggingLevel.WARN,
                            'Portwood packet title format failed: ' + titleErr.getMessage()
                        );
                    }
                }

                if (String.isNotBlank(req.Related_Record_Id__c)) {
                    ContentVersion pdfCv = new ContentVersion();
                    pdfCv.Title = fileName;
                    pdfCv.PathOnClient = fileName + '.pdf';
                    pdfCv.VersionData = pdfBlob;
                    pdfCv.FirstPublishLocationId = req.Related_Record_Id__c;
                    // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
                    DocGenFlsGuard.assertCreateable(
                        pdfCv,
                        new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId' }
                    );
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    Database.SaveResult cvRes = Database.insert(
                        new List<ContentVersion>{ pdfCv },
                        false,
                        AccessLevel.SYSTEM_MODE
                    )[0];
                    // Surface a silent finalize failure — previously a failed save left the
                    // request "Signed" with NO attached PDF and no trace (the bug Sarah hit:
                    // signing completes but the signed document never appears).
                    if (!cvRes.isSuccess()) {
                        throw new DocGenException(
                            'Signed PDF could not be saved to ' +
                                req.Related_Record_Id__c +
                                ': ' +
                                cvRes.getErrors()[0].getMessage()
                        );
                    }

                    // Signer form-field writeback: publish the decoupled event ONLY
                    // after the signed PDF ContentVersion is saved, so writeback fires
                    // once, post-completion, in the Automated Process context — never
                    // from the guest request and never before the document is final.
                    // The subscriber (DocGenFieldWritebackTrigger) re-derives the
                    // writable allowlist from config and re-checks FLS per field; a
                    // writeback failure is logged, never thrown into this finalize.
                    if (formValues != null && !formValues.isEmpty()) {
                        try {
                            DocGen_Field_Writeback__e wbEvent = new DocGen_Field_Writeback__e();
                            wbEvent.Request_Id__c = requestId;
                            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                            EventBus.publish(wbEvent);
                        } catch (Exception wbEx) {
                            System.debug(
                                LoggingLevel.WARN,
                                'Portwood: field writeback event publish failed: ' + wbEx.getMessage()
                            );
                        }
                    }
                }

                // Update document hash on existing audit records
                String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
                DocGenFlsGuard.assertAccessible(
                    DocGen_Signature_Audit__c.sObjectType,
                    new Set<String>{ 'Signature_Request__c', 'Document_Hash_SHA256__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<DocGen_Signature_Audit__c> audits = [
                    SELECT Id
                    FROM DocGen_Signature_Audit__c
                    WHERE Signature_Request__c = :requestId AND Document_Hash_SHA256__c = NULL
                    WITH SYSTEM_MODE
                ];
                for (DocGen_Signature_Audit__c a : audits) {
                    // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
                    a.Document_Hash_SHA256__c = pdfHash;
                }
                if (!audits.isEmpty()) {
                    // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
                    DocGenFlsGuard.assertUpdateable(audits, new Set<String>{ 'Document_Hash_SHA256__c' });
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    List<Database.SaveResult> auditResults = Database.update(audits, false, AccessLevel.SYSTEM_MODE);
                    for (Integer i = 0; i < auditResults.size(); i++) {
                        requireDmlSuccess(auditResults[i], 'Update signed-document audit hash', audits[i].Id);
                    }
                }

                // Mark signed. #156: reclaim the frozen-snapshot CV (signed PDF produced);
                // Snapshot_Hash__c stays as the retained tamper-evidence.
                // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
                req.Status__c = 'Signed';
                // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
                req.Signature_Data__c = null;
                Id frozenCvToPurge = (Id) req.Frozen_Document_CV_Id__c;
                req.Frozen_Document_CV_Id__c = null;
                // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
                DocGenFlsGuard.assertUpdateable(
                    req,
                    new Set<String>{ 'Status__c', 'Signature_Data__c', 'Frozen_Document_CV_Id__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                requireDmlSuccess(
                    Database.update(req, false, AccessLevel.SYSTEM_MODE),
                    'Complete signature request',
                    req.Id
                );
                purgeFrozenSnapshotCv(frozenCvToPurge);

                // Completion emails (moved here from DocGenSignaturePdfTrigger so the
                // finalized PDF can be attached — it doesn't exist yet in the trigger).
                // Each send is individually guarded: an email failure must never reach
                // the outer catch, which would reset a signed request back to Viewed.
                try {
                    DocGenSignatureEmailService.sendAllSignedNotification(requestId, pdfBlob, fileName);
                } catch (Exception notifEx) {
                    System.debug(
                        LoggingLevel.WARN,
                        'Portwood: All-signed notification failed: ' + notifEx.getMessage()
                    );
                }
                try {
                    DocGenSignatureEmailService.sendSignerCompletionEmails(requestId, pdfBlob, fileName);
                } catch (Exception notifEx) {
                    System.debug(
                        LoggingLevel.WARN,
                        'Portwood: Signer completion email failed: ' + notifEx.getMessage()
                    );
                }
            } catch (Exception e) {
                String errMsg = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
                System.debug(
                    LoggingLevel.ERROR,
                    'Portwood: Template signature PDF failed for ' + req.Id + ': ' + errMsg
                );
                DocGen_Signature_Audit__c errAudit = new DocGen_Signature_Audit__c();
                errAudit.Signature_Request__c = req.Id;
                errAudit.Signer_Name__c = 'SYSTEM';
                errAudit.Error_Message__c = errMsg;
                errAudit.Signed_Date__c = System.now();
                // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
                DocGenFlsGuard.assertCreateable(
                    errAudit,
                    new Set<String>{ 'Signature_Request__c', 'Signer_Name__c', 'Error_Message__c', 'Signed_Date__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
                // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
                req.Status__c = 'Viewed';
                // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
                DocGenFlsGuard.assertUpdateable(req, new Set<String>{ 'Status__c' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.update(req, false, AccessLevel.SYSTEM_MODE);
            } finally {
                // resolveFormFields is process-static — always reset so a later
                // send-time merge in this transaction never resolves {?key} early.
                if (formFieldsResolvedHere) {
                    DocGenService.resolveFormFields = false;
                }
                // reservedMergeData is one-shot (cleared inside mergeTemplate) but
                // reset defensively in case a render path threw before consuming it.
                DocGenService.reservedMergeData = null;
            }
        }

        /**
         * Merges template, stamps typed-name signatures into XML, renders PDF.
         * No DOCX intermediate — pure XML → HTML → PDF.
         */
        private Blob renderTemplateSignaturePdf(Id reqId, Id templateId, String recordId) {
            return renderTemplateSignaturePdf(reqId, templateId, recordId, null, null);
        }

        private Blob renderTemplateSignaturePdf(
            Id reqId,
            Id templateId,
            String recordId,
            Map<String, Object> snapshotData
        ) {
            return renderTemplateSignaturePdf(reqId, templateId, recordId, snapshotData, null);
        }

        /**
         * Renders the template signature PDF from a point-in-time snapshot rather than a
         * live re-merge, so the signed PDF matches what the signer reviewed even if the
         * source record changed after send. Two snapshot mechanisms, in priority order:
         *   1. snapshotData != null (PDF-viewer flow, Render_Data_Snapshot__c) — re-merge
         *      the template against the frozen send-time DATA.
         *   2. Frozen_Document__c present (classic flow) — render the frozen document BODY
         *      directly, with no re-merge at all.
         *   3. Neither (legacy/oversized requests) — fall back to a live merge.
         * All downstream processing (image/style hydration, placement stamping,
         * certificate-page injection, Blob.toPdf) is identical regardless of source.
         */
        private Blob renderTemplateSignaturePdf(
            Id reqId,
            Id templateId,
            String recordId,
            Map<String, Object> snapshotData,
            Map<String, Object> formValues
        ) {
            // Load the request cache: the frozen document body (classic-flow snapshot) +
            // the image/style maps. One query serves both.
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{ 'Signature_Data__c', 'Frozen_Document__c', 'Frozen_Document_CV_Id__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            DocGen_Signature_Request__c reqData = [
                SELECT Signature_Data__c, Frozen_Document__c, Frozen_Document_CV_Id__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :reqId
                WITH SYSTEM_MODE
                LIMIT 1
            ];

            Map<String, Object> mergeData;
            if (snapshotData != null) {
                // PDF-viewer flow: re-merge from the send-time data snapshot. The
                // snapshot already carries '__formFields' (injected by the queueable),
                // so the {?key} tokens resolve during this re-merge.
                mergeData = DocGenService.mergeTemplateForSignatureFromData(templateId, snapshotData);
            } else {
                // Classic flow: render the frozen document body with no re-merge. #156: the
                // snapshot is CV-backed (no size cap); the legacy inline field is the fallback.
                // Only genuinely legacy/snapshot-less requests fall through to a live merge.
                List<Map<String, Object>> frozenDocs = resolveFrozenMergeData(reqData);
                if (frozenDocs != null && !frozenDocs.isEmpty()) {
                    // Frozen body: {?key} tokens were preserved at send-time and the
                    // frozen XML is not re-merged here, so they cannot resolve on this
                    // path (documented limitation — form fields target the snapshot
                    // re-render path).
                    mergeData = frozenDocs[0];
                } else {
                    // Live re-merge: surface the collected form-field values under
                    // '__formFields' for this one mergeTemplate call so {?key} resolves.
                    DocGenService.reservedMergeData = formValues;
                    mergeData = DocGenService.mergeTemplateForSignature(templateId, recordId);
                }
            }

            String documentXml = (String) mergeData.get('combinedDocumentXml');
            if (String.isBlank(documentXml)) {
                documentXml = (String) mergeData.get('documentXml');
            }
            String relsXml = (String) mergeData.get('relsXml');
            String contentTypesXml = (String) mergeData.get('contentTypesXml');
            Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
            String templateType = (String) mergeData.get('templateType');
            if (String.isNotBlank(reqData.Signature_Data__c)) {
                Map<String, Object> cachedData = (Map<String, Object>) JSON.deserializeUntyped(
                    reqData.Signature_Data__c
                );
                Object imgMapObj = cachedData.get('imageMap');
                if (imgMapObj instanceof Map<String, Object>) {
                    Map<String, Object> cachedMap = (Map<String, Object>) imgMapObj;
                    for (String relId : cachedMap.keySet()) {
                        if (!pdfImageMap.containsKey(relId)) {
                            pdfImageMap.put(relId, (String) cachedMap.get(relId));
                        }
                    }
                }
                // 1.49 (#28): hydrate the style maps cached at request creation.
                // Async context (Automated Process user) can't re-query the pre-decomposed
                // styles.xml ContentVersion, so the renderer falls back to these maps for
                // table borders + text attributes (color, font, size, bold, italic).
                Object bordersObj = cachedData.get('tableBordersMap');
                if (bordersObj instanceof Map<String, Object>) {
                    Map<String, String> borders = new Map<String, String>();
                    for (String k : ((Map<String, Object>) bordersObj).keySet()) {
                        borders.put(k, (String) ((Map<String, Object>) bordersObj).get(k));
                    }
                    DocGenHtmlRenderer.tableStyleBorderMap = borders;
                }
                Object textAttrsObj = cachedData.get('styleTextAttrsMap');
                if (textAttrsObj instanceof Map<String, Object>) {
                    Map<String, Map<String, String>> textAttrs = new Map<String, Map<String, String>>();
                    Map<String, Object> raw = (Map<String, Object>) textAttrsObj;
                    for (String styleName : raw.keySet()) {
                        Object attrsObj = raw.get(styleName);
                        if (attrsObj instanceof Map<String, Object>) {
                            Map<String, String> attrs = new Map<String, String>();
                            Map<String, Object> attrsRaw = (Map<String, Object>) attrsObj;
                            for (String k : attrsRaw.keySet())
                                attrs.put(k, (String) attrsRaw.get(k));
                            textAttrs.put(styleName, attrs);
                        }
                    }
                    DocGenHtmlRenderer.styleTextAttrsMap = textAttrs;
                }
            }

            // Get signer typed names
            DocGenFlsGuard.assertAccessible(
                DocGen_Signer__c.sObjectType,
                new Set<String>{
                    'Role_Name__c',
                    'Signature_Data__c',
                    'Signature_Request__c',
                    'Status__c',
                    'Sort_Order__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signer__c> signers = [
                SELECT Id, Role_Name__c, Signature_Data__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
                ORDER BY Sort_Order__c ASC
            ];

            List<SignerImageData> signerImages = new List<SignerImageData>();
            for (DocGen_Signer__c s : signers) {
                String role = String.isNotBlank(s.Role_Name__c) ? s.Role_Name__c : 'Signer';
                signerImages.add(new SignerImageData(role, s.Signature_Data__c, System.now()));
            }

            // Query placements for stamping
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Placement__c.sObjectType,
                new Set<String>{
                    'Signer__c',
                    'Placement_Type__c',
                    'Sequence_Order__c',
                    'Signed_Value__c',
                    'Status__c',
                    'Signed_At__c',
                    'Tag_Text__c',
                    'Document_Index__c',
                    'Signature_Request__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Placement__c> placements = [
                SELECT
                    Id,
                    Signer__c,
                    Placement_Type__c,
                    Sequence_Order__c,
                    Signed_Value__c,
                    Status__c,
                    Signed_At__c,
                    Tag_Text__c,
                    Document_Index__c
                FROM DocGen_Signature_Placement__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
                ORDER BY Document_Index__c ASC, Sequence_Order__c ASC
            ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets

            // Oversized/legacy requests (no Frozen_Document__c) reached this point via a
            // LIVE re-merge (or a data-snapshot re-merge), so the body carries the ORIGINAL
            // {@Signature_*} tags rather than the @@SIG-n@@ sentinels the placements key on.
            // Re-apply the send-time substitution so stampSignaturesInXml/InHtml match lands;
            // the frozen-body path already carries sentinels (no-op there). Without this,
            // signatures silently never stamp on templates whose snapshot exceeds the freeze cap.
            documentXml = DocGenSignatureSenderController.resentinelSignatureBody(documentXml);

            String html;
            if (DocGenService.isHtmlBacked(templateType)) {
                html = stampSignaturesInHtml(documentXml, placements);
            } else {
                // Stamp typed-name signatures into merged XML
                StampResult stamped = stampSignaturesInXml(
                    documentXml,
                    relsXml,
                    contentTypesXml,
                    signerImages,
                    placements
                );

                // Re-prime the HTML renderer context immediately before convertToHtml.
                DocGenHtmlRenderer.stylesXml = (String) mergeData.get('stylesXml');
                DocGenHtmlRenderer.numberingXml = (String) mergeData.get('numberingXml');
                DocGenService.applyWatermarkOverride(templateId);

                // Render PDF with template images only (no signature images needed)
                html = DocGenHtmlRenderer.convertToHtml(stamped.documentXml, pdfImageMap);
            }

            // Append verification certificate block before closing body
            DocGenFlsGuard.assertAccessible(
                DocGen_Signer__c.sObjectType,
                new Set<String>{
                    'Signer_Name__c',
                    'Signature_Data__c',
                    'Signer_Email__c',
                    'Role_Name__c',
                    'PIN_Verified_At__c',
                    'Signature_Request__c',
                    'Status__c',
                    'Sort_Order__c',
                    'Field_Data_Json__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signer__c> fullSigners = [
                SELECT
                    Signer_Name__c,
                    Signature_Data__c,
                    Signer_Email__c,
                    Role_Name__c,
                    PIN_Verified_At__c,
                    Field_Data_Json__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
                ORDER BY Sort_Order__c ASC
            ];
            String verifyBlock = buildVerificationBlockHtml(
                reqId,
                fullSigners,
                loadCertFieldDefs(templateId),
                formValues
            );
            html = injectVerifyBlockBeforeLastBody(html, verifyBlock);

            assertNoUnresolvedSignatureSentinels(html);

            return Blob.toPdf(html);
        }

        /**
         * Renders a multi-template packet as a single signed PDF.
         * Merges each template, stamps placements per document, concatenates HTML with page breaks.
         */
        private Blob renderPacketSignaturePdf(
            Id reqId,
            String templateIdsJson,
            String recordId,
            Map<String, Object> formValues
        ) {
            List<Object> rawIds = (List<Object>) JSON.deserializeUntyped(templateIdsJson);
            List<Id> templateIds = new List<Id>();
            for (Object o : rawIds)
                templateIds.add((Id) o);

            // Query template names for document headers
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Name' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Map<Id, DocGen_Template__c> templateMap = new Map<Id, DocGen_Template__c>(
                [SELECT Id, Name FROM DocGen_Template__c WHERE Id IN :templateIds WITH SYSTEM_MODE]
            ); // NOPMD

            // Query all placements for this request
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Placement__c.sObjectType,
                new Set<String>{
                    'Signer__c',
                    'Placement_Type__c',
                    'Sequence_Order__c',
                    'Signed_Value__c',
                    'Status__c',
                    'Signed_At__c',
                    'Tag_Text__c',
                    'Document_Index__c',
                    'Signature_Request__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Placement__c> allPlacements = [
                SELECT
                    Id,
                    Signer__c,
                    Placement_Type__c,
                    Sequence_Order__c,
                    Signed_Value__c,
                    Status__c,
                    Signed_At__c,
                    Tag_Text__c,
                    Document_Index__c
                FROM DocGen_Signature_Placement__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
                ORDER BY Document_Index__c ASC, Sequence_Order__c ASC
            ]; // NOPMD

            // Query signers for placement stamping (roles + typed names)
            DocGenFlsGuard.assertAccessible(
                DocGen_Signer__c.sObjectType,
                new Set<String>{
                    'Role_Name__c',
                    'Signature_Data__c',
                    'Signature_Request__c',
                    'Status__c',
                    'Sort_Order__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signer__c> signers = [
                SELECT Id, Role_Name__c, Signature_Data__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
                ORDER BY Sort_Order__c ASC
            ]; // NOPMD
            List<SignerImageData> signerImages = new List<SignerImageData>();
            for (DocGen_Signer__c s : signers) {
                signerImages.add(
                    new SignerImageData(
                        String.isNotBlank(s.Role_Name__c) ? s.Role_Name__c : 'Signer',
                        s.Signature_Data__c,
                        System.now()
                    )
                );
            }

            // Get cached image map
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{ 'Signature_Data__c', 'Frozen_Document__c', 'Frozen_Document_CV_Id__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            DocGen_Signature_Request__c reqData = [
                SELECT Signature_Data__c, Frozen_Document__c, Frozen_Document_CV_Id__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :reqId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD
            Map<String, String> cachedImageMap = new Map<String, String>();
            if (String.isNotBlank(reqData.Signature_Data__c)) {
                Map<String, Object> cachedData = (Map<String, Object>) JSON.deserializeUntyped(
                    reqData.Signature_Data__c
                );
                Object imgMapObj = cachedData.get('imageMap');
                if (imgMapObj instanceof Map<String, Object>) {
                    for (String k : ((Map<String, Object>) imgMapObj).keySet()) {
                        cachedImageMap.put(k, (String) ((Map<String, Object>) imgMapObj).get(k));
                    }
                }
            }

            // INTEGRITY: each document renders from its frozen snapshot (captured at
            // creation), not a live re-merge. Aligned to templateIds by index. Null when
            // no snapshot exists (legacy snapshot-less packet) → per-doc live-merge fallback.
            // #156: CV-backed snapshot preferred, legacy inline field is the fallback.
            List<Map<String, Object>> frozenDocs = resolveFrozenMergeData(reqData);

            // Merge and stamp each document
            List<String> htmlParts = new List<String>();
            for (Integer docIdx = 0; docIdx < templateIds.size(); docIdx++) {
                Id tid = templateIds[docIdx];
                Map<String, Object> mergeData;
                if (frozenDocs != null && docIdx < frozenDocs.size()) {
                    // Frozen body: {?key} preserved, not re-merged (documented limitation).
                    mergeData = frozenDocs[docIdx];
                } else {
                    // Live re-merge for this template — inject form-field values so
                    // {?key} resolves. reservedMergeData is one-shot (cleared inside
                    // mergeTemplate), so set it fresh before each per-template merge.
                    DocGenService.reservedMergeData = formValues;
                    mergeData = DocGenService.mergeTemplateForSignature(tid, recordId);
                }
                String documentXml = (String) mergeData.get('combinedDocumentXml');
                if (String.isBlank(documentXml)) {
                    documentXml = (String) mergeData.get('documentXml');
                }
                String relsXml = (String) mergeData.get('relsXml');
                String contentTypesXml = (String) mergeData.get('contentTypesXml');
                Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
                String templateType = (String) mergeData.get('templateType');
                pdfImageMap.putAll(cachedImageMap);

                // Filter placements for this document
                List<DocGen_Signature_Placement__c> docPlacements = new List<DocGen_Signature_Placement__c>();
                for (DocGen_Signature_Placement__c p : allPlacements) {
                    if (p.Document_Index__c == docIdx)
                        docPlacements.add(p);
                }

                // See the single-template finalizer: a per-template live re-merge (no frozen
                // snapshot) carries the ORIGINAL {@Signature_*} tags, so re-apply the send-time
                // @@SIG-n@@ sentinel substitution before stamping. No-op on the frozen path.
                documentXml = DocGenSignatureSenderController.resentinelSignatureBody(documentXml);

                String docHtml;
                if (DocGenService.isHtmlBacked(templateType)) {
                    docHtml = stampSignaturesInHtml(documentXml, docPlacements);
                } else {
                    StampResult stamped = stampSignaturesInXml(
                        documentXml,
                        relsXml,
                        contentTypesXml,
                        signerImages,
                        docPlacements
                    );
                    // Re-prime renderer context for this document (see #28 — statics don't survive
                    // intermediate calls reliably in async context).
                    DocGenHtmlRenderer.stylesXml = (String) mergeData.get('stylesXml');
                    DocGenHtmlRenderer.numberingXml = (String) mergeData.get('numberingXml');
                    DocGenService.applyWatermarkOverride(tid);
                    docHtml = DocGenHtmlRenderer.convertToHtml(stamped.documentXml, pdfImageMap);
                }

                if (docIdx > 0) {
                    htmlParts.add('<div style="page-break-before:always"></div>');
                }
                htmlParts.add(docHtml);
            }

            String fullHtml = String.join(htmlParts, '');

            // Append verification block
            DocGenFlsGuard.assertAccessible(
                DocGen_Signer__c.sObjectType,
                new Set<String>{
                    'Signer_Name__c',
                    'Signature_Data__c',
                    'Signer_Email__c',
                    'Role_Name__c',
                    'PIN_Verified_At__c',
                    'Signature_Request__c',
                    'Status__c',
                    'Sort_Order__c',
                    'Field_Data_Json__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signer__c> fullSigners = [
                SELECT
                    Signer_Name__c,
                    Signature_Data__c,
                    Signer_Email__c,
                    Role_Name__c,
                    PIN_Verified_At__c,
                    Field_Data_Json__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :reqId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
                ORDER BY Sort_Order__c ASC
            ]; // NOPMD
            // Form fields are template-scoped — for a packet, list the first
            // template's flagged fields on the single shared certificate.
            String verifyBlock = buildVerificationBlockHtml(
                reqId,
                fullSigners,
                loadCertFieldDefs(templateIds.isEmpty() ? null : templateIds[0]),
                formValues
            );
            // injectVerifyBlockBeforeLastBody handles the multi-</body> case —
            // packet HTML has one </body> per template, so String.replace would
            // drop the verification block after every template (the v1.77 bug).
            fullHtml = injectVerifyBlockBeforeLastBody(fullHtml, verifyBlock);

            assertNoUnresolvedSignatureSentinels(fullHtml);

            return Blob.toPdf(fullHtml);
        }
    }
}
