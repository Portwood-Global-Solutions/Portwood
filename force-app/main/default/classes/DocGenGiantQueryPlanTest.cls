@IsTest
private class DocGenGiantQueryPlanTest {
    @IsTest
    static void keepsFourTablePlacementsInTemplateOrder() {
        String template =
            '<h1>Account packet</h1>' +
            '<table><thead><tr><th>Active names</th></tr></thead><tbody>' +
            '<tr><td>{#ActiveContacts}{Name}{/ActiveContacts}</td></tr>' +
            '<tr><td>Active total</td></tr></tbody></table>' +
            '<p>Between the tables</p>' +
            '<table><tbody><tr><td>{ # InactiveContacts }{Email}{ / InactiveContacts }</td></tr></tbody></table>' +
            '<table><tr><td>{#Opportunities}{StageName}{/Opportunities}</td></tr></table>' +
            '<table><tr><td>Role {#ActiveContacts}{Title}{/ActiveContacts}</td></tr></table>' +
            '<p>Closing paragraph</p>';

        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(
            template,
            new Set<String>{ 'Opportunities', 'ActiveContacts', 'InactiveContacts' }
        );

        Assert.areEqual(4, plan.slots.size());
        Assert.areEqual(0, plan.slots[0].ordinal);
        Assert.areEqual('00000', plan.slots[0].key);
        Assert.areEqual('ActiveContacts', plan.slots[0].queryKey);
        Assert.areEqual('InactiveContacts', plan.slots[1].queryKey);
        Assert.areEqual('Opportunities', plan.slots[2].queryKey);
        Assert.areEqual('ActiveContacts', plan.slots[3].queryKey);
        Assert.areEqual('<tr><td>{Name}</td></tr>', plan.slots[0].innerXml);
        Assert.areEqual('<tr><td>{Email}</td></tr>', plan.slots[1].innerXml);
        Assert.areEqual('<tr><td>{StageName}</td></tr>', plan.slots[2].innerXml);
        Assert.areEqual('<tr><td>Role {Title}</td></tr>', plan.slots[3].innerXml);

        // Completion order is unrelated to authored order. An explicitly empty
        // placement retains its surrounding table and exactly zero data rows.
        String rendered = plan.fill(
            '<body>' + plan.shell + '</body>',
            new Map<String, String>{
                '00003' => '<tr><td>Engineer</td></tr>',
                '00001' => '',
                '00002' => '<tr><td>Closed Won</td></tr>',
                '00000' => '<tr><td>Alex</td></tr>'
            }
        );

        Assert.areEqual(
            '<body><h1>Account packet</h1>' +
                '<table><thead><tr><th>Active names</th></tr></thead><tbody>' +
                '<tr><td>Alex</td></tr><tr><td>Active total</td></tr></tbody></table>' +
                '<p>Between the tables</p><table><tbody></tbody></table>' +
                '<table><tr><td>Closed Won</td></tr></table>' +
                '<table><tr><td>Engineer</td></tr></table><p>Closing paragraph</p></body>',
            rendered
        );
    }

    @IsTest
    static void liftsWordRowsAfterRejoiningSplitTags() {
        String xml =
            '<w:body><w:tbl><w:tr><w:tc><w:p>' +
            '<w:r><w:t>{#Con</w:t></w:r><w:r><w:t>tacts}</w:t></w:r>' +
            '<w:r><w:t>{Name}</w:t></w:r>' +
            '<w:r><w:t>{/Con</w:t></w:r><w:r><w:t>tacts}</w:t></w:r>' +
            '</w:p></w:tc></w:tr></w:tbl></w:body>';

        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(xml, new Set<String>{ 'Contacts' });
        Assert.areEqual(1, plan.slots.size());
        Assert.isTrue(plan.slots[0].innerXml.startsWith('<w:tr>'));
        Assert.isTrue(plan.slots[0].innerXml.endsWith('</w:tr>'));
        Assert.isTrue(plan.slots[0].innerXml.contains('{Name}'));
        Assert.areEqual('<w:body><w:tbl>' + plan.slots[0].marker + '</w:tbl></w:body>', plan.shell);
    }

    @IsTest
    static void leavesNestedLoopsAndOrdinaryContentInTheShell() {
        String html =
            '<style>@media print {p {color: darkblue;}}</style>' +
            '<p>{#IF Visible}{#Contacts}{HiddenByConditional}{/Contacts}{/IF}</p>' +
            '<ul><li>&#123;#Contacts&#125;{Name}&#123;/Contacts&#125;</li></ul>' +
            '<p>{#Unplanned}{Caption}{/Unplanned}</p>';
        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(html, new Set<String>{ 'Contacts' });

        Assert.areEqual(new Set<String>{ 'Contacts' }, plan.nestedQueryKeys);
        Assert.areEqual(1, plan.slots.size());
        Assert.areEqual('<li>{Name}</li>', plan.slots[0].innerXml);
        Assert.isTrue(plan.shell.contains('{#IF Visible}{#Contacts}{HiddenByConditional}{/Contacts}{/IF}'));
        Assert.isTrue(plan.shell.contains('<p>{#Unplanned}{Caption}{/Unplanned}</p>'));
    }

    @IsTest
    static void preservesIndependentSiblingLoopsInOneRow() {
        String html = '<table><tr><td>{#A}{Name}{/A}</td><td>Keep</td><td>{ # B }{Code}{ /B }</td></tr></table>';
        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(html, new Set<String>{ 'A', 'B' });

        Assert.areEqual(2, plan.slots.size());
        Assert.areEqual('{Name}', plan.slots[0].innerXml);
        Assert.areEqual('{Code}', plan.slots[1].innerXml);
        String output = plan.fill(new Map<String, String>{ '00000' => 'Alex', '00001' => 'B-001' });
        Assert.areEqual('<table><tr><td>Alex</td><td>Keep</td><td>B-001</td></tr></table>', output);
    }

    @IsTest
    static void repeatsCompleteWordParagraphsAndOmitsStandaloneMarkers() {
        String html =
            '<html><body><h1>{CaseNumber}</h1>' +
            '<p><span>{#EmailMessages}</span></p>' +
            '<p>{Subject}</p><p>{TextBody}</p>' +
            '<p><span>{/EmailMessages}</span></p>' +
            '<p class="comments">{#CaseComments}{CommentBody}{/CaseComments}</p>' +
            '<p>End</p></body></html>';
        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(
            html,
            new Set<String>{ 'EmailMessages', 'CaseComments' },
            true
        );
        Assert.areEqual(2, plan.slots.size());
        Assert.areEqual('<p>{Subject}</p><p>{TextBody}</p>', plan.slots[0].innerXml);
        Assert.areEqual('<p class="comments">{CommentBody}</p>', plan.slots[1].innerXml);
        Assert.areEqual(
            '<html><body><h1>{CaseNumber}</h1><p>Topic</p><p>Reply</p><p class="comments">Notes</p><p>End</p></body></html>',
            plan.fill(
                new Map<String, String>{
                    '00000' => '<p>Topic</p><p>Reply</p>',
                    '00001' => '<p class="comments">Notes</p>'
                }
            )
        );
    }

    @IsTest
    static void repeatsStyledWordHeadingAndParagraphAsACompleteEmailBlock() {
        String heading = '<h2 style="color:blue"><span>{Subject}</span></h2>';
        String body = '<p><span>{HtmlBody}</span></p>';
        String authored =
            '<p>Before</p>' +
            heading.replace('{Subject}', '{#EmailMessages}{Subject}') +
            '<p>{FromAddress}</p>' +
            body.replace('{HtmlBody}', '{HtmlBody}{/EmailMessages}') +
            '<p>{#CaseComments}{CommentBody}{/CaseComments}</p><p>After</p>';
        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(
            authored,
            new Set<String>{ 'EmailMessages', 'CaseComments' },
            true
        );
        Assert.areEqual(2, plan.slots.size());
        Assert.areEqual(heading + '<p>{FromAddress}</p>' + body, plan.slots[0].innerXml);
        Assert.areEqual('<p>{CommentBody}</p>', plan.slots[1].innerXml);
        String first = heading.replace('{Subject}', 'First') + '<p>Sender 1</p>' + body.replace('{HtmlBody}', 'One');
        String second = heading.replace('{Subject}', 'Second') + '<p>Sender 2</p>' + body.replace('{HtmlBody}', 'Two');
        Assert.areEqual(
            '<p>Before</p>' + first + second + '<p>Notes</p><p>After</p>',
            plan.fill(new Map<String, String>{ '00000' => first + second, '00001' => '<p>Notes</p>' })
        );
    }

    @IsTest
    static void nativeWordRepeatsTheHeadingStyleAndCompleteBodyForEveryRecord() {
        String heading =
            '<w:p w:rsidR="ABCDEF12"><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>' +
            '<w:r><w:rPr><w:b/></w:rPr><w:t>{Subject}</w:t></w:r></w:p>';
        String sender = '<w:p><w:r><w:t>{FromAddress}</w:t></w:r></w:p>';
        String body = '<w:p><w:r><w:t xml:space="preserve">{%TextBody:80x40}</w:t></w:r></w:p>';
        String before = '<w:body><w:p><w:r><w:t>Before</w:t></w:r></w:p>';
        String after = '<w:p><w:r><w:t>After</w:t></w:r></w:p><w:sectPr/></w:body>';
        String xml =
            before +
            heading.replace('{Subject}', '{#EmailMessages}{Subject}') +
            sender +
            body.replace('{%TextBody:80x40}', '{%TextBody:80x40}{/EmailMessages}') +
            after;

        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(xml, new Set<String>{ 'EmailMessages' });
        Assert.areEqual(1, plan.slots.size());
        Assert.areEqual(heading + sender + body, plan.slots[0].innerXml);
        Assert.areEqual(before + plan.slots[0].marker + after, plan.shell);

        String first = heading.replace('{Subject}', 'First') + sender + body;
        String second = heading.replace('{Subject}', 'Second') + sender + body;
        Assert.areEqual(
            before + first + second + after,
            plan.fill(new Map<String, String>{ '00000' => first + second })
        );
        Assert.areEqual(before + after, plan.fill(new Map<String, String>{ '00000' => '' }));
    }

    @IsTest
    static void nativeWordParagraphExpansionKeepsInlineAndSectionContentInPlace() {
        String inline = '<w:p><w:r><w:t>Before {#Inline}{Name}{/Inline} after</w:t></w:r></w:p>';
        String spanning =
            '<w:p><w:r><w:rPr /><w:t>Keep</w:t></w:r>' +
            '<w:r><w:rPr><w:b/></w:rPr><w:t>{#Spanning}{First}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{Last}{/Spanning}</w:t></w:r></w:p>';
        String section =
            '<w:p><w:pPr><w:sectPr/></w:pPr><w:r><w:t>{#Section}{Title}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{Body}{/Section}</w:t></w:r></w:p>';
        String xml = '<w:body>' + inline + spanning + section + '</w:body>';

        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(
            xml,
            new Set<String>{ 'Inline', 'Spanning', 'Section' }
        );
        Assert.areEqual(3, plan.slots.size());
        Assert.areEqual('{Name}', plan.slots[0].innerXml);
        Assert.areEqual('{First}</w:t></w:r></w:p><w:p><w:r><w:t>{Last}', plan.slots[1].innerXml);
        Assert.areEqual('{Title}</w:t></w:r></w:p><w:p><w:r><w:t>{Body}', plan.slots[2].innerXml);
        Assert.isTrue(plan.shell.contains('Before ' + plan.slots[0].marker + ' after'));
        Assert.isTrue(plan.shell.contains('<w:t>Keep</w:t>'));
        Assert.isTrue(plan.shell.contains('<w:rPr><w:b/></w:rPr><w:t>' + plan.slots[1].marker));
        Assert.isTrue(plan.shell.contains('<w:pPr><w:sectPr/></w:pPr><w:r><w:t>' + plan.slots[2].marker));
    }

    @IsTest
    static void keepsConfiguredPagesForSkinnyRowsAndNarrowsLongTextPages() {
        Assert.areEqual(50, DocGenGiantQueryMulti.pageSizeForFields(null, 'Contact', new List<String>{ 'LastName' }));
        Assert.areEqual(11, DocGenGiantQueryMulti.pageSizeForFields(11, 'Contact', new List<String>{ 'LastName' }));
        Assert.areEqual(1, DocGenGiantQueryMulti.pageSizeForFields(1, 'EmailMessage', new List<String>{ 'TextBody' }));
        Assert.isTrue(
            DocGenGiantQueryMulti.pageSizeForFields(50, 'EmailMessage', new List<String>{ 'HtmlBody', 'TextBody' }) < 50
        );
    }

    @IsTest
    static void plansFlatConfigSiblingsFromTheSavedWordSnapshot() {
        Account account = new Account(Name = 'Snapshot example');
        insert account;
        String config = 'Name, (SELECT Email FROM Contacts), (SELECT StageName FROM Opportunities ORDER BY Id LIMIT 3)';
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Word snapshot example',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Query_Config__c = config
        );
        insert template;
        DocGen_Template_Version__c version = new DocGen_Template_Version__c(
            Template__c = template.Id,
            Is_Active__c = true
        );
        insert version;
        String title = 'docgen_tmpl_html_' + version.Id;
        insert new ContentVersion(
            Title = title,
            PathOnClient = title + '.html',
            VersionData = Blob.valueOf(
                '<html><body><p>{#Contacts}{Email}{/Contacts}</p>' +
                '<p>{#Opportunities}{StageName}{/Opportunities}</p></body></html>'
            ),
            FirstPublishLocationId = version.Id
        );

        DocGenGiantQueryMulti.Run plan = DocGenGiantQueryMulti.planWordPdf(account.Id, version.Id, config, 7);
        Assert.isTrue(plan.wordSnapshot);
        Assert.areEqual(2, plan.datasets.size());
        Assert.areEqual(new List<String>{ 'Email' }, plan.datasets[0].fields);
        Assert.areEqual(new List<String>{ 'StageName' }, plan.datasets[1].fields);
        Assert.areEqual('3', plan.datasets[1].childNode.get('limit'));
        Assert.areEqual('<p>{StageName}</p>', plan.slots[1].innerXml);
        Assert.areEqual(7, plan.datasets[1].pageSize);
    }

    @IsTest
    static void rejectsMissingRowsAndInvalidMarkers() {
        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(
            '{#Contacts}{Name}{/Contacts}',
            new Set<String>{ 'Contacts' }
        );
        try {
            plan.fill(new Map<String, String>());
            Assert.fail('A missing placement must fail.');
        } catch (DocGenException failure) {
            Assert.isTrue(failure.getMessage().contains('Missing rows'));
        }

        try {
            plan.fill('<body></body>', new Map<String, String>{ '00000' => 'Alex' });
            Assert.fail('A formatter dropping the marker must fail.');
        } catch (DocGenException failure) {
            Assert.isTrue(failure.getMessage().contains('Missing, duplicated, or reordered'));
        }

        try {
            plan.fill(plan.shell + plan.slots[0].marker, new Map<String, String>{ '00000' => 'Alex' });
            Assert.fail('A formatter duplicating the marker must fail.');
        } catch (DocGenException failure) {
            Assert.isTrue(failure.getMessage().contains('Unexpected giant query slot marker'));
        }
    }

    @IsTest
    static void rendersNestedFlatRelationshipsWithGroupScopedCounts() {
        Account account = new Account(Name = 'Grouped account');
        insert account;
        Contact first = new Contact(LastName = 'First group', AccountId = account.Id);
        Contact empty = new Contact(LastName = 'Empty group', AccountId = account.Id);
        insert new List<Contact>{ first, empty };
        insert new List<Case>{
            new Case(AccountId = account.Id, ContactId = first.Id, Subject = 'Alpha', Status = 'New', Origin = 'Phone'),
            new Case(AccountId = account.Id, ContactId = first.Id, Subject = 'Beta', Status = 'New', Origin = 'Phone')
        };

        String config = 'Name, (SELECT Name, (SELECT Subject FROM Cases ORDER BY Subject DESC LIMIT 1) FROM Contacts)';
        String body =
            '{#Contacts}<h2>{Name}</h2>{#Cases}<p>{Subject}</p>{/Cases}<p>{COUNT:Cases}</p>{/Contacts}' +
            '{#Description}<aside>{#Contacts}<p>{Name}</p>{/Contacts}</aside>{/Description}';
        DocGenGiantQueryMulti.Run plan = DocGenGiantQueryMulti.plan(body, config, account.Id);
        Assert.areEqual(1, plan.slots.size());
        Assert.areEqual('Contacts', plan.slots[0].queryKey);
        DocGenGiantQueryPlan visible = DocGenGiantQueryPlan.compileGrouped(
            body,
            new Set<String>{ 'Contacts' },
            new Map<String, Object>{ 'Description' => 'Show additional table' }
        );
        Assert.areEqual(2, visible.slots.size());
        Assert.isTrue(visible.shell.contains('<aside>' + visible.slots[1].marker + '</aside>'));
        DocGenGiantQueryMulti.Dataset dataset = plan.datasets[0];
        Assert.areEqual(new List<String>{ 'Id', 'Name' }, dataset.fields);

        Database.Cursor cursor = DocGenDataRetriever.openGiantQueryCursor(
            account.Id,
            dataset.childNode,
            dataset.fields
        );
        Map<Id, String> groups = new Map<Id, String>();
        for (SObject row : cursor.fetch(0, 2)) {
            Map<String, Object> data = DocGenDataRetriever.loadGiantGroup(account.Id, dataset.nestedQuery, row);
            groups.put(row.Id, DocGenService.mergeGiantHtml(plan.slots[0].innerXml, data, 1));
        }
        Assert.areEqual('<h2>First group</h2><p>Beta</p><p>1</p>', groups.get(first.Id));
        Assert.areEqual('<h2>Empty group</h2><p>0</p>', groups.get(empty.Id));
    }
}
