// DocGen E2E Test 07-syntax3 — Running-user merge tags (v1.77+)
// Run: sf apex run --target-org <org> -f scripts/e2e-07-syntax3.apex
// Depends on: nothing (uses DocGenService.processXmlForTest directly)
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;
String r;

// ===== {RunningUser.Name} resolves to UserInfo.getName() =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.Name}</w:t>', new Map<String, Object>());
    if (r.contains(UserInfo.getName())) {
        pass++;
        System.debug('RUNNING USER NAME: PASS — ' + r);
    } else {
        fail++;
        System.debug('RUNNING USER NAME: FAIL — got [' + r + '] expected to contain [' + UserInfo.getName() + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER NAME: FAIL — ' + e.getMessage());
}

// ===== {RunningUser.FirstName} =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.FirstName}</w:t>', new Map<String, Object>());
    if (UserInfo.getFirstName() == null || r.contains(UserInfo.getFirstName())) {
        pass++;
        System.debug('RUNNING USER FIRSTNAME: PASS — ' + r);
    } else {
        fail++;
        System.debug('RUNNING USER FIRSTNAME: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER FIRSTNAME: FAIL — ' + e.getMessage());
}

// ===== {RunningUser.Email} =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.Email}</w:t>', new Map<String, Object>());
    if (r.contains(UserInfo.getUserEmail())) {
        pass++;
        System.debug('RUNNING USER EMAIL: PASS');
    } else {
        fail++;
        System.debug('RUNNING USER EMAIL: FAIL — got [' + r + '] expected [' + UserInfo.getUserEmail() + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER EMAIL: FAIL — ' + e.getMessage());
}

// ===== {RunningUser.Username} =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.Username}</w:t>', new Map<String, Object>());
    if (r.contains(UserInfo.getUserName())) {
        pass++;
        System.debug('RUNNING USER USERNAME: PASS');
    } else {
        fail++;
        System.debug('RUNNING USER USERNAME: FAIL — got [' + r + '] expected [' + UserInfo.getUserName() + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER USERNAME: FAIL — ' + e.getMessage());
}

// ===== {RunningUser.Id} resolves to current user Id =====
try {
    r = DocGenService.processXmlForTest('<w:t>{RunningUser.Id}</w:t>', new Map<String, Object>());
    if (r.contains(String.valueOf(UserInfo.getUserId()).left(15))) {
        pass++;
        System.debug('RUNNING USER ID: PASS');
    } else {
        fail++;
        System.debug('RUNNING USER ID: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER ID: FAIL — ' + e.getMessage());
}

// ===== Case insensitive: {runninguser.name} should also work =====
try {
    r = DocGenService.processXmlForTest('<w:t>{runninguser.name}</w:t>', new Map<String, Object>());
    if (r.contains(UserInfo.getName())) {
        pass++;
        System.debug('RUNNING USER LOWERCASE: PASS');
    } else {
        fail++;
        System.debug('RUNNING USER LOWERCASE: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER LOWERCASE: FAIL — ' + e.getMessage());
}

// ===== Unknown subfield (not in allowlist) → empty resolution =====
try {
    r = DocGenService.processXmlForTest('<w:t>[{RunningUser.SomethingFake}]</w:t>', new Map<String, Object>());
    // Expected: tag resolves to empty — output is "[]"
    if (r.contains('[]')) {
        pass++;
        System.debug('RUNNING USER UNKNOWN FIELD: PASS — ' + r);
    } else {
        fail++;
        System.debug('RUNNING USER UNKNOWN FIELD: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER UNKNOWN FIELD: FAIL — ' + e.getMessage());
}

// ===== Rich-text apostrophe decode (issue #51) =====
// Lightning RTE stores apostrophes as &#39; and double-quotes as &quot;;
// convertRichTextToDocxXml must decode both before emitting OOXML.
try {
    String rt = '<p>ain&#39;t it &quot;great&quot;</p>';
    r = DocGenService.processXmlForTest(
        '<w:p><w:r><w:t>{Notes}</w:t></w:r></w:p>',
        new Map<String, Object>{ 'Notes' => rt }
    );
    // After decode, OOXML re-escapes apostrophe as &apos; and quote as &quot;
    // for XML safety; Word/PDF unescape on render. The bug signature is the
    // numeric reference &#39; surviving — that's what we must NOT see.
    Boolean noNumericRef = !r.contains('&#39;');
    Boolean apos = r.contains('ain&apos;t') || r.contains('ain\'t');
    Boolean quot = r.contains('&quot;great&quot;') || r.contains('"great"');
    if (apos && quot && noNumericRef) {
        pass++;
        System.debug('RICHTEXT APOSTROPHE DECODE: PASS');
    } else {
        fail++;
        System.debug(
            'RICHTEXT APOSTROPHE DECODE: FAIL — apos=' +
                apos +
                ' quot=' +
                quot +
                ' noNumericRef=' +
                noNumericRef +
                ' r=' +
                r
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('RICHTEXT APOSTROPHE DECODE: FAIL — ' + e.getMessage());
}

// ===== Rich-text Unicode numeric entities (issue #51 follow-up) =====
// Smart quotes / em-dash / en-dash / hex-form accented char must all decode.
// The renderer's decodeNumericEntities is reused by the DOCX rich-text path.
try {
    String rt = '<p>he said &#8220;don&#8217;t&#8221; &#8212; ok&#8211;done caf&#xE9;</p>';
    r = DocGenService.processXmlForTest('<w:p><w:r><w:t>{N}</w:t></w:r></w:p>', new Map<String, Object>{ 'N' => rt });
    Boolean noRefs =
        !r.contains('&#8220;') &&
        !r.contains('&#8217;') &&
        !r.contains('&#8221;') &&
        !r.contains('&#8212;') &&
        !r.contains('&#8211;') &&
        !r.contains('&#xE9;');
    Boolean ldquo = r.contains('“'); // left double quote
    Boolean rsquo = r.contains('’'); // right single quote
    Boolean rdquo = r.contains('”'); // right double quote
    Boolean mdash = r.contains('—'); // em dash
    Boolean ndash = r.contains('–'); // en dash
    Boolean eacute = r.contains('é'); // é
    if (noRefs && ldquo && rsquo && rdquo && mdash && ndash && eacute) {
        pass++;
        System.debug('RICHTEXT UNICODE DECODE: PASS');
    } else {
        fail++;
        System.debug(
            'RICHTEXT UNICODE DECODE: FAIL — noRefs=' +
                noRefs +
                ' ldquo=' +
                ldquo +
                ' rsquo=' +
                rsquo +
                ' rdquo=' +
                rdquo +
                ' mdash=' +
                mdash +
                ' ndash=' +
                ndash +
                ' eacute=' +
                eacute +
                ' r=' +
                r
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('RICHTEXT UNICODE DECODE: FAIL — ' + e.getMessage());
}

// ===== Allowlist enforcement: a User field NOT in the allowlist (e.g., ProfileId) =====
try {
    r = DocGenService.processXmlForTest('<w:t>[{RunningUser.ProfileId}]</w:t>', new Map<String, Object>());
    // ProfileId is intentionally NOT in the allowlist — must resolve to empty.
    if (r.contains('[]')) {
        pass++;
        System.debug('RUNNING USER ALLOWLIST GUARD: PASS — ProfileId not exposed');
    } else {
        fail++;
        System.debug('RUNNING USER ALLOWLIST GUARD: FAIL — got [' + r + ']');
    }
} catch (Exception e) {
    fail++;
    System.debug('RUNNING USER ALLOWLIST GUARD: FAIL — ' + e.getMessage());
}

// ===== Document title built-ins: {Today}, {Now}, {RunningUser.X}, format suffixes =====
// generateDocTitle previously only walked data-map fields; built-ins rendered empty.
try {
    Map<String, Object> recData = new Map<String, Object>{ 'Name' => 'Acme' };
    String t1 = DocGenService.generateDocTitle('{Name}-{Today:MM-dd-yyyy}', recData);
    Date td = Date.today();
    String mm = td.month() < 10 ? '0' + td.month() : '' + td.month();
    String dd = td.day() < 10 ? '0' + td.day() : '' + td.day();
    String expected1 = 'Acme-' + mm + '-' + dd + '-' + td.year();
    Boolean ok1 = (t1 == expected1);

    String t2 = DocGenService.generateDocTitle('{Now:yyyy}', recData);
    Boolean ok2 = (t2 == String.valueOf(DateTime.now().year()));

    String t3 = DocGenService.generateDocTitle('Prepared by {RunningUser.Name}', recData);
    Boolean ok3 = t3.contains(UserInfo.getName());

    String t4 = DocGenService.generateDocTitle('{Today}', recData);
    Boolean ok4 = String.isNotBlank(t4) && t4.contains(String.valueOf(td.year()));

    if (ok1 && ok2 && ok3 && ok4) {
        pass++;
        System.debug('TITLE BUILTINS: PASS — ' + t1 + ' | ' + t2 + ' | ' + t3 + ' | ' + t4);
    } else {
        fail++;
        System.debug(
            'TITLE BUILTINS: FAIL — ok1=' +
                ok1 +
                ' ok2=' +
                ok2 +
                ' ok3=' +
                ok3 +
                ' ok4=' +
                ok4 +
                ' t1=' +
                t1 +
                ' t2=' +
                t2 +
                ' t3=' +
                t3 +
                ' t4=' +
                t4
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('TITLE BUILTINS: FAIL — ' + e.getMessage());
}

// ===== Salesforce Custom Label merge tags =====
try {
    String resolved = DocGenService.processXmlForTest(
        'Before {!$Label.DocGenRunner_Subtitle} after',
        new Map<String, Object>()
    );
    String missing = DocGenService.processXmlForTest(
        'Before {!$Label.Portwood_Label_That_Does_Not_Exist} after',
        new Map<String, Object>()
    );
    String title = DocGenService.generateDocTitle(
        '{!$Label.DocGenRunner_Category} - {Name}',
        new Map<String, Object>{ 'Name' => 'Example' }
    );

    Boolean resolvedOk = resolved == 'Before Create or combine documents for this record. after';
    Boolean missingOk = missing == 'Before  after';
    Boolean titleOk = title == 'Category - Example';
    if (resolvedOk && missingOk && titleOk) {
        pass++;
        System.debug('CUSTOM LABEL MERGE TAGS: PASS');
    } else {
        fail++;
        System.debug(
            'CUSTOM LABEL MERGE TAGS: FAIL - resolved=' + resolved + ' missing=' + missing + ' title=' + title
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('CUSTOM LABEL MERGE TAGS: FAIL - ' + e.getMessage());
}

// ===== IF inside table row, condition false, no else (issue #53) =====
// Pre-fix: smart-container expansion backtracked the row's <w:tr> opening,
// IF emitted nothing, downstream </w:tr> orphaned → DOCX corruption + PDF
// trailing-content drop. Post-fix: IF must NEVER trigger container expansion.
try {
    String tableXml =
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{#IF Status = open}{Name}{/IF}</w:t></w:r></w:p></w:tc></w:tr>' +
        '<w:tr><w:tc><w:p><w:r><w:t>after-row</w:t></w:r></w:p></w:tc></w:tr></w:tbl>';
    Map<String, Object> falseData = new Map<String, Object>{ 'Status' => 'closed', 'Name' => 'Acme' };
    String r1 = DocGenService.processXmlForTest(tableXml, falseData);
    Boolean falseHasFirstRow = r1.contains('<w:tr>') && r1.indexOf('<w:tr>') < r1.indexOf('after-row');
    Boolean falseHasAfter = r1.contains('after-row');
    Boolean falseBalanced =
        (r1.indexOf('<w:tr>') != -1) &&
        (r1.indexOf('</w:tr>') != -1) &&
        r1.split('<w:tr>').size() == r1.split('</w:tr>').size();

    Map<String, Object> trueData = new Map<String, Object>{ 'Status' => 'open', 'Name' => 'Acme' };
    String r2 = DocGenService.processXmlForTest(tableXml, trueData);
    Boolean trueHasName = r2.contains('Acme');
    Boolean trueHasAfter = r2.contains('after-row');

    if (falseHasFirstRow && falseHasAfter && falseBalanced && trueHasName && trueHasAfter) {
        pass++;
        System.debug('IF-IN-ROW (issue #53): PASS');
    } else {
        fail++;
        System.debug(
            'IF-IN-ROW (issue #53): FAIL — falseHasFirstRow=' +
                falseHasFirstRow +
                ' falseHasAfter=' +
                falseHasAfter +
                ' falseBalanced=' +
                falseBalanced +
                ' trueHasName=' +
                trueHasName +
                ' trueHasAfter=' +
                trueHasAfter +
                ' r1=' +
                r1 +
                ' r2=' +
                r2
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('IF-IN-ROW (issue #53): FAIL — ' + e.getMessage());
}

// ===== IF double-quoted literal (issue #69) =====
// Pre-fix: only single quotes were stripped from the value side, so the
// double-quoted form compared `Won` against `"Won"` (10 chars) and never
// matched. Asserts symmetry with single-quote form for both = and !=.
try {
    String t =
        '<w:t>{#IF S = "Won"}M{/IF}|{#IF S != "Won"}N{/IF}|' + '{#IF S = \'Won\'}m{/IF}|{#IF S != \'Won\'}n{/IF}</w:t>';
    String hit = DocGenService.processXmlForTest(t, new Map<String, Object>{ 'S' => 'Won' });
    String miss = DocGenService.processXmlForTest(t, new Map<String, Object>{ 'S' => 'Lost' });
    if (hit == '<w:t>M||m|</w:t>' && miss == '<w:t>|N||n</w:t>') {
        pass++;
        System.debug('IF DBLQUOTE LITERAL (#69): PASS');
    } else {
        fail++;
        System.debug('IF DBLQUOTE LITERAL (#69): FAIL hit=' + hit + ' miss=' + miss);
    }
} catch (Exception e) {
    fail++;
    System.debug('IF DBLQUOTE LITERAL (#69): FAIL — ' + e.getMessage());
}

// ===== Nested IF/else ownership across outer section (issue #68) =====
// Pre-fix: outer section's split-on-{:else} grabbed the inner IF's
// {:else} as its own split point; recursing into trueBranch (now with
// an unclosed {#IF} opener) threw "Malformed loop tag". Post-fix:
// findElseAtDepthZero ignores nested {:else}s. Verifies all three
// section types: regular loop, regular loop with its own outer
// {:else}, and inverse {^X}.
try {
    // Case 1 — Joe's repro: non-IF loop with nested IF/else, multi-iter.
    String t1 = '<w:t>{#Steps}{#IF S = \'Started\'}A{:else}B{/IF}|{/Steps}</w:t>';
    Map<String, Object> d1 = new Map<String, Object>{
        'Steps' => new List<Object>{
            new Map<String, Object>{ 'S' => 'Started' },
            new Map<String, Object>{ 'S' => 'Pending' },
            new Map<String, Object>{ 'S' => 'Started' }
        }
    };
    String r1 = DocGenService.processXmlForTest(t1, d1);

    // Case 2 — outer {:else} must still be found AFTER a nested IF/else.
    // The depth-aware scan must walk past inner {#IF}, {:else}, {/IF}
    // and identify the OUTER {:else} that comes after {/IF}.
    String t2 = '<w:t>{#Recs}{#IF X = \'a\'}Y{:else}N{/IF}{:else}EMPTY{/Recs}</w:t>';
    String r2empty = DocGenService.processXmlForTest(t2, new Map<String, Object>{ 'Recs' => new List<Object>() });
    String r2match = DocGenService.processXmlForTest(
        t2,
        new Map<String, Object>{ 'Recs' => new List<Object>{ new Map<String, Object>{ 'X' => 'a' } } }
    );

    // Case 3 — inverse section {^X} with nested IF/else.
    String t3 = '<w:t>{^Empty}{#IF X = \'a\'}YES{:else}NO{/IF}{/Empty}</w:t>';
    String r3 = DocGenService.processXmlForTest(t3, new Map<String, Object>{ 'Empty' => null, 'X' => 'a' });

    Boolean ok1 = (r1 == '<w:t>A|B|A|</w:t>');
    Boolean ok2 = (r2empty == '<w:t>EMPTY</w:t>' && r2match == '<w:t>Y</w:t>');
    Boolean ok3 = (r3 == '<w:t>YES</w:t>');
    if (ok1 && ok2 && ok3) {
        pass++;
        System.debug('NESTED IF/ELSE OWNERSHIP (#68): PASS');
    } else {
        fail++;
        System.debug(
            'NESTED IF/ELSE OWNERSHIP (#68): FAIL ok1=' +
                ok1 +
                ' ok2=' +
                ok2 +
                ' ok3=' +
                ok3 +
                ' r1=' +
                r1 +
                ' r2empty=' +
                r2empty +
                ' r2match=' +
                r2match +
                ' r3=' +
                r3
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('NESTED IF/ELSE OWNERSHIP (#68): FAIL — ' + e.getMessage());
}

// ===== Issue #97 — French locale must NOT mirror German =====
// French uses SPACE-as-thousands and COMMA-as-decimal.
// Bug was: fr_FR was bucketed with de_DE in the dot-as-thousands branch
// of getLocaleGroupSep, producing identical output for both locales.
try {
    Map<String, Object> ad = new Map<String, Object>{ 'Qty' => 1234567 };
    String fr = DocGenService.processXmlForTest('<w:t>{Qty:number:fr_FR}</w:t>', ad);
    String de = DocGenService.processXmlForTest('<w:t>{Qty:number:de_DE}</w:t>', ad);
    if (fr.contains('1 234 567') && de.contains('1.234.567') && fr != de) {
        pass++;
        System.debug('NUMBER fr_FR vs de_DE (#97): PASS');
    } else {
        fail++;
        System.debug('NUMBER fr_FR vs de_DE (#97): FAIL — fr=' + fr + ' de=' + de);
    }
} catch (Exception e) {
    fail++;
    System.debug('NUMBER fr_FR vs de_DE (#97): FAIL — ' + e.getMessage());
}

try {
    String r97 = DocGenService.processXmlForTest(
        '<w:t>{Amt:currency:EUR:fr_FR}</w:t>',
        new Map<String, Object>{ 'Amt' => 500000 }
    );
    if (r97.contains('500 000,00') && r97.contains('€')) {
        pass++;
        System.debug('CURRENCY EUR fr_FR (#97): PASS');
    } else {
        fail++;
        System.debug('CURRENCY EUR fr_FR (#97): FAIL — ' + r97);
    }
} catch (Exception e) {
    fail++;
    System.debug('CURRENCY EUR fr_FR (#97): FAIL — ' + e.getMessage());
}

// ===== Issue #112 — sibling sections in one numbered/bulleted paragraph =====
// Bug was: list-paragraph container expansion grabbed the whole <w:p w:numPr>,
// so the first section's trueBranch consumed everything in the paragraph,
// dropping every sibling section + label that followed `{/}`. Ben's checkbox
// templates (`{#A}☒{:else}☐{/A} Label {#B}☒{:else}☐{/B} Label …` inside one
// bulleted line) rendered only the first checkbox. Fix adds a sibling guard
// so paragraph expansion only fires when this section is the sole tagged
// region in the paragraph.
try {
    String numPrXml =
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>' +
        '<w:r><w:t>{#A}YA{:else}NA{/A} la {#B}YB{:else}NB{/B} lb {#C}YC{:else}NC{/C} lc</w:t></w:r>' +
        '</w:p>';
    String all3 = DocGenService.processXmlForTest(
        numPrXml,
        new Map<String, Object>{ 'A' => 'x', 'B' => 'y', 'C' => 'z' }
    );
    String mix = DocGenService.processXmlForTest(
        numPrXml,
        new Map<String, Object>{ 'A' => 'x', 'B' => null, 'C' => 'z' }
    );
    String none = DocGenService.processXmlForTest(
        numPrXml,
        new Map<String, Object>{ 'A' => null, 'B' => null, 'C' => null }
    );
    Boolean ok =
        all3.contains('YA') &&
        all3.contains('la') &&
        all3.contains('YB') &&
        all3.contains('lb') &&
        all3.contains('YC') &&
        all3.contains('lc') &&
        mix.contains('YA') &&
        mix.contains('NB') &&
        mix.contains('YC') &&
        mix.contains('la') &&
        mix.contains('lb') &&
        mix.contains('lc') &&
        none.contains('NA') &&
        none.contains('NB') &&
        none.contains('NC') &&
        none.contains('la') &&
        none.contains('lb') &&
        none.contains('lc');
    if (ok) {
        pass++;
        System.debug('SIBLING SECTIONS IN numPr PARAGRAPH (#112): PASS');
    } else {
        fail++;
        System.debug(
            'SIBLING SECTIONS IN numPr PARAGRAPH (#112): FAIL — all=' + all3 + ' mix=' + mix + ' none=' + none
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('SIBLING SECTIONS IN numPr PARAGRAPH (#112): FAIL — ' + e.getMessage());
}

// ===== Shared Assets {%asset:<key>} (#185) =====
// Positive resolution + version-bump are covered in DocGenAssetTest; here we
// pin the parser-level contract: an unknown {%asset:<key>} degrades to the
// inline placeholder via processXmlForTest, never a hard mid-generation failure.
try {
    // Anonymous Apex starts a fresh transaction, so the per-transaction
    // assetCvCache static is already null — no reset needed (and it is a
    // @TestVisible private member, inaccessible from anonymous Apex anyway).
    r = DocGenService.processXmlForTest('A {%asset:nope-185} B', new Map<String, Object>());
    if (r.contains('[missing asset: nope-185]') && !r.contains('{%asset:')) {
        pass++;
        System.debug('SHARED ASSET TAG (#185): PASS');
    } else {
        fail++;
        System.debug('SHARED ASSET TAG (#185): FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('SHARED ASSET TAG (#185): FAIL — ' + e.getMessage());
}

System.debug('========================================');
System.debug(
    'E2E-07-SYNTAX3 — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
