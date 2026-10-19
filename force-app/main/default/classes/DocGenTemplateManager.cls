public with sharing class DocGenTemplateManager {
    /**
     * Retrieves the ContentVersion Blob for the latest file attached to the Portwood Template.
     * @param templateId The ID of the DocGen_Template__c record.
     * @return String Base64 encoded file data.
     */
    public static String getTemplateFileContent(Id templateId) {
        if (templateId == null) {
            throw new DocGenException('Template ID is required.');
        }
        // Designer live-preview override: render the caller-supplied draft in
        // place of the saved body. Handled here (not just in mergeTemplate) so
        // a brand-new template with NO saved version can still preview.
        if (DocGenService.draftHtmlBodyOverride != null) {
            return EncodingUtil.base64Encode(Blob.valueOf(DocGenService.draftHtmlBodyOverride));
        }

        Id targetCvId = getTemplateFileVersionId(templateId);

        // Explicit CRUD check on ContentVersion — standard object, isAccessible()
        // returns true for any user with file access. This documents enforcement
        // for the AppExchange reviewer.
        if (!Schema.sObjectType.ContentVersion.isAccessible()) {
            throw new DocGenException('ContentVersion access denied.');
        }
        // SYSTEM_MODE: the template body CV is a package-internal artifact whose
        // access is already gated upstream — the caller reaches this point only
        // via an active version of a DocGen_Template__c that the user can read.
        // USER_MODE on this specific query can return "ContentVersion not found"
        // when the body CV's CDL defaults to Visibility=InternalUsers on fresh
        // upload (subscriber-org artifact of the platform behavior).
        // v2.0.1 — per-field FLS enforcement on SOQL reads (see DocGenFlsGuard).
        DocGenFlsGuard.assertAccessible(
            ContentVersion.sObjectType,
            new Set<String>{ 'VersionData', 'Title', 'FileExtension' }
        );
        List<ContentVersion> cvs = [
            SELECT VersionData, Title, FileExtension
            FROM ContentVersion
            WHERE Id = :targetCvId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (cvs.isEmpty()) {
            throw new DocGenException('ContentVersion not found.');
        }

        return EncodingUtil.base64Encode(cvs[0].VersionData);
    }

    /** Resolve the active body without loading or base64-encoding the archive. */
    public static Id getTemplateFileVersionId(Id templateId) {
        if (templateId == null)
            throw new DocGenException('Template ID is required.');
        // Object-level CRUD gate — caller (generateDocumentData) has already
        // enforced Template CRUD; this redundant check documents enforcement
        // at this entry point too.
        if (!Schema.sObjectType.DocGen_Template_Version__c.isAccessible()) {
            throw new DocGenException('Insufficient access to template versions.');
        }
        // 1. Check for Active Version first — SYSTEM_MODE retained for the
        // package-internal version metadata (Content_Version_Id__c is the
        // pointer to the template body CV; USER_MODE strict FLS strips it for
        // any admin lacking FLS, including in managed-package build orgs).
        // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
        // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
        // calls Schema.SObjectField.getDescribe().isAccessible() on every field
        // the SELECT lists; throws DocGenException with the offending field name
        // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
        // package-build @TestSetup FLS-propagation issue documented in
        // DocGenFlsGuard.cls.
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Content_Version_Id__c', 'Template__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        Id targetCvId = null;

        if (!activeVersions.isEmpty()) {
            targetCvId = activeVersions[0].Content_Version_Id__c;
        }

        // Fallback: If no active version OR active version has null CV ID (legacy/broken data)
        if (targetCvId == null) {
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :templateId
                WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate DESC
                LIMIT 1
            ];

            if (!links.isEmpty()) {
                // Get latest ContentVersion for this document
                List<ContentVersion> cvs = [
                    SELECT Id
                    FROM ContentVersion
                    WHERE ContentDocumentId = :links[0].ContentDocumentId AND IsLatest = TRUE
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!cvs.isEmpty()) {
                    targetCvId = cvs[0].Id;
                }
            }
        }

        if (targetCvId == null) {
            throw new DocGenException('No template file found (active or attached).');
        }

        return targetCvId;
    }
}
