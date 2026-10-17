/** Private example Files for Agentforce authoring. No binary file bytes cross an Aura request. */
public with sharing class DocGenAiReferenceController {
    private static final Integer FILE_BUDGET = 15 * 1024 * 1024;
    public static ContentVersion readableFile(Id documentId) {
        if (documentId == null || documentId.getSObjectType() != ContentDocument.sObjectType)
            throw new DocGenException('Choose a PDF or DOCX example from Salesforce Files.');
        List<ContentVersion> files = [
            SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId = :documentId AND IsLatest = TRUE
            WITH USER_MODE
            LIMIT 1
        ];
        if (files.isEmpty())
            throw new DocGenException(
                'This example file is unavailable. Upload it again or choose a file you can access.'
            );
        ContentVersion file = files[0];
        if (file.FileExtension != 'pdf' && file.FileExtension != 'docx')
            throw new DocGenException(
                'Choose a PDF or DOCX example. Other file formats are not supported for AI references.'
            );
        if (file.ContentSize > FILE_BUDGET)
            throw new DocGenException(
                'This example exceeds the 15 MB Agentforce reference-file budget. Use a shorter representative example.'
            );
        return file;
    }
    @AuraEnabled
    public static Map<String, Object> prepareReference(Id documentId) {
        try {
            ContentVersion file = readableFile(documentId);
            Map<String, Object> out = new Map<String, Object>{
                'documentId' => documentId,
                'versionId' => file.Id,
                'name' => file.Title,
                'format' => file.FileExtension,
                'state' => 'ready'
            };
            if (file.FileExtension == 'docx') {
                out.put('jobId', System.enqueueJob(new PrepareDocx(file.Id)));
                out.put('state', 'preparing');
            }
            return out;
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'The example could not be prepared.');
        }
    }
    @AuraEnabled
    public static Map<String, Object> getReferenceStatus(Id jobId) {
        Id owner = UserInfo.getUserId();
        // Internal job status is strictly scoped to this user and this preparation class.
        /* code-analyzer-suppress ApexFlsViolation */
        List<AsyncApexJob> jobs = [
            SELECT Id, Status, ExtendedStatus
            FROM AsyncApexJob
            WHERE Id = :jobId AND CreatedById = :owner AND ApexClass.Name = 'DocGenAiReferenceController'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (jobs.isEmpty())
            throw DocGenService.ahe('This example preparation is unavailable. Upload the example again.');
        // QueueableContext may expose 15 characters while Aura sends 18; normalize both sides.
        String title = 'docgen_ai_reference_' + String.valueOf(jobId).left(15);
        List<ContentVersion> results = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Title = :title AND CreatedById = :owner AND IsLatest = TRUE
            WITH USER_MODE
            LIMIT 1
        ];
        if (!results.isEmpty())
            return (Map<String, Object>) JSON.deserializeUntyped(results[0].VersionData.toString());
        if (jobs[0].Status == 'Failed' || jobs[0].Status == 'Aborted')
            return new Map<String, Object>{
                'state' => 'error',
                'message' => 'The DOCX could not be prepared within Salesforce processing limits. Try a smaller example or upload its PDF export.'
            };
        return new Map<String, Object>{ 'state' => 'preparing' };
    }
    /** Carry extracted images into the new template's normal private image pipeline. */
    @AuraEnabled
    public static void attachReferenceImages(Id templateId, List<Id> versionIds) {
        if (versionIds == null || versionIds.isEmpty())
            return;
        Id owner = UserInfo.getUserId();
        List<DocGen_Template__c> templates = [
            SELECT Id
            FROM DocGen_Template__c
            WHERE Id = :templateId AND CreatedById = :owner
            WITH USER_MODE
            LIMIT 1
        ];
        if (templates.isEmpty())
            throw DocGenService.ahe('Create your template before attaching example images.');
        List<ContentVersion> images = [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :versionIds AND CreatedById = :owner AND Title LIKE 'docgen_ai_ref_img_%'
            WITH USER_MODE
        ];
        if (images.size() != new Set<Id>(versionIds).size())
            throw DocGenService.ahe('An example image is unavailable. Prepare the example again.');
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (ContentVersion image : images)
            links.add(
                new ContentDocumentLink(
                    ContentDocumentId = image.ContentDocumentId,
                    LinkedEntityId = templateId,
                    // Let Salesforce choose the valid record-link visibility for this org.
                    // InternalUsers is rejected in orgs without Experience Cloud; this is
                    // a record-scoped viewer link, never a public ContentDistribution.
                    ShareType = 'V'
                )
            );
        try {
            Database.insert(links, AccessLevel.USER_MODE);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'The example images could not be attached.');
        }
    }
    public class PrepareDocx implements Queueable {
        private Id versionId;
        public PrepareDocx(Id sourceId) {
            versionId = sourceId;
        }
        public void execute(QueueableContext context) {
            Savepoint checkpoint = Database.setSavepoint();
            Map<String, Object> result;
            try {
                ContentVersion file = [
                    SELECT Id, ContentDocumentId, Title, VersionData
                    FROM ContentVersion
                    WHERE Id = :versionId
                    WITH USER_MODE
                    LIMIT 1
                ];
                Compression.ZipReader reader = new Compression.ZipReader(file.VersionData);
                Map<String, Compression.ZipEntry> entries = new Map<String, Compression.ZipEntry>();
                for (Compression.ZipEntry entry : reader.getEntries())
                    entries.put(entry.getName(), entry);
                if (!entries.containsKey('word/document.xml'))
                    throw new DocGenException('The file is not a valid DOCX document.');
                String xml = reader.extract(entries.get('word/document.xml')).toString();
                DocGenHtmlRenderer.stylesXml = part(reader, entries, 'word/styles.xml');
                DocGenHtmlRenderer.numberingXml = part(reader, entries, 'word/numbering.xml');
                Map<String, String> imageUrls = new Map<String, String>();
                List<Id> imageIds = new List<Id>();
                String relationships = part(reader, entries, 'word/_rels/document.xml.rels');
                if (String.isNotBlank(relationships)) {
                    Dom.Document rels = new Dom.Document();
                    rels.load(relationships);
                    for (Dom.XmlNode rel : rels.getRootElement().getChildElements()) {
                        String target = rel.getAttribute('Target', null);
                        String type = rel.getAttribute('Type', null);
                        if (
                            type == null ||
                            !type.endsWith('/image') ||
                            rel.getAttribute('TargetMode', null) == 'External' ||
                            target == null ||
                            !target.startsWith('media/')
                        )
                            continue;
                        String path = 'word/' + target;
                        String ext = path.substringAfterLast('.').toLowerCase();
                        if (!entries.containsKey(path) || (ext != 'png' && ext != 'jpg' && ext != 'jpeg'))
                            continue;
                        if (Limits.getDmlStatements() + 3 >= Limits.getLimitDmlStatements())
                            throw new DocGenException(
                                'This DOCX contains too many embedded images. Use a shorter example.'
                            );
                        ContentVersion image = new ContentVersion(
                            Title = 'docgen_ai_ref_img_' + versionId + '_' + imageIds.size(),
                            PathOnClient = 'example-image.' + ext,
                            VersionData = reader.extract(entries.get(path)),
                            FirstPublishLocationId = UserInfo.getUserId()
                        );
                        Database.insert(image, AccessLevel.USER_MODE);
                        imageIds.add(image.Id);
                        imageUrls.put(
                            rel.getAttribute('Id', null),
                            '/sfc/servlet.shepherd/version/download/' + image.Id
                        );
                    }
                }
                String header = part(reader, entries, 'word/header1.xml');
                String footer = part(reader, entries, 'word/footer1.xml');
                if (String.isNotBlank(header))
                    xml = '<!-- DOCGEN_HEADER_START -->' + header + '<!-- DOCGEN_HEADER_END -->' + xml;
                if (String.isNotBlank(footer))
                    xml += '<!-- DOCGEN_FOOTER_START -->' + footer + '<!-- DOCGEN_FOOTER_END -->';
                String html = DocGenHtmlRenderer.convertToHtml(xml, imageUrls);
                if (html.length() > 90000)
                    throw new DocGenException(
                        'This example has more content than fits in the Agentforce authoring prompt. Use a shorter representative example.'
                    );
                result = new Map<String, Object>{
                    'state' => 'ready',
                    'documentId' => file.ContentDocumentId,
                    'versionId' => file.Id,
                    'name' => file.Title,
                    'format' => 'docx',
                    'html' => html,
                    'imageVersionIds' => imageIds
                };
            } catch (Exception e) {
                Database.rollback(checkpoint);
                result = new Map<String, Object>{
                    'state' => 'error',
                    'message' => 'The DOCX could not be prepared: ' +
                    e.getMessage() +
                    ' Try a PDF export if the document uses unsupported Word features.'
                };
            }
            ContentVersion output = new ContentVersion(
                Title = 'docgen_ai_reference_' + String.valueOf(context.getJobId()).left(15),
                PathOnClient = 'reference-result.json',
                VersionData = Blob.valueOf(JSON.serialize(result)),
                FirstPublishLocationId = UserInfo.getUserId()
            );
            Database.insert(output, AccessLevel.USER_MODE);
        }
        private String part(Compression.ZipReader reader, Map<String, Compression.ZipEntry> entries, String path) {
            return entries.containsKey(path) ? reader.extract(entries.get(path)).toString() : null;
        }
    }
}
