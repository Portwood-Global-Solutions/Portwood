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
        System.assertNotEquals(null, findRule(findings, 'display:flex / display:grid'), 'flex must be reported');
        System.assertNotEquals(null, findRule(findings, 'Gradient'), 'gradients must be reported');
        System.assertNotEquals(null, findRule(findings, 'calc()'), 'calc() must be reported');
        for (DocGenAiHtmlValidator.Finding f : findings) {
            System.assertEquals('warning', f.action, 'lint never repairs or removes — every finding is a warning');
            System.assert(
                f.detail.contains('your file was not modified'),
                'reworded detail must say the file was not modified: ' + f.detail
            );
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

    // =========================================================================
    // {~Label} root-anchor tag (#439) — Label is a free-form match key, not a
    // relationship name, so it must not be existence-checked the way {#Label}
    // loop relationships are, while still being pairing-checked like any
    // {#…}/{^…} section.
    // =========================================================================

    @isTest
    static void rootAnchorTagIsNotFlaggedAsAnUnknownLoopRelationship() {
        // Opportunities is a real child relationship of Account (unlike
        // OpportunityLineItems, which is a child of Opportunity, not Account) —
        // the nested loop must resolve cleanly so this test isolates the
        // root-anchor behavior, not an unrelated schema mismatch.
        String html = '<html><body><table><tr><td>{~Offices}{#Opportunities}{Amount}{/Opportunities}{/Offices}</td></tr></table></body></html>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(html, accountTemplate('Name'));
        System.assertEquals(
            null,
            findRule(findings, 'Loop relationship not found'),
            '{~Offices} is a root-anchor label, not a relationship name — must not be existence-checked: ' + findings
        );
    }

    @isTest
    static void unclosedRootAnchorTagStillReportsUnclosedLoop() {
        // {~Label} is section-shaped like {#…}/{^…} and must still be pairing-
        // checked — an unclosed one fails generation with the same "Malformed
        // loop tag" error, so it must produce the SAME warning, not a silently
        // skipped one.
        List<DocGenAiHtmlValidator.Finding> findings = DocGenTemplateLinter.lint(
            '<p>{~Offices}</p><p>{Name}</p>',
            accountTemplate('Name')
        );
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Unclosed loop tag');
        System.assertNotEquals(null, f, 'an unclosed {~Label} must still be flagged, same as {#…}/{^…}');
        System.assert(f.detail.contains('{~Offices}'), 'the warning must name the tag: ' + f.detail);
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
}
