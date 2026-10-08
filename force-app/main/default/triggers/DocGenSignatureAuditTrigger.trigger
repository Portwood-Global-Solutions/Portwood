trigger DocGenSignatureAuditTrigger on DocGen_Signature_Audit__c(before update, before delete) {
    if (Trigger.isBefore && Trigger.isUpdate) {
        DocGenSignatureImmutability.blockAuditUpdates(Trigger.new, Trigger.oldMap);
    }
    if (Trigger.isBefore && Trigger.isDelete) {
        DocGenSignatureImmutability.blockAuditDeletes(Trigger.old);
    }
}
