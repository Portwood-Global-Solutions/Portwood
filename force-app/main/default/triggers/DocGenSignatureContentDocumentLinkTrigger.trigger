trigger DocGenSignatureContentDocumentLinkTrigger on ContentDocumentLink(before delete) {
    if (Trigger.isBefore && Trigger.isDelete) {
        DocGenSignatureImmutability.blockProtectedContentDocumentLinkDeletes(Trigger.old);
    }
}
