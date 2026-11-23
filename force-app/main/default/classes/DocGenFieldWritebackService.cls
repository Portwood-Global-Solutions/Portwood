/**
 * Signer form-field capture, validation, and decoupled record writeback.
 *
 * ─────────────────────────────────────────────────────────────────────────
 * WHY THIS IS A SEPARATE, SYSTEM-CONTEXT SUBSYSTEM
 * ─────────────────────────────────────────────────────────────────────────
 *
 * Portwood e-signing lets an admin configure extra "form fields" on a template
 * (DocGen_Template__c.Form_Fields_Config__c → formFields[]), each optionally mapped
 * to a base-object field. The guest signer fills them in during signing; the
 * values are (a) merged into the re-rendered signed PDF at {?key} positions,
 * (b) optionally listed on the signing certificate, and (c) written back to
 * the base record.
 *
 * The GUEST never performs DML on the base record. The guest only persists the
 * collected values as a validated JSON blob on DocGen_Signer__c.Field_Data_Json__c
 * (inside the existing token-bound, allowlisted guest write boundary — see
 * DocGenSignatureGuestSecurity). A platform event (DocGen_Field_Writeback__e),
 * published by the signature finalizer ONLY after the signed PDF is saved, is
 * consumed by DocGenFieldWritebackTrigger running as the Automated Process user;
 * that subscriber calls performWriteback() in system context.
 *
 * TWO INDEPENDENT SECURITY CONTROLS (both enforced here, neither optional):
 *   1. SERVER-DERIVED ALLOWLIST — the set of writable fields is rebuilt from
 *      the template config at write time (writeback==true). The guest's JSON
 *      keys are NEVER trusted to decide what gets written.
 *   2. PER-FIELD FLS — each target field is re-checked with isUpdateable(), and
 *      the DML runs Database.update(..., allOrNone=false, AccessLevel.USER_MODE)
 *      so the automation user's FLS + validation rules apply. A field the
 *      automation user can't write, or a validation-rule failure, is skipped +
 *      logged to DocGen_Signature_Audit__c and NEVER re-thrown into signing.
 *
 * `global without sharing`: global so subscriber Flows can route writeback via
 * the @InvocableMethod; without sharing because the subscriber runs as the
 * Automated Process user and the base-record write is intentionally a
 * system-context operation gated by USER_MODE FLS, not by record sharing.
 * ─────────────────────────────────────────────────────────────────────────
 */
global without sharing class DocGenFieldWritebackService { // NOPMD AvoidGlobalModifier - global required so subscriber Flows can call writeBackFields
    // Stable id grammar for a form-field key. Mirrors the cross-workstream
    // contract pinned with the frontend: key is [A-Za-z0-9_]+.
    private static final Pattern KEY_PATTERN = Pattern.compile('^[A-Za-z0-9_]+$');

    // This internal snapshot is written only from a sent request or its existing template.
    private static final String EMPTY_FORM_FIELDS = '{"formFields":[]}';

    public static void snapshotSendingRequests(
        List<DocGen_Signature_Request__c> requests,
        Map<Id, DocGen_Signature_Request__c> oldRequests
    ) {
        List<DocGen_Signature_Request__c> sending = new List<DocGen_Signature_Request__c>();
        Set<Id> templateIds = new Set<Id>();
        for (DocGen_Signature_Request__c request : requests) {
            if (
                request.Template__c != null &&
                request.Status__c != 'Draft' &&
                (oldRequests == null ||
                oldRequests.get(request.Id).Status__c == 'Draft')
            ) {
                templateIds.add(request.Template__c);
                sending.add(request);
            }
        }
        if (templateIds.isEmpty()) {
            return;
        }
        Map<Id, DocGen_Template__c> templates = new Map<Id, DocGen_Template__c>(
            [SELECT Id, Form_Fields_Config__c FROM DocGen_Template__c WHERE Id IN :templateIds WITH SYSTEM_MODE]
        );
        for (DocGen_Signature_Request__c request : sending) {
            DocGen_Template__c template = templates.get(request.Template__c);
            if (template != null) {
                request.Form_Fields_Snapshot__c = snapshotValue(template.Form_Fields_Config__c);
            }
        }
    }

    public static void preserveOpenRequestFields(
        List<DocGen_Template__c> templates,
        Map<Id, DocGen_Template__c> oldTemplates
    ) {
        Map<Id, String> previousByTemplate = new Map<Id, String>();
        for (DocGen_Template__c template : templates) {
            String oldConfig = oldTemplates.get(template.Id).Form_Fields_Config__c;
            if (
                oldConfig == null
                    ? template.Form_Fields_Config__c != null
                    : !oldConfig.equals(template.Form_Fields_Config__c)
            ) {
                Set<String> keys = new Set<String>();
                Boolean duplicate = false;
                for (FormFieldDef field : parseConfig(template.Form_Fields_Config__c)) {
                    String key = field.key.toLowerCase();
                    if (keys.contains(key)) {
                        duplicate = true;
                        break;
                    }
                    keys.add(key);
                }
                if (duplicate) {
                    template.Form_Fields_Config__c.addError('Signer merge tag keys must be unique.');
                } else {
                    previousByTemplate.put(template.Id, snapshotValue(oldConfig));
                }
            }
        }
        if (previousByTemplate.isEmpty()) {
            return;
        }
        Set<Id> templateIds = previousByTemplate.keySet();
        List<DocGen_Signature_Request__c> snapshots = new List<DocGen_Signature_Request__c>();
        for (DocGen_Signature_Request__c request : [
            SELECT Id, Template__c, Form_Fields_Snapshot__c
            FROM DocGen_Signature_Request__c
            WHERE Template__c IN :templateIds AND Status__c IN ('Sent', 'Viewed', 'In Progress')
            WITH SYSTEM_MODE
        ]) {
            if (String.isBlank(request.Form_Fields_Snapshot__c)) {
                snapshots.add(
                    new DocGen_Signature_Request__c(
                        Id = request.Id,
                        Form_Fields_Snapshot__c = previousByTemplate.get(request.Template__c)
                    )
                );
            }
        }
        if (!snapshots.isEmpty()) {
            Database.update(snapshots, AccessLevel.SYSTEM_MODE);
        }
    }

    private static String snapshotValue(String config) {
        return String.isBlank(config) ? EMPTY_FORM_FIELDS : config;
    }

    public static String requestConfig(DocGen_Signature_Request__c request) {
        return String.isNotBlank(request.Form_Fields_Snapshot__c)
            ? request.Form_Fields_Snapshot__c
            : (request.Template__r == null ? null : request.Template__r.Form_Fields_Config__c);
    }

    /**
     * One configured signer form field, parsed from the template's
     * Form_Fields_Config__c formFields[] array.
     */
    public class FormFieldDef {
        public String key;
        public String label;
        public String fieldApiName;
        public String type; // text | number | date | checkbox | picklist
        public Boolean required = false;
        public Boolean writeback = false;
        public String mergeTag;
        public List<String> choices = new List<String>();
        public Boolean listOnCertificate = false;
    }

    /**
     * Flow-invocable wrapper input — carries only the request Id. The writeback
     * field allowlist is re-derived from the template config (never from Flow
     * input) so this stays a safe automation entry point.
     */
    global class WritebackRequest {
        @InvocableVariable(
            required=true
            label='Signature Request Id'
            description='The Portwood Signature Request whose collected signer form-field values should be written back to the base record.'
        )
        @AuraEnabled
        global String requestId;

        global WritebackRequest() {
        }
    }

    /**
     * Parses the formFields[] array out of a template Form_Fields_Config__c JSON.
     * Tolerant of missing/blank config (returns an empty list) and of malformed
     * JSON (logs + returns empty) — writeback/merge degrade gracefully rather
     * than break the signing transaction. Unknown / malformed entries are
     * skipped; entries without a grammar-valid key are dropped.
     */
    public static List<FormFieldDef> parseConfig(String queryConfigJson) {
        List<FormFieldDef> defs = new List<FormFieldDef>();
        if (String.isBlank(queryConfigJson)) {
            return defs;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(queryConfigJson);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: form-field config parse failed: ' + e.getMessage());
            return defs;
        }
        if (!(parsed instanceof Map<String, Object>)) {
            return defs;
        }
        Object ffRaw = ((Map<String, Object>) parsed).get('formFields');
        if (!(ffRaw instanceof List<Object>)) {
            return defs;
        }
        for (Object item : (List<Object>) ffRaw) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> row = (Map<String, Object>) item;
            String key = stringVal(row.get('key'));
            if (String.isBlank(key) || !KEY_PATTERN.matcher(key).matches()) {
                // No valid stable id — unusable for capture, merge, or writeback.
                continue;
            }
            FormFieldDef def = new FormFieldDef();
            def.key = key;
            def.label = stringVal(row.get('label'));
            def.fieldApiName = stringVal(row.get('fieldApiName'));
            def.type = normalizeType(stringVal(row.get('type')));
            def.required = boolVal(row.get('required'));
            def.writeback = boolVal(row.get('writeback'));
            def.mergeTag = stringVal(row.get('mergeTag'));
            def.listOnCertificate = boolVal(row.get('listOnCertificate'));
            Object choicesRaw = row.get('choices');
            if (choicesRaw instanceof List<Object>) {
                for (Object c : (List<Object>) choicesRaw) {
                    if (c != null) {
                        def.choices.add(String.valueOf(c));
                    }
                }
            }
            defs.add(def);
        }
        return defs;
    }

    /**
     * PUBLIC-SAFE projection for the guest signing page (validateToken response).
     * Exposes ONLY {key,label,type,required,choices,listOnCertificate} — never the
     * writeback flag or the base-object field API name (the writeback allowlist is
     * re-derived server-side at completion). listOnCertificate is a presentation
     * flag, not a capability, so the drawn-path client can render it on its
     * Certificate of Completion just like the server cert does.
     */
    public static List<Object> publicFormFields(String queryConfigJson) {
        List<Object> publicDefs = new List<Object>();
        for (FormFieldDef def : parseConfig(queryConfigJson)) {
            publicDefs.add(
                new Map<String, Object>{
                    'key' => def.key,
                    'label' => def.label,
                    'type' => def.type,
                    'required' => def.required,
                    'choices' => def.choices,
                    'listOnCertificate' => def.listOnCertificate
                }
            );
        }
        return publicDefs;
    }

    /**
     * Validates the guest-supplied {key:value} JSON against the template config:
     *   • enforces `required` (throws AuraHandledException naming the field),
     *   • coerces each value by `type`,
     *   • DROPS unknown keys (anything not in the config),
     * and returns a clean, config-ORDERED map ready to serialize onto
     * DocGen_Signer__c.Field_Data_Json__c. Returns null when there are no
     * configured form fields (caller then writes nothing).
     */
    public static Map<String, Object> validateAndClean(List<FormFieldDef> defs, String incomingJson) {
        if (defs == null || defs.isEmpty()) {
            return null;
        }
        Map<String, Object> incoming = new Map<String, Object>();
        if (String.isNotBlank(incomingJson)) {
            try {
                Object parsed = JSON.deserializeUntyped(incomingJson);
                if (parsed instanceof Map<String, Object>) {
                    incoming = (Map<String, Object>) parsed;
                }
            } catch (Exception e) {
                throw new AuraHandledException('The submitted form data could not be read.');
            }
        }
        // Config-ordered clean map — unknown keys in `incoming` are simply never
        // read, so they are dropped.
        Map<String, Object> clean = new Map<String, Object>();
        for (FormFieldDef def : defs) {
            Object raw = incoming.get(def.key);
            Object coerced = coerceByType(raw, def.type);
            Boolean isEmpty = coerced == null || (coerced instanceof String && String.isBlank((String) coerced));
            if (def.required && isEmpty) {
                String fieldLabel = String.isNotBlank(def.label) ? def.label : def.key;
                throw new AuraHandledException('Please complete the required field: ' + fieldLabel + '.');
            }
            clean.put(def.key, coerced);
        }
        return clean;
    }

    /**
     * Aggregates the collected form-field values across every signer on the
     * request into a single {key:value} map for the finalize re-render.
     * Last-writer-wins (signers ordered by Sort_Order__c; later signers'
     * non-null values override earlier ones). Per-signer distinct fields are
     * out of scope this milestone (documented known limitation). Runs in the
     * async finalize (Automated Process) context — SYSTEM_MODE required.
     */
    public static Map<String, Object> collectValues(Id requestId) {
        Map<String, Object> merged = new Map<String, Object>();
        if (requestId == null) {
            return merged;
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Field_Data_Json__c', 'Signature_Request__c', 'Sort_Order__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        // NOTE: Field_Data_Json__c is a LongTextArea and cannot be filtered in a
        // SOQL WHERE clause, so the null/blank filter is applied in Apex below.
        List<DocGen_Signer__c> signers = [
            SELECT Field_Data_Json__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets
        for (DocGen_Signer__c s : signers) {
            if (String.isBlank(s.Field_Data_Json__c)) {
                continue;
            }
            try {
                Object parsed = JSON.deserializeUntyped(s.Field_Data_Json__c);
                if (parsed instanceof Map<String, Object>) {
                    for (String k : ((Map<String, Object>) parsed).keySet()) {
                        Object v = ((Map<String, Object>) parsed).get(k);
                        if (v != null) {
                            merged.put(k, v); // last-writer-wins
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Portwood: collectValues parse skip: ' + e.getMessage());
            }
        }
        return merged;
    }

    /**
     * Writes collected signer form-field values back to the base record.
     *
     * SECURITY (see class header): the writable allowlist is rebuilt from the
     * template config (writeback==true), NEVER from the guest JSON keys; each
     * field is re-checked with isUpdateable(); the DML runs USER_MODE with
     * allOrNone=false so the automation user's FLS + validation rules apply and
     * a single failure neither escalates nor strands signing. All failures are
     * logged to DocGen_Signature_Audit__c and swallowed — this method must
     * NEVER re-throw into the signing/finalize path.
     */
    public static void performWriteback(Id requestId) {
        if (requestId == null) {
            return;
        }
        try {
            // 1. Load request → Template config + Related_Record_Id__c.
            DocGenFlsGuard.assertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{ 'Template__c', 'Related_Record_Id__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> reqs = [
                SELECT Related_Record_Id__c, Form_Fields_Snapshot__c, Template__r.Form_Fields_Config__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets
            if (reqs.isEmpty()) {
                return;
            }
            DocGen_Signature_Request__c req = reqs[0];
            if (String.isBlank(req.Related_Record_Id__c) || req.Template__r == null) {
                return; // capture-only template or no base record — nothing to write.
            }

            List<FormFieldDef> defs = parseConfig(requestConfig(req));
            // 2. Allowlist = config fields where writeback==true AND a base field
            //    is mapped. NEVER derived from the guest JSON keys.
            Map<String, FormFieldDef> writebackDefs = new Map<String, FormFieldDef>();
            for (FormFieldDef def : defs) {
                if (def.writeback && String.isNotBlank(def.fieldApiName)) {
                    writebackDefs.put(def.key, def);
                }
            }
            if (writebackDefs.isEmpty()) {
                return;
            }

            // Writeback is single-signer only. On a multi-signer request every signer
            // fills the same template-scoped fields, so there is no unambiguous single
            // value to write (collectValues would merge them last-writer-wins). Skip the
            // record write — capture + per-signer certificate attribution still happen.
            DocGenFlsGuard.assertAccessible(DocGen_Signer__c.sObjectType, new Set<String>{ 'Signature_Request__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Integer signerCount = [
                SELECT COUNT()
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :requestId
                WITH SYSTEM_MODE
            ];
            if (signerCount > 1) {
                logWritebackError(
                    requestId,
                    'Form-field writeback skipped — multi-signer request (' +
                        signerCount +
                        ' signers); writeback applies to single-signer requests only.'
                );
                return;
            }

            Map<String, Object> values = collectValues(requestId);
            if (values.isEmpty()) {
                return;
            }

            Id recordId;
            try {
                recordId = (Id) req.Related_Record_Id__c;
            } catch (Exception badId) {
                logWritebackError(requestId, 'Invalid Related Record Id for writeback: ' + badId.getMessage());
                return;
            }
            SObjectType targetType = recordId.getSObjectType();
            Map<String, Schema.SObjectField> fieldMap = targetType.getDescribe().fields.getMap();

            SObject record = targetType.newSObject(recordId);
            Boolean anySet = false;
            for (String key : writebackDefs.keySet()) {
                FormFieldDef def = writebackDefs.get(key);
                if (!values.containsKey(key)) {
                    continue;
                }
                Schema.SObjectField sof = fieldMap.get(def.fieldApiName.toLowerCase());
                if (sof == null) {
                    logWritebackError(requestId, 'Writeback target field not found: ' + def.fieldApiName);
                    continue;
                }
                Schema.DescribeFieldResult dfr = sof.getDescribe();
                // 3. Per-field FLS re-check (defense in depth alongside USER_MODE).
                if (!dfr.isUpdateable()) {
                    logWritebackError(requestId, 'Writeback target field not updateable: ' + def.fieldApiName);
                    continue;
                }
                try {
                    Object typed = coerceForDisplayType(values.get(key), dfr.getType());
                    record.put(sof, typed);
                    anySet = true;
                } catch (Exception coerceEx) {
                    logWritebackError(
                        requestId,
                        'Writeback coercion failed for ' + def.fieldApiName + ': ' + coerceEx.getMessage()
                    );
                }
            }

            if (!anySet) {
                return;
            }

            // 4. USER_MODE + allOrNone=false: automation user's FLS + validation
            //    rules apply; partial success is allowed.
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.SaveResult sr = Database.update(record, false, AccessLevel.USER_MODE);
            if (!sr.isSuccess()) {
                List<String> msgs = new List<String>();
                for (Database.Error err : sr.getErrors()) {
                    msgs.add(err.getStatusCode() + ': ' + err.getMessage());
                }
                logWritebackError(requestId, 'Writeback DML failed: ' + String.join(msgs, '; '));
            }
        } catch (Exception e) {
            // 5. NEVER re-throw into the signing/finalize path.
            logWritebackError(requestId, e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /**
     * Flow-invocable entry point so an admin can route writeback through a
     * record-triggered Flow instead of the auto-subscriber. Carries only the
     * request Id; the allowlist is re-derived server-side.
     */
    @InvocableMethod(
        label='Portwood: Write Back Signer Form Fields'
        description='Writes the collected signer form-field values for a completed signature request back to its related record. The writable fields are re-derived from the template config; failures are logged, never thrown.'
        category='Document Generation'
    )
    global static void writeBackFields(List<WritebackRequest> requests) {
        if (requests == null) {
            return;
        }
        for (WritebackRequest r : requests) {
            if (r != null && String.isNotBlank(r.requestId)) {
                try {
                    performWriteback((Id) r.requestId);
                } catch (Exception e) {
                    // Defensive: performWriteback already swallows, but a bad Id
                    // cast here must not break the Flow / event batch.
                    System.debug(LoggingLevel.WARN, 'Portwood: writeBackFields skip: ' + e.getMessage());
                }
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────────────

    /**
     * Coerces a raw JSON value to the form-field config `type` for capture/merge
     * (text|number|date|checkbox|picklist). Returns the cleaned value or null.
     */
    @TestVisible
    private static Object coerceByType(Object raw, String type) {
        if (raw == null) {
            return null;
        }
        String s = String.valueOf(raw).trim();
        if (String.isBlank(s)) {
            return type == 'checkbox' ? (Object) false : null;
        }
        if (type == 'number') {
            try {
                return Decimal.valueOf(s);
            } catch (Exception e) {
                throw new AuraHandledException('"' + s + '" is not a valid number.');
            }
        } else if (type == 'checkbox') {
            return s.equalsIgnoreCase('true') || s == '1' || s.equalsIgnoreCase('yes') || s.equalsIgnoreCase('on');
        } else if (type == 'date') {
            try {
                // Accept ISO yyyy-MM-dd (native HTML date input) — validate by parse.
                Date.valueOf(s);
                return s;
            } catch (Exception e) {
                throw new AuraHandledException('"' + s + '" is not a valid date.');
            }
        }
        // text | picklist | unknown — store as trimmed string.
        return s;
    }

    /**
     * Coerces a captured value to the target base-field Schema.DisplayType for
     * writeback DML. Conservative — supports the common scalar types; anything
     * unhandled falls through to the String form and lets USER_MODE DML reject
     * it (logged, not thrown).
     */
    @TestVisible
    private static Object coerceForDisplayType(Object value, Schema.DisplayType dt) {
        if (value == null) {
            return null;
        }
        String s = String.valueOf(value).trim();
        if (dt == Schema.DisplayType.DOUBLE || dt == Schema.DisplayType.CURRENCY || dt == Schema.DisplayType.PERCENT) {
            return String.isBlank(s) ? null : Decimal.valueOf(s);
        } else if (dt == Schema.DisplayType.INTEGER) {
            // INTEGER fields reject a Long assignment ("Illegal assignment from Long
            // to Integer"); coerce to Integer explicitly.
            return String.isBlank(s) ? null : Integer.valueOf(Decimal.valueOf(s).intValue());
        } else if (dt == Schema.DisplayType.LONG) {
            return String.isBlank(s) ? null : Long.valueOf(s);
        } else if (dt == Schema.DisplayType.BOOLEAN) {
            return value instanceof Boolean
                ? (Boolean) value
                : (s.equalsIgnoreCase('true') || s == '1' || s.equalsIgnoreCase('yes'));
        } else if (dt == Schema.DisplayType.DATE) {
            return String.isBlank(s) ? null : Date.valueOf(s);
        } else if (dt == Schema.DisplayType.DATETIME) {
            return String.isBlank(s) ? null : (Object) Datetime.valueOf(s.replace('T', ' '));
        }
        // STRING/TEXTAREA/PICKLIST/EMAIL/PHONE/URL/REFERENCE/etc. — string form.
        return s;
    }

    private static String normalizeType(String type) {
        if (String.isBlank(type)) {
            return 'text';
        }
        String t = type.trim().toLowerCase();
        if (t == 'text' || t == 'number' || t == 'date' || t == 'checkbox' || t == 'picklist') {
            return t;
        }
        return 'text';
    }

    private static String stringVal(Object o) {
        return o == null ? null : String.valueOf(o);
    }

    private static Boolean boolVal(Object o) {
        if (o instanceof Boolean) {
            return (Boolean) o;
        }
        return o != null && String.valueOf(o).equalsIgnoreCase('true');
    }

    /**
     * Logs a writeback failure to DocGen_Signature_Audit__c. Best-effort —
     * swallows its own errors so a logging failure can never escalate.
     */
    private static void logWritebackError(Id requestId, String message) {
        System.debug(LoggingLevel.ERROR, 'Portwood: writeback error (req ' + requestId + '): ' + message);
        // ALSO to DocGen_Error_Log__c, not only to the signature audit trail.
        // Writeback failures used to land exclusively on
        // DocGen_Signature_Audit__c.Error_Message__c, so "check the Error Log"
        // genuinely did not find them and nothing said so. The audit row stays —
        // it is the tamper-evident record for that request — but the error log
        // is where someone debugging actually looks.
        DocGenErrorLogger.warn(
            'DocGenFieldWritebackService',
            'Form-field writeback',
            'Writeback did not complete: ' + message,
            null,
            String.valueOf(requestId)
        );
        DocGenErrorLogger.flush();
        try {
            DocGen_Signature_Audit__c errAudit = new DocGen_Signature_Audit__c();
            errAudit.Signature_Request__c = requestId;
            errAudit.Signer_Name__c = 'SYSTEM (writeback)';
            errAudit.Error_Message__c = message != null ? message.left(32768) : null;
            errAudit.Signed_Date__c = System.now();
            DocGenFlsGuard.assertCreateable(
                errAudit,
                new Set<String>{ 'Signature_Request__c', 'Signer_Name__c', 'Error_Message__c', 'Signed_Date__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(new List<DocGen_Signature_Audit__c>{ errAudit }, false, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Portwood: writeback audit log failed: ' + e.getMessage());
        }
    }
}
