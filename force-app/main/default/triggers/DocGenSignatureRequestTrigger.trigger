trigger DocGenSignatureRequestTrigger on DocGen_Signature_Request__c(before update) {
    if (Trigger.isBefore && Trigger.isUpdate) {
        DocGenSignatureImmutability.blockFinalizedRequestSnapshotChanges(Trigger.new, Trigger.oldMap);
        DocGenSignatureImmutability.blockSignedRequestStatusChanges(Trigger.new, Trigger.oldMap);
    }
}
