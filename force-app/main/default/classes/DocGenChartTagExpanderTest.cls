@IsTest
private class DocGenChartTagExpanderTest {
    @IsTest
    static void noTags_returnsInputUnchanged() {
        String input = '<html><body><p>Hello {Name}</p></body></html>';
        System.assertEquals(input, DocGenChartTagExpander.expand(input, 'HTML'));
    }

    @IsTest
    static void nullInput_returnsNull() {
        System.assertEquals(null, DocGenChartTagExpander.expand(null, 'HTML'));
    }

    @IsTest
    static void barMinimal_emitsChartBucketLoop() {
        String input = '<body>{Chart:Survey_Responses__r:Selected_Answer__c}</body>';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(
            out.contains('{#ChartBucket:Survey_Responses__r:Selected_Answer__c}'),
            'Expected expanded snippet to contain a ChartBucket open tag. Got: ' + out
        );
        System.assert(out.contains('{/ChartBucket}'), 'Expected matching close tag.');
        System.assert(out.contains('{key_label}'), 'Bar style should reference key_label.');
        System.assert(out.contains('{percent}'), 'Bar style should reference percent.');
    }

    @IsTest
    static void barWithTitle_emitsHeading() {
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:bar:title=How satisfied?}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('<h2'), 'Expected heading for title.');
        System.assert(out.contains('How satisfied?'), 'Title text should pass through.');
    }

    @IsTest
    static void barWithWhere_passesOptionToChartBucket() {
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:bar:where=Q__c=1}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('where=Q__c=1'), 'where clause should pass through to ChartBucket tag.');
    }

    @IsTest
    static void pivot_requiresGroupBy() {
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:pivot}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('Chart error'), 'Missing groupBy should render error block.');
        System.assert(out.contains('groupBy='), 'Error should hint at groupBy.');
    }

    @IsTest
    static void pivot_requiresColSort() {
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:pivot:groupBy=Dept__c}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('Chart error'), 'Missing colSort should render error block.');
        System.assert(out.contains('colSort='), 'Error should hint at colSort.');
    }

    @IsTest
    static void pivot_emitsHeadersFromColSort() {
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:pivot:groupBy=Dept__c&colSort=Eng,Sales,Mkt}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('Eng'), 'Header should include Eng.');
        System.assert(out.contains('Sales'), 'Header should include Sales.');
        System.assert(out.contains('Mkt'), 'Header should include Mkt.');
        System.assert(out.contains('Total'), 'Pivot should emit a Total column.');
        System.assert(out.contains('{#cols}'), 'Pivot body should iterate columns.');
    }

    @IsTest
    static void clustered_emitsLegendAndCols() {
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:clustered:groupBy=Dept__c&colSort=Eng,Sales}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('{percent_int}'), 'Clustered uses percent_int for px heights.');
        System.assert(out.contains('{#cols}'), 'Clustered iterates columns inside each answer group.');
    }

    @IsTest
    static void stacked_emitsPercentOfRow() {
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:stacked:groupBy=Dept__c&colSort=Eng,Sales}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('{percent_of_row}'), 'Stacked uses percent_of_row for segment widths.');
    }

    @IsTest
    static void unknownStyle_rendersErrorBlock() {
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:waterfall}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('Chart error'), 'Unknown style should render error block.');
        System.assert(out.contains('waterfall'), 'Error should mention the bad style.');
    }

    @IsTest
    static void powerPointMalformedChartErrorIsEscaped() {
        String input = '<a:t>{Chart:Survey_Responses__r:Selected_Answer__c:r><a}</a:t>';
        String out = DocGenChartTagExpander.expand(input, 'PowerPoint');
        System.assert(out.contains('[Chart error:'), 'PowerPoint should render a text error placeholder. Got: ' + out);
        System.assert(
            !out.contains('style "r><a"'),
            'Raw XML-ish error text must not be emitted into OOXML. Got: ' + out
        );
        System.assert(out.contains('&quot;r&gt;&lt;a&quot;'), 'Error text should be XML-escaped. Got: ' + out);
    }

    @IsTest
    static void missingField_rendersError() {
        String input = '{Chart:Survey_Responses__r}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('Chart error'), 'Missing field should render error.');
    }

    @IsTest
    static void unterminatedTag_rendersError() {
        String input = '<p>{Chart:Survey_Responses__r:Selected_Answer__c';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(
            out.contains('Chart error') || out.contains('Unterminated'),
            'Unterminated tag should render error.'
        );
    }

    @IsTest
    static void wordTemplate_noChartCvMap_emitsTextPlaceholder() {
        // Post-#117: Word templates no longer throw on {Chart:...}. The
        // server-side path with no LWC to rasterize emits a text placeholder
        // identifying the chart so authors see the gap rather than silent loss.
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:bar:title=How satisfied?}';
        String out = DocGenChartTagExpander.expand(input, 'Word');
        System.assert(out.contains('[Chart:'), 'Word + no chartCvMap should emit text placeholder. Got: ' + out);
        System.assert(out.contains('How satisfied?'), 'Placeholder should include the chart title. Got: ' + out);
        System.assert(!out.contains('<h2'), 'Placeholder must NOT emit HTML in Word output (would corrupt OOXML).');
    }

    @IsTest
    static void wordTemplate_withChartCvMap_emitsImageTag() {
        String input = '{Chart:Responses__r:A__c:bar}';
        // Same option set produces the same signature both sides; here we
        // pre-compute the signature with the controller's helper so the test
        // doesn't have to hand-roll a SHA-256.
        Map<String, String> opts = new Map<String, String>();
        String sig = DocGenChartImageController.tagSignature('Responses__r', 'A__c', 'bar', opts);
        String fakeCvId = '0681x00000000000001';
        Map<String, String> chartCvMap = new Map<String, String>{ sig => fakeCvId };
        Map<String, Object> data = new Map<String, Object>();

        String out = DocGenChartTagExpander.expand(input, 'Word', data, chartCvMap);

        System.assert(
            out.contains('{%__dgchart_' + fakeCvId + '}'),
            'Word + chartCvMap should emit synthetic image tag. Got: ' + out
        );
        System.assertEquals(
            fakeCvId,
            (String) data.get('__dgchart_' + fakeCvId),
            'Data map should be seeded with the synthetic key → CV Id.'
        );
    }

    @IsTest
    static void wordTemplate_titledChart_signatureMatchesController() {
        // Regression guard: pre-fix, the expander stripped `title` from opts
        // before hashing while the controller hashed with title intact. Result:
        // every titled chart fell back to text in Word. Both sides must hash
        // the SAME map shape.
        String tag = '{Chart:Survey_Responses__r:Selected_Answer__c:bar:title=How Satisfied?}';
        Map<String, String> opts = new Map<String, String>{ 'title' => 'How Satisfied?' };
        String controllerSig = DocGenChartImageController.tagSignature(
            'Survey_Responses__r',
            'Selected_Answer__c',
            'bar',
            opts
        );

        String fakeCvId = '0681x00000000000099';
        Map<String, String> chartCvMap = new Map<String, String>{ controllerSig => fakeCvId };
        Map<String, Object> data = new Map<String, Object>();

        String out = DocGenChartTagExpander.expand(tag, 'Word', data, chartCvMap);

        System.assert(
            out.contains('{%__dgchart_' + fakeCvId + '}'),
            'Expander must hash the same map shape as the controller, including title. Got: ' + out
        );
        System.assert(
            !out.contains('[Chart:'),
            'Should NOT fall back to text placeholder when CV is present in the map.'
        );
    }

    @IsTest
    static void wordTemplate_signatureStable_acrossOptionOrder() {
        // Same options in different order must hash to the same signature so
        // the LWC and the expander agree on which CV maps to which tag.
        Map<String, String> aFirst = new Map<String, String>{ 'colors' => '#aaa,#bbb', 'width' => '400' };
        Map<String, String> bFirst = new Map<String, String>{ 'width' => '400', 'colors' => '#aaa,#bbb' };
        System.assertEquals(
            DocGenChartImageController.tagSignature('Rel__r', 'F__c', 'bar', aFirst),
            DocGenChartImageController.tagSignature('Rel__r', 'F__c', 'bar', bFirst),
            'Signature must be order-independent.'
        );
    }

    @IsTest
    static void multipleTags_allExpanded() {
        String input =
            '{Chart:Survey_Responses__r:Selected_Answer__c:bar:title=Q1}' +
            '<p>middle</p>' +
            '{Chart:Survey_Responses__r:Selected_Answer__c:bar:title=Q2}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('Q1'), 'First tag expanded.');
        System.assert(out.contains('Q2'), 'Second tag expanded.');
        System.assert(out.contains('middle'), 'Static content preserved between tags.');
        Integer chartBucketOpens = out.countMatches('{#ChartBucket:');
        System.assertEquals(2, chartBucketOpens, 'Should emit two ChartBucket open tags.');
    }

    /**
     * The integration test: expand a {Chart:...} tag, feed the result into
     * DocGenService.processXmlForTest (HTML mode), and confirm bucket data
     * actually fills in. Verifies the expander's output is a valid template
     * that the downstream ChartBucket resolver consumes correctly.
     */
    @IsTest
    static void barTag_resolvesEndToEnd() {
        String tag = '{Chart:Responses__r:A__c:bar}';
        String expanded = DocGenChartTagExpander.expand(tag, 'HTML');
        Map<String, Object> data = new Map<String, Object>{
            'Responses__r' => new List<Object>{
                new Map<String, Object>{ 'A__c' => 'Yes' },
                new Map<String, Object>{ 'A__c' => 'Yes' },
                new Map<String, Object>{ 'A__c' => 'No' }
            }
        };
        Test.startTest();
        String rendered = DocGenService.processXmlForTest(expanded, data, 'HTML');
        Test.stopTest();

        System.assert(
            rendered.contains('Yes') && rendered.contains('No'),
            'Both bucket keys should appear in rendered output. Got: ' + rendered
        );
        System.assert(rendered.contains('66.7'), 'Yes bucket = 66.7%. Got: ' + rendered);
        System.assert(rendered.contains('33.3'), 'No bucket = 33.3%. Got: ' + rendered);
        System.assert(!rendered.contains('{key_label}'), 'Template placeholders should be replaced.');
        System.assert(!rendered.contains('{percent}'), 'Template placeholders should be replaced.');
    }

    /**
     * Google Docs / pandoc HTML-escape & to &amp; on export. The expander must
     * decode common XML entities so cross-tab option strings (which use & as
     * the option separator) parse correctly when the template came from a
     * Docs / Word round-trip rather than direct HTML authoring.
     */
    @IsTest
    static void htmlEntitiesInTagAreDecoded() {
        String input = '{Chart:R__r:F__c:pivot:groupBy=Dept__c&amp;colSort=Eng,Sales&amp;title=Q&apos;s}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('groupBy=Dept__c'), 'groupBy option should survive &amp; decode. Got: ' + out);
        System.assert(out.contains('colSort=Eng,Sales'), 'colSort option should survive &amp; decode. Got: ' + out);
        System.assert(out.contains('Eng'), 'Pivot headers should appear from colSort.');
        System.assert(!out.contains('Chart error'), 'Decoded tag should parse cleanly.');
    }

    @IsTest
    static void titleIsEscaped() {
        String input = '{Chart:Survey_Responses__r:Selected_Answer__c:bar:title=<script>alert(1)</script>}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(!out.contains('<script>'), 'Title HTML must be escaped.');
        System.assert(out.contains('&lt;script&gt;'), 'Title HTML should be XML-escaped.');
    }

    // ─── Path-C SVG unification (htmlRender=svg opt-in) ─────────────────────
    // The htmlRender=svg modifier routes HTML output through
    // DocGenSvgChartSerializer.emit, sharing one per-style renderer with the
    // PNG-via-CV pipeline. These tests verify the opt-in is wired correctly,
    // doesn't affect the existing CSS-bar default, and produces a syntactically
    // valid inline SVG.

    @IsTest
    static void htmlRenderSvg_defaultIsCssBar_noRegression() {
        // Without htmlRender=svg the legacy CSS-bar table path runs — the
        // expander returns the {#ChartBucket:...} loop body, NOT a raw <svg>.
        String input = '{Chart:Responses__r:A__c:bar}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(
            out.contains('{#ChartBucket:'),
            'Default HTML path must keep emitting {#ChartBucket} loops. Got: ' + out
        );
        System.assert(
            !out.contains('<svg'),
            'Default HTML path must NOT emit inline SVG (would break Flying Saucer PDF). Got: ' + out
        );
    }

    @IsTest
    static void htmlRenderSvg_barStyle_emitsInlineSvg() {
        // Opt in to SVG, with pre-loaded relationship data so bucket
        // resolution happens in-memory (no SOQL needed for the test).
        String input = '{Chart:Responses__r:A__c:bar:htmlRender=svg}';
        Map<String, Object> data = new Map<String, Object>{
            'Responses__r' => new List<Object>{
                new Map<String, Object>{ 'A__c' => 'Yes' },
                new Map<String, Object>{ 'A__c' => 'Yes' },
                new Map<String, Object>{ 'A__c' => 'No' }
            }
        };
        String out = DocGenChartTagExpander.expand(input, 'HTML', data, null);
        System.assert(out.contains('<svg'), 'htmlRender=svg should produce inline SVG. Got: ' + out);
        System.assert(out.contains('</svg>'), 'SVG must be closed.');
        System.assert(out.contains('Yes'), 'Bucket label "Yes" should appear in SVG text. Got: ' + out);
        System.assert(out.contains('No'), 'Bucket label "No" should appear in SVG text.');
        System.assert(
            !out.contains('{#ChartBucket:'),
            'SVG path must NOT also emit the legacy ChartBucket loop. Got: ' + out
        );
    }

    @IsTest
    static void htmlRenderSvg_columnStyle_emitsInlineSvg() {
        String input = '{Chart:Responses__r:A__c:column:htmlRender=svg}';
        Map<String, Object> data = new Map<String, Object>{
            'Responses__r' => new List<Object>{
                new Map<String, Object>{ 'A__c' => 'Alpha' },
                new Map<String, Object>{ 'A__c' => 'Beta' }
            }
        };
        String out = DocGenChartTagExpander.expand(input, 'HTML', data, null);
        System.assert(out.contains('<svg'), 'column + htmlRender=svg should produce inline SVG. Got: ' + out);
        System.assert(out.contains('Alpha'), 'Column labels should appear in SVG.');
    }

    @IsTest
    static void htmlRenderSvg_pieStyle_emitsInlineSvg() {
        String input = '{Chart:Responses__r:A__c:pie:htmlRender=svg}';
        Map<String, Object> data = new Map<String, Object>{
            'Responses__r' => new List<Object>{
                new Map<String, Object>{ 'A__c' => 'Foo' },
                new Map<String, Object>{ 'A__c' => 'Bar' }
            }
        };
        String out = DocGenChartTagExpander.expand(input, 'HTML', data, null);
        System.assert(out.contains('<svg'), 'pie + htmlRender=svg should produce inline SVG. Got: ' + out);
        System.assert(out.contains('<path'), 'Pie slices are <path> elements.');
    }

    @IsTest
    static void htmlRenderSvg_donutStyle_emitsInlineSvg() {
        String input = '{Chart:Responses__r:A__c:donut:htmlRender=svg}';
        Map<String, Object> data = new Map<String, Object>{
            'Responses__r' => new List<Object>{
                new Map<String, Object>{ 'A__c' => 'X' },
                new Map<String, Object>{ 'A__c' => 'X' },
                new Map<String, Object>{ 'A__c' => 'Y' }
            }
        };
        String out = DocGenChartTagExpander.expand(input, 'HTML', data, null);
        System.assert(out.contains('<svg'), 'donut + htmlRender=svg should produce inline SVG. Got: ' + out);
    }

    @IsTest
    static void htmlRenderSvg_titlePassesIntoSvg() {
        // Title is consumed by the expander, then re-injected into the SVG
        // options so the serializer renders the heading INSIDE the SVG —
        // keeps the chart self-contained without an external <h2>.
        String input = '{Chart:Responses__r:A__c:bar:htmlRender=svg&title=Quarter Results}';
        Map<String, Object> data = new Map<String, Object>{
            'Responses__r' => new List<Object>{ new Map<String, Object>{ 'A__c' => 'A' } }
        };
        String out = DocGenChartTagExpander.expand(input, 'HTML', data, null);
        System.assert(out.contains('Quarter Results'), 'Title should appear inside the SVG. Got: ' + out);
        System.assert(
            !out.contains('<h2'),
            'SVG path should NOT emit an external <h2> — title goes inside the SVG. Got: ' + out
        );
    }

    @IsTest
    static void htmlRenderSvg_emptyData_emitsNoDataPlaceholder() {
        // Resolver returns empty buckets when data is null AND no parent Id
        // is available for SOQL fallback. The SVG serializer's emitEmpty
        // produces a "No data" placeholder rather than throwing or vanishing.
        String input = '{Chart:Responses__r:A__c:bar:htmlRender=svg}';
        String out = DocGenChartTagExpander.expand(input, 'HTML', null, null);
        System.assert(out.contains('<svg'), 'Empty-data SVG path still emits an SVG.');
        System.assert(out.contains('No data'), 'Empty buckets should produce the "No data" placeholder. Got: ' + out);
    }

    @IsTest
    static void htmlRenderSvg_crossTabStyle_errorsWithGuidance() {
        // pivot/clustered/stacked aren't on the SVG serializer's supported
        // style list, so the opt-in shouldn't apply. The expander hits the
        // unified error rather than silently degrading.
        String input = '{Chart:Responses__r:A__c:pivot:htmlRender=svg&groupBy=Dept__c&colSort=Eng}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        // pivot still expects {#cols} body emission, so the cross-tab check
        // runs first; this test confirms htmlRender=svg doesn't override the
        // cross-tab requirements (the user gets the CSS-bar pivot anyway,
        // which is the documented v1 behavior for cross-tab styles).
        System.assert(
            out.contains('{#cols}'),
            'Cross-tab styles ignore htmlRender=svg and fall through to CSS-bar pivot. Got: ' + out
        );
    }

    @IsTest
    static void htmlRenderSvg_bareColumnStyle_errorsWithoutOptIn() {
        // {Chart:R:F:column} without htmlRender=svg has no CSS-bar renderer
        // (column is SVG-only) — the expander surfaces an actionable error
        // pointing the author at the opt-in rather than silently dropping
        // the chart.
        String input = '{Chart:Responses__r:A__c:column}';
        String out = DocGenChartTagExpander.expand(input, 'HTML');
        System.assert(out.contains('Chart error'), 'Bare column style should render an error block. Got: ' + out);
        System.assert(out.contains('htmlRender=svg'), 'Error should point the author at the htmlRender=svg opt-in.');
    }

    // ─── Task #23: HTML chart output via PNG-via-CV ──────────────────────────
    // When chartCvMap is populated, the HTML branch emits <img> tags pointing
    // at the relative CV download URL — same one-maintenance-place path the
    // Word side uses. Flying Saucer fetches the PNG when rendering HTML→PDF,
    // and the browser fetches it when rendering HTML→browser. Adding a new
    // chart style only requires landing it in DocGenChartRasterizer.

    @IsTest
    static void htmlChartCvMap_emitsImgWithRelativeUrl() {
        String input = '<body>{Chart:Responses__r:A__c:bar}</body>';
        Map<String, String> opts = new Map<String, String>();
        String signature = DocGenChartImageController.tagSignature('Responses__r', 'A__c', 'bar', opts);
        Id fakeCvId = '068000000000000AAA';
        Map<String, String> chartCvMap = new Map<String, String>();
        chartCvMap.put(signature, fakeCvId + '|420x260');

        String out = DocGenChartTagExpander.expand(input, 'HTML', new Map<String, Object>(), chartCvMap);
        System.assert(
            out.contains('/sfc/servlet.shepherd/version/download/' + fakeCvId),
            'HTML+chartCvMap should emit relative CV download URL. Got: ' + out
        );
        System.assert(out.contains('width="420"'), 'Image width attr should match the chartCvMap WxH. Got: ' + out);
        System.assert(out.contains('height="260"'), 'Image height attr should match the chartCvMap WxH. Got: ' + out);
        System.assert(
            !out.contains('{#ChartBucket'),
            'CSS-bar loop should NOT emit when chartCvMap claims the chart. Got: ' + out
        );
    }

    @IsTest
    static void htmlChartCvMap_titleBecomesAltText() {
        String input = '{Chart:Responses__r:A__c:bar:title=Satisfaction Scores}';
        Map<String, String> opts = new Map<String, String>{ 'title' => 'Satisfaction Scores' };
        String signature = DocGenChartImageController.tagSignature('Responses__r', 'A__c', 'bar', opts);
        Map<String, String> chartCvMap = new Map<String, String>();
        chartCvMap.put(signature, '068000000000000AAA|500x300');
        String out = DocGenChartTagExpander.expand(input, 'HTML', new Map<String, Object>(), chartCvMap);
        System.assert(
            out.contains('alt="Satisfaction Scores"'),
            'Chart title should become the img alt text. Got: ' + out
        );
    }

    @IsTest
    static void htmlChartCvMap_emptyMap_fallsBackToCssBar() {
        // chartCvMap supplied but no entry for this chart's signature → fall
        // through to CSS-bar default, no regression for HTML templates that
        // skip chart prep (Flow/batch).
        String input = '{Chart:Responses__r:A__c:bar}';
        Map<String, String> chartCvMap = new Map<String, String>(); // empty
        String out = DocGenChartTagExpander.expand(input, 'HTML', new Map<String, Object>(), chartCvMap);
        System.assert(out.contains('{#ChartBucket:'), 'Empty chartCvMap should fall through to CSS-bar. Got: ' + out);
        System.assert(!out.contains('<img'), 'No img tag expected when signature absent from map. Got: ' + out);
    }

    @IsTest
    static void htmlChartCvMap_nullMap_fallsBackToCssBar() {
        String input = '{Chart:Responses__r:A__c:bar}';
        String out = DocGenChartTagExpander.expand(input, 'HTML', new Map<String, Object>(), null);
        System.assert(out.contains('{#ChartBucket:'), 'Null chartCvMap should fall through to CSS-bar. Got: ' + out);
    }

    /**
     * fontSize= has to work on the server path too.
     *
     * It was added to the browser renderer first, and this one kept 19 hardcoded sizes —
     * so the same template produced different label sizes depending on whether a person
     * or a Flow generated it, and the modifier documented as working did nothing on the
     * half of generation that has no browser.
     */
    @isTest
    static void serverChartsHonourFontSize() {
        List<Map<String, Object>> buckets = new List<Map<String, Object>>{
            new Map<String, Object>{ 'key_label' => 'Sales', 'count' => 4, 'percent' => 40, 'color' => '#1e40af' },
            new Map<String, Object>{ 'key_label' => 'Engineering', 'count' => 6, 'percent' => 60, 'color' => '#b91c1c' }
        };
        Map<String, String> base = new Map<String, String>{ 'style' => 'bar', 'title' => 'Headcount' };

        Test.startTest();
        String plain = DocGenSvgChartSerializer.emit(buckets, base);
        Map<String, String> bigOpts = new Map<String, String>(base);
        bigOpts.put('fontSize', '22');
        String big = DocGenSvgChartSerializer.emit(buckets, bigOpts);
        Map<String, String> junkOpts = new Map<String, String>(base);
        junkOpts.put('fontSize', 'abc');
        String junk = DocGenSvgChartSerializer.emit(buckets, junkOpts);
        Test.stopTest();

        System.assert(plain.contains('font-size="11"'), 'the default axis label is 11: ' + sizesIn(plain));
        System.assert(plain.contains('font-size="14"'), 'and the default title is 14');

        // The whole point of scaling rather than substituting: the hierarchy survives.
        System.assert(big.contains('font-size="22"'), 'fontSize=22 sets the axis label: ' + sizesIn(big));
        System.assert(big.contains('font-size="28"'), 'and carries the title up with it, keeping the 14:11 ratio');
        System.assert(!big.contains('font-size="11"'), 'nothing is left at the old size');

        System.assertEquals(
            sizesIn(plain),
            sizesIn(junk),
            'an unparseable size falls back rather than breaking the SVG'
        );
    }

    /** The distinct font sizes in an SVG, sorted, for readable assertion messages. */
    private static String sizesIn(String svg) {
        Matcher m = Pattern.compile('font-size="(\\d+)"').matcher(svg);
        Set<String> found = new Set<String>();
        while (m.find()) {
            found.add(m.group(1));
        }
        List<String> out = new List<String>(found);
        out.sort();
        return String.join(out, ',');
    }

    /**
     * The HTML/CSS chart path must honour fontSize= as well.
     *
     * Charts render three ways — Chart.js in the browser, SVG for Word and PowerPoint,
     * and these CSS bars for HTML-to-PDF. fontSize= went into the first two and this one
     * kept its own sizes, so an HTML template produced the same chart whatever the tag
     * asked for. Two byte-identical PDFs at fontSize=10 and fontSize=26 is what showed
     * it.
     */
    @isTest
    static void htmlChartsHonourFontSize() {
        String bucketTag = '{#ChartBucket:Contacts:Department}{key}{count}{percent}{/ChartBucket}';
        Map<String, String> plain = new Map<String, String>{ 'style' => 'clustered', 'colSort' => 'A,B' };
        Map<String, String> big = new Map<String, String>{
            'style' => 'clustered',
            'colSort' => 'A,B',
            'fontSize' => '24'
        };
        Map<String, String> junk = new Map<String, String>{
            'style' => 'clustered',
            'colSort' => 'A,B',
            'fontSize' => 'abc'
        };

        Test.startTest();
        String a = DocGenChartTagExpander.renderForTest('Headcount', bucketTag, plain);
        String b = DocGenChartTagExpander.renderForTest('Headcount', bucketTag, big);
        String c = DocGenChartTagExpander.renderForTest('Headcount', bucketTag, junk);
        Test.stopTest();

        System.assertEquals('16,7,9', ptsIn(a), 'the built-in sizes');
        // Doubled, every one of them — the hierarchy has to survive an override or a
        // heading stops looking like a heading.
        System.assertEquals('14,18,32', ptsIn(b), 'fontSize=24 doubles all three: ' + ptsIn(b));
        System.assertEquals(ptsIn(a), ptsIn(c), 'an unparseable size falls back');

        // The 1px rules give a zero-height bar its line box. They are layout, not text,
        // and scaling them would push every bar out of shape. They live in the bar and
        // stacked renderers, not clustered — so check one that actually has them.
        Map<String, String> barBig = new Map<String, String>{ 'style' => 'bar', 'fontSize' => '24' };
        String bar = DocGenChartTagExpander.renderForTest('Headcount', bucketTag, barBig);
        System.assert(bar.contains('font-size:1px'), 'the bar line-box rule is left at 1px');
        System.assert(!bar.contains('font-size:2px'), 'and is not scaled with the text');
    }

    /** Distinct pt sizes in the rendered HTML, for readable assertion messages. */
    private static String ptsIn(String html) {
        Matcher m = Pattern.compile('font-size:([0-9.]+)pt').matcher(html);
        Set<String> found = new Set<String>();
        while (m.find()) {
            found.add(m.group(1));
        }
        List<String> out = new List<String>(found);
        out.sort();
        return String.join(out, ',');
    }

    /**
     * The category labels have to move with fontSize= as well.
     *
     * Measured in a rendered PDF: at fontSize=30 the value labels grew from 7.8pt to
     * 23.4pt while "Sales" and "Engineering" stayed at 10.3. Those cells carried no
     * font-size at all and were inheriting the document's, so the option moved half the
     * chart.
     *
     * The size is emitted only when the tag asks for one. Always-on would give those
     * cells a fixed base and silently restyle every existing chart in a template that
     * sets its own body font.
     */
    @isTest
    static void categoryLabelsScaleAndDefaultsAreUntouched() {
        String tag = '{#ChartBucket:Contacts:Department}{key}{count}{percent}{/ChartBucket}';
        Test.startTest();
        for (String style : new List<String>{ 'bar', 'pivot', 'stacked', 'clustered' }) {
            Map<String, String> plain = new Map<String, String>{ 'style' => style, 'colSort' => 'A,B' };
            Map<String, String> big = new Map<String, String>{
                'style' => style,
                'colSort' => 'A,B',
                'fontSize' => '24'
            };
            String a = DocGenChartTagExpander.renderForTest('T', tag, plain);
            String b = DocGenChartTagExpander.renderForTest('T', tag, big);

            System.assertNotEquals(a, b, style + ': fontSize= must change the output');
            System.assert(
                b.substringBefore('{key_label}').substringAfterLast('<').contains('font-size'),
                style + ': the category cell carries a size once fontSize= is set'
            );
            System.assertEquals(
                a,
                DocGenChartTagExpander.renderForTest('T', tag, plain),
                style + ': rendering is deterministic'
            );
        }
        Test.stopTest();
    }

    /**
     * Sizes must be valid CSS at every fontSize=, not just the convenient ones.
     *
     * Decimal.stripTrailingZeros() renders any multiple of ten in scientific notation —
     * 1E+1, 2E+1, 4E+1 — which is not a CSS length. The engine discards the declaration
     * and the element falls back to the inherited size, silently.
     *
     * It bit unevenly, which is why it survived: at fontSize=12 the 10pt cell broke, at
     * 30 the 16pt title broke, and at 24 nothing did. 24 is the value the first tests
     * happened to use.
     */
    @isTest
    static void chartSizesAreAlwaysValidCss() {
        String tag = '{#ChartBucket:Contacts:Department}{key}{count}{percent}{/ChartBucket}';
        Test.startTest();
        for (String style : new List<String>{ 'bar', 'pivot', 'stacked', 'clustered' }) {
            // 12 and 30 are the values that produced 1E+1 and 4E+1; 18 gives fractions.
            for (String req : new List<String>{ '6', '12', '18', '24', '30', '48' }) {
                String html = DocGenChartTagExpander.renderForTest(
                    'Title',
                    tag,
                    new Map<String, String>{ 'style' => style, 'colSort' => 'A,B', 'fontSize' => req }
                );
                System.assert(
                    !html.contains('E+'),
                    style +
                        ' @ fontSize=' +
                        req +
                        ' emitted scientific notation: ' +
                        html.substringAfter('E+').left(0) +
                        html
                );
                System.assert(
                    Pattern.compile('font-size:[0-9]').matcher(html).find(),
                    style + ' @ fontSize=' + req + ' emitted no usable size'
                );
            }
        }
        Test.stopTest();
    }
}
