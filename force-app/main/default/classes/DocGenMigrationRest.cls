/** Authenticated, record-scoped configuration migration transport for the Salesforce CLI. */
@RestResource(urlMapping='/portwood/migration/v1/*')
global with sharing class DocGenMigrationRest {
    private static final Integer MAX_BODY_BYTES = 1500000;
    private static final Integer MAX_FILE_BYTES = 10000000;
    private static final Integer MAX_FONT_FILE_BYTES = 9000000;
    private static final List<String> RESOURCES = new List<String>{
        'template',
        'snippet',
        'asset',
        'brand',
        'email',
        'settings',
        'font'
    };

    @HttpGet
    global static void readConfiguration() {
        if (!authorize())
            return;
        List<String> path = route();
        try {
            if (path.size() == 1 && path[0] == 'capabilities') {
                respond(200, new Map<String, Object>{ 'schemaVersion' => 2, 'resources' => RESOURCES });
            } else if (path.size() == 2 && path[0] == 'template') {
                Id templateId = Id.valueOf(path[1]);
                DocGen_Template__c template = [
                    SELECT Brand__c
                    FROM DocGen_Template__c
                    WHERE Id = :templateId
                    WITH USER_MODE
                ];
                assertReadableTemplateFiles(templateId);
                String exportJson = DocGenController.exportTemplateForMigration(templateId);
                Map<String, Object> bundle = (Map<String, Object>) JSON.deserializeUntyped(exportJson);
                if (bundle.get('templateFile') == null) {
                    throw new DocGenException('No readable active template file was exported.');
                }
                assertReadableExportAssets(bundle);
                bundle.put('brandId', template.Brand__c);
                respond(200, bundle);
            } else if (path.size() == 2 && path[0] == 'snippet') {
                Id assetId = Id.valueOf(path[1]);
                List<DocGen_Asset__c> readable = [SELECT Id FROM DocGen_Asset__c WHERE Id = :assetId WITH USER_MODE];
                if (readable.isEmpty())
                    throw new DocGenException('Snippet not found or not accessible.');
                Map<String, Object> snippet = DocGenSnippetController.getSnippet(assetId, null);
                respond(
                    200,
                    new Map<String, Object>{
                        'name' => snippet.get('name'),
                        'assetKey' => snippet.get('assetKey'),
                        'category' => snippet.get('category'),
                        'html' => snippet.get('html'),
                        'isActive' => snippet.get('isActive')
                    }
                );
            } else if (path.size() == 2 && path[0] == 'asset') {
                respond(200, readAsset(Id.valueOf(path[1])));
            } else if (path.size() == 2 && path[0] == 'brand') {
                respond(200, readBrand(Id.valueOf(path[1])));
            } else if (path.size() == 2 && path[0] == 'email') {
                respond(200, readEmail(Id.valueOf(path[1])));
            } else if (path.size() == 1 && path[0] == 'settings') {
                respond(200, readSettings());
            } else if (path.size() == 2 && path[0] == 'font') {
                respond(200, readFont(Id.valueOf(path[1])));
            } else if (path.size() == 2 && path[0] == 'font-job') {
                respond(200, DocGenFontController.getFontJobStatus(Id.valueOf(path[1])));
            } else if (path.size() == 2 && path[0] == 'font-revision') {
                String key = path[1];
                DocGen_Font_Face__c font = [
                    SELECT Id
                    FROM DocGen_Font_Face__c
                    WHERE Revision_Key__c = :key
                    WITH USER_MODE
                ];
                respond(200, new Map<String, Object>{ 'id' => font.Id });
            } else {
                reject(404, 'Unknown migration resource.');
            }
        } catch (Exception error) {
            reject(400, error.getMessage());
        }
    }

    @HttpPost
    global static void createConfiguration() {
        if (!authorize())
            return;
        List<String> path = route();
        Blob body = RestContext.request.requestBody;
        if (path.size() != 1 || !RESOURCES.contains(path[0])) {
            reject(404, 'Unknown migration resource.');
            return;
        }
        if (body == null || body.size() > MAX_BODY_BYTES) {
            reject(413, 'Migration resource exceeds the maximum request size of ' + MAX_BODY_BYTES + ' bytes.');
            return;
        }
        Savepoint checkpoint = Database.setSavepoint();
        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(body.toString());
            if (path[0] == 'template') {
                createTemplate(payload);
            } else if (path[0] == 'asset') {
                respond(201, new Map<String, Object>{ 'id' => createAsset(payload) });
            } else if (path[0] == 'brand') {
                respond(201, new Map<String, Object>{ 'id' => createBrand(payload) });
            } else if (path[0] == 'email') {
                respond(201, new Map<String, Object>{ 'id' => createEmail(payload) });
            } else if (path[0] == 'settings') {
                writeSettings(payload);
                respond(200, new Map<String, Object>{ 'id' => DocGen_Settings__c.getOrgDefaults().Id });
            } else if (path[0] == 'font') {
                respond(202, new Map<String, Object>{ 'jobId' => stageFont(payload) });
            } else {
                Map<String, Object> result = DocGenSnippetController.saveSnippet(
                    null,
                    (String) payload.get('name'),
                    (String) payload.get('assetKey'),
                    (String) payload.get('category'),
                    (String) payload.get('html'),
                    null,
                    (Boolean) payload.get('isActive')
                );
                respond(201, result);
            }
        } catch (Exception error) {
            Database.rollback(checkpoint);
            reject(400, error.getMessage());
        }
    }

    private static void assertReadableTemplateFiles(Id templateId) {
        List<DocGen_Template_Version__c> versions = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH USER_MODE
            LIMIT 2
        ];
        if (versions.size() != 1 || String.isBlank(versions[0].Content_Version_Id__c)) {
            throw new DocGenException('The template must have one readable active version with a file.');
        }
        Id versionId = Id.valueOf(versions[0].Content_Version_Id__c);
        if ([SELECT COUNT() FROM ContentVersion WHERE Id = :versionId WITH USER_MODE] != 1) {
            throw new DocGenException('The active template file is not readable.');
        }
    }

    private static void assertReadableExportAssets(Map<String, Object> bundle) {
        List<Object> assets = (List<Object>) bundle.get('assets');
        if (assets == null || assets.isEmpty())
            return;
        Set<Id> versions = new Set<Id>();
        for (Object item : assets) {
            Map<String, Object> asset = (Map<String, Object>) item;
            versions.add(Id.valueOf((String) asset.get('originalCvId')));
        }
        if ([SELECT COUNT() FROM ContentVersion WHERE Id IN :versions WITH USER_MODE] != versions.size()) {
            throw new DocGenException('One or more referenced template files are not readable.');
        }
    }

    private static Map<String, Object> readAsset(Id assetId) {
        DocGen_Asset__c asset = [
            SELECT
                Name,
                Asset_Key__c,
                Asset_Type__c,
                Category__c,
                Is_Active__c,
                (
                    SELECT ContentDocument.LatestPublishedVersionId
                    FROM ContentDocumentLinks
                    ORDER BY ContentDocument.CreatedDate DESC, ContentDocument.Id DESC
                    LIMIT 1
                )
            FROM DocGen_Asset__c
            WHERE Id = :assetId
            WITH USER_MODE
        ];
        if (asset.Asset_Type__c != null && asset.Asset_Type__c != 'Image') {
            throw new DocGenException('Only image assets can use the shared image migration resource.');
        }
        if (asset.ContentDocumentLinks.isEmpty())
            throw new DocGenException('The asset has no published file.');
        Id versionId = asset.ContentDocumentLinks[0].ContentDocument.LatestPublishedVersionId;
        return new Map<String, Object>{
            'name' => asset.Name,
            'assetKey' => asset.Asset_Key__c,
            'category' => asset.Category__c,
            'isActive' => asset.Is_Active__c,
            'file' => readableFile(versionId, MAX_FILE_BYTES)
        };
    }

    private static Id createAsset(Map<String, Object> payload) {
        String key = (String) payload.get('assetKey');
        if (String.isBlank(key) || key != DocGenAssetKeyHandler.normalizeKey(key)) {
            throw new DocGenException('A valid, canonical asset key is required.');
        }
        Map<String, Object> file = (Map<String, Object>) payload.get('file');
        ContentVersion staged = checkedStage(file, MAX_FILE_BYTES);
        if (
            !new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'svg', 'webp' }.contains(staged.FileExtension.toLowerCase())
        ) {
            throw new DocGenException('Unrecognized image file extension.');
        }
        Map<String, Object> created = DocGenController.createAsset((String) payload.get('name'), key);
        Id assetId = (Id) created.get('id');
        Database.update(new ContentVersion(Id = staged.Id, Title = (String) file.get('title')), AccessLevel.USER_MODE);
        DocGenController.addAssetVersion(assetId, staged.Id);
        Database.update(
            new DocGen_Asset__c(
                Id = assetId,
                Category__c = (String) payload.get('category'),
                Is_Active__c = (Boolean) payload.get('isActive')
            ),
            AccessLevel.USER_MODE
        );
        return assetId;
    }

    private static Map<String, Object> readableFile(Id versionId, Integer limitBytes) {
        ContentVersion version = [
            SELECT Title, FileExtension, ContentSize, Checksum, ContentLocation
            FROM ContentVersion
            WHERE Id = :versionId
            WITH USER_MODE
        ];
        if (version.ContentLocation != 'S' || version.ContentSize > limitBytes || String.isBlank(version.Checksum)) {
            throw new DocGenException('File must be stored in Salesforce and fit the migration size limit.');
        }
        return new Map<String, Object>{
            'id' => versionId,
            'title' => version.Title,
            'extension' => version.FileExtension,
            'size' => version.ContentSize,
            'checksum' => version.Checksum
        };
    }

    private static ContentVersion checkedStage(Map<String, Object> file, Integer limitBytes) {
        if (file == null)
            throw new DocGenException('A staged Salesforce File is required.');
        String name = (String) file.get('stagingTitle');
        if (String.isBlank(name) || !Pattern.matches('Portwood Migration Staging [0-9a-f-]{36}', name)) {
            throw new DocGenException('Expected a Portwood migration staging file.');
        }
        Id versionId = Id.valueOf((String) file.get('id'));
        ContentVersion version = [
            SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize, Checksum, ContentLocation
            FROM ContentVersion
            WHERE
                Id = :versionId
                AND IsLatest = TRUE
                AND OwnerId = :UserInfo.getUserId()
                AND CreatedById = :UserInfo.getUserId()
            WITH USER_MODE
        ];
        if (
            version.Title != name ||
            version.ContentLocation != 'S' ||
            version.ContentSize > limitBytes ||
            version.ContentSize != getInteger(file, 'size') ||
            String.isBlank(version.Checksum) ||
            !version.Checksum.equalsIgnoreCase((String) file.get('checksum')) ||
            !version.FileExtension.equalsIgnoreCase((String) file.get('extension'))
        ) {
            throw new DocGenException(
                'The staged File does not match the size, checksum, or extension expected by the migration.'
            );
        }
        ensurePrivateStage(version.ContentDocumentId);
        return version;
    }

    private static void ensurePrivateStage(Id documentId) {
        if (
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :documentId AND LinkedEntityId != :UserInfo.getUserId()
                WITH SYSTEM_MODE
            ] > 0
        ) {
            throw new DocGenException('A migration staging file must have no sharing links.');
        }
        if (
            Schema.getGlobalDescribe().containsKey('ContentDistribution') &&
            Database.countQueryWithBinds(
                'SELECT COUNT() FROM ContentDistribution WHERE ContentDocumentId = :documentId',
                new Map<String, Object>{ 'documentId' => documentId },
                AccessLevel.SYSTEM_MODE
            ) > 0
        ) {
            throw new DocGenException('A migration staging file must have no public deliveries.');
        }
    }

    @HttpDelete
    global static void discardStage() {
        if (!authorize())
            return;
        List<String> path = route();
        if (path.size() != 2 || path[0] != 'staging') {
            reject(404, 'Unknown migration resource.');
            return;
        }
        try {
            Id versionId = Id.valueOf(path[1]);
            ContentVersion version = [
                SELECT Title, ContentDocumentId
                FROM ContentVersion
                WHERE
                    Id = :versionId
                    AND IsLatest = TRUE
                    AND OwnerId = :UserInfo.getUserId()
                    AND CreatedById = :UserInfo.getUserId()
                WITH USER_MODE
            ];
            if (!Pattern.matches('Portwood Migration Staging [0-9a-f-]{36}', version.Title)) {
                throw new DocGenException('Only a private migration staging file can be discarded.');
            }
            ensurePrivateStage(version.ContentDocumentId);
            Database.delete(new ContentDocument(Id = version.ContentDocumentId), AccessLevel.USER_MODE);
            respond(200, new Map<String, Object>{ 'discarded' => true });
        } catch (Exception error) {
            reject(400, error.getMessage());
        }
    }

    private static Map<String, Object> readBrand(Id brandId) {
        DocGen_Brand__c brand = [
            SELECT
                Name,
                OWA_Id__c,
                Brand_Color__c,
                Logo_Url__c,
                Logo_Url_Extended__c,
                Logo_Asset_Key__c,
                Logo_Height__c,
                Company_Name__c,
                Footer_Text__c,
                Is_Active__c
            FROM DocGen_Brand__c
            WHERE Id = :brandId
            WITH USER_MODE
        ];
        return new Map<String, Object>{
            'name' => brand.Name,
            'owaId' => brand.OWA_Id__c,
            'brandColor' => brand.Brand_Color__c,
            'logoUrl' => String.isBlank(brand.Logo_Url_Extended__c) ? brand.Logo_Url__c : brand.Logo_Url_Extended__c,
            'logoAssetKey' => brand.Logo_Asset_Key__c,
            'logoHeight' => brand.Logo_Height__c,
            'companyName' => brand.Company_Name__c,
            'footerText' => brand.Footer_Text__c,
            'isActive' => brand.Is_Active__c
        };
    }

    private static Id createBrand(Map<String, Object> payload) {
        payload.remove('id');
        String name = (String) payload.get('name');
        if (String.isBlank(name) || [SELECT COUNT() FROM DocGen_Brand__c WHERE Name = :name WITH SYSTEM_MODE] > 0) {
            throw new DocGenException('A unique destination brand name is required.');
        }
        Id brandId = DocGenBrandController.saveBrand(payload);
        if (payload.get('logoHeight') != null) {
            Database.update(
                new DocGen_Brand__c(
                    Id = brandId,
                    Logo_Height__c = Decimal.valueOf(String.valueOf(payload.get('logoHeight')))
                ),
                AccessLevel.USER_MODE
            );
        }
        return brandId;
    }

    private static Map<String, Object> readEmail(Id emailId) {
        DocGen_Email_Template__c row = [
            SELECT
                Name,
                Description__c,
                Type__c,
                Subject__c,
                Body_Html__c,
                Body_Plain__c,
                Brand_Color__c,
                Logo_Url__c,
                Logo_Url_Extended__c,
                Logo_Asset_Key__c,
                Logo_Height__c,
                Footer_Text__c,
                Layout_Mode__c,
                Is_Active__c,
                Brand__c
            FROM DocGen_Email_Template__c
            WHERE Id = :emailId
            WITH USER_MODE
        ];
        return new Map<String, Object>{
            'name' => row.Name,
            'description' => row.Description__c,
            'type' => row.Type__c,
            'subject' => row.Subject__c,
            'bodyHtml' => row.Body_Html__c,
            'bodyPlain' => row.Body_Plain__c,
            'brandColor' => row.Brand_Color__c,
            'logoUrl' => String.isBlank(row.Logo_Url_Extended__c) ? row.Logo_Url__c : row.Logo_Url_Extended__c,
            'logoAssetKey' => row.Logo_Asset_Key__c,
            'logoHeight' => row.Logo_Height__c,
            'footerText' => row.Footer_Text__c,
            'layoutMode' => row.Layout_Mode__c == null ? DocGenEmailTemplateService.MODE_MANAGED : row.Layout_Mode__c,
            'isActive' => row.Is_Active__c,
            'brandId' => row.Brand__c
        };
    }

    private static Id createEmail(Map<String, Object> payload) {
        payload.remove('recordId');
        String type = (String) payload.get('type');
        Id brandId = checkedBrand(payload);
        if (
            [
                SELECT COUNT()
                FROM DocGen_Email_Template__c
                WHERE Type__c = :type AND Brand__c = :brandId
                WITH SYSTEM_MODE
            ] > 0
        ) {
            throw new DocGenException('Destination already has an email template for this type and brand.');
        }
        Id emailId = DocGenEmailTemplateController.saveTemplate(payload);
        if (payload.get('description') != null) {
            Database.update(
                new DocGen_Email_Template__c(Id = emailId, Description__c = (String) payload.get('description')),
                AccessLevel.USER_MODE
            );
        }
        return emailId;
    }

    private static Id checkedBrand(Map<String, Object> payload) {
        if (payload.get('brandId') == null)
            return null;
        Id brandId = Id.valueOf((String) payload.get('brandId'));
        if ([SELECT COUNT() FROM DocGen_Brand__c WHERE Id = :brandId WITH USER_MODE] != 1) {
            throw new DocGenException('The mapped sending brand is not readable in the destination org.');
        }
        return brandId;
    }

    private static Map<String, Object> readFont(Id fontId) {
        DocGen_Font_Face__c font = [
            SELECT
                Revision_Key__c,
                API_Name__c,
                Status__c,
                Asset__r.Asset_Key__c,
                Asset__r.Is_Active__c,
                Asset__r.Name,
                Asset__r.Category__c
            FROM DocGen_Font_Face__c
            WHERE Id = :fontId
            WITH USER_MODE
        ];
        if (font.Status__c == 'Retired' || !font.Asset__r.Is_Active__c) {
            throw new DocGenException('Retired or inactive fonts require review before transfer.');
        }
        DocGen_Font_Face__c registered = DocGenFontController.load(font.Revision_Key__c);
        ContentVersion source = DocGenFontController.sourceFile(registered);
        Map<String, Object> metadata = (Map<String, Object>) JSON.deserializeUntyped(registered.Metadata_JSON__c);
        String licenseText = (String) metadata.get('licenseText');
        if (String.isBlank(licenseText)) {
            throw new DocGenException('The font has no exact approved license text in its registry metadata.');
        }
        return new Map<String, Object>{
            'assetKey' => font.Asset__r.Asset_Key__c,
            'assetName' => font.Asset__r.Name,
            'assetCategory' => font.Asset__r.Category__c,
            'apiName' => font.API_Name__c,
            'revisionKey' => font.Revision_Key__c,
            'licenseText' => licenseText,
            'file' => readableFile(source.Id, MAX_FONT_FILE_BYTES),
            'status' => font.Status__c
        };
    }

    private static String stageFont(Map<String, Object> payload) {
        if (payload.get('hostingRightsConfirmed') != true) {
            throw new DocGenException('Confirm that the target can host and embed this font under its license.');
        }
        String expectedKey = (String) payload.get('revisionKey');
        if ([SELECT COUNT() FROM DocGen_Font_Face__c WHERE Revision_Key__c = :expectedKey WITH SYSTEM_MODE] > 0) {
            throw new DocGenException('This exact font revision already exists in the destination.');
        }
        ContentVersion staged = checkedStage((Map<String, Object>) payload.get('file'), MAX_FONT_FILE_BYTES);
        if (!'ttf'.equalsIgnoreCase(staged.FileExtension))
            throw new DocGenException('Expected a static TTF file.');
        if (
            !FeatureManagement.checkPermission('Manage_DocGen_Fonts') ||
            String.isBlank(expectedKey) ||
            !Pattern.matches('[a-f0-9]{64}', expectedKey)
        ) {
            throw new DocGenException('A valid font revision and Manage Portwood Fonts permission are required.');
        }
        return System.enqueueJob(
            new DocGenFontOperation(
                staged.Id,
                (String) payload.get('assetKey'),
                (String) payload.get('apiName'),
                (String) payload.get('licenseText'),
                expectedKey,
                (String) payload.get('assetName'),
                (String) payload.get('assetCategory')
            )
        );
    }

    private static Map<String, Object> readSettings() {
        DocGenFlsGuard.assertAccessible(
            DocGen_Settings__c.sObjectType,
            new Set<String>{
                'Experience_Site_Url__c',
                'Company_Name__c',
                'Signature_Email_Brand_Color__c',
                'Signature_Email_Logo_Url__c',
                'Signature_Email_Subject__c',
                'Signature_Email_Message__c',
                'Signature_Email_Footer_Text__c',
                'Signature_OWA_Id__c',
                'Signature_Reminder_Enabled__c',
                'Signature_Reminder_Hours__c',
                'Signature_Reminder_Schedule__c',
                'Signature_Expiration_Days__c',
                'Signature_Skip_Email_Verification__c',
                'Signature_Prefill_Signer_Email__c',
                'Signature_Hide_Decline__c',
                'Signature_Type_Only__c'
            }
        );
        return DocGenSetupController.getSettingsFresh();
    }

    private static void writeSettings(Map<String, Object> settings) {
        if (settings == null || settings.keySet() != readSettings().keySet()) {
            throw new DocGenException('Provide the complete supported settings payload.');
        }
        DocGenSetupController.saveSettings((String) settings.get('Experience_Site_Url__c'));
        DocGenSetupController.saveSignatureSettings(
            (String) settings.get('Signature_Email_Brand_Color__c'),
            (String) settings.get('Signature_Email_Logo_Url__c'),
            (String) settings.get('Signature_Email_Subject__c'),
            (String) settings.get('Signature_Email_Message__c'),
            (String) settings.get('Signature_Email_Footer_Text__c'),
            (String) settings.get('Company_Name__c'),
            (String) settings.get('Signature_OWA_Id__c')
        );
        DocGenSetupController.saveVerificationSettings(
            (Boolean) settings.get('Signature_Require_Email_Verification__c'),
            (Boolean) settings.get('Signature_Prefill_Signer_Email__c')
        );
        DocGenSetupController.saveDeclineSettings((Boolean) settings.get('Signature_Hide_Decline__c'));
        DocGenSetupController.saveSignatureInputSettings((Boolean) settings.get('Signature_Type_Only__c'));
        DocGenSetupController.saveReminderSettings(
            (Boolean) settings.get('Signature_Reminder_Enabled__c'),
            getInteger(settings, 'Signature_Reminder_Hours__c'),
            (String) settings.get('Signature_Reminder_Schedule__c'),
            getInteger(settings, 'Signature_Expiration_Days__c')
        );
    }

    private static Integer getInteger(Map<String, Object> source, String key) {
        return source.get(key) == null ? null : Decimal.valueOf(String.valueOf(source.get(key))).intValue();
    }

    private static void createTemplate(Map<String, Object> payload) {
        if (payload.get('docgenExportVersion') != '1' || payload.get('templateFile') == null) {
            throw new DocGenException('Expected a version 1 Portwood template export with an active file.');
        }
        Map<String, Object> template = (Map<String, Object>) payload.get('template');
        String apiName = template == null ? null : (String) template.get('API_Name__c');
        if (String.isBlank(apiName))
            throw new DocGenException('A template API name is required for migration.');
        if ([SELECT COUNT() FROM DocGen_Template__c WHERE API_Name__c = :apiName WITH SYSTEM_MODE] > 0) {
            throw new DocGenException('A template already uses the API name ' + apiName + '.');
        }
        Id brandId = checkedBrand(payload);
        Map<String, Object> fileData = (Map<String, Object>) payload.get('templateFile');
        Id templateId;
        if (fileData.get('file') == null) {
            templateId = DocGenController.importTemplateFromMigrationFile(JSON.serialize(payload), null);
        } else {
            ContentVersion staged = checkedStage((Map<String, Object>) fileData.get('file'), MAX_FILE_BYTES);
            if (
                !new Set<String>{ 'docx', 'xlsx', 'xlsm', 'pptx', 'pdf' }
                    .contains(staged.FileExtension.toLowerCase()) ||
                !staged.FileExtension.equalsIgnoreCase((String) fileData.get('fileExtension'))
            ) {
                throw new DocGenException('Template file extension is unsupported or does not match its package.');
            }
            templateId = DocGenController.importTemplateFromMigrationFile(JSON.serialize(payload), staged);
        }
        DocGen_Template__c imported = [
            SELECT API_Name__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH USER_MODE
        ];
        if (imported.API_Name__c != apiName)
            throw new DocGenException('The imported template did not preserve its API name.');
        if (brandId != null)
            Database.update(new DocGen_Template__c(Id = templateId, Brand__c = brandId), AccessLevel.USER_MODE);
        respond(201, new Map<String, Object>{ 'id' => templateId, 'apiName' => apiName });
    }

    private static Boolean authorize() {
        // Class access is required by Salesforce in addition to this custom permission.
        if (UserInfo.getUserType() == 'Guest' || !FeatureManagement.checkPermission('Migrate_DocGen_Configuration')) {
            reject(403, 'The Portwood configuration migration permission is required.');
            return false;
        }
        return true;
    }

    private static List<String> route() {
        String uri = RestContext.request.requestURI;
        return uri.substringAfter('/portwood/migration/v1/').split('/');
    }

    private static void respond(Integer statusCode, Object payload) {
        RestContext.response.statusCode = statusCode;
        RestContext.response.addHeader('Content-Type', 'application/json');
        RestContext.response.addHeader('Cache-Control', 'no-store');
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(payload));
    }

    private static void reject(Integer statusCode, String message) {
        respond(statusCode, new Map<String, Object>{ 'message' => message });
    }
}
