@IsTest
private class DocGenGiantQueryAssemblerTest {
    @IsTest
    static void preservesSeparateTableHeadersAndMarkupWhenPaginating() {
        String alphaOpen =
            '<table class="alpha"><colgroup><col width="95%" /></colgroup>' +
            '<thead><tr><th>Alpha header</th></tr></thead><tbody class="alpha-body">';
        String alphaClose = '<tr><td>Alpha summary</td></tr></tbody></table>';
        String betaOpen =
            '<table class="beta"><colgroup><col width="60%" /></colgroup>' +
            '<thead><tr><th>Beta header</th></tr></thead><tbody>';
        String between = '<p>Between Alpha and Beta</p>';
        String betaClose = '</tbody></table>';
        String listOpen = '<ul><li>Static opening item</li>';
        String listClose = '<li>Static closing item</li></ul>';
        String source =
            alphaOpen +
            '<tr><td>{#Alpha}{Name}{/Alpha}</td></tr>' +
            alphaClose +
            between +
            betaOpen +
            '<tr><td>{#Beta}{Name}{/Beta}</td></tr>' +
            betaClose +
            listOpen +
            '<li>{#Empty}{Name}{/Empty}</li>' +
            listClose;
        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(source, new Set<String>{ 'Alpha', 'Beta', 'Empty' });
        DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(null, null, null, 'Alpha');

        Map<String, String> rows = new Map<String, String>{
            plan.slots[0].key => assembler.paginatePlannedRows(
                plan.shell,
                plan.slots[0],
                '<tr><td>A1</td></tr><tr><td>A2</td></tr><tr><td>A3</td></tr>',
                2
            ),
            plan.slots[1].key => assembler.paginatePlannedRows(
                plan.shell,
                plan.slots[1],
                '<tr><td>B1</td></tr><tr><td>B2</td></tr><tr><td>B3</td></tr>',
                2
            ),
            plan.slots[2].key => assembler.paginatePlannedRows(plan.shell, plan.slots[2], '', 2)
        };
        String actual = plan.fill(rows);

        System.assert(
            actual.contains('</tbody></table>' + alphaOpen + '<tr><td>A3</td></tr>' + alphaClose + between + betaOpen),
            actual
        );
        System.assert(
            actual.contains('</tbody></table>' + betaOpen + '<tr><td>B3</td></tr>' + betaClose + listOpen + listClose),
            actual
        );
        System.assert(!actual.contains('docgen-giant-slot-'), actual);
    }

    /**
     * #540: the engine wraps sourceStyles in its own <style> element, so the CSS the
     * assembler appends must be raw. A nested <style> voided the table rule and closed
     * the stylesheet early, leaving the row rule outside it. Rows then straddled page
     * breaks and were printed twice: clipped at the bottom of one page, whole on the next.
     */
    @IsTest
    static void plannedPdfStylesheetIsWellFormedAndKeepsRowsWhole() {
        Account acc = new Account(Name = 'Stylesheet account');
        insert acc;
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Giant Query stylesheet',
            Base_Object_API__c = 'Account',
            Type__c = 'HTML',
            Output_Format__c = 'PDF'
        );
        insert tpl;
        String body =
            '<table><tbody>{#Alpha}<tr><td>{Name}</td></tr>{/Alpha}</tbody></table>' +
            '<table><tbody>{#Beta}<tr><td>{Name}</td></tr>{/Beta}</tbody></table>';
        ContentVersion source = new ContentVersion(
            Title = 'giant-query-stylesheet-body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(
                '<html><head><style>td { color: #111111; }</style></head><body>' + body + '</body></html>'
            )
        );
        insert source;
        DocGen_Template_Version__c version = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Content_Version_Id__c = source.Id,
            Type__c = 'HTML',
            Is_Active__c = true
        );
        insert version;
        DocGenGiantQueryPlan plan = DocGenGiantQueryPlan.compile(body, new Set<String>{ 'Alpha', 'Beta' });
        String config = '{"v":3,"root":"Account","nodes":[{"id":"n0","object":"Account","fields":["Name"],"parentNode":null}]}';
        DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(
            null,
            tpl.Id,
            acc.Id,
            version.Id,
            plan.slots,
            new Map<String, Integer>(),
            config
        );

        String html = assembler.buildHtmlTemplateForHtmlType(null, null);

        Integer open = html.indexOf('<style');
        System.assert(open > -1, html);
        while (open != -1) {
            Integer close = html.indexOf('</style>', open);
            Integer next = html.indexOf('<style', open + 6);
            System.assert(close > -1 && (next == -1 || next > close), 'Nested <style> element: ' + html);
            open = next;
        }
        for (String rule : new List<String>{ 'tr { page-break-inside: avoid; }', '-fs-table-paginate: paginate' }) {
            Integer at = html.indexOf(rule);
            System.assert(at > -1, 'Missing ' + rule + ': ' + html);
            System.assert(
                html.lastIndexOf('<style', at) > html.lastIndexOf('</style>', at),
                rule + ' must sit inside a stylesheet: ' + html
            );
        }
    }

    @IsTest
    static void linksImagesForPinnedInactiveVersion() {
        Account account = new Account(Name = 'Giant Query asset recipient');
        insert account;
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Versioned Giant Query images',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert template;
        ContentVersion body = new ContentVersion(
            Title = 'Versioned body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf('<html><body></body></html>')
        );
        insert body;
        DocGen_Template_Version__c pinned = new DocGen_Template_Version__c(
            Template__c = template.Id,
            Content_Version_Id__c = body.Id,
            Is_Active__c = false
        );
        insert new List<DocGen_Template_Version__c>{
            pinned,
            new DocGen_Template_Version__c(
                Template__c = template.Id,
                Content_Version_Id__c = body.Id,
                Is_Active__c = true
            )
        };
        ContentVersion image = new ContentVersion(
            Title = 'docgen_html_img_' + pinned.Id + '_original.png',
            PathOnClient = 'original.png',
            VersionData = EncodingUtil.base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='
            ),
            FirstPublishLocationId = pinned.Id
        );
        insert image;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :image.Id].ContentDocumentId;
        String html = '<img src="/sfc/servlet.shepherd/version/download/' + image.Id + '" />';

        DocGenService.ensureTemplateAssetImageAccessForPdf(template.Id, account.Id, html);
        System.assertEquals(0, countLinks(account.Id, docId));

        DocGenService.ensureTemplateAssetImageAccessForPdf(template.Id, account.Id, html, pinned.Id);
        System.assertEquals(1, countLinks(account.Id, docId));

        DocGenService.removeTemplateImageLinksAfterRender(template.Id, account.Id, html);
        System.assertEquals(0, countLinks(account.Id, docId));
    }

    private static Integer countLinks(Id accountId, Id docId) {
        return [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :accountId AND ContentDocumentId = :docId
        ];
    }
}
