System.assertEquals('__EXPECTED_ORG_ID__', UserInfo.getOrganizationId());
portwoodglobal__DocGen_Asset__c asset = new portwoodglobal__DocGen_Asset__c(
    Name = 'QA Private Image',
    portwoodglobal__Asset_Key__c = 'qa-logo',
    portwoodglobal__Asset_Type__c = 'Image',
    portwoodglobal__Is_Active__c = true
);
insert asset;
ContentVersion image = new ContentVersion(
    Title = 'QA Private Image',
    PathOnClient = 'qa-logo.png',
    VersionData = EncodingUtil.base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAPAAAABQCAIAAACoK28rAAABi0lEQVR4nO3SQQkCAQBFwQ1gDeuYwxBmMcVW826E9fDhIQxMhDk+5/EXbo8nXOqnCs1QP1VohvqpQjPUTxWaoX6q0Az1U4VmqJ8qNEP9VKEZ6qcKzVA/VWiG+qlCM9RPFZqhfqrQDPVThWaonyo0Q/1UoRnqpwrNUD9VaIb6qUIz1E8VmqF+qtAM9VOFZqifKjRD/VShGeqnCs1QP1VohvqpQjPUTxWaoX6q0Az1U4VmqJ8qNEP9VKEZ6qcKzVA/VWiG+qlCM9RPFZqhfqrQDPVThWaonyo0Q/3UH91fb7jUTxWaoX6q0Az1U4VmqJ8qNEP9VKEZ6qcKzVA/VWiG+qlCM9RPFZqhfqrQDPVThWaonyo0Q/1UoRnqpwrNUD9VaIb6qUIz1E8VmqF+qtAM9VOFZqifKjRD/VShGeqnCs1QP1VohvqpQjPUTxWaoX6q0Az1U4VmqJ8qNEP9VKEZ6qcKzVA/VWiG+qlCM9RPFZqhfqrQDPVThWaonyo0Q/1UoRnqpwrNUD9VaIa+8Q+vSxvLQx8AAAAASUVORK5CYII='
    ),
    FirstPublishLocationId = asset.Id
);
insert image;
for (String kind : new List<String>{ 'HTML', 'Word' }) {
    portwoodglobal__DocGen_Template__c tmpl = new portwoodglobal__DocGen_Template__c(
        Name = 'QA Asset ' + kind,
        portwoodglobal__Type__c = kind,
        portwoodglobal__Output_Format__c = 'PDF',
        portwoodglobal__Base_Object_API__c = 'Account',
        portwoodglobal__Query_Config__c = 'Name',
        portwoodglobal__Header_Html__c = '<div>HEADER {%asset:qa-logo:120x40}</div>',
        portwoodglobal__Footer_Html__c = '<div>FOOTER {%asset:qa-logo:120x40}</div>',
        portwoodglobal__Document_Title_Format__c = 'QA_' + kind + '_{Name}'
    );
    insert tmpl;
    ContentVersion body = new ContentVersion(
        Title = 'QA ' + kind + ' body',
        PathOnClient = kind == 'HTML' ? 'body.html' : 'body.docx',
        VersionData = kind == 'HTML'
            ? Blob.valueOf(
                  '<html><body style="font-family:Arial"><h1>QA ASSET SCHEDULE TEST</h1><p>{Name}</p><p>Body asset:</p><p>{%asset:qa-logo:240x80}</p><p>Attribute asset:</p><img src="{%asset:qa-logo}" width="240" height="80" /></body></html>'
              )
            : EncodingUtil.base64Decode(
                  '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'
              ),
        FirstPublishLocationId = tmpl.Id
    );
    insert body;
    insert new portwoodglobal__DocGen_Template_Version__c(
        portwoodglobal__Template__c = tmpl.Id,
        portwoodglobal__Content_Version_Id__c = body.Id,
        portwoodglobal__Is_Active__c = true
    );
    System.debug('TEMPLATE=' + kind + '~' + tmpl.Id);
}
System.debug('IMAGE=' + image.Id);
System.assertEquals(0, [SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = :image.Id]);
