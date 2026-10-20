trigger DocGenFontFaceGuard on DocGen_Font_Face__c(before insert, before update, before delete) {
    if (!DocGenFontController.authorizedMutation) {
        for (DocGen_Font_Face__c f : Trigger.isDelete ? Trigger.old : Trigger.new)
            f.addError(
                'Manage font revisions through Portwood Assets. Published font dependencies and evidence are immutable.'
            );
    } else if (Trigger.isUpdate) {
        for (DocGen_Font_Face__c f : Trigger.new) {
            DocGen_Font_Face__c old = Trigger.oldMap.get(f.Id);
            if (
                f.Revision_Key__c != old.Revision_Key__c ||
                f.Asset__c != old.Asset__c ||
                f.Source_CV_Id__c != old.Source_CV_Id__c ||
                (old.Source_Checksum__c != null &&
                f.Source_Checksum__c != old.Source_Checksum__c) ||
                (f.Metadata_JSON__c != old.Metadata_JSON__c && !DocGenFontController.isStagedLicenseRecovery(old, f)) ||
                f.License_Text__c != old.License_Text__c
            )
                f.addError('Create a new immutable font revision to change source bytes or metadata.');
        }
    }
}
