trigger DocGenTemplateSignerFieldsTrigger on DocGen_Template__c(before update) {
    DocGenFieldWritebackService.preserveOpenRequestFields(Trigger.new, Trigger.oldMap);
}
