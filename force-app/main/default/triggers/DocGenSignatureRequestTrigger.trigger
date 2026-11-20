trigger DocGenSignatureRequestTrigger on DocGen_Signature_Request__c(before insert, before update) {
    DocGenFieldWritebackService.snapshotSendingRequests(Trigger.new, Trigger.oldMap);
    if (Trigger.isUpdate) {
        DocGenSignatureImmutability.blockFinalizedRequestSnapshotChanges(Trigger.new, Trigger.oldMap);
        DocGenSignatureImmutability.blockSignedRequestStatusChanges(Trigger.new, Trigger.oldMap);
    }
}
