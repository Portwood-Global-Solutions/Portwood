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
