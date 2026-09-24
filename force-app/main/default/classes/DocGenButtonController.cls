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
        @AuraEnabled
        public String previewHtml;
        @AuraEnabled
        public String templatePreviewUrl;
        @AuraEnabled
        public String templatePreviewMimeType;
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
        List<ButtonOption> options = new List<ButtonOption>();
        if (recordId == null) {
            return options;
        }
        String objectApiName = recordId.getSObjectType().getDescribe().getName();
        String rtDevName = recordTypeDevName(recordId);
        for (DocGen_Button__mdt cfg : loadConfigs(objectApiName)) {
            if (!matchesRecordType(cfg, rtDevName)) {
                continue;
            }
            ButtonOption opt = new ButtonOption();
            opt.developerName = cfg.DeveloperName;
            opt.label = String.isNotBlank(cfg.MasterLabel) ? cfg.MasterLabel : cfg.DeveloperName;
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
            gReq.outputFormatOverride = cfg.Output_Format_Override__c;

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
            if (dto.deliveryMode == DELIVERY_PREVIEW || dto.deliveryMode == DELIVERY_PREVIEW_AND_DOWNLOAD) {
                List<DocGen_Template_Version__c> templateVersions = [
                    SELECT Content_Version_Id__c
                    FROM DocGen_Template_Version__c
                    WHERE Template__c = :templateId AND Is_Active__c = TRUE
                    WITH USER_MODE
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ];
                if (!templateVersions.isEmpty() && templateVersions[0].Content_Version_Id__c != null) {
                    Id sourceVersionId = (Id) templateVersions[0].Content_Version_Id__c;
                    List<ContentVersion> sourceVersions = [
                        SELECT Id, FileExtension
                        FROM ContentVersion
                        WHERE Id = :sourceVersionId
                        WITH USER_MODE
                        LIMIT 1
                    ];
                    if (!sourceVersions.isEmpty()) {
                        dto.templatePreviewUrl = '/sfc/servlet.shepherd/version/download/' + sourceVersions[0].Id;
                        dto.templatePreviewMimeType = mimeFor(sourceVersions[0].FileExtension);
                    }
                }
                try {
                    dto.previewHtml = DocGenService.renderPreviewHtml(templateId, recordId);
                } catch (Exception previewEx) {
                    // The generated file is still valid and downloadable. Some
                    // source formats (for example PowerPoint) do not have an
                    // HTML preview path, so leave previewHtml blank and let the
                    // LWC show a clear fallback in the preview screen.
                    String noop = previewEx.getMessage(); // NOPMD UnusedLocalVariable
                }
            }

            // Always provide a file-servlet download URL. It works for every MIME type
            // and any size, and sidesteps Lightning Web Security's Blob/createObjectURL
            // MIME allowlist (which rejects Office formats like .docx/.pptx/.xlsx).
            dto.downloadUrl = '/sfc/servlet.shepherd/version/download/' + cv.Id;

            // Also return base64 for small files. The LWC uses the Blob path only for
            // LWS-safe MIME types (PDF, images, text) and otherwise uses downloadUrl.
            // Preview-only buttons need inline bytes for PDFs too; Salesforce native
            // file preview can lag or report "No preview available" for fresh files.
            Boolean needsInlineBytes = dto.deliveryMode != DELIVERY_PREVIEW || isDirectPreviewMime(dto.mimeType);
            if (needsInlineBytes && cv.ContentSize != null && cv.ContentSize <= inlineDownloadMaxBytes) {
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

    /** Maps the admin-entered Delivery_Mode__c to a canonical value. Blank or
     *  unrecognized values return DOWNLOAD so existing buttons are unchanged.
     *  Accepts spaces, hyphens, "+", and "&" as separators (e.g. "Preview + Download"). */
    @TestVisible
    private static String normalizeDeliveryMode(String raw) {
        if (String.isBlank(raw)) {
            return DELIVERY_DOWNLOAD;
        }
        String k = raw.trim().toUpperCase();
        k = k.replaceAll('\\s+', '_');
        k = k.replaceAll('\\+', '_');
        k = k.replaceAll('&', '_');
        k = k.replaceAll('-', '_');
        k = k.replaceAll('_+', '_');
        if (k == DELIVERY_PREVIEW || k == DELIVERY_PREVIEW_AND_DOWNLOAD) {
            return k;
        }
        if (k == 'DOWNLOAD_AND_PREVIEW' || k == 'DOWNLOAD_PREVIEW' || k == 'PREVIEW_DOWNLOAD' || k == 'BOTH') {
            return DELIVERY_PREVIEW_AND_DOWNLOAD;
        }
        return DELIVERY_DOWNLOAD;
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

    private static Boolean isDirectPreviewMime(String mimeType) {
        return mimeType == 'application/pdf' ||
            (mimeType != null && (mimeType.startsWith('image/') || mimeType.startsWith('text/')));
    }
}
