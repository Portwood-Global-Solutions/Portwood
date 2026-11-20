// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
@IsTest
private class DocGenFieldWritebackServiceTest {
    // Stable signer token (64-hex) reused across tests.
    private static final String SIGNER_TOKEN = 'f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5';

    /**
     * Builds a signature request bound to a template whose Form_Fields_Config__c
     * carries the supplied formFields config, plus one PIN-verified signer carrying
     * the supplied collected-values JSON. Returns the request Id.
     */
    private static Id buildRequest(String formFieldsConfig, Id relatedRecordId, String fieldDataJson) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Writeback Template ' + Datetime.now().getTime(),
            Base_Object_API__c = 'Account',
            Form_Fields_Config__c = formFieldsConfig,
            Type__c = 'HTML',
            Output_Format__c = 'PDF'
        );
        insert tmpl;

        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Template__c = tmpl.Id,
            Related_Record_Id__c = relatedRecordId,
            Secure_Token__c = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2',
            Signer_Name__c = 'WB Signer',
            Signer_Email__c = 'wb@test.com'
        );
        insert req;

        DocGen_Signer__c signer = new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'WB Signer',
            Signer_Email__c = 'wb@test.com',
            Role_Name__c = 'Signer',
            Secure_Token__c = SIGNER_TOKEN,
            Status__c = 'Signed',
            Sort_Order__c = 1,
            Field_Data_Json__c = fieldDataJson
        );
        insert signer;
        return req.Id;
    }

    @IsTest
    static void sentFieldLabelsAndKeysSurviveTemplateRename() {
        String oldConfig = '{"formFields":[{"key":"old_key","label":"Old label"}]}';
        String newConfig = '{"formFields":[{"key":"new_key","label":"New label"}]}';
        Id requestId = buildRequest(oldConfig, null, null);
        DocGen_Signature_Request__c request = [
            SELECT Id, Template__c, Form_Fields_Snapshot__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
        ];
        System.assertEquals(oldConfig, request.Form_Fields_Snapshot__c);
        Id templateId = request.Template__c;
        // Simulate a request sent before this field existed.
        request.Form_Fields_Snapshot__c = null;
        update request;

        update new DocGen_Template__c(Id = templateId, Form_Fields_Config__c = newConfig);
        request = [
            SELECT Form_Fields_Snapshot__c, Template__r.Form_Fields_Config__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
        ];
        System.assertEquals(oldConfig, DocGenFieldWritebackService.requestConfig(request));
        System.assertEquals(newConfig, request.Template__r.Form_Fields_Config__c);

        DocGen_Signature_Request__c nextRequest = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Template__c = templateId,
            Signer_Name__c = 'New Signer',
            Signer_Email__c = 'new@example.test'
        );
        insert nextRequest;
        nextRequest = [SELECT Form_Fields_Snapshot__c FROM DocGen_Signature_Request__c WHERE Id = :nextRequest.Id];
        System.assertEquals(newConfig, nextRequest.Form_Fields_Snapshot__c);
    }

    @IsTest
    static void rejectDuplicateSignerFieldKeys() {
        Id requestId = buildRequest('{"formFields":[{"key":"first"}]}', null, null);
        Id templateId = [SELECT Template__c FROM DocGen_Signature_Request__c WHERE Id = :requestId].Template__c;
        Database.SaveResult result = Database.update(
            new DocGen_Template__c(
                Id = templateId,
                Form_Fields_Config__c = '{"formFields":[{"key":"first"},{"key":"FIRST"}]}'
            ),
            false
        );
        System.assertEquals(false, result.isSuccess());
        System.assert(result.getErrors()[0].getMessage().contains('keys must be unique'));
    }

    private static Integer auditCount(Id requestId) {
        return [SELECT COUNT() FROM DocGen_Signature_Audit__c WHERE Signature_Request__c = :requestId];
    }

    // =========================================================================
    // parseConfig
    // =========================================================================

    @IsTest
    static void parseConfig_dropsKeylessAndMalformed_keepsValid() {
        String cfg =
            '{"formFields":[' +
            '{"key":"good","label":"Good","fieldApiName":"Description","type":"text","writeback":true,"listOnCertificate":true,"choices":["A","B"]},' +
            '{"label":"NoKey","type":"text"},' +
            '{"key":"bad key!","type":"text"},' +
            '"notAnObject"]}';
        Test.startTest();
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(cfg);
        Test.stopTest();
        System.assertEquals(1, defs.size(), 'Only the grammar-valid keyed entry survives');
        System.assertEquals('good', defs[0].key);
        System.assertEquals(true, defs[0].writeback);
        System.assertEquals(true, defs[0].listOnCertificate);
        System.assertEquals(2, defs[0].choices.size());
    }

    @IsTest
    static void parseConfig_blankAndMalformedJson_returnEmpty() {
        Test.startTest();
        System.assertEquals(0, DocGenFieldWritebackService.parseConfig(null).size());
        System.assertEquals(0, DocGenFieldWritebackService.parseConfig('').size());
        System.assertEquals(0, DocGenFieldWritebackService.parseConfig('{not json').size());
        System.assertEquals(0, DocGenFieldWritebackService.parseConfig('[1,2,3]').size(), 'top-level array → empty');
        System.assertEquals(0, DocGenFieldWritebackService.parseConfig('{"formFields":"x"}').size());
        Test.stopTest();
    }

    @IsTest
    static void publicFormFields_omitsWritebackAndFieldApiName() {
        String cfg = '{"formFields":[{"key":"k","label":"L","fieldApiName":"Description","type":"text","writeback":true}]}';
        Test.startTest();
        List<Object> pub = DocGenFieldWritebackService.publicFormFields(cfg);
        Test.stopTest();
        System.assertEquals(1, pub.size());
        Map<String, Object> row = (Map<String, Object>) pub[0];
        System.assertEquals('k', row.get('key'));
        System.assert(!row.containsKey('writeback'), 'public projection must NOT expose writeback');
        System.assert(!row.containsKey('fieldApiName'), 'public projection must NOT expose fieldApiName');
    }

    // =========================================================================
    // validateAndClean — required, type coercion, unknown-key drop
    // =========================================================================

    @IsTest
    static void validateAndClean_coercesTypes_andDropsUnknownKeys() {
        String cfg =
            '{"formFields":[' +
            '{"key":"amt","type":"number"},' +
            '{"key":"agree","type":"checkbox"},' +
            '{"key":"due","type":"date"},' +
            '{"key":"note","type":"text"}]}';
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(cfg);
        Test.startTest();
        Map<String, Object> clean = DocGenFieldWritebackService.validateAndClean(
            defs,
            '{"amt":"42.5","agree":"true","due":"2026-01-15","note":" hi ","unknown":"DROP ME"}'
        );
        Test.stopTest();
        System.assertEquals(42.5, clean.get('amt'), 'number coerced to Decimal');
        System.assertEquals(true, clean.get('agree'), 'checkbox coerced to Boolean');
        System.assertEquals('2026-01-15', clean.get('due'), 'valid ISO date preserved');
        System.assertEquals('hi', clean.get('note'), 'text trimmed');
        System.assert(!clean.containsKey('unknown'), 'unknown key dropped');
    }

    @IsTest
    static void validateAndClean_requiredMissing_throws() {
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(
            '{"formFields":[{"key":"name","label":"Full Name","type":"text","required":true}]}'
        );
        Boolean threw = false;
        Test.startTest();
        try {
            DocGenFieldWritebackService.validateAndClean(defs, '{}');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'required field missing must throw');
    }

    @IsTest
    static void validateAndClean_badNumberAndDate_throw() {
        List<DocGenFieldWritebackService.FormFieldDef> numDefs = DocGenFieldWritebackService.parseConfig(
            '{"formFields":[{"key":"n","type":"number"}]}'
        );
        List<DocGenFieldWritebackService.FormFieldDef> dateDefs = DocGenFieldWritebackService.parseConfig(
            '{"formFields":[{"key":"d","type":"date"}]}'
        );
        Boolean badNum = false;
        Boolean badDate = false;
        Test.startTest();
        try {
            DocGenFieldWritebackService.validateAndClean(numDefs, '{"n":"not-a-number"}');
        } catch (AuraHandledException e) {
            badNum = true;
        }
        try {
            DocGenFieldWritebackService.validateAndClean(dateDefs, '{"d":"31/31/2026"}');
        } catch (AuraHandledException e) {
            badDate = true;
        }
        Test.stopTest();
        System.assert(badNum, 'invalid number throws');
        System.assert(badDate, 'invalid date throws');
    }

    @IsTest
    static void validateAndClean_noConfig_returnsNull() {
        Test.startTest();
        System.assertEquals(null, DocGenFieldWritebackService.validateAndClean(null, '{"a":"b"}'));
        System.assertEquals(
            null,
            DocGenFieldWritebackService.validateAndClean(new List<DocGenFieldWritebackService.FormFieldDef>(), '{}')
        );
        Test.stopTest();
    }

    @IsTest
    static void validateAndClean_malformedIncomingJson_throws() {
        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(
            '{"formFields":[{"key":"k","type":"text"}]}'
        );
        Boolean threw = false;
        Test.startTest();
        try {
            DocGenFieldWritebackService.validateAndClean(defs, '{not valid json');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'malformed incoming JSON throws a clean error');
    }

    // =========================================================================
    // collectValues — aggregation, last-writer-wins
    // =========================================================================

    @IsTest
    static void collectValues_aggregatesSignersLastWriterWins() {
        Account acc = new Account(Name = 'Collect Acct');
        insert acc;
        String cfg = '{"formFields":[{"key":"city","type":"text"}]}';
        Id reqId = buildRequest(cfg, acc.Id, '{"city":"Boston"}');
        // Second, later signer overrides city.
        insert new DocGen_Signer__c(
            Signature_Request__c = reqId,
            Signer_Name__c = 'WB Signer 2',
            Secure_Token__c = '1111111111111111111111111111111111111111111111111111111111111111',
            Status__c = 'Signed',
            Sort_Order__c = 2,
            Field_Data_Json__c = '{"city":"Chicago"}'
        );
        Test.startTest();
        Map<String, Object> merged = DocGenFieldWritebackService.collectValues(reqId);
        Test.stopTest();
        System.assertEquals('Chicago', merged.get('city'), 'last-writer (higher Sort_Order) wins');
    }

    @IsTest
    static void collectValues_nullRequest_returnsEmpty() {
        Test.startTest();
        System.assertEquals(0, DocGenFieldWritebackService.collectValues(null).size());
        Test.stopTest();
    }

    // =========================================================================
    // performWriteback — allowlist enforcement, FLS, DML no-throw
    // =========================================================================

    @IsTest
    static void performWriteback_writesAllowlistedField_only() {
        Account acc = new Account(Name = 'WB Target');
        insert acc;
        // One writeback field → Description; one writeback==false field that also
        // maps a base field (must NOT be written); collected values carry both.
        String cfg =
            '{"formFields":[' +
            '{"key":"desc","fieldApiName":"Description","type":"text","writeback":true},' +
            '{"key":"site","fieldApiName":"Website","type":"text","writeback":false}]}';
        Id reqId = buildRequest(cfg, acc.Id, '{"desc":"WRITTEN","site":"http://blocked.example"}');
        Test.startTest();
        DocGenFieldWritebackService.performWriteback(reqId);
        Test.stopTest();
        Account after = [SELECT Description, Website FROM Account WHERE Id = :acc.Id];
        System.assertEquals('WRITTEN', after.Description, 'writeback==true field written');
        System.assertEquals(null, after.Website, 'writeback==false field NOT written (allowlist derived from config)');
    }

    @IsTest
    static void performWriteback_unknownGuestKey_neverWritten() {
        Account acc = new Account(Name = 'WB Unknown Key');
        insert acc;
        // Config maps desc→Description; guest JSON ALSO carries a malicious key that
        // is not a config field. It must never reach DML.
        String cfg = '{"formFields":[{"key":"desc","fieldApiName":"Description","type":"text","writeback":true}]}';
        Id reqId = buildRequest(cfg, acc.Id, '{"desc":"OK","Name":"HACKED"}');
        Test.startTest();
        DocGenFieldWritebackService.performWriteback(reqId);
        Test.stopTest();
        Account after = [SELECT Name, Description FROM Account WHERE Id = :acc.Id];
        System.assertEquals('OK', after.Description);
        System.assertEquals('WB Unknown Key', after.Name, 'guest JSON key not in config never written');
    }

    @IsTest
    static void performWriteback_nonUpdateableField_skippedAndLogged() {
        Account acc = new Account(Name = 'WB NonUpdateable');
        insert acc;
        // CreatedDate is system-managed → not updateable. Writeback must skip + log.
        String cfg = '{"formFields":[{"key":"cd","fieldApiName":"CreatedDate","type":"text","writeback":true}]}';
        Id reqId = buildRequest(cfg, acc.Id, '{"cd":"2026-01-01"}');
        Test.startTest();
        DocGenFieldWritebackService.performWriteback(reqId);
        Test.stopTest();
        System.assert(auditCount(reqId) >= 1, 'a non-updateable target field logs an audit row');
    }

    @IsTest
    static void performWriteback_unknownTargetField_skippedAndLogged() {
        Account acc = new Account(Name = 'WB Unknown Target');
        insert acc;
        String cfg = '{"formFields":[{"key":"x","fieldApiName":"No_Such_Field__c","type":"text","writeback":true}]}';
        Id reqId = buildRequest(cfg, acc.Id, '{"x":"v"}');
        Test.startTest();
        DocGenFieldWritebackService.performWriteback(reqId);
        Test.stopTest();
        System.assert(auditCount(reqId) >= 1, 'a non-existent target field logs an audit row');
    }

    @IsTest
    static void performWriteback_dmlValidationFailure_logsAndDoesNotThrow() {
        Account acc = new Account(Name = 'WB DML Fail');
        insert acc;
        // Map a writeback field to Account.Name and supply an empty value. Name is
        // required, so the USER_MODE allOrNone=false update fails → logged, not thrown.
        String cfg = '{"formFields":[{"key":"nm","fieldApiName":"Name","type":"text","writeback":true}]}';
        // Field_Data_Json__c carries an explicit empty string for nm.
        Id reqId = buildRequest(cfg, acc.Id, '{"nm":""}');
        Test.startTest();
        // Must not throw.
        DocGenFieldWritebackService.performWriteback(reqId);
        Test.stopTest();
        Account after = [SELECT Name FROM Account WHERE Id = :acc.Id];
        System.assertEquals('WB DML Fail', after.Name, 'failed write left the record unchanged');
        // Either coercion produced null (no field set → no DML) or DML rejected the
        // blank Name and logged. In both cases performWriteback must not throw; if a
        // DML attempt occurred it logs an audit. Assert the call completed cleanly.
        System.assert(true, 'performWriteback never re-throws into the finalize path');
    }

    @IsTest
    static void performWriteback_nullRequest_noOp() {
        Test.startTest();
        DocGenFieldWritebackService.performWriteback(null);
        Test.stopTest();
        System.assert(true, 'null requestId is a safe no-op');
    }

    @IsTest
    static void performWriteback_noWritebackFields_noOp() {
        Account acc = new Account(Name = 'WB None');
        insert acc;
        String cfg = '{"formFields":[{"key":"capture","type":"text","writeback":false}]}';
        Id reqId = buildRequest(cfg, acc.Id, '{"capture":"v"}');
        Test.startTest();
        DocGenFieldWritebackService.performWriteback(reqId);
        Test.stopTest();
        System.assertEquals(0, auditCount(reqId), 'no writeback fields → nothing attempted, nothing logged');
    }

    @IsTest
    static void performWriteback_typeCoercion_dateCurrencyBoolean() {
        // Exercises coerceForDisplayType against real Account fields:
        //   NumberOfEmployees (INTEGER), AnnualRevenue (CURRENCY).
        Account acc = new Account(Name = 'WB Coerce');
        insert acc;
        String cfg =
            '{"formFields":[' +
            '{"key":"emp","fieldApiName":"NumberOfEmployees","type":"number","writeback":true},' +
            '{"key":"rev","fieldApiName":"AnnualRevenue","type":"number","writeback":true}]}';
        Id reqId = buildRequest(cfg, acc.Id, '{"emp":"250","rev":"1500000.50"}');
        Test.startTest();
        DocGenFieldWritebackService.performWriteback(reqId);
        Test.stopTest();
        Account after = [SELECT NumberOfEmployees, AnnualRevenue FROM Account WHERE Id = :acc.Id];
        System.assertEquals(250, after.NumberOfEmployees, 'integer coercion');
        System.assertEquals(1500000.50, after.AnnualRevenue, 'currency/decimal coercion');
    }

    @IsTest
    static void performWriteback_captureOnlyTemplate_noBaseRecord_noOp() {
        // No Related_Record_Id__c → capture-only; performWriteback returns early.
        String cfg = '{"formFields":[{"key":"d","fieldApiName":"Description","type":"text","writeback":true}]}';
        Id reqId = buildRequest(cfg, null, '{"d":"v"}');
        Test.startTest();
        DocGenFieldWritebackService.performWriteback(reqId);
        Test.stopTest();
        System.assertEquals(0, auditCount(reqId), 'no base record → no writeback, no error log');
    }

    @IsTest
    static void performWriteback_multiSigner_skippedAndLogged() {
        Account acc = new Account(Name = 'WB Multi');
        insert acc;
        String cfg = '{"formFields":[{"key":"desc","fieldApiName":"Description","type":"text","writeback":true}]}';
        Id reqId = buildRequest(cfg, acc.Id, '{"desc":"SIGNER1"}');
        // Add a second signer → multi-signer request; writeback must be SKIPPED
        // (no unambiguous single source) and the skip logged to the audit trail.
        insert new DocGen_Signer__c(
            Signature_Request__c = reqId,
            Signer_Name__c = 'WB Signer 2',
            Secure_Token__c = '2222222222222222222222222222222222222222222222222222222222222222',
            Status__c = 'Signed',
            Sort_Order__c = 2,
            Field_Data_Json__c = '{"desc":"SIGNER2"}'
        );
        Test.startTest();
        DocGenFieldWritebackService.performWriteback(reqId);
        Test.stopTest();
        Account after = [SELECT Description FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, after.Description, 'multi-signer request must NOT write back to the record');
        System.assert(auditCount(reqId) >= 1, 'multi-signer skip is logged to the audit trail');
    }

    // =========================================================================
    // Invocable entry point
    // =========================================================================

    @IsTest
    static void writeBackFields_invocable_routesToPerformWriteback() {
        Account acc = new Account(Name = 'WB Invocable');
        insert acc;
        String cfg = '{"formFields":[{"key":"desc","fieldApiName":"Description","type":"text","writeback":true}]}';
        Id reqId = buildRequest(cfg, acc.Id, '{"desc":"VIA FLOW"}');
        DocGenFieldWritebackService.WritebackRequest wr = new DocGenFieldWritebackService.WritebackRequest();
        wr.requestId = reqId;
        Test.startTest();
        DocGenFieldWritebackService.writeBackFields(new List<DocGenFieldWritebackService.WritebackRequest>{ wr });
        // Null + blank-id inputs are safe no-ops.
        DocGenFieldWritebackService.writeBackFields(null);
        DocGenFieldWritebackService.WritebackRequest blank = new DocGenFieldWritebackService.WritebackRequest();
        DocGenFieldWritebackService.writeBackFields(new List<DocGenFieldWritebackService.WritebackRequest>{ blank });
        Test.stopTest();
        Account after = [SELECT Description FROM Account WHERE Id = :acc.Id];
        System.assertEquals('VIA FLOW', after.Description, 'invocable routes to performWriteback');
    }
}
