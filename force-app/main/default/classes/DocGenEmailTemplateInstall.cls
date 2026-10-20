/**
 * Post-install seeder for the brandable email templates (#193).
 *
 * Records can't ship inside a 2GP package, so on every install/upgrade this
 * handler creates one active DocGen_Email_Template__c per Type__c (carrying the
 * built-in default markup) for any type that doesn't already have one. The
 * service falls back to the same built-ins at send time, so email works even
 * before — or without — this running; the seed just makes the records visible
 * and editable on the Email Templates tab out of the box.
 *
 * Idempotent: existing records are never overwritten, so an upgrade never
 * clobbers an admin's customised templates. The same seedDefaults() entry point
 * is callable from anonymous Apex to seed a source-deployed scratch/dev org
 * (where InstallHandler does not fire).
 */
global with sharing class DocGenEmailTemplateInstall implements InstallHandler {
    global void onInstall(InstallContext context) {
        DocGenSignatureIpContext.initialize();
        seedDefaults();
    }

    /** Friendly record names per type (the Name field is a label only). */
    private static final Map<String, String> TYPE_LABELS = new Map<String, String>{
        DocGenEmailTemplateService.TYPE_REQUEST => 'Signature Request',
        DocGenEmailTemplateService.TYPE_REMINDER => 'Signature Reminder',
        DocGenEmailTemplateService.TYPE_PIN => 'Email Verification Code',
        DocGenEmailTemplateService.TYPE_SIGNER_COMPLETED => 'Signer Completed (to sender)',
        DocGenEmailTemplateService.TYPE_ALL_SIGNED => 'All Signatures Complete (to sender)',
        DocGenEmailTemplateService.TYPE_DECLINED => 'Signer Declined (to sender)',
        DocGenEmailTemplateService.TYPE_COMPLETION => 'Completion Confirmation (to signers)'
    };

    /**
     * Inserts a default template for every type that has no record yet.
     * @return the number of records created.
     */
    global static Integer seedDefaults() {
        Set<String> existing = new Set<String>();
        // Package-internal object; CRUD via Portwood permission sets.
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        for (DocGen_Email_Template__c t : [
            SELECT Type__c
            FROM DocGen_Email_Template__c
            WITH SYSTEM_MODE
        ]) {
            // NOPMD
            existing.add(t.Type__c);
        }

        List<DocGen_Email_Template__c> toInsert = new List<DocGen_Email_Template__c>();
        for (String type : DocGenEmailTemplateService.ALL_TYPES) {
            if (existing.contains(type)) {
                continue;
            }
            DocGenEmailTemplateService.TemplateDef def = DocGenEmailTemplateService.builtInDef(type);
            DocGen_Email_Template__c rec = new DocGen_Email_Template__c();
            rec.Name = (TYPE_LABELS.containsKey(type) ? TYPE_LABELS.get(type) : type);
            rec.Type__c = type;
            rec.Subject__c = def.subject;
            rec.Body_Html__c = def.bodyHtml;
            rec.Is_Active__c = true;
            rec.Description__c = 'Default template seeded by Portwood. Edit freely; delete to fall back to the built-in.';
            toInsert.add(rec);
        }

        if (toInsert.isEmpty()) {
            return 0;
        }

        DocGenFlsGuard.assertCreateable(
            toInsert,
            new Set<String>{ 'Type__c', 'Subject__c', 'Body_Html__c', 'Is_Active__c', 'Description__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(toInsert, AccessLevel.SYSTEM_MODE);
        return toInsert.size();
    }
}
