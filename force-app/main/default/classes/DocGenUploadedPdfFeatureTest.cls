@IsTest
private class DocGenUploadedPdfFeatureTest {
    private static final String PDF = EncodingUtil.base64Encode(
        Blob.valueOf('%PDF-1.4\nunit transport fixture\n%%EOF')
    );

    private static Account account() {
        Account row = new Account(Name = 'Prepared PDF Test');
        insert row;
        return row;
    }
    private static Map<String, Object> draft(Id recordId) {
        return DocGenSignaturePreparationController.uploadPdf(recordId, 'Agreement.pdf', PDF);
    }
    private static String preparation(Map<String, Object> draft) {
        return JSON.serialize(
            new Map<String, Object>{
                'documentId' => draft.get('documentId'),
                'title' => 'Prepared Agreement',
                'expirationDays' => 30,
                'delivery' => 'preview',
                'requireVerification' => false,
                'prefill' => true,
                'recipients' => new List<Object>{
                    new Map<String, Object>{
                        'key' => 'first',
                        'name' => 'First Signer',
                        'email' => 'first@example.invalid'
                    },
                    new Map<String, Object>{
                        'key' => 'second',
                        'name' => 'Second Signer',
                        'email' => 'second@example.invalid'
                    }
                },
                'pages' => new List<Object>{
                    new Map<String, Object>{ 'x' => 0, 'y' => 0, 'width' => 612, 'height' => 792, 'rotation' => 0 }
                },
                'fields' => new List<Object>{
                    new Map<String, Object>{
                        'id' => 'a',
                        'recipientKey' => 'first',
                        'type' => 'Full',
                        'page' => 1,
                        'x' => 50,
                        'y' => 150,
                        'width' => 160,
                        'height' => 40
                    },
                    new Map<String, Object>{
                        'id' => 'b',
                        'recipientKey' => 'first',
                        'type' => 'Date',
                        'page' => 1,
                        'x' => 350,
                        'y' => 150,
                        'width' => 160,
                        'height' => 40
                    },
                    new Map<String, Object>{
                        'id' => 'c',
                        'recipientKey' => 'second',
                        'type' => 'Full',
                        'page' => 1,
                        'x' => 50,
                        'y' => 50,
                        'width' => 160,
                        'height' => 40
                    }
                }
            }
        );
    }
    private static List<DocGen_Signer__c> signers(Id requestId) {
        return [
            SELECT Id, Secure_Token__c, Status__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId
            ORDER BY Sort_Order__c
        ];
    }
    private static void completeFields(String token) {
        for (Map<String, Object> field : DocGenSignatureController.getSignerPlacements(token)) {
            DocGenSignatureController.signPlacement(token, (Id) field.get('id'), 'Example Signer');
        }
    }

    @IsTest
    static void uploadCreatesPrivateRecordBoundDraft() {
        Account record = account();
        Map<String, Object> draft = draft(record.Id);
        Id requestId = (Id) draft.get('draftId'), documentId = (Id) draft.get('documentId');
        DocGen_Signature_Request__c row = [
            SELECT
                Status__c,
                Original_Document_CV_Id__c,
                Original_Content_Document_Id__c,
                Related_Record_Id__c,
                Snapshot_Hash__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
        ];
        System.assertEquals('Draft', row.Status__c);
        System.assertEquals(String.valueOf(record.Id), row.Related_Record_Id__c);
        System.assertEquals(documentId, (Id) row.Original_Document_CV_Id__c);
        System.assertEquals(64, row.Snapshot_Hash__c.length());
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Signer__c WHERE Signature_Request__c = :requestId]);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :record.Id]);
        System.assertNotEquals(null, DocGenSignaturePreparationController.getPreparationUrl(record.Id));
    }

    @IsTest
    static void draftRoundTripAndStaleSave() {
        Account record = account();
        Map<String, Object> draft = draft(record.Id);
        Id requestId = (Id) draft.get('draftId');
        Integer revision = DocGenSignaturePreparationController.saveDraft(record.Id, requestId, 0, preparation(draft));
        System.assertEquals(1, revision);
        Map<String, Object> loaded = DocGenSignaturePreparationController.loadDraft(record.Id, requestId);
        System.assertEquals(1, ((Decimal) loaded.get('revision')).intValue());
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped((String) loaded.get('config'));
        System.assertEquals(3, ((List<Object>) config.get('fields')).size());
        System.assertEquals(PDF, loaded.get('base64'));
        Boolean rejected = false;
        try {
            DocGenSignaturePreparationController.saveDraft(record.Id, requestId, 0, preparation(draft));
        } catch (DocGenSignaturePreparationController.PreparationException ex) {
            rejected = ex.getMessage().contains('another window');
        }
        System.assert(rejected, 'Stale drafts must never overwrite newer configuration');
    }

    @IsTest
    static void sourceMismatchAndMissingSignatureAreRejectedBeforeSend() {
        Account record = account();
        Map<String, Object> draft = draft(record.Id);
        Id requestId = (Id) draft.get('draftId');
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(preparation(draft));
        config.put('documentId', '068000000000000AAA');
        Boolean rejected = false;
        try {
            DocGenSignaturePreparationController.sendDraft(record.Id, requestId, 0, JSON.serialize(config));
        } catch (DocGenSignaturePreparationController.PreparationException ex) {
            rejected = ex.getMessage().contains('different PDF');
        }
        System.assert(rejected);
        config = (Map<String, Object>) JSON.deserializeUntyped(preparation(draft));
        ((List<Object>) config.get('fields')).remove(2);
        rejected = false;
        try {
            DocGenSignaturePreparationController.sendDraft(record.Id, requestId, 0, JSON.serialize(config));
        } catch (DocGenSignaturePreparationController.PreparationException ex) {
            rejected = ex.getMessage().contains('every recipient');
        }
        System.assert(rejected);
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Signer__c WHERE Signature_Request__c = :requestId]);
    }

    @IsTest
    static void invalidGeometryIsRejected() {
        Account record = account();
        Map<String, Object> draft = draft(record.Id);
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(preparation(draft));
        Map<String, Object> field = (Map<String, Object>) ((List<Object>) config.get('fields'))[0];
        field.put('x', 600);
        Boolean rejected = false;
        try {
            DocGenSignaturePreparationController.sendDraft(
                record.Id,
                (Id) draft.get('draftId'),
                0,
                JSON.serialize(config)
            );
        } catch (DocGenSignaturePreparationController.PreparationException ex) {
            rejected = ex.getMessage().contains('inside');
        }
        System.assert(rejected, 'Reject a field extending off the page');
    }

    @IsTest
    static void sendCreatesCoordinateFieldsAndGatesSigningOrder() {
        Account record = account();
        Map<String, Object> draft = draft(record.Id);
        Id requestId = (Id) draft.get('draftId');
        Map<String, Object> result = DocGenSignaturePreparationController.sendDraft(
            record.Id,
            requestId,
            0,
            preparation(draft)
        );
        System.assertEquals('preview', result.get('delivery'));
        System.assertEquals(0, Limits.getEmailInvocations(), 'Internal preview must not send invitations');
        List<DocGen_Signer__c> people = signers(requestId);
        System.assertEquals(2, people.size());
        DocGenSignatureController.SignatureInitResponse init = DocGenSignatureController.validateToken(
            people[0].Secure_Token__c
        );
        System.assertEquals(true, init.isValid);
        System.assertEquals('Prepared Agreement', init.documentTitle);
        System.assertEquals(null, init.documentUrl, 'Original PDF must not acquire a public file distribution');
        System.assertEquals(0, [SELECT COUNT() FROM ContentDistribution]);
        System.assertEquals(false, DocGenSignatureController.validateToken(people[1].Secure_Token__c).isValid);
        System.assertEquals(
            'Prepared Agreement',
            DocGenSignatureController.getSignatureCertificate(people[0].Secure_Token__c).get('documentTitle')
        );
        List<Map<String, Object>> fields = DocGenSignatureController.getSignerPlacements(people[0].Secure_Token__c);
        System.assertEquals(2, fields.size());
        System.assertNotEquals(null, fields[0].get('pdfRect'));
        System.assertEquals('1', String.valueOf(fields[0].get('pdfPage')));
        Boolean rejected = false;
        try {
            DocGenSignatureController.getSignerPlacements(people[1].Secure_Token__c);
        } catch (AuraHandledException ex) {
            rejected = true;
        }
        System.assert(rejected, 'The next signer must wait');
        List<Map<String, Object>> requests = DocGenSignatureSenderController.getPendingSignatureRequests(record.Id);
        System.assertEquals('Prepared Agreement', requests[0].get('documentTitle'));
    }

    @IsTest
    static void sequentialCompletionPreservesOriginalAndRejectsStaleOutput() {
        Account record = account();
        Map<String, Object> draft = draft(record.Id);
        Id requestId = (Id) draft.get('draftId');
        DocGenSignaturePreparationController.sendDraft(record.Id, requestId, 0, preparation(draft));
        List<DocGen_Signer__c> people = signers(requestId);
        completeFields(people[0].Secure_Token__c);
        Boolean rejected = false;
        try {
            DocGenSignatureController.savePreparedSignedPdf(people[0].Secure_Token__c, PDF, true, '', '', '{}', 0);
        } catch (AuraHandledException ex) {
            rejected = true;
        }
        System.assert(rejected, 'Reject stale working PDFs');
        rejected = false;
        try {
            DocGenSignatureController.saveCompositedSignedPdf(people[0].Secure_Token__c, PDF, true, '', '', '{}');
        } catch (AuraHandledException ex) {
            rejected = true;
        }
        System.assert(rejected, 'Prepared tokens cannot bypass revision checks through the older API');
        DocGenSignatureController.SavePdfSignatureResult first = DocGenSignatureController.savePreparedSignedPdf(
            people[0].Secure_Token__c,
            PDF,
            true,
            '',
            '',
            '{}',
            1
        );
        System.assertEquals(true, first.success);
        System.assertEquals(false, first.isComplete);
        completeFields(people[1].Secure_Token__c);
        DocGenSignatureController.SavePdfSignatureResult second = DocGenSignatureController.savePreparedSignedPdf(
            people[1].Secure_Token__c,
            PDF,
            true,
            '',
            '',
            '{}',
            2
        );
        System.assertEquals(true, second.success);
        System.assertEquals(true, second.isComplete);
        DocGen_Signature_Request__c request = [
            SELECT
                Status__c,
                Original_Document_CV_Id__c,
                Protected_Signed_Content_Document_Id__c,
                PDF_Revision__c,
                Source_Document_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
        ];
        System.assertEquals('Signed', request.Status__c);
        System.assertEquals(3, request.PDF_Revision__c);
        System.assertEquals(draft.get('documentId'), (Id) request.Original_Document_CV_Id__c);
        System.assertNotEquals(null, request.Protected_Signed_Content_Document_Id__c);
        Id finalVersionId = (Id) request.Source_Document_Id__c;
        System.assertEquals(
            (Id) request.Protected_Signed_Content_Document_Id__c,
            [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :finalVersionId].ContentDocumentId,
            'Completed prepared sessions must resolve the final PDF, including its certificate'
        );
        System.assertEquals(2, [SELECT COUNT() FROM DocGen_Signature_Audit__c WHERE Signature_Request__c = :requestId]);
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :record.Id]);
    }

    @IsTest
    static void sentOriginalAndFieldsAreImmutable() {
        Account record = account();
        Map<String, Object> draft = draft(record.Id);
        Id requestId = (Id) draft.get('draftId');
        DocGenSignaturePreparationController.sendDraft(record.Id, requestId, 0, preparation(draft));
        DocGen_Signature_Request__c request = [
            SELECT Original_Content_Document_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
        ];
        Database.DeleteResult deletion = Database.delete(
            new ContentDocument(Id = (Id) request.Original_Content_Document_Id__c),
            false
        );
        System.assertEquals(false, deletion.isSuccess());
        DocGen_Signature_Placement__c field = [
            SELECT PDF_Page__c, PDF_X__c
            FROM DocGen_Signature_Placement__c
            WHERE Signature_Request__c = :requestId
            LIMIT 1
        ];
        field.PDF_Page__c = null;
        System.assertEquals(
            false,
            Database.update(field, false).isSuccess(),
            'Clearing geometry cannot bypass the field lock'
        );
        request.Original_Document_CV_Id__c = null;
        System.assertEquals(false, Database.update(request, false).isSuccess());
        System.assertEquals(
            false,
            Database.update(new DocGen_Signature_Request__c(Id = requestId, Status__c = 'Draft'), false).isSuccess(),
            'Returning to Draft must not unlock the retained original'
        );
        System.assertEquals(
            false,
            Database.update(new DocGen_Signature_Request__c(Id = requestId, PDF_Internal_Preview__c = false), false)
                .isSuccess(),
            'A preview cannot be converted into an email request after sending'
        );
        System.assertEquals(
            false,
            Database.insert(
                    new DocGen_Signature_Placement__c(
                        Signature_Request__c = requestId,
                        Signer__c = signers(requestId)[0].Id,
                        Placement_Type__c = 'Full',
                        PDF_Page__c = 1
                    ),
                    false
                )
                .isSuccess(),
            'Sent requests cannot gain new required fields'
        );
    }

    @IsTest
    static void draftIsPrivateToItsCreatorEvenForAnotherAdministrator() {
        User other = new User(
            Alias = 'pdfother',
            Email = 'pdfother@example.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'PDF Owner',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/New_York',
            Username = 'pdfother.' + System.now().getTime() + '@example.invalid'
        );
        insert other;
        Id recordId, draftId;
        System.runAs(other) {
            Account record = account();
            recordId = record.Id;
            draftId = (Id) draft(recordId).get('draftId');
        }
        Boolean rejected = false;
        try {
            DocGenSignaturePreparationController.loadDraft(recordId, draftId);
        } catch (DocGenSignaturePreparationController.PreparationException ex) {
            rejected = true;
        }
        System.assert(rejected, 'Record access alone must not disclose another sender\'s private draft');
    }

    @IsTest
    static void rotatedCropBoxGeometryAndPreviewEmailSuppression() {
        Account record = account();
        Map<String, Object> draft = draft(record.Id);
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(preparation(draft));
        Map<String, Object> page = (Map<String, Object>) ((List<Object>) config.get('pages'))[0];
        page.put('rotation', 90);
        page.put('x', 20);
        page.put('y', 30);
        Id requestId = (Id) draft.get('draftId');
        DocGenSignaturePreparationController.sendDraft(record.Id, requestId, 0, JSON.serialize(config));
        System.assertEquals(
            3,
            [
                SELECT COUNT()
                FROM DocGen_Signature_Placement__c
                WHERE Signature_Request__c = :requestId AND PDF_Rotation__c = 90
            ]
        );
        List<DocGenSignatureEmailService.SignerEmail> emails = new List<DocGenSignatureEmailService.SignerEmail>{
            new DocGenSignatureEmailService.SignerEmail(
                'Test',
                'test@example.invalid',
                'Signer',
                'https://example.invalid',
                null
            )
        };
        DocGenSignatureEmailService.sendSignatureReminderEmails(emails, 'Preview', requestId);
        DocGenSignatureEmailService.sendAllSignedNotification(requestId);
        DocGenSignatureEmailService.sendSignerCompletionEmails(requestId);
        System.assertEquals(0, Limits.getEmailInvocations());
        System.assertEquals(
            null,
            [SELECT Email_Status__c FROM DocGen_Signature_Request__c WHERE Id = :requestId].Email_Status__c,
            'Suppressed preview mail must not create a missing-sender failure status'
        );
    }

    @IsTest
    static void existingFileIsCopiedAndUnrelatedRecordCannotResumeDraft() {
        Account record = account();
        ContentVersion source = new ContentVersion(
            Title = 'Customer Original',
            PathOnClient = 'customer.pdf',
            VersionData = EncodingUtil.base64Decode(PDF),
            FirstPublishLocationId = record.Id
        );
        insert source;
        Map<String, Object> draft = DocGenSignaturePreparationController.selectPdf(record.Id, source.Id);
        System.assertNotEquals(source.Id, draft.get('documentId'), 'Keep an independent version-bound original');
        Boolean rejected = false;
        Account otherRecord = account();
        try {
            DocGenSignaturePreparationController.loadDraft(otherRecord.Id, (Id) draft.get('draftId'));
        } catch (DocGenSignaturePreparationController.PreparationException ex) {
            rejected = true;
        }
        System.assert(rejected, 'A draft belongs to one record');
    }

    @IsTest
    static void invalidUploadAndMalformedConfigurationFailClosed() {
        Account record = account();
        Boolean rejected = false;
        try {
            DocGenSignaturePreparationController.uploadPdf(record.Id, 'bad.pdf', 'bm90IGEgcGRm');
        } catch (DocGenSignaturePreparationController.PreparationException ex) {
            rejected = true;
        }
        System.assert(rejected);
        Map<String, Object> draft = draft(record.Id);
        rejected = false;
        try {
            DocGenSignaturePreparationController.saveDraft(record.Id, (Id) draft.get('draftId'), 0, '[]');
        } catch (DocGenSignaturePreparationController.PreparationException ex) {
            rejected = true;
        }
        System.assert(rejected);
    }
}
