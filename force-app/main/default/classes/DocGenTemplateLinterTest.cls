/**
 * Coverage for DocGenTemplateLinter — the upload-time fidelity report (issue #272).
 *
 * The renderer-compatibility findings come from DocGenAiHtmlValidator's MEASURED
 * rule set (see that class's tests for the per-rule proof); what is asserted here
 * is the lint layer on top: findings are reworded so nothing implies the file was
 * modified, the input bytes are never touched, and the checks the validator does
 * not have (@page conflicts, tbody selectors, loop pairing, split runs, field
 * resolution against Base_Object_API__c / Query_Config__c) each fire — and each
 * stays quiet when it should.
 */
@isTest
private class DocGenTemplateLinterTest {
    private static DocGenAiHtmlValidator.Finding findRule(List<DocGenAiHtmlValidator.Finding> findings, String rule) {
        for (DocGenAiHtmlValidator.Finding f : findings) {
            if (f.rule == rule) {
                return f;
            }
        }
        return null;
    }

    /** A template record for lint — in-memory is enough, lint never queries it. */
    private static DocGen_Template__c accountTemplate(String queryConfig) {
        return new DocGen_Template__c(
            Name = 'Lint Tpl',
            Type__c = 'HTML',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF',
            Query_Config__c = queryConfig
        );
    }

    @isTest
    static void cleanCss21TemplateProducesZeroFindings() {
        String html =
            '<html><head><style>body{font-family:Helvetica,Arial,sans-serif;font-size:11pt;color:#333;}' +
            'table{width:100%;border-collapse:collapse;}td{padding:4pt;border:0.5pt solid #ccc;}' +
            'tr:nth-child(even){background:#f5f7fa;}</style></head><body>' +
            '<table><tr><td>{Name}</td><td>{Industry}</td></tr></table></body></html>';
        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            html,
            accountTemplate('Name, Industry')
        );
        Test.stopTest();
        System.assertEquals(0, findings.size(), 'A CSS 2.1-clean template must report nothing: ' + findings);
    }

    @isTest
    static void modernCssWarnsAndTheInputIsNotMutated() {
        String html =
            '<style>.h{display:flex;gap:8pt;} .b{background:linear-gradient(90deg,#0b3d91,#63b3ed);}' +
            '.w{width:calc(100% - 40pt);}</style><div class="h">x</div>';
        String before = html;
        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, accountTemplate(null));
        Test.stopTest();

        System.assertEquals(before, html, 'lint must never touch the author\'s bytes');
        // CHANGED in #318: flex, gradients and calc() share one cause and one
        // remedy, so they are reported as ONE finding naming all three rather
        // than three accusations about the same stylesheet.
        DocGenAiHtmlValidator.Finding css = findRule(findings, 'Modern CSS the PDF engine ignores');
        System.assertNotEquals(null, css, 'the CSS-compat family must still be reported. Got: ' + findings);
        System.assert(css.detail.contains('display:flex / display:grid'), 'flex must be named: ' + css.detail);
        System.assert(css.detail.contains('Gradient'), 'gradients must be named: ' + css.detail);
        System.assert(css.detail.contains('calc()'), 'calc() must be named: ' + css.detail);
        for (DocGenAiHtmlValidator.Finding f : findings) {
            System.assertEquals('warning', f.action, 'lint never repairs or removes — every finding is a warning');
        }
    }

    @isTest
    static void pageRuleConflictsWithExplicitTemplatePageSetup() {
        String html = '<html><head><style>@page{size:Letter portrait;margin:1in;}</style></head><body><p>x</p></body></html>';

        DocGen_Template__c overridden = accountTemplate(null);
        overridden.Page_Margins__c = 'Wide';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, overridden);
        DocGenAiHtmlValidator.Finding f = findRule(findings, '@page conflicts with template page setup');
        System.assertNotEquals(null, f, 'an explicit margins preset overrides the author\'s @page — say so');
        System.assert(f.detail.contains('Wide'), 'the warning must name the competing setting: ' + f.detail);
    }

    @isTest
    static void pageRuleAloneWithUntouchedFieldsIsNotAConflict() {
        // Letter/Portrait/Default cannot be told apart from "never touched" (#243),
        // so an @page rule with only defaults on the record is the author being in
        // charge — no warning.
        String html = '<html><head><style>@page{size:A4 landscape;margin:2cm;}</style></head><body><p>x</p></body></html>';
        DocGen_Template__c tpl = accountTemplate(null);
        tpl.Page_Margins__c = 'Default';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, tpl);
        System.assertEquals(null, findRule(findings, '@page conflicts with template page setup'));
    }

    @isTest
    static void tbodySelectorIsFlagged() {
        String html =
            '<html><head><style>table > tbody > tr > td{border:0.5pt solid #ccc;}</style></head>' +
            '<body><table><tr><td>x</td></tr></table></body></html>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, accountTemplate(null));
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'tbody in a CSS selector');
        System.assertNotEquals(null, f, 'the engine does not match tbody — the selector silently selects nothing');
        System.assertEquals(1, f.occurrences);
    }

    @isTest
    static void tbodyInMarkupWithoutASelectorIsFine() {
        // <tbody> in the markup is harmless — only selectors are the trap.
        String html = '<html><body><table><tbody><tr><td>x</td></tr></tbody></table></body></html>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, accountTemplate(null));
        System.assertEquals(null, findRule(findings, 'tbody in a CSS selector'));
    }

    @isTest
    static void unclosedLoopTagIsReported() {
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            '<p>{#Lines}</p><p>{Name}</p>',
            accountTemplate('Name')
        );
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Unclosed loop tag');
        System.assertNotEquals(null, f, 'generation would fail with "Malformed loop tag" — warn at save time');
        System.assert(f.detail.contains('{#Lines}'), 'the warning must name the tag: ' + f.detail);
    }

    @isTest
    static void strayClosingTagIsReported() {
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            '<p>{Name}</p><p>{/Lines}</p>',
            accountTemplate('Name')
        );
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Unmatched closing tag');
        System.assertNotEquals(null, f, 'a closer with no opener must be flagged');
        System.assert(f.detail.contains('{/Lines}'), 'the warning must name the tag: ' + f.detail);
    }

    @isTest
    static void balancedLoopWithElseIsClean() {
        String html = '<html><body><table><tr><td>{#OpportunityLineItems}{Name}{:else}none{/OpportunityLineItems}</td></tr></table></body></html>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, accountTemplate('Name'));
        System.assertEquals(null, findRule(findings, 'Unclosed loop tag'));
        System.assertEquals(null, findRule(findings, 'Unmatched closing tag'));
    }

    @isTest
    static void splitRunTagIsReported() {
        // Bold half a merge tag in the editor and it arrives like this.
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            '<p>{Na<b>me}</b></p>',
            accountTemplate('Name')
        );
        System.assertNotEquals(null, findRule(findings, 'Merge tag split by formatting'), 'formatting split the tag');
    }

    @isTest
    static void unknownFieldIsReported() {
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            '<p>{NotAField__c}</p>',
            accountTemplate('Name')
        );
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Merge tag does not resolve');
        System.assertNotEquals(null, f, 'a field that does not exist on Account merges blank — warn');
        System.assert(f.detail.contains('NotAField__c'), 'the warning must name the field: ' + f.detail);
        System.assert(f.detail.contains('Account'), 'and the object: ' + f.detail);
    }

    @isTest
    static void validBuiltInAndSpecialTagsAreNotFieldWarnings() {
        String html =
            '<p>{Name}</p><p>{Parent.Name}</p><p>{Today}</p>' +
            '<p>{SUM:Lines.Amount}</p><p>{Chart:Lines:Amount:bar}</p>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            html,
            accountTemplate('Name, Parent.Name')
        );
        System.assertEquals(
            null,
            findRule(findings, 'Merge tag does not resolve'),
            'valid fields, built-ins, aggregates and chart tags must not be flagged: ' + findings
        );
        System.assertEquals(null, findRule(findings, 'Field not in Query Config'));
    }

    @isTest
    static void fieldMissingFromQueryConfigIsReported() {
        // Industry exists on Account but the template only queries Name — the tag
        // merges blank and nothing at generation time says why.
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            '<p>{Name}</p><p>{Industry}</p>',
            accountTemplate('Name')
        );
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Field not in Query Config');
        System.assertNotEquals(null, f);
        System.assert(f.detail.contains('Industry'), 'the warning must name the field: ' + f.detail);
    }

    @isTest
    static void fieldInsideALoopBodyIsNotValidatedAgainstTheBaseObject() {
        // {Name} inside {#OpportunityLineItems} is the CHILD's Name — validating it
        // against Account would be wrong either way, so it is skipped.
        String html = '<html><body><table><tr><td>{#OpportunityLineItems}{Widget_Name__c}{/OpportunityLineItems}</td></tr></table></body></html>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, accountTemplate('Name'));
        System.assertEquals(
            null,
            findRule(findings, 'Merge tag does not resolve'),
            'loop-body fields belong to the child object: ' + findings
        );
    }

    @isTest
    static void unknownLoopRelationshipIsReported() {
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            '<p>{#NotARel}</p><p>{Name}</p><p>{/NotARel}</p>',
            accountTemplate('Name')
        );
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Loop relationship not found');
        System.assertNotEquals(null, f, 'a loop on a relationship the base object does not have renders nothing');
        System.assert(f.detail.contains('NotARel'), 'the warning must name the relationship: ' + f.detail);
        System.assert(f.detail.contains('Account'), 'and the object: ' + f.detail);
    }

    @isTest
    static void aliasedLoopFromQueryConfigIsAccepted() {
        // A V3 Query Config node can rename its relationship — templates loop on
        // the ALIAS, so describe alone must not condemn it.
        DocGen_Template__c tpl = accountTemplate(
            '{"nodes":[{"object":"OpportunityLineItem","relationshipName":"OpportunityLineItems","lookupField":"OpportunityId","alias":"Lines","fields":["UnitPrice"]}]}'
        );
        String html = '<html><body><table><tr><td>{#Lines}{UnitPrice}{/Lines}</td></tr></table></body></html>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, tpl);
        System.assertEquals(
            null,
            findRule(findings, 'Loop relationship not found'),
            'the alias is defined by the Query Config: ' + findings
        );
    }

    @isTest
    static void lintNeverThrowsOnGarbage() {
        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> blank = DocGenTemplateLinter.lint(null, null);
        List<DocGenAiHtmlValidator.Finding> garbage = DocGenTemplateLinter.lint('{{{ not html at all', null);
        List<DocGenAiHtmlValidator.Finding> noTemplate = DocGenTemplateLinter.lint(
            '<p>{Name}</p>',
            new DocGen_Template__c()
        );
        Test.stopTest();
        System.assertEquals(0, blank.size(), 'blank input is an empty report, not an exception');
        System.assertNotEquals(null, garbage);
        System.assertNotEquals(null, noTemplate);
    }

    // -----------------------------------------------------------------------
    // The hook: every HTML body write funnels through saveHtmlTemplateBody, so
    // the warnings ride back with the save result.
    // -----------------------------------------------------------------------

    private static DocGen_Template__c newHtmlTemplate() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Lint Hook ' + System.now().getTime(),
            Base_Object_API__c = 'Account',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);
        return tpl;
    }

    @isTest
    static void saveReturnsTheWarningsKeys() {
        DocGen_Template__c tpl = newHtmlTemplate();
        Test.startTest();
        Map<String, Object> res = DocGenController.saveHtmlTemplateBody(
            tpl.Id,
            'body.html',
            '<html><body><p>Hello {Name}</p></body></html>'
        );
        Test.stopTest();

        System.assert(res.containsKey('warnings'), 'the save result must carry the fidelity report');
        System.assert(res.containsKey('warningCount'), 'and its count');
        List<DocGenAiHtmlValidator.Finding> warnings = (List<DocGenAiHtmlValidator.Finding>) res.get('warnings');
        System.assertEquals(0, warnings.size(), 'a clean body warns about nothing: ' + warnings);
        System.assertEquals(0, (Integer) res.get('warningCount'));
    }

    @isTest
    static void saveReportsWarningsWithoutBlocking() {
        DocGen_Template__c tpl = newHtmlTemplate();
        Test.startTest();
        Map<String, Object> res = DocGenController.saveHtmlTemplateBody(
            tpl.Id,
            'body.html',
            '<html><head><style>.h{display:flex;}</style></head><body><p>Hello {Name}</p></body></html>'
        );
        Test.stopTest();

        System.assertNotEquals(null, res.get('contentVersionId'), 'warnings never block the save');
        List<DocGenAiHtmlValidator.Finding> warnings = (List<DocGenAiHtmlValidator.Finding>) res.get('warnings');
        System.assert(!warnings.isEmpty(), 'flex in the body must produce a warning');
        System.assertEquals(warnings.size(), (Integer) res.get('warningCount'), 'count must match the list');
    }

    @isTest
    static void saveAndPublishPropagatesTheWarnings() {
        DocGen_Template__c tpl = newHtmlTemplate();
        Test.startTest();
        Map<String, Object> res = DocGenController.saveAndPublishHtmlBody(
            tpl.Id,
            'body.html',
            '<html><head><style>.h{display:flex;}</style></head><body><p>Hello {Name}</p></body></html>',
            false
        );
        Test.stopTest();

        System.assert(res.containsKey('warnings'), 'the canvas path returns the same report');
        System.assert(
            !((List<DocGenAiHtmlValidator.Finding>) res.get('warnings')).isEmpty(),
            'warnings must survive the publish wrapper'
        );
        System.assertEquals(
            ((List<DocGenAiHtmlValidator.Finding>) res.get('warnings')).size(),
            (Integer) res.get('warningCount')
        );
    }

    // -------------------------------------------------------------------------
    // Canvas-authored bodies must not get a fidelity report.
    // -------------------------------------------------------------------------

    @isTest
    static void trailingNewlineIsNotAMarkdownFence() {
        // The fence rule snapshotted the html BEFORE trim(), so anything with a
        // leading or trailing newline reported a ``` fence it never had. Canvas
        // output always ends with one; so does most hand-authored HTML.
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            '\n<html><body><p>{Name}</p></body></html>\n',
            accountTemplate(null)
        );
        for (DocGenAiHtmlValidator.Finding f : findings) {
            System.assertNotEquals('Markdown code fence', f.rule, 'A trailing newline is not a code fence.');
        }
    }

    @isTest
    static void realMarkdownFenceIsStillReported() {
        // Control: the rule must keep catching an actual fence, or the fix above
        // would have quietly disabled it.
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            '```html\n<html><body><p>{Name}</p></body></html>\n```',
            accountTemplate(null)
        );
        Boolean found = false;
        for (DocGenAiHtmlValidator.Finding f : findings) {
            if (f.rule == 'Markdown code fence') {
                found = true;
            }
        }
        System.assert(found, 'An actual ``` fence must still be reported.');
    }

    @isTest
    static void canvasAuthoredBodySkipsTheFidelityReport() {
        // A canvas body legitimately uses position:absolute for pinned boxes and
        // already wraps its row loop in <tbody>. Reporting those tells the author
        // their own designer produced something questionable, about markup they
        // never wrote. saveHtmlTemplateBody skips the report when it sees the
        // canvas marker.
        DocGen_Template__c tpl = accountTemplate('Name');
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);

        String canvasBody =
            '<!DOCTYPE html><html><head><style>' +
            '.dg-artboard { position: relative; width: 8.5in; }' +
            '.dg-pin { position: absolute; }' +
            '</style></head><body><div class="dg-artboard">' +
            '<div class="dg-pin" data-dg-x="1" data-dg-y="1">{Name}</div>' +
            '</div></body></html>';

        Test.startTest();
        Map<String, Object> res = DocGenController.saveHtmlTemplateBody(tpl.Id, 'canvas.html', canvasBody);
        Test.stopTest();

        System.assertEquals(0, (Integer) res.get('warningCount'), 'Canvas bodies get no fidelity report.');
    }

    @isTest
    static void handAuthoredBodyStillGetsTheFidelityReport() {
        // Control for the skip: an imported file with the same construct must
        // still be reported, or the exemption would have disabled the feature.
        DocGen_Template__c tpl = accountTemplate('Name');
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);

        String handAuthored =
            '<html><head><style>.hero { position: absolute; top: 0; }</style></head>' +
            '<body><div class="hero">{Name}</div></body></html>';

        Test.startTest();
        Map<String, Object> res = DocGenController.saveHtmlTemplateBody(tpl.Id, 'hand.html', handAuthored);
        Test.stopTest();

        System.assert((Integer) res.get('warningCount') > 0, 'Hand-authored HTML must still get the fidelity report.');
    }

    // -----------------------------------------------------------------------
    // Oversized bodies. `System.LimitException: Regex too complicated` is NOT
    // caught by `catch (Exception)`, so before the size gate a large body took
    // the whole save down with it — the v3.55/v3.56 regression. These assert the
    // gate itself, because the failure it prevents cannot be asserted directly:
    // an uncatchable exception fails the test method rather than being caught.
    // -----------------------------------------------------------------------

    /** A CSS-dense body of a requested length, shaped like the reported templates. */
    private static String bodyOfLength(Integer target) {
        // display:flex is the signal: #318 suppresses font-weight, which this
        // fixture used to rely on, so it needs a trait that is still reported.
        String cell = '<td style="border:1px solid #ccc;padding:4pt 6pt;font-size:9pt;display:flex">Item</td>';
        String block = '<table style="width:100%;border-collapse:collapse"><tr>' + cell + cell + cell + '</tr></table>';
        String html = '<html><head><style>body{font-family:Arial;font-size:10pt}</style></head><body>';
        while (html.length() < target) {
            html += block;
        }
        return html;
    }

    @isTest
    static void oversizedBodySkipsTheReportInsteadOfThrowing() {
        DocGenTemplateLinter.maxLintChars = 5000;
        String big = bodyOfLength(20000);

        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(big, accountTemplate('Name'));
        Test.stopTest();

        System.assertEquals(1, findings.size(), 'An oversized body reports exactly one advisory finding.');
        System.assertEquals('Template too large to check', findings[0].rule, 'The gate must name itself.');
        System.assert(
            findings[0].detail.contains('saved normally'),
            'The notice must tell the author their template still saved: ' + findings[0].detail
        );
        System.assertEquals(
            null,
            findRule(findings, 'Modern CSS the PDF engine ignores'),
            'No renderer-compatibility check may run above the gate — that is what throws.'
        );
    }

    @isTest
    static void bodyUnderTheGateIsStillFullyChecked() {
        // Control for the gate: the same markup below the threshold must still
        // be reported, or the fix would have silently disabled the feature.
        DocGenTemplateLinter.maxLintChars = 100000;

        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            bodyOfLength(20000),
            accountTemplate('Name')
        );
        Test.stopTest();

        System.assertEquals(null, findRule(findings, 'Template too large to check'), 'The gate must not fire here.');
        System.assertNotEquals(
            null,
            findRule(findings, 'Modern CSS the PDF engine ignores'),
            'Under the gate the checks still run.'
        );
    }

    @isTest
    static void reportModeNeverClaimsTheFileWasRepaired() {
        // The validator is the Agentforce REPAIR pass, so its details describe
        // edits it made. Reused verbatim here they contradicted themselves —
        // "your file was not modified. Mapped 600 and above to bold" — which is
        // what made the report read as untrustworthy.
        String html =
            '<html><head><style>.a{font-weight:600}.b{background:rgba(0,0,0,.5)}' +
            '.c{background:linear-gradient(#fff,#000)}</style></head><body>{Name}</body></html>';

        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, accountTemplate('Name'));
        Test.stopTest();

        System.assert(!findings.isEmpty(), 'This body trips several renderer-compatibility rules.');
        for (DocGenAiHtmlValidator.Finding f : findings) {
            String d = f.detail.toLowerCase();
            System.assert(
                !d.contains('mapped ') &&
                    !d.contains('composited the') &&
                    !d.contains('replaced each') &&
                    !d.contains('removed the font') &&
                    !d.contains('substituted the'),
                'Report-mode detail must not claim an edit was made: [' + f.rule + '] ' + f.detail
            );
        }
    }

    // ─── #318: the report has to be worth reading ────────────────────────────
    //
    // Everything was a separate warning, so a realistic modern stylesheet — a
    // :root block, a flex header, an rgba() tint, a gradient — produced eight
    // findings before the author had done anything unusual. That reads as "you
    // are making errors constantly", and a report that reads that way stops
    // being read at all.
    //
    // Measured on exactly that stylesheet: 10 raw findings -> 2 lines.

    private static String modernStylesheet() {
        return '<html><head><style>' +
            ':root{--brand:#0b3d2e;--gap:8px}' +
            '.hdr{display:flex;gap:var(--gap);align-items:center}' +
            '.title{font-weight:600;color:var(--brand)}' +
            '.card{background:rgba(11,61,46,0.08);border-radius:4px}' +
            '.hero{background:linear-gradient(90deg,#0b3d2e,#63b3ed)}' +
            '.w{width:calc(100% - 40pt)}' +
            '@media print{.card{padding:0}}' +
            '</style></head><body><div class="hdr"><span class="title">{Name}</span></div></body></html>';
    }

    @isTest
    static void aModernStylesheetProducesOneLineNotEight() {
        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            modernStylesheet(),
            accountTemplate('Name')
        );
        Test.stopTest();

        System.assert(findings.size() <= 2, 'A modern stylesheet must not produce a wall. Got: ' + findings);
        DocGenAiHtmlValidator.Finding css = findRule(findings, 'Modern CSS the PDF engine ignores');
        System.assertNotEquals(null, css, 'the grouped CSS finding must be present');
        // It still has to say WHICH properties, or the author cannot act on it.
        for (String named : new List<String>{ 'CSS variable', 'rgba() colour', 'Gradient', 'calc()' }) {
            System.assert(css.detail.contains(named), named + ' must be named in the detail: ' + css.detail);
        }
    }

    @isTest
    static void inertRulesAreNotReportedAtAll() {
        // Each of these describes something the reader could never see. They
        // fire on essentially every modern stylesheet, which is what made the
        // panel feel like a scolding.
        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            modernStylesheet(),
            accountTemplate('Name')
        );
        Test.stopTest();

        for (
            String gone : new List<String>{
                'Custom property declaration',
                'Numeric font-weight',
                'Flex/grid alignment properties'
            }
        ) {
            System.assertEquals(null, findRule(findings, gone), gone + ' is inert and must not be reported');
        }
    }

    @isTest
    static void aCleanTemplateSaysNothingAtAll() {
        String clean =
            '<html><head><style>body{font-family:Arial;font-size:10pt}' +
            'table{border-collapse:collapse}td{border:1px solid #ccc;padding:4pt}</style></head>' +
            '<body><table><tr><td>{Name}</td></tr></table></body></html>';
        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(clean, accountTemplate('Name'));
        Test.stopTest();
        System.assertEquals(0, findings.size(), 'A CSS 2.1-clean template must be silent. Got: ' + findings);
    }

    @isTest
    static void thingsThatActuallyBreakAreStillLoud() {
        // The whole point of quietening the inert rules is that what is LEFT
        // gets believed. Each of these changes what the reader sees, or fails
        // the merge outright, and each keeps its own line and its own remedy.
        Map<String, String> cases = new Map<String, String>{
            'Unclosed loop tag' => '<p>{#Lines}</p><p>{Name}</p>',
            'Unmatched closing tag' => '<p>{Name}</p><p>{/Lines}</p>',
            'Unbalanced merge braces' => '<p>{Name</p>',
            'Dingbat font' => '<style>.x{font-family:Wingdings}</style><p>l</p>',
            '<svg>' => '<p><svg width="10"><rect/></svg></p>',
            'External stylesheet' => '<link rel="stylesheet" href="x.css"><p>{Name}</p>',
            'Markdown code fence' => '```html\n<p>{Name}</p>\n```'
        };
        Test.startTest();
        for (String rule : cases.keySet()) {
            List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
                cases.get(rule),
                accountTemplate('Name')
            );
            System.assertNotEquals(null, findRule(findings, rule), rule + ' must still be reported. Got: ' + findings);
        }
        Test.stopTest();
    }

    @isTest
    static void theListIsCappedRatherThanEndless() {
        DocGenTemplateLinter.maxReportedFindings = 2;
        // Several DISTINCT remedies, so none of them group.
        String html =
            '```html\n<link rel="stylesheet" href="a.css"><style>@import url(b.css);.x{font-family:Wingdings}</style>' +
            '<p><svg/></p><p>{#Lines}</p><p>{/Other}</p>\n```';
        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, accountTemplate('Name'));
        Test.stopTest();

        System.assertEquals(3, findings.size(), 'cap of 2 plus one summary line. Got: ' + findings);
        System.assert(
            findings[findings.size() - 1].rule.endsWith('more not shown'),
            'the last line must say how many were withheld. Got: ' + findings[findings.size() - 1].rule
        );
    }
}
