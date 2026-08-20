/**
 * Central rendering engine for every Portwood signature/notification email (#193).
 *
 * Outbound emails are record-driven: an admin defines one active
 * DocGen_Email_Template__c per Type__c (subject + rich-text HTML body +
 * optional branding overrides) on the Command Hub "Email Templates" tab.
 * At send time the relevant send site asks this service to render the
 * {subject, htmlBody, plainBody} for a type given a token map.
 *
 * OUT-OF-THE-BOX GUARANTEE: if no active record exists for a type (fresh
 * install before the post-install seed runs, or an admin deleted one), the
 * service renders a BUILT-IN default that mirrors the markup Portwood has
 * always shipped. Any failure reading the record store also falls back to the
 * built-in. Email therefore never silently breaks.
 *
 * The admin body is SIMPLE rich text. Structural, branded, or security-critical
 * pieces are SYSTEM WIDGETS the admin places as tokens ({ActionButton},
 * {DocumentInfo}, {SecurityNote}, {VerificationCode}) so they survive the
 * rich-text editor round-trip and the signing link can never be removed.
 *
 * Merge VALUES are HTML-escaped before insertion; the body HTML itself is
 * author-trusted (admin-authored via the editor / built-in default). The
 * send-time message override flows in as the {Message} token value only — it
 * cannot alter the branded chrome or drop the action button.
 */
global with sharing class DocGenEmailTemplateService {
    // Type__c picklist values (kept in one place; mirrored by the seed + LWC).
    global static final String TYPE_REQUEST = 'Signature_Request';
    global static final String TYPE_REMINDER = 'Signature_Reminder';
    global static final String TYPE_PIN = 'Verification_PIN';
    global static final String TYPE_SIGNER_COMPLETED = 'Signer_Completed';
    global static final String TYPE_ALL_SIGNED = 'All_Signed';
    global static final String TYPE_DECLINED = 'Signer_Declined';
    global static final String TYPE_COMPLETION = 'Completion_Confirmation';

    global static final List<String> ALL_TYPES = new List<String>{
        TYPE_REQUEST,
        TYPE_REMINDER,
        TYPE_PIN,
        TYPE_SIGNER_COMPLETED,
        TYPE_ALL_SIGNED,
        TYPE_DECLINED,
        TYPE_COMPLETION
    };

    private static final String DEFAULT_BRAND = '#1589EE';

    // Layout_Mode__c values.
    global static final String MODE_MANAGED = 'Managed';
    global static final String MODE_FULL_HTML = 'Full_Html';

    /** The rendered, ready-to-send parts for one email. */
    global class RenderedEmail {
        @AuraEnabled
        global String subject;
        @AuraEnabled
        global String htmlBody;
        @AuraEnabled
        global String plainBody;
    }

    /** Resolved template definition — a record's values or a built-in default. */
    public class TemplateDef {
        public String type;
        public String subject;
        public String bodyHtml;
        public String bodyPlain;
        public String brandColorOverride;
        public String logoUrlOverride;
        public String logoAssetKey;
        public Integer logoHeight;
        public String footerTextOverride;
        public String layoutMode; // MODE_MANAGED (default) or MODE_FULL_HTML
    }

    // Per-transaction caches so a bulk send issues one settings read + one
    // template read regardless of signer count.
    private static Map<String, TemplateDef> defCache;
    private static DocGen_Settings__c settingsCache;

    // =====================================================================
    // Public API
    // =====================================================================

    global static RenderedEmail render(String type, Map<String, String> tokens) {
        return render(type, tokens, null);
    }

    /**
     * Renders an email for the given type.
     * @param tokens          value tokens (SignerName, DocumentTitle, SignatureUrl, Pin, ...)
     * @param messageOverride optional send-time replacement for the {Message} token value
     */
    global static RenderedEmail render(String type, Map<String, String> tokens, String messageOverride) {
        return renderWith(getTemplate(type), tokens, messageOverride);
    }

    /**
     * Resolves merge tokens in a caller-supplied subject line — used for the
     * per-send subject override so the sender can reference {DocumentTitle},
     * {SignerName}, etc. Values are not HTML (plain subject), so not escaped.
     */
    global static String renderSubject(String subjectTemplate, Map<String, String> tokens) {
        if (String.isBlank(subjectTemplate)) {
            return subjectTemplate;
        }
        Map<String, String> v = tokens == null ? new Map<String, String>() : tokens.clone();
        if (!v.containsKey('CompanyName')) {
            v.put('CompanyName', getSettings().Company_Name__c);
        }
        return resolveValueTokens(subjectTemplate, v, false);
    }

    /**
     * Renders from an explicit definition rather than the stored record — used by
     * the Email Templates editor for live preview / test send of unsaved values.
     */
    public static RenderedEmail renderWith(TemplateDef def, Map<String, String> tokens, String messageOverride) {
        if (tokens == null) {
            tokens = new Map<String, String>();
        }
        // Fill blank pieces from the built-in so a partial/preview def still renders fully.
        TemplateDef bi = builtInDef(def.type);
        if (String.isBlank(def.subject)) {
            def.subject = bi.subject;
        }
        if (String.isBlank(def.bodyHtml)) {
            def.bodyHtml = bi.bodyHtml;
        }
        DocGen_Settings__c settings = getSettings();

        // Resolve branding: template override -> org default -> hard default.
        String brand = safeBrandColor(
            String.isNotBlank(def.brandColorOverride) ? def.brandColorOverride : settings.Signature_Email_Brand_Color__c
        );
        // Logo precedence: linked Shared Asset (resolved to its LATEST file's public
        // link at send time, so replacing the asset image updates every email with
        // no template edit) -> stored URL override -> org default.
        String logo = null;
        if (String.isNotBlank(def.logoAssetKey)) {
            logo = resolveAssetPublicUrlByKey(def.logoAssetKey);
        }
        if (String.isBlank(logo)) {
            logo = String.isNotBlank(def.logoUrlOverride) ? def.logoUrlOverride : settings.Signature_Email_Logo_Url__c;
        }
        String footer = String.isNotBlank(def.footerTextOverride)
            ? def.footerTextOverride
            : settings.Signature_Email_Footer_Text__c;
        String company = settings.Company_Name__c;

        // Build the full token set the body/subject can reference.
        Map<String, String> v = tokens.clone();
        if (!v.containsKey('CompanyName')) {
            v.put('CompanyName', company);
        }
        v.put('BrandColor', brand);
        // {LogoUrl} — the effective logo, so Full-custom-HTML templates can place
        // and size it themselves: <img src="{LogoUrl}" style="height:60px"/>.
        v.put('LogoUrl', logo == null ? '' : logo);
        // {Message} value: send-time override wins, else whatever the caller/template default supplied.
        String message = String.isNotBlank(messageOverride) ? messageOverride : v.get('Message');
        v.put('Message', message);

        RenderedEmail out = new RenderedEmail();
        out.subject = resolveValueTokens(def.subject, v, false);

        // {%asset:<key>} — resolve Shared Asset tags to their public delivery
        // URLs BEFORE token expansion so nothing else consumes the tag. Emails
        // get the URL (authors write + size their own <img>); documents embed
        // the image bytes — the one documented difference in tag behavior.
        String assetResolvedHtml = resolveAssetTags(def.bodyHtml);
        String bodyInner = expandBody(assetResolvedHtml, v, brand, true);
        if (def.layoutMode == MODE_FULL_HTML) {
            // Full custom HTML: the body IS the whole document — send it as authored,
            // tokens/widgets resolved, no Portwood header/footer chrome.
            out.htmlBody = bodyInner;
        } else {
            out.htmlBody = wrapChrome(bodyInner, brand, logo, company, footer, def.logoHeight);
        }

        // Plain part: explicit override if provided, else derive from the body.
        if (String.isNotBlank(def.bodyPlain)) {
            out.plainBody = stripTags(expandBody(def.bodyPlain, v, brand, false));
        } else {
            out.plainBody = stripTags(expandBody(assetResolvedHtml, v, brand, false));
        }
        return out;
    }

    /** Resolves the template definition for a type (record or built-in). Cached. */
    public static TemplateDef getTemplate(String type) {
        if (defCache == null) {
            loadActiveTemplates();
        }
        TemplateDef def = defCache.get(type);
        if (def == null) {
            def = builtInDef(type);
        }
        // Fill any blank piece from the built-in so a partial record still renders fully.
        TemplateDef fallback = builtInDef(type);
        if (String.isBlank(def.subject)) {
            def.subject = fallback.subject;
        }
        if (String.isBlank(def.bodyHtml)) {
            def.bodyHtml = fallback.bodyHtml;
        }
        return def;
    }

    // =====================================================================
    // Record loading (defensive — never throws to the caller)
    // =====================================================================

    /**
     * The active-template read, in its own `without sharing` scope.
     *
     * `WITH SYSTEM_MODE` bypasses CRUD/FLS but NOT record sharing — sharing is
     * decided by the sharing keyword of the class the query runs in, and this
     * class is `with sharing`. DocGen_Email_Template__c ships with
     * sharingModel=ReadWrite but externalSharingModel=Private, so an internal
     * sender sees every active record and a GUEST sender sees none: the query
     * returned zero rows, defCache stayed empty, and getTemplate() silently fell
     * back to builtInDef(). That is exactly why the two guest-context emails
     * (Verification PIN, Completion Confirmation) arrived on the built-in
     * default while the two internal-context ones (Signature Request, Reminder)
     * used the customer's saved template.
     *
     * A guest sharing rule is not the fix — this is package-internal branding
     * config with no per-record confidentiality model (internal OWD is already
     * ReadWrite), and requiring every subscriber to hand-build a sharing rule
     * for it would be a setup trap. The bypass is scoped to this one read rather
     * than applied to the whole class, and FLS is still enforced by the
     * guestAssertAccessible guard in loadActiveTemplates.
     */
    private without sharing class TemplateReader {
        /**
         * The logo asset behind {%asset:key} and Logo_Asset_Key__c, same story:
         * DocGen_Asset__c is also sharingModel=ReadWrite / externalSharingModel=
         * Private, so under `with sharing` a guest read returned nothing and the
         * logo silently vanished from the guest emails — degrading quietly,
         * because queryAssetPublicUrl treats "no rows" as "no logo".
         */
        private List<DocGen_Asset__c> readAssetByKey(String assetKey) {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            return [
                SELECT
                    Id,
                    (
                        SELECT ContentDocument.LatestPublishedVersionId
                        FROM ContentDocumentLinks
                        ORDER BY ContentDocument.CreatedDate DESC, ContentDocument.Id DESC
                        LIMIT 1
                    )
                FROM DocGen_Asset__c
                WHERE Asset_Key__c = :assetKey
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets
        }

        private List<ContentDistribution> readDistribution(Id cvId) {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            return [
                SELECT ContentDownloadUrl
                FROM ContentDistribution
                WHERE ContentVersionId = :cvId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        }

        private List<DocGen_Email_Template__c> read() {
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            return [
                SELECT
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
                    Layout_Mode__c
                FROM DocGen_Email_Template__c
                WHERE Is_Active__c = TRUE
                WITH SYSTEM_MODE
                ORDER BY LastModifiedDate DESC
            ]; // NOPMD - package-internal object; CRUD via Portwood permission sets
        }
    }

    private static void loadActiveTemplates() {
        defCache = new Map<String, TemplateDef>();
        try {
            // Guest signers send the PIN/completion emails, so this read must
            // pass guest FLS. SYSTEM_MODE + guestAssertAccessible matches the
            // established pattern for guest-reachable internal-object reads.
            DocGenFlsGuard.guestAssertAccessible(
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
            List<DocGen_Email_Template__c> rows = new TemplateReader().read();
            for (DocGen_Email_Template__c r : rows) {
                if (r.Type__c == null || defCache.containsKey(r.Type__c)) {
                    continue; // first (most-recently-modified) active record per type wins
                }
                TemplateDef d = new TemplateDef();
                d.type = r.Type__c;
                d.subject = r.Subject__c;
                d.bodyHtml = r.Body_Html__c;
                d.bodyPlain = r.Body_Plain__c;
                d.brandColorOverride = r.Brand_Color__c;
                // Long field wins — Logo_Url__c is a platform Url field capped at 255
                // chars and type-locked in the managed package; Files delivery URLs
                // and other long links live in Logo_Url_Extended__c.
                d.logoUrlOverride = String.isNotBlank(r.Logo_Url_Extended__c)
                    ? r.Logo_Url_Extended__c.trim()
                    : r.Logo_Url__c;
                d.logoAssetKey = r.Logo_Asset_Key__c;
                d.logoHeight = r.Logo_Height__c == null ? null : Integer.valueOf(r.Logo_Height__c);
                d.footerTextOverride = r.Footer_Text__c;
                d.layoutMode = r.Layout_Mode__c == MODE_FULL_HTML ? MODE_FULL_HTML : MODE_MANAGED;
                defCache.put(r.Type__c, d);
            }
        } catch (Exception e) {
            // Object not deployed yet, FLS blocked, etc. — built-in defaults cover us.
            System.debug(LoggingLevel.WARN, 'Portwood: email-template load fell back to built-ins: ' + e.getMessage());
        }
    }

    private static DocGen_Settings__c getSettings() {
        if (settingsCache == null) {
            settingsCache = DocGen_Settings__c.getOrgDefaults();
            if (settingsCache == null) {
                settingsCache = new DocGen_Settings__c();
            }
        }
        return settingsCache;
    }

    // Per-transaction asset-URL cache (includes negative results) so a bulk
    // reminder run rendering hundreds of emails resolves each asset tag with at
    // most one query pair per key, not per recipient.
    private static Map<String, String> assetUrlCache = new Map<String, String>();

    @TestVisible
    private static void clearCache() {
        defCache = null;
        settingsCache = null;
        assetUrlCache = new Map<String, String>();
    }

    // =====================================================================
    // Token + widget expansion
    // =====================================================================

    /**
     * Expands a body template: widgets first (trusted HTML / plain), then
     * HTML-escaped value tokens. Unknown {Tokens} are blanked so no literal
     * placeholder ever leaks to a recipient.
     */
    private static String expandBody(String body, Map<String, String> v, String brand, Boolean isHtml) {
        if (String.isBlank(body)) {
            return '';
        }
        String s = body;

        // {Message} — prose value: escape + newline->br for HTML.
        String msg = v.containsKey('Message') ? v.get('Message') : '';
        if (msg == null) {
            msg = '';
        }
        s = s.replace('{Message}', isHtml ? brToHtml(msg) : msg);

        // Widgets.
        s = s.replace(
            '{ActionButton}',
            isHtml ? actionButtonHtml(v.get('SignatureUrl'), brand) : actionButtonPlain(v.get('SignatureUrl'))
        );
        s = s.replace(
            '{DocumentInfo}',
            isHtml
                ? documentInfoHtml(v.get('DocumentTitle'), v.get('RoleName'), brand)
                : documentInfoPlain(v.get('DocumentTitle'), v.get('RoleName'))
        );
        s = s.replace(
            '{SecurityNote}',
            isHtml
                ? securityNoteHtml(v.get('SignatureUrl'), v.get('ExpirationHours'), brand)
                : securityNotePlain(v.get('SignatureUrl'), v.get('ExpirationHours'))
        );
        s = s.replace(
            '{VerificationCode}',
            isHtml
                ? verificationCodeHtml(v.get('Pin'), v.get('ExpirationMinutes'))
                : verificationCodePlain(v.get('Pin'), v.get('ExpirationMinutes'))
        );

        // {BrandColor} is a validated hex — safe to inject raw into style="".
        s = s.replace('{BrandColor}', brand);

        // Remaining value tokens (HTML-escaped). Blank missing ones.
        s = resolveValueTokens(s, v, isHtml);
        return s;
    }

    /** Replaces {Token} for every key in v with its escaped value; blanks leftover {...}. */
    private static String resolveValueTokens(String input, Map<String, String> v, Boolean isHtml) {
        if (String.isBlank(input)) {
            return input == null ? '' : input;
        }
        String s = input;
        for (String key : v.keySet()) {
            if (key == 'Message' || key == 'BrandColor') {
                continue; // already handled
            }
            String val = v.get(key);
            val = val == null ? '' : val;
            s = s.replace('{' + key + '}', isHtml ? escapeHtml(val) : val);
        }
        // Strip any leftover unresolved {Token} so nothing leaks.
        s = s.replaceAll('\\{[A-Za-z0-9_]+\\}', '');
        return s;
    }

    // =====================================================================
    // Widget builders — HTML
    // =====================================================================

    private static String actionButtonHtml(String url, String brand) {
        String safeUrl = escapeHtml(url);
        String html = '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto 24px auto;">';
        html += '<tr><td align="center" style="border-radius:6px;background-color:' + brand + ';">';
        html +=
            '<a href="' +
            safeUrl +
            '" target="_blank" style="display:inline-block;padding:14px 32px;color:#ffffff;font-size:16px;font-weight:bold;text-decoration:none;border-radius:6px;">Review &amp; Sign Document</a>';
        html += '</td></tr></table>';
        return html;
    }

    private static String documentInfoHtml(String title, String role, String brand) {
        String safeTitle = escapeHtml(String.isNotBlank(title) ? title : 'Document');
        String html = '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px 0;">';
        html +=
            '<tr><td style="background-color:#f8f9fa;border-left:4px solid ' +
            brand +
            ';padding:16px 20px;border-radius:0 4px 4px 0;">';
        html += '<p style="font-size:14px;color:#706e6b;margin:0 0 4px 0;">Document</p>';
        html += '<p style="font-size:16px;color:#181818;font-weight:bold;margin:0;">' + safeTitle + '</p>';
        if (String.isNotBlank(role)) {
            html +=
                '<p style="font-size:13px;color:#706e6b;margin:8px 0 0 0;">Your role: <strong>' +
                escapeHtml(role) +
                '</strong></p>';
        }
        html += '</td></tr></table>';
        return html;
    }

    private static String securityNoteHtml(String url, String hours, String brand) {
        String h = String.isNotBlank(hours) ? hours : '48';
        String safeUrl = escapeHtml(url);
        String html = '<p style="font-size:13px;color:#706e6b;margin:0 0 8px 0;line-height:1.5;">';
        html +=
            'This link is unique to you and will expire in ' +
            escapeHtml(h) +
            ' hours. You will need to verify your email before signing.</p>';
        html += '<p style="font-size:12px;color:#999999;margin:0;word-break:break-all;">';
        html += 'If the button above doesn\'t work, copy and paste this URL into your browser:<br/>';
        html += '<a href="' + safeUrl + '" style="color:' + brand + ';">' + safeUrl + '</a></p>';
        return html;
    }

    private static String verificationCodeHtml(String pin, String minutes) {
        String safePin = escapeHtml(pin);
        String m = String.isNotBlank(minutes) ? minutes : '15';
        String html = '<p style="font-size:16px;color:#333333;margin:0 0 8px 0;text-align:center;">Your verification code is:</p>';
        html +=
            '<p style="font-size:36px;font-weight:bold;color:#181818;letter-spacing:8px;margin:16px 0;font-family:monospace;text-align:center;">' +
            safePin +
            '</p>';
        html +=
            '<p style="font-size:13px;color:#706e6b;margin:16px 0 0 0;text-align:center;">This code expires in ' +
            escapeHtml(m) +
            ' minutes.</p>';
        return html;
    }

    // =====================================================================
    // Widget builders — plain text
    // =====================================================================

    private static String actionButtonPlain(String url) {
        return url == null ? '' : ('Review & sign your document: ' + url);
    }

    private static String documentInfoPlain(String title, String role) {
        String s = 'Document: ' + (String.isNotBlank(title) ? title : 'Document');
        if (String.isNotBlank(role)) {
            s += '\nYour role: ' + role;
        }
        return s;
    }

    private static String securityNotePlain(String url, String hours) {
        String h = String.isNotBlank(hours) ? hours : '48';
        String s = 'This link is unique to you and expires in ' + h + ' hours.';
        if (String.isNotBlank(url)) {
            s += '\n' + url;
        }
        return s;
    }

    private static String verificationCodePlain(String pin, String minutes) {
        String m = String.isNotBlank(minutes) ? minutes : '15';
        return 'Your verification code is: ' + (pin == null ? '' : pin) + ' (expires in ' + m + ' minutes).';
    }

    // =====================================================================
    // Chrome + helpers
    // =====================================================================

    /**
     * Send-time resolution of a Shared Asset logo (guest-safe: read-only,
     * SYSTEM_MODE behind guest FLS guards — guest/Automated Process senders can
     * QUERY ContentDistributions, they just can't create them; creation happens
     * in the editor and on asset-image replacement, both admin sessions).
     * Returns the public download URL of the asset's latest file, or null when
     * anything is missing so the caller falls back to the stored URL.
     */
    @TestVisible
    private static String resolveAssetPublicUrlByKey(String assetKey) {
        try {
            // Stored keys are canonical slugs (underscores → hyphens, lowercased);
            // normalize the lookup the same way the {%asset:} tag resolver does.
            assetKey = DocGenAssetKeyHandler.normalizeKey(assetKey);
            if (String.isBlank(assetKey)) {
                return null;
            }
            if (assetUrlCache.containsKey(assetKey)) {
                String cached = assetUrlCache.get(assetKey);
                return String.isBlank(cached) ? null : cached;
            }
            String resolved = queryAssetPublicUrl(assetKey);
            assetUrlCache.put(assetKey, resolved == null ? '' : resolved);
            return resolved;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: asset tag resolution fell back: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Replaces every {%asset:<key>} tag in an email body with the asset's public
     * delivery URL — so custom-HTML authors can reference ANY Shared Asset image
     * (<img src="{%asset:footer-banner}" style="height:40px"/>), not just the
     * logo. Unresolvable tags (unknown key / never-published asset) blank out —
     * consistent with how document templates drop unsupported asset tags cleanly.
     * Deliveries are ensured at editor save/preview time (admin session); this
     * pass only reads, so guest/Automated Process sends stay safe.
     */
    @TestVisible
    private static String resolveAssetTags(String body) {
        if (String.isBlank(body) || !body.contains('{%asset:')) {
            return body;
        }
        Pattern tagPattern = Pattern.compile('\\{%asset:([^}]+)\\}');
        Matcher m = tagPattern.matcher(body);
        String result = '';
        Integer cursor = 0;
        while (m.find()) {
            result += body.substring(cursor, m.start());
            // Tolerate the document-template size suffix ({%asset:logo:200x100}) —
            // emails size via the author's own CSS, so only the key matters.
            String rawKey = m.group(1).contains(':') ? m.group(1).substringBefore(':') : m.group(1);
            String url = resolveAssetPublicUrlByKey(rawKey);
            if (String.isBlank(url)) {
                System.debug(LoggingLevel.WARN, 'Portwood: email asset tag unresolved (key=' + m.group(1) + ')');
            } else {
                result += escapeHtml(url);
            }
            cursor = m.end();
        }
        result += body.substring(cursor);
        return result;
    }

    private static String queryAssetPublicUrl(String assetKey) {
        try {
            DocGenFlsGuard.guestAssertAccessible(DocGen_Asset__c.sObjectType, new Set<String>{ 'Asset_Key__c' });
            List<DocGen_Asset__c> assets = new TemplateReader().readAssetByKey(assetKey);
            if (assets.isEmpty() || assets[0].ContentDocumentLinks.isEmpty()) {
                return null;
            }
            Id cvId = assets[0].ContentDocumentLinks[0].ContentDocument.LatestPublishedVersionId;
            if (cvId == null) {
                return null;
            }
            DocGenFlsGuard.guestAssertAccessible(
                ContentDistribution.sObjectType,
                new Set<String>{ 'ContentDownloadUrl', 'ContentVersionId' }
            );
            List<ContentDistribution> dists = new TemplateReader().readDistribution(cvId);
            return dists.isEmpty() ? null : dists[0].ContentDownloadUrl;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: logo asset resolution fell back to URL: ' + e.getMessage());
            return null;
        }
    }

    private static String wrapChrome(
        String bodyInner,
        String brand,
        String logoUrl,
        String company,
        String footer,
        Integer logoHeight
    ) {
        String safeCompany = escapeHtml(company);
        // Default 48px tall / 200px wide (the long-standing chrome); a per-template
        // Logo Height scales both proportionally, clamped to email-sane bounds.
        Integer h = (logoHeight != null && logoHeight >= 16 && logoHeight <= 200) ? logoHeight : 48;
        Integer maxW = (h * 200) / 48;
        String html = '<!DOCTYPE html>';
        html += '<html lang="en"><head><meta charset="utf-8"/>';
        html += '<meta name="viewport" content="width=device-width, initial-scale=1.0"/></head>';
        html += '<body style="margin:0;padding:0;background-color:#f4f4f4;font-family:Arial,Helvetica,sans-serif;">';
        html += '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f4f4;">';
        html += '<tr><td align="center" style="padding:24px 16px;">';
        html += '<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background-color:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08);">';

        // Header bar.
        html += '<tr><td style="background-color:' + brand + ';padding:24px 32px;text-align:center;">';
        if (String.isNotBlank(logoUrl)) {
            html +=
                '<img src="' +
                escapeHtml(logoUrl) +
                '" alt="' +
                safeCompany +
                '" style="max-height:' +
                h +
                'px;max-width:' +
                maxW +
                'px;display:inline-block;" />';
        } else if (String.isNotBlank(company)) {
            html += '<span style="color:#ffffff;font-size:20px;font-weight:bold;">' + safeCompany + '</span>';
        }
        html += '</td></tr>';

        // Body.
        html += '<tr><td style="padding:32px;">' + bodyInner + '</td></tr>';

        // Footer.
        html += '<tr><td style="background-color:#f8f9fa;padding:20px 32px;border-top:1px solid #e5e5e5;text-align:center;">';
        if (String.isNotBlank(footer)) {
            html += '<p style="font-size:12px;color:#999999;margin:0;line-height:1.4;">' + escapeHtml(footer) + '</p>';
        } else {
            html += '<p style="font-size:12px;color:#999999;margin:0;">Powered by Portwood &mdash; Open-Source Document Generation for Salesforce</p>';
        }
        html += '</td></tr>';

        html += '</table></td></tr></table></body></html>';
        return html;
    }

    /** Crude but safe HTML->text for the plain part. */
    private static String stripTags(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        String s = html;
        s = s.replaceAll('(?i)<br\\s*/?>', '\n');
        s = s.replaceAll('(?i)</p>', '\n\n');
        s = s.replaceAll('(?i)</tr>', '\n');
        s = s.replaceAll('<[^>]+>', '');
        // Unescape the entities we emit.
        s = s.replace('&amp;', '&')
            .replace('&lt;', '<')
            .replace('&gt;', '>')
            .replace('&quot;', '"')
            .replace('&#39;', '\'')
            .replace('&mdash;', '-');
        // Collapse 3+ newlines.
        s = s.replaceAll('\\n{3,}', '\n\n');
        return s.trim();
    }

    private static String escapeHtml(String input) {
        if (input == null) {
            return '';
        }
        return input.replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;')
            .replace('\'', '&#39;');
    }

    private static String brToHtml(String input) {
        return escapeHtml(input).replace('\r\n', '\n').replace('\n', '<br/>');
    }

    /** Validates #RRGGBB; returns a safe default otherwise (prevents style injection). */
    private static String safeBrandColor(String input) {
        if (String.isNotBlank(input) && Pattern.matches('^#[0-9a-fA-F]{6}$', input)) {
            return input;
        }
        return DEFAULT_BRAND;
    }

    // =====================================================================
    // Built-in defaults (the markup Portwood has always shipped)
    // =====================================================================

    /** Returns the built-in default definition for a type. Public for the install seed + LWC "reset". */
    public static TemplateDef builtInDef(String type) {
        TemplateDef d = new TemplateDef();
        d.type = type;
        d.layoutMode = MODE_MANAGED;
        DocGen_Settings__c s = getSettings();

        if (type == TYPE_REQUEST) {
            d.subject = String.isNotBlank(s.Signature_Email_Subject__c)
                ? s.Signature_Email_Subject__c
                : 'Action Required: Please Sign {DocumentTitle}';
            d.bodyHtml =
                '<p style="font-size:16px;color:#333333;margin:0 0 16px 0;">Hi {SignerName},</p>' +
                '<p style="font-size:15px;color:#555555;margin:0 0 16px 0;line-height:1.5;">{Message}</p>' +
                '{DocumentInfo}{ActionButton}{SecurityNote}';
        } else if (type == TYPE_REMINDER) {
            d.subject = 'Reminder: {DocumentTitle}';
            d.bodyHtml =
                '<p style="font-size:16px;color:#333333;margin:0 0 16px 0;">Hi {SignerName},</p>' +
                '<p style="font-size:15px;color:#555555;margin:0 0 16px 0;line-height:1.5;">{Message}</p>' +
                '{DocumentInfo}{ActionButton}{SecurityNote}';
        } else if (type == TYPE_PIN) {
            d.subject = 'Your {CompanyName} Signature Verification Code';
            d.bodyHtml =
                '{VerificationCode}' +
                '<p style="font-size:13px;color:#706e6b;margin:16px 0 0 0;text-align:center;">If you did not request this code, you can safely ignore this email.</p>';
        } else if (type == TYPE_SIGNER_COMPLETED) {
            d.subject = 'Signature Update: {SignerName} has signed';
            d.bodyHtml =
                '<p>{SignerName} ({RoleName}) has completed their signature.</p>' +
                '<p style="font-size:13px;color:#706e6b;margin-top:16px;">Request ID: {RequestId}</p>';
        } else if (type == TYPE_ALL_SIGNED) {
            d.subject = 'All Signatures Complete';
            d.bodyHtml =
                '<p>All signers have completed their signatures. The signed PDF has been generated and attached to the record.</p>' +
                '<p style="font-size:13px;color:#706e6b;margin-top:16px;">Request ID: {RequestId}</p>';
        } else if (type == TYPE_DECLINED) {
            d.subject = 'Signature Declined: {SignerName}';
            d.bodyHtml =
                '<p><strong>{SignerName}</strong> ({RoleName}) has <span style="color:#ea001e;font-weight:bold;">declined</span> to sign.</p>' +
                '<p>{Message}</p>' +
                '<p style="font-size:13px;color:#706e6b;margin-top:16px;">Request ID: {RequestId}</p>';
        } else if (type == TYPE_COMPLETION) {
            d.subject = 'Signature complete: {DocumentTitle}';
            d.bodyHtml =
                '<p>Hi {SignerName},</p>' +
                '<p>Thanks for signing. All parties have now completed <strong>{DocumentTitle}</strong>, and the signed document is finalized. No further action is needed.</p>' +
                '<p style="font-size:13px;color:#706e6b;">This is your confirmation that the signature was recorded.</p>';
        } else {
            d.subject = 'Portwood Notification';
            d.bodyHtml = '<p>{Message}</p>';
        }
        return d;
    }

    /** The friendly default message prose for a type (used when no {Message} token supplied). */
    public static String defaultMessage(String type) {
        DocGen_Settings__c s = getSettings();
        if (type == TYPE_REQUEST || type == TYPE_REMINDER) {
            if (String.isNotBlank(s.Signature_Email_Message__c)) {
                return s.Signature_Email_Message__c;
            }
            return type == TYPE_REMINDER
                ? 'This is a friendly reminder that the document below is still awaiting your signature.'
                : '{SenderName} has sent you a document that requires your signature:';
        }
        return '';
    }
}
