public with sharing class DocGenSetupController {
    /**
     * Returns the org's domain URL for configuration display.
     * @return The external form of the org domain URL
     */
    @AuraEnabled(cacheable=true)
    public static String getOrgUrl() {
        // Return the core my.salesforce.com URL, not the Lightning domain
        return Url.getOrgDomainUrl().toExternalForm();
    }

    /**
     * @deprecated Use getSettingsFresh() instead. In managed packages this returns
     * the SObject with namespaced field names which break LWC property access.
     * Retained because docGenSetupWizard still wires this method; do not remove
     * (zero subscriber impact rule).
     * @return The DocGen_Settings__c org defaults record
     */
    @AuraEnabled(cacheable=true)
    public static DocGen_Settings__c getSettings() {
        return DocGen_Settings__c.getOrgDefaults();
    }

    /**
     * Returns fresh (non-cached) settings as a plain map with unqualified field names.
     * In managed packages, SObject field names are returned with the namespace prefix
     * (e.g., portwoodglobal__Experience_Site_Url__c), which breaks LWC property access.
     * This method strips the prefix so the LWC can use simple field names.
     */
    @AuraEnabled
    public static Map<String, Object> getSettingsFresh() {
        DocGen_Settings__c s = DocGen_Settings__c.getOrgDefaults();
        Map<String, Object> result = new Map<String, Object>();
        result.put('Experience_Site_Url__c', s.Experience_Site_Url__c);
        result.put('Company_Name__c', s.Company_Name__c);
        result.put('Signature_Email_Brand_Color__c', s.Signature_Email_Brand_Color__c);
        result.put('Signature_Email_Logo_Url__c', s.Signature_Email_Logo_Url__c);
        result.put('Signature_Email_Subject__c', s.Signature_Email_Subject__c);
        result.put('Signature_Email_Message__c', s.Signature_Email_Message__c);
        result.put('Signature_Email_Footer_Text__c', s.Signature_Email_Footer_Text__c);
        result.put('Signature_OWA_Id__c', s.Signature_OWA_Id__c);
        result.put('Signature_Reminder_Enabled__c', s.Signature_Reminder_Enabled__c);
        result.put('Signature_Reminder_Hours__c', s.Signature_Reminder_Hours__c);
        result.put('Signature_Reminder_Schedule__c', s.Signature_Reminder_Schedule__c);
        result.put('Signature_Expiration_Days__c', s.Signature_Expiration_Days__c);
        // #verification — stored as inverted "skip" so the safe default (required) survives
        // upgrades. Report require = NOT skip; key kept stable for the LWC.
        result.put(
            'Signature_Require_Email_Verification__c',
            !(s != null && s.Signature_Skip_Email_Verification__c == true)
        );
        result.put('Signature_Prefill_Signer_Email__c', s != null && s.Signature_Prefill_Signer_Email__c == true);
        // #367 — plain pass-through: Checkbox naturally defaults false, which is
        // exactly the intended default (Decline hidden until explicitly shown).
        result.put('Signature_Show_Decline__c', s != null && s.Signature_Show_Decline__c == true);
        return result;
    }

    /**
     * Saves the Experience Site URL to Portwood settings.
     * @param experienceSiteUrl The Experience Site base URL to store
     */
    @AuraEnabled
    public static void saveSettings(String experienceSiteUrl) {
        // Only allow users with Customize Application or DocGen_Admin permission set
        if (
            !FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()
        ) {
            throw DocGenService.ahe('Insufficient privileges to modify Portwood settings.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Experience_Site_Url__c = experienceSiteUrl;
        // Package-internal object — CRUD controlled by Portwood permission sets
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create"/"FLS Update").
        // upsert is checked against both create + update FLS because the
        // operation can do either depending on whether the hierarchy
        // custom settings record already exists.
        DocGenFlsGuard.assertCreateable(settings, new Set<String>{ 'Experience_Site_Url__c' });
        DocGenFlsGuard.assertUpdateable(settings, new Set<String>{ 'Experience_Site_Url__c' });
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.upsert(settings, AccessLevel.SYSTEM_MODE);
        } catch (DmlException e) {
            throw DocGenService.dmlAhe(e, DocGen_Settings__c.sObjectType);
        }
    }

    /**
     * Saves signature-specific settings (email branding, site URL).
     */
    /**
     * Returns available Org-Wide Email Addresses for the signature email sender picker.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getOrgWideEmailAddresses() {
        if (!FeatureManagement.checkPermission('DocGen_Admin_Access') && !isCurrentUserAdmin()) {
            throw DocGenService.ahe('Insufficient privileges to view Org-Wide Email Addresses.');
        }
        List<Map<String, String>> results = new List<Map<String, String>>();
        results.add(new Map<String, String>{ 'label' => '-- Running User (default) --', 'value' => '' });
        for (OrgWideEmailAddress owa : [
            SELECT Id, Address, DisplayName
            FROM OrgWideEmailAddress
            WITH USER_MODE
            ORDER BY DisplayName
        ]) {
            String label = String.isNotBlank(owa.DisplayName)
                ? owa.DisplayName + ' <' + owa.Address + '>'
                : owa.Address;
            results.add(new Map<String, String>{ 'label' => label, 'value' => owa.Id });
        }
        return results;
    }

    /**
     * Validates the signature setup configuration and returns a list of check results.
     * Each result has: name, passed, message, fixUrl.
     */
    @AuraEnabled
    public static List<Map<String, Object>> validateSignatureSetup() {
        if (!FeatureManagement.checkPermission('DocGen_Admin_Access') && !isCurrentUserAdmin()) {
            throw DocGenService.ahe('Insufficient privileges to validate signature setup.');
        }
        List<Map<String, Object>> checks = new List<Map<String, Object>>();
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();

        // 1. Site URL configured
        Boolean siteUrlOk = String.isNotBlank(settings.Experience_Site_Url__c);
        checks.add(
            buildCheck(
                'Site URL Configured',
                siteUrlOk,
                siteUrlOk
                    ? 'Signature Site URL is set.'
                    : 'No Signature Site URL configured. Enter your Salesforce Site URL below.',
                null
            )
        );

        // 2. Salesforce Site exists and is active
        Boolean siteActive = false;
        String siteName = '';
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<Site> sites = [SELECT Id, Name, Status FROM Site WHERE Status = 'Active' WITH USER_MODE LIMIT 10];
            siteActive = !sites.isEmpty();
            if (siteActive) {
                siteName = sites[0].Name;
            }
        } catch (Exception e) {
            // Site query may fail in some contexts
        }
        checks.add(
            buildCheck(
                'Salesforce Site Active',
                siteActive,
                siteActive
                    ? 'Active site found: ' + siteName
                    : 'No active Salesforce Site found. Create one in Setup > Sites.',
                '/lightning/setup/CustomDomain/home'
            )
        );

        // 3. Org-Wide Email Address configured
        Boolean owaOk = false;
        String owaDisplay = '';
        if (String.isNotBlank(settings.Signature_OWA_Id__c)) {
            try {
                /* code-analyzer-suppress ApexFlsViolation */
                List<OrgWideEmailAddress> owas = [
                    SELECT Id, DisplayName, Address
                    FROM OrgWideEmailAddress
                    WHERE Id = :settings.Signature_OWA_Id__c
                    WITH USER_MODE
                    LIMIT 1
                ]; // NOPMD
                owaOk = !owas.isEmpty();
                if (owaOk) {
                    owaDisplay = owas[0].DisplayName + ' <' + owas[0].Address + '>';
                }
            } catch (Exception e) {
                // OWA query failed
            }
        }
        checks.add(
            buildCheck(
                'Org-Wide Email Address',
                owaOk,
                owaOk
                    ? 'Email sender configured: ' + owaDisplay
                    : 'No Org-Wide Email Address selected. Required for PIN verification emails. Create one in Setup > Organization-Wide Email Addresses, then select it below.',
                '/lightning/setup/OrgWideEmailAddresses/home'
            )
        );

        // 4. Guest user permission set check
        Boolean guestPermOk = false;
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<PermissionSet> ps = [
                SELECT Id
                FROM PermissionSet
                WHERE Name = 'DocGen_Guest_Signature'
                WITH USER_MODE
                LIMIT 1
            ]; // NOPMD
            if (!ps.isEmpty()) {
                /* code-analyzer-suppress ApexFlsViolation */
                List<PermissionSetAssignment> psa = [
                    SELECT Id
                    FROM PermissionSetAssignment
                    WHERE PermissionSetId = :ps[0].Id
                    WITH USER_MODE
                    LIMIT 1
                ]; // NOPMD
                guestPermOk = !psa.isEmpty();
            }
        } catch (Exception e) {
            // Permission query failed
        }
        checks.add(
            buildCheck(
                'Guest Permission Set Assigned',
                guestPermOk,
                guestPermOk
                    ? 'Portwood Guest Signature permission set is assigned.'
                    : 'The Portwood Guest Signature permission set is not assigned to any user. Assign it to the Site guest user via Site > Public Access Settings.',
                null
            )
        );

        // 5. VF pages accessible check — verify the key pages exist in the org
        Boolean vfPagesOk = false;
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<ApexPage> pages = [
                SELECT Name
                FROM ApexPage
                WHERE Name IN ('DocGenSign', 'DocGenSignature', 'DocGenVerify')
                WITH USER_MODE
            ]; // NOPMD
            vfPagesOk = pages.size() >= 3;
        } catch (Exception e) {
            // ApexPage query may not be available
        }
        checks.add(
            buildCheck(
                'Visualforce Pages Deployed',
                vfPagesOk,
                vfPagesOk
                    ? 'DocGenSign, DocGenSignature, and DocGenVerify pages are deployed.'
                    : 'Required Visualforce pages are missing. Ensure the Portwood package is fully deployed.',
                null
            )
        );

        return checks;
    }

    /**
     * Returns true if the running user has the System Administrator-equivalent
     * "Modify All Data" permission. Used as a fallback to DocGen_Admin_Access
     * so org admins are never locked out of read-only setup endpoints.
     * UserInfo.isAdministrator() is not available in this API version.
     */
    private static Boolean isCurrentUserAdmin() {
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<User> rows = [
                SELECT Profile.PermissionsModifyAllData
                FROM User
                WHERE Id = :UserInfo.getUserId()
                WITH USER_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - read-only User self-lookup
            return !rows.isEmpty() && rows[0].Profile != null && rows[0].Profile.PermissionsModifyAllData == true;
        } catch (Exception e) {
            return false;
        }
    }

    private static Map<String, Object> buildCheck(String name, Boolean passed, String message, String fixUrl) {
        Map<String, Object> check = new Map<String, Object>();
        check.put('name', name);
        check.put('passed', passed);
        check.put('message', message);
        if (fixUrl != null) {
            check.put('fixUrl', fixUrl);
        }
        return check;
    }

    @AuraEnabled
    public static void saveSignatureSettings(
        String brandColor,
        String logoUrl,
        String emailSubject,
        String emailMessage,
        String footerText,
        String companyName,
        String owaId
    ) {
        if (
            !FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()
        ) {
            throw DocGenService.ahe('Insufficient privileges to modify Portwood settings.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Signature_Email_Brand_Color__c = brandColor;
        settings.Signature_Email_Logo_Url__c = logoUrl;
        settings.Signature_Email_Subject__c = emailSubject;
        settings.Signature_Email_Message__c = emailMessage;
        settings.Signature_Email_Footer_Text__c = footerText;
        settings.Company_Name__c = companyName;
        settings.Signature_OWA_Id__c = owaId;
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create"/"FLS Update").
        Set<String> sigSettingsFields = new Set<String>{
            'Signature_Email_Brand_Color__c',
            'Signature_Email_Logo_Url__c',
            'Signature_Email_Subject__c',
            'Signature_Email_Message__c',
            'Signature_Email_Footer_Text__c',
            'Company_Name__c',
            'Signature_OWA_Id__c'
        };
        DocGenFlsGuard.assertCreateable(settings, sigSettingsFields);
        DocGenFlsGuard.assertUpdateable(settings, sigSettingsFields);
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.upsert(settings, AccessLevel.SYSTEM_MODE);
        } catch (DmlException e) {
            throw DocGenService.dmlAhe(e, DocGen_Settings__c.sObjectType);
        }
    }

    /**
     * Saves reminder settings and auto-schedules/unschedules the reminder job.
     * When enabled, schedules DocGenSignatureReminderSchedulable to run hourly.
     * When disabled, aborts the scheduled job.
     */
    public static void saveReminderSettings(Boolean enabled, Integer hours) {
        saveReminderSettings(enabled, hours, null, null);
    }

    /**
     * 4-arg canonical. schedule = CSV of reminder hour offsets ("24,72,168");
     * blank keeps the legacy single reminder from hours. expirationDays = org-wide
     * default signing-window (1-365); null leaves the stored value untouched.
     */
    @AuraEnabled
    public static void saveReminderSettings(Boolean enabled, Integer hours, String schedule, Integer expirationDays) {
        if (
            !FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()
        ) {
            throw DocGenService.ahe('Insufficient privileges to modify Portwood settings.');
        }
        String normalizedSchedule = normalizeReminderSchedule(schedule);
        if (expirationDays != null && (expirationDays < 1 || expirationDays > 365)) {
            throw DocGenService.ahe('Link expiration must be between 1 and 365 days.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Signature_Reminder_Enabled__c = enabled;
        settings.Signature_Reminder_Hours__c = hours != null && hours > 0 ? hours : 24;
        settings.Signature_Reminder_Schedule__c = normalizedSchedule;
        if (expirationDays != null) {
            settings.Signature_Expiration_Days__c = expirationDays;
        }
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create"/"FLS Update").
        Set<String> reminderFields = new Set<String>{
            'Signature_Reminder_Enabled__c',
            'Signature_Reminder_Hours__c',
            'Signature_Reminder_Schedule__c',
            'Signature_Expiration_Days__c'
        };
        DocGenFlsGuard.assertCreateable(settings, reminderFields);
        DocGenFlsGuard.assertUpdateable(settings, reminderFields);
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.upsert(settings, AccessLevel.SYSTEM_MODE);
        } catch (DmlException e) {
            throw DocGenService.dmlAhe(e, DocGen_Settings__c.sObjectType);
        }

        // Auto-schedule or abort the reminder job
        String jobName = 'DocGen Signature Reminders';
        try {
            // Abort existing job if any
            /* code-analyzer-suppress ApexFlsViolation */
            List<CronTrigger> existing = [
                SELECT Id
                FROM CronTrigger
                WHERE CronJobDetail.Name = :jobName
                WITH USER_MODE
                LIMIT 1
            ]; // NOPMD
            for (CronTrigger ct : existing) {
                System.abortJob(ct.Id);
            }

            // Schedule new job if enabled
            if (enabled) {
                System.schedule(jobName, '0 0 * * * ?', new DocGenSignatureReminderSchedulable());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: Failed to schedule/abort reminder job: ' + e.getMessage());
        }
    }

    /**
     * Validates + normalizes the reminder-schedule CSV: digits separated by
     * commas, each entry 1-8760 hours, max 10 entries, returned sorted and
     * whitespace-free. Blank in → null out (legacy single-reminder mode).
     */
    private static String normalizeReminderSchedule(String schedule) {
        if (String.isBlank(schedule)) {
            return null;
        }
        List<Integer> offsets = new List<Integer>();
        for (String part : schedule.split(',')) {
            String trimmed = part.trim();
            if (!trimmed.isNumeric()) {
                throw DocGenService.ahe(
                    'Reminder schedule must be hour offsets separated by commas, e.g. 24, 72, 168.'
                );
            }
            Integer hours = Integer.valueOf(trimmed);
            if (hours < 1 || hours > 8760) {
                throw DocGenService.ahe('Each reminder offset must be between 1 and 8760 hours (1 year).');
            }
            offsets.add(hours);
        }
        if (offsets.size() > 10) {
            throw DocGenService.ahe('At most 10 reminders are allowed per schedule.');
        }
        offsets.sort();
        return String.join(offsets, ',');
    }

    /**
     * #verification — saves the org-default signer-verification settings (require email PIN,
     * pre-fill signer email). Templates and individual sends can override these.
     */
    @AuraEnabled
    public static void saveVerificationSettings(Boolean requireVerification, Boolean prefillEmail) {
        if (
            !FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()
        ) {
            throw DocGenService.ahe('Insufficient privileges to modify Portwood settings.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        // Stored inverted: require=false → skip=true. Default (require true) → skip false.
        settings.Signature_Skip_Email_Verification__c = (requireVerification == false);
        settings.Signature_Prefill_Signer_Email__c = prefillEmail == true;
        Set<String> verifFields = new Set<String>{
            'Signature_Skip_Email_Verification__c',
            'Signature_Prefill_Signer_Email__c'
        };
        DocGenFlsGuard.assertCreateable(settings, verifFields);
        DocGenFlsGuard.assertUpdateable(settings, verifFields);
        /* code-analyzer-suppress ApexFlsViolation */
        Database.upsert(settings, AccessLevel.SYSTEM_MODE);
    }

    /**
     * #367 — org-wide master switch for the "Decline to Sign" button. Resolved live on
     * every signing-page load (DocGenSignatureController.validateToken), not stamped
     * at send time, so flipping this also reaches already-sent, still-pending requests.
     * Default is off (Decline hidden). When on, each template still needs its own
     * Show_Signer_Decline__c opt-in before Decline appears on it (AND-gate, not an
     * override) — except source-document sends with no template, gated by this alone.
     * @param showDecline true turns the org-wide switch on; templates still gate individually.
     */
    @AuraEnabled
    public static void saveDeclineSettings(Boolean showDecline) {
        if (
            !FeatureManagement.checkPermission('DocGen_Admin_Access') &&
            !Schema.sObjectType.DocGen_Settings__c.isUpdateable()
        ) {
            throw DocGenService.ahe('Insufficient privileges to modify Portwood settings.');
        }
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Signature_Show_Decline__c = (showDecline == true);
        Set<String> declineFields = new Set<String>{ 'Signature_Show_Decline__c' };
        DocGenFlsGuard.assertCreateable(settings, declineFields);
        DocGenFlsGuard.assertUpdateable(settings, declineFields);
        /* code-analyzer-suppress ApexFlsViolation */
        Database.upsert(settings, AccessLevel.SYSTEM_MODE);
    }
}
