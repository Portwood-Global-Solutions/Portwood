// DocGen E2E Test 07.5 — {RowNumber} loop counter via processXmlForTest()
// Run: sf apex run --target-org <org> -f scripts/e2e-07-syntax5.apex
// Depends on: nothing (uses DocGenService.processXmlForTest directly)
// Expected: PASS: N  FAIL: 0
//
// Split into its own file rather than appended to syntax1-4: those are all within
// a few hundred characters of the Anonymous Apex size ceiling.

Integer pass = 0;
Integer fail = 0;
String r;

// ============================================================
// RowNumber — numbers a child loop 1..N, in list order
// ============================================================
try {
    Map<String, Object> data = new Map<String, Object>{
        'Lines' => new List<Object>{
            new Map<String, Object>{ 'Name' => 'Alpha' },
            new Map<String, Object>{ 'Name' => 'Beta' },
            new Map<String, Object>{ 'Name' => 'Gamma' }
        }
    };
    r = DocGenService.processXmlForTest('{#Lines}[{RowNumber}.{Name}]{/Lines}', data);
    if (r == '[1.Alpha][2.Beta][3.Gamma]') {
        pass++;
        System.debug('ROWNUMBER BASIC: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROWNUMBER BASIC: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROWNUMBER BASIC: FAIL — ' + e.getMessage());
}

// ============================================================
// RowNumber — 1-based, not 0-based (off-by-one guard)
// ============================================================
try {
    Map<String, Object> data = new Map<String, Object>{
        'Lines' => new List<Object>{ new Map<String, Object>{ 'Name' => 'Only' } }
    };
    r = DocGenService.processXmlForTest('{#Lines}{RowNumber}{/Lines}', data);
    if (r == '1') {
        pass++;
        System.debug('ROWNUMBER ONE-BASED: PASS');
    } else {
        fail++;
        System.debug('ROWNUMBER ONE-BASED: FAIL — expected 1, got: ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROWNUMBER ONE-BASED: FAIL — ' + e.getMessage());
}

// ============================================================
// RowNumber — the {records: [...]} relationship shape (aliased/subset form)
// resolves the same as a bare list. These are two separate loop paths in
// processXml and a fix to one has historically missed the other.
// ============================================================
try {
    Map<String, Object> data = new Map<String, Object>{
        'Lines' => new Map<String, Object>{
            'records' => new List<Object>{
                new Map<String, Object>{ 'Name' => 'One' },
                new Map<String, Object>{ 'Name' => 'Two' }
            }
        }
    };
    r = DocGenService.processXmlForTest('{#Lines}[{RowNumber}:{Name}]{/Lines}', data);
    if (r == '[1:One][2:Two]') {
        pass++;
        System.debug('ROWNUMBER RECORDS-SHAPE: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROWNUMBER RECORDS-SHAPE: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROWNUMBER RECORDS-SHAPE: FAIL — ' + e.getMessage());
}

// ============================================================
// RowNumber — nested loops each count their OWN rows, and the inner counter
// does not leak back into the outer body after the inner loop closes.
// ============================================================
try {
    Map<String, Object> data = new Map<String, Object>{
        'Groups' => new List<Object>{
            new Map<String, Object>{
                'Title' => 'G1',
                'Items' => new List<Object>{
                    new Map<String, Object>{ 'Name' => 'a' },
                    new Map<String, Object>{ 'Name' => 'b' }
                }
            },
            new Map<String, Object>{
                'Title' => 'G2',
                'Items' => new List<Object>{ new Map<String, Object>{ 'Name' => 'c' } }
            }
        }
    };
    r = DocGenService.processXmlForTest(
        '{#Groups}<{RowNumber}:{Title}{#Items}({RowNumber}{Name}){/Items}={RowNumber}>{/Groups}',
        data
    );
    if (r == '<1:G1(1a)(2b)=1><2:G2(1c)=2>') {
        pass++;
        System.debug('ROWNUMBER NESTED: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROWNUMBER NESTED: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROWNUMBER NESTED: FAIL — ' + e.getMessage());
}

// ============================================================
// RowNumber — a record field actually named RowNumber still wins inside the
// loop body ONLY where the template did not ask for the counter. The counter is
// injected per row, so it shadows; this asserts the documented precedence
// rather than leaving it accidental.
// ============================================================
try {
    Map<String, Object> data = new Map<String, Object>{
        'Lines' => new List<Object>{
            new Map<String, Object>{ 'Name' => 'X', 'RowNumber' => 'FIELD' },
            new Map<String, Object>{ 'Name' => 'Y', 'RowNumber' => 'FIELD' }
        }
    };
    r = DocGenService.processXmlForTest('{#Lines}[{RowNumber}]{/Lines}', data);
    if (r == '[1][2]') {
        pass++;
        System.debug('ROWNUMBER SHADOWS FIELD: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROWNUMBER SHADOWS FIELD: FAIL — expected [1][2], got: ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROWNUMBER SHADOWS FIELD: FAIL — ' + e.getMessage());
}

// ============================================================
// RowNumber — a loop that does NOT use the tag is byte-identical to before.
// The row-map copy is gated on the tag being present, so this guards the
// no-cost path as much as the output.
// ============================================================
try {
    Map<String, Object> data = new Map<String, Object>{
        'Lines' => new List<Object>{
            new Map<String, Object>{ 'Name' => 'P' },
            new Map<String, Object>{ 'Name' => 'Q' }
        }
    };
    r = DocGenService.processXmlForTest('{#Lines}[{Name}]{/Lines}', data);
    if (r == '[P][Q]') {
        pass++;
        System.debug('ROWNUMBER ABSENT UNCHANGED: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROWNUMBER ABSENT UNCHANGED: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROWNUMBER ABSENT UNCHANGED: FAIL — ' + e.getMessage());
}

// ============================================================
// RowNumber — outside any loop it is not a tag and must not resolve to a
// number. Left alone, it is a plain unmatched merge tag.
// ============================================================
try {
    r = DocGenService.processXmlForTest('Total: {RowNumber}', new Map<String, Object>{ 'Name' => 'Z' });
    if (!r.contains('1')) {
        pass++;
        System.debug('ROWNUMBER OUTSIDE LOOP: PASS — ' + r);
    } else {
        fail++;
        System.debug('ROWNUMBER OUTSIDE LOOP: FAIL — resolved to a number outside a loop: ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('ROWNUMBER OUTSIDE LOOP: FAIL — ' + e.getMessage());
}

// ============================================================
// Currency aggregates — regression guard for the multi-currency fix.
// These orgs are single-currency, so the mixed-currency guard never engages;
// what is asserted here is that it stays completely out of the way. The guard
// and :convert conversion themselves are covered in DocGenCurrencyTest, which
// can stub the org's CurrencyType rates (anonymous Apex cannot reach the
// @TestVisible private seam).
// ============================================================
try {
    Map<String, Object> ad = new Map<String, Object>{
        'Items' => new Map<String, Object>{
            'records' => new List<Object>{
                new Map<String, Object>{ 'Amount' => 100, 'CurrencyIsoCode' => 'USD' },
                new Map<String, Object>{ 'Amount' => 50, 'CurrencyIsoCode' => 'EUR' }
            }
        }
    };
    r = DocGenService.processXmlForTest('<w:t>{SUM:Items.Amount:currency:GBP}</w:t>', ad);
    if (r.contains('150')) {
        pass++;
        System.debug('CURRENCY AGG SINGLE-CURRENCY ORG UNCHANGED: PASS — ' + r);
    } else {
        fail++;
        System.debug('CURRENCY AGG SINGLE-CURRENCY ORG UNCHANGED: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('CURRENCY AGG SINGLE-CURRENCY ORG UNCHANGED: FAIL — ' + e.getMessage());
}

// The :convert suffix is an aggregation-time instruction. It must be consumed
// before formatting and must never surface in rendered output.
try {
    Map<String, Object> ad = new Map<String, Object>{
        'Items' => new Map<String, Object>{
            'records' => new List<Object>{
                new Map<String, Object>{ 'Amount' => 100 },
                new Map<String, Object>{ 'Amount' => 25 }
            }
        }
    };
    r = DocGenService.processXmlForTest('<w:t>{SUM:Items.Amount:currency:EUR:convert}</w:t>', ad);
    if (r.contains('125') && !r.containsIgnoreCase('convert')) {
        pass++;
        System.debug('CURRENCY AGG :convert SUFFIX CONSUMED: PASS — ' + r);
    } else {
        fail++;
        System.debug('CURRENCY AGG :convert SUFFIX CONSUMED: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('CURRENCY AGG :convert SUFFIX CONSUMED: FAIL — ' + e.getMessage());
}

// :convert with a locale segment in between must still parse.
try {
    Map<String, Object> ad = new Map<String, Object>{
        'Items' => new Map<String, Object>{
            'records' => new List<Object>{ new Map<String, Object>{ 'Amount' => 1234.5 } }
        }
    };
    r = DocGenService.processXmlForTest('<w:t>{SUM:Items.Amount:currency:EUR:de_DE:convert}</w:t>', ad);
    if (!r.containsIgnoreCase('convert') && r.contains('1')) {
        pass++;
        System.debug('CURRENCY AGG :convert WITH LOCALE: PASS — ' + r);
    } else {
        fail++;
        System.debug('CURRENCY AGG :convert WITH LOCALE: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('CURRENCY AGG :convert WITH LOCALE: FAIL — ' + e.getMessage());
}

// ── #327: a split inverse tag must name the tag, not dump XML ───────────────
// jlay's report was unreadable because the message interpolated the raw key,
// and when Word splits a tag that key IS markup. The quotes looked empty
// because the XML inside them was stripped in transit.
try {
    String splitXml =
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{#Lines}{^</w:t></w:r>' +
        '<w:r><w:rPr><w:color w:val="000000"/></w:rPr><w:t></w:t></w:r>' +
        '<w:r><w:t>Optional__c}</w:t></w:r></w:p></w:tc>' +
        '<w:tc><w:p><w:r><w:t>{/Optional__c}{/Lines}</w:t></w:r></w:p></w:tc></w:tr></w:tbl>';
    DocGenService.processXmlForTest(
        splitXml,
        new Map<String, Object>{ 'Lines' => new List<Object>{ new Map<String, Object>{ 'Optional__c' => false } } }
    );
    fail++;
    System.debug('SPLIT INVERSE TAG: FAIL — expected a DocGenException');
} catch (Exception e) {
    String m = e.getMessage();
    if (m.contains('{^Optional__c}') && m.contains('split across formatting runs') && !m.contains('<w:')) {
        pass++;
        System.debug('SPLIT INVERSE TAG: PASS — names the tag, no raw XML');
    } else {
        fail++;
        System.debug('SPLIT INVERSE TAG: FAIL — got [' + m.left(160) + ']');
    }
}

// A genuinely missing closer must still say so, and stay readable.
try {
    DocGenService.processXmlForTest('<p>{^Optional__c}body</p>', new Map<String, Object>());
    fail++;
    System.debug('MISSING INVERSE CLOSER: FAIL — expected a DocGenException');
} catch (Exception e) {
    String m = e.getMessage();
    if (m.contains('{/Optional__c}') && !m.contains('<w:') && !m.contains('split across')) {
        pass++;
        System.debug('MISSING INVERSE CLOSER: PASS — asks for the closing tag');
    } else {
        fail++;
        System.debug('MISSING INVERSE CLOSER: FAIL — got [' + m.left(160) + ']');
    }
}

System.debug('========================================');
System.debug(
    'E2E-07-SYNTAX5 — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
