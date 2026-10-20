/**
 * Org configuration + seed data for a testable DocGen org.
 *
 * Run by setup-org.sh. Idempotent — everything is upserted, so re-running
 * against a live org is safe.
 */

// ── 1. Signature settings ────────────────────────────────────────────────────
//
// Signature_Skip_Email_Verification__c is the box that matters for testing. With
// it off, a signer has to verify by email before signing, which in a scratch org
// means the send has to actually leave the org — and that needs a verified
// sender / DKIM set up, which a throwaway org will never have. Testing then
// stalls on infrastructure that has nothing to do with the feature under test.
//
// Deliberately org-default (SetupOwnerId = the org Id), so it applies to every
// user in the org without per-user assignment.
DocGen_Settings__c cfg = DocGen_Settings__c.getOrgDefaults();
if (cfg == null || cfg.Id == null) {
    cfg = new DocGen_Settings__c(SetupOwnerId = UserInfo.getOrganizationId());
}
cfg.Signature_Skip_Email_Verification__c = true;
// Prefill the signer's email so a test does not have to type it, and give the
// emails a sender identity so nothing falls back to a blank From.
cfg.Signature_Prefill_Signer_Email__c = true;
if (String.isBlank(cfg.Company_Name__c)) {
    cfg.Company_Name__c = 'DocGen QA';
}
if (cfg.Signature_Expiration_Days__c == null) {
    cfg.Signature_Expiration_Days__c = 30;
}
// Reminders off: a scheduled job firing mid-run creates async noise that shows
// up as flake in suites that count records.
cfg.Signature_Reminder_Enabled__c = false;
upsert cfg;
DocGenSignatureIpContext.initialize();
System.debug('SETUP settings: skipEmailVerification=' + cfg.Signature_Skip_Email_Verification__c);

// ── 2. A record for the UI suites to open ────────────────────────────────────
List<Account> accts = [SELECT Id FROM Account LIMIT 1];
Id acctId;
if (accts.isEmpty()) {
    Account a = new Account(Name = 'DocGen QA Account', Industry = 'Technology');
    insert a;
    acctId = a.Id;
} else {
    acctId = accts[0].Id;
}
System.debug('SETUP account: ' + acctId);

// ── 3. The template the designer smoke test opens ────────────────────────────
// scripts/ui-smoke.mjs defaults to --template "Verify", so an org with no
// matching template fails at "designer did not open" — which reads like a
// product defect and is really missing seed data.
final String VERIFY_NAME = 'Verify — Designer (pill-dense)';
List<DocGen_Template__c> existing = [SELECT Id FROM DocGen_Template__c WHERE Name = :VERIFY_NAME LIMIT 1];
DocGen_Template__c tpl;
if (existing.isEmpty()) {
    tpl = new DocGen_Template__c(
        Name = VERIFY_NAME,
        // The DocGen_Button__mdt QA fixtures point at the template by API name,
        // not Id — an Id would tie the fixture to one org. This is the other end
        // of that reference; change it and docGenButton fails with "No DocGen
        // Template found with API Name", which reads like a product bug.
        API_Name__c = 'QA_Verify_Designer',
        Type__c = 'HTML',
        Output_Format__c = 'PDF',
        Base_Object_API__c = 'Account',
        Query_Config__c = 'Name, Industry, Phone, Website',
        Is_Active__c = true,
        Test_Record_Id__c = acctId,
        Header_Html__c = '<div style="text-align:left; font-size:9pt;">Header — edit me in the canvas</div>',
        Footer_Html__c = '<div style="text-align:center; font-size:8pt;">Page {PageNumber} of {TotalPages}</div>',
        Description__c = 'Seeded by scripts/qa/setup-org.sh for the designer smoke suite.'
    );
    insert tpl;
} else {
    tpl = existing[0];
    tpl.Test_Record_Id__c = acctId;
    tpl.Is_Active__c = true;
    tpl.API_Name__c = 'QA_Verify_Designer';
    update tpl;
}

// A body dense with merge-tag pills — the designer suite exercises pill
// handling, tables and the running bands, so the seed has to contain all three.
String body =
    '<!DOCTYPE html>\n<html>\n<head>\n<meta charset="utf-8" />\n<style>\n' +
    '@page { size: Letter portrait; margin: 0.75in; }\n' +
    'body { font-family: Helvetica, Arial, sans-serif; font-size: 10.5pt; color: #1a1a1a; }\n' +
    'table { border-collapse: collapse; width: 100%; }\n' +
    'td, th { border: 0.75pt solid #ddd; padding: 5pt 7pt; }\n' +
    '</style>\n</head>\n<body>\n' +
    '<h1>{Name}</h1>\n' +
    '<p>Industry {Industry} · Phone {Phone} · Web {Website}</p>\n' +
    '<p>Prepared by {RunningUser.Name} on {Today:MMMM d, yyyy}</p>\n' +
    '<table><tr><th>Field</th><th>Value</th></tr>' +
    '<tr><td>Name</td><td>{Name}</td></tr>' +
    '<tr><td>Industry</td><td>{Industry}</td></tr></table>\n' +
    '</body>\n</html>\n';

List<DocGen_Template_Version__c> vers = [
    SELECT Id
    FROM DocGen_Template_Version__c
    WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
    LIMIT 1
];
if (vers.isEmpty()) {
    ContentVersion cv = new ContentVersion(
        Title = 'docgen_qa_seed_body',
        PathOnClient = 'seed.html',
        VersionData = Blob.valueOf(body),
        FirstPublishLocationId = tpl.Id
    );
    insert cv;
    cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
    // Type__c MUST be set explicitly, even though the template already says HTML.
    // Word is default=true on this picklist, so omitting it does not leave it
    // blank — the platform stamps Word. DocGenController then does
    // template.Type__c = version.Type__c, and the editor tries to open an HTML
    // body as a DOCX archive and shows an empty canvas. Generation still works
    // (it reads the template's own type), so the template looks fine right up
    // until someone opens it.
    insert new DocGen_Template_Version__c(
        Template__c = tpl.Id,
        Content_Version_Id__c = cv.Id,
        Type__c = 'HTML',
        Is_Active__c = true
    );
}

// OUTSIDE the "new template" branch on purpose.
//
// The visual Designer does NOT read Content_Version_Id__c. It looks up a
// ContentVersion titled 'docgen_html_body_<templateId>' — what
// saveHtmlTemplateBody writes when a person saves in the UI. Without it the
// template opens to an empty canvas even though it generates perfectly.
//
// Writing this only when the template is CREATED means an org seeded before
// that was understood keeps a blank canvas forever, because every later run
// takes the update branch and skips it. This script is meant to be idempotent
// and safe to re-run; "repairs an existing org" is part of that, not a bonus.
// The template-integrity suite caught exactly this on the second run.
Integer designerBodies = [
    SELECT COUNT()
    FROM ContentVersion
    WHERE Title LIKE :('docgen_html_body_' + tpl.Id + '%') AND IsLatest = TRUE
];
if (designerBodies == 0) {
    insert new ContentVersion(
        Title = 'docgen_html_body_' + tpl.Id + '_' + Datetime.now().getTime(),
        PathOnClient = 'body.html',
        VersionData = Blob.valueOf(body),
        FirstPublishLocationId = tpl.Id
    );
    System.debug('SETUP designer body: created');
}
System.debug('SETUP template: ' + tpl.Id + ' (' + VERIFY_NAME + ')');
System.debug('SETUP complete');
