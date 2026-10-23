// DocGen E2E Test 07.6 — {~Label} root-anchor tag (#439) via processXmlForTest()
// Run: sf apex run --target-org <org> -f scripts/e2e-07-syntax6.apex
// Depends on: nothing (uses DocGenService.processXmlForTest directly)
// Expected: PASS: N  FAIL: 0
//
// Split into its own file rather than appended to syntax1-5: those are all within
// a few hundred characters of the Anonymous Apex size ceiling.

Integer pass = 0;
Integer fail = 0;
String r;

// ============================================================
// #439 repro itself — a loop over Line_Items__r has no reach to the sibling
// Offices__r relationship on the parent record (rowContext() swaps the data
// context to the current row's own map). {~Offices} defers its body and
// resolves it against the root map instead, so {#Offices__r} inside it now
// sees Austin/Denver from INSIDE the Line_Items__r loop, at the position
// where the author wrote it — not pushed after the loop as a workaround.
// ============================================================
try {
    Map<String, Object> data = new Map<String, Object>{
        'Name' => 'Acme Corp',
        'Offices__r' => new Map<String, Object>{
            'records' => new List<Object>{
                new Map<String, Object>{ 'City__c' => 'Austin' },
                new Map<String, Object>{ 'City__c' => 'Denver' }
            }
        },
        'Line_Items__r' => new Map<String, Object>{
            'records' => new List<Object>{ new Map<String, Object>{ 'Product__c' => 'Widget' } }
        }
    };
    r = DocGenService.processXmlForTest(
        '{#Line_Items__r}Product={Product__c}, {~Offices}{#Offices__r}{City__c} {/Offices__r}{/Offices}end{/Line_Items__r}',
        data
    );
    if (r == 'Product=Widget, Austin Denver end') {
        pass++;
        System.debug('ROOTANCHOR #439 REPRO: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROOTANCHOR #439 REPRO: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROOTANCHOR #439 REPRO: FAIL — ' + e.getMessage());
}

// ============================================================
// {~Label} at true top level (no enclosing loop) is a harmless no-op path —
// the owning call's root data IS the data it would have resolved against
// anyway, so nesting is not required to use the tag.
// ============================================================
try {
    r = DocGenService.processXmlForTest('{~X}Hello {Name}{/X}', new Map<String, Object>{ 'Name' => 'World' });
    if (r == 'Hello World') {
        pass++;
        System.debug('ROOTANCHOR TOP LEVEL NOOP: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROOTANCHOR TOP LEVEL NOOP: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROOTANCHOR TOP LEVEL NOOP: FAIL — ' + e.getMessage());
}

// ============================================================
// Two independent {~Label} tags with different labels in the same document
// don't conflict — the marker sequence counter and drain loop keep them
// separate.
// ============================================================
try {
    Map<String, Object> data = new Map<String, Object>{ 'A' => 'Alpha', 'B' => 'Beta' };
    r = DocGenService.processXmlForTest('[{~First}{A}{/First}][{~Second}{B}{/Second}]', data);
    if (r == '[Alpha][Beta]') {
        pass++;
        System.debug('ROOTANCHOR TWO INDEPENDENT TAGS: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROOTANCHOR TWO INDEPENDENT TAGS: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROOTANCHOR TWO INDEPENDENT TAGS: FAIL — ' + e.getMessage());
}

// ============================================================
// A {~Label} nested inside another {~Label} must still drain — resolving the
// outer job's content (itself a processXml call) enqueues the inner job onto
// the SAME pending list, so the drain loop's index cursor has to keep going
// past the list's original length, not snapshot it.
// ============================================================
try {
    r = DocGenService.processXmlForTest(
        '{~Outer}outer-{~Inner}{Name}{/Inner}-end{/Outer}',
        new Map<String, Object>{ 'Name' => 'Nested' }
    );
    if (r == 'outer-Nested-end') {
        pass++;
        System.debug('ROOTANCHOR NESTED DRAINS: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROOTANCHOR NESTED DRAINS: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROOTANCHOR NESTED DRAINS: FAIL — ' + e.getMessage());
}

// ============================================================
// {#ChartBucket} nested inside {~Label} nested inside a loop. Regression
// guard for a second bug found while building this fix: preprocessInline's
// depth-tracker only recognized {# as a section opener, not {~ — so a chart
// wrapped in {~Label} would get eagerly (and wrongly) resolved against the
// current LOOP ROW before the {~} dispatch branch ever got a chance to defer
// it. Each Contacts row must independently resolve the SIBLING Opportunities
// relationship's full bucket breakdown, not render empty or wrong.
// ============================================================
try {
    Map<String, Object> data = new Map<String, Object>{
        'Opportunities' => new Map<String, Object>{
            'records' => new List<Object>{
                new Map<String, Object>{ 'StageName' => 'Closed Won' },
                new Map<String, Object>{ 'StageName' => 'Closed Won' },
                new Map<String, Object>{ 'StageName' => 'Prospecting' }
            }
        },
        'Contacts' => new Map<String, Object>{
            'records' => new List<Object>{
                new Map<String, Object>{ 'LastName' => 'Alpha' },
                new Map<String, Object>{ 'LastName' => 'Beta' }
            }
        }
    };
    r = DocGenService.processXmlForTest(
        '{#Contacts}[{LastName}: {~Chart}{#ChartBucket:Opportunities:StageName}{key}={count} {/ChartBucket}{/Chart}]{/Contacts}',
        data
    );
    if (r.contains('Alpha: Closed Won=2 Prospecting=1') && r.contains('Beta: Closed Won=2 Prospecting=1')) {
        pass++;
        System.debug('ROOTANCHOR CHARTBUCKET NESTED IN LOOP: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROOTANCHOR CHARTBUCKET NESTED IN LOOP: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROOTANCHOR CHARTBUCKET NESTED IN LOOP: FAIL — ' + e.getMessage());
}

// ============================================================
// Malformed {~Label} with no matching {/Label} must throw, mirroring the
// existing {#…}/{^…} malformed-tag behavior rather than silently dropping
// content.
// ============================================================
try {
    r = DocGenService.processXmlForTest('{~Unclosed}no closer here', new Map<String, Object>{ 'X' => 1 });
    fail++;
    System.debug('ROOTANCHOR UNCLOSED THROWS: FAIL — expected DocGenException, got result: ' + r);
} catch (Exception e) {
    if (e.getMessage().contains('Malformed root-anchor tag')) {
        pass++;
        System.debug('ROOTANCHOR UNCLOSED THROWS: PASS — ' + e.getMessage());
    } else {
        fail++;
        System.debug('ROOTANCHOR UNCLOSED THROWS: FAIL — wrong exception: ' + e.getMessage());
    }
}

// ============================================================
// Giant-query scope limit (#439) — a {~Label} tag inside a giant-query loop's
// row template is not supported (each chunk renders against a flat,
// field-limited per-record map with no sibling-relationship data, by design,
// to keep per-chunk heap bounded). DocGenGiantQueryBatch must fail loud and
// synchronously at construction, before Database.executeBatch ever runs,
// rather than silently rendering every {~} blank across a large job. The
// guard runs before childNodeConfig is read, so placeholder ids/config are
// enough to prove it.
// ============================================================
try {
    DocGenGiantQueryBatch b = new DocGenGiantQueryBatch(
        null,
        null,
        null,
        new Map<String, Object>(),
        '<w:tr><w:tc>{~Offices}{#Offices__r}{City__c}{/Offices__r}{/Offices}</w:tc></w:tr>',
        'PDF'
    );
    fail++;
    System.debug('ROOTANCHOR GIANT-QUERY FAILS LOUD: FAIL — expected DocGenException, construction succeeded');
} catch (Exception e) {
    if (e.getMessage().contains('not supported inside giant-query loops')) {
        pass++;
        System.debug('ROOTANCHOR GIANT-QUERY FAILS LOUD: PASS — ' + e.getMessage());
    } else {
        fail++;
        System.debug('ROOTANCHOR GIANT-QUERY FAILS LOUD: FAIL — wrong exception: ' + e.getMessage());
    }
}

// A giant-query batch WITHOUT a {~} tag must construct normally — proves the
// guard is scoped to the literal '{~' substring and doesn't false-positive on
// ordinary giant-query templates.
try {
    DocGenGiantQueryBatch b2 = new DocGenGiantQueryBatch(
        null,
        null,
        null,
        new Map<String, Object>{
            'relationshipName' => 'Line_Items__r',
            'object' => 'OpportunityLineItem',
            'lookupField' => 'OpportunityId',
            'fields' => new List<Object>{ 'Product2.Name' }
        },
        '<w:tr><w:tc>{Product2.Name}</w:tc></w:tr>',
        'PDF'
    );
    pass++;
    System.debug('ROOTANCHOR GIANT-QUERY UNCHANGED WITHOUT TAG: PASS');
} catch (Exception e) {
    fail++;
    System.debug('ROOTANCHOR GIANT-QUERY UNCHANGED WITHOUT TAG: FAIL — ' + e.getMessage());
}

System.debug('========================================');
System.debug(
    'E2E-07-SYNTAX6 — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
