@IsTest
private class DocGenAssetPolicyTest {
    @IsTest
    static void onlyThisOrgsNativeAssetRoutesAreAllowed() {
        String orgBase = URL.getOrgDomainUrl().toExternalForm();
        System.assertEquals(orgBase + '/resource/logo', DocGenAssetPolicy.assetUrl('/resource/logo'));
        System.assertEquals(
            orgBase + '/sfc/dist/version/download/?d=public',
            DocGenAssetPolicy.assetUrl(orgBase + '/sfc/dist/version/download/?d=public')
        );
        String content = 'https://' + DomainCreator.getContentHostname() + '/sfc/dist/version/download/?d=public';
        System.assertEquals(content, DocGenAssetPolicy.assetUrl(content));
        for (
            String value : new List<String>{
                'https://example.com/logo.png',
                'https://other-org.file.force.com/sfc/dist/version/download/?d=x',
                '//example.com/logo',
                orgBase + '/apex/redirect',
                orgBase + '/resource/../apex/redirect',
                'https://user@example.com/resource/logo',
                orgBase + ':444/resource/logo',
                'javascript:alert(1)'
            }
        )
            System.assertEquals(null, DocGenAssetPolicy.assetUrl(value), value);
    }

    @IsTest
    static void formattingInlineImagesAndManualLinksRemainUsable() {
        String html = '<style>/* local formatting */p{color:#123456;background:url(/resource/local)}</style><p><a href="https://example.com/support">Support</a><img src="/sfc/servlet.shepherd/version/download/068000000000001AAA"/><img src="data:image/png;base64,AAAA"/></p>';
        System.assertEquals(html, DocGenAssetPolicy.assertHtmlResources(html));
        String svg = '<svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="g"/></defs><rect fill="url(#g)"/><text>Native chart</text></svg>';
        System.assertEquals(svg, DocGenAssetPolicy.assertHtmlResources(svg));
        String escaped = '<p title="src=\'https://example.com/text\'">&lt;img src=x onerror=alert(1)&gt;</p>';
        System.assertEquals(escaped, DocGenAssetPolicy.assertHtmlResources(escaped), 'Escaped text is not a resource.');
    }

    @IsTest
    static void externalResourceAndDisguisedCssLoadsAreRejected() {
        for (
            String html : new List<String>{
                '<img src="https://example.com/tracker.png">',
                '<img src="&#104;ttps://example.com/image.png">',
                '<img srcset="https://example.com/image.png 2x">',
                '<div style="background:url(https://example.com/image)">x</div>',
                '<style>@import "https://example.com/font.css";</style>',
                '<style>p{background:image-set("https://example.com/image" 1x)}</style>',
                '<style>p{background:image("https://example.com/image")}</style>',
                '<style>p{background:u\\72l(https://example.com/image)}</style>',
                '<iframe src="https://example.com"></iframe>',
                '<link rel="stylesheet" href="https://example.com/style.css">',
                '<script>fetch("https://example.com")</script>',
                '<svg><image href="https://example.com/tracker"/></svg>',
                '<svg><rect fill="url(https://example.com/tracker)"/></svg>',
                '<svg><set attributeName="href" to="https://example.com/tracker"/></svg>'
            }
        ) {
            Boolean rejected = false;
            try {
                DocGenAssetPolicy.assertHtmlResources(html);
            } catch (DocGenException ex) {
                rejected = ex.getMessage().contains('Salesforce-hosted');
            }
            System.assert(rejected, html);
        }
    }

    @IsTest
    static void linkedOfficeImagesAreRejectedAndHyperlinksArePreserved() {
        for (String type : new List<String>{ 'image', 'hyperlink' }) {
            Compression.ZipWriter writer = new Compression.ZipWriter();
            writer.addEntry(
                'word/_rels/document.xml.rels',
                Blob.valueOf(
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/' +
                        type +
                        '" TargetMode="External" Target="https://example.com/file"/></Relationships>'
                )
            );
            Boolean rejected = false;
            try {
                DocGenAssetPolicy.assertOfficeResources(new Compression.ZipReader(writer.getArchive()));
            } catch (DocGenException ex) {
                rejected = true;
            }
            System.assertEquals(type == 'image', rejected);
        }
    }

    @IsTest
    static void largeEmbeddedImageDoesNotExhaustRegexAndCannotHideAnotherResource() {
        String html = '<p>Large inline image</p><img src="data:image/png;base64,' + 'A'.repeat(400000) + '"/>';
        System.assertEquals(html, DocGenAssetPolicy.assertHtmlResources(html));
        Boolean rejected = false;
        try {
            DocGenAssetPolicy.assertHtmlResources(html + '<img src="https://example.com/tracker.png"/>');
        } catch (DocGenException ex) {
            rejected = true;
        }
        System.assert(rejected, 'Skipping inline bytes must not skip a later external image.');
    }

    @IsTest
    static void inlineSvgMayUseLocalFragmentsButCannotLoadAnotherResource() {
        String svg = '<svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="g"/></defs><rect fill="url(#g)"/></svg>';
        String html = '<img src="data:image/svg+xml;base64,' + EncodingUtil.base64Encode(Blob.valueOf(svg)) + '"/>';
        System.assertEquals(html, DocGenAssetPolicy.assertHtmlResources(html));
        svg = '<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/tracker.png"/></svg>';
        Boolean rejected = false;
        try {
            DocGenAssetPolicy.assertHtmlResources(
                '<img src="data:image/svg+xml;base64,' + EncodingUtil.base64Encode(Blob.valueOf(svg)) + '"/>'
            );
        } catch (DocGenException ex) {
            rejected = true;
        }
        System.assert(rejected);
    }
}
