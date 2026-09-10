// DocGen E2E Test 01 — Permission Set Validation
// Run: sf apex run --target-org <org> -f scripts/e2e-01-permissions.apex

Integer pass = 0;
Integer fail = 0;

Boolean containsNs(Set<String> s, String val) {
    if (s.contains(val) || s.contains('portwoodglobal__' + val)) {
        return true;
    }
    // Object.Field needs BOTH halves prefixed. In a managed package
    // 'DocGen_Job__c.Label__c' is stored as
    // 'portwoodglobal__DocGen_Job__c.portwoodglobal__Label__c', and prefixing the
    // whole string once only produces 'portwoodglobal__DocGen_Job__c.Label__c',
    // which matches nothing. That reported Label__c and Merge_Only__c as ungranted
    // when the permission set grants both — a FALSE FAILURE that survived because
    // object-only lookups (the common case here) work fine with one prefix.
    if (val.contains('.')) {
        String obj = val.substringBefore('.');
        String fld = val.substringAfter('.');
        if (
            s.contains('portwoodglobal__' + obj + '.portwoodglobal__' + fld) ||
            s.contains(obj + '.portwoodglobal__' + fld)
        ) {
            return true;
        }
    }
    return false;
}

Boolean containsFld(Set<String> s, String obj, String fld) {
    return s.contains(obj + '.' + fld) ||
        s.contains('portwoodglobal__' + obj + '.' + fld) ||
        s.contains(obj + '.portwoodglobal__' + fld) ||
        s.contains('portwoodglobal__' + obj + '.portwoodglobal__' + fld);
}

// ===== DocGen_Admin Permission Set =====
try {
    List<PermissionSet> aps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Admin' LIMIT 1];
    if (aps.isEmpty()) {
        fail++;
        System.debug('ADMIN EXISTS: FAIL — DocGen_Admin not found');
    } else {
        pass++;
        Id psId = aps[0].Id;

        // Apex class accesses
        Set<String> cls = new Set<String>();
        Set<Id> clsIds = new Set<Id>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId = :psId AND SetupEntityType = 'ApexClass'
        ]) {
            clsIds.add(s.SetupEntityId);
        }
        // Bulk name lookup — a SOQL-in-loop here scaled with the number of
        // granted entries and blew the 100-query limit as the permsets grew.
        for (ApexClass a : [SELECT Name FROM ApexClass WHERE Id IN :clsIds]) {
            cls.add(a.Name);
        }

        // Core classes
        Boolean coreOk = cls.contains('DocGenController') && cls.contains('DocGenService');
        if (coreOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN CORE CLASSES: FAIL');
        }

        // Bulk classes
        Boolean bulkOk = cls.contains('DocGenBulkController');
        if (bulkOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN BULK CLASS: FAIL');
        }

        // Signature classes
        Boolean sigOk = cls.contains('DocGenSignatureController') && cls.contains('DocGenAuthenticatorController');
        if (sigOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN SIGNATURE CLASSES: FAIL');
        }

        // Setup classes
        Boolean setupOk = cls.contains('DocGenSetupController');
        if (setupOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN SETUP CLASS: FAIL');
        }

        // Sender controller
        Boolean senderOk = cls.contains('DocGenSignatureSenderController');
        if (senderOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN SENDER CLASS: FAIL');
        }

        // Flow invocables (signature + giant query)
        Boolean sigFlowOk = cls.contains('DocGenSignatureFlowAction');
        if (sigFlowOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN FLOW CLASS DocGenSignatureFlowAction: FAIL');
        }

        Boolean gqFlowOk = cls.contains('DocGenGiantQueryFlowAction');
        if (gqFlowOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN FLOW CLASS DocGenGiantQueryFlowAction: FAIL');
        }

        Boolean signerTypeOk = cls.contains('DocGenSigner');
        if (signerTypeOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN CLASS DocGenSigner: FAIL');
        }

        Boolean reminderSchedOk = cls.contains('DocGenSignatureReminderSchedulable');
        if (reminderSchedOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN CLASS DocGenSignatureReminderSchedulable: FAIL');
        }

        // VF page accesses
        Set<String> apgs = new Set<String>();
        Set<Id> apgIds = new Set<Id>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId = :psId AND SetupEntityType = 'ApexPage'
        ]) {
            apgIds.add(s.SetupEntityId);
        }
        // Bulk name lookup — see the ApexClass note above.
        for (ApexPage a : [SELECT Name FROM ApexPage WHERE Id IN :apgIds]) {
            apgs.add(a.Name);
        }
        Boolean guideOk = apgs.contains('DocGenGuide');
        if (guideOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN PAGE DocGenGuide: FAIL');
        }
        Boolean verifyOk = apgs.contains('DocGenVerify');
        if (verifyOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN PAGE DocGenVerify: FAIL');
        }

        // Object permissions — templates, jobs, signature objects
        Set<String> objs = new Set<String>();
        for (ObjectPermissions op : [
            SELECT SobjectType
            FROM ObjectPermissions
            WHERE ParentId = :psId AND PermissionsRead = TRUE
        ]) {
            objs.add(op.SobjectType);
        }

        if (containsNs(objs, 'DocGen_Template__c')) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Template__c: FAIL');
        }

        if (containsNs(objs, 'DocGen_Job__c')) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Job__c: FAIL');
        }

        if (containsNs(objs, 'DocGen_Signature_Request__c')) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Signature_Request__c: FAIL');
        }

        if (containsNs(objs, 'DocGen_Signer__c')) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Signer__c: FAIL');
        }

        if (containsNs(objs, 'DocGen_Signature_Audit__c')) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Signature_Audit__c: FAIL');
        }

        if (containsNs(objs, 'DocGen_Signature_Placement__c')) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Signature_Placement__c: FAIL');
        }

        if (containsNs(objs, 'DocGen_Saved_Query__c')) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN OBJ DocGen_Saved_Query__c: FAIL');
        }

        // Key signature field permissions
        Set<String> flds = new Set<String>();
        for (FieldPermissions fp : [
            SELECT Field
            FROM FieldPermissions
            WHERE ParentId = :psId AND PermissionsRead = TRUE
        ]) {
            flds.add(fp.Field);
        }

        Boolean pinHashOk = containsFld(flds, 'DocGen_Signer__c', 'PIN_Hash__c');
        if (pinHashOk) {
            pass++;
        } else {
            fail++;
            System.debug(
                'ADMIN FLD PIN_Hash__c: FAIL — sample: ' + (flds.size() > 0 ? new List<String>(flds)[0] : 'empty')
            );
        }

        Boolean tokenOk = containsFld(flds, 'DocGen_Signer__c', 'Secure_Token__c');
        if (tokenOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN FLD Secure_Token__c: FAIL');
        }

        Boolean hashFieldOk = containsFld(flds, 'DocGen_Signature_Audit__c', 'Document_Hash_SHA256__c');
        if (hashFieldOk) {
            pass++;
        } else {
            fail++;
            System.debug('ADMIN FLD Document_Hash_SHA256__c: FAIL');
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('ADMIN PERMS: FAIL — ' + e.getMessage());
}

// ===== DocGen_User Permission Set =====
try {
    List<PermissionSet> ups = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1];
    if (ups.isEmpty()) {
        fail++;
        System.debug('USER EXISTS: FAIL — DocGen_User not found');
    } else {
        pass++;
        Id upsId = ups[0].Id;

        Set<String> uo = new Set<String>();
        for (ObjectPermissions op : [
            SELECT SobjectType
            FROM ObjectPermissions
            WHERE ParentId = :upsId AND PermissionsRead = TRUE
        ]) {
            uo.add(op.SobjectType);
        }

        if (containsNs(uo, 'DocGen_Template__c')) {
            pass++;
        } else {
            fail++;
            System.debug('USER READ DocGen_Template__c: FAIL');
        }

        if (containsNs(uo, 'DocGen_Signature_Request__c')) {
            pass++;
        } else {
            fail++;
            System.debug('USER READ DocGen_Signature_Request__c: FAIL');
        }

        if (containsNs(uo, 'DocGen_Signer__c')) {
            pass++;
        } else {
            fail++;
            System.debug('USER READ DocGen_Signer__c: FAIL');
        }

        // User class accesses
        Set<String> ucls = new Set<String>();
        Set<Id> uclsIds = new Set<Id>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId = :upsId AND SetupEntityType = 'ApexClass'
        ]) {
            uclsIds.add(s.SetupEntityId);
        }
        // Bulk name lookup.
        for (ApexClass a : [SELECT Name FROM ApexClass WHERE Id IN :uclsIds]) {
            ucls.add(a.Name);
        }
        Boolean uClsOk = ucls.contains('DocGenController');
        if (uClsOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER CLASS DocGenController: FAIL');
        }

        Boolean uFlowOk = ucls.contains('DocGenSignatureFlowAction');
        if (uFlowOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER CLASS DocGenSignatureFlowAction: FAIL');
        }

        Boolean uGqFlowOk = ucls.contains('DocGenGiantQueryFlowAction');
        if (uGqFlowOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER CLASS DocGenGiantQueryFlowAction: FAIL');
        }

        Boolean uAuthOk = ucls.contains('DocGenAuthenticatorController');
        if (uAuthOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER CLASS DocGenAuthenticatorController: FAIL');
        }

        Boolean uSignerTypeOk = ucls.contains('DocGenSigner');
        if (uSignerTypeOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER CLASS DocGenSigner: FAIL');
        }

        Boolean uSigningHelpersOk =
            ucls.contains('DocGenSignatureSubmitter') &&
            ucls.contains('DocGenSignatureValidator') &&
            ucls.contains('DocGenSignatureFinalizer');
        if (uSigningHelpersOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER custom signing helpers: FAIL');
        }

        Set<String> upgs = new Set<String>();
        Set<Id> upgIds = new Set<Id>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId
            FROM SetupEntityAccess
            WHERE ParentId = :upsId AND SetupEntityType = 'ApexPage'
        ]) {
            upgIds.add(s.SetupEntityId);
        }
        // Bulk name lookup.
        for (ApexPage a : [SELECT Name FROM ApexPage WHERE Id IN :upgIds]) {
            upgs.add(a.Name);
        }
        Boolean uVerifyOk = upgs.contains('DocGenVerify');
        if (uVerifyOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER PAGE DocGenVerify: FAIL');
        }

        Set<String> editableJobFields = new Set<String>();
        for (FieldPermissions fp : [
            SELECT Field
            FROM FieldPermissions
            WHERE ParentId = :upsId AND PermissionsEdit = TRUE
        ]) {
            editableJobFields.add(fp.Field);
        }

        Boolean userJobLabelOk = containsNs(editableJobFields, 'DocGen_Job__c.Label__c');
        if (userJobLabelOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER FLD DocGen_Job__c.Label__c edit: FAIL');
        }

        Boolean userJobMergeOnlyOk = containsNs(editableJobFields, 'DocGen_Job__c.Merge_Only__c');
        if (userJobMergeOnlyOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER FLD DocGen_Job__c.Merge_Only__c edit: FAIL');
        }

        // v3.49 — submitJobInternal writes Sort_Order__c on every bulk job, so a
        // missing grant here breaks bulk generation for standard users while an
        // admin sees nothing wrong. Every new writable DocGen_Job__c field belongs
        // in this list; the suite passed a release without it once already.
        Boolean userJobSortOrderOk = containsNs(editableJobFields, 'DocGen_Job__c.Sort_Order__c');
        if (userJobSortOrderOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER FLD DocGen_Job__c.Sort_Order__c edit: FAIL');
        }

        // #382 — DocGenBulkController.submitJobInternal and DocGenBatch/DocGenMergeJob
        // read Duplex_Padding__c on every bulk job. A missing grant fails bulk
        // generation for standard users (see the Sort_Order__c note above).
        Boolean userJobDuplexOk = containsNs(editableJobFields, 'DocGen_Job__c.Duplex_Padding__c');
        if (userJobDuplexOk) {
            pass++;
        } else {
            fail++;
            System.debug('USER FLD DocGen_Job__c.Duplex_Padding__c edit: FAIL');
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('USER PERMS: FAIL — ' + e.getMessage());
}

// ===== DocGen_Guest_Signature Permission Set =====
try {
    List<PermissionSet> gps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Guest_Signature' LIMIT 1];
    if (gps.isEmpty()) {
        fail++;
        System.debug('GUEST EXISTS: FAIL — DocGen_Guest_Signature not found');
    } else {
        pass++;
        Id gId = gps[0].Id;

        Set<String> gc = new Set<String>();
        Set<String> gp = new Set<String>();
        Set<Id> gcIds = new Set<Id>();
        Set<Id> gpIds = new Set<Id>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId, SetupEntityType
            FROM SetupEntityAccess
            WHERE ParentId = :gId
        ]) {
            if (s.SetupEntityType == 'ApexClass') {
                gcIds.add(s.SetupEntityId);
            }
            if (s.SetupEntityType == 'ApexPage') {
                gpIds.add(s.SetupEntityId);
            }
        }
        // Bulk name lookup.
        for (ApexClass a : [SELECT Name FROM ApexClass WHERE Id IN :gcIds]) {
            gc.add(a.Name);
        }
        for (ApexPage a : [SELECT Name FROM ApexPage WHERE Id IN :gpIds]) {
            gp.add(a.Name);
        }

        // VF pages
        Boolean sigPageOk = gp.contains('DocGenSignature');
        if (sigPageOk) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST PAGE DocGenSignature: FAIL');
        }

        Boolean signPageOk = gp.contains('DocGenSign');
        if (signPageOk) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST PAGE DocGenSign: FAIL');
        }

        Boolean verifyPageOk = gp.contains('DocGenVerify');
        if (verifyPageOk) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST PAGE DocGenVerify: FAIL');
        }

        // Apex classes
        Boolean gSigCtrl = gc.contains('DocGenSignatureController');
        if (gSigCtrl) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST CLASS DocGenSignatureController: FAIL');
        }

        Boolean gAuthCtrl = gc.contains('DocGenAuthenticatorController');
        if (gAuthCtrl) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST CLASS DocGenAuthenticatorController: FAIL');
        }

        // Object permissions
        Set<String> go2 = new Set<String>();
        for (ObjectPermissions op : [
            SELECT SobjectType
            FROM ObjectPermissions
            WHERE ParentId = :gId AND PermissionsRead = TRUE
        ]) {
            go2.add(op.SobjectType);
        }

        if (containsNs(go2, 'DocGen_Signature_Request__c')) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST OBJ DocGen_Signature_Request__c: FAIL');
        }

        if (containsNs(go2, 'DocGen_Signer__c')) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST OBJ DocGen_Signer__c: FAIL');
        }

        if (containsNs(go2, 'DocGen_Signature_Audit__c')) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST OBJ DocGen_Signature_Audit__c: FAIL');
        }

        if (containsNs(go2, 'DocGen_Signature_Placement__c')) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST OBJ DocGen_Signature_Placement__c: FAIL');
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('GUEST PERMS: FAIL — ' + e.getMessage());
}

// ===== DocGen_Guest_Runner Permission Set (deprecated in v1.98) =====
// The Experience Cloud guest render path was removed; this permset is retained
// as an empty stub for 2GP upgrade compatibility. Assert it exists AND that all
// class/object grants have been stripped — any lingering grant would re-expose
// the removed surface.
try {
    List<PermissionSet> grps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Guest_Runner' LIMIT 1];
    if (grps.isEmpty()) {
        fail++;
        System.debug('GUEST_RUNNER EXISTS: FAIL');
    } else {
        pass++;
        Id grId = grps[0].Id;
        Integer grcCount = [
            SELECT COUNT()
            FROM SetupEntityAccess
            WHERE ParentId = :grId AND SetupEntityType = 'ApexClass'
        ];
        Integer grObjCount = [
            SELECT COUNT()
            FROM ObjectPermissions
            WHERE ParentId = :grId AND (PermissionsRead = TRUE OR PermissionsEdit = TRUE OR PermissionsCreate = TRUE)
        ];
        if (grcCount == 0) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST_RUNNER DEPRECATED — expected 0 class grants, found ' + grcCount + ': FAIL');
        }
        if (grObjCount == 0) {
            pass++;
        } else {
            fail++;
            System.debug('GUEST_RUNNER DEPRECATED — expected 0 object grants, found ' + grObjCount + ': FAIL');
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('GUEST_RUNNER PERMS: FAIL — ' + e.getMessage());
}

System.debug('========================================');
System.debug(
    'E2E-01 PERMISSIONS — PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
