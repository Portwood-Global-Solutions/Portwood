/**
 * LWC controller for the Command Hub "Email Templates" tab (#193). Lets admins
 * load, edit, preview, test-send, save, and reset the brandable email templates.
 * Rendering itself lives in DocGenEmailTemplateService; this is the admin-facing
 * CRUD + preview surface.
 */
public with sharing class DocGenEmailTemplateController {
    private static final Map<String, String> TYPE_LABELS = new Map<String, String>{
        DocGenEmailTemplateService.TYPE_REQUEST => 'Signature Request (to signer)',
        DocGenEmailTemplateService.TYPE_REMINDER => 'Signature Reminder (to signer)',
        DocGenEmailTemplateService.TYPE_PIN => 'Email Verification Code (to signer)',
        DocGenEmailTemplateService.TYPE_SIGNER_COMPLETED => 'Signer Completed (to sender)',
        DocGenEmailTemplateService.TYPE_ALL_SIGNED => 'All Signatures Complete (to sender)',
        DocGenEmailTemplateService.TYPE_DECLINED => 'Signer Declined (to sender)',
        DocGenEmailTemplateService.TYPE_COMPLETION => 'Completion Confirmation (to signers)'
    };

    // Merge tokens offered in the editor per type (chips the admin can insert).
    private static final Map<String, List<String>> TYPE_TOKENS = new Map<String, List<String>>{
        DocGenEmailTemplateService.TYPE_REQUEST => new List<String>{
            'SignerName',
            'SenderName',
            'CompanyName',
            'DocumentTitle',
            'RoleName',
            'Message',
            'ActionButton',
            'DocumentInfo',
            'SecurityNote',
            'SignatureUrl',
            'ExpirationHours',
            'LogoUrl'
        },
        DocGenEmailTemplateService.TYPE_REMINDER => new List<String>{
            'SignerName',
            'SenderName',
            'CompanyName',
            'DocumentTitle',
            'RoleName',
            'Message',
            'ActionButton',
            'DocumentInfo',
            'SecurityNote',
            'SignatureUrl',
            'ExpirationHours',
            'LogoUrl'
        },
        DocGenEmailTemplateService.TYPE_PIN => new List<String>{
            'VerificationCode',
            'Pin',
            'ExpirationMinutes',
            'CompanyName',
            'LogoUrl'
        },
        DocGenEmailTemplateService.TYPE_SIGNER_COMPLETED => new List<String>{
            'SignerName',
            'RoleName',
            'RequestId',
            'CompanyName',
            'LogoUrl'
        },
        DocGenEmailTemplateService.TYPE_ALL_SIGNED => new List<String>{ 'RequestId', 'CompanyName', 'LogoUrl' },
        DocGenEmailTemplateService.TYPE_DECLINED => new List<String>{
            'SignerName',
            'RoleName',
            'Message',
            'RequestId',
            'CompanyName',
            'LogoUrl'
        },
        DocGenEmailTemplateService.TYPE_COMPLETION => new List<String>{
            'SignerName',
            'DocumentTitle',
            'CompanyName',
            'LogoUrl'
        }
    };

    /** One editable row per type — the stored record's values or the built-in default. */
    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getTemplates() {
        Map<String, DocGen_Email_Template__c> byType = new Map<String, DocGen_Email_Template__c>();
        DocGenFlsGuard.assertAccessible(
            DocGen_Email_Template__c.sObjectType,
            new Set<String>{
                'Type__c',
                'Subject__c',
                'Body_Html__c',
                'Body_Plain__c',
                'Brand_Color__c',
                'Logo_Url__c',
                'Logo_Url_Extended__c',
                'Logo_Asset_Key__c',
                'Logo_Height__c',
                'Footer_Text__c',
                'Layout_Mode__c',
                'Is_Active__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        for (DocGen_Email_Template__c r : [
            SELECT
                Id,
                Name,
                Type__c,
                Subject__c,
                Body_Html__c,
                Body_Plain__c,
                Brand_Color__c,
                Logo_Url__c,
                Logo_Url_Extended__c,
                Logo_Asset_Key__c,
                Logo_Height__c,
                Footer_Text__c,
                Layout_Mode__c,
                Is_Active__c
            FROM DocGen_Email_Template__c
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
        ]) {
            if (r.Type__c != null && !byType.containsKey(r.Type__c)) {
                byType.put(r.Type__c, r);
            }
        }

        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (String type : DocGenEmailTemplateService.ALL_TYPES) {
            DocGen_Email_Template__c r = byType.get(type);
            DocGenEmailTemplateService.TemplateDef def = DocGenEmailTemplateService.builtInDef(type);
            rows.add(
                new Map<String, Object>{
                    'type' => type,
                    'typeLabel' => TYPE_LABELS.get(type),
                    'recordId' => r == null ? null : r.Id,
                    'name' => r == null ? TYPE_LABELS.get(type) : r.Name,
                    'subject' => r == null ? def.subject : r.Subject__c,
                    'bodyHtml' => r == null ? def.bodyHtml : r.Body_Html__c,
                    'bodyPlain' => r == null ? '' : r.Body_Plain__c,
                    'brandColor' => r == null ? '' : r.Brand_Color__c,
                    'logoUrl' => r == null
                        ? ''
                        : (String.isNotBlank(r.Logo_Url_Extended__c) ? r.Logo_Url_Extended__c.trim() : r.Logo_Url__c),
                    'logoAssetKey' => r == null ? '' : r.Logo_Asset_Key__c,
                    'logoHeight' => r == null ? null : r.Logo_Height__c,
                    'footerText' => r == null ? '' : r.Footer_Text__c,
                    'layoutMode' => (r == null ||
                        r.Layout_Mode__c == null)
                        ? DocGenEmailTemplateService.MODE_MANAGED
                        : r.Layout_Mode__c,
                    'isActive' => r == null ? true : r.Is_Active__c,
                    'hasRecord' => r != null,
                    'tokens' => TYPE_TOKENS.get(type)
                }
            );
        }
        return rows;
    }

    /** Upserts a template from editor values. Returns the saved record Id. */
    @AuraEnabled
    public static Id saveTemplate(Map<String, Object> data) {
        String type = (String) data.get('type');
        if (String.isBlank(type) || !TYPE_LABELS.containsKey(type)) {
            throw new AuraHandledException('Unknown email template type.');
        }
        DocGen_Email_Template__c rec = new DocGen_Email_Template__c();
        String recordId = (String) data.get('recordId');
        if (String.isNotBlank(recordId)) {
            rec.Id = (Id) recordId;
        }
        rec.Type__c = type;
        rec.Name = String.isNotBlank((String) data.get('name')) ? (String) data.get('name') : TYPE_LABELS.get(type);
        rec.Subject__c = (String) data.get('subject');
        rec.Body_Html__c = (String) data.get('bodyHtml');
        rec.Body_Plain__c = (String) data.get('bodyPlain');
        rec.Brand_Color__c = (String) data.get('brandColor');
        // Logo_Url__c (platform Url field) is capped at 255 and type-locked in the
        // managed package; the long companion field is authoritative. Mirror short
        // values into the legacy field for anything still reading it.
        String logoUrl = (String) data.get('logoUrl');
        rec.Logo_Url_Extended__c = logoUrl;
        rec.Logo_Url__c = (logoUrl != null && logoUrl.length() <= 255) ? logoUrl : null;
        rec.Logo_Asset_Key__c = (String) data.get('logoAssetKey');
        Object logoHeight = data.get('logoHeight');
        rec.Logo_Height__c = logoHeight == null ? null : Decimal.valueOf(String.valueOf(logoHeight));
        rec.Footer_Text__c = (String) data.get('footerText');
        rec.Layout_Mode__c = (data.get('layoutMode') == DocGenEmailTemplateService.MODE_FULL_HTML)
            ? DocGenEmailTemplateService.MODE_FULL_HTML
            : DocGenEmailTemplateService.MODE_MANAGED;
        rec.Is_Active__c = data.get('isActive') == null ? true : (Boolean) data.get('isActive');

        Set<String> fields = new Set<String>{
            'Type__c',
            'Subject__c',
            'Body_Html__c',
            'Body_Plain__c',
            'Brand_Color__c',
            'Logo_Url__c',
            'Logo_Url_Extended__c',
            'Logo_Asset_Key__c',
            'Logo_Height__c',
            'Footer_Text__c',
            'Layout_Mode__c',
            'Is_Active__c'
        };
        if (rec.Id == null) {
            DocGenFlsGuard.assertCreateable(rec, fields);
        } else {
            DocGenFlsGuard.assertUpdateable(rec, fields);
        }
        try {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.upsert(rec, AccessLevel.SYSTEM_MODE);
        } catch (DmlException e) {
            throw DocGenService.dmlAhe(e, DocGen_Email_Template__c.sObjectType);
        }
        // Publish every {%asset:<key>} the body references while we're in the
        // admin's session — send-time resolution (guest/Automated Process) can
        // only READ deliveries. Best-effort: an unresolvable key never blocks
        // the save (the tag blanks at send and warns in the debug log).
        ensureAssetDeliveriesForBody(rec.Body_Html__c);
        return rec.Id;
    }

    /** Extracts {%asset:<key>} keys from a body and ensures each referenced
     *  asset's latest file has a public delivery. Admin-session only. */
    private static void ensureAssetDeliveriesForBody(String bodyHtml) {
        if (String.isBlank(bodyHtml) || !bodyHtml.contains('{%asset:')) {
            return;
        }
        Set<String> keys = new Set<String>();
        Matcher m = Pattern.compile('\\{%asset:([^}]+)\\}').matcher(bodyHtml);
        while (m.find()) {
            String rawKey = m.group(1).contains(':') ? m.group(1).substringBefore(':') : m.group(1);
            String key = DocGenAssetKeyHandler.normalizeKey(rawKey);
            if (String.isNotBlank(key)) {
                keys.add(key);
            }
        }
        if (keys.isEmpty()) {
            return;
        }
        try {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            for (DocGen_Asset__c a : [
                SELECT Id
                FROM DocGen_Asset__c
                WHERE Asset_Key__c IN :keys
                WITH SYSTEM_MODE
            ]) {
                // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets
                try {
                    resolveAssetPublicUrl(a.Id);
                } catch (Exception perAsset) {
                    System.debug(
                        LoggingLevel.WARN,
                        'Portwood: could not publish asset ' + a.Id + ' for email use: ' + perAsset.getMessage()
                    );
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: asset delivery ensure skipped: ' + e.getMessage());
        }
    }

    /**
     * "Override with Asset File": resolves a Portwood Shared Asset (its latest file
     * version) to a public content-delivery URL that email clients can fetch
     * anonymously, for use as the branded-header logo. Creates a ContentDistribution
     * on first use and reuses it afterwards; PreferencesLinkLatestVersion keeps the
     * URL serving the newest upload when the asset file is replaced. Resolution
     * happens here — at editor-save time, in an admin session — because guest and
     * Automated Process contexts (which SEND the emails) cannot create
     * ContentDistributions.
     */
    @AuraEnabled
    public static String resolveAssetPublicUrl(Id assetId) {
        if (assetId == null) {
            throw DocGenService.ahe('An asset Id is required.');
        }
        DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, new Set<String>{ 'Name' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Asset__c> assets = [
            SELECT
                Id,
                Name,
                (
                    SELECT ContentDocument.LatestPublishedVersionId
                    FROM ContentDocumentLinks
                    ORDER BY ContentDocument.CreatedDate DESC, ContentDocument.Id DESC
                    LIMIT 1
                )
            FROM DocGen_Asset__c
            WHERE Id = :assetId
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets
        if (assets.isEmpty() || assets[0].ContentDocumentLinks == null || assets[0].ContentDocumentLinks.isEmpty()) {
            throw DocGenService.ahe('This asset has no file yet — upload an image to it first.');
        }
        Id cvId = assets[0].ContentDocumentLinks[0].ContentDocument.LatestPublishedVersionId;
        if (cvId == null) {
            throw DocGenService.ahe('This asset has no published file version.');
        }

        if (!DocGenService.isContentDistributionAvailable()) {
            throw DocGenService.ahe(
                'Public links are disabled in this org (Setup → Content Deliveries and Public Links) — enable them to use an asset file as the email logo.'
            );
        }
        DocGenFlsGuard.assertAccessible(
            DocGenService.contentDistributionType(),
            new Set<String>{ 'ContentDownloadUrl', 'ContentVersionId', 'PreferencesExpires' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        String quotedCvId = '\'' + String.escapeSingleQuotes((String) cvId) + '\'';
        List<SObject> existing = Database.query(
            'SELECT Id, ContentDownloadUrl, PreferencesExpires FROM ContentDistribution WHERE ContentVersionId = ' +
                quotedCvId +
                ' WITH SYSTEM_MODE LIMIT 1'
        );
        try {
            if (!existing.isEmpty()) {
                if ((Boolean) existing[0].get('PreferencesExpires') == true) {
                    // A delivery created elsewhere (e.g. the signing flow) may carry an
                    // expiry — a logo link must not go dark, so clear it.
                    SObject fix = DocGenService.contentDistributionType().newSObject((Id) existing[0].get('Id'));
                    fix.put('PreferencesExpires', false);
                    fix.put('ExpiryDate', null);
                    DocGenFlsGuard.assertUpdateable(fix, new Set<String>{ 'PreferencesExpires', 'ExpiryDate' });
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    Database.update(fix, AccessLevel.SYSTEM_MODE);
                }
                return (String) existing[0].get('ContentDownloadUrl');
            }

            SObject cd = DocGenService.newContentDistribution(
                new Map<String, Object>{
                    'Name' => 'Portwood Asset - ' + assets[0].Name,
                    'ContentVersionId' => cvId,
                    'PreferencesAllowViewInBrowser' => true,
                    'PreferencesLinkLatestVersion' => true,
                    'PreferencesAllowOriginalDownload' => true,
                    'PreferencesExpires' => false,
                    'PreferencesNotifyOnVisit' => false,
                    'PreferencesAllowPDFDownload' => false
                }
            );
            DocGenFlsGuard.assertCreateable(
                cd,
                new Set<String>{
                    'Name',
                    'ContentVersionId',
                    'PreferencesAllowViewInBrowser',
                    'PreferencesLinkLatestVersion',
                    'PreferencesAllowOriginalDownload',
                    'PreferencesExpires',
                    'PreferencesNotifyOnVisit',
                    'PreferencesAllowPDFDownload'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(cd, AccessLevel.SYSTEM_MODE);
            // ContentDownloadUrl is generated server-side — re-query for it.
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<SObject> created = Database.query(
                'SELECT ContentDownloadUrl FROM ContentDistribution WHERE Id = \'' +
                    String.escapeSingleQuotes((String) cd.get('Id')) +
                    '\' WITH SYSTEM_MODE LIMIT 1'
            );
            if (created.isEmpty() || String.isBlank((String) created[0].get('ContentDownloadUrl'))) {
                throw DocGenService.ahe(
                    'The public file link was created but has no download URL yet — try again in a moment.'
                );
            }
            return (String) created[0].get('ContentDownloadUrl');
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw DocGenService.ahe(
                e,
                'Could not create a public link for this asset. Check that Content Deliveries are enabled (Setup → Content Deliveries and Public Links).'
            );
        }
    }

    /** The built-in default subject + body for a type (for the editor "Reset" action; not persisted). */
    @AuraEnabled
    public static Map<String, Object> getDefault(String type) {
        DocGenEmailTemplateService.TemplateDef def = DocGenEmailTemplateService.builtInDef(type);
        return new Map<String, Object>{ 'subject' => def.subject, 'bodyHtml' => def.bodyHtml };
    }

    /** Renders a preview from unsaved editor values using realistic sample tokens. */
    @AuraEnabled
    public static DocGenEmailTemplateService.RenderedEmail renderPreview(Map<String, Object> data) {
        // Editor session is admin — publish any newly-typed {%asset:} references
        // so the preview (and the eventual sends) can resolve them.
        ensureAssetDeliveriesForBody((String) data.get('bodyHtml'));
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.renderWith(
            buildDef(data),
            sampleTokens((String) data.get('type')),
            null
        );
        return r;
    }

    /** Sends a test email of the unsaved editor values to the given address via the OWA. */
    @AuraEnabled
    public static void sendTest(Map<String, Object> data, String toAddress) {
        if (String.isBlank(toAddress)) {
            throw new AuraHandledException('Enter a recipient email address for the test.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        String owaId = settings == null ? null : settings.Signature_OWA_Id__c;
        if (String.isBlank(owaId)) {
            throw new AuraHandledException(
                'No Org-Wide Email Address is configured. Set one under Portwood > Signatures before sending a test.'
            );
        }
        DocGenEmailTemplateService.RenderedEmail rendered = DocGenEmailTemplateService.renderWith(
            buildDef(data),
            sampleTokens((String) data.get('type')),
            null
        );
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ toAddress });
        email.setSubject('[TEST] ' + rendered.subject);
        email.setHtmlBody(rendered.htmlBody);
        if (String.isNotBlank(rendered.plainBody)) {
            email.setPlainTextBody(rendered.plainBody);
        }
        email.setSaveAsActivity(false);
        email.setOrgWideEmailAddressId(owaId);
        List<Messaging.SendEmailResult> results = Messaging.sendEmail(
            new List<Messaging.SingleEmailMessage>{ email },
            false
        );
        if (!results.isEmpty() && !results[0].isSuccess()) {
            throw new AuraHandledException('Test send failed: ' + results[0].getErrors()[0].getMessage());
        }
    }

    private static DocGenEmailTemplateService.TemplateDef buildDef(Map<String, Object> data) {
        DocGenEmailTemplateService.TemplateDef def = new DocGenEmailTemplateService.TemplateDef();
        def.type = (String) data.get('type');
        def.subject = (String) data.get('subject');
        def.bodyHtml = (String) data.get('bodyHtml');
        def.bodyPlain = (String) data.get('bodyPlain');
        def.brandColorOverride = (String) data.get('brandColor');
        def.logoUrlOverride = (String) data.get('logoUrl');
        def.logoAssetKey = (String) data.get('logoAssetKey');
        Object previewLogoHeight = data.get('logoHeight');
        def.logoHeight = previewLogoHeight == null ? null : Integer.valueOf(String.valueOf(previewLogoHeight));
        def.footerTextOverride = (String) data.get('footerText');
        def.layoutMode = (data.get('layoutMode') == DocGenEmailTemplateService.MODE_FULL_HTML)
            ? DocGenEmailTemplateService.MODE_FULL_HTML
            : DocGenEmailTemplateService.MODE_MANAGED;
        return def;
    }

    /** Realistic placeholder values so previews/tests look like a real send. */
    private static Map<String, String> sampleTokens(String type) {
        return new Map<String, String>{
            'SignerName' => 'Jordan Rivera',
            'SignerEmail' => 'jordan.rivera@example.com',
            'RoleName' => 'Authorized Signer',
            'DocumentTitle' => 'Master Services Agreement',
            'SenderName' => UserInfo.getName(),
            'SignatureUrl' => 'https://example.com/sign?token=SAMPLE-TOKEN',
            'ExpirationHours' => String.valueOf(DocGenSignatureExpiry.defaultHours()),
            'ExpirationMinutes' => '15',
            'Pin' => '481627',
            'RequestId' => 'a0X000000000SAMPLE',
            'Message' => DocGenEmailTemplateService.defaultMessage(type)
        };
    }
}
