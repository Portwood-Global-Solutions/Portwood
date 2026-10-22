/** Record-scoped PDF preparation. Draft files/configuration remain uploader-private.
 * Global remoting is required by Salesforce for a Visualforce editor in a Lightning iframe.
 * Every entry point still enforces authenticated record access and draft ownership. */
global with sharing class DocGenSignaturePreparationController {
    public static final Integer MAX_PDF_BYTES = 2097152;
    private static final Integer MAX_FIELDS = 100;

    @AuraEnabled
    public static String getPreparationUrl(Id recordId) {
        assertRecordAccess(recordId);
        return Page.DocGenSignaturePrepare.getUrl() + '?recordId=' + recordId;
    }

    @RemoteAction
    global static List<Contact> searchContacts(Id recordId, String search) {
        assertRecordAccess(recordId);
        if (String.isBlank(search) || search.trim().length() < 2)
            return new List<Contact>();
        String term = '%' + search.trim().left(60) + '%';
        return [
            SELECT Id, Name, Email
            FROM Contact
            WHERE Name LIKE :term
            WITH USER_MODE
            ORDER BY Name
            LIMIT 8
        ];
    }

    @AuraEnabled
    @RemoteAction
    global static Map<String, Object> getContext(Id recordId) {
        assertRecordAccess(recordId);
        Set<Id> fileIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
            WITH USER_MODE
            LIMIT 100
        ])
            fileIds.add(link.ContentDocumentId);
        List<ContentVersion> files = [
            SELECT Id, Title, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId IN :fileIds AND IsLatest = TRUE AND FileExtension = 'pdf'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 100
        ];
        Id userId = UserInfo.getUserId();
        String relatedId = String.valueOf(recordId);
        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{
                'Name',
                'Document_Title_Format__c',
                'PDF_Revision__c',
                'Related_Record_Id__c',
                'CreatedById',
                'Status__c',
                'Original_Document_CV_Id__c',
                'LastModifiedDate'
            }
        );
        // Owner and related record constrain these private draft records; fields are guarded above.
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signature_Request__c> drafts = [
            SELECT Id, Name, Document_Title_Format__c, PDF_Revision__c
            FROM DocGen_Signature_Request__c
            WHERE
                Related_Record_Id__c = :relatedId
                AND CreatedById = :userId
                AND Status__c = 'Draft'
                AND Original_Document_CV_Id__c != NULL
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 10
        ];
        String siteUrl = DocGenSignatureSenderController.getSiteBaseUrl();
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        Boolean publicSite = String.isNotBlank(siteUrl) && !siteUrl.contains('<');
        return new Map<String, Object>{
            'files' => files,
            'drafts' => drafts,
            'brands' => availableBrands(),
            'maxBytes' => MAX_PDF_BYTES,
            'publicSite' => publicSite,
            'canEmail' => publicSite && String.isNotBlank(settings.Signature_OWA_Id__c),
            'verificationDefault' => settings.Signature_Skip_Email_Verification__c != true
        };
    }

    @RemoteAction
    global static Map<String, Object> uploadPdf(Id recordId, String fileName, String base64Pdf) {
        assertRecordAccess(recordId);
        if (
            String.isBlank(base64Pdf) ||
            base64Pdf.length() > ((MAX_PDF_BYTES + 2) / 3) * 4 ||
            !base64Pdf.startsWith('JVBERi0')
        )
            fail('Choose a valid PDF no larger than 2 MB.');
        Blob bytes;
        try {
            bytes = EncodingUtil.base64Decode(base64Pdf);
        } catch (Exception ex) {
            fail('The PDF could not be read. Choose the file again.');
        }
        if (bytes.size() > MAX_PDF_BYTES)
            fail('This PDF is larger than 2 MB. Choose a smaller PDF.');
        return createDraft(recordId, fileName, bytes);
    }

    @RemoteAction
    global static Map<String, Object> selectPdf(Id recordId, Id contentVersionId) {
        assertRecordAccess(recordId);
        ContentVersion source = readablePdf(contentVersionId);
        ContentVersion data = [SELECT VersionData FROM ContentVersion WHERE Id = :source.Id WITH USER_MODE];
        // A separate snapshot keeps the selected Salesforce file editable by its owner.
        return createDraft(recordId, source.Title, data.VersionData);
    }

    private static Map<String, Object> createDraft(Id recordId, String fileName, Blob bytes) {
        String title = String.isBlank(fileName) ? 'Document' : fileName.replaceAll('(?i)\\.pdf$', '').left(200);
        ContentVersion source = new ContentVersion(
            Title = title + ' - Original',
            PathOnClient = 'original.pdf',
            VersionData = bytes
        );
        DocGenFlsGuard.assertCreateable(source, new Set<String>{ 'Title', 'PathOnClient', 'VersionData' });
        Database.insert(source, AccessLevel.SYSTEM_MODE);
        source = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :source.Id WITH SYSTEM_MODE];
        DocGen_Signature_Request__c draft = new DocGen_Signature_Request__c(
            Related_Record_Id__c = String.valueOf(recordId),
            Status__c = 'Draft',
            Document_Title_Format__c = title,
            Original_Document_CV_Id__c = source.Id,
            Original_Content_Document_Id__c = source.ContentDocumentId,
            PDF_Revision__c = 0,
            Source_Document_Id__c = source.Id,
            Snapshot_Hash__c = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', bytes))
        );
        DocGenFlsGuard.assertCreateable(
            draft,
            new Set<String>{
                'Related_Record_Id__c',
                'Status__c',
                'Document_Title_Format__c',
                'Original_Document_CV_Id__c',
                'Original_Content_Document_Id__c',
                'PDF_Revision__c',
                'Source_Document_Id__c',
                'Snapshot_Hash__c'
            }
        );
        Database.insert(draft, AccessLevel.SYSTEM_MODE);
        return new Map<String, Object>{
            'draftId' => draft.Id,
            'revision' => 0,
            'documentId' => source.Id,
            'title' => title,
            'base64' => EncodingUtil.base64Encode(bytes)
        };
    }

    @RemoteAction
    global static Map<String, Object> loadDraft(Id recordId, Id draftId) {
        assertRecordAccess(recordId);
        DocGen_Signature_Request__c draft = ownedDraft(recordId, draftId);
        ContentVersion source = readablePdf((Id) draft.Original_Document_CV_Id__c);
        ContentVersion data = [SELECT VersionData FROM ContentVersion WHERE Id = :source.Id WITH USER_MODE];
        String config = null;
        if (String.isNotBlank(draft.Preparation_Config_CV_Id__c)) {
            Id configId = (Id) draft.Preparation_Config_CV_Id__c;
            config = [SELECT VersionData FROM ContentVersion WHERE Id = :configId WITH USER_MODE]
                .VersionData.toString();
        }
        return new Map<String, Object>{
            'draftId' => draft.Id,
            'revision' => draft.PDF_Revision__c,
            'documentId' => source.Id,
            'title' => draft.Document_Title_Format__c,
            'base64' => EncodingUtil.base64Encode(data.VersionData),
            'config' => config
        };
    }

    @RemoteAction
    global static Integer saveDraft(Id recordId, Id draftId, Integer expectedRevision, String configJson) {
        assertRecordAccess(recordId);
        DocGen_Signature_Request__c draft = ownedDraft(recordId, draftId);
        assertRevision(draft, expectedRevision);
        Map<String, Object> config = validateConfig(configJson, draft, false);
        persistConfig(draft, config);
        return draft.PDF_Revision__c.intValue();
    }

    private static void persistConfig(DocGen_Signature_Request__c draft, Map<String, Object> config) {
        ContentVersion cv = new ContentVersion(
            Title = 'Portwood private signing draft',
            PathOnClient = 'preparation.json',
            VersionData = Blob.valueOf(JSON.serialize(config))
        );
        if (String.isNotBlank(draft.Preparation_Config_CV_Id__c)) {
            Id previousId = (Id) draft.Preparation_Config_CV_Id__c;
            cv.ContentDocumentId = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE Id = :previousId
                WITH USER_MODE
            ]
            .ContentDocumentId;
        }
        DocGenFlsGuard.assertCreateable(
            cv,
            new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'ContentDocumentId' }
        );
        Database.insert(cv, AccessLevel.SYSTEM_MODE);
        draft.Preparation_Config_CV_Id__c = cv.Id;
        draft.PDF_Revision__c = (draft.PDF_Revision__c == null ? 0 : draft.PDF_Revision__c) + 1;
        draft.Document_Title_Format__c = text(config, 'title', 200);
        String brandId = text(config, 'brandId', 18);
        draft.Brand__c = String.isBlank(brandId) ? null : (Id) brandId;
        DocGenFlsGuard.assertUpdateable(
            draft,
            new Set<String>{ 'Preparation_Config_CV_Id__c', 'PDF_Revision__c', 'Document_Title_Format__c', 'Brand__c' }
        );
        Database.update(draft, AccessLevel.SYSTEM_MODE);
    }

    @RemoteAction
    global static Map<String, Object> sendDraft(Id recordId, Id draftId, Integer expectedRevision, String configJson) {
        assertRecordAccess(recordId);
        DocGen_Signature_Request__c draft = ownedDraft(recordId, draftId);
        assertRevision(draft, expectedRevision);
        Map<String, Object> config = validateConfig(configJson, draft, true);
        String delivery = text(config, 'delivery', 20);
        String siteUrl = DocGenSignatureSenderController.getSiteBaseUrl();
        if (delivery != 'preview' && (String.isBlank(siteUrl) || siteUrl.contains('<')))
            fail('Configure a public signing site, or choose Preview signing in Salesforce.');
        if (delivery == 'email' && String.isBlank(DocGen_Settings__c.getOrgDefaults().Signature_OWA_Id__c))
            fail('Configure a verified signature email sender, or create signing links.');
        persistConfig(draft, config);
        List<Map<String, Object>> inputs = new List<Map<String, Object>>();
        Map<String, Integer> recipientIndex = new Map<String, Integer>();
        List<Object> recipients = (List<Object>) config.get('recipients');
        for (Integer i = 0; i < recipients.size(); i++) {
            Map<String, Object> person = (Map<String, Object>) recipients[i];
            recipientIndex.put((String) person.get('key'), i);
            inputs.add(
                new Map<String, Object>{
                    'roleName' => 'Signer ' + (i + 1),
                    'signerName' => person.get('name'),
                    'signerEmail' => person.get('email'),
                    'contactId' => person.get('contactId')
                }
            );
        }
        List<DocGenSignatureSenderController.SignerResult> signers = DocGenSignatureSenderController.createPreparedPdfSigners(
            draft.Id,
            draft.Document_Title_Format__c,
            inputs,
            (Boolean) config.get('requireVerification'),
            (Boolean) config.get('prefill')
        );
        List<DocGen_Signature_Placement__c> placements = new List<DocGen_Signature_Placement__c>();
        Integer sequence = 0;
        List<Object> pages = (List<Object>) config.get('pages');
        for (Object entry : (List<Object>) config.get('fields')) {
            Map<String, Object> field = (Map<String, Object>) entry;
            Integer page = integerValue(field, 'page');
            Map<String, Object> geometry = (Map<String, Object>) pages[page - 1];
            placements.add(
                new DocGen_Signature_Placement__c(
                    Signature_Request__c = draft.Id,
                    Signer__c = signers[recipientIndex.get((String) field.get('recipientKey'))].signerId,
                    Sequence_Order__c = ++sequence,
                    Document_Index__c = 0,
                    Status__c = 'Pending',
                    Placement_Type__c = (String) field.get('type'),
                    Render_Inline__c = true,
                    PDF_Page__c = page,
                    PDF_X__c = numberValue(field, 'x'),
                    PDF_Y__c = numberValue(field, 'y'),
                    PDF_Width__c = numberValue(field, 'width'),
                    PDF_Height__c = numberValue(field, 'height'),
                    PDF_Rotation__c = numberValue(geometry, 'rotation')
                )
            );
        }
        DocGenFlsGuard.assertCreateable(
            placements,
            new Set<String>{
                'Signature_Request__c',
                'Signer__c',
                'Sequence_Order__c',
                'Document_Index__c',
                'Status__c',
                'Placement_Type__c',
                'Render_Inline__c',
                'PDF_Page__c',
                'PDF_X__c',
                'PDF_Y__c',
                'PDF_Width__c',
                'PDF_Height__c',
                'PDF_Rotation__c'
            }
        );
        Database.insert(placements, AccessLevel.SYSTEM_MODE);
        draft.Status__c = 'Sent';
        draft.Signing_Order__c = 'Sequential';
        draft.PDF_Internal_Preview__c = delivery == 'preview';
        draft.Expires_At__c = DocGenSignatureExpiry.computeExpiry(integerValue(config, 'expirationDays'));
        draft.Snapshot_Taken_At__c = System.now();
        // Update only our fields: signer creation has already resolved verification settings.
        DocGen_Signature_Request__c sent = new DocGen_Signature_Request__c(
            Id = draft.Id,
            Status__c = draft.Status__c,
            // Mint at send time so resumed drafts also get the template flow's verify link.
            Secure_Token__c = DocGenSignatureSenderController.generateRequestVerificationToken(),
            Signing_Order__c = draft.Signing_Order__c,
            PDF_Internal_Preview__c = draft.PDF_Internal_Preview__c,
            Expires_At__c = draft.Expires_At__c,
            Snapshot_Taken_At__c = draft.Snapshot_Taken_At__c
        );
        DocGenFlsGuard.assertUpdateable(
            sent,
            new Set<String>{
                'Status__c',
                'Secure_Token__c',
                'Signing_Order__c',
                'PDF_Internal_Preview__c',
                'Expires_At__c',
                'Snapshot_Taken_At__c'
            }
        );
        Database.update(sent, AccessLevel.SYSTEM_MODE);
        if (delivery == 'preview') {
            for (DocGenSignatureSenderController.SignerResult signer : signers) {
                signer.signerUrl = signer.signerUrl.replace(siteUrl, URL.getOrgDomainUrl().toExternalForm());
            }
        }
        if (delivery == 'email') {
            DocGenSignatureSenderController.SignerResult first = signers[0];
            DocGenSignatureEmailService.sendSignatureRequestEmails(
                new List<DocGenSignatureEmailService.SignerEmail>{
                    new DocGenSignatureEmailService.SignerEmail(
                        first.signerName,
                        first.signerEmail,
                        first.roleName,
                        first.signerUrl,
                        null
                    )
                },
                draft.Document_Title_Format__c,
                draft.Id,
                text(config, 'message', 2000),
                text(config, 'subject', 255)
            );
        }
        String emailStatus = [
            SELECT Email_Status__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :draft.Id
            WITH SYSTEM_MODE
        ]
        .Email_Status__c;
        return new Map<String, Object>{
            'requestId' => draft.Id,
            'signers' => signers,
            'delivery' => delivery,
            'emailStatus' => emailStatus,
            'title' => draft.Document_Title_Format__c
        };
    }

    private static ContentVersion readablePdf(Id versionId) {
        List<ContentVersion> files = [
            SELECT Id, Title, ContentSize, FileExtension
            FROM ContentVersion
            WHERE Id = :versionId
            WITH USER_MODE
            LIMIT 1
        ];
        if (files.isEmpty() || files[0].FileExtension.toLowerCase() != 'pdf')
            fail('Choose an accessible PDF file.');
        if (files[0].ContentSize > MAX_PDF_BYTES)
            fail('This PDF is larger than 2 MB. Choose a smaller PDF.');
        return files[0];
    }

    private static DocGen_Signature_Request__c ownedDraft(Id recordId, Id draftId) {
        Id userId = UserInfo.getUserId();
        String relatedId = String.valueOf(recordId);
        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{
                'Status__c',
                'Related_Record_Id__c',
                'CreatedById',
                'Original_Document_CV_Id__c',
                'Preparation_Config_CV_Id__c',
                'PDF_Revision__c',
                'Document_Title_Format__c'
            }
        );
        // Owner/record-scoped draft lock; every read field is guarded above.
        // SFGE also reports the FOR UPDATE keyword as a field named UPDATE.
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signature_Request__c> drafts = [
            SELECT
                Id,
                Status__c,
                Related_Record_Id__c,
                Original_Document_CV_Id__c,
                Preparation_Config_CV_Id__c,
                PDF_Revision__c,
                Document_Title_Format__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :draftId AND CreatedById = :userId AND Related_Record_Id__c = :relatedId
            WITH SYSTEM_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (drafts.isEmpty() || drafts[0].Status__c != 'Draft' || String.isBlank(drafts[0].Original_Document_CV_Id__c))
            fail('This draft is unavailable or has already been sent. Refresh the record to continue.');
        return drafts[0];
    }

    private static void assertRevision(DocGen_Signature_Request__c draft, Integer expected) {
        if (expected == null || draft.PDF_Revision__c != expected)
            fail('This draft changed in another window. Reopen it before saving or sending.');
    }

    private static List<Map<String, Object>> availableBrands() {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        if (!Schema.sObjectType.DocGen_Brand__c.isAccessible())
            return result;
        for (DocGen_Brand__c brand : [
            SELECT Id, Name
            FROM DocGen_Brand__c
            WHERE Is_Active__c = TRUE
            WITH USER_MODE
            ORDER BY Name
            LIMIT 100
        ]) {
            result.add(new Map<String, Object>{ 'id' => brand.Id, 'name' => brand.Name });
        }
        return result;
    }

    private static void assertRecordAccess(Id recordId) {
        if (recordId == null || UserInfo.getUserType() == 'Guest')
            fail('Open the sender from a Salesforce record.');
        String objectName = recordId.getSObjectType().getDescribe().getName();
        List<SObject> records = Database.queryWithBinds(
            DocGenSignatureIpContext.publicQuery('SELECT Id FROM ' + objectName + ' WHERE Id = :rid LIMIT 1'),
            new Map<String, Object>{ 'rid' => recordId },
            AccessLevel.USER_MODE
        );
        if (records.isEmpty())
            fail('You do not have access to this record.');
        if (!Schema.sObjectType.DocGen_Signature_Request__c.isCreateable() && !Test.isRunningTest())
            fail('Ask your administrator for Portwood signature sender access.');
    }

    public static void assertSenderRecordAccess(Id recordId) {
        assertRecordAccess(recordId);
    }

    @TestVisible
    private static Map<String, Object> validateConfig(
        String configJson,
        DocGen_Signature_Request__c draft,
        Boolean sending
    ) {
        if (String.isBlank(configJson) || configJson.length() > 120000)
            fail('The preparation data is missing or too large.');
        Map<String, Object> config;
        try {
            config = (Map<String, Object>) JSON.deserializeUntyped(configJson);
        } catch (Exception ex) {
            fail('The preparation data could not be read. Reopen the draft.');
        }
        if ((String) config.get('documentId') != draft.Original_Document_CV_Id__c)
            fail('The prepared fields belong to a different PDF. Prepare the document again.');
        if (String.isBlank(text(config, 'title', 200)))
            fail('Enter a document title.');
        String brandId = text(config, 'brandId', 18);
        if (String.isNotBlank(brandId)) {
            Boolean found = false;
            for (Map<String, Object> brand : availableBrands()) {
                if (String.valueOf(brand.get('id')) == brandId)
                    found = true;
            }
            if (!found)
                fail('Choose an active Brand you can access, or use the org default.');
        }
        List<Object> recipients = listValue(config, 'recipients');
        List<Object> pages = listValue(config, 'pages');
        List<Object> fields = listValue(config, 'fields');
        if (recipients.size() > 10 || fields.size() > MAX_FIELDS || pages.size() > 50)
            fail('Use at most 10 recipients, 50 pages, and 100 fields.');
        if (sending && (recipients.isEmpty() || pages.isEmpty() || fields.isEmpty()))
            fail('Add recipients and place a signature for each recipient.');
        Set<String> recipientKeys = new Set<String>();
        Set<String> needsSignature = new Set<String>();
        for (Object item : recipients) {
            Map<String, Object> person = (Map<String, Object>) item;
            String key = text(person, 'key', 80);
            if (String.isBlank(key) || !recipientKeys.add(key))
                fail('Each recipient must have a unique identity.');
            if (
                sending &&
                (String.isBlank(text(person, 'name', 100)) ||
                !Pattern.matches('^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$', text(person, 'email', 100)))
            )
                fail('Enter a name and valid email for every recipient.');
            if (person.get('contactId') != null && String.isNotBlank((String) person.get('contactId'))) {
                Id contactId = (Id) person.get('contactId');
                if ([SELECT COUNT() FROM Contact WHERE Id = :contactId WITH USER_MODE] == 0)
                    fail('Choose a contact you can access.');
            }
            needsSignature.add(key);
        }
        for (Object item : pages) {
            Map<String, Object> page = (Map<String, Object>) item;
            Decimal width = numberValue(page, 'width'), height = numberValue(page, 'height');
            Integer rotation = integerValue(page, 'rotation');
            numberValue(page, 'x');
            numberValue(page, 'y');
            if (
                width <= 0 ||
                height <= 0 ||
                width > 20000 ||
                height > 20000 ||
                !new Set<Integer>{ 0, 90, 180, 270 }.contains(rotation)
            )
                fail('Unsupported PDF page geometry.');
        }
        Set<String> fieldKeys = new Set<String>();
        for (Object item : fields) {
            Map<String, Object> field = (Map<String, Object>) item;
            String key = text(field, 'id', 80), owner = text(field, 'recipientKey', 80);
            Integer pageNumber = integerValue(field, 'page');
            String type = text(field, 'type', 20);
            if (
                String.isBlank(key) ||
                !fieldKeys.add(key) ||
                !recipientKeys.contains(owner) ||
                !new Set<String>{ 'Full', 'Initials', 'Date', 'DatePick' }.contains(type) ||
                pageNumber == null ||
                pageNumber < 1 ||
                pageNumber > pages.size()
            )
                fail('Check each field and recipient assignment.');
            Map<String, Object> page = (Map<String, Object>) pages[pageNumber - 1];
            Decimal x = numberValue(field, 'x'),
                y = numberValue(field, 'y'),
                width = numberValue(field, 'width'),
                height = numberValue(field, 'height');
            if (
                width < 8 ||
                height < 8 ||
                x < numberValue(page, 'x') - 0.1 ||
                y < numberValue(page, 'y') - 0.1 ||
                x + width >
                numberValue(page, 'x') + numberValue(page, 'width') + 0.1 ||
                y + height >
                numberValue(page, 'y') + numberValue(page, 'height') + 0.1
            )
                fail('Keep each field inside its PDF page.');
            if (type == 'Full')
                needsSignature.remove(owner);
        }
        if (sending && !needsSignature.isEmpty())
            fail('Place at least one signature for every recipient.');
        Integer expiration = integerValue(config, 'expirationDays');
        if (expiration == null || expiration < 1 || expiration > 365)
            fail('Choose an expiration between 1 and 365 days.');
        if (sending && !new Set<String>{ 'preview', 'links', 'email' }.contains(text(config, 'delivery', 20)))
            fail('Choose how to deliver this request.');
        config.put('version', 1);
        return config;
    }

    private static List<Object> listValue(Map<String, Object> data, String key) {
        if (!(data.get(key) instanceof List<Object>))
            fail('Missing preparation section: ' + key);
        return (List<Object>) data.get(key);
    }
    private static String text(Map<String, Object> data, String key, Integer maxLength) {
        Object value = data.get(key);
        return value == null ? '' : String.valueOf(value).trim().left(maxLength);
    }
    private static Decimal numberValue(Map<String, Object> data, String key) {
        try {
            return Decimal.valueOf(String.valueOf(data.get(key)));
        } catch (Exception ex) {
            fail('Invalid PDF position: ' + key);
        }
        return 0;
    }
    private static Integer integerValue(Map<String, Object> data, String key) {
        Decimal value = numberValue(data, key);
        if (value != value.setScale(0))
            fail('Invalid whole number: ' + key);
        return value.intValue();
    }
    private static void fail(String message) {
        throw new PreparationException(message);
    }
    public class PreparationException extends Exception {
    }
}