/**
 * Tests for the configurable email template system (#193):
 * DocGenEmailTemplateService (render engine + built-in fallback + escaping +
 * branding + send-time override), DocGenEmailTemplateController (admin CRUD +
 * preview + test send), and DocGenEmailTemplateInstall (idempotent seeding).
 */
@IsTest
private class DocGenEmailTemplateTest {
    // ---- Service: built-in defaults render for every type with no records ----
    @IsTest
    static void builtInDefaults_renderForAllTypes() {
        DocGenEmailTemplateService.clearCache();
        Test.startTest();
        for (String type : DocGenEmailTemplateService.ALL_TYPES) {
            DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(type, sampleTokens(type));
            System.assert(String.isNotBlank(r.subject), 'subject for ' + type);
            System.assert(String.isNotBlank(r.htmlBody), 'html for ' + type);
            System.assert(r.htmlBody.contains('<!DOCTYPE html>'), 'chrome wrap for ' + type);
            System.assert(String.isNotBlank(r.plainBody), 'plain for ' + type);
            // No unresolved tokens should leak.
            System.assert(!r.htmlBody.contains('{'), 'no leftover token in ' + type + ': ' + r.htmlBody);
            System.assert(!r.subject.contains('{'), 'no leftover token in subject ' + type);
        }
        Test.stopTest();
    }

    // ---- Service: request email includes the signing button + URL ----
    @IsTest
    static void requestEmail_hasActionButtonAndUrl() {
        DocGenEmailTemplateService.clearCache();
        Map<String, String> tk = sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST);
        tk.put('SignatureUrl', 'https://sign.example.com/?token=ABC123');
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            tk
        );
        System.assert(r.htmlBody.contains('Review &amp; Sign Document'), 'button label present');
        System.assert(r.htmlBody.contains('https://sign.example.com/?token=ABC123'), 'signing url present');
        System.assert(r.plainBody.contains('https://sign.example.com/?token=ABC123'), 'url in plain part');
    }

    // ---- Service: merge values are HTML-escaped (no injection) ----
    @IsTest
    static void mergeValues_areEscaped() {
        DocGenEmailTemplateService.clearCache();
        Map<String, String> tk = sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST);
        tk.put('SignerName', '<script>alert(1)</script>');
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            tk
        );
        System.assert(!r.htmlBody.contains('<script>alert(1)</script>'), 'raw script must not survive');
        System.assert(r.htmlBody.contains('&lt;script&gt;'), 'name should be escaped');
    }

    // ---- Service: send-time message override replaces {Message} ----
    @IsTest
    static void messageOverride_replacesMessage() {
        DocGenEmailTemplateService.clearCache();
        String custom = 'Please review and sign before Friday — thanks!';
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST),
            custom
        );
        System.assert(r.htmlBody.contains('Please review and sign before Friday'), 'override prose present');
    }

    // ---- Service: a stored record overrides the built-in; branding override applies ----
    @IsTest
    static void storedRecord_overridesBuiltIn() {
        insert new DocGen_Email_Template__c(
            Name = 'Custom Request',
            Type__c = DocGenEmailTemplateService.TYPE_REQUEST,
            Subject__c = 'Custom subject for {DocumentTitle}',
            Body_Html__c = '<p>Custom body for {SignerName}. {ActionButton}</p>',
            Brand_Color__c = '#FF0000',
            Is_Active__c = true
        );
        DocGenEmailTemplateService.clearCache();
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST)
        );
        System.assert(r.subject.startsWith('Custom subject for'), 'stored subject used: ' + r.subject);
        System.assert(r.htmlBody.contains('Custom body for'), 'stored body used');
        System.assert(r.htmlBody.contains('#FF0000'), 'brand override applied');
    }

    // ---- Long logo URLs (Logo_Url_Extended__c beats the 255-capped Url field) ----
    @IsTest
    static void controller_save_longLogoUrl_roundTripsAndRenders() {
        String longUrl = 'https://files.example.com/sfc/dist/version/download/' + 'x'.repeat(400) + '/logo.png';
        Map<String, Object> data = new Map<String, Object>{
            'type' => DocGenEmailTemplateService.TYPE_REQUEST,
            'subject' => 'Hi',
            'bodyHtml' => '<p>x {ActionButton}</p>',
            'logoUrl' => longUrl,
            'isActive' => true
        };
        Test.startTest();
        Id recId = DocGenEmailTemplateController.saveTemplate(data);
        Test.stopTest();

        DocGen_Email_Template__c saved = [
            SELECT Logo_Url__c, Logo_Url_Extended__c
            FROM DocGen_Email_Template__c
            WHERE Id = :recId
        ];
        System.assertEquals(longUrl, saved.Logo_Url_Extended__c, 'Long URL stored in the extended field');
        System.assertEquals(null, saved.Logo_Url__c, 'Over-255 URL must not touch the capped legacy field');

        for (Map<String, Object> row : DocGenEmailTemplateController.getTemplates()) {
            if (row.get('type') == DocGenEmailTemplateService.TYPE_REQUEST) {
                System.assertEquals(longUrl, row.get('logoUrl'), 'Editor round-trips the long URL');
            }
        }

        DocGenEmailTemplateService.clearCache();
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST)
        );
        System.assert(r.htmlBody.contains('logo.png'), 'Renderer uses the long logo URL: ' + r.htmlBody.left(300));
    }

    @IsTest
    static void controller_save_shortLogoUrl_mirrorsLegacyField() {
        Map<String, Object> data = new Map<String, Object>{
            'type' => DocGenEmailTemplateService.TYPE_PIN,
            'subject' => 'Hi',
            'bodyHtml' => '<p>{VerificationCode}</p>',
            'logoUrl' => 'https://example.com/logo.png'
        };
        Id recId = DocGenEmailTemplateController.saveTemplate(data);
        DocGen_Email_Template__c saved = [
            SELECT Logo_Url__c, Logo_Url_Extended__c
            FROM DocGen_Email_Template__c
            WHERE Id = :recId
        ];
        System.assertEquals('https://example.com/logo.png', saved.Logo_Url_Extended__c);
        System.assertEquals(
            'https://example.com/logo.png',
            saved.Logo_Url__c,
            'Short URLs mirror into the legacy field for anything still reading it'
        );
    }

    // ---- "Override with Asset File": asset → public delivery URL ----
    @IsTest
    static void controller_resolveAssetPublicUrl() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Logo Test Asset', Asset_Key__c = 'logo-test');
        insert asset;
        ContentVersion cv = new ContentVersion(
            Title = 'logo',
            PathOnClient = 'logo.png',
            VersionData = Blob.valueOf('fake png bytes'),
            FirstPublishLocationId = asset.Id
        );
        insert cv;

        Test.startTest();
        String url;
        String failureMsg;
        try {
            url = DocGenEmailTemplateController.resolveAssetPublicUrl(asset.Id);
            // Second call must reuse the same distribution, not mint another.
            String again = DocGenEmailTemplateController.resolveAssetPublicUrl(asset.Id);
            System.assertEquals(url, again, 'Repeat resolution reuses the existing public link');
        } catch (AuraHandledException e) {
            // Orgs without Content Deliveries enabled can't create distributions —
            // the contract then is a friendly, actionable message (never raw DML).
            failureMsg = e.getMessage();
        }
        Test.stopTest();

        if (url != null) {
            System.assert(url.startsWith('http'), 'Public download URL returned: ' + url);
            System.assertEquals(
                1,
                Database.countQuery(
                    'SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = \'' +
                        String.escapeSingleQuotes((String) cv.Id) +
                        '\''
                ),
                'Exactly one distribution per asset version'
            );
        } else {
            System.assert(
                failureMsg != null && failureMsg.contains('Content Deliveries'),
                'Friendly guidance expected when deliveries are unavailable; got: ' + failureMsg
            );
        }
    }

    @IsTest
    static void controller_resolveAssetPublicUrl_noFileIsFriendly() {
        DocGen_Asset__c bare = new DocGen_Asset__c(Name = 'Empty Asset', Asset_Key__c = 'empty-asset');
        insert bare;
        Boolean caught = false;
        try {
            DocGenEmailTemplateController.resolveAssetPublicUrl(bare.Id);
        } catch (AuraHandledException e) {
            caught = true;
            System.assert(e.getMessage().contains('upload an image'), 'Actionable message; got: ' + e.getMessage());
        }
        System.assert(caught, 'Asset without a file must be rejected with guidance');
    }

    // ---- {LogoUrl} token + asset-linked logo + logo height ----
    @IsTest
    static void logoUrlToken_resolvesInCustomHtml() {
        insert new DocGen_Email_Template__c(
            Name = 'Custom HTML w/ logo token',
            Type__c = DocGenEmailTemplateService.TYPE_REQUEST,
            Subject__c = 'Hi',
            Body_Html__c = '<html><body><img src="{LogoUrl}" style="height:60px"/>{ActionButton}</body></html>',
            Layout_Mode__c = DocGenEmailTemplateService.MODE_FULL_HTML,
            Logo_Url_Extended__c = 'https://cdn.example.com/brand/logo-v2.png',
            Is_Active__c = true
        );
        DocGenEmailTemplateService.clearCache();
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST)
        );
        System.assert(
            r.htmlBody.contains('src="https://cdn.example.com/brand/logo-v2.png"'),
            '{LogoUrl} resolves to the effective logo in full custom HTML: ' + r.htmlBody.left(300)
        );
    }

    @IsTest
    static void logoHeight_scalesChrome() {
        insert new DocGen_Email_Template__c(
            Name = 'Tall logo',
            Type__c = DocGenEmailTemplateService.TYPE_REQUEST,
            Subject__c = 'Hi',
            Body_Html__c = '<p>x {ActionButton}</p>',
            Logo_Url_Extended__c = 'https://cdn.example.com/logo.png',
            Logo_Height__c = 96,
            Is_Active__c = true
        );
        DocGenEmailTemplateService.clearCache();
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST)
        );
        System.assert(
            r.htmlBody.contains('max-height:96px') && r.htmlBody.contains('max-width:400px'),
            'Logo height honored with proportional width cap: ' + r.htmlBody.left(600)
        );
    }

    @IsTest
    static void logoAssetKey_resolvesLatestFileAtSendTime() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Brand Logo', Asset_Key__c = 'brand-logo');
        insert asset;
        ContentVersion cv = new ContentVersion(
            Title = 'logo-v1',
            PathOnClient = 'logo-v1.png',
            VersionData = Blob.valueOf('v1 bytes'),
            FirstPublishLocationId = asset.Id
        );
        insert cv;

        String publicUrl;
        try {
            publicUrl = DocGenEmailTemplateController.resolveAssetPublicUrl(asset.Id);
        } catch (AuraHandledException e) {
            return; // org without Content Deliveries — resolution path covered elsewhere
        }

        insert new DocGen_Email_Template__c(
            Name = 'Asset-linked logo',
            Type__c = DocGenEmailTemplateService.TYPE_REQUEST,
            Subject__c = 'Hi',
            Body_Html__c = '<p>x {ActionButton}</p>',
            Logo_Asset_Key__c = 'brand-logo',
            Logo_Url_Extended__c = 'https://stale.example.com/old-logo.png',
            Is_Active__c = true
        );
        DocGenEmailTemplateService.clearCache();
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST)
        );
        System.assert(
            r.htmlBody.contains(publicUrl.escapeHtml4()) || r.htmlBody.contains(publicUrl),
            'Asset link beats the stored URL at send time: ' + r.htmlBody.left(600)
        );
        System.assert(
            !r.htmlBody.contains('stale.example.com'),
            'Stored URL is only the fallback when an asset is linked'
        );
    }

    @IsTest
    static void addAssetVersion_carriesDeliveryForwardToReplacementFile() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'CF Logo', Asset_Key__c = 'cf-logo');
        insert asset;
        ContentVersion v1 = new ContentVersion(
            Title = 'v1',
            PathOnClient = 'v1.png',
            VersionData = Blob.valueOf('v1'),
            FirstPublishLocationId = asset.Id
        );
        insert v1;
        try {
            DocGenEmailTemplateController.resolveAssetPublicUrl(asset.Id);
        } catch (AuraHandledException e) {
            return; // org without Content Deliveries
        }

        // Replace the asset image the way the Assets tab does: a NEW document.
        ContentVersion v2 = new ContentVersion(Title = 'v2', PathOnClient = 'v2.png', VersionData = Blob.valueOf('v2'));
        insert v2;
        Test.startTest();
        Id newLatestCvId = DocGenController.addAssetVersion(asset.Id, v2.Id);
        Test.stopTest();

        Integer carryCount = Database.countQuery(
            'SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = \'' +
                String.escapeSingleQuotes((String) newLatestCvId) +
                '\''
        );
        if (DocGenService.isContentDistributionAvailable()) {
            System.assertEquals(
                1,
                carryCount,
                'Replacing a published asset image must publish the NEW file too, so ' +
                'send-time logo resolution keeps working (guest senders cannot create deliveries)'
            );
        } else {
            System.assertEquals(0, carryCount, 'No deliveries when the feature is disabled');
        }
    }

    // ---- {%asset:key} tags in email bodies resolve to public delivery URLs ----
    @IsTest
    static void assetTags_resolveInEmailBody() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Footer Banner', Asset_Key__c = 'footer-banner');
        insert asset;
        insert new ContentVersion(
            Title = 'banner',
            PathOnClient = 'banner.png',
            VersionData = Blob.valueOf('banner bytes'),
            FirstPublishLocationId = asset.Id
        );

        Map<String, Object> data = new Map<String, Object>{
            'type' => DocGenEmailTemplateService.TYPE_REQUEST,
            'subject' => 'Hi',
            'bodyHtml' => '<html><body>' +
            '<img src="{%asset:footer-banner}" style="height:40px"/>' +
            '<img src="{%asset:no-such-asset}"/>' +
            '{ActionButton}</body></html>',
            'layoutMode' => DocGenEmailTemplateService.MODE_FULL_HTML,
            'isActive' => true
        };
        Test.startTest();
        // saveTemplate publishes the referenced asset (admin session) so send-time
        // resolution — read-only — finds the delivery.
        DocGenEmailTemplateController.saveTemplate(data);
        Test.stopTest();

        List<SObject> dists = new List<SObject>();
        if (DocGenService.isContentDistributionAvailable()) {
            dists = Database.query(
                'SELECT ContentDownloadUrl FROM ContentDistribution WHERE Name LIKE \'Portwood Asset - Footer Banner%\''
            );
        }
        if (dists.isEmpty()) {
            return; // org without Content Deliveries — publish path covered elsewhere
        }

        DocGenEmailTemplateService.clearCache();
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST)
        );
        System.assert(
            !r.htmlBody.contains('{%asset:'),
            'Every asset tag must resolve or blank — none may leak: ' + r.htmlBody
        );
        String expectedUrl = (String) dists[0].get('ContentDownloadUrl');
        String expected = expectedUrl.escapeHtml4();
        System.assert(
            r.htmlBody.contains(expected) || r.htmlBody.contains(expectedUrl),
            'Known asset tag resolves to its public delivery URL: ' + r.htmlBody
        );
        System.assert(r.htmlBody.contains('src=""'), 'Unknown asset key blanks cleanly');
    }

    // ---- Service: invalid brand color falls back to the safe default ----
    @IsTest
    static void invalidBrandColor_fallsBackSafe() {
        // The field caps at 7 chars (first defense); safeBrandColor rejects any
        // non-#RRGGBB value (second defense) and substitutes the safe default.
        insert new DocGen_Email_Template__c(
            Name = 'Bad Color',
            Type__c = DocGenEmailTemplateService.TYPE_COMPLETION,
            Brand_Color__c = '#ZZ000',
            Is_Active__c = true
        );
        DocGenEmailTemplateService.clearCache();
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_COMPLETION,
            sampleTokens(DocGenEmailTemplateService.TYPE_COMPLETION)
        );
        System.assert(!r.htmlBody.contains('#ZZ000'), 'invalid color must not survive');
        System.assert(r.htmlBody.contains('#1589EE'), 'safe default color used');
    }

    // ---- Install: seeding is idempotent ----
    @IsTest
    static void seedDefaults_isIdempotent() {
        Test.startTest();
        Integer first = DocGenEmailTemplateInstall.seedDefaults();
        Integer second = DocGenEmailTemplateInstall.seedDefaults();
        Test.stopTest();
        System.assertEquals(DocGenEmailTemplateService.ALL_TYPES.size(), first, 'seeds one per type');
        System.assertEquals(0, second, 'second run inserts nothing');
        System.assertEquals(
            DocGenEmailTemplateService.ALL_TYPES.size(),
            [SELECT COUNT() FROM DocGen_Email_Template__c],
            'one record per type total'
        );
    }

    // ---- Install handler entry point ----
    @IsTest
    static void onInstall_seeds() {
        Test.startTest();
        new DocGenEmailTemplateInstall().onInstall(null);
        Test.stopTest();
        System.assertEquals(
            DocGenEmailTemplateService.ALL_TYPES.size(),
            [SELECT COUNT() FROM DocGen_Email_Template__c]
        );
    }

    // ---- Controller: getTemplates returns one row per type ----
    @IsTest
    static void controller_getTemplates_rowPerType() {
        List<Map<String, Object>> rows = DocGenEmailTemplateController.getTemplates();
        System.assertEquals(DocGenEmailTemplateService.ALL_TYPES.size(), rows.size());
        for (Map<String, Object> row : rows) {
            System.assert(String.isNotBlank((String) row.get('subject')), 'row has subject');
            System.assert(row.get('tokens') != null, 'row has tokens');
        }
    }

    // ---- Controller: save then re-read reflects the edit ----
    @IsTest
    static void controller_save_and_reload() {
        Map<String, Object> data = new Map<String, Object>{
            'type' => DocGenEmailTemplateService.TYPE_PIN,
            'name' => 'My PIN email',
            'subject' => 'Your code is here',
            'bodyHtml' => '<p>{VerificationCode}</p>',
            'isActive' => true
        };
        Test.startTest();
        Id newId = DocGenEmailTemplateController.saveTemplate(data);
        // Update path
        data.put('recordId', newId);
        data.put('subject', 'Updated subject');
        Id sameId = DocGenEmailTemplateController.saveTemplate(data);
        Test.stopTest();
        System.assertEquals(newId, sameId, 'upsert keeps the same record');
        DocGen_Email_Template__c rec = [SELECT Subject__c FROM DocGen_Email_Template__c WHERE Id = :newId];
        System.assertEquals('Updated subject', rec.Subject__c);
    }

    // Oversized Logo URL Override must surface a friendly "too long" message,
    // not the raw DmlException (which renders as "[object Object]" in the LWC).
    @IsTest
    static void controller_save_oversized_logo_url_friendly_error() {
        // URLs past the extended field's 32,768-char cap still get the friendly
        // "too long" treatment instead of a raw DmlException / [object Object].
        // (URLs between 256 and 32,768 chars are a supported feature now — see
        // controller_save_longLogoUrl_roundTripsAndRenders.)
        Map<String, Object> data = new Map<String, Object>{
            'type' => DocGenEmailTemplateService.TYPE_REQUEST,
            'subject' => 'Hi',
            'bodyHtml' => '<p>x</p>',
            'logoUrl' => 'https://example.com/' + 'a'.repeat(33000)
        };
        Boolean caught = false;
        String message;
        Test.startTest();
        try {
            DocGenEmailTemplateController.saveTemplate(data);
        } catch (AuraHandledException e) {
            caught = true;
            message = e.getMessage();
        }
        Test.stopTest();
        System.assert(caught, 'Oversized logo URL must throw AuraHandledException');
        System.assert(
            message.contains('32768') && message.containsIgnoreCase('too long'),
            'Message must name the max length; got: ' + message
        );
    }

    // ---- Controller: getDefault + renderPreview ----
    @IsTest
    static void controller_default_and_preview() {
        Map<String, Object> def = DocGenEmailTemplateController.getDefault(DocGenEmailTemplateService.TYPE_REQUEST);
        System.assert(String.isNotBlank((String) def.get('bodyHtml')));

        Map<String, Object> data = new Map<String, Object>{
            'type' => DocGenEmailTemplateService.TYPE_REQUEST,
            'subject' => 'Preview {DocumentTitle}',
            'bodyHtml' => '<p>Hi {SignerName} {ActionButton}</p>'
        };
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateController.renderPreview(data);
        System.assert(r.htmlBody.contains('Jordan Rivera'), 'sample signer name rendered');
        System.assert(r.subject.contains('Master Services Agreement'), 'sample doc title in subject');
    }

    // ---- Controller: sendTest guards on missing OWA / sends when one exists ----
    @IsTest
    static void controller_sendTest_owaGuard() {
        Map<String, Object> data = new Map<String, Object>{
            'type' => DocGenEmailTemplateService.TYPE_REQUEST,
            'subject' => 'x',
            'bodyHtml' => '<p>{ActionButton}</p>'
        };
        List<OrgWideEmailAddress> owas = [SELECT Id FROM OrgWideEmailAddress LIMIT 1];
        Test.startTest();
        if (owas.isEmpty()) {
            // No OWA configured → the guard should reject the test send.
            Boolean threw = false;
            try {
                DocGenEmailTemplateController.sendTest(data, 'someone@example.com');
            } catch (Exception e) {
                threw = true;
            }
            System.assert(threw, 'sendTest must reject when no OWA is configured');
        } else {
            insert new DocGen_Settings__c(
                SetupOwnerId = UserInfo.getOrganizationId(),
                Signature_OWA_Id__c = owas[0].Id
            );
            DocGenEmailTemplateController.sendTest(data, 'someone@example.com');
        }
        // Empty recipient always rejected.
        Boolean blankThrew = false;
        try {
            DocGenEmailTemplateController.sendTest(data, '');
        } catch (Exception e) {
            blankThrew = true;
        }
        System.assert(blankThrew, 'blank recipient rejected');
        Test.stopTest();
    }

    // ---- Email service: the send path bails cleanly with no OWA ----
    @IsTest
    static void emailService_noOwa_setsStatus() {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Status__c = 'Sent');
        insert req;
        DocGenEmailTemplateService.clearCache();
        Test.startTest();
        DocGenSignatureEmailService.sendSignatureRequestEmails(
            new List<DocGenSignatureEmailService.SignerEmail>{
                new DocGenSignatureEmailService.SignerEmail('A', 'a@example.com', 'Signer', 'https://x/y', null)
            },
            'Doc',
            req.Id
        );
        Test.stopTest();
        DocGen_Signature_Request__c after = [
            SELECT Email_Status__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :req.Id
        ];
        System.assert(
            after.Email_Status__c != null && after.Email_Status__c.contains('Org-Wide Email Address'),
            'no-OWA status surfaced: ' + after.Email_Status__c
        );
    }

    // ---- #208: per-template default message resolution ----
    @IsTest
    static void templateDefaultMessage_resolvesFromRequestTemplate() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Quote Template',
            Base_Object_API__c = 'Account',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Default_Email_Message__c = 'Please see the attached proposal — reply with any questions.'
        );
        insert tpl;
        DocGen_Signature_Request__c withTpl = new DocGen_Signature_Request__c(Status__c = 'Sent', Template__c = tpl.Id);
        DocGen_Signature_Request__c noTpl = new DocGen_Signature_Request__c(Status__c = 'Sent');
        insert new List<DocGen_Signature_Request__c>{ withTpl, noTpl };

        Test.startTest();
        String resolved = DocGenSignatureEmailService.templateDefaultMessage(withTpl.Id);
        String withoutTemplate = DocGenSignatureEmailService.templateDefaultMessage(noTpl.Id);
        String nullRequest = DocGenSignatureEmailService.templateDefaultMessage(null);
        Test.stopTest();

        System.assertEquals(
            'Please see the attached proposal — reply with any questions.',
            resolved,
            'template default must resolve through the request lookup'
        );
        System.assertEquals(null, withoutTemplate, 'doc-based request (no template) yields null');
        System.assertEquals(null, nullRequest, 'null requestId yields null');
    }

    // ---- #208: blank template default falls through to the type default ----
    @IsTest
    static void templateDefaultMessage_blankFieldYieldsNull() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'No Default Template',
            Base_Object_API__c = 'Account',
            Type__c = 'HTML',
            Output_Format__c = 'PDF'
        );
        insert tpl;
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Status__c = 'Sent', Template__c = tpl.Id);
        insert req;
        System.assert(
            String.isBlank(DocGenSignatureEmailService.templateDefaultMessage(req.Id)),
            'blank field must not shadow the generic type default'
        );
    }

    // ---- Service: Full HTML mode sends the admin's document with no chrome ----
    @IsTest
    static void fullHtmlMode_skipsChrome() {
        insert new DocGen_Email_Template__c(
            Name = 'Raw Request',
            Type__c = DocGenEmailTemplateService.TYPE_REQUEST,
            Layout_Mode__c = DocGenEmailTemplateService.MODE_FULL_HTML,
            Subject__c = 'Raw {DocumentTitle}',
            Body_Html__c = '<div id="mine">Hi {SignerName} {ActionButton}</div>',
            Is_Active__c = true
        );
        DocGenEmailTemplateService.clearCache();
        Map<String, String> tk = sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST);
        tk.put('SignatureUrl', 'https://sign.example.com/?token=RAW');
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_REQUEST,
            tk
        );
        System.assert(r.htmlBody.startsWith('<div id="mine">'), 'admin markup is the document root: ' + r.htmlBody);
        System.assert(r.htmlBody.contains('Jordan Rivera'), 'merge token resolved in full HTML');
        System.assert(r.htmlBody.contains('https://sign.example.com/?token=RAW'), 'action button widget resolved');
        System.assert(!r.htmlBody.contains('Powered by Portwood'), 'no Portwood chrome footer in full HTML');
        System.assert(!r.htmlBody.contains('max-width:600px'), 'no Portwood chrome wrapper in full HTML');
    }

    // ---- Service: per-send subject override resolves tokens ----
    @IsTest
    static void renderSubject_resolvesTokens() {
        String out = DocGenEmailTemplateService.renderSubject(
            'Please sign {DocumentTitle}, {SignerName}',
            sampleTokens(DocGenEmailTemplateService.TYPE_REQUEST)
        );
        System.assertEquals('Please sign Master Services Agreement, Jordan Rivera', out);
    }

    // ---- Controller: layoutMode round-trips through save + reload ----
    @IsTest
    static void controller_layoutMode_roundTrips() {
        Map<String, Object> data = new Map<String, Object>{
            'type' => DocGenEmailTemplateService.TYPE_COMPLETION,
            'subject' => 'Done',
            'bodyHtml' => '<html><body>Thanks {SignerName}</body></html>',
            'layoutMode' => DocGenEmailTemplateService.MODE_FULL_HTML,
            'isActive' => true
        };
        Test.startTest();
        DocGenEmailTemplateController.saveTemplate(data);
        // Preview from unsaved full-HTML values skips chrome too.
        DocGenEmailTemplateService.RenderedEmail pv = DocGenEmailTemplateController.renderPreview(data);
        Test.stopTest();
        System.assert(!pv.htmlBody.contains('Powered by Portwood'), 'full-HTML preview has no chrome');

        List<Map<String, Object>> rows = DocGenEmailTemplateController.getTemplates();
        for (Map<String, Object> row : rows) {
            if (row.get('type') == DocGenEmailTemplateService.TYPE_COMPLETION) {
                System.assertEquals(
                    DocGenEmailTemplateService.MODE_FULL_HTML,
                    (String) row.get('layoutMode'),
                    'saved layoutMode round-trips'
                );
            }
        }
    }

    // ---- helpers ----
    private static Map<String, String> sampleTokens(String type) {
        return new Map<String, String>{
            'SignerName' => 'Jordan Rivera',
            'RoleName' => 'Signer',
            'DocumentTitle' => 'Master Services Agreement',
            'SenderName' => 'Casey Sender',
            'SignatureUrl' => 'https://example.com/sign?token=SAMPLE',
            'ExpirationHours' => '48',
            'ExpirationMinutes' => '15',
            'Pin' => '481627',
            'RequestId' => 'a0X000000000SAMPLE',
            'Message' => DocGenEmailTemplateService.defaultMessage(type)
        };
    }
}
