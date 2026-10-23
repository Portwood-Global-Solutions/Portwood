trigger DocGenSignatureContentDocumentTrigger on ContentDocument(before update, before delete) {
    if (Trigger.isBefore && Trigger.isUpdate) {
        DocGenSignatureImmutability.blockProtectedContentDocumentChanges(Trigger.new);
    }
    if (Trigger.isBefore && Trigger.isDelete) {
        DocGenSignatureImmutability.blockProtectedContentDocumentChanges(Trigger.old);
    }
}
