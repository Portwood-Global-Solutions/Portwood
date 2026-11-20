/** Native Files operations keep multi-megabyte font payloads out of synchronous LWC requests. */
public with sharing class DocGenFontOperation implements Queueable {
    private String operation;
    private Id versionId;
    private String key;
    private String apiName;
    private String argument;
    private String namespacePrefix;
    private String expectedMigrationKey;
    private String migrationAssetName;
    private String migrationAssetCategory;

    public DocGenFontOperation(
        Id versionId,
        String key,
        String apiName,
        String licenseText,
        String expectedKey,
        String assetName,
        String assetCategory
    ) {
        this('MigrationImport', versionId, key, apiName, licenseText, null);
        expectedMigrationKey = expectedKey;
        migrationAssetName = assetName;
        migrationAssetCategory = assetCategory;
    }
    public DocGenFontOperation(String operation, Id versionId, String key, String argument, String namespacePrefix) {
        this(operation, versionId, key, null, argument, namespacePrefix);
    }
    public DocGenFontOperation(
        String operation,
        Id versionId,
        String key,
        String apiName,
        String argument,
        String namespacePrefix
    ) {
        this.operation = operation;
        this.versionId = versionId;
        this.key = key;
        this.apiName = apiName;
        this.argument = argument;
        this.namespacePrefix = namespacePrefix;
    }
    public void execute(QueueableContext context) {
        if (!FeatureManagement.checkPermission('Manage_DocGen_Fonts'))
            throw new DocGenException('Manage Portwood Fonts permission is required.');
        if (Limits.getLimitHeapSize() < 25000000)
            throw new DocGenException(
                'Large font imports require the Winter 27 Apex heap limits. Check Apex Settings.'
            );
        if (operation == 'Import') {
            DocGenFontController.inspectUploadedFontWithApiName(versionId, key, apiName, argument);
        } else if (operation == 'MigrationImport') {
            DocGenFontController.inspectUploadedFontWithApiName(versionId, key, apiName, argument);
            DocGen_Font_Face__c imported = DocGenFontController.load(expectedMigrationKey);
            if (imported.Source_CV_Id__c != String.valueOf(versionId)) {
                throw new DocGenException('The migrated font revision did not retain the staged File.');
            }
            Database.update(
                new DocGen_Asset__c(
                    Id = imported.Asset__c,
                    Name = migrationAssetName,
                    Category__c = migrationAssetCategory
                ),
                AccessLevel.USER_MODE
            );
        } else if (operation == 'ImportArchive') {
            DocGenFontController.inspectUploadedFontArchive(versionId, argument);
        } else if (operation == 'Proof') {
            DocGenFontController.createFontProof(key);
        } else {
            throw new DocGenException('Unknown font operation.');
        }
    }
}
