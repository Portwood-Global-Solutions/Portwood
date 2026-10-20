/** Native Files operations keep multi-megabyte font payloads out of synchronous LWC requests. */
public with sharing class DocGenFontOperation implements Queueable {
    private String operation;
    private Id versionId;
    private String key;
    private String argument;
    private String namespacePrefix;
    public DocGenFontOperation(String operation, Id versionId, String key, String argument, String namespacePrefix) {
        this.operation = operation;
        this.versionId = versionId;
        this.key = key;
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
            DocGenFontController.inspectUploadedFont(versionId, key, argument);
        } else if (operation == 'Proof') {
            DocGenFontController.createFontProof(key);
        } else {
            throw new DocGenException('Unknown font operation.');
        }
    }
}
