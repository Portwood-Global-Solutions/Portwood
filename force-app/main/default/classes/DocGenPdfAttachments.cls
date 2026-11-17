/** Ordered, pinned supplemental PDF versions on a template. */
public with sharing class DocGenPdfAttachments {
    private static final Integer MAX_FILES = 20;

    public class Attachment {
        public Id versionId;
        public String title;
        public String placement;
    }

    private static DocGen_Template__c readTemplate(Id templateId) {
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.SObjectType, new Set<String>{ 'Pdf_Attachments__c' });
        List<DocGen_Template__c> templates = [
            SELECT Pdf_Attachments__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (templates.isEmpty()) {
            throw new DocGenException('The template is missing or inaccessible.');
        }
        return templates[0];
    }

    public static List<Attachment> read(Id templateId) {
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Pdf_Attachments__c' });
        return configured(templateId);
    }

    private static List<Attachment> configured(Id templateId) {
        // Runtime policy owned by the template; the initiating user still needs access
        // to each source File. Custom permission sets need not expose the setting itself.
        return parse(readTemplate(templateId).Pdf_Attachments__c);
    }

    public static void preflight(Id templateId) {
        List<Attachment> entries = configured(templateId);
        if (!entries.isEmpty()) {
            metadata(entries);
        }
    }

    private static List<Attachment> parse(String config) {
        if (String.isBlank(config)) {
            return new List<Attachment>();
        }
        List<Attachment> entries = (List<Attachment>) JSON.deserialize(config, List<Attachment>.class);
        if (entries == null || entries.size() > MAX_FILES) {
            throw new DocGenException('Configure no more than ' + MAX_FILES + ' supplemental PDFs.');
        }
        for (Attachment entry : entries) {
            if (
                entry == null ||
                entry.versionId == null ||
                entry.versionId.getSObjectType() != ContentVersion.SObjectType ||
                (entry.placement != 'before' &&
                entry.placement != 'after')
            ) {
                throw new DocGenException('Each attachment needs a PDF file version and a before or after placement.');
            }
        }
        return entries;
    }

    private static String label(Attachment entry) {
        return String.isBlank(entry.title) ? String.valueOf(entry.versionId) : entry.title;
    }

    private static Map<Id, ContentVersion> metadata(List<Attachment> entries) {
        Set<Id> ids = new Set<Id>();
        for (Attachment entry : entries) {
            ids.add(entry.versionId);
        }
        Map<Id, ContentVersion> files = new Map<Id, ContentVersion>(
            [
                SELECT Id, Title, FileType, ContentLocation, ContentSize
                FROM ContentVersion
                WHERE Id IN :ids
                WITH USER_MODE
            ]
        );
        for (Attachment entry : entries) {
            ContentVersion file = files.get(entry.versionId);
            if (file == null) {
                throw new DocGenException('Template PDF attachment "' + label(entry) + '" is missing or inaccessible.');
            }
            if (file.FileType != 'PDF' || file.ContentLocation != 'S') {
                throw new DocGenException(
                    'Template attachment "' + label(entry) + '" must be a PDF stored in Salesforce Files.'
                );
            }
        }
        return files;
    }

    public static void save(Id templateId, String config) {
        readTemplate(templateId);
        List<Attachment> entries = parse(config);
        if (!entries.isEmpty()) {
            Map<Id, ContentVersion> files = metadata(entries);
            for (Attachment entry : entries) {
                entry.title = files.get(entry.versionId).Title;
            }
        }
        DocGen_Template__c updateRecord = new DocGen_Template__c(
            Id = templateId,
            Pdf_Attachments__c = entries.isEmpty() ? null : JSON.serialize(entries)
        );
        DocGenFlsGuard.assertUpdateable(updateRecord, new Set<String>{ 'Pdf_Attachments__c' });
        Database.update(updateRecord, AccessLevel.USER_MODE);
    }

    public static Blob includeInPdf(Id templateId, Blob primary) {
        List<Attachment> entries = configured(templateId);
        if (entries.isEmpty()) {
            return primary;
        }
        Map<Id, ContentVersion> files = metadata(entries);
        Integer total = primary.size();
        for (Attachment entry : entries) {
            total += files.get(entry.versionId).ContentSize;
        }
        if (
            total > DocGenPdfMergeFlowAction.inputLimit() ||
            total * 14 > Limits.getLimitHeapSize() - Limits.getHeapSize()
        ) {
            throw new DocGenException(
                'The generated PDF and template attachments exceed the native PDF merge size budget. Reduce the PDF sizes.'
            );
        }

        List<Id> before = new List<Id>();
        List<Id> after = new List<Id>();
        List<String> names = new List<String>();
        for (Attachment entry : entries) {
            List<Id> destination = entry.placement == 'before' ? before : after;
            destination.add(entry.versionId);
            names.add(label(entry));
        }
        try {
            return DocGenPdfMerger.mergeAroundPdf(before, primary, after);
        } catch (DocGenPdfMerger.DocGenPdfMergeException e) {
            throw new DocGenException(
                'Could not merge template PDF attachments (' + String.join(names, ', ') + '): ' + e.getMessage()
            );
        }
    }

    public static void assertGiantPdfSupported(Id templateId) {
        if (!configured(templateId).isEmpty()) {
            throw new DocGenException(
                'Giant Query PDF generation cannot include this template\'s PDF attachments. Use a smaller record set or generate with a separate template and combine the PDFs.'
            );
        }
    }
}
