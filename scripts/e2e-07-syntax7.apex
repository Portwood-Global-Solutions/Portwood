// Standalone shared-content regression. All demo data rolls back.
// sf apex run --target-org <scratch-alias> -f scripts/e2e-07-syntax7.apex
Savepoint sp = Database.setSavepoint();
Integer pass = 0, fail = 0;
try {
    String key = 'e2e-snippet-' + String.valueOf(DateTime.now().getTime());
    Map<String, Object> asset = DocGenSnippetController.saveSnippet(
        null,
        'E2E shared clause',
        key,
        'QA',
        '<p style="page-break-inside:avoid">Terms for {Name}</p>',
        null,
        true
    );
    String tag = (String) asset.get('mergeTag');
    String expanded = DocGenService.extractHtmlBodyContent('<html><body>' + tag + '</body></html>');
    String result = DocGenService.processXmlForTest(expanded, new Map<String, Object>{ 'Name' => 'Example customer' });
    System.assertEquals('<p style="page-break-inside:avoid">Terms for Example customer</p>', result);
    pass++;
    // The giant HTML assembler uses this same extractor BEFORE its parent/aggregate scan.
    String giant = DocGenService.extractHtmlBodyContent(
        '<body><h2>Giant document</h2>' +
            tag +
            '<table><tr>{#Contacts}<td>{LastName}</td>{/Contacts}</tr></table></body>'
    );
    System.assert(giant.contains('Terms for {Name}') && !giant.contains('{%snippet:'));
    System.assert(DocGenService.extractLoopBody(giant, 'Contacts').get('innerXml').contains('{LastName}'));
    pass++;
    Map<String, Object> updated = DocGenSnippetController.saveSnippet(
        (Id) asset.get('id'),
        'E2E shared clause',
        key,
        'QA',
        '<p>Updated terms for {Name}</p>',
        (String) asset.get('currentVersionId'),
        true
    );
    System.assertEquals('<p>Updated terms for {Name}</p>', DocGenSnippetService.expand(tag));
    System.assertEquals('2', updated.get('versionNumber'));
    System.assert(
        ((String) DocGenSnippetController.getSnippet((Id) asset.get('id'), (Id) asset.get('versionId')).get('html'))
            .contains('Terms for')
    );
    pass++;
} catch (Exception e) {
    fail++;
    System.debug('SNIPPETS FAIL: ' + e.getMessage() + ' ' + e.getStackTraceString());
}
Database.rollback(sp);
System.debug(
    'E2E-07-SYNTAX7 — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
