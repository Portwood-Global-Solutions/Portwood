/**
 * DocGenButtonController
 * -----------------------
 * Backs the docGenButton quick action. Resolves a pre-configured template from the
 * DocGen_Button__mdt custom metadata type, generates the document through the Portwood
 * service layer, and returns the file to the browser for download (and, optionally,
 * attaches it to the record).
 *
 * Generation goes through DocGenService.generateDocument(...) — the same service
 * entry DocGenFlowAction uses internally — then the resulting ContentVersion is read
 * back and returned to the client either as a base64 payload (small files with an
 * LWS-safe MIME type: PDF, images, text) or as a file-servlet download URL (everything
 * else, including Office formats that Lightning Web Security blocks for Blob URLs).
 *
 * Delivery_Mode__c controls what the LWC does with the file: DOWNLOAD (default,
 * blank, or unrecognized), PREVIEW (open the native file preview, no download), or
 * PREVIEW_AND_DOWNLOAD. Preview uses the ContentDocumentId, so a preview-only
 * button skips reading VersionData into heap.
 *
 * The generation call is isolated behind the Generator seam so the full controller
 * flow can be unit-tested without invoking real document rendering.
 */
public with sharing class DocGenButtonController {
    /** Files at/under this byte size are returned inline as base64 for a direct
     *  client-side download. Larger files fall back to the download servlet URL to
     *  stay within Apex heap. Not final so tests can exercise both branches. */
    @TestVisible
    private static Integer inlineDownloadMaxBytes = 3500000; // ~3.5 MB

    /** Normalized Delivery_Mode__c values returned to the LWC. */
    public static final String DELIVERY_DOWNLOAD = 'DOWNLOAD';
    public static final String DELIVERY_PREVIEW = 'PREVIEW';
    public static final String DELIVERY_PREVIEW_AND_DOWNLOAD = 'PREVIEW_AND_DOWNLOAD';

    /** Cap on recipients per Send Email action (manual entry included). */
    @TestVisible
    private static final Integer MAX_EMAIL_RECIPIENTS = 10;

    public class DocGenButtonException extends Exception {
    }

    // ---------------------------------------------------------------------
    // Generation seam (lets tests run the controller without real rendering)
    // ---------------------------------------------------------------------
    public interface Generator {
        GenResult generate(GenRequest req);
    }

    public class GenRequest {
        public Id templateId;
        public Id recordId;
        public Boolean saveToRecord;
        public String documentTitle;
        public String outputFormatOverride;
    }

    public class GenResult {
        public Id contentDocumentId;
        public Id contentVersionId;
        public Boolean success;
        public String errorMessage;
    }

    /** Default generator: delegates to the Portwood service layer. */
    public class ServiceGenerator implements Generator {
        public GenResult generate(GenRequest r) {
            GenResult out = new GenResult();
            try {
                // attachmentRecordId = recordId links the file to the record (Files
                // related list); null produces a standalone ContentVersion that is
                // still downloadable via the returned ContentDocumentId.
                Id attachmentRecordId = (r.saveToRecord == true) ? r.recordId : null;
                Id contentDocumentId = DocGenService.generateDocument(
                    r.templateId,
                    r.recordId,
                    r.outputFormatOverride,
                    r.documentTitle,
                    attachmentRecordId
                );
                out.contentDocumentId = contentDocumentId;
                out.success = (contentDocumentId != null);
                if (!out.success) {
                    out.errorMessage = 'Portwood did not return a document.';
                }
            } catch (Exception e) {
                out.success = false;
                out.errorMessage = e.getMessage();
            }
            return out;
        }
    }

    @TestVisible
    private static Generator generator = new ServiceGenerator();

    /** Optional test override of the config source. Custom metadata records cannot
     *  be inserted via DML in tests, so tests inject rows here instead of querying. */
    @TestVisible
    private static List<DocGen_Button__mdt> configOverride;

    // ---------------------------------------------------------------------
    // LWC-facing DTOs
    // ---------------------------------------------------------------------
    public class ButtonOption {
        @AuraEnabled
        public String developerName;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String templateName;
    }

    public class GenerateResultDTO {
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String errorMessage;
        @AuraEnabled
        public String fileName;
        @AuraEnabled
        public String mimeType;
        @AuraEnabled
        public String base64Data; // populated for small files
        @AuraEnabled
        public String downloadUrl; // populated for large files
        @AuraEnabled
        public Id contentDocumentId;
        @AuraEnabled
        public Id contentVersionId;
        @AuraEnabled
        public String deliveryMode; // DOWNLOAD | PREVIEW | PREVIEW_AND_DOWNLOAD
    }

    public class EmailCandidate {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;
    }

    public class EmailTemplateOption {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;
    }

    public class SendEmailResultDTO {
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String errorMessage;
        @AuraEnabled
        public String fileName;
        @AuraEnabled
        public Id contentDocumentId;
        @AuraEnabled
        public Id contentVersionId;
    }

    // ---------------------------------------------------------------------
    // Public API (called from the LWC)
    // ---------------------------------------------------------------------

    /** Returns the active button configurations for the record's object so the LWC
     *  can auto-run a single button or present a small picker for several.
     *  Takes recordId (always injected into quick actions) and derives the object
     *  API name server-side from the Id — quick actions don't reliably inject
     *  objectApiName before connectedCallback, and this also removes any
     *  namespace/case/whitespace mismatch. Not cacheable: config reads happen once
     *  per click and caching would let a stale/empty result persist. */
    @AuraEnabled
    public static List<ButtonOption> getButtons(Id recordId) {
        return getButtonsForAction(recordId, 'Document');
    }

    @AuraEnabled
    public static List<ButtonOption> getEmailButtons(Id recordId) {
        return getButtonsForAction(recordId, 'Email');
    }

    private static List<ButtonOption> getButtonsForAction(Id recordId, String actionType) {
        List<ButtonOption> options = new List<ButtonOption>();
        if (recordId == null) {
            return options;
        }
        String objectApiName = recordId.getSObjectType().getDescribe().getName();
        String rtDevName = recordTypeDevName(recordId);
        List<DocGen_Button__mdt> matchedConfigs = new List<DocGen_Button__mdt>();
        for (DocGen_Button__mdt cfg : loadConfigs(objectApiName)) {
            if (
                normalizeActionType(cfg.Action_Type__c) != normalizeActionType(actionType) ||
                !matchesRecordType(cfg, rtDevName)
            ) {
                continue;
            }
            matchedConfigs.add(cfg);
        }
        Map<String, String> templateNames = templateNamesByConfig(matchedConfigs);
        for (DocGen_Button__mdt cfg : matchedConfigs) {
            ButtonOption opt = new ButtonOption();
            opt.developerName = cfg.DeveloperName;
            opt.label = String.isNotBlank(cfg.MasterLabel) ? cfg.MasterLabel : cfg.DeveloperName;
            opt.templateName = templateNames.containsKey(cfg.DeveloperName)
                ? templateNames.get(cfg.DeveloperName)
                : templateLabel(cfg);
            options.add(opt);
        }
        return options;
    }

    /** Generates the document for the chosen configuration and returns it for download. */
    @AuraEnabled
    public static GenerateResultDTO generate(Id recordId, String configDeveloperName) {
        GenerateResultDTO dto = new GenerateResultDTO();
        try {
            DocGen_Button__mdt cfg = getConfig(configDeveloperName);
            if (cfg == null) {
                throw new DocGenButtonException(
                    'No active Portwood Button configuration named "' + configDeveloperName + '".'
                );
            }
            // Enforce the object + record-type match here too — getButtons hides a
            // mismatched button, but generate is directly callable, so the display
            // filter alone can be bypassed.
            if (normalizeActionType(cfg.Action_Type__c) != 'Document') {
                throw new DocGenButtonException(
                    'Portwood Button "' + configDeveloperName + '" is not a document-generation button.'
                );
            }
            String recObject = recordId.getSObjectType().getDescribe().getName();
            if (String.isNotBlank(cfg.Object_API_Name__c) && cfg.Object_API_Name__c != recObject) {
                throw new DocGenButtonException(
                    'Portwood Button "' +
                        configDeveloperName +
                        '" is configured for ' +
                        cfg.Object_API_Name__c +
                        ' records, not ' +
                        recObject +
                        '.'
                );
            }
            if (!matchesRecordType(cfg, recordTypeDevName(recordId))) {
                throw new DocGenButtonException(
                    'Portwood Button "' + configDeveloperName + '" is not available for this record\'s record type.'
                );
            }
            if (String.isBlank(cfg.Template_Id__c) && String.isBlank(cfg.Template_API_Name__c)) {
                throw new DocGenButtonException(
                    'Portwood Button "' +
                        configDeveloperName +
                        '" has no template configured. Set Template Id or Template API Name.'
                );
            }

            Id templateId;
            if (String.isNotBlank(cfg.Template_Id__c)) {
                try {
                    templateId = (Id) cfg.Template_Id__c;
                } catch (Exception idEx) {
                    throw new DocGenButtonException(
                        'Portwood Button "' +
                            configDeveloperName +
                            '" has an invalid Template Id (' +
                            cfg.Template_Id__c +
                            '). Set it to a Portwood Template record Id, or use Template API Name.'
                    );
                }
            } else {
                // Environment-stable key (PHD-9) — same value in sandbox and production.
                templateId = DocGenService.templateIdByApiName(cfg.Template_API_Name__c);
            }

            GenRequest gReq = new GenRequest();
            gReq.templateId = templateId;
            gReq.recordId = recordId;
            gReq.saveToRecord = cfg.Save_To_Record__c == true;
            gReq.documentTitle = cfg.Document_Title__c;
            gReq.outputFormatOverride = normalizeOutputFormatOverride(cfg.Output_Format_Override__c);

            GenResult res = generator.generate(gReq);
            if (res == null || res.success != true) {
                throw new DocGenButtonException(
                    (res != null && String.isNotBlank(res.errorMessage))
                        ? res.errorMessage
                        : 'Document generation failed.'
                );
            }

            Id cvId = res.contentVersionId;
            if (cvId == null && res.contentDocumentId != null) {
                List<ContentVersion> latest = [
                    SELECT Id
                    FROM ContentVersion
                    WHERE ContentDocumentId = :res.contentDocumentId
                    WITH USER_MODE
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ];
                if (!latest.isEmpty()) {
                    cvId = latest[0].Id;
                }
            }
            if (cvId == null) {
                throw new DocGenButtonException('The document was generated but no file reference was returned.');
            }

            List<ContentVersion> cvs = [
                SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :cvId
                WITH USER_MODE
                LIMIT 1
            ];
            if (cvs.isEmpty()) {
                throw new DocGenButtonException(
                    'Generated file could not be read back. Check file sharing/visibility.'
                );
            }
            ContentVersion cv = cvs[0];

            dto.success = true;
            dto.deliveryMode = normalizeDeliveryMode(cfg.Delivery_Mode__c);
            dto.contentVersionId = cv.Id;
            dto.contentDocumentId = cv.ContentDocumentId;
            dto.fileName = buildFileName(cv);
            dto.mimeType = mimeFor(cv.FileExtension);

            // Always provide a file-servlet download URL. It works for every MIME type
            // and any size, and sidesteps Lightning Web Security's Blob/createObjectURL
            // MIME allowlist (which rejects Office formats like .docx/.pptx/.xlsx).
            dto.downloadUrl = '/sfc/servlet.shepherd/version/download/' + cv.Id;

            // Also return base64 for small files. The LWC uses the Blob path only for
            // LWS-safe MIME types (PDF, images, text) and otherwise uses downloadUrl.
            // A preview-only button never downloads, so skip loading VersionData.
            Boolean needsDownload = dto.deliveryMode != DELIVERY_PREVIEW;
            if (needsDownload && cv.ContentSize != null && cv.ContentSize <= inlineDownloadMaxBytes) {
                List<ContentVersion> withData = [
                    SELECT VersionData
                    FROM ContentVersion
                    WHERE Id = :cv.Id
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!withData.isEmpty() && withData[0].VersionData != null) {
                    dto.base64Data = EncodingUtil.base64Encode(withData[0].VersionData);
                }
            }

            return dto;
        } catch (Exception e) {
            dto.success = false;
            dto.errorMessage = e.getMessage();
            return dto;
        }
    }

    public static String getEmailPreviewHtml(Id recordId, String configDeveloperName) {
        return getEmailPreviewHtml(recordId, configDeveloperName, null);
    }

    @AuraEnabled
    public static String getEmailPreviewHtml(Id recordId, String configDeveloperName, String templateReference) {
        try {
            DocGen_Button__mdt cfg = validateConfig(recordId, configDeveloperName, 'Email');
            Id templateId = resolveEmailTemplateId(cfg, configDeveloperName, templateReference, recordId);
            String html = DocGenSignatureSenderController.getDocumentPreviewHtml(templateId, String.valueOf(recordId));
            return String.isBlank(html) ? previewFallback('Preview is unavailable for this template.') : html;
        } catch (Exception e) {
            return previewFallback('Preview is unavailable: ' + e.getMessage());
        }
    }

    /**
     * Templates the user may pick for this Email button on this record. A button that pins a
     * template offers only that one; otherwise only active templates built for the record's own
     * object are offered. Not cacheable: the answer depends on the record and the button.
     */
    @AuraEnabled
    public static List<EmailTemplateOption> getEmailTemplateOptions(Id recordId, String configDeveloperName) {
        List<EmailTemplateOption> out = new List<EmailTemplateOption>();
        DocGen_Button__mdt cfg = validateConfig(recordId, configDeveloperName, 'Email');
        String recObject = recordId.getSObjectType().getDescribe().getName();
        Id pinnedId = hasConfiguredTemplate(cfg) ? resolveTemplateId(cfg, configDeveloperName, null) : null;
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Name', 'API_Name__c', 'Base_Object_API__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexCRUDViolation ApexFlsViolation */
        for (DocGen_Template__c t : [
            SELECT Id, Name, API_Name__c
            FROM DocGen_Template__c
            WHERE Is_Active__c = TRUE AND Base_Object_API__c = :recObject
            WITH SYSTEM_MODE
            ORDER BY Name
        ]) {
            if (pinnedId != null && t.Id != pinnedId) {
                continue;
            }
            EmailTemplateOption option = new EmailTemplateOption();
            option.label = t.Name;
            option.value = String.isNotBlank(t.API_Name__c) ? 'key:' + t.API_Name__c : 'id:' + t.Id;
            out.add(option);
        }
        return out;
    }

    @AuraEnabled
    public static List<EmailCandidate> getEmailCandidates(Id recordId) {
        List<EmailCandidate> out = new List<EmailCandidate>();
        if (recordId == null) {
            return out;
        }
        Schema.DescribeSObjectResult d = recordId.getSObjectType().getDescribe();
        Map<String, Schema.SObjectField> fields = d.fields.getMap();
        List<String> emailFields = new List<String>();
        for (String fieldName : fields.keySet()) {
            Schema.DescribeFieldResult f = fields.get(fieldName).getDescribe();
            if (f.getType() == Schema.DisplayType.Email && f.isAccessible()) {
                emailFields.add(f.getName());
            }
        }
        if (emailFields.isEmpty()) {
            return out;
        }
        emailFields.sort();
        String soql =
            'SELECT ' +
            String.join(emailFields, ',') +
            ' FROM ' +
            d.getName() +
            ' WHERE Id = :recordId LIMIT 1';
        /* code-analyzer-suppress ApexFlsViolation */
        List<SObject> rows = Database.query(soql, AccessLevel.USER_MODE);
        if (rows.isEmpty()) {
            return out;
        }
        for (String fieldName : emailFields) {
            String email = (String) rows[0].get(fieldName);
            if (String.isBlank(email)) {
                continue;
            }
            EmailCandidate candidate = new EmailCandidate();
            candidate.label = fields.get(fieldName).getDescribe().getLabel() + ' - ' + email;
            candidate.value = email;
            out.add(candidate);
        }
        return out;
    }

    public static SendEmailResultDTO sendGeneratedEmail(
        Id recordId,
        String configDeveloperName,
        List<String> toAddresses,
        String subject,
        String body
    ) {
        return sendGeneratedEmail(recordId, configDeveloperName, null, toAddresses, subject, body);
    }

    @AuraEnabled
    public static SendEmailResultDTO sendGeneratedEmail(
        Id recordId,
        String configDeveloperName,
        String templateReference,
        List<String> toAddresses,
        String subject,
        String body
    ) {
        SendEmailResultDTO dto = new SendEmailResultDTO();
        try {
            if (recordId == null) {
                throw new DocGenButtonException('No record was provided.');
            }
            if (String.isBlank(subject)) {
                throw new DocGenButtonException('Enter an email subject.');
            }
            if (String.isBlank(body)) {
                throw new DocGenButtonException('Enter an email body.');
            }
            List<String> recipients = normalizeEmails(toAddresses);
            if (recipients.isEmpty()) {
                throw new DocGenButtonException('Choose or enter at least one recipient email address.');
            }

            DocGen_Button__mdt cfg = validateConfig(recordId, configDeveloperName, 'Email');
            Id templateId = resolveEmailTemplateId(cfg, configDeveloperName, templateReference, recordId);

            GenRequest gReq = new GenRequest();
            gReq.templateId = templateId;
            gReq.recordId = recordId;
            gReq.saveToRecord = true;
            gReq.documentTitle = cfg.Document_Title__c;
            gReq.outputFormatOverride = cfg.Output_Format_Override__c;

            GenResult res = generator.generate(gReq);
            if (res == null || res.success != true) {
                throw new DocGenButtonException(
                    (res != null && String.isNotBlank(res.errorMessage))
                        ? res.errorMessage
                        : 'Document generation failed.'
                );
            }
            ContentVersion cv = latestVersion(res);
            ContentVersion withData = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Id = :cv.Id
                WITH USER_MODE
                LIMIT 1
            ];

            Messaging.EmailFileAttachment attachment = new Messaging.EmailFileAttachment();
            attachment.setFileName(buildFileName(cv));
            attachment.setContentType(mimeFor(cv.FileExtension));
            attachment.setBody(withData.VersionData);

            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setToAddresses(recipients);
            msg.setSubject(stripHtml(subject));
            msg.setHtmlBody(body);
            msg.setFileAttachments(new List<Messaging.EmailFileAttachment>{ attachment });
            // Send from the sender the admin configured for Portwood when there is one; otherwise
            // as the running user. Never guess an org-wide address the admin did not choose.
            Id configuredSenderId = configuredOrgWideEmailAddressId();
            if (configuredSenderId != null) {
                msg.setOrgWideEmailAddressId(configuredSenderId);
            }
            if (!Test.isRunningTest()) {
                Messaging.SendEmailResult[] sendResults = Messaging.sendEmail(new List<Messaging.Email>{ msg }, false);
                if (sendResults == null || sendResults.isEmpty() || sendResults[0].isSuccess() != true) {
                    throw new DocGenButtonException(buildSendEmailError(sendResults));
                }
            }

            dto.success = true;
            dto.fileName = buildFileName(cv);
            dto.contentVersionId = cv.Id;
            dto.contentDocumentId = cv.ContentDocumentId;
            return dto;
        } catch (Exception e) {
            dto.success = false;
            dto.errorMessage = e.getMessage();
            return dto;
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /** Developer name of the record's RecordType, or null when the object has no
     *  record types or the record is on the master type. Guards the describe so a
     *  dynamic query never runs against an object without a RecordTypeId field. */
    @TestVisible
    private static String recordTypeDevName(Id recordId) {
        if (recordId == null) {
            return null;
        }
        Schema.DescribeSObjectResult d = recordId.getSObjectType().getDescribe();
        if (!d.fields.getMap().containsKey('RecordTypeId')) {
            return null;
        }
        // AccessLevel.USER_MODE enforces object + FLS at runtime; the read is
        // limited to RecordType.DeveloperName on the record the user is acting on.
        // Graph Engine can't resolve fields inside a dynamic query string, so it
        // false-positives ApexFlsViolation here — suppress with the runtime guard
        // documented above.
        /* code-analyzer-suppress ApexFlsViolation */
        List<SObject> rows = Database.query(
            'SELECT RecordType.DeveloperName FROM ' + d.getName() + ' WHERE Id = :recordId LIMIT 1',
            AccessLevel.USER_MODE
        );
        if (rows.isEmpty()) {
            return null;
        }
        SObject rt = rows[0].getSObject('RecordType');
        return rt == null ? null : (String) rt.get('DeveloperName');
    }

    /** True when the config applies to the record's record type. A blank
     *  Record_Type_Developer_Names__c means "all record types" (backward
     *  compatible). Otherwise the record's record-type developer name must appear
     *  in the comma-separated list (case-insensitive); a record with no record
     *  type never matches a config that names specific ones. */
    @TestVisible
    private static Boolean matchesRecordType(DocGen_Button__mdt cfg, String rtDevName) {
        String allowed = cfg == null ? null : cfg.Record_Type_Developer_Names__c;
        if (String.isBlank(allowed)) {
            return true;
        }
        if (String.isBlank(rtDevName)) {
            return false;
        }
        for (String name : allowed.split(',')) {
            if (name.trim().equalsIgnoreCase(rtDevName)) {
                return true;
            }
        }
        return false;
    }

    @TestVisible
    private static List<DocGen_Button__mdt> loadConfigs(String objectApiName) {
        if (configOverride != null) {
            List<DocGen_Button__mdt> filtered = new List<DocGen_Button__mdt>();
            for (DocGen_Button__mdt c : configOverride) {
                if (c.Active__c == true && c.Object_API_Name__c == objectApiName) {
                    filtered.add(c);
                }
            }
            return filtered;
        }
        return [
            SELECT
                DeveloperName,
                MasterLabel,
                Object_API_Name__c,
                Template_Id__c,
                Template_API_Name__c,
                Action_Type__c,
                Save_To_Record__c,
                Output_Format_Override__c,
                Document_Title__c,
                Delivery_Mode__c,
                Active__c,
                Sort_Order__c,
                Record_Type_Developer_Names__c
            FROM DocGen_Button__mdt
            WHERE Active__c = TRUE AND Object_API_Name__c = :objectApiName
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c NULLS LAST, MasterLabel
        ]; // NOPMD ApexCRUDViolation — CMDT is admin-authored config; internal config reads use SYSTEM_MODE (USER_MODE breaks the namespaced build + is permission-gated for CMDT)
    }

    @TestVisible
    private static DocGen_Button__mdt getConfig(String developerName) {
        if (configOverride != null) {
            for (DocGen_Button__mdt c : configOverride) {
                if (c.DeveloperName == developerName && c.Active__c == true) {
                    return c;
                }
            }
            return null;
        }
        List<DocGen_Button__mdt> rows = [
            SELECT
                DeveloperName,
                MasterLabel,
                Object_API_Name__c,
                Template_Id__c,
                Template_API_Name__c,
                Action_Type__c,
                Save_To_Record__c,
                Output_Format_Override__c,
                Document_Title__c,
                Delivery_Mode__c,
                Active__c,
                Record_Type_Developer_Names__c
            FROM DocGen_Button__mdt
            WHERE DeveloperName = :developerName AND Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation — CMDT is admin-authored config; internal config reads use SYSTEM_MODE
        return rows.isEmpty() ? null : rows[0];
    }

    @TestVisible
    private static String normalizeOutputFormatOverride(String rawOverride) {
        if (String.isBlank(rawOverride)) {
            return null;
        }
        String value = rawOverride.trim();
        String key = value.toUpperCase();
        Map<String, String> aliases = new Map<String, String>{
            'PDF' => 'PDF',
            'DOCX' => 'Word',
            'WORD' => 'Word',
            'XLSX' => 'Excel',
            'XLSM' => 'Excel',
            'EXCEL' => 'Excel',
            'PPTX' => 'PowerPoint',
            'PPT' => 'PowerPoint',
            'POWERPOINT' => 'PowerPoint',
            'POWER POINT' => 'PowerPoint',
            'HTML' => 'HTML'
        };
        return aliases.containsKey(key) ? aliases.get(key) : value;
    }

    /** Maps the admin-entered Delivery_Mode__c to a canonical value. Blank or
     *  unrecognized values return DOWNLOAD so existing buttons are unchanged.
     *  Accepts spaces, hyphens, "+", and "&" as separators (e.g. "Preview + Download"). */
    @TestVisible
    private static String normalizeDeliveryMode(String raw) {
        if (String.isBlank(raw)) {
            return DELIVERY_DOWNLOAD;
        }
        // Separators ("+", "&", "-", spaces) collapse to "_", and a spelled-out "AND" is dropped,
        // so "Preview + Download", "Preview & Download" and "Preview_And_Download" all become
        // PREVIEW_DOWNLOAD. (The "+" and "&" forms have no "AND" to match on, which is why the
        // canonical-string compare alone left them falling back to DOWNLOAD.)
        String k = raw.trim().toUpperCase().replaceAll('[\\s+&-]+', '_').replaceAll('_+', '_').replace('_AND_', '_');
        if (k == DELIVERY_PREVIEW) {
            return DELIVERY_PREVIEW;
        }
        if (k == 'PREVIEW_DOWNLOAD' || k == 'DOWNLOAD_PREVIEW' || k == 'BOTH') {
            return DELIVERY_PREVIEW_AND_DOWNLOAD;
        }
        return DELIVERY_DOWNLOAD;
    }

    private static DocGen_Button__mdt validateConfig(Id recordId, String configDeveloperName, String actionType) {
        if (recordId == null) {
            throw new DocGenButtonException('No record was provided.');
        }
        DocGen_Button__mdt cfg = getConfig(configDeveloperName);
        if (cfg == null) {
            throw new DocGenButtonException(
                'No active Portwood Button configuration named "' + configDeveloperName + '".'
            );
        }
        if (normalizeActionType(cfg.Action_Type__c) != normalizeActionType(actionType)) {
            throw new DocGenButtonException(
                'Portwood Button "' + configDeveloperName + '" is not a ' + actionType + ' button.'
            );
        }
        String recObject = recordId.getSObjectType().getDescribe().getName();
        if (String.isNotBlank(cfg.Object_API_Name__c) && cfg.Object_API_Name__c != recObject) {
            throw new DocGenButtonException(
                'Portwood Button "' +
                    configDeveloperName +
                    '" is configured for ' +
                    cfg.Object_API_Name__c +
                    ' records, not ' +
                    recObject +
                    '.'
            );
        }
        if (!matchesRecordType(cfg, recordTypeDevName(recordId))) {
            throw new DocGenButtonException(
                'Portwood Button "' + configDeveloperName + '" is not available for this record\'s record type.'
            );
        }
        if (
            normalizeActionType(actionType) != 'Email' &&
            String.isBlank(cfg.Template_Id__c) &&
            String.isBlank(cfg.Template_API_Name__c)
        ) {
            throw new DocGenButtonException(
                'Portwood Button "' +
                    configDeveloperName +
                    '" has no template configured. Set Template Id or Template API Name.'
            );
        }
        return cfg;
    }

    private static Id resolveTemplateId(DocGen_Button__mdt cfg, String configDeveloperName) {
        return resolveTemplateId(cfg, configDeveloperName, null);
    }

    private static Id resolveTemplateId(DocGen_Button__mdt cfg, String configDeveloperName, String templateReference) {
        if (String.isNotBlank(templateReference)) {
            if (templateReference.startsWith('key:')) {
                return DocGenService.templateIdByApiName(templateReference.substring(4));
            }
            if (templateReference.startsWith('id:')) {
                try {
                    return (Id) templateReference.substring(3);
                } catch (Exception idEx) {
                    throw new DocGenButtonException('The selected template Id is invalid.');
                }
            }
            throw new DocGenButtonException('The selected template is invalid.');
        }
        if (String.isNotBlank(cfg.Template_Id__c)) {
            try {
                return (Id) cfg.Template_Id__c;
            } catch (Exception idEx) {
                throw new DocGenButtonException(
                    'Portwood Button "' +
                        configDeveloperName +
                        '" has an invalid Template Id (' +
                        cfg.Template_Id__c +
                        '). Set it to a Portwood Template record Id, or use Template API Name.'
                );
            }
        }
        return DocGenService.templateIdByApiName(cfg.Template_API_Name__c);
    }

    private static ContentVersion latestVersion(GenResult res) {
        Id cvId = res.contentVersionId;
        if (cvId == null && res.contentDocumentId != null) {
            List<ContentVersion> latest = [
                SELECT Id
                FROM ContentVersion
                WHERE ContentDocumentId = :res.contentDocumentId
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!latest.isEmpty()) {
                cvId = latest[0].Id;
            }
        }
        if (cvId == null) {
            throw new DocGenButtonException('The document was generated but no file reference was returned.');
        }
        List<ContentVersion> cvs = [
            SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cvId
            WITH USER_MODE
            LIMIT 1
        ];
        if (cvs.isEmpty()) {
            throw new DocGenButtonException('Generated file could not be read back. Check file sharing/visibility.');
        }
        return cvs[0];
    }

    private static List<String> normalizeEmails(List<String> rawAddresses) {
        Set<String> unique = new Set<String>();
        if (rawAddresses != null) {
            for (String raw : rawAddresses) {
                if (String.isBlank(raw)) {
                    continue;
                }
                for (String part : raw.split('[,;\\s]+')) {
                    String email = part == null ? null : part.trim();
                    if (String.isBlank(email)) {
                        continue;
                    }
                    if (!Pattern.matches('^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$', email)) {
                        throw new DocGenButtonException('Invalid email address: ' + email);
                    }
                    unique.add(email.toLowerCase());
                }
            }
        }
        if (unique.size() > MAX_EMAIL_RECIPIENTS) {
            throw new DocGenButtonException(
                'A Send Email action can address at most ' + MAX_EMAIL_RECIPIENTS + ' recipients.'
            );
        }
        return new List<String>(unique);
    }

    private static String normalizeActionType(String actionType) {
        return String.isNotBlank(actionType) && actionType.equalsIgnoreCase('Email') ? 'Email' : 'Document';
    }

    private static String templateLabel(DocGen_Button__mdt cfg) {
        return String.isNotBlank(cfg.Template_API_Name__c) ? cfg.Template_API_Name__c : cfg.Template_Id__c;
    }

    private static Map<String, String> templateNamesByConfig(List<DocGen_Button__mdt> configs) {
        Map<String, String> out = new Map<String, String>();
        Set<Id> templateIds = new Set<Id>();
        Set<String> templateApiNames = new Set<String>();
        Map<Id, List<String>> configNamesByTemplateId = new Map<Id, List<String>>();
        Map<String, List<String>> configNamesByTemplateApi = new Map<String, List<String>>();
        for (DocGen_Button__mdt cfg : configs) {
            if (String.isNotBlank(cfg.Template_Id__c)) {
                try {
                    Id templateId = (Id) cfg.Template_Id__c;
                    templateIds.add(templateId);
                    if (!configNamesByTemplateId.containsKey(templateId)) {
                        configNamesByTemplateId.put(templateId, new List<String>());
                    }
                    configNamesByTemplateId.get(templateId).add(cfg.DeveloperName);
                } catch (Exception ignored) {
                    System.debug(
                        LoggingLevel.DEBUG,
                        'Ignoring invalid Portwood Button template id: ' + ignored.getMessage()
                    );
                }
            } else if (String.isNotBlank(cfg.Template_API_Name__c)) {
                templateApiNames.add(cfg.Template_API_Name__c);
                if (!configNamesByTemplateApi.containsKey(cfg.Template_API_Name__c)) {
                    configNamesByTemplateApi.put(cfg.Template_API_Name__c, new List<String>());
                }
                configNamesByTemplateApi.get(cfg.Template_API_Name__c).add(cfg.DeveloperName);
            }
        }
        if (templateIds.isEmpty() && templateApiNames.isEmpty()) {
            return out;
        }
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Name', 'API_Name__c' });
            /* code-analyzer-suppress ApexCRUDViolation ApexFlsViolation */
            for (DocGen_Template__c t : [
                SELECT Id, Name, API_Name__c
                FROM DocGen_Template__c
                WHERE Id IN :templateIds OR API_Name__c IN :templateApiNames
                WITH SYSTEM_MODE
            ]) {
                if (configNamesByTemplateId.containsKey(t.Id)) {
                    for (String configName : configNamesByTemplateId.get(t.Id)) {
                        out.put(configName, t.Name);
                    }
                }
                if (String.isNotBlank(t.API_Name__c) && configNamesByTemplateApi.containsKey(t.API_Name__c)) {
                    for (String configName : configNamesByTemplateApi.get(t.API_Name__c)) {
                        out.put(configName, t.Name);
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.DEBUG, 'Portwood Button template name lookup skipped: ' + e.getMessage());
        }
        return out;
    }

    private static String previewFallback(String message) {
        return '<div style="font-family:Arial,sans-serif;padding:16px;">' + message.escapeHtml4() + '</div>';
    }

    private static String buildSendEmailError(Messaging.SendEmailResult[] sendResults) {
        List<String> messages = new List<String>();
        if (sendResults != null) {
            for (Messaging.SendEmailResult result : sendResults) {
                if (result == null || result.isSuccess()) {
                    continue;
                }
                for (Messaging.SendEmailError err : result.getErrors()) {
                    if (err != null && String.isNotBlank(err.getMessage())) {
                        messages.add(err.getMessage());
                    }
                }
            }
        }
        return messages.isEmpty()
            ? 'Salesforce did not accept the email for delivery.'
            : 'Salesforce did not accept the email for delivery: ' + String.join(messages, '; ');
    }

    /**
     * The org-wide sender an admin explicitly chose for Portwood emails
     * (DocGen_Settings__c.Signature_OWA_Id__c, the same setting the signature and email-template
     * senders use), and only if it is still verified. Null means "send as the running user".
     */
    @TestVisible
    private static Id configuredOrgWideEmailAddressId() {
        try {
            DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
            if (settings == null || String.isBlank(settings.Signature_OWA_Id__c)) {
                return null;
            }
            String configured = settings.Signature_OWA_Id__c;
            List<OrgWideEmailAddress> senders = [
                SELECT Id
                FROM OrgWideEmailAddress
                WHERE Id = :configured AND IsVerified = TRUE
                WITH USER_MODE
                LIMIT 1
            ];
            return senders.isEmpty() ? null : senders[0].Id;
        } catch (Exception e) {
            return null;
        }
    }

    private static Boolean hasConfiguredTemplate(DocGen_Button__mdt cfg) {
        return String.isNotBlank(cfg.Template_Id__c) || String.isNotBlank(cfg.Template_API_Name__c);
    }

    /**
     * Template an Email button may generate. A button that pins a template always uses it (the
     * client cannot swap it). Otherwise the client's choice must be an active template built for
     * the record's own object, so the picker is not the only thing standing between a user and
     * every template in the org.
     */
    private static Id resolveEmailTemplateId(
        DocGen_Button__mdt cfg,
        String configDeveloperName,
        String templateReference,
        Id recordId
    ) {
        if (hasConfiguredTemplate(cfg)) {
            return resolveTemplateId(cfg, configDeveloperName, null);
        }
        if (String.isBlank(templateReference)) {
            throw new DocGenButtonException('Choose a template.');
        }
        Id templateId = resolveTemplateId(cfg, configDeveloperName, templateReference);
        String recObject = recordId.getSObjectType().getDescribe().getName();
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Base_Object_API__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexCRUDViolation ApexFlsViolation */
        List<DocGen_Template__c> allowed = [
            SELECT Id
            FROM DocGen_Template__c
            WHERE Id = :templateId AND Is_Active__c = TRUE AND Base_Object_API__c = :recObject
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (allowed.isEmpty()) {
            throw new DocGenButtonException('That template is not available for this record.');
        }
        return templateId;
    }

    private static String stripHtml(String value) {
        return String.isBlank(value) ? value : value.replaceAll('<[^>]*>', '').replace('&nbsp;', ' ').trim();
    }

    private static String buildFileName(ContentVersion cv) {
        String base = String.isNotBlank(cv.Title) ? cv.Title : 'Document';
        String ext = String.isNotBlank(cv.FileExtension) ? cv.FileExtension.toLowerCase() : 'pdf';
        return base.endsWithIgnoreCase('.' + ext) ? base : base + '.' + ext;
    }

    private static String mimeFor(String ext) {
        String e = (ext == null) ? '' : ext.toLowerCase();
        Map<String, String> m = new Map<String, String>{
            'pdf' => 'application/pdf',
            'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'doc' => 'application/msword',
            'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
            'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            'xlsm' => 'application/vnd.ms-excel.sheet.macroEnabled.12'
        };
        return m.containsKey(e) ? m.get(e) : 'application/octet-stream';
    }
}
