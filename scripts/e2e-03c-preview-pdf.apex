// DocGen E2E Test 03c - Designer draft PDF preview handoff
// Run: sf apex run --target-org <org> -f scripts/e2e-03c-preview-pdf.apex
// Depends on: nothing (creates and cleans up its own data)
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;

Account acct;
DocGen_Template__c tmpl;

try {
    acct = new Account(Name = 'E2E Preview Account ' + Datetime.now().getTime());
    insert acct;
    pass++;
    System.debug('ACCOUNT CREATED: PASS - ' + acct.Id);
} catch (Exception e) {
    fail++;
    System.debug('ACCOUNT CREATED: FAIL - ' + e.getMessage());
}

try {
    tmpl = new DocGen_Template__c(
        Name = 'E2E PDF Preview Template ' + Datetime.now().getTime(),
        Type__c = 'HTML',
        Output_Format__c = 'PDF',
        Base_Object_API__c = 'Account',
        Query_Config__c = 'Name, CreatedDate'
    );
    insert tmpl;
    pass++;
    System.debug('TEMPLATE CREATED: PASS - ' + tmpl.Id);
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE CREATED: FAIL - ' + e.getMessage());
}

if (acct != null && tmpl != null) {
    try {
        String draftHtml =
            '<h1>PDF Preview Test</h1>' +
            '<p>Account Name: {Name}</p>' +
            '<p>Created Date: {CreatedDate}</p>';
        Map<String, Object> result = DocGenController.previewDraftPdf(tmpl.Id, acct.Id, draftHtml, '', '');

        Id contentVersionId = (Id) result.get('contentVersionId');
        Id contentDocumentId = (Id) result.get('contentDocumentId');

        if (contentVersionId != null && contentDocumentId != null) {
            pass++;
            System.debug('PREVIEW IDS RETURNED: PASS - version=' + contentVersionId + ', document=' + contentDocumentId);
        } else {
            fail++;
            System.debug('PREVIEW IDS RETURNED: FAIL - ' + result);
        }

        if (contentVersionId != null) {
            ContentVersion cv = [
                SELECT Id, ContentDocumentId, Title, PathOnClient, FileExtension, ContentSize
                FROM ContentVersion
                WHERE Id = :contentVersionId
                LIMIT 1
            ];

            Boolean titleOk = cv.Title == 'dg_pdf_preview_' + tmpl.Id;
            Boolean documentOk = cv.ContentDocumentId == contentDocumentId;
            Boolean pdfOk = cv.PathOnClient == 'preview.pdf' && cv.FileExtension == 'pdf' && cv.ContentSize > 500;

            if (titleOk && documentOk && pdfOk) {
                pass++;
                System.debug('PREVIEW CONTENTVERSION PDF: PASS - size=' + cv.ContentSize);
            } else {
                fail++;
                System.debug(
                    'PREVIEW CONTENTVERSION PDF: FAIL - titleOk=' +
                        titleOk +
                        ' documentOk=' +
                        documentOk +
                        ' pdfOk=' +
                        pdfOk +
                        ' title=' +
                        cv.Title +
                        ' path=' +
                        cv.PathOnClient +
                        ' ext=' +
                        cv.FileExtension +
                        ' size=' +
                        cv.ContentSize
                );
            }
        }
    } catch (Exception e) {
        fail++;
        System.debug('PREVIEW DRAFT PDF: FAIL - ' + e.getMessage() + ' line ' + e.getLineNumber());
    }
}

try {
    if (tmpl != null) {
        delete tmpl;
    }
    if (acct != null) {
        delete acct;
    }
    pass++;
    System.debug('CLEANUP: PASS');
} catch (Exception e) {
    fail++;
    System.debug('CLEANUP: FAIL - ' + e.getMessage());
}

System.debug('========================================');
System.debug(
    'E2E-03C PREVIEW PDF - PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
