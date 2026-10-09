trigger DocGenSignatureContentVersionTrigger on ContentVersion(before insert, before update) {
    if (Trigger.isBefore && Trigger.isInsert) {
        DocGenSignatureImmutability.blockProtectedContentVersionChanges(Trigger.new);
    }
    if (Trigger.isBefore && Trigger.isUpdate) {
        DocGenSignatureImmutability.blockProtectedContentVersionChanges(Trigger.new);
    }
}
