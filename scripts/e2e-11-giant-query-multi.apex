// Giant Query multi-table regression (#540). Standalone. All demo data rolls back.
// Runs the synchronous half of the multi-table pipeline against real records:
// plan -> one USER_MODE cursor per dataset -> rows rendered per table -> tables put back in authored order.
// The asynchronous harvest and the PDF render are covered by scripts/qa/giant-query-540-check.mjs.
// sf apex run --target-org <scratch-alias> -f scripts/e2e-11-giant-query-multi.apex
Savepoint sp = Database.setSavepoint();
Integer pass = 0, fail = 0;
Account acc = new Account(Name = 'E2E GQ Multi');
insert acc;
List<Contact> contacts = new List<Contact>();
// Inserted out of order so the cursor's ORDER BY is what puts them in order.
for (Integer i = 3; i >= 1; i--) {
    contacts.add(
        new Contact(AccountId = acc.Id, LastName = 'Active' + i, FirstName = 'Role' + i, Department = 'GQ-Active')
    );
}
contacts.add(new Contact(AccountId = acc.Id, LastName = 'Inactive1', FirstName = 'Role9', Department = 'GQ-Inactive'));
insert contacts;
String stage = [SELECT MasterLabel FROM OpportunityStage WHERE IsActive = TRUE ORDER BY SortOrder LIMIT 1].MasterLabel;
insert new List<Opportunity>{
    new Opportunity(AccountId = acc.Id, Name = 'OppLate', StageName = stage, CloseDate = Date.today().addDays(2)),
    new Opportunity(AccountId = acc.Id, Name = 'OppEarly', StageName = stage, CloseDate = Date.today().addDays(1))
};

String root = '{"id":"n0","object":"Account","fields":["Name"],"parentNode":null}';
String child = '"parentNode":"n0","lookupField":"AccountId",';
String config =
    '{"v":3,"root":"Account","nodes":[' +
    root +
    ',{"id":"ActiveContacts","alias":"ActiveContacts",' +
    child +
    '"object":"Contact","relationshipName":"Contacts","fields":["LastName","FirstName"],' +
    '"orderBy":"LastName ASC","where":"Department = \'GQ-Active\'"}' +
    ',{"id":"InactiveContacts","alias":"InactiveContacts",' +
    child +
    '"object":"Contact","relationshipName":"Contacts","fields":["LastName"],' +
    '"orderBy":"LastName ASC","where":"Department = \'GQ-Inactive\'"}' +
    ',{"id":"Opportunities",' +
    child +
    '"object":"Opportunity","relationshipName":"Opportunities","fields":["Name","CloseDate"],' +
    '"orderBy":"CloseDate ASC"}]}';

// Four tables from three datasets: ActiveContacts feeds the first and the last table.
String body =
    '<h1>{Name}</h1>' +
    '<p>MARK-A</p><table><tbody>{#ActiveContacts}<tr><td>A-{LastName}</td></tr>{/ActiveContacts}</tbody></table>' +
    '<p>MARK-I</p><table><tbody>{#InactiveContacts}<tr><td>I-{LastName}</td></tr>{/InactiveContacts}</tbody></table>' +
    '<p>MARK-O</p><table><tbody>{#Opportunities}<tr><td>O-{Name}</td></tr>{/Opportunities}</tbody></table>' +
    '<p>MARK-R</p><table><tbody>{#ActiveContacts}<tr><td>R-{FirstName}</td></tr>{/ActiveContacts}</tbody></table>' +
    '<p>MARK-END</p>';

// ── 1. Plan: four tables, in authored order, sharing three datasets ──
DocGenGiantQueryMulti.Run run;
try {
    run = DocGenGiantQueryMulti.plan(body, config, acc.Id);
    System.assertNotEquals(null, run, 'A template with several large tables must plan as multi-table.');
    System.assertEquals(4, run.slots.size());
    List<String> keys = new List<String>();
    for (DocGenGiantQueryPlan.Slot slot : run.slots) {
        keys.add(slot.queryKey);
    }
    System.assertEquals(
        new List<String>{ 'ActiveContacts', 'InactiveContacts', 'Opportunities', 'ActiveContacts' },
        keys
    );
    System.assertEquals(3, run.datasets.size(), 'A query used by two tables must be read once.');
    System.assertEquals(2, run.datasets[0].slots.size());
    System.assertEquals('Contact', run.datasets[0].childNode.get('object'));
    pass++;
} catch (Exception e) {
    fail++;
    System.debug('GQ-MULTI PLAN FAIL: ' + e.getMessage() + ' ' + e.getStackTraceString());
}

// ── 2. Retrieve and render every table, then reassemble ──
try {
    Map<String, String> rowsBySlot = new Map<String, String>();
    Map<String, Integer> counts = new Map<String, Integer>();
    for (DocGenGiantQueryMulti.Dataset ds : run.datasets) {
        Database.Cursor cursor = DocGenDataRetriever.openGiantQueryCursor(acc.Id, ds.childNode, ds.fields);
        Integer total = cursor.getNumRecords();
        List<SObject> rows = total == 0 ? new List<SObject>() : cursor.fetch(0, total);
        counts.put(ds.slots[0].queryKey, rows.size());
        for (DocGenGiantQueryPlan.Slot slot : ds.slots) {
            rowsBySlot.put(
                slot.key,
                DocGenService.renderLoopBodyForRecords(slot.innerXml, slot.queryKey, rows, ds.fields, 0, 'HTML', 'PDF')
            );
        }
    }
    // Aliases over one relationship keep their own filters.
    System.assertEquals(3, counts.get('ActiveContacts'));
    System.assertEquals(1, counts.get('InactiveContacts'));
    System.assertEquals(2, counts.get('Opportunities'));

    Set<String> queryKeys = new Set<String>{ 'ActiveContacts', 'InactiveContacts', 'Opportunities' };
    String html = DocGenGiantQueryPlan.compile(body, queryKeys).fill(rowsBySlot);
    System.assert(!html.contains('docgen-giant-slot'), 'Every slot marker must be replaced.');
    System.assert(!html.contains('{#'), 'No loop tags may survive assembly.');
    List<String> expected = new List<String>{
        'MARK-A',
        'A-Active1',
        'A-Active2',
        'A-Active3',
        'MARK-I',
        'I-Inactive1',
        'MARK-O',
        'O-OppEarly',
        'O-OppLate',
        'MARK-R',
        'R-Role1',
        'R-Role2',
        'R-Role3',
        'MARK-END'
    };
    Integer cursorAt = -1;
    for (String token : expected) {
        Integer at = html.indexOf(token);
        System.assert(at > cursorAt, token + ' is missing or out of order in: ' + html);
        cursorAt = at;
    }
    // Each table holds only its own rows.
    String activeTable = html.substringBetween('MARK-A', 'MARK-I');
    System.assert(!activeTable.contains('Inactive1') && !activeTable.contains('Opp'));
    System.assertEquals(3, html.countMatches('A-Active'));
    System.assertEquals(3, html.countMatches('R-Role'));
    System.assertEquals(1, html.countMatches('I-Inactive'));
    pass++;
} catch (Exception e) {
    fail++;
    System.debug('GQ-MULTI RENDER FAIL: ' + e.getMessage() + ' ' + e.getStackTraceString());
}

// ── 3. A single large table keeps the original Giant Query path ──
try {
    String single = '<table><tbody>{#Opportunities}<tr><td>{Name}</td></tr>{/Opportunities}</tbody></table>';
    System.assertEquals(null, DocGenGiantQueryMulti.plan(single, config, acc.Id));
    pass++;
} catch (Exception e) {
    fail++;
    System.debug('GQ-MULTI SINGLE FAIL: ' + e.getMessage() + ' ' + e.getStackTraceString());
}

// ── 4. A large table nested inside a section is rejected with a clear message ──
try {
    String nested =
        '<table><tbody>{#ActiveContacts}<tr><td>{LastName}</td></tr>{/ActiveContacts}</tbody></table>' +
        '<table><tbody>{#InactiveContacts}<tr><td>{LastName}</td></tr>{/InactiveContacts}</tbody></table>' +
        '{#IF Name}<table><tbody>{#Opportunities}<tr><td>{Name}</td></tr>{/Opportunities}</tbody></table>{/IF}';
    Boolean threw = false;
    try {
        DocGenGiantQueryMulti.plan(nested, config, acc.Id);
    } catch (DocGenException e) {
        threw = e.getMessage().contains('top-level table loops') && e.getMessage().contains('Opportunities');
    }
    System.assert(threw, 'A nested giant table must be rejected by name.');
    pass++;
} catch (Exception e) {
    fail++;
    System.debug('GQ-MULTI NESTED FAIL: ' + e.getMessage() + ' ' + e.getStackTraceString());
}

// ── 5. Two child queries with the same key are rejected ──
try {
    String dupConfig =
        '{"v":3,"root":"Account","nodes":[' +
        root +
        ',{"id":"c1",' +
        child +
        '"object":"Contact","relationshipName":"Contacts","fields":["LastName"]}' +
        ',{"id":"c2",' +
        child +
        '"object":"Contact","relationshipName":"Contacts","fields":["FirstName"]}' +
        ',{"id":"o1",' +
        child +
        '"object":"Opportunity","relationshipName":"Opportunities","fields":["Name"]}]}';
    String dupBody =
        '<table><tbody>{#Contacts}<tr><td>{LastName}</td></tr>{/Contacts}</tbody></table>' +
        '<table><tbody>{#Opportunities}<tr><td>{Name}</td></tr>{/Opportunities}</tbody></table>';
    Boolean threw = false;
    try {
        DocGenGiantQueryMulti.plan(dupBody, dupConfig, acc.Id);
    } catch (DocGenException e) {
        threw = e.getMessage().contains('alias must be unique');
    }
    System.assert(threw, 'Duplicate child query keys must be rejected.');
    pass++;
} catch (Exception e) {
    fail++;
    System.debug('GQ-MULTI DUPLICATE FAIL: ' + e.getMessage() + ' ' + e.getStackTraceString());
}

// ── 6. Root-anchor tags inside a large table are rejected ──
try {
    String anchored =
        '<table><tbody>{#ActiveContacts}<tr><td>{~Acct}{Name}{/Acct}</td></tr>{/ActiveContacts}</tbody></table>' +
        '<table><tbody>{#Opportunities}<tr><td>{Name}</td></tr>{/Opportunities}</tbody></table>';
    Boolean threw = false;
    try {
        DocGenGiantQueryMulti.plan(anchored, config, acc.Id);
    } catch (DocGenException e) {
        threw = e.getMessage().contains('Root-anchor');
    }
    System.assert(threw, 'Root-anchor tags in a giant table must be rejected.');
    pass++;
} catch (Exception e) {
    fail++;
    System.debug('GQ-MULTI ANCHOR FAIL: ' + e.getMessage() + ' ' + e.getStackTraceString());
}

Database.rollback(sp);
System.debug(
    'E2E-11-GIANT-QUERY-MULTI — PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
