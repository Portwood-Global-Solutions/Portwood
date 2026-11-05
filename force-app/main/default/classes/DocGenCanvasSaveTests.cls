/**
 * Coverage for DocGenController.saveAndPublishHtmlBody — the single write path behind
 * every canvas save, every HTML import, and every version publish.
 *
 * WHY THIS CLASS EXISTS
 * ---------------------
 * This method shipped in v3.54.0 with no test coverage at all, in a promoted (and
 * therefore frozen) managed package. The risk is not that a save fails loudly — it is
 * the clone-and-activate path failing QUIETLY:
 *
 *   saveAndPublishHtmlBody(newVersion=true) creates a new version and makes it active.
 *   A version carries the whole authoring config — query, base object, page setup,
 *   header/footer, output format — and activateVersion pushes those fields BACK onto
 *   the template. So a new version built with only a body pointer does not merely lose
 *   its own settings: activating it WIPES the customer's query config and page setup.
 *
 * Nothing reports an error when that happens. The save succeeds, the document renders,
 * and the template's configuration is gone. That is the silent-corruption class the
 * triage rubric puts at P0, which is why the assertions here are about what a save must
 * NOT change, not just about what it writes.
 *
 * The second failure mode covered here is version drift. The renderer picks its active
 * version with LIMIT 1 and NO ORDER BY (DocGenTemplateManager.getTemplateFileContent),
 * so a template left with two active versions renders an ARBITRARY one — a save appears
 * to do nothing because the PDF is built from an older body.
 */
@IsTest
private class DocGenCanvasSaveTests {
    // Substantive on every axis hasSubstantiveHtml checks: real text, a table, and a
    // merge tag. A body that fails that check takes a different branch entirely.
    private static final String CANVAS_BODY =
        '<html><head><style>.dg-box{position:absolute}</style></head><body>' +
        '<div class="dg-page"><div class="dg-box" style="left:1in;top:1in;width:6in">' +
        '<h1>{Name}</h1><table><tr><td>{Industry}</td></tr></table>' +
        '</div></div></body></html>';

    private static final String SECOND_BODY = CANVAS_BODY.replace('{Industry}', '{BillingCity}');

    private static DocGen_Template__c newCanvasTemplate() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Canvas Save Coverage',
            Type__c = 'Canvas',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name, Industry, BillingCity',
            Category__c = 'Sales',
            Description__c = 'Template description'
        );
        insert tpl;
        return tpl;
    }

    /**
     * A version with EVERY field the clone is supposed to carry populated, and each with
     * a distinct value — so a clone that drops one, or copies the wrong one, fails
     * loudly rather than passing because two fields happened to match.
     */
    private static DocGen_Template_Version__c newConfiguredVersion(Id tplId, Boolean isActive) {
        DocGen_Template_Version__c v = new DocGen_Template_Version__c(
            Template__c = tplId,
            Is_Active__c = isActive,
            Type__c = 'Canvas',
            Query_Config__c = 'Name, Industry, BillingCity',
            Base_Object_API__c = 'Account',
            Category__c = 'Sales',
            Description__c = 'Version description',
            Output_Format__c = 'PDF',
            Document_Title_Format__c = '{Name} Summary',
            Header_Html__c = '<div>header</div>',
            Footer_Html__c = '<div>footer</div>',
            Page_Size__c = 'Legal',
            Page_Orientation__c = 'Landscape',
            Page_Margins__c = 'Custom',
            Custom_Margins__c = '0.25in 0.5in 0.25in 0.5in',
            Watermark_Image_CV_Id__c = '068000000000000AAA'
        );
        insert v;
        return v;
    }

    // Field TOKENS, not string names: inside a managed package the string form of a
    // field name is namespace-prefixed, and a test that reads back with a bare
    // 'Query_Config__c' passes in the repo and fails in the packaging org.
    private static final Map<Schema.SObjectField, Object> CLONED_FIELDS = new Map<Schema.SObjectField, Object>{
        DocGen_Template_Version__c.Query_Config__c => 'Name, Industry, BillingCity',
        DocGen_Template_Version__c.Base_Object_API__c => 'Account',
        DocGen_Template_Version__c.Category__c => 'Sales',
        DocGen_Template_Version__c.Description__c => 'Version description',
        DocGen_Template_Version__c.Type__c => 'Canvas',
        DocGen_Template_Version__c.Output_Format__c => 'PDF',
        DocGen_Template_Version__c.Document_Title_Format__c => '{Name} Summary',
        DocGen_Template_Version__c.Header_Html__c => '<div>header</div>',
        DocGen_Template_Version__c.Footer_Html__c => '<div>footer</div>',
        DocGen_Template_Version__c.Page_Size__c => 'Legal',
        DocGen_Template_Version__c.Page_Orientation__c => 'Landscape',
        DocGen_Template_Version__c.Page_Margins__c => 'Custom',
        DocGen_Template_Version__c.Custom_Margins__c => '0.25in 0.5in 0.25in 0.5in',
        DocGen_Template_Version__c.Watermark_Image_CV_Id__c => '068000000000000AAA'
    };

    private static DocGen_Template_Version__c reload(Id versionId) {
        return Database.query(
            'SELECT Id, Is_Active__c, Content_Version_Id__c, Template__c, ' +
                String.join(fieldNames(), ', ') +
                ' FROM DocGen_Template_Version__c WHERE Id = :versionId'
        );
    }

    private static List<String> fieldNames() {
        List<String> names = new List<String>();
        for (Schema.SObjectField f : CLONED_FIELDS.keySet()) {
            names.add(f.getDescribe().getName());
        }
        return names;
    }

    // -----------------------------------------------------------------------
    // The P0 path: a save must carry the whole authoring config forward.
    // -----------------------------------------------------------------------
    @IsTest
    static void newVersionClonesEveryAuthoringField() {
        DocGen_Template__c tpl = newCanvasTemplate();
        DocGen_Template_Version__c original = newConfiguredVersion(tpl.Id, true);

        Test.startTest();
        Map<String, Object> res = DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', CANVAS_BODY, true);
        Test.stopTest();

        System.assertEquals(true, res.get('versionCreated'), 'A new version should have been created');
        Id newVersionId = (Id) res.get('versionId');
        System.assertNotEquals(null, newVersionId, 'The new version Id should be returned to the editor');
        System.assertNotEquals(original.Id, newVersionId, 'A new version, not the one being superseded');

        DocGen_Template_Version__c fresh = reload(newVersionId);
        for (Schema.SObjectField f : CLONED_FIELDS.keySet()) {
            System.assertEquals(
                CLONED_FIELDS.get(f),
                fresh.get(f),
                f.getDescribe().getName() + ' must survive the save — activateVersion pushes it back onto the template'
            );
        }

        // The one thing a save IS meant to change.
        System.assertEquals(
            (Id) res.get('contentVersionId'),
            (Id) fresh.Content_Version_Id__c,
            'The new version should point at the body just saved'
        );
        System.assertEquals(true, fresh.Is_Active__c, 'The new version should be the active one');
    }

    /**
     * The damage path end to end. Cloning is not the goal — surviving activateVersion
     * without wiping the template is. This is the assertion that would have caught the
     * original bug, because a version built from scratch clones nothing and activating
     * it nulls the template's query config.
     *
     * Note what is and is not being claimed. activateVersion overwriting the template
     * from the activated version is its DOCUMENTED job, not the bug — the version is
     * the record of authoring intent. The bug is those fields arriving EMPTY because the
     * version that got activated never carried them. So the assertion is that the
     * template ends up holding the version's real values, and explicitly that none of
     * them came back blank: null is the corrupted state, and null is what a
     * built-from-scratch version produces.
     */
    @IsTest
    static void activatingTheSavedVersionLeavesTheTemplateIntact() {
        DocGen_Template__c tpl = newCanvasTemplate();
        DocGen_Template_Version__c source = newConfiguredVersion(tpl.Id, true);

        Test.startTest();
        Map<String, Object> res = DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', CANVAS_BODY, true);
        DocGenController.activateVersion((Id) res.get('versionId'));
        Test.stopTest();

        DocGen_Template__c after = [
            SELECT Query_Config__c, Base_Object_API__c, Category__c, Description__c, Type__c
            FROM DocGen_Template__c
            WHERE Id = :tpl.Id
        ];
        System.assertEquals(
            source.Query_Config__c,
            after.Query_Config__c,
            'Saving a canvas must not wipe the query config — this is the silent-corruption case'
        );
        System.assertEquals(source.Base_Object_API__c, after.Base_Object_API__c, 'Base object must survive a save');
        System.assertEquals(source.Category__c, after.Category__c, 'Category must survive a save');
        System.assertEquals(source.Description__c, after.Description__c, 'Description must survive a save');
        System.assertEquals(source.Type__c, after.Type__c, 'Type must survive a save');

        // Stated separately because it is the actual corruption signature. Comparing
        // against the source version would still pass if BOTH were somehow null.
        System.assert(String.isNotBlank(after.Query_Config__c), 'Query config must not be blanked by a save');
        System.assert(String.isNotBlank(after.Base_Object_API__c), 'Base object must not be blanked by a save');
        System.assert(String.isNotBlank(after.Type__c), 'Type must not be blanked by a save');
    }

    // -----------------------------------------------------------------------
    // Version drift: exactly one version may be active afterwards.
    // -----------------------------------------------------------------------
    @IsTest
    static void saveSweepsEveryPriorActiveVersion() {
        DocGen_Template__c tpl = newCanvasTemplate();
        // A template that has ALREADY drifted into two active versions. The read inside
        // saveAndPublishHtmlBody is LIMIT 1, so deactivating only what it read would
        // leave this template broken — and the renderer picks with no ORDER BY, so which
        // body prints would be arbitrary.
        newConfiguredVersion(tpl.Id, true);
        newConfiguredVersion(tpl.Id, true);

        Test.startTest();
        Map<String, Object> res = DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', CANVAS_BODY, true);
        Test.stopTest();

        List<DocGen_Template_Version__c> active = [
            SELECT Id
            FROM DocGen_Template_Version__c
            WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
        ];
        System.assertEquals(1, active.size(), 'A save must leave exactly one active version, healing prior drift');
        System.assertEquals((Id) res.get('versionId'), active[0].Id, 'And it must be the version just saved');
    }

    // -----------------------------------------------------------------------
    // newVersion = false — repoint in place, do not accumulate versions.
    // -----------------------------------------------------------------------
    @IsTest
    static void saveWithoutNewVersionRepointsTheActiveVersion() {
        DocGen_Template__c tpl = newCanvasTemplate();
        DocGen_Template_Version__c original = newConfiguredVersion(tpl.Id, true);

        Test.startTest();
        Map<String, Object> res = DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', CANVAS_BODY, false);
        Test.stopTest();

        System.assertEquals(true, res.get('versionUpdated'), 'The existing version should have been updated');
        System.assertEquals(null, res.get('versionCreated'), 'No new version should be reported');
        System.assertEquals(
            1,
            [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tpl.Id],
            'Repointing must not create a second version'
        );

        DocGen_Template_Version__c after = reload(original.Id);
        System.assertEquals(
            (Id) res.get('contentVersionId'),
            (Id) after.Content_Version_Id__c,
            'The active version should now point at the new body'
        );
        System.assertEquals('Legal', after.Page_Size__c, 'Repointing must not disturb the rest of the config');
    }

    // -----------------------------------------------------------------------
    // Templates with no active version — created outside the wizard.
    // -----------------------------------------------------------------------
    @IsTest
    static void saveCreatesAVersionWhenTheTemplateHasNone() {
        DocGen_Template__c tpl = newCanvasTemplate();

        Test.startTest();
        Map<String, Object> res = DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', CANVAS_BODY, false);
        Test.stopTest();

        System.assertEquals(
            true,
            res.get('versionCreated'),
            'A version should be created rather than saving into a void'
        );
        List<DocGen_Template_Version__c> versions = [
            SELECT Id, Is_Active__c, Type__c, Base_Object_API__c, Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :tpl.Id
        ];
        System.assertEquals(1, versions.size(), 'Exactly one version');
        System.assertEquals(
            true,
            versions[0].Is_Active__c,
            'And it must be active, or the renderer will never read it'
        );
        System.assertEquals('Canvas', versions[0].Type__c, 'It should inherit the template type');
        System.assertEquals('Account', versions[0].Base_Object_API__c, 'It should inherit the template base object');
        System.assertEquals(
            (Id) res.get('contentVersionId'),
            (Id) versions[0].Content_Version_Id__c,
            'Pointing at the body just saved'
        );
    }

    /**
     * newVersion = true with nothing to clone. The fallback must still stamp the type,
     * because a version with a blank Type__c renders down the wrong path entirely — a
     * Canvas body handed to the DOCX reader fails with "Could not load Zip".
     */
    @IsTest
    static void newVersionWithNothingToCloneInheritsTheTemplateType() {
        DocGen_Template__c tpl = newCanvasTemplate();

        Test.startTest();
        Map<String, Object> res = DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', CANVAS_BODY, true);
        Test.stopTest();

        DocGen_Template_Version__c fresh = reload((Id) res.get('versionId'));
        System.assertEquals(
            'Canvas',
            fresh.Type__c,
            'Type must be stamped from the template when there is no prior version'
        );
        System.assertEquals(true, fresh.Is_Active__c, 'The fallback version must be active');
        System.assertEquals(tpl.Id, fresh.Template__c, 'And parented to the template');
    }

    // -----------------------------------------------------------------------
    // What the editor saved is what the renderer reads.
    // -----------------------------------------------------------------------
    @IsTest
    static void savedBodyIsWhatTheVersionServesBack() {
        DocGen_Template__c tpl = newCanvasTemplate();
        newConfiguredVersion(tpl.Id, true);

        Test.startTest();
        Map<String, Object> first = DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', CANVAS_BODY, true);
        Map<String, Object> second = DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', SECOND_BODY, true);
        Test.stopTest();

        // Each version keeps ITS OWN body — this is what makes the version picker able
        // to take you back to an earlier canvas rather than to whatever was saved last.
        System.assertEquals(
            CANVAS_BODY,
            DocGenController.getVersionBody((Id) first.get('versionId')),
            'The first version should still serve the body it was saved with'
        );
        System.assertEquals(
            SECOND_BODY,
            DocGenController.getVersionBody((Id) second.get('versionId')),
            'The current version should serve the body just saved'
        );
    }

    // -----------------------------------------------------------------------
    // Guards.
    // -----------------------------------------------------------------------
    @IsTest
    static void aBlankBodyCannotReplaceARealOne() {
        DocGen_Template__c tpl = newCanvasTemplate();
        newConfiguredVersion(tpl.Id, true);
        DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', CANVAS_BODY, true);

        Boolean refused = false;
        Test.startTest();
        try {
            DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', '<html><body></body></html>', true);
        } catch (DocGenException e) {
            refused = true;
            System.assert(
                e.getMessage().contains('empty document'),
                'The message should explain the body is safe, not just fail: ' + e.getMessage()
            );
        }
        Test.stopTest();

        System.assertEquals(true, refused, 'An empty document must not overwrite saved work');
        // The guard has to be non-destructive, not merely noisy.
        DocGen_Template_Version__c active = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
            LIMIT 1
        ];
        System.assertEquals(
            CANVAS_BODY,
            DocGenController.getVersionBody(active.Id),
            'The stored body must be untouched after a refused save'
        );
    }

    @IsTest
    static void nonHtmlBackedTemplatesAreRefused() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Word Template',
            Type__c = 'Word',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'Native'
        );
        insert tpl;

        Boolean refused = false;
        Test.startTest();
        try {
            DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', CANVAS_BODY, true);
        } catch (DocGenException e) {
            refused = true;
        }
        Test.stopTest();

        System.assertEquals(true, refused, 'A Word template stores a .docx — an HTML body must not be written to it');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tpl.Id],
            'And nothing should have been created on the way to refusing'
        );
    }

    /**
     * Canvas and HTML must both reach this method. Thirteen branches across seven
     * classes tested Type__c == 'HTML' directly and sent Canvas bodies to the DOCX
     * reader; DocGenService.isHtmlBacked is the single place that knows better, and
     * this asserts the storage path honours it for both.
     */
    @IsTest
    static void bothHtmlBackedTypesAreAccepted() {
        DocGen_Template__c htmlTpl = new DocGen_Template__c(
            Name = 'HTML Template',
            Type__c = 'HTML',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF'
        );
        insert htmlTpl;
        DocGen_Template__c canvasTpl = newCanvasTemplate();

        Test.startTest();
        Map<String, Object> htmlRes = DocGenController.saveAndPublishHtmlBody(
            htmlTpl.Id,
            'body.html',
            CANVAS_BODY,
            true
        );
        Map<String, Object> canvasRes = DocGenController.saveAndPublishHtmlBody(
            canvasTpl.Id,
            'canvas.html',
            CANVAS_BODY,
            true
        );
        Test.stopTest();

        System.assertNotEquals(null, htmlRes.get('versionId'), 'HTML templates save through this path');
        System.assertNotEquals(null, canvasRes.get('versionId'), 'Canvas templates save through the same path');
        System.assertEquals(true, DocGenService.isHtmlBacked('Canvas'), 'Canvas is HTML-backed');
        System.assertEquals(true, DocGenService.isHtmlBacked('HTML'), 'HTML is HTML-backed');
        System.assertEquals(false, DocGenService.isHtmlBacked('Word'), 'Word is not');
    }

    @IsTest
    static void missingArgumentsAreRejected() {
        DocGen_Template__c tpl = newCanvasTemplate();

        Integer refusals = 0;
        Test.startTest();
        try {
            DocGenController.saveAndPublishHtmlBody(null, 'canvas.html', CANVAS_BODY, true);
        } catch (Exception e) {
            refusals++;
        }
        try {
            DocGenController.saveAndPublishHtmlBody(tpl.Id, 'canvas.html', null, true);
        } catch (Exception e) {
            refusals++;
        }
        Test.stopTest();

        System.assertEquals(2, refusals, 'A missing template or a null body must both be refused');
    }
}
