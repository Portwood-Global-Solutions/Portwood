/**
 * Front-end admin for the one-click Portwood Button configs (DocGen_Button__mdt).
 *
 * Lets Portwood admins create / update / deactivate the record-page document
 * buttons from the Command Hub UI instead of Setup > Custom Metadata Types.
 * Custom metadata can't be written with DML, so saves go through the Apex
 * Metadata API (Metadata.Operations.enqueueDeployment) and are ASYNC — the LWC
 * re-queries after a short delay to show the new/updated row.
 *
 * Namespace-safe: the type + field API names are taken from describe tokens, so
 * the deployed fullName / field names carry the package namespace correctly in
 * subscriber orgs. Access is gated by the DocGen_Button_Manager permission set
 * (the only grant for this class); saves additionally require the platform
 * "Customize Application" / "Modify Metadata" permission (see canManageButtons).
 */
public with sharing class DocGenButtonAdminController {
    public class ButtonConfigDTO {
        @AuraEnabled
        public String developerName;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String objectApiName;
        @AuraEnabled
        public String templateApiName;
        @AuraEnabled
        public String templateId;
        @AuraEnabled
        public String documentTitle;
        @AuraEnabled
        public String outputFormatOverride;
        @AuraEnabled
        public Boolean saveToRecord;
        @AuraEnabled
        public Decimal sortOrder;
        @AuraEnabled
        public Boolean active;
        @AuraEnabled
        public String recordTypeDeveloperNames;
    }

    public class Option {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String templateType;
        @AuraEnabled
        public Boolean lockOutputFormat;
        public Option(String l, String v) {
            this.label = l;
            this.value = v;
        }
        public Option(String l, String v, String templateType, Boolean lockOutputFormat) {
            this(l, v);
            this.templateType = templateType;
            this.lockOutputFormat = lockOutputFormat;
        }
    }

    /** All button configs (active + inactive) for the management list. */
    @AuraEnabled(cacheable=false)
    public static List<ButtonConfigDTO> getButtonConfigs() {
        List<ButtonConfigDTO> out = new List<ButtonConfigDTO>();
        // Custom metadata is admin-authored config (no row-level FLS/CRUD); this
        // class is reachable only via the DocGen_Button_Manager permission set.
        /* code-analyzer-suppress ApexCRUDViolation ApexFlsViolation */
        List<DocGen_Button__mdt> rows = [
            SELECT
                DeveloperName,
                MasterLabel,
                Object_API_Name__c,
                Template_API_Name__c,
                Template_Id__c,
                Document_Title__c,
                Output_Format_Override__c,
                Save_To_Record__c,
                Sort_Order__c,
                Active__c,
                Record_Type_Developer_Names__c
            FROM DocGen_Button__mdt
            ORDER BY Object_API_Name__c, Sort_Order__c NULLS LAST, MasterLabel
        ]; // NOPMD ApexCRUDViolation - button-manager-gated CMDT config read
        for (DocGen_Button__mdt c : rows) {
            ButtonConfigDTO d = new ButtonConfigDTO();
            d.developerName = c.DeveloperName;
            d.label = c.MasterLabel;
            d.objectApiName = c.Object_API_Name__c;
            d.templateApiName = c.Template_API_Name__c;
            d.templateId = c.Template_Id__c;
            d.documentTitle = c.Document_Title__c;
            d.outputFormatOverride = c.Output_Format_Override__c;
            d.saveToRecord = c.Save_To_Record__c;
            d.sortOrder = c.Sort_Order__c;
            d.active = c.Active__c;
            d.recordTypeDeveloperNames = c.Record_Type_Developer_Names__c;
            out.add(d);
        }
        return out;
    }

    /** Active templates as options; value is "key:<ApiName>" (preferred, env-stable)
     *  or "id:<Id>" when a template has no API name. The LWC splits on the prefix. */
    @AuraEnabled(cacheable=true)
    public static List<Option> getTemplateOptions() {
        List<Option> out = new List<Option>();
        // Button-manager-gated read of the template list for a picker; Name /
        // API_Name are label fields. SYSTEM_MODE avoids the managed-package USER_MODE
        // namespace pitfall (see DocGenController); class access is the gate.
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Name', 'API_Name__c', 'Type__c', 'Lock_Output_Format__c' }
        );
        /* code-analyzer-suppress ApexCRUDViolation ApexFlsViolation */
        List<DocGen_Template__c> tpls = [
            SELECT Id, Name, API_Name__c, Type__c, Lock_Output_Format__c
            FROM DocGen_Template__c
            WHERE Is_Active__c = TRUE
            WITH SYSTEM_MODE
            ORDER BY Name
        ]; // NOPMD ApexCRUDViolation - button-manager-gated template picker read
        for (DocGen_Template__c t : tpls) {
            Boolean hasKey = String.isNotBlank(t.API_Name__c);
            out.add(
                new Option(
                    hasKey ? t.Name + ' (' + t.API_Name__c + ')' : t.Name,
                    hasKey ? 'key:' + t.API_Name__c : 'id:' + t.Id,
                    t.Type__c,
                    t.Lock_Output_Format__c
                )
            );
        }
        return out;
    }

    /** Active, non-master record types for an object — the record-type checklist. */
    @AuraEnabled(cacheable=true)
    public static List<Option> getObjectRecordTypes(String objectApiName) {
        List<Option> out = new List<Option>();
        if (String.isBlank(objectApiName)) {
            return out;
        }
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            return out;
        }
        for (Schema.RecordTypeInfo rti : sot.getDescribe().getRecordTypeInfos()) {
            if (!rti.isAvailable() || rti.isMaster()) {
                continue;
            }
            out.add(new Option(rti.getName(), rti.getDeveloperName()));
        }
        return out;
    }

    /**
     * Create or update a button config via the Metadata API. Returns the async
     * deploy job Id (null in tests, where Metadata deploys can't run). Re-saving
     * an existing developerName updates it; set active=false to "delete" (hide).
     */
    @AuraEnabled
    public static Id saveButtonConfig(Map<String, Object> cfg) {
        assertCanManage();
        if (cfg == null) {
            throw new AuraHandledException('No button details were provided.');
        }
        // A Map param is used (not a typed DTO) so a single field's JS type — e.g.
        // a numeric sort order that arrives as a string — can never fail the whole
        // deserialization and leave the config looking empty.
        String objectApiName = str(cfg, 'objectApiName');
        String templateApiName = str(cfg, 'templateApiName');
        String templateId = str(cfg, 'templateId');
        String label = str(cfg, 'label');

        if (String.isBlank(objectApiName)) {
            throw new AuraHandledException('An object is required.');
        }
        if (String.isBlank(templateApiName) && String.isBlank(templateId)) {
            throw new AuraHandledException('Choose a template.');
        }
        String devName = String.isNotBlank(str(cfg, 'developerName'))
            ? str(cfg, 'developerName')
            : sanitizeDevName(label);
        if (String.isBlank(devName)) {
            throw new AuraHandledException('A label is required so the button can be named.');
        }

        Schema.DescribeSObjectResult dsr = DocGen_Button__mdt.sObjectType.getDescribe();

        Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
        cmd.fullName = dsr.getName() + '.' + devName; // namespaced type + record dev name
        cmd.label = String.isNotBlank(label) ? label : devName;

        addValue(cmd, DocGen_Button__mdt.Object_API_Name__c, objectApiName);
        addValue(cmd, DocGen_Button__mdt.Template_API_Name__c, templateApiName);
        addValue(cmd, DocGen_Button__mdt.Template_Id__c, templateId);
        addValue(cmd, DocGen_Button__mdt.Document_Title__c, str(cfg, 'documentTitle'));
        addValue(cmd, DocGen_Button__mdt.Output_Format_Override__c, str(cfg, 'outputFormatOverride'));
        addValue(cmd, DocGen_Button__mdt.Save_To_Record__c, cfg.get('saveToRecord') == true);
        addValue(cmd, DocGen_Button__mdt.Sort_Order__c, dec(cfg, 'sortOrder'));
        addValue(cmd, DocGen_Button__mdt.Active__c, cfg.get('active') != false); // default active
        addValue(cmd, DocGen_Button__mdt.Record_Type_Developer_Names__c, str(cfg, 'recordTypeDeveloperNames'));

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cmd);
        if (Test.isRunningTest()) {
            return null; // Metadata deploys are a no-op / not permitted in test context
        }
        return Metadata.Operations.enqueueDeployment(container, new DeployCallback());
    }

    /** Map value as a trimmed String (null when absent/blank). */
    private static String str(Map<String, Object> m, String key) {
        Object v = m == null ? null : m.get(key);
        if (v == null) {
            return null;
        }
        String s = String.valueOf(v).trim();
        return String.isBlank(s) ? null : s;
    }

    /** Map value as a Decimal, coercing a numeric string (null when absent/blank). */
    private static Decimal dec(Map<String, Object> m, String key) {
        Object v = m == null ? null : m.get(key);
        if (v == null) {
            return null;
        }
        if (v instanceof Decimal) {
            return (Decimal) v;
        }
        if (v instanceof Integer) {
            return (Decimal) (Integer) v;
        }
        String s = String.valueOf(v).trim();
        if (String.isBlank(s)) {
            return null;
        }
        try {
            return Decimal.valueOf(s);
        } catch (Exception e) {
            return null;
        }
    }

    private static void addValue(Metadata.CustomMetadata cmd, Schema.SObjectField field, Object val) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field.getDescribe().getName(); // namespaced field API name
        v.value = val;
        cmd.values.add(v);
    }

    /** Label -> a valid, unique-ish CMDT DeveloperName (letters/digits/underscores). */
    @TestVisible
    private static String sanitizeDevName(String label) {
        if (String.isBlank(label)) {
            return null;
        }
        String s = label.replaceAll('[^a-zA-Z0-9_]', '_').replaceAll('_+', '_');
        s = s.removeStart('_').removeEnd('_');
        if (String.isBlank(s)) {
            return null;
        }
        if (!Pattern.matches('^[A-Za-z].*', s)) {
            s = 'B_' + s;
        }
        return s.length() > 40 ? s.substring(0, 40) : s;
    }

    public class DeployCallback implements Metadata.DeployCallback {
        public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
            // Fire-and-forget: the LWC re-queries getButtonConfigs after the deploy
            // window. Failures surface to the admin on the next refresh (the row
            // simply won't appear / update).
        }
    }

    /**
     * Whether the current user can actually create/edit buttons — i.e. holds the
     * platform metadata-write permission the Metadata API deploy requires
     * ("Customize Application" or "Modify Metadata Through Metadata API
     * Functions"). Reaching this method at all already implies the
     * DocGen_Button_Manager permission set (it's the only grant for this class);
     * this is the additional runtime gate. The Command Hub hides the Buttons tab
     * when this returns false, and saveButtonConfig enforces it.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean canManageButtons() {
        return userCanModifyMetadata();
    }

    // Test seam: force the metadata-permission verdict so tests are deterministic
    // regardless of the running user's profile. Null = evaluate for real.
    @TestVisible
    private static Boolean testMetadataOverride = null;

    @TestVisible
    private static Boolean userCanModifyMetadata() {
        if (testMetadataOverride != null) {
            return testMetadataOverride;
        }
        for (PermissionSetAssignment psa : [
            SELECT PermissionSet.PermissionsCustomizeApplication, PermissionSet.PermissionsModifyMetadata
            FROM PermissionSetAssignment
            WHERE AssigneeId = :UserInfo.getUserId()
            WITH USER_MODE
        ]) {
            if (psa.PermissionSet.PermissionsCustomizeApplication || psa.PermissionSet.PermissionsModifyMetadata) {
                return true;
            }
        }
        return false;
    }

    private static void assertCanManage() {
        if (!userCanModifyMetadata()) {
            throw new AuraHandledException(
                'Creating or editing document buttons requires the "Customize Application" ' +
                    '(or "Modify Metadata Through Metadata API Functions") permission. ' +
                    'Ask your Salesforce administrator to grant it — this package cannot.'
            );
        }
    }
}
