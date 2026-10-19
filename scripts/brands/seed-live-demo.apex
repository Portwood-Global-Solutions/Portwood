// Developer-only fictional fixture. Called by demo.mjs after creating a live branding set.
System.assertEquals('00DRu00000aiv7VMAQ', UserInfo.getOrganizationId(), 'Proposal scratch demo only.');
Blob pdf = Blob.toPdf(
    '<html><head><style>@page{size:letter;margin:54pt;}body{font-family:Helvetica;color:#243247;}h1{color:#143B52;}p{line-height:1.6;}</style></head><body><h1>Cedar Community</h1><h2>Welcome agreement</h2><p>This fictional document demonstrates the branded guest signing experience.</p><p>Your signing page follows the linked Salesforce theme. The document keeps its own design.</p><p>Sign in the highlighted field below.</p></body></html>'
);
List<Account> accounts = [SELECT Id FROM Account WHERE Name = 'Cedar Community - live Brand demo' LIMIT 1];
Account record = accounts.isEmpty() ? new Account(Name = 'Cedar Community - live Brand demo') : accounts[0];
if (record.Id == null)
    insert record;
List<DocGen_Brand__c> brands = [SELECT Id FROM DocGen_Brand__c WHERE Name = 'Cedar Community - live theme' LIMIT 1];
Id brandId = DocGenBrandController.saveBrand(
    new Map<String, Object>{
        'id' => brands.isEmpty() ? null : brands[0].Id,
        'name' => 'Cedar Community - live theme',
        'companyName' => 'Cedar Community',
        'isActive' => true,
        'brandColor' => '#227548',
        'signingColor' => '#990099',
        'signingHeaderColor' => '#FFFFFF',
        'signingBackgroundColor' => '#FFFFFF',
        'signingTitle' => 'Welcome to Cedar Community',
        'signingWelcomeText' => 'Please review this sample agreement. This page uses a live Salesforce theme.',
        'signingFooterText' => 'Cedar Community • Fictional demonstration',
        'signingCompletionMessage' => 'Thank you. Your sample agreement is complete.',
        'signingPageConfig' => JSON.serialize(
            new Map<String, Object>{ 'brandingSetId' => 'BRANDING_SET_ID', 'logoHeight' => 48, 'contentWidth' => 1040 }
        )
    }
);
DocGen_Template__c template = new DocGen_Template__c(
    Name = 'Cedar Community - Brand demo (HTML)',
    Base_Object_API__c = 'Account',
    Type__c = 'HTML',
    Is_Active__c = false,
    Brand__c = brandId
);
insert template;
String html = '<html><body style="font-family:Arial;color:#243247;padding:24px;"><h1>Cedar Community</h1><h2>Welcome agreement</h2><p>This fictional agreement demonstrates a Brand selected on a template.</p><p>Guest-page colors follow the linked Salesforce theme. The document retains its own design.</p><p>Your signature: <span>@@SIG-1@@</span></p></body></html>';
DocGen_Signature_Request__c htmlRequest = new DocGen_Signature_Request__c(
    Template__c = template.Id,
    Related_Record_Id__c = record.Id,
    Status__c = 'Sent',
    Signing_Order__c = 'Parallel',
    Require_Email_Verification__c = false,
    Expires_At__c = Datetime.now().addDays(30),
    Signature_Data__c = JSON.serialize(new Map<String, Object>{ 'previewHtml' => html })
);
insert htmlRequest;
String token = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
DocGen_Signer__c signer = new DocGen_Signer__c(
    Signature_Request__c = htmlRequest.Id,
    Signer_Name__c = 'Pat Demo',
    Signer_Email__c = 'pat@example.invalid',
    Role_Name__c = 'Resident',
    Sort_Order__c = 1,
    Secure_Token__c = token,
    Status__c = 'Pending'
);
insert signer;
insert new DocGen_Signature_Placement__c(
    Signature_Request__c = htmlRequest.Id,
    Signer__c = signer.Id,
    Tag_Text__c = '@@SIG-1@@',
    Placement_Type__c = 'Full',
    Sequence_Order__c = 1,
    Status__c = 'Pending'
);
Map<String, Object> draft = DocGenSignaturePreparationController.uploadPdf(
    record.Id,
    'Cedar Community.pdf',
    EncodingUtil.base64Encode(pdf)
);
Map<String, Object> config = new Map<String, Object>{
    'documentId' => draft.get('documentId'),
    'title' => 'Cedar Community - welcome agreement',
    'brandId' => brandId,
    'expirationDays' => 30,
    'delivery' => 'links',
    'requireVerification' => false,
    'prefill' => true,
    'recipients' => new List<Object>{
        new Map<String, Object>{ 'key' => 'resident', 'name' => 'Pat Demo', 'email' => 'pat@example.invalid' }
    },
    'pages' => new List<Object>{
        new Map<String, Object>{ 'x' => 0, 'y' => 0, 'width' => 612, 'height' => 792, 'rotation' => 0 }
    },
    'fields' => new List<Object>{
        new Map<String, Object>{
            'id' => 'signature',
            'recipientKey' => 'resident',
            'type' => 'Full',
            'page' => 1,
            'x' => 54,
            'y' => 160,
            'width' => 220,
            'height' => 48
        }
    }
};
Map<String, Object> sent = DocGenSignaturePreparationController.sendDraft(
    record.Id,
    (Id) draft.get('draftId'),
    0,
    JSON.serialize(config)
);
List<Object> pdfSigners = (List<Object>) JSON.deserializeUntyped(JSON.serialize(sent.get('signers')));
System.debug(
    'DEMO=' +
    JSON.serialize(
        new Map<String, Object>{
            'brandId' => brandId,
            'accountId' => record.Id,
            'templateId' => template.Id,
            'htmlRequestId' => htmlRequest.Id,
            'pdfRequestId' => draft.get('draftId'),
            'htmlUrl' => DocGenSignatureSenderController.getSiteBaseUrl() +
            '/apex/DocGenSignature?token=' +
            token,
            'pdfUrl' => ((Map<String, Object>) pdfSigners[0]).get('signerUrl'),
            'emailsSent' => Limits.getEmailInvocations()
        }
    )
);
