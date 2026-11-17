@IsTest
private class DocGenSignatureManagementTest {
    @TestSetup
    static void setup() {
        Id userId = UserInfo.getUserId();
        Id permissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Admin' LIMIT 1].Id;
        if (
            [
                SELECT COUNT()
                FROM PermissionSetAssignment
                WHERE AssigneeId = :userId AND PermissionSetId = :permissionSetId
            ] == 0
        )
            insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permissionSetId);
    }

    private static DocGen_Signature_Request__c makeRequest(Id recordId, String order) {
        DocGen_Signature_Request__c request = new DocGen_Signature_Request__c(
            Related_Record_Id__c = String.valueOf(recordId),
            Signing_Order__c = order,
            Status__c = 'Sent',
            Expires_At__c = System.now().addDays(2)
        );
        insert request;
        return request;
    }

    private static DocGen_Signer__c makeSigner(Id requestId, Integer position, String status) {
        DocGen_Signer__c signer = new DocGen_Signer__c(
            Signature_Request__c = requestId,
            Signer_Name__c = 'Signer ' + position,
            Signer_Email__c = 'wrong' + position + '@example.test',
            Role_Name__c = 'Approver',
            Sort_Order__c = position,
            Status__c = status,
            Secure_Token__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256)),
            PIN_Hash__c = 'old-pin',
            PIN_Expires_At__c = System.now().addMinutes(10),
            PIN_Attempts__c = 2,
            PIN_Verified_At__c = System.now()
        );
        insert signer;
        return signer;
    }

    @IsTest
    static void correctionRotatesTokenAndAuditsOnlySelectedSigner() {
        Account record = new Account(Name = 'Signature management');
        insert record;
        DocGen_Signature_Request__c request = makeRequest(record.Id, 'Sequential');
        DocGen_Signer__c first = makeSigner(request.Id, 1, 'Pending');
        DocGen_Signer__c second = makeSigner(request.Id, 2, 'Viewed');

        Test.startTest();
        Boolean sent = DocGenSignatureManagementController.correctEmail(
            record.Id,
            request.Id,
            second.Id,
            second.Signer_Email__c,
            'corrected@example.test'
        );
        List<Map<String, Object>> listed = DocGenSignatureManagementController.listRequests(record.Id);
        Test.stopTest();

        Assert.isFalse(sent, 'The later signer must wait for the first signer.');
        Assert.areEqual(1, listed.size());
        Assert.isFalse(JSON.serialize(listed).contains(second.Secure_Token__c));
        Map<Id, DocGen_Signer__c> signers = new Map<Id, DocGen_Signer__c>(
            [
                SELECT
                    Secure_Token__c,
                    Signer_Email__c,
                    Status__c,
                    PIN_Hash__c,
                    PIN_Attempts__c,
                    PIN_Expires_At__c,
                    PIN_Verified_At__c,
                    Sort_Order__c
                FROM DocGen_Signer__c
                WHERE Signature_Request__c = :request.Id
            ]
        );
        DocGen_Signer__c changed = signers.get(second.Id);
        Assert.areEqual('corrected@example.test', changed.Signer_Email__c);
        Assert.areEqual('Pending', changed.Status__c);
        Assert.areEqual(2, changed.Sort_Order__c);
        Assert.areNotEqual(second.Secure_Token__c, changed.Secure_Token__c);
        Assert.isNull(changed.PIN_Hash__c);
        Assert.isNull(changed.PIN_Expires_At__c);
        Assert.isNull(changed.PIN_Verified_At__c);
        Assert.areEqual(0, changed.PIN_Attempts__c);
        Assert.areEqual(first.Secure_Token__c, signers.get(first.Id).Secure_Token__c);
        Assert.areEqual(first.Signer_Email__c, signers.get(first.Id).Signer_Email__c);
        Assert.isFalse(
            (Boolean) DocGenSignatureController.sendPin(second.Secure_Token__c, second.Signer_Email__c).get('success')
        );
        DocGen_Signer_Email_Change__c audit = [
            SELECT Signature_Request__c, Signer__c, Previous_Email__c, Corrected_Email__c, CreatedById, CreatedDate
            FROM DocGen_Signer_Email_Change__c
        ];
        Assert.areEqual(second.Signer_Email__c, audit.Previous_Email__c);
        Assert.areEqual('corrected@example.test', audit.Corrected_Email__c);
        Assert.areEqual(UserInfo.getUserId(), audit.CreatedById);
        Assert.isNotNull(audit.CreatedDate);
        Assert.areEqual(second.Id, audit.Signer__c);
        Assert.areEqual(request.Id, audit.Signature_Request__c);
    }

    @IsTest
    static void staleEmailAndWrongRecordAndSignedSignerAreRejected() {
        Account record = new Account(Name = 'Signature request record');
        Account other = new Account(Name = 'Other record');
        insert new List<Account>{ record, other };
        DocGen_Signature_Request__c request = makeRequest(record.Id, 'Parallel');
        DocGen_Signer__c pending = makeSigner(request.Id, 1, 'Pending');
        DocGen_Signer__c signed = makeSigner(request.Id, 2, 'Signed');
        assertRejected(other.Id, request.Id, pending.Id, pending.Signer_Email__c, 'unavailable');
        assertRejected(record.Id, request.Id, pending.Id, 'stale@example.test', 'changed');
        assertRejected(record.Id, request.Id, signed.Id, signed.Signer_Email__c, 'unsigned');
        Assert.areEqual(0, [SELECT COUNT() FROM DocGen_Signer_Email_Change__c]);
    }

    @IsTest
    static void activeCorrectionRemovesContactRecipientAndLeavesOtherSignerUntouched() {
        Account record = new Account(Name = 'Correct an active signer');
        insert record;
        Contact contact = new Contact(
            LastName = 'Original Address',
            AccountId = record.Id,
            Email = 'wrong1@example.test'
        );
        insert contact;
        DocGen_Signature_Request__c request = makeRequest(record.Id, 'Parallel');
        DocGen_Signer__c first = makeSigner(request.Id, 1, 'Viewed');
        DocGen_Signer__c second = makeSigner(request.Id, 2, 'Pending');
        update new DocGen_Signer__c(Id = first.Id, Contact__c = contact.Id);

        Test.startTest();
        Boolean attempted = DocGenSignatureManagementController.correctEmail(
            record.Id,
            request.Id,
            first.Id,
            first.Signer_Email__c,
            'corrected@example.test'
        );
        Test.stopTest();

        Assert.isTrue(attempted, 'An active signer may be sent a replacement link immediately.');
        DocGen_Signer__c changed = [
            SELECT Contact__c, Signer_Email__c, Secure_Token__c
            FROM DocGen_Signer__c
            WHERE Id = :first.Id
        ];
        Assert.isNull(changed.Contact__c, 'A Contact could route email back to the old address.');
        Assert.areEqual('corrected@example.test', changed.Signer_Email__c);
        Assert.areNotEqual(first.Secure_Token__c, changed.Secure_Token__c);
        Assert.areEqual(
            second.Secure_Token__c,
            [SELECT Secure_Token__c FROM DocGen_Signer__c WHERE Id = :second.Id].Secure_Token__c
        );
        Assert.areEqual(
            request.Expires_At__c,
            [SELECT Expires_At__c FROM DocGen_Signature_Request__c WHERE Id = :request.Id].Expires_At__c,
            'Correction should preserve the request expiration.'
        );
    }

    private static void assertRejected(Id recordId, Id requestId, Id signerId, String oldEmail, String message) {
        try {
            DocGenSignatureManagementController.correctEmail(
                recordId,
                requestId,
                signerId,
                oldEmail,
                'new@example.test'
            );
            Assert.fail('Expected rejection');
        } catch (AuraHandledException error) {
            Assert.isTrue(error.getMessage().contains(message), error.getMessage());
        }
    }
}
