/** Font library in Assets. Exact, inspected Salesforce File versions back preview and native PDFs. */
public with sharing class DocGenFontController {
    public static Boolean authorizedMutation = false;
    private static final Integer MAX_FONT_ARCHIVE_BYTES = 25 * 1024 * 1024;
    private static final Set<String> FIELDS = new Set<String>{
        'Name',
        'Asset__c',
        'Revision_Key__c',
        'Source_CV_Id__c',
        'Source_Checksum__c',
        'Metadata_JSON__c',
        'License_Text__c',
        'Status__c',
        'Proof_CV_Id__c',
        'Verified_By__c',
        'Verified_At__c'
    };
    public static String digest(Blob bytes) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', bytes));
    }
    private static void admin() {
        if (!FeatureManagement.checkPermission('Manage_DocGen_Fonts'))
            throw new DocGenException('Manage Portwood Fonts permission is required.');
    }
    public static DocGen_Font_Face__c load(String key) {
        DocGenFlsGuard.assertAccessible(DocGen_Font_Face__c.sObjectType, FIELDS);
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Font_Face__c> rows = [
            SELECT
                Id,
                Name,
                Asset__c,
                Revision_Key__c,
                Source_CV_Id__c,
                Source_Checksum__c,
                Metadata_JSON__c,
                License_Text__c,
                Status__c,
                Proof_CV_Id__c,
                Verified_By__c,
                Verified_At__c
            FROM DocGen_Font_Face__c
            WHERE Revision_Key__c = :key
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (rows.isEmpty())
            throw new DocGenException('Registered font revision was not found or is inaccessible.');
        return rows[0];
    }
    private static void save(DocGen_Font_Face__c face) {
        authorizedMutation = true;
        try {
            if (face.Id == null) {
                DocGenFlsGuard.assertCreateable(face, FIELDS);
                // Explicit per-field create guard above covers every registry field, including Name.
                /* code-analyzer-suppress ApexFlsViolation */
                Database.insert(face, AccessLevel.SYSTEM_MODE);
            } else {
                DocGenFlsGuard.assertUpdateable(face, FIELDS);
                // Explicit per-field update guard above covers the loaded record and changes.
                /* code-analyzer-suppress ApexFlsViolation */
                Database.update(face, AccessLevel.SYSTEM_MODE);
            }
        } finally {
            authorizedMutation = false;
        }
    }
    @AuraEnabled
    public static List<Map<String, Object>> getFontFaces() {
        DocGenFlsGuard.assertAccessible(DocGen_Font_Face__c.sObjectType, FIELDS);
        DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, new Set<String>{ 'Is_Active__c', 'Asset_Key__c' });
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Font_Face__c> faces = [
            SELECT
                Id,
                Name,
                Revision_Key__c,
                Metadata_JSON__c,
                Status__c,
                Proof_CV_Id__c,
                Source_CV_Id__c,
                Asset__r.Is_Active__c,
                Asset__r.Asset_Key__c
            FROM DocGen_Font_Face__c
            WITH SYSTEM_MODE
            ORDER BY Name, CreatedDate DESC
            LIMIT 200
        ];
        Set<Id> versions = new Set<Id>();
        Set<String> names = new Set<String>();
        for (DocGen_Font_Face__c face : faces) {
            versions.add(Id.valueOf(face.Source_CV_Id__c));
            names.add('Portwood font preview ' + face.Revision_Key__c);
        }
        Map<String, String> previews = new Map<String, String>();
        DocGenFlsGuard.assertAccessible(
            ContentDistribution.sObjectType,
            new Set<String>{
                'Name',
                'ContentVersionId',
                'ContentDownloadUrl',
                'PreferencesLinkLatestVersion',
                'PreferencesAllowOriginalDownload'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        for (ContentDistribution delivery : [
            SELECT Name, ContentVersionId, ContentDownloadUrl
            FROM ContentDistribution
            WHERE
                ContentVersionId IN :versions
                AND Name IN :names
                AND PreferencesLinkLatestVersion = FALSE
                AND PreferencesAllowOriginalDownload = TRUE
            WITH SYSTEM_MODE
            LIMIT 200
        ]) {
            String url = delivery.ContentDownloadUrl;
            if (url != null && url.contains('/sfc/dist/version/download/'))
                previews.put(
                    delivery.Name + ':' + delivery.ContentVersionId,
                    url.substring(url.indexOf('/sfc/dist/version/download/'))
                );
        }
        // Permission is constant for the request; resolve it once per library.
        Boolean canManage = FeatureManagement.checkPermission('Manage_DocGen_Fonts');
        for (DocGen_Font_Face__c f : faces) {
            Map<String, Object> meta = catalogMetadata(f.Metadata_JSON__c);
            meta.put('id', f.Id);
            meta.put('key', f.Revision_Key__c);
            meta.put('label', f.Name);
            meta.put('assetKey', f.Asset__r.Asset_Key__c);
            meta.put('status', f.Status__c);
            meta.put('mergeTag', DocGenFontService.mergeTag(f.Asset__r.Asset_Key__c, f.Revision_Key__c));
            meta.put(
                'proofUrl',
                f.Proof_CV_Id__c == null ? null : '/sfc/servlet.shepherd/version/download/' + f.Proof_CV_Id__c
            );
            meta.put('selectable', f.Status__c == 'Verified' && f.Asset__r.Is_Active__c);
            meta.put('canManage', canManage);
            meta.put('fileUrl', fileUrl(f.Source_CV_Id__c));
            meta.put(
                'previewUrl',
                previews.get('Portwood font preview ' + f.Revision_Key__c + ':' + f.Source_CV_Id__c)
            );
            meta.put('previewFamily', 'PW_' + f.Revision_Key__c);
            out.add(meta);
        }
        return out;
    }
    /** Catalogs need scalar display data, not thousands of coverage entries or the complete license. */
    @TestVisible
    private static Map<String, Object> catalogMetadata(String source) {
        Map<String, Object> out = new Map<String, Object>();
        JSONParser parser = JSON.createParser(source);
        while (parser.nextToken() != null) {
            if (parser.getCurrentToken() != JSONToken.FIELD_NAME)
                continue;
            String key = parser.getText();
            JSONToken token = parser.nextToken();
            if (key == 'coverage' || key == 'licenseText') {
                parser.skipChildren();
            } else if (token == JSONToken.VALUE_STRING) {
                out.put(key, parser.getText());
            } else if (token == JSONToken.VALUE_NUMBER_INT) {
                out.put(key, parser.getLongValue());
            } else if (token == JSONToken.VALUE_NUMBER_FLOAT) {
                out.put(key, parser.getDecimalValue());
            } else if (token == JSONToken.VALUE_TRUE || token == JSONToken.VALUE_FALSE) {
                out.put(key, parser.getBooleanValue());
            } else if (token == JSONToken.VALUE_NULL) {
                out.put(key, null);
            } else {
                parser.skipChildren();
            }
        }
        // Existing pinned faces remain usable without rewriting immutable metadata.
        if (!out.containsKey('hasCedilla'))
            out.put('hasCedilla', legacyCedillaCoverage(source));
        return out;
    }
    private static Boolean legacyCedillaCoverage(String source) {
        JSONParser parser = JSON.createParser(source);
        Boolean upper = false, lower = false;
        while (parser.nextToken() != null) {
            if (parser.getCurrentToken() != JSONToken.FIELD_NAME)
                continue;
            String key = parser.getText();
            parser.nextToken();
            if (key != 'coverage') {
                parser.skipChildren();
                continue;
            }
            while (parser.nextToken() != JSONToken.END_ARRAY) {
                parser.nextToken();
                Integer lo = parser.getIntegerValue();
                parser.nextToken();
                Integer hi = parser.getIntegerValue();
                parser.nextToken();
                upper = upper || lo <= 350 && hi >= 350;
                lower = lower || lo <= 351 && hi >= 351;
                if (lo > 351 || upper && lower)
                    return upper && lower;
            }
            return upper && lower;
        }
        return false;
    }
    // Small server-side fixtures use this helper; the UI uploads through native Files.
    public static String stageFont(
        String filename,
        String base64Data,
        String fontKey,
        String licenseText,
        Boolean hostingRightsConfirmed
    ) {
        validateUpload(fontKey, licenseText, hostingRightsConfirmed);
        if (String.isBlank(base64Data) || base64Data.length() > 12582912)
            throw new DocGenException('Choose a valid static TTF up to 9 MB.');
        Blob bytes = EncodingUtil.base64Decode(base64Data);
        Map<String, Object> meta = new DocGenFontInspector(bytes).inspect(filename);
        return stageInspected(meta, fontKey, licenseText, bytes, null);
    }
    private static void validateUpload(String fontKey, String licenseText, Boolean hostingRightsConfirmed) {
        admin();
        validateLicense(licenseText, hostingRightsConfirmed);
        String normalized = DocGenAssetKeyHandler.normalizeKey(fontKey);
        if (String.isBlank(normalized) || normalized != fontKey || fontKey.length() > 40)
            throw new DocGenException('Use a font key of up to 40 lowercase letters, numbers and hyphens.');
    }
    private static void validateLicense(String licenseText, Boolean hostingRightsConfirmed) {
        if (hostingRightsConfirmed != true)
            throw new DocGenException('Confirm the license permits public font previews and PDF embedding.');
        if (String.isBlank(licenseText) || Blob.valueOf(licenseText).size() > 65536)
            throw new DocGenException('Include the font license text (up to 64 KiB).');
    }
    private static ContentVersion ownedUpload(Id documentId) {
        return ownedUpload(documentId, '.ttf', 'Choose a valid static TTF up to 9 MB.');
    }
    private static ContentVersion ownedArchiveUpload(Id documentId) {
        return ownedUpload(documentId, '.zip', 'Choose a ZIP archive containing static TTF fonts up to 25 MB.');
    }
    private static ContentVersion ownedUpload(Id documentId, String extension, String errorMessage) {
        DocGenFlsGuard.assertAccessible(ContentDocument.sObjectType, new Set<String>{ 'OwnerId' });
        DocGenFlsGuard.assertAccessible(
            ContentVersion.sObjectType,
            new Set<String>{ 'Title', 'PathOnClient', 'ContentDocumentId', 'CreatedById', 'ContentSize', 'IsLatest' }
        );
        // Uploads have no record-id and remain private to their uploader until registration.
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> files = [
            SELECT Id, Title, PathOnClient, ContentDocumentId, CreatedById, ContentSize
            FROM ContentVersion
            WHERE
                ContentDocumentId = :documentId
                AND CreatedById = :UserInfo.getUserId()
                AND ContentDocument.OwnerId = :UserInfo.getUserId()
                AND IsLatest = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (files.isEmpty())
            throw new DocGenException('Upload a new font File using your own account.');
        ContentVersion cv = files[0];
        if (
            cv.ContentSize < 12 ||
            (extension == '.ttf' &&
            cv.ContentSize > DocGenFontInspector.MAX_FONT_BYTES) ||
            (extension == '.zip' &&
            cv.ContentSize > MAX_FONT_ARCHIVE_BYTES) ||
            String.isBlank(cv.PathOnClient) ||
            !cv.PathOnClient.toLowerCase().endsWith(extension)
        )
            throw new DocGenException(errorMessage);
        return cv;
    }
    @AuraEnabled
    public static String importUploadedFont(
        Id contentDocumentId,
        String fontKey,
        String licenseText,
        Boolean hostingRightsConfirmed
    ) {
        validateUpload(fontKey, licenseText, hostingRightsConfirmed);
        ContentVersion cv = ownedUpload(contentDocumentId);
        return System.enqueueJob(new DocGenFontOperation('Import', cv.Id, fontKey, licenseText, null));
    }
    @AuraEnabled
    public static String importUploadedFontArchive(
        Id contentDocumentId,
        String licenseText,
        Boolean hostingRightsConfirmed
    ) {
        admin();
        validateLicense(licenseText, hostingRightsConfirmed);
        ContentVersion cv = ownedArchiveUpload(contentDocumentId);
        return System.enqueueJob(new DocGenFontOperation('ImportArchive', cv.Id, null, licenseText, null));
    }
    public static void inspectUploadedFont(Id versionId, String fontKey, String licenseText) {
        validateUpload(fontKey, licenseText, true);
        DocGenFlsGuard.assertAccessible(ContentDocument.sObjectType, new Set<String>{ 'OwnerId' });
        DocGenFlsGuard.assertAccessible(
            ContentVersion.sObjectType,
            new Set<String>{ 'VersionData', 'PathOnClient', 'ContentDocumentId', 'CreatedById', 'ContentSize' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        ContentVersion cv = [
            SELECT Id, VersionData, PathOnClient, ContentDocumentId, ContentSize
            FROM ContentVersion
            WHERE
                Id = :versionId
                AND CreatedById = :UserInfo.getUserId()
                AND ContentDocument.OwnerId = :UserInfo.getUserId()
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cv.ContentSize > DocGenFontInspector.MAX_FONT_BYTES)
            throw new DocGenException('Choose a valid static TTF up to 9 MB.');
        String filename = cv.PathOnClient.replace('\\', '/');
        if (filename.contains('/'))
            filename = filename.substringAfterLast('/');
        Map<String, Object> meta = new DocGenFontInspector(cv.VersionData).inspect(filename);
        assertNativePdfCompatible(meta);
        String key = stageInspected(meta, fontKey, licenseText, null, cv);
        ensureFontPreview(key);
    }
    public static void inspectUploadedFontArchive(Id versionId, String licenseText) {
        admin();
        validateLicense(licenseText, true);
        DocGenFlsGuard.assertAccessible(ContentDocument.sObjectType, new Set<String>{ 'OwnerId' });
        DocGenFlsGuard.assertAccessible(
            ContentVersion.sObjectType,
            new Set<String>{ 'VersionData', 'PathOnClient', 'ContentDocumentId', 'CreatedById', 'ContentSize' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        ContentVersion archive = [
            SELECT Id, VersionData, PathOnClient, ContentDocumentId, ContentSize
            FROM ContentVersion
            WHERE
                Id = :versionId
                AND CreatedById = :UserInfo.getUserId()
                AND ContentDocument.OwnerId = :UserInfo.getUserId()
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (
            archive.ContentSize > MAX_FONT_ARCHIVE_BYTES ||
            String.isBlank(archive.PathOnClient) ||
            !archive.PathOnClient.toLowerCase().endsWith('.zip')
        )
            throw new DocGenException('Choose a ZIP archive containing static TTF fonts up to 25 MB.');

        Compression.ZipReader reader = new Compression.ZipReader(archive.VersionData);
        Set<String> usedKeys = new Set<String>();
        Integer fontCount = 0;
        for (Compression.ZipEntry entry : reader.getEntries()) {
            String path = entry.getName();
            if (String.isBlank(path) || path.endsWith('/') || path.startsWith('__MACOSX/'))
                continue;
            String filename = path.contains('/') ? path.substringAfterLast('/') : path;
            if (String.isBlank(filename) || filename.startsWith('._') || !filename.toLowerCase().endsWith('.ttf'))
                continue;
            fontCount++;
            if (fontCount > 200)
                throw new DocGenException('A font ZIP can contain at most 200 TTF files.');
            String key = archiveFontKey(filename, usedKeys);
            inspectArchiveEntry(reader.extract(entry), filename, key, licenseText);
        }
        if (fontCount == 0)
            throw new DocGenException('The ZIP archive does not contain any .ttf font files.');
    }
    public static String inspectArchiveEntry(Blob bytes, String filename, String fontKey, String licenseText) {
        validateUpload(fontKey, licenseText, true);
        Map<String, Object> meta = new DocGenFontInspector(bytes).inspect(filename);
        assertNativePdfCompatible(meta);
        String key = stageInspected(meta, fontKey, licenseText, bytes, null);
        ensureFontPreview(key);
        return key;
    }

    /**
     * Reject files whose advertised character coverage cannot be rendered by the
     * native PDF engine. The browser can preview these fonts, but Flying Saucer's
     * custom-font path is limited to the UTF-16 BMP (U+0000..U+FFFF). Validate this
     * before creating the Asset, source File link, or DocGen_Font_Face__c row.
     */
    private static void assertNativePdfCompatible(Map<String, Object> meta) {
        List<Object> coverage = (List<Object>) meta.get('coverage');
        if (coverage == null)
            return;
        for (Object item : coverage) {
            List<Object> range = (List<Object>) item;
            Integer first = Integer.valueOf(range[0]);
            Integer last = Integer.valueOf(range[1]);
            if (last > 65535) {
                Integer codePoint = Math.max(first, 65536);
                String digits = '0123456789ABCDEF';
                String hex = '';
                Integer value = codePoint;
                while (value > 0) {
                    hex = digits.substring(Math.mod(value, 16), Math.mod(value, 16) + 1) + hex;
                    value = value / 16;
                }
                while (hex.length() < 4)
                    hex = '0' + hex;
                throw new DocGenException(
                    'Font ' +
                        meta.get('family') +
                        ' is not supported by the Salesforce native PDF renderer because it contains supplementary Unicode characters such as U+' +
                        hex +
                        ' (> U+FFFF). Upload a BMP-only static TTF font.'
                );
            }
        }
    }
    private static String archiveFontKey(String filename, Set<String> usedKeys) {
        String base = DocGenAssetKeyHandler.normalizeKey(filename.substringBeforeLast('.'));
        if (String.isBlank(base))
            base = 'font';
        String key = base;
        Integer suffix = 2;
        while (usedKeys.contains(key)) {
            String suffixText = '-' + String.valueOf(suffix);
            Integer keep = Math.max(1, 40 - suffixText.length());
            key = base.length() > keep ? base.substring(0, keep) + suffixText : base + suffixText;
            suffix++;
        }
        usedKeys.add(key);
        return key;
    }
    private static String stageInspected(
        Map<String, Object> meta,
        String fontKey,
        String licenseText,
        Blob bytes,
        ContentVersion uploaded
    ) {
        String licenseHash = digest(Blob.valueOf(licenseText));
        meta.put('licenseSha256', licenseHash);
        // Long Text Area storage can trim trailing newlines. JSON preserves the licensed bytes.
        meta.put('licenseText', licenseText);
        if (JSON.serialize(meta).length() > 131072)
            throw new DocGenException('Font coverage and license metadata exceed the registry capacity.');
        String key = digest(Blob.valueOf((String) meta.get('sha256') + ':' + licenseHash));
        List<DocGen_Font_Face__c> existing = [
            SELECT Id
            FROM DocGen_Font_Face__c
            WHERE Revision_Key__c = :key
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            DocGen_Font_Face__c prior = load(key);
            Map<String, Object> oldMeta = (Map<String, Object>) JSON.deserializeUntyped(prior.Metadata_JSON__c);
            if (prior.Status__c == 'Staged' && !oldMeta.containsKey('licenseText')) {
                oldMeta.put('licenseText', licenseText);
                prior.Metadata_JSON__c = JSON.serialize(oldMeta);
                save(prior);
            }
            return key;
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Asset__c.sObjectType,
            new Set<String>{ 'Asset_Key__c', 'Asset_Type__c', 'Is_Active__c' }
        );
        List<DocGen_Asset__c> assets = [
            SELECT Id, Asset_Type__c, Is_Active__c
            FROM DocGen_Asset__c
            WHERE Asset_Key__c = :fontKey
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        DocGen_Asset__c asset;
        if (assets.isEmpty()) {
            asset = new DocGen_Asset__c(
                Name = String.valueOf(
                    meta.get('preferredFamily') == null ? meta.get('family') : meta.get('preferredFamily')
                ),
                Asset_Key__c = fontKey,
                Asset_Type__c = 'Font',
                Category__c = 'Fonts',
                Is_Active__c = true
            );
            DocGenFlsGuard.assertCreateable(
                asset,
                new Set<String>{ 'Name', 'Asset_Key__c', 'Asset_Type__c', 'Category__c', 'Is_Active__c' }
            );
            Database.insert(asset, AccessLevel.SYSTEM_MODE);
        } else {
            asset = assets[0];
            if (asset.Asset_Type__c != 'Font' || !asset.Is_Active__c)
                throw new DocGenException(
                    'Choose an active font asset key. This key belongs to another asset type or is retired.'
                );
        }
        ContentVersion source = uploaded;
        if (source == null) {
            source = new ContentVersion(
                Title = 'Portwood font source ' + key,
                PathOnClient = (String) meta.get('filename'),
                VersionData = bytes,
                FirstPublishLocationId = asset.Id
            );
            DocGenFlsGuard.assertCreateable(
                source,
                new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId' }
            );
            Database.insert(source, AccessLevel.SYSTEM_MODE);
        } else {
            ContentDocumentLink link = new ContentDocumentLink(
                ContentDocumentId = source.ContentDocumentId,
                LinkedEntityId = asset.Id,
                ShareType = 'V',
                Visibility = 'AllUsers'
            );
            DocGenFlsGuard.assertCreateable(
                link,
                new Set<String>{ 'ContentDocumentId', 'LinkedEntityId', 'ShareType', 'Visibility' }
            );
            Database.insert(link, AccessLevel.SYSTEM_MODE);
        }
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Checksum' });
        Id sourceVersionId = source.Id;
        // Pin Salesforce's checksum after SHA-256 inspection; no font bytes are read during rendering.
        /* code-analyzer-suppress ApexFlsViolation */
        String sourceChecksum = [
            SELECT Checksum
            FROM ContentVersion
            WHERE Id = :sourceVersionId
            WITH SYSTEM_MODE
            LIMIT 1
        ]
        .Checksum;
        save(
            new DocGen_Font_Face__c(
                Name = (String) meta.get('family') + ' / ' + (String) meta.get('subfamily'),
                Asset__c = asset.Id,
                Revision_Key__c = key,
                Metadata_JSON__c = JSON.serialize(meta),
                License_Text__c = licenseText,
                Source_CV_Id__c = source.Id,
                Source_Checksum__c = sourceChecksum,
                Status__c = 'Staged'
            )
        );
        return key;
    }
    public static Boolean isStagedLicenseRecovery(DocGen_Font_Face__c oldFace, DocGen_Font_Face__c newFace) {
        if (oldFace.Status__c != 'Staged' || newFace.Status__c != 'Staged')
            return false;
        Map<String, Object> before = (Map<String, Object>) JSON.deserializeUntyped(oldFace.Metadata_JSON__c);
        Map<String, Object> after = (Map<String, Object>) JSON.deserializeUntyped(newFace.Metadata_JSON__c);
        if (
            before.containsKey('licenseText') ||
            !(after.get('licenseText') instanceof String) ||
            digest(Blob.valueOf((String) after.get('licenseText'))) != (String) before.get('licenseSha256')
        )
            return false;
        after.remove('licenseText');
        if (before.keySet() != after.keySet())
            return false;
        for (String field : before.keySet())
            if (JSON.serialize(before.get(field)) != JSON.serialize(after.get(field)))
                return false;
        return true;
    }
    /** Browser fonts require same-origin delivery; the native PDF uses the authenticated File URL. */
    public static void ensureFontPreview(String key) {
        admin();
        DocGen_Font_Face__c face = load(key);
        ContentVersion file = sourceFile(face);
        String name = 'Portwood font preview ' + key;
        Id versionId = file.Id;
        DocGenFlsGuard.assertAccessible(
            ContentDistribution.sObjectType,
            new Set<String>{
                'Name',
                'ContentVersionId',
                'PreferencesLinkLatestVersion',
                'PreferencesAllowOriginalDownload'
            }
        );
        if (
            [
                SELECT COUNT()
                FROM ContentDistribution
                WHERE
                    Name = :name
                    AND ContentVersionId = :versionId
                    AND PreferencesLinkLatestVersion = FALSE
                    AND PreferencesAllowOriginalDownload = TRUE
                WITH SYSTEM_MODE
            ] > 0
        )
            return;
        ContentDistribution preview = new ContentDistribution(
            Name = name,
            ContentVersionId = versionId,
            PreferencesAllowViewInBrowser = true,
            PreferencesAllowOriginalDownload = true,
            PreferencesLinkLatestVersion = false,
            PreferencesNotifyOnVisit = false
        );
        DocGenFlsGuard.assertCreateable(
            preview,
            new Set<String>{
                'Name',
                'ContentVersionId',
                'PreferencesAllowViewInBrowser',
                'PreferencesAllowOriginalDownload',
                'PreferencesLinkLatestVersion',
                'PreferencesNotifyOnVisit'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(preview, AccessLevel.SYSTEM_MODE);
    }
    /** iText identifies the font by the URL suffix, including its query string. */
    public static String fileUrl(String versionId) {
        return '/sfc/servlet.shepherd/version/download/' + Id.valueOf(versionId) + '?font.ttf';
    }
    /** Scope internal Files reads to the registered asset; never load VersionData during generation. */
    public static ContentVersion sourceFile(DocGen_Font_Face__c face) {
        Id assetId = face.Asset__c;
        DocGenFlsGuard.assertAccessible(
            ContentDocumentLink.sObjectType,
            new Set<String>{ 'ContentDocumentId', 'LinkedEntityId' }
        );
        Set<Id> docs = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :assetId
            WITH SYSTEM_MODE
        ])
            docs.add(link.ContentDocumentId);
        DocGenFlsGuard.assertAccessible(
            ContentVersion.sObjectType,
            new Set<String>{ 'ContentDocumentId', 'ContentSize', 'Checksum' }
        );
        Id versionId = Id.valueOf(face.Source_CV_Id__c);
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> files = [
            SELECT Id, ContentDocumentId, ContentSize, Checksum
            FROM ContentVersion
            WHERE Id = :versionId AND ContentDocumentId IN :docs
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(face.Metadata_JSON__c);
        if (
            files.isEmpty() ||
            (m.containsKey('sizeBytes') && files[0].ContentSize != Integer.valueOf(m.get('sizeBytes')))
        )
            throw new DocGenException(
                'The original font File is missing or changed. Restore its exact version or upload a new font revision.'
            );
        if (face.Source_Checksum__c != null && files[0].Checksum != face.Source_Checksum__c)
            throw new DocGenException(
                'Font File content changed. Restore its immutable version or upload a new font revision.'
            );
        return files[0];
    }
    /** Migrate previously staged resource-era revisions by proving their original File bytes once. */
    private static Boolean pinSourceFile(DocGen_Font_Face__c face) {
        ContentVersion file = sourceFile(face);
        if (face.Source_Checksum__c != null)
            return false;
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
        Id versionId = file.Id;
        /* code-analyzer-suppress ApexFlsViolation */
        ContentVersion bytes = [SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH SYSTEM_MODE LIMIT 1];
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(face.Metadata_JSON__c);
        if (digest(bytes.VersionData) != (String) m.get('sha256'))
            throw new DocGenException(
                'The original font File no longer matches the inspected font. Upload a new revision.'
            );
        face.Source_Checksum__c = file.Checksum;
        return true;
    }
    @AuraEnabled
    public static String startFontProof(String key) {
        admin();
        load(key);
        return System.enqueueJob(new DocGenFontOperation('Proof', null, key, null, null));
    }
    @AuraEnabled
    public static Map<String, Object> getFontJobStatus(Id jobId) {
        admin();
        List<AsyncApexJob> jobs = [
            SELECT Status, ExtendedStatus
            FROM AsyncApexJob
            WHERE Id = :jobId AND CreatedById = :UserInfo.getUserId() AND ApexClass.Name = 'DocGenFontOperation'
            LIMIT 1
        ];
        if (jobs.isEmpty())
            throw new DocGenException('Font operation was not found for your account.');
        Map<String, Object> result = new Map<String, Object>{ 'status' => jobs[0].Status };
        if (jobs[0].Status == 'Failed' || jobs[0].Status == 'Aborted')
            result.put(
                'error',
                String.isBlank(jobs[0].ExtendedStatus)
                    ? 'Font operation failed. Retry or check Apex Jobs.'
                    : jobs[0].ExtendedStatus
            );
        return result;
    }
    private static void assertProofPresent(DocGen_Font_Face__c f) {
        Id assetId = f.Asset__c;
        Set<Id> docs = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :assetId
            WITH SYSTEM_MODE
        ])
            docs.add(link.ContentDocumentId);
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
        Id cvId = String.isBlank(f.Proof_CV_Id__c) ? null : Id.valueOf(f.Proof_CV_Id__c);
        if ([SELECT COUNT() FROM ContentVersion WHERE Id = :cvId AND ContentDocumentId IN :docs WITH SYSTEM_MODE] == 0)
            throw new DocGenException(
                'The current native specimen is missing. Restore its File before approving or using the existing proof.'
            );
    }
    @AuraEnabled
    public static String createFontProof(String key) {
        admin();
        DocGen_Font_Face__c f = load(key);
        if (f.Status__c == 'Retired')
            throw new DocGenException(
                'Retired fonts retain their approved specimen. Upload a new revision to make changes.'
            );
        Boolean migrated = pinSourceFile(f);
        ensureFontPreview(key);
        if (f.Status__c == 'Verified' && !migrated) {
            assertProofPresent(f);
            return f.Proof_CV_Id__c;
        }
        Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(f.Metadata_JSON__c);
        String sample = DocGenFontService.specimenText(m);
        DocGenFontService.checkText(m, sample);
        String instructions = DocGenFontService.hasGlyph(m, 350) && DocGenFontService.hasGlyph(m, 351)
            ? 'Inspect embedded font identity, live text and the actual U+015E / U+015F glyph runs before approving.'
            : 'Inspect embedded font identity, live text and the glyphs this face covers before approving. This face does not contain U+015E / U+015F.';
        String html =
            '<html><head><meta charset="utf-8"/><style>@page{size:letter;margin:0.7in;}' +
            DocGenFontService.faceCss(f) +
            '</style></head><body><p>Portwood native font specimen</p><h1 style="font-family:&quot;' +
            m.get('family') +
            '&quot;;font-weight:' +
            m.get('weight') +
            ';font-style:' +
            m.get('style') +
            ';font-size:32pt;">' +
            sample.escapeHtml4() +
            '</h1><p>' +
            f.Name.escapeHtml4() +
            '</p><p>' +
            instructions +
            '</p></body></html>';
        Blob pdf = Test.isRunningTest() ? Blob.valueOf('%PDF-test') : Blob.toPdf(html);
        ContentVersion proof = new ContentVersion(
            Title = 'Portwood font specimen ' + f.Name,
            PathOnClient = 'font-specimen.pdf',
            VersionData = pdf,
            FirstPublishLocationId = f.Asset__c
        );
        DocGenFlsGuard.assertCreateable(
            proof,
            new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId' }
        );
        Database.insert(proof, AccessLevel.SYSTEM_MODE);
        f.Proof_CV_Id__c = proof.Id;
        f.Status__c = 'Published';
        f.Verified_At__c = null;
        f.Verified_By__c = null;
        save(f);
        return proof.Id;
    }
    @AuraEnabled
    public static void verifyFont(String key, String proofVersionId, Boolean reviewed) {
        admin();
        DocGen_Font_Face__c f = load(key);
        sourceFile(f);
        if (f.Source_Checksum__c == null)
            throw new DocGenException('Generate the native PDF specimen from the original font File first.');
        if (
            reviewed != true ||
            f.Status__c != 'Published' ||
            String.isBlank(proofVersionId) ||
            proofVersionId != f.Proof_CV_Id__c
        )
            throw new DocGenException('Review the current native PDF specimen before approving this font.');
        assertProofPresent(f);
        f.Status__c = 'Verified';
        f.Verified_At__c = System.now();
        f.Verified_By__c = UserInfo.getUserId();
        save(f);
    }
    @AuraEnabled
    public static void verifyFonts(List<String> keys, Boolean reviewed) {
        admin();
        if (reviewed != true || keys == null || keys.isEmpty())
            throw new DocGenException('Select fonts and confirm you reviewed each current PDF specimen.');
        Set<String> requested = new Set<String>();
        for (String key : keys) {
            if (String.isBlank(key))
                throw new DocGenException('Every selected font must have a revision key.');
            requested.add(key);
        }
        if (requested.size() > 25)
            throw new DocGenException('Approve no more than 25 fonts in one action.');
        DocGenFlsGuard.assertAccessible(DocGen_Font_Face__c.sObjectType, FIELDS);
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Font_Face__c> faces = [
            SELECT
                Id,
                Name,
                Asset__c,
                Revision_Key__c,
                Source_CV_Id__c,
                Source_Checksum__c,
                Metadata_JSON__c,
                License_Text__c,
                Status__c,
                Proof_CV_Id__c,
                Verified_By__c,
                Verified_At__c
            FROM DocGen_Font_Face__c
            WHERE Revision_Key__c IN :requested
            WITH SYSTEM_MODE
        ];
        if (faces.size() != requested.size())
            throw new DocGenException('One or more selected font revisions no longer exists. Refresh the font list.');
        for (DocGen_Font_Face__c f : faces) {
            sourceFile(f);
            if (f.Source_Checksum__c == null || f.Status__c != 'Published' || String.isBlank(f.Proof_CV_Id__c))
                throw new DocGenException(
                    'Every selected font must have a current native PDF specimen ready for approval.'
                );
            assertProofPresent(f);
            f.Status__c = 'Verified';
            f.Verified_At__c = System.now();
            f.Verified_By__c = UserInfo.getUserId();
        }
        DocGenFlsGuard.assertUpdateable(faces[0], FIELDS);
        authorizedMutation = true;
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(faces, AccessLevel.SYSTEM_MODE);
        } finally {
            authorizedMutation = false;
        }
    }
    @AuraEnabled
    public static void retireFont(String key) {
        admin();
        DocGen_Font_Face__c f = load(key);
        if (f.Status__c != 'Verified')
            throw new DocGenException(
                'Only a verified face can be retired. Staged or unreviewed faces cannot become renderable.'
            );
        f.Status__c = 'Retired';
        save(f);
    }
    @AuraEnabled
    public static void retireFonts(List<String> keys) {
        admin();
        if (keys == null || keys.isEmpty())
            throw new DocGenException('Select at least one approved font to retire.');
        Set<String> requested = new Set<String>(keys);
        if (requested.size() > 25)
            throw new DocGenException('Retire no more than 25 fonts in one action.');
        DocGenFlsGuard.assertAccessible(DocGen_Font_Face__c.sObjectType, FIELDS);
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Font_Face__c> faces = [
            SELECT Id, Revision_Key__c, Status__c
            FROM DocGen_Font_Face__c
            WHERE Revision_Key__c IN :requested
            WITH SYSTEM_MODE
        ];
        if (faces.size() != requested.size())
            throw new DocGenException('One or more selected font revisions no longer exists. Refresh the font list.');
        for (DocGen_Font_Face__c f : faces)
            if (f.Status__c != 'Verified')
                throw new DocGenException('Only approved fonts can be retired.');
        for (DocGen_Font_Face__c f : faces)
            f.Status__c = 'Retired';
        DocGenFlsGuard.assertUpdateable(faces[0], FIELDS);
        authorizedMutation = true;
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(faces, AccessLevel.SYSTEM_MODE);
        } finally {
            authorizedMutation = false;
        }
    }
    @AuraEnabled
    public static void deleteRetiredFont(String key) {
        admin();
        if (!Schema.sObjectType.DocGen_Font_Face__c.isDeletable())
            throw new DocGenException('Insufficient access to delete retired fonts.');
        DocGen_Font_Face__c f = load(key);
        if (f.Status__c != 'Retired')
            throw new DocGenException('Only a retired font can be deleted. Active and approved fonts are protected.');
        authorizedMutation = true;
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.delete(f.Id, AccessLevel.SYSTEM_MODE);
        } finally {
            authorizedMutation = false;
        }
    }
    @AuraEnabled
    public static void deleteRetiredFonts(List<String> keys) {
        admin();
        if (!Schema.sObjectType.DocGen_Font_Face__c.isDeletable())
            throw new DocGenException('Insufficient access to delete retired fonts.');
        if (keys == null || keys.isEmpty())
            throw new DocGenException('Select at least one retired font to delete.');
        Set<String> requested = new Set<String>(keys);
        if (requested.size() > 25)
            throw new DocGenException('Delete no more than 25 retired fonts in one action.');
        DocGenFlsGuard.assertAccessible(DocGen_Font_Face__c.sObjectType, FIELDS);
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Font_Face__c> faces = [
            SELECT Id, Revision_Key__c, Status__c
            FROM DocGen_Font_Face__c
            WHERE Revision_Key__c IN :requested
            WITH SYSTEM_MODE
        ];
        if (faces.size() != requested.size())
            throw new DocGenException('One or more selected font revisions no longer exists. Refresh the font list.');
        for (DocGen_Font_Face__c f : faces)
            if (f.Status__c != 'Retired')
                throw new DocGenException('Only retired fonts can be deleted. Active fonts are protected.');
        authorizedMutation = true;
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.delete(faces, AccessLevel.SYSTEM_MODE);
        } finally {
            authorizedMutation = false;
        }
    }
}
