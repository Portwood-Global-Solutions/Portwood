/** Assets authoring API. HTML stays in private Salesforce Files with native revision history. */
public with sharing class DocGenSnippetController {
    private static final Set<String> ASSET_FIELDS = new Set<String>{
        'Name',
        'Asset_Key__c',
        'Asset_Type__c',
        'Category__c',
        'Is_Active__c'
    };
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getSnippets() {
        DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, ASSET_FIELDS);
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Asset__c> assets = [
            SELECT Id, Name, Asset_Key__c, Asset_Type__c, Category__c, Is_Active__c
            FROM DocGen_Asset__c
            WHERE Asset_Type__c = :DocGenSnippetService.ASSET_TYPE
            WITH SYSTEM_MODE
            ORDER BY Name
            LIMIT 1000
        ];
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (DocGen_Asset__c a : assets)
            result.add(dto(a));
        return result;
    }
    private static Map<String, Object> dto(DocGen_Asset__c a) {
        return new Map<String, Object>{
            'id' => a.Id,
            'name' => a.Name,
            'assetKey' => a.Asset_Key__c,
            'category' => a.Category__c,
            'isActive' => a.Is_Active__c,
            'mergeTag' => DocGenSnippetService.mergeTag(a.Asset_Key__c)
        };
    }
    private static DocGen_Asset__c asset(Id assetId, Boolean lockRow) {
        DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, ASSET_FIELDS);
        List<DocGen_Asset__c> rows;
        if (lockRow) {
            /* code-analyzer-suppress ApexFlsViolation */
            rows = [
                SELECT Id, Name, Asset_Key__c, Asset_Type__c, Category__c, Is_Active__c
                FROM DocGen_Asset__c
                WHERE Id = :assetId AND Asset_Type__c = :DocGenSnippetService.ASSET_TYPE
                WITH SYSTEM_MODE
                LIMIT 1
                FOR UPDATE
            ];
        } else {
            /* code-analyzer-suppress ApexFlsViolation */
            rows = [
                SELECT Id, Name, Asset_Key__c, Asset_Type__c, Category__c, Is_Active__c
                FROM DocGen_Asset__c
                WHERE Id = :assetId AND Asset_Type__c = :DocGenSnippetService.ASSET_TYPE
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        }
        if (rows.isEmpty())
            throw new DocGenException('This shared content was not found or is inaccessible.');
        return rows[0];
    }
    private static List<ContentVersion> revisions(Id assetId) {
        return new PrivateFiles().revisions(assetId);
    }
    /** Internal merge gateway: authorize snippet assets with sharing before reading their private backing Files. */
    public static Map<String, String> loadActiveBodies(Set<String> keys) {
        DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, ASSET_FIELDS);
        Map<Id, String> byId = new Map<Id, String>();
        /* code-analyzer-suppress ApexFlsViolation */
        for (DocGen_Asset__c a : [
            SELECT Id, Asset_Key__c
            FROM DocGen_Asset__c
            WHERE Asset_Key__c IN :keys AND Asset_Type__c = :DocGenSnippetService.ASSET_TYPE AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
        ])
            byId.put(a.Id, a.Asset_Key__c);
        return byId.isEmpty() ? new Map<String, String>() : new PrivateFiles().latest(byId);
    }
    /** These files are private on records. Only the sharing/FLS-checked asset gateways above can reach this reader. */
    private without sharing class PrivateFiles {
        public List<ContentVersion> revisions(Id assetId) {
            DocGenFlsGuard.assertAccessible(
                ContentDocumentLink.sObjectType,
                new Set<String>{ 'ContentDocumentId', 'LinkedEntityId' }
            );
            Set<Id> docs = new Set<Id>();
            /* code-analyzer-suppress ApexFlsViolation */
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :assetId
                WITH SYSTEM_MODE
            ])
                docs.add(link.ContentDocumentId);
            DocGenFlsGuard.assertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{
                    'ContentDocumentId',
                    'Title',
                    'VersionNumber',
                    'CreatedDate',
                    'IsLatest',
                    'ContentSize'
                }
            );
            String title = 'docgen_snippet_' + assetId;
            /* code-analyzer-suppress ApexFlsViolation */
            return [
                SELECT Id, ContentDocumentId, VersionNumber, CreatedDate, ContentSize
                FROM ContentVersion
                WHERE ContentDocumentId IN :docs AND Title = :title
                WITH SYSTEM_MODE
                ORDER BY IsLatest DESC, CreatedDate DESC, Id DESC
                LIMIT 1000
            ];
        }

        public String body(Id versionId) {
            DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
            /* code-analyzer-suppress ApexFlsViolation */
            return [SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH SYSTEM_MODE]
                .VersionData.toString();
        }
        public void insertVersion(ContentVersion cv, Set<String> fields) {
            DocGenFlsGuard.assertCreateable(cv, fields);
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(cv, AccessLevel.SYSTEM_MODE);
        }
        public Map<String, String> latest(Map<Id, String> byId) {
            Map<String, String> result = new Map<String, String>();
            DocGenFlsGuard.assertAccessible(
                ContentDocumentLink.sObjectType,
                new Set<String>{ 'ContentDocumentId', 'LinkedEntityId' }
            );
            Map<Id, Id> documents = new Map<Id, Id>();
            /* code-analyzer-suppress ApexFlsViolation */
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId, LinkedEntityId
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :byId.keySet()
                WITH SYSTEM_MODE
            ])
                documents.put(link.ContentDocumentId, link.LinkedEntityId);
            DocGenFlsGuard.assertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{ 'ContentDocumentId', 'Title', 'IsLatest', 'ContentSize', 'VersionData' }
            );
            Set<Id> ids = documents.keySet();
            Set<Id> versionIds = new Set<Id>();
            Map<Id, String> versionKeys = new Map<Id, String>();
            Integer totalBytes = 0;
            /* code-analyzer-suppress ApexFlsViolation */
            for (ContentVersion cv : [
                SELECT Id, ContentDocumentId, Title, ContentSize
                FROM ContentVersion
                WHERE ContentDocumentId IN :ids AND IsLatest = TRUE
                WITH SYSTEM_MODE
            ]) {
                Id assetId = documents.get(cv.ContentDocumentId);
                if (cv.Title != 'docgen_snippet_' + assetId)
                    continue;
                totalBytes += cv.ContentSize;
                if (cv.ContentSize > DocGenSnippetService.MAX_HTML * 4 || totalBytes > 1000000 * 2)
                    throw new DocGenException('Shared content is too large for one document.');
                versionIds.add(cv.Id);
                versionKeys.put(cv.Id, byId.get(assetId));
            }
            // Metadata bounds the combined private file bytes BEFORE loading bodies; one bulk read per level.
            /* code-analyzer-suppress ApexFlsViolation */
            for (ContentVersion cv : [
                SELECT Id, VersionData
                FROM ContentVersion
                WHERE Id IN :versionIds
                WITH SYSTEM_MODE
            ])
                result.put(versionKeys.get(cv.Id), DocGenSnippetService.validate(cv.VersionData.toString()));

            return result;
        }
    }
    @AuraEnabled
    public static Map<String, Object> getSnippet(Id assetId, Id versionId) {
        try {
            DocGen_Asset__c a = asset(assetId, false);
            List<ContentVersion> versions = revisions(assetId);
            ContentVersion chosen;
            List<Map<String, Object>> history = new List<Map<String, Object>>();
            for (ContentVersion cv : versions) {
                history.add(
                    new Map<String, Object>{
                        'id' => cv.Id,
                        'number' => cv.VersionNumber,
                        'createdAt' => cv.CreatedDate
                    }
                );
                if (cv.Id == versionId || (versionId == null && chosen == null))
                    chosen = cv;
            }
            if (chosen == null)
                throw new DocGenException('The saved snippet revision was not found.');
            if (chosen.ContentSize > DocGenSnippetService.MAX_HTML * 4)
                throw new DocGenException('This snippet is too large to edit.');
            Map<String, Object> out = dto(a);
            out.put('html', new PrivateFiles().body(chosen.Id));
            out.put('versionId', chosen.Id);
            out.put('currentVersionId', versions[0].Id);
            out.put('versionNumber', chosen.VersionNumber);
            out.put('history', history);
            return out;
        } catch (DocGenException e) {
            throw DocGenService.ahe(e.getMessage());
        }
    }
    @AuraEnabled
    public static Map<String, Object> saveSnippet(
        Id assetId,
        String name,
        String assetKey,
        String category,
        String html,
        String expectedVersionId,
        Boolean isActive
    ) {
        // Validate before any write; never quietly strip a clause's wording or formatting.
        try {
            html = DocGenSnippetService.validate(html);
        } catch (DocGenException e) {
            throw DocGenService.ahe(e.getMessage());
        }
        if (String.isBlank(name) || name.trim().length() > 80)
            throw DocGenService.ahe('Give this content a name of up to 80 characters.');
        if (category != null && category.length() > 80)
            throw DocGenService.ahe('Use a category of up to 80 characters.');
        Savepoint sp = Database.setSavepoint();
        try {
            DocGen_Asset__c a;
            Id documentId;
            if (assetId == null) {
                String key = DocGenAssetKeyHandler.normalizeKey(String.isBlank(assetKey) ? name : assetKey);
                if (String.isBlank(key))
                    throw new DocGenException('Use letters or numbers in the tag key.');
                DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, new Set<String>{ 'Asset_Key__c' });
                /* code-analyzer-suppress ApexFlsViolation */
                if ([SELECT COUNT() FROM DocGen_Asset__c WHERE Asset_Key__c = :key WITH SYSTEM_MODE] > 0)
                    throw new DocGenException('That tag key is already used. Choose another key.');
                a = new DocGen_Asset__c(
                    Name = name.trim(),
                    Asset_Key__c = key,
                    Asset_Type__c = DocGenSnippetService.ASSET_TYPE,
                    Category__c = category,
                    Is_Active__c = isActive != false
                );
                DocGenFlsGuard.assertCreateable(a, ASSET_FIELDS);
                /* code-analyzer-suppress ApexFlsViolation */
                Database.insert(a, AccessLevel.SYSTEM_MODE);
                a = asset(a.Id, false);
                if (a.Asset_Key__c != key)
                    throw new DocGenException('That tag key was just used. Choose another key.');
            } else {
                a = asset(assetId, true);
                List<ContentVersion> versions = revisions(assetId);
                if (versions.isEmpty() || String.valueOf(versions[0].Id) != expectedVersionId)
                    throw new DocGenException(
                        'Someone saved a newer revision. Your edits are still here; reopen this snippet before saving again.'
                    );
                documentId = versions[0].ContentDocumentId;
                a.Name = name.trim();
                a.Category__c = category;
                a.Is_Active__c = isActive != false;
                DocGenFlsGuard.assertUpdateable(a, new Set<String>{ 'Name', 'Category__c', 'Is_Active__c' });
                /* code-analyzer-suppress ApexFlsViolation */
                Database.update(a, AccessLevel.SYSTEM_MODE);
            }
            ContentVersion cv = new ContentVersion(
                Title = 'docgen_snippet_' + a.Id,
                PathOnClient = a.Asset_Key__c + '.html',
                VersionData = Blob.valueOf(html),
                SharingPrivacy = 'P'
            );
            Set<String> writeFields = new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'SharingPrivacy' };
            if (documentId == null) {
                cv.FirstPublishLocationId = a.Id;
                writeFields.add('FirstPublishLocationId');
            } else {
                cv.ContentDocumentId = documentId;
                writeFields.add('ContentDocumentId');
            }
            new PrivateFiles().insertVersion(cv, writeFields);
            DocGenSnippetService.clearCache();
            if (a.Is_Active__c)
                DocGenSnippetService.expand(DocGenSnippetService.mergeTag(a.Asset_Key__c));
            return getSnippet(a.Id, null);
        } catch (Exception e) {
            Database.rollback(sp);
            DocGenSnippetService.clearCache();
            throw DocGenService.ahe(e.getMessage());
        }
    }
}
