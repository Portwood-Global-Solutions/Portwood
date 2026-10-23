@IsTest
private class DocGenSignatureImmutabilityTest {
    private static final String FINAL_HASH = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    private static DocGen_Signature_Request__c createRequest() {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Status__c = 'Sent');
        insert req;
        return req;
    }

    private static DocGen_Signature_Audit__c createAudit(Id requestId) {
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c(
            Signature_Request__c = requestId,
            Signer_Name__c = 'Immutable Signer',
            Signer_Email__c = 'signer@example.com',
            Signed_Date__c = System.now(),
            Document_Hash_SHA256__c = null
        );
        insert audit;
        return audit;
    }

    private static Id protectSignedFile(Id requestId) {
        Account acc = new Account(Name = 'Immutable File Account');
        insert acc;

        ContentVersion cv = new ContentVersion(
            Title = 'Signed Agreement',
            PathOnClient = 'signed-agreement.pdf',
            VersionData = Blob.valueOf('signed pdf bytes'),
            FirstPublishLocationId = acc.Id
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        update new DocGen_Signature_Request__c(
            Id = requestId,
            Protected_Signed_Content_Document_Id__c = String.valueOf(docId)
        );
        return docId;
    }

    @IsTest
    static void auditAllowsInitialHashThenBlocksHashChangesAndDeletes() {
        DocGen_Signature_Request__c req = createRequest();
        DocGen_Signature_Audit__c audit = createAudit(req.Id);

        List<Database.SaveResult> hashResults = DocGenSignatureImmutability.updateFinalAuditHashes(
            new List<DocGen_Signature_Audit__c>{
                new DocGen_Signature_Audit__c(Id = audit.Id, Document_Hash_SHA256__c = FINAL_HASH)
            }
        );
        System.assertEquals(true, hashResults[0].isSuccess(), 'The package finalizer can write the first final hash');

        Database.SaveResult normalEditResult = Database.update(
            new DocGen_Signature_Audit__c(Id = audit.Id, Signer_Name__c = 'Corrected Signer Name'),
            false
        );
        System.assertEquals(true, normalEditResult.isSuccess(), 'Non-hash audit corrections remain allowed');

        Database.SaveResult hashEditResult = Database.update(
            new DocGen_Signature_Audit__c(
                Id = audit.Id,
                Document_Hash_SHA256__c = 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
            ),
            false
        );
        System.assertEquals(false, hashEditResult.isSuccess(), 'Document hash cannot be changed once filled');

        Database.DeleteResult deleteResult = Database.delete(new DocGen_Signature_Audit__c(Id = audit.Id), false);
        System.assertEquals(false, deleteResult.isSuccess(), 'Audit deletes must be blocked after creation');
    }

    @IsTest
    static void auditBlocksDirectHashEditsAndInvalidInternalHashes() {
        DocGen_Signature_Request__c req = createRequest();
        DocGen_Signature_Audit__c audit = createAudit(req.Id);

        Database.SaveResult normalEditResult = Database.update(
            new DocGen_Signature_Audit__c(Id = audit.Id, Signer_Email__c = 'changed@example.com'),
            false
        );
        System.assertEquals(true, normalEditResult.isSuccess(), 'Non-hash audit edits are allowed');

        Database.SaveResult directHashResult = Database.update(
            new DocGen_Signature_Audit__c(Id = audit.Id, Document_Hash_SHA256__c = FINAL_HASH),
            false
        );
        System.assertEquals(false, directHashResult.isSuccess(), 'Users cannot directly fill the hash field');

        List<Database.SaveResult> badHashResults = DocGenSignatureImmutability.updateFinalAuditHashes(
            new List<DocGen_Signature_Audit__c>{
                new DocGen_Signature_Audit__c(Id = audit.Id, Document_Hash_SHA256__c = 'not-a-sha256-hash')
            }
        );
        System.assertEquals(false, badHashResults[0].isSuccess(), 'Internal hash writes still require SHA-256 hex');

        DocGenSignatureImmutability.updateFinalAuditHashes(
            new List<DocGen_Signature_Audit__c>{
                new DocGen_Signature_Audit__c(Id = audit.Id, Document_Hash_SHA256__c = FINAL_HASH)
            }
        );
        List<Database.SaveResult> secondHashResults = DocGenSignatureImmutability.updateFinalAuditHashes(
            new List<DocGen_Signature_Audit__c>{
                new DocGen_Signature_Audit__c(
                    Id = audit.Id,
                    Document_Hash_SHA256__c = 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
                )
            }
        );
        System.assertEquals(false, secondHashResults[0].isSuccess(), 'A final hash cannot be replaced');

        DocGen_Signature_Audit__c directAudit = new DocGen_Signature_Audit__c(Id = audit.Id);
        DocGenSignatureImmutability.blockAuditUpdates(
            new List<DocGen_Signature_Audit__c>{ directAudit },
            new Map<Id, DocGen_Signature_Audit__c>()
        );
        System.assertEquals(true, directAudit.hasErrors(), 'Missing old rows are treated as immutable');
    }

    @IsTest
    static void auditBlocksIpAddressChangesButAllowsOtherFields() {
        DocGen_Signature_Request__c req = createRequest();
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Immutable Signer',
            Signer_Email__c = 'signer@example.com',
            Signed_Date__c = System.now(),
            IP_Address__c = '203.0.113.10'
        );
        insert audit;

        Database.SaveResult ipEditResult = Database.update(
            new DocGen_Signature_Audit__c(Id = audit.Id, IP_Address__c = '198.51.100.1'),
            false
        );
        System.assertEquals(false, ipEditResult.isSuccess(), 'Recorded IP address cannot be changed once set');

        Database.SaveResult normalEditResult = Database.update(
            new DocGen_Signature_Audit__c(Id = audit.Id, Verification_Method__c = 'Email PIN'),
            false
        );
        System.assertEquals(true, normalEditResult.isSuccess(), 'Non-IP audit edits remain allowed');
    }

    @IsTest
    static void finalizedRequestBlocksSnapshotHashChanges() {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Snapshot_Hash__c = FINAL_HASH
        );
        insert req;

        update new DocGen_Signature_Request__c(Id = req.Id, Snapshot_Hash__c = null);
        update new DocGen_Signature_Request__c(Id = req.Id, Snapshot_Hash__c = FINAL_HASH);

        update new DocGen_Signature_Request__c(Id = req.Id, Status__c = 'Signed');

        Database.SaveResult snapshotEditResult = Database.update(
            new DocGen_Signature_Request__c(
                Id = req.Id,
                Snapshot_Hash__c = 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
            ),
            false
        );
        System.assertEquals(false, snapshotEditResult.isSuccess(), 'Finalized snapshot hash cannot be changed');

        Database.SaveResult statusEditResult = Database.update(
            new DocGen_Signature_Request__c(Id = req.Id, Signer_Name__c = 'Finalized Request Correction'),
            false
        );
        System.assertEquals(
            true,
            statusEditResult.isSuccess(),
            'Other finalized request fields are not locked by this guard'
        );
    }

    @IsTest
    static void finalizedRequestBlocksFrozenDocumentCvIdChanges() {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Frozen_Document_CV_Id__c = '068000000000001AAA'
        );
        insert req;

        // Pre-finalization: legitimate decline/cancel flows null this out — must stay allowed.
        Database.SaveResult preFinalizeClearResult = Database.update(
            new DocGen_Signature_Request__c(Id = req.Id, Frozen_Document_CV_Id__c = null),
            false
        );
        System.assertEquals(
            true,
            preFinalizeClearResult.isSuccess(),
            'Clearing the frozen document reference before finalization (decline/cancel) remains allowed'
        );
        update new DocGen_Signature_Request__c(Id = req.Id, Frozen_Document_CV_Id__c = '068000000000001AAA');

        update new DocGen_Signature_Request__c(Id = req.Id, Status__c = 'Signed');

        Database.SaveResult frozenDocEditResult = Database.update(
            new DocGen_Signature_Request__c(Id = req.Id, Frozen_Document_CV_Id__c = '068000000000099AAA'),
            false
        );
        System.assertEquals(
            false,
            frozenDocEditResult.isSuccess(),
            'Finalized frozen-document reference cannot be repointed'
        );
    }

    @IsTest
    static void signedRequestStatusCannotBeChanged() {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Status__c = 'Sent');
        insert req;

        Database.SaveResult signResult = Database.update(
            new DocGen_Signature_Request__c(Id = req.Id, Status__c = 'Signed'),
            false
        );
        System.assertEquals(true, signResult.isSuccess(), 'The request can move into Signed');

        Database.SaveResult reopenResult = Database.update(
            new DocGen_Signature_Request__c(Id = req.Id, Status__c = 'Sent'),
            false
        );
        System.assertEquals(false, reopenResult.isSuccess(), 'Signed status cannot be changed');

        Database.SaveResult sameStatusResult = Database.update(
            new DocGen_Signature_Request__c(Id = req.Id, Status__c = 'Signed', Signer_Name__c = 'Corrected Name'),
            false
        );
        System.assertEquals(true, sameStatusResult.isSuccess(), 'Updates that leave status Signed are allowed');
    }

    @IsTest
    static void protectedSignedFileBlocksDeleteEditAndNewVersion() {
        DocGen_Signature_Request__c req = createRequest();
        Id docId = protectSignedFile(req.Id);

        Database.DeleteResult deleteResult = Database.delete(new ContentDocument(Id = docId), false);
        System.assertEquals(false, deleteResult.isSuccess(), 'Protected signed files must not be deleted');

        ContentDocumentLink protectedLink = [
            SELECT Id
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :docId
            LIMIT 1
        ];
        Database.DeleteResult unlinkResult = Database.delete(protectedLink, false);
        System.assertEquals(
            false,
            unlinkResult.isSuccess(),
            'Protected signed files must not be removed from record pages'
        );

        Database.SaveResult editResult = Database.update(new ContentDocument(Id = docId, Title = 'Tampered'), false);
        System.assertEquals(false, editResult.isSuccess(), 'Protected signed files must not be edited');

        ContentVersion newVersion = new ContentVersion(
            ContentDocumentId = docId,
            Title = 'Signed Agreement v2',
            PathOnClient = 'signed-agreement-v2.pdf',
            VersionData = Blob.valueOf('tampered bytes')
        );
        Database.SaveResult versionResult = Database.insert(newVersion, false);
        System.assertEquals(false, versionResult.isSuccess(), 'Protected signed files must not accept new versions');

        Id latestVersionId = [
            SELECT LatestPublishedVersionId
            FROM ContentDocument
            WHERE Id = :docId
        ]
        .LatestPublishedVersionId;
        Database.SaveResult versionEditResult = Database.update(
            new ContentVersion(Id = latestVersionId, Title = 'Tampered Version'),
            false
        );
        System.assertEquals(false, versionEditResult.isSuccess(), 'Protected signed file versions must not be edited');
    }

    @IsTest
    static void unprotectedFilesRemainEditableAndVersionable() {
        Account acc = new Account(Name = 'Unprotected File Account');
        insert acc;

        ContentVersion cv = new ContentVersion(
            Title = 'Working Document',
            PathOnClient = 'working-document.pdf',
            VersionData = Blob.valueOf('draft bytes'),
            FirstPublishLocationId = acc.Id
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        Database.SaveResult docEditResult = Database.update(
            new ContentDocument(Id = docId, Title = 'Still Working'),
            false
        );
        System.assertEquals(true, docEditResult.isSuccess(), 'Unprotected files stay editable');

        ContentVersion newVersion = new ContentVersion(
            ContentDocumentId = docId,
            Title = 'Working Document v2',
            PathOnClient = 'working-document-v2.pdf',
            VersionData = Blob.valueOf('draft bytes v2')
        );
        Database.SaveResult versionResult = Database.insert(newVersion, false);
        System.assertEquals(true, versionResult.isSuccess(), 'Unprotected files can receive new versions');

        Id latestVersionId = [
            SELECT LatestPublishedVersionId
            FROM ContentDocument
            WHERE Id = :docId
        ]
        .LatestPublishedVersionId;
        Database.SaveResult versionEditResult = Database.update(
            new ContentVersion(Id = latestVersionId, Title = 'Still Working Version'),
            false
        );
        System.assertEquals(true, versionEditResult.isSuccess(), 'Unprotected file versions stay editable');

        ContentDocumentLink unprotectedLink = [
            SELECT Id
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :docId
            LIMIT 1
        ];
        Database.DeleteResult unlinkResult = Database.delete(unprotectedLink, false);
        System.assertEquals(true, unlinkResult.isSuccess(), 'Unprotected files can still be removed from record pages');

        DocGenSignatureImmutability.blockProtectedContentDocumentChanges(new List<ContentDocument>());
        DocGenSignatureImmutability.blockProtectedContentVersionChanges(new List<ContentVersion>());
        DocGenSignatureImmutability.blockProtectedContentDocumentLinkDeletes(new List<ContentDocumentLink>());
    }
}
