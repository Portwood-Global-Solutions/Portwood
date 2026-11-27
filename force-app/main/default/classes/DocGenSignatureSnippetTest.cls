/**
 * #587: signing tags inside shared snippets ({%snippet:key}) must be discovered the
 * same way as tags typed directly into the template, because generation expands the
 * snippet before the frozen body is sentinel-substituted.
 */
@IsTest
private class DocGenSignatureSnippetTest {
    private static final String SIGNOFF_HTML =
        '<p>Customer signature</p><p>{@Signature_Customer:1:Full}</p>' +
        '<p>Customer initials</p><p>{@Signature_Customer:1:Initials}</p>' +
        '<p>Date signed</p><p>{@Signature_Customer:1:Date}</p>' +
        '<p>Choose an acceptance date</p><p>{@Signature_Customer:1:DatePick}</p>';

    @TestSetup
    static void setup() {
        insert new Account(Name = 'Snippet Sig Co', Industry = 'Technology');
    }

    private static Map<String, Object> createSnippet(String key, String html) {
        return DocGenSnippetController.saveSnippet(null, key, key, 'Terms & Conditions', html, null, true);
    }

    private static Id createHtmlTemplate(String bodyHtml) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Snippet Signature Template ' + Datetime.now().getTime(),
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, Industry',
            Type__c = 'HTML',
            Output_Format__c = 'PDF'
        );
        insert tmpl;
        ContentVersion bodyCv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'template.html',
            VersionData = Blob.valueOf(bodyHtml),
            FirstPublishLocationId = tmpl.Id
        );
        insert bodyCv;
        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Is_Active__c = true,
            Content_Version_Id__c = bodyCv.Id
        );
        return tmpl.Id;
    }

    private static String customerSignerJson() {
        return '[{"signerName":"Casey Customer","signerEmail":"casey@example.com","roleName":"Customer"}]';
    }

    private static Map<String, Integer> countByType(List<DocGenSignatureSenderController.PlacementInfo> placements) {
        Map<String, Integer> out = new Map<String, Integer>();
        for (DocGenSignatureSenderController.PlacementInfo p : placements) {
            out.put(p.placementType, (out.containsKey(p.placementType) ? out.get(p.placementType) : 0) + 1);
        }
        return out;
    }

    private static String frozenBody(Id templateId) {
        DocGen_Signature_Request__c req = [
            SELECT Frozen_Document_CV_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Template__c = :templateId
            LIMIT 1
        ];
        String json = [SELECT VersionData FROM ContentVersion WHERE Id = :req.Frozen_Document_CV_Id__c]
            .VersionData.toString();
        return (String) DocGenSignatureService.loadFrozenMergeData(json)[0].get('combinedDocumentXml');
    }

    @IsTest
    static void allFourTagsInsideSnippetAreDiscovered() {
        createSnippet('agreement-signoff', SIGNOFF_HTML);
        Id tplId = createHtmlTemplate('<html><body><div>{%snippet:agreement-signoff}</div></body></html>');

        List<DocGenSignatureSenderController.PlacementInfo> placements = DocGenSignatureSenderController.getTemplateSignaturePlacements(
            tplId
        );

        System.assertEquals(4, placements.size(), 'Every tag inside the snippet becomes a placement');
        Map<String, Integer> byType = countByType(placements);
        for (String t : new List<String>{ 'Full', 'Initials', 'Date', 'DatePick' }) {
            System.assertEquals(1, byType.get(t), 'One ' + t + ' placement expected, got ' + byType);
        }
        for (DocGenSignatureSenderController.PlacementInfo p : placements) {
            System.assertEquals('Customer', p.role, 'Snippet tags keep their role');
        }
        System.assertEquals(
            new List<String>{ 'Customer' },
            DocGenSignatureSenderController.getTemplateSignatureRoles(tplId),
            'The Sender lists the role found inside the snippet'
        );
    }

    @IsTest
    static void snippetTagsPlusTemplateTagAreAllDiscovered() {
        createSnippet('agreement-signoff', SIGNOFF_HTML);
        Id tplId = createHtmlTemplate(
            '<html><body><div>{%snippet:agreement-signoff}</div>' +
            '<p>Customer signature (template copy)</p><p>{@Signature_Customer:1:Full}</p></body></html>'
        );

        List<DocGenSignatureSenderController.PlacementInfo> placements = DocGenSignatureSenderController.getTemplateSignaturePlacements(
            tplId
        );

        System.assertEquals(5, placements.size(), 'Four snippet tags plus the template tag');
        System.assertEquals(2, countByType(placements).get('Full'), 'Both Full occurrences get a placement');
    }

    @IsTest
    static void tagInsideNestedSnippetIsDiscovered() {
        createSnippet('inner-initials', '<p>Initials {@Signature_Customer:1:Initials}</p>');
        createSnippet('outer-block', '<p>Outer clause</p>{%snippet:inner-initials}');
        Id tplId = createHtmlTemplate('<html><body>{%snippet:outer-block}</body></html>');

        List<DocGenSignatureSenderController.PlacementInfo> placements = DocGenSignatureSenderController.getTemplateSignaturePlacements(
            tplId
        );

        System.assertEquals(1, placements.size(), 'A tag two snippets deep is found');
        System.assertEquals('Initials', placements[0].placementType);
        System.assertEquals('Customer', placements[0].role);
    }

    @IsTest
    static void missingOrInactiveSnippetKeepsTemplateTags() {
        Map<String, Object> s = createSnippet('retired-signoff', '<p>{@Signature_Customer:1:Initials}</p>');
        DocGenSnippetController.saveSnippet(
            (Id) s.get('id'),
            (String) s.get('name'),
            (String) s.get('assetKey'),
            'Terms & Conditions',
            '<p>{@Signature_Customer:1:Initials}</p>',
            (String) s.get('currentVersionId'),
            false
        );
        Id missingTpl = createHtmlTemplate(
            '<html><body>{%snippet:does-not-exist}<p>{@Signature_Customer:1:Full}</p></body></html>'
        );
        Id inactiveTpl = createHtmlTemplate(
            '<html><body>{%snippet:retired-signoff}<p>{@Signature_Customer:1:Full}</p></body></html>'
        );

        for (Id tplId : new List<Id>{ missingTpl, inactiveTpl }) {
            List<DocGenSignatureSenderController.PlacementInfo> placements = DocGenSignatureSenderController.getTemplateSignaturePlacements(
                tplId
            );
            System.assertEquals(1, placements.size(), 'Discovery does not throw and still returns the template tag');
            System.assertEquals('Full', placements[0].placementType);
        }
    }

    @IsTest
    static void templateWithoutSnippetsIsUnchanged() {
        String body =
            '<html><body><p>{@Signature_Member:1:Initials}</p>' +
            '<p>{@Signature_Member:2:Full}</p><p>{@Signature_Member:3:Date}</p></body></html>';
        Id tplId = createHtmlTemplate(body);

        System.assertEquals(
            body,
            DocGenSignatureSenderController.expandSnippetsForPlacementScan(body),
            'Text without a snippet tag passes through untouched'
        );
        System.assertEquals(null, DocGenSignatureSenderController.expandSnippetsForPlacementScan(null));

        List<DocGenSignatureSenderController.PlacementInfo> placements = DocGenSignatureSenderController.getTemplateSignaturePlacements(
            tplId
        );
        System.assertEquals(3, placements.size());
        System.assertEquals('Initials', placements[0].placementType);
        System.assertEquals('Full', placements[1].placementType);
        System.assertEquals('Date', placements[2].placementType);
    }

    @IsTest
    static void guidedSendSentinelisesEverySnippetTag() {
        createSnippet('agreement-signoff', SIGNOFF_HTML);
        Id tplId = createHtmlTemplate(
            '<html><body><h1>{Name}</h1><div>{%snippet:agreement-signoff}</div></body></html>'
        );
        Account a = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(
            tplId,
            a.Id,
            customerSignerJson(),
            'Parallel',
            null,
            null,
            null,
            null,
            null,
            false,
            null
        );
        Test.stopTest();

        String body = frozenBody(tplId);
        System.assert(!body.contains('>Signatures</div>'), 'No synthetic Signatures block for a tagged snippet');
        System.assert(!body.contains('{@Signature_'), 'No literal signing tag left in the frozen body: ' + body);
        for (Integer i = 0; i < 4; i++) {
            System.assertEquals(1, body.countMatches('@@SIG-' + i + '@@'), 'Sentinel @@SIG-' + i + '@@ placed once');
        }

        Map<String, String> typeBySentinel = new Map<String, String>();
        for (DocGen_Signature_Placement__c p : [
            SELECT Tag_Text__c, Placement_Type__c, Signer__r.Role_Name__c
            FROM DocGen_Signature_Placement__c
            WHERE Signature_Request__r.Template__c = :tplId
        ]) {
            System.assertEquals('Customer', p.Signer__r.Role_Name__c);
            typeBySentinel.put(p.Tag_Text__c, p.Placement_Type__c);
        }
        System.assertEquals(4, typeBySentinel.size(), 'Four placements created');
        // Each sentinel sits where its own tag was typed in the snippet.
        for (String sentinel : typeBySentinel.keySet()) {
            String type = typeBySentinel.get(sentinel);
            String label = type == 'Full'
                ? 'Customer signature'
                : type == 'Initials'
                      ? 'Customer initials'
                      : type == 'Date' ? 'Date signed' : 'Choose an acceptance date';
            System.assert(
                body.contains('<p>' + label + '</p><p>' + sentinel + '</p>'),
                type + ' placement ' + sentinel + ' should follow its label'
            );
        }
    }

    @IsTest
    static void sentinelsFollowTagTextWhenSequencesDiffer() {
        // The snippet (earlier in the document) holds the sequence-2 tag; the template's
        // own sequence-1 tag comes later. Placements sort by sequence, so the later tag
        // gets @@SIG-0@@ and the snippet tag @@SIG-1@@: each must still land on its own tag.
        createSnippet('late-initials', '<p>Initials here {@Signature_Customer:2:Initials}</p>');
        Id tplId = createHtmlTemplate(
            '<html><body>{%snippet:late-initials}<p>Sign here {@Signature_Customer:1:Full}</p></body></html>'
        );
        Account a = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(
            tplId,
            a.Id,
            customerSignerJson(),
            'Parallel',
            null,
            null,
            null,
            null,
            null,
            false,
            null
        );
        Test.stopTest();

        String body = frozenBody(tplId);
        System.assert(body.contains('Initials here @@SIG-1@@'), 'Snippet tag keeps its position: ' + body);
        System.assert(body.contains('Sign here @@SIG-0@@'), 'Template tag keeps its position: ' + body);
        System.assert(body.indexOf('@@SIG-1@@') < body.indexOf('@@SIG-0@@'), 'Document order is preserved');

        Map<String, DocGen_Signature_Placement__c> bySentinel = new Map<String, DocGen_Signature_Placement__c>();
        for (DocGen_Signature_Placement__c p : [
            SELECT Tag_Text__c, Placement_Type__c, Sequence_Order__c
            FROM DocGen_Signature_Placement__c
            WHERE Signature_Request__r.Template__c = :tplId
        ]) {
            bySentinel.put(p.Tag_Text__c, p);
        }
        System.assertEquals('Full', bySentinel.get('@@SIG-0@@').Placement_Type__c);
        System.assertEquals(1, bySentinel.get('@@SIG-0@@').Sequence_Order__c);
        System.assertEquals('Initials', bySentinel.get('@@SIG-1@@').Placement_Type__c);
        System.assertEquals(2, bySentinel.get('@@SIG-1@@').Sequence_Order__c);
    }

    @IsTest
    static void wordSnippetTagsAreDiscoveredAndStayContiguousAfterMerge() {
        createSnippet('word-initials', '<p>Customer initials</p><p>{@Signature_Customer:1:Initials}</p>');

        // Discovery: a Word template whose pre-decomposed document.xml splits the snippet
        // tag across runs, as Word often does.
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Word Snippet Sig ' + Datetime.now().getTime(),
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Type__c = 'Word',
            Output_Format__c = 'PDF'
        );
        insert tmpl;
        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(Template__c = tmpl.Id, Is_Active__c = true);
        insert ver;
        insert new ContentVersion(
            Title = 'docgen_tmpl_xml_' + ver.Id + '_word__document.xml',
            PathOnClient = 'document.xml',
            VersionData = Blob.valueOf(
                '<w:document><w:body><w:p><w:r><w:t>{%snippet:</w:t></w:r>' +
                '<w:r><w:t>word-initials}</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        List<DocGenSignatureSenderController.PlacementInfo> placements = DocGenSignatureSenderController.getTemplateSignaturePlacements(
            tmpl.Id
        );
        System.assertEquals(1, placements.size(), 'Tag inside a Word template snippet is found');
        System.assertEquals('Initials', placements[0].placementType);

        // Merge: the Word snippet branch must emit the tag text whole inside one <w:t>,
        // so the frozen-body replaceFirst can find it.
        String merged;
        DocGenService.preserveSignatureTags = true;
        try {
            merged = DocGenService.processXmlForTest(
                '<w:p><w:r><w:t>{%snippet:word-initials}</w:t></w:r></w:p>',
                new Map<String, Object>(),
                'Word'
            );
        } finally {
            DocGenService.preserveSignatureTags = false;
        }
        System.assert(
            merged.contains('<w:t xml:space="preserve">' + placements[0].tagText + '</w:t>'),
            'Tag text survives the Word snippet conversion in one run: ' + merged
        );
        System.assert(
            merged.replaceFirst(Pattern.quote(placements[0].tagText), '@@SIG-0@@').contains('@@SIG-0@@'),
            'Frozen-body substitution finds the tag'
        );
    }
}
