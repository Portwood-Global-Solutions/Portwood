public without sharing class DocGenSignatureImmutability {
    private static final String AUDIT_DELETE_LOCK_MESSAGE = 'Signature audit records cannot be deleted after creation.';
    private static final String AUDIT_HASH_LOCK_MESSAGE = 'Document Hash (SHA-256) cannot be changed after it is filled.';
    private static final String AUDIT_IP_LOCK_MESSAGE = 'IP Address cannot be changed after it is recorded.';
    private static final String FILE_LOCK_MESSAGE = 'Signed document files are immutable after creation. Create a new signature request instead of editing, versioning, or deleting this file.';
    private static final String SNAPSHOT_LOCK_MESSAGE = 'Snapshot Hash cannot be changed after the signature request is finalized.';
    private static final String FROZEN_DOC_LOCK_MESSAGE = 'Frozen Document CV Id cannot be changed after the signature request is finalized.';
    private static final String SIGNED_STATUS_LOCK_MESSAGE = 'Signature request status cannot be changed after it is Signed.';
    private static Boolean internalHashFinalization = false;

    public static List<Database.SaveResult> updateFinalAuditHashes(List<DocGen_Signature_Audit__c> audits) {
        internalHashFinalization = true;
        try {
            return Database.update(audits, false, AccessLevel.SYSTEM_MODE);
        } finally {
            internalHashFinalization = false;
        }
    }

    public static void blockAuditUpdates(
        List<DocGen_Signature_Audit__c> newRecords,
        Map<Id, DocGen_Signature_Audit__c> oldMap
    ) {
        for (DocGen_Signature_Audit__c audit : newRecords) {
            DocGen_Signature_Audit__c oldAudit = oldMap.get(audit.Id);
            if (internalHashFinalization && isInitialHashFinalization(audit, oldAudit)) {
                continue;
            }
            if (documentHashChanged(audit, oldAudit)) {
                audit.addError(AUDIT_HASH_LOCK_MESSAGE);
            }
            if (ipAddressChanged(audit, oldAudit)) {
                audit.addError(AUDIT_IP_LOCK_MESSAGE);
            }
        }
    }

    public static void blockAuditDeletes(List<DocGen_Signature_Audit__c> oldRecords) {
        for (DocGen_Signature_Audit__c audit : oldRecords) {
            audit.addError(AUDIT_DELETE_LOCK_MESSAGE);
        }
    }

    public static void blockFinalizedRequestSnapshotChanges(
        List<DocGen_Signature_Request__c> newRecords,
        Map<Id, DocGen_Signature_Request__c> oldMap
    ) {
        for (DocGen_Signature_Request__c req : newRecords) {
            DocGen_Signature_Request__c oldReq = oldMap.get(req.Id);
            if (oldReq == null) {
                continue;
            }
            Boolean finalized = isFinalized(req) || isFinalized(oldReq);
            if (req.Snapshot_Hash__c != oldReq.Snapshot_Hash__c && finalized) {
                req.addError(SNAPSHOT_LOCK_MESSAGE);
            }
            if (req.Frozen_Document_CV_Id__c != oldReq.Frozen_Document_CV_Id__c && finalized) {
                req.addError(FROZEN_DOC_LOCK_MESSAGE);
            }
        }
    }

    public static void blockSignedRequestStatusChanges(
        List<DocGen_Signature_Request__c> newRecords,
        Map<Id, DocGen_Signature_Request__c> oldMap
    ) {
        for (DocGen_Signature_Request__c req : newRecords) {
            DocGen_Signature_Request__c oldReq = oldMap.get(req.Id);
            if (oldReq == null || oldReq.Status__c != 'Signed' || req.Status__c == oldReq.Status__c) {
                continue;
            }
            req.addError(SIGNED_STATUS_LOCK_MESSAGE);
        }
    }

    public static void blockProtectedContentDocumentChanges(List<ContentDocument> documents) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocument doc : documents) {
            if (doc.Id != null) {
                docIds.add(doc.Id);
            }
        }
        Set<Id> protectedDocIds = getProtectedContentDocumentIds(docIds);
        for (ContentDocument doc : documents) {
            if (protectedDocIds.contains(doc.Id)) {
                doc.addError(FILE_LOCK_MESSAGE);
            }
        }
    }

    public static void blockProtectedContentVersionChanges(List<ContentVersion> versions) {
        Set<Id> docIds = new Set<Id>();
        for (ContentVersion version : versions) {
            if (version.ContentDocumentId != null) {
                docIds.add(version.ContentDocumentId);
            }
        }
        Set<Id> protectedDocIds = getProtectedContentDocumentIds(docIds);
        for (ContentVersion version : versions) {
            if (protectedDocIds.contains(version.ContentDocumentId)) {
                version.addError(FILE_LOCK_MESSAGE);
            }
        }
    }

    public static void blockProtectedContentDocumentLinkDeletes(List<ContentDocumentLink> links) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            if (link.ContentDocumentId != null) {
                docIds.add(link.ContentDocumentId);
            }
        }
        Set<Id> protectedDocIds = getProtectedContentDocumentIds(docIds);
        for (ContentDocumentLink link : links) {
            if (protectedDocIds.contains(link.ContentDocumentId)) {
                link.addError(FILE_LOCK_MESSAGE);
            }
        }
    }

    private static Boolean isInitialHashFinalization(
        DocGen_Signature_Audit__c audit,
        DocGen_Signature_Audit__c oldAudit
    ) {
        if (oldAudit == null) {
            return false;
        }
        String oldHash = oldAudit.Document_Hash_SHA256__c;
        String newHash = audit.Document_Hash_SHA256__c;
        if (String.isNotBlank(oldHash) || !isSha256Hex(newHash)) {
            return false;
        }
        return true;
    }

    private static Boolean documentHashChanged(DocGen_Signature_Audit__c audit, DocGen_Signature_Audit__c oldAudit) {
        if (oldAudit == null) {
            return true;
        }
        return audit.Document_Hash_SHA256__c != oldAudit.Document_Hash_SHA256__c;
    }

    private static Boolean ipAddressChanged(DocGen_Signature_Audit__c audit, DocGen_Signature_Audit__c oldAudit) {
        if (oldAudit == null) {
            return true;
        }
        return audit.IP_Address__c != oldAudit.IP_Address__c;
    }

    private static Boolean isFinalized(DocGen_Signature_Request__c req) {
        return req != null &&
            (req.Status__c == 'Signed' || String.isNotBlank(req.Protected_Signed_Content_Document_Id__c));
    }

    private static Boolean isSha256Hex(String value) {
        return String.isNotBlank(value) && Pattern.matches('(?i)^[0-9a-f]{64}$', value);
    }

    private static Set<Id> getProtectedContentDocumentIds(Set<Id> docIds) {
        Set<Id> protectedDocIds = new Set<Id>();
        if (docIds == null || docIds.isEmpty()) {
            return protectedDocIds;
        }
        Set<String> docIdStrings = new Set<String>();
        for (Id docId : docIds) {
            docIdStrings.add(String.valueOf(docId));
        }
        for (DocGen_Signature_Request__c req : [
            SELECT Protected_Signed_Content_Document_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Protected_Signed_Content_Document_Id__c IN :docIdStrings
            WITH SYSTEM_MODE
        ]) {
            protectedDocIds.add((Id) req.Protected_Signed_Content_Document_Id__c);
        }
        return protectedDocIds;
    }
}
