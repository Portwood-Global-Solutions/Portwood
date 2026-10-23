@IsTest
private class DocGenFontTest {
    @TestSetup
    static void setupPermission() {
        Profile authorProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User author = new User(
            Alias = 'fontau',
            Email = 'font-author@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Portwood Font Author QA',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/New_York',
            ProfileId = authorProfile.Id,
            Username = 'fontauthor' + UserInfo.getOrganizationId() + System.now().getTime() + '@example.invalid'
        );
        insert author;
        Id userPs = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1].Id;
        insert new PermissionSetAssignment(AssigneeId = author.Id, PermissionSetId = userPs);
        User admin = author.clone(false, false, false, false);
        admin.Alias = 'fontad';
        admin.LastName = 'Portwood Font Admin QA';
        admin.Username = 'fontadmin' + UserInfo.getOrganizationId() + System.now().getTime() + '@example.invalid';
        insert admin;
        Id adminPs = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Admin' LIMIT 1].Id;
        insert new PermissionSetAssignment(AssigneeId = admin.Id, PermissionSetId = adminPs);
    }
    private static User fontAdmin() {
        return [SELECT Id FROM User WHERE Alias = 'fontad' LIMIT 1];
    }
    private static String stage() {
        return DocGenFontController.stageFont(
            'PWTestScript-Regular.ttf',
            EncodingUtil.base64Encode(DocGenFontTestData.regular()),
            'parisienne',
            'SIL OFL 1.1 - test fixture; original license retained in DocGenFontTestData',
            true
        );
    }
    private static String published() {
        String key = stage();
        DocGenFontController.createFontProof(key);
        return key;
    }
    private static String verified() {
        String key = published();
        String proof = DocGenFontController.createFontProof(key);
        DocGenFontController.verifyFont(key, proof, true);
        return key;
    }
    private static String bound(String key, String text) {
        return '<html><head></head><body><div style="-pw-font-face:' +
            key +
            ';font-family:\'Portwood Test Script\';font-weight:400;font-style:normal;">' +
            text +
            '</div></body></html>';
    }
    @IsTest
    static void serverInspectionAndStageIdempotency() {
        System.runAs(fontAdmin()) {
            String key = stage();
            System.assertEquals(key, stage());
            DocGen_Font_Face__c f = DocGenFontController.load(key);
            Map<String, Object> meta = (Map<String, Object>) JSON.deserializeUntyped(f.Metadata_JSON__c);
            System.assertEquals('Portwood Test Script', meta.get('family'));
            System.assertEquals('PortwoodTestScript-Regular', meta.get('postscriptName'));
            System.assertEquals('400', String.valueOf(meta.get('weight')));
            System.assertEquals('Staged', f.Status__c);
            System.assertEquals(1, [SELECT COUNT() FROM DocGen_Font_Face__c]);
            DocGenFontService.checkText(meta, 'Şahin ş');
            try {
                DocGenFontService.checkText(meta, '漢');
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('U+6F22'));
            }
            try {
                DocGenFontService.checkText(meta, '😀');
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('U+1F600'));
            }
        }
    }
    @IsTest
    static void rejectSpoofedAndUnlicensedUploads() {
        System.runAs(fontAdmin()) {
            try {
                DocGenFontController.stageFont(
                    'Fake.ttf',
                    EncodingUtil.base64Encode(Blob.valueOf('not a font at all')),
                    'fake',
                    'license',
                    true
                );
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('static TrueType'));
            }
            try {
                DocGenFontController.stageFont('Fake.ttf', 'AA==', 'fake', 'license', false);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('license'));
            }
            try {
                DocGenFontController.stageFont('Fake.ttf', 'AA==', 'fake', '', true);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('license'));
            }
            try {
                new DocGenFontInspector(Blob.valueOf('tiny')).inspect('fake.ttf');
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('valid static TTF'));
            }
        }
    }
    @IsTest
    static void stagedIsNotPublishedOrRetired() {
        System.runAs(fontAdmin()) {
            String key = stage();
            try {
                DocGenFontService.prepare(bound(key, 'Şahin'));
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('review'));
            }
            try {
                DocGenFontController.retireFont(key);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('verified'));
            }
        }
    }
    @IsTest
    static void fileSpecimenAndCurrentProofRequired() {
        System.runAs(fontAdmin()) {
            String key = stage();
            try {
                DocGenFontController.verifyFont(key, '068000000000001', true);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('current native'));
            }
            String proof = DocGenFontController.createFontProof(key);
            try {
                DocGenFontController.verifyFont(key, proof, false);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('Review'));
            }
            DocGenFontController.verifyFont(key, proof, true);
            System.assertEquals('Verified', DocGenFontController.load(key).Status__c);
            System.assertEquals(proof, DocGenFontController.createFontProof(key));
            System.assertEquals('Verified', DocGenFontController.load(key).Status__c);
        }
    }
    @IsTest
    static void exactFaceAndMissingMergedGlyph() {
        System.runAs(fontAdmin()) {
            String key = verified();
            String html = DocGenFontService.prepare(bound(key, 'Şahin &amp; 漢'));
            System.assert(html.contains('-fs-pdf-font-encoding:Identity-H'));
            System.assert(
                html.contains('src:url("/sfc/servlet.shepherd/version/download/'),
                'Native font URLs must be relative: absolute org URLs silently fall back in Lightning generation.'
            );
            System.assert(html.contains('?font.ttf'));
            System.assert(!html.contains('/resource/'));
            System.assert(!html.contains('format(\'truetype\')'));
            // An unsupported glyph inside a pinned binding falls back to Arial Unicode MS
            // for that element rather than aborting the whole document (see
            // hasUnsupportedRenderText's doc comment) -- checkText() is the strict,
            // throwing check, reserved for upload-time/verification review.
            String fallback = DocGenFontService.prepare(bound(key, '漢'));
            System.assert(!fallback.contains('-pw-font-face:' + key), fallback);
            System.assert(fallback.contains('Arial Unicode MS'), fallback);
            try {
                DocGenFontService.prepare(bound(key, '<b>Şahin</b>'));
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('explicit verified face'));
            }
            try {
                DocGenFontService.prepare(bound(key, 'Şahin').replace('font-weight:400', 'font-weight:700'));
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('explicit verified face'));
            }
            try {
                DocGenFontService.prepare(bound(key, 'Şahin').replace('<head>', '<head><style>@font-face{}</style>'));
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('registry'));
            }
            try {
                DocGenFontService.prepare(
                    bound(key, 'Şahin')
                        .replace('</body>', '<p style="font-family:Portwood Test Script">Şahin</p></body>')
                );
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('binding'));
            }
            try {
                DocGenFontService.prepare(
                    bound(key, 'Şahin')
                        .replace('<head>', '<head><style>.custom{font-family:Portwood Test Script;}</style>')
                );
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('bindings'));
            }
            DocGen_Font_Face__c f = DocGenFontController.load(key);
            f.Source_Checksum__c = 'changed';
            try {
                DocGenFontController.sourceFile(f);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('File content changed'));
            }
        }
    }
    @IsTest
    static void importantLayoutStylesPreserveVerifiedFaces() {
        System.runAs(fontAdmin()) {
            String key = verified();
            String css =
                '.title,.title *{color:#285e63 !important;}' +
                '.title{font:italic 700 24pt Arial !important;}' +
                'tr{page-break-inside:avoid !important;}';
            String authored = bound(
                    key,
                    '<h1 class="title" style="width:90% !important;text-align:center !important;">Şahin ş</h1>'
                )
                .replace('<head>', '<head><style>' + css + '</style>');
            String rendered = DocGenFontService.prepare(authored);
            System.assert(rendered.contains(css), 'Preserve stylesheet colour, size and pagination priorities');
            System.assert(
                rendered.contains('width:90% !important;text-align:center !important;'),
                'Preserve inline layout priorities'
            );
            String pinned = 'font-family:&quot;Portwood Test Script&quot; !important;font-weight:400 !important;font-style:normal !important;';
            System.assertEquals(
                2,
                rendered.split(pinned, -1).size() - 1,
                'Both the container and inherited heading keep the reviewed face despite important font shorthand'
            );
            System.assert(rendered.contains('Identity-H'), 'Still embed the verified Salesforce File font');
            String wrapped = DocGenService.wrapHtmlForPdf(
                authored.substringBetween('<body>', '</body>'),
                css,
                null,
                null
            );
            System.assert(wrapped.contains(css) && wrapped.contains(pinned), 'The PDF wrapper uses the same rules');
            String legacy = '<p style="color:red !important;">Plain text</p>';
            System.assertEquals(legacy, DocGenFontService.prepare(legacy), 'Unbound documents stay unchanged');
        }
    }
    @IsTest
    static void importantFontValuesStillRequireExactFace() {
        System.runAs(fontAdmin()) {
            String key = verified();
            String exact = bound(key, 'Şahin ş')
                .replace('Portwood Test Script\';', 'Portwood Test Script\' !IMPORTANT;')
                .replace('font-weight:400;', 'font-weight:normal ! important;')
                .replace('font-style:normal;', 'font-style:normal !important;');
            System.assert(
                DocGenFontService.prepare(exact).contains('font-weight:400 !important;'),
                'Priority does not change the meaning of an exact registered face'
            );
            for (
                String changed : new List<String>{
                    exact.replace('Portwood Test Script', 'Arial'),
                    exact.replace('font-weight:normal', 'font-weight:700'),
                    exact.replace('font-style:normal', 'font-style:italic')
                }
            ) {
                try {
                    DocGenFontService.prepare(changed);
                    System.assert(false, 'Conflicting inline font overrides must still be rejected');
                } catch (DocGenException e) {
                    System.assert(e.getMessage().contains('explicit verified face'), e.getMessage());
                }
            }
            try {
                DocGenFontService.prepare(
                    bound(key, 'Şahin')
                        .replace('</body>', '<p style="font-family:Portwood Test Script !important;">Şahin</p></body>')
                );
                System.assert(false, 'Priority cannot bypass an explicit binding requirement');
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('binding'), e.getMessage());
            }
            try {
                DocGenFontService.prepare(
                    bound(key, 'Şahin')
                        .replace(
                            '<head>',
                            '<head><style>.unbound{font-family:"Portwood Test Script" !IMPORTANT;}</style>'
                        )
                );
                System.assert(false, 'Stylesheet priority cannot bypass font bindings and glyph validation');
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('bindings'), e.getMessage());
            }
        }
    }
    @IsTest
    static void preserveCustomGlyphsWithoutChangingLegacyText() {
        System.runAs(fontAdmin()) {
            String key = verified();
            String custom =
                '<div style="-pw-font-face:' +
                key +
                ';font-family:\'Portwood Test Script\';font-weight:400;font-style:normal;">Şahin <span>漢</span></div>';
            String out = DocGenService.wrapHtmlForPdf(custom, '', null, null);
            System.assert(out.contains('Şahin') && out.contains('漢</span>'), 'Selected font glyphs remain live text');
            System.assert(
                !out.contains('Arial Unicode MS\', sans-serif;\">漢'),
                'No automatic substitution inside selected face'
            );
            String legacy = DocGenService.wrapHtmlForPdf('<p>漢</p>', '', null, null);
            System.assert(legacy.contains('Arial Unicode MS'));
            DocGenFontController.retireFont(key);
            System.assert(DocGenFontService.prepare(bound(key, 'Şahin')).contains('Identity-H'));
            for (Map<String, Object> face : DocGenFontController.getFontFaces())
                if (face.get('key') == key)
                    System.assertEquals(false, face.get('selectable'));
        }
    }
    @IsTest
    static void immutableRegistryAndImageIsolation() {
        System.runAs(fontAdmin()) {
            String key = verified();
            DocGen_Font_Face__c face = DocGenFontController.load(key);
            face.Metadata_JSON__c = '{}';
            try {
                update face;
                System.assert(false);
            } catch (DmlException e) {
                System.assert(e.getMessage().contains('Assets'));
            }
            try {
                delete face;
                System.assert(false);
            } catch (DmlException e) {
                System.assert(e.getMessage().contains('Assets'));
            }
            System.assertEquals(
                null,
                DocGenService.resolveAssetCvIds(new Set<String>{ 'parisienne' }).get('parisienne')
            );
            for (Map<String, Object> image : DocGenController.getAssets())
                System.assertNotEquals('Font', image.get('assetType'));
            DocGenFontController.authorizedMutation = true;
            try {
                face = DocGenFontController.load(key);
                face.Source_CV_Id__c = '068000000000001';
                update face;
                System.assert(false);
            } catch (DmlException e) {
                System.assert(e.getMessage().contains('immutable'));
            } finally {
                DocGenFontController.authorizedMutation = false;
            }
        }
    }
    @IsTest
    static void authorCanUseVerifiedFontsWithoutManagementPermission() {
        System.runAs(fontAdmin()) {
            String key = verified();
            User author = [SELECT Id FROM User WHERE LastName = 'Portwood Font Author QA' LIMIT 1];
            System.runAs(author) {
                System.assert(!FeatureManagement.checkPermission('Manage_DocGen_Fonts'));
                System.assert(!DocGenFontController.getFontFaces().isEmpty());
                System.assert(DocGenFontService.prepare(bound(key, 'Şahin 漢')).contains('Identity-H'));
                try {
                    DocGenFontController.retireFont(key);
                    System.assert(false);
                } catch (DocGenException e) {
                    System.assert(e.getMessage().contains('permission'));
                }
            }
        }
    }

    @IsTest
    static void pinnedRuntimeDoesNotLoadFontBytes() {
        System.runAs(fontAdmin()) {
            String key = verified();
            DocGen_Font_Face__c face = DocGenFontController.load(key);
            System.assertNotEquals(null, face.Source_Checksum__c);
            ContentVersion metadata = DocGenFontController.sourceFile(face);
            System.assert(
                !metadata.getPopulatedFieldsAsMap().containsKey('VersionData'),
                'Runtime must not fetch font bytes'
            );
            DocGenFontController.authorizedMutation = true;
            try {
                face.Source_Checksum__c = 'changed';
                update face;
                System.assert(false, 'An inspected File checksum must be immutable');
            } catch (DmlException e) {
                System.assert(e.getMessage().contains('immutable'));
            } finally {
                DocGenFontController.authorizedMutation = false;
            }
        }
    }
    @IsTest
    static void nativeFileUploadAndPrivateJobResult() {
        System.runAs(fontAdmin()) {
            Blob bytes = DocGenFontTestData.regular();
            String license = 'SIL OFL 1.1 - test fixture';
            ContentVersion cv = new ContentVersion(
                Title = 'PortwoodTestScript-Regular',
                PathOnClient = 'PWTestScript-Regular.ttf',
                VersionData = bytes
            );
            insert cv;
            cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
            Test.startTest();
            String job = DocGenFontController.importUploadedFont(cv.ContentDocumentId, 'parisienne', license, true);
            Test.stopTest();
            System.assertEquals('Completed', DocGenFontController.getFontJobStatus(job).get('status'));
            DocGen_Font_Face__c face = [
                SELECT Source_CV_Id__c, Source_Checksum__c, Status__c
                FROM DocGen_Font_Face__c
                LIMIT 1
            ];
            System.assertEquals(cv.Id, face.Source_CV_Id__c, 'Keep the original uploaded File; do not copy its bytes');
            System.assertEquals('Staged', face.Status__c);
            System.assertNotEquals(null, face.Source_Checksum__c);
            System.assert(
                String.valueOf(DocGenFontController.getFontFaces()[0].get('previewUrl'))
                    .startsWith('/sfc/dist/version/download/')
            );
            System.assertEquals(1, [SELECT COUNT() FROM ContentVersion]);
            User author = [SELECT Id FROM User WHERE LastName = 'Portwood Font Author QA' LIMIT 1];
            System.runAs(author) {
                try {
                    DocGenFontController.getFontJobStatus(job);
                    System.assert(false);
                } catch (DocGenException e) {
                    System.assert(e.getMessage().contains('permission'));
                }
            }
        }
    }
    @IsTest
    static void nativeFileProofRunsInBackground() {
        System.runAs(fontAdmin()) {
            String key = stage();
            Test.startTest();
            String job = DocGenFontController.startFontProof(key);
            Test.stopTest();
            System.assertEquals('Completed', DocGenFontController.getFontJobStatus(job).get('status'));
            DocGen_Font_Face__c face = DocGenFontController.load(key);
            System.assertEquals('Published', face.Status__c);
            System.assertNotEquals(null, face.Proof_CV_Id__c);
            System.assertEquals(
                2,
                [SELECT COUNT() FROM ContentVersion],
                'Only original TTF and PDF; no ZIP or CSS File'
            );
        }
    }
    @IsTest
    static void rejectAnotherUsersPrivateFont() {
        System.runAs(fontAdmin()) {
            User author = [SELECT Id FROM User WHERE LastName = 'Portwood Font Author QA' LIMIT 1];
            Id documentId;
            System.runAs(author) {
                ContentVersion cv = new ContentVersion(
                    Title = 'Private',
                    PathOnClient = 'Private.ttf',
                    VersionData = Blob.valueOf('not a valid font')
                );
                insert cv;
                documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            }
            try {
                DocGenFontController.importUploadedFont(documentId, 'private-font', 'license', true);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('own account'));
            }
        }
    }

    @IsTest
    static void originalLicenseWhitespaceSurvivesPublication() {
        System.runAs(fontAdmin()) {
            Blob font = DocGenFontTestData.regular();
            String license = 'Original license\n\n';
            String key = DocGenFontController.stageFont(
                'PWTestScript-Regular.ttf',
                EncodingUtil.base64Encode(font),
                'license-qa',
                license,
                true
            );
            DocGen_Font_Face__c face = DocGenFontController.load(key);
            Map<String, Object> meta = (Map<String, Object>) JSON.deserializeUntyped(face.Metadata_JSON__c);
            System.assertEquals(license, meta.get('licenseText'));
            System.assertNotEquals(null, DocGenFontController.createFontProof(key));
            System.assertEquals(
                license,
                ((Map<String, Object>) JSON.deserializeUntyped(DocGenFontController.load(key).Metadata_JSON__c))
                    .get('licenseText')
            );
        }
    }

    @IsTest
    static void missingOrChangedFontFileCannotRender() {
        System.runAs(fontAdmin()) {
            String key = verified();
            DocGen_Font_Face__c face = DocGenFontController.load(key);
            ContentVersion file = DocGenFontController.sourceFile(face);
            Map<String, Object> meta = (Map<String, Object>) JSON.deserializeUntyped(face.Metadata_JSON__c);
            meta.put('sizeBytes', 1);
            face.Metadata_JSON__c = JSON.serialize(meta);
            try {
                DocGenFontController.sourceFile(face);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('missing or changed'));
            }
            Id docId = file.ContentDocumentId;
            ContentDocumentLink link = [
                SELECT Id
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :docId AND LinkedEntityId = :face.Asset__c
                LIMIT 1
            ];
            delete link;
            try {
                DocGenFontService.prepare(bound(key, 'Şahin'));
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('missing or changed'));
            }
        }
    }
    @IsTest
    static void newerFileVersionDoesNotChangePinnedFont() {
        System.runAs(fontAdmin()) {
            String key = verified();
            DocGen_Font_Face__c face = DocGenFontController.load(key);
            ContentVersion original = DocGenFontController.sourceFile(face);
            insert new ContentVersion(
                ContentDocumentId = original.ContentDocumentId,
                Title = 'replacement',
                PathOnClient = 'replacement.ttf',
                VersionData = Blob.valueOf('new bytes')
            );
            System.assertEquals(original.Id, DocGenFontController.sourceFile(face).Id);
            ContentDistribution preview = [
                SELECT ContentVersionId, PreferencesLinkLatestVersion
                FROM ContentDistribution
                WHERE ContentVersionId = :original.Id
                LIMIT 1
            ];
            System.assertEquals(false, preview.PreferencesLinkLatestVersion);
            System.assertEquals(original.Id, preview.ContentVersionId);
            System.assert(
                DocGenFontService.prepare(bound(key, 'Şahin')).contains(String.valueOf(original.Id) + '?font.ttf')
            );
        }
    }

    private static String fontTag(String key) {
        return DocGenFontService.mergeTag('parisienne', key);
    }
    @IsTest
    static void fontTagCatalogAndAuthorAccess() {
        System.runAs(fontAdmin()) {
            String key = verified();
            String tag = fontTag(key);
            User author = [SELECT Id FROM User WHERE LastName = 'Portwood Font Author QA' LIMIT 1];
            System.runAs(author) {
                System.assertEquals(tag, DocGenFontController.getFontFaces()[0].get('mergeTag'));
                String source = '<p style="' + tag + ';font-size:12pt">Şahin 漢</p>';
                String expanded = DocGenFontService.expandTags(source);
                System.assert(expanded.contains('-pw-font-face:' + key));
                System.assert(expanded.contains('font-size:12pt'));
                System.assertEquals(expanded, DocGenFontService.expandTags(expanded), 'Expansion is idempotent');
                String fullKeyTag = '{%font:parisienne:' + key + '}';
                System.assertEquals(expanded, DocGenFontService.expandTags(source.replace(tag, fullKeyTag)));
                System.assertEquals(
                    expanded,
                    DocGenFontService.expandTags(source.replace('{', '&#123;').replace('}', '&#125;'))
                );
            }
        }
    }
    @IsTest
    static void htmlTemplateFontTagMergesBodyAndChrome() {
        System.runAs(fontAdmin()) {
            String key = verified(), tag = fontTag(key);
            Account a = new Account(Name = 'Şahin Şirket');
            insert a;
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'HTML font tags',
                Type__c = 'HTML',
                Output_Format__c = 'PDF',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Header_Html__c = '<p style="' + tag + '">Header {Name}</p>',
                Footer_Html__c = '<p style="' + tag + '">Footer 漢</p>'
            );
            insert t;
            String source =
                '<html><head><style>p{color:#183452}</style></head><body style="' +
                tag +
                ';font-size:14pt"><h1>{Name}</h1><p>Live 漢</p></body></html>';
            Map<String, Object> saved = DocGenController.saveAndPublishHtmlBody(t.Id, 'font-tags.html', source, true);
            Test.startTest();
            // The renderer cannot fetch Files inserted inside an uncommitted test transaction.
            // Exercise the complete HTML merge; committed Files embedding is verified by live PDF probes.
            String rendered = DocGenService.generateHtmlForRecord(t.Id, a.Id, null);
            Test.stopTest();
            System.assert(rendered.contains('Şahin Şirket'), rendered);
            System.assert(rendered.contains('-pw-font-face:' + key), 'Body binding survives extraction');
            System.assert(rendered.contains('Identity-H'));
            System.assert(!rendered.contains('{%font:'));
            System.assert(!rendered.contains('Arial Unicode MS\', sans-serif;\">漢'));
            System.assert(rendered.contains('Header Şahin Şirket') && rendered.contains('Footer 漢'));
            DocGen_Template_Version__c version = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Template__c = :t.Id AND Is_Active__c = TRUE
                LIMIT 1
            ];
            System.assertEquals(
                source,
                DocGenController.getVersionBody(version.Id),
                'The authored, revision-pinned tag survives save/reopen'
            );
        }
    }
    @IsTest
    static void fontTagsRejectMisuseAndUnverifiedFaces() {
        System.runAs(fontAdmin()) {
            String key = stage(), tag = fontTag(key);
            try {
                DocGenFontService.expandTags('<p style="' + tag + '">not verified</p>');
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('review'));
            }
            String proofKey = verified();
            System.assertEquals(key, proofKey);
            tag = fontTag(key);
            for (
                String bad : new List<String>{
                    '<p>' +
                    tag +
                    '</p>',
                    '<img src="' +
                    tag +
                    '"/>',
                    '<style>.brand{' +
                    tag +
                    '}</style>',
                    '<p style="font-family:' +
                    tag +
                    '">bad value</p>',
                    '<p style="' +
                    tag +
                    tag +
                    '">two faces</p>',
                    '<p style="' +
                    tag +
                    ';font-weight:bold">synthetic bold</p>',
                    '<p style="font-family:Arial;' +
                    tag +
                    '">family override</p>',
                    '<p style="' +
                    tag +
                    ';font:italic 12pt Arial">shorthand override</p>',
                    '<p style="{%font:parisienne}">missing revision</p>',
                    '<p style="{%font:missing:0000000000000000}">missing asset</p>'
                }
            ) {
                try {
                    DocGenFontService.expandTags(bad);
                    System.assert(false, bad);
                } catch (DocGenException e) {
                    System.assert(String.isNotBlank(e.getMessage()));
                }
            }
            String comment = '<!-- ' + tag + ' -->';
            System.assertEquals(comment, DocGenFontService.expandTags(comment));
            try {
                DocGenService.wrapHtmlForPdf('<p>Body</p>', '', null, '<p style="' + tag + '">Page {PageNumber}</p>');
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('page-counter'));
            }
        }
    }
    @IsTest
    static void fontTagKeepsRetiredRevisionAndFallsBackOnMissingGlyphs() {
        System.runAs(fontAdmin()) {
            String key = verified(), tag = fontTag(key);
            DocGenFontController.retireFont(key);
            String source = '<p style="' + tag + '">Şahin 漢</p>';
            System.assert(DocGenService.wrapHtmlForPdf(source, '', null, null).contains('Identity-H'));
            // An unsupported glyph falls back to Arial Unicode MS for that element
            // rather than aborting the document (see hasUnsupportedRenderText).
            String fallback = DocGenService.wrapHtmlForPdf('<p style="' + tag + '">漢</p>', '', null, null);
            System.assert(!fallback.contains('-pw-font-face:' + key), fallback);
            System.assert(fallback.contains('Arial Unicode MS'), fallback);
        }
    }

    @IsTest
    static void giantRowsArePresentBeforeFontsAndGlyphsArePrepared() {
        System.runAs(fontAdmin()) {
            String key = verified();
            String tag = DocGenFontService.mergeTag('parisienne', key);
            String shell = DocGenService.wrapHtmlForPdf('<table><tbody>{ROWS}</tbody></table>', '', null, null, false);
            System.assert(!shell.contains('@font-face'));
            String row = '<tr><td style="' + tag + '">Hello customer</td></tr>';
            String prepared = DocGenFontService.prepare(shell.replace('{ROWS}', row));
            System.assert(prepared.contains('@font-face') && prepared.contains(key));
            System.assert(!prepared.contains('{%font:'));
            // An unsupported glyph in an injected batch row falls back to Arial
            // Unicode MS for that row rather than aborting the whole document.
            String fallback = DocGenFontService.prepare(shell.replace('{ROWS}', row.replace('Hello customer', '漢')));
            System.assert(
                !fallback.contains('-pw-font-face:' + key),
                'Glyphs from injected batch rows must be validated: ' + fallback
            );
            System.assert(fallback.contains('Arial Unicode MS'), fallback);
        }
    }

    @IsTest
    static void fontTagsSurviveGiantParentResolution() {
        System.runAs(fontAdmin()) {
            String key = verified(), tag = fontTag(key);
            Account a = new Account(Name = 'Giant Şahin');
            insert a;
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Giant font tag',
                Type__c = 'HTML',
                Output_Format__c = 'PDF',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name'
            );
            insert t;
            DocGenGiantQueryAssembler giant = new DocGenGiantQueryAssembler(null, t.Id, a.Id, 'Contacts');
            String source = '<p style="' + tag + '">{Name}</p>';
            String merged = giant.resolveParentMergeTags(source);
            System.assert(merged.contains('Giant Şahin'), merged);
            System.assert(merged.contains(tag), 'The giant parent regex leaves font tags for the shared HTML wrapper');
            System.assert(DocGenService.wrapHtmlForPdf(merged, '', null, null).contains('Identity-H'));
            String body = DocGenService.extractHtmlBodyContent('<html><body style="' + tag + '">{Name}</body></html>');
            System.assert(body.contains('-pw-font-face:' + key), 'The giant HTML extractor uses the same binding path');
        }
    }
    @IsTest
    static void nestedFontTagsUseExactRegularAndBoldFaces() {
        System.runAs(fontAdmin()) {
            String regular = verified();
            String bold = DocGenFontController.stageFont(
                'PWTestSans-Bold.ttf',
                EncodingUtil.base64Encode(DocGenFontTestData.bold()),
                'barlow',
                'SIL OFL 1.1 - test fixture',
                true
            );
            DocGenFontController.verifyFont(bold, DocGenFontController.createFontProof(bold), true);
            String html = DocGenService.wrapHtmlForPdf(
                '<p style="' +
                    fontTag(regular) +
                    '">Regular <strong style="' +
                    DocGenFontService.mergeTag('barlow', bold) +
                    '">Bold Şahin</strong> Regular ş</p>',
                '',
                null,
                null
            );
            System.assert(html.contains('-pw-font-face:' + regular) && html.contains('-pw-font-face:' + bold));
            System.assert(html.contains('font-weight:700'));
            System.assert(html.contains('Bold Şahin') && html.contains('Regular ş'));
        }
    }

    private static Blob patched(Blob bytes, Integer byteAt, String replacement) {
        String h = EncodingUtil.convertToHex(bytes);
        return EncodingUtil.convertFromHex(
            h.substring(0, byteAt * 2) + replacement + h.substring(byteAt * 2 + replacement.length())
        );
    }
    @IsTest
    static void filenamesMetricsAndColorOutlineCompatibility() {
        System.runAs(fontAdmin()) {
            Blob bytes = DocGenFontTestData.regular();
            Map<String, Object> meta = new DocGenFontInspector(bytes).inspect('Brand Font (Regular) 😀😀.TTF');
            System.assertEquals('Brand Font (Regular) 😀😀.TTF', meta.get('filename'));
            System.assertEquals(false, meta.get('colorFont'));
            String h = EncodingUtil.convertToHex(bytes);
            for (String tag : new List<String>{ '68686561', '686d7478' }) {
                Integer directory = h.indexOf(tag) / 2;
                System.assert(directory >= 12);
                try {
                    new DocGenFontInspector(patched(bytes, directory, '50575141')).inspect('Missing.ttf');
                    System.assert(
                        false,
                        'Missing metric tables must fail before the renderer silently substitutes Times.'
                    );
                } catch (DocGenException e) {
                    System.assert(e.getMessage().contains('Missing TrueType table'), e.getMessage());
                }
            }
            Integer hhea = h.indexOf('68686561') / 2;
            Integer metricOffset = 0;
            for (Integer i = (hhea + 8) * 2; i < (hhea + 12) * 2; i++)
                metricOffset = metricOffset * 16 + '0123456789abcdef'.indexOf(h.substring(i, i + 1));
            try {
                new DocGenFontInspector(patched(bytes, metricOffset + 34, '0000')).inspect('InvalidMetrics.ttf');
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('metric count'), e.getMessage());
            }
            Integer gasp = h.indexOf('67617370') / 2;
            meta = new DocGenFontInspector(patched(bytes, gasp, '434f4c52')).inspect('Color.ttf');
            System.assertEquals(true, meta.get('colorFont'), 'Color tables need an explicit native PDF warning.');
            for (String filename : new List<String>{ '../font.ttf', 'folder\\font.ttf', 'font.txt', 'font\n.ttf' }) {
                try {
                    new DocGenFontInspector(bytes).inspect(filename);
                    System.assert(false);
                } catch (DocGenException e) {
                    System.assert(e.getMessage().contains('filename'), e.getMessage());
                }
            }
        }
    }
    @IsTest
    static void catalogProjectionPreservesLegacyCoverageAndSkipsPrivatePayload() {
        System.runAs(fontAdmin()) {
            Map<String, Object> full = new DocGenFontInspector(DocGenFontTestData.regular()).inspect('Regular.ttf');
            full.put('licenseText', 'License text with JSON-like content: "coverage":[[0,999999]]');
            Map<String, Object> summary = DocGenFontController.catalogMetadata(JSON.serialize(full));
            System.assertEquals(full.get('family'), summary.get('family'));
            System.assertEquals(full.get('hasCedilla'), summary.get('hasCedilla'));
            System.assertEquals(full.get('colorFont'), summary.get('colorFont'));
            System.assertEquals(String.valueOf(full.get('weight')), String.valueOf(summary.get('weight')));
            System.assert(!summary.containsKey('coverage') && !summary.containsKey('licenseText'));
            full.remove('hasCedilla');
            summary = DocGenFontController.catalogMetadata(JSON.serialize(full));
            System.assertEquals(true, summary.get('hasCedilla'));
            full.put(
                'coverage',
                new List<List<Integer>>{ new List<Integer>{ 32, 126 }, new List<Integer>{ 1000, 1100 } }
            );
            summary = DocGenFontController.catalogMetadata(JSON.serialize(full));
            System.assertEquals(false, summary.get('hasCedilla'));
            full.put('coverage', new List<List<Integer>>{ new List<Integer>{ 350, 350 } });
            System.assertEquals(false, DocGenFontController.catalogMetadata(JSON.serialize(full)).get('hasCedilla'));
        }
    }
    @IsTest
    static void supplementaryGlyphCoverageDoesNotPromiseNativeRendering() {
        System.runAs(fontAdmin()) {
            Map<String, Object> meta = new Map<String, Object>{
                'family' => 'QA Unicode',
                'coverage' => new List<List<Integer>>{
                    new List<Integer>{ 9833, 9836 },
                    new List<Integer>{ 119070, 119070 },
                    new List<Integer>{ 128512, 128512 }
                }
            };
            DocGenFontService.checkText(meta, '♪♬');
            for (String text : new List<String>{ '𝄞', '😀' }) {
                try {
                    DocGenFontService.checkText(meta, text);
                    System.assert(
                        false,
                        'The native renderer drops these covered characters; generation must fail clearly.'
                    );
                } catch (DocGenException e) {
                    System.assert(e.getMessage().contains('supplementary Unicode'), e.getMessage());
                }
            }
        }
    }
    @IsTest
    static void rejectEmbeddingRestrictionsVariableAndMalformedBounds() {
        System.runAs(fontAdmin()) {
            Blob bytes = DocGenFontTestData.regular();
            String h = EncodingUtil.convertToHex(bytes);
            Integer directory = h.indexOf('4f532f32') / 2;
            Integer osOffset = 0;
            for (Integer i = (directory + 8) * 2; i < (directory + 12) * 2; i++)
                osOffset = osOffset * 16 + '0123456789abcdef'.indexOf(h.substring(i, i + 1));
            for (String flags : new List<String>{ '0002', '0100', '0200' }) {
                try {
                    new DocGenFontInspector(patched(bytes, osOffset + 8, flags)).inspect('Restricted.ttf');
                    System.assert(false);
                } catch (DocGenException e) {
                    System.assert(e.getMessage().contains('restrictions'), e.getMessage());
                }
            }
            Integer gasp = h.indexOf('67617370') / 2;
            System.assert(gasp >= 12);
            try {
                new DocGenFontInspector(patched(bytes, gasp, '66766172')).inspect('Variable.ttf');
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('static TrueType'), e.getMessage());
            }
            try {
                new DocGenFontInspector(patched(bytes, 4, 'ffff')).inspect('Malformed.ttf');
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('table count'), e.getMessage());
            }
        }
    }

    @IsTest
    static void unauthorizedUserCannotManageFonts() {
        Profile profile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'fontqa',
            Email = 'fonts@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Font QA',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/New_York',
            ProfileId = profile.Id,
            Username = 'fontqa' + System.now().getTime() + '@example.invalid'
        );
        insert u;
        System.runAs(u) {
            try {
                DocGenFontController.stageFont('fake.ttf', 'AA==', 'fake', 'license', true);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('permission'));
            }
        }
    }
}
