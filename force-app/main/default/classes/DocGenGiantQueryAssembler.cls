/**
 * Queueable that progressively assembles Giant Query PDF fragments.
 * Chains to itself, each pass loading the previous accumulated HTML + next
 * batch of fragments. Final pass wraps in HTML and calls Blob.toPdf().
 * Peak heap stays under 12MB even for 10K+ rows.
 */
public with sharing class DocGenGiantQueryAssembler implements Queueable {
    private static final Integer FRAGS_PER_PASS = 50; // ~1.15MB per pass
    private static final Integer ROWS_PER_PDF_CHUNK = 2000; // Max rows per Blob.toPdf() call

    private Id jobId;
    private Id templateId;
    private Id recordId;
    private String giantRelationshipName;
    private String childObjectName;
    private String lookupFieldName;
    private String whereClauseOverride;
    private String colGroupHtml = '';
    // The authored <table …> opening tag captured from the template snapshot. Chunk-break
    // tables reproduce this verbatim so every page renders at the SAME authored width /
    // table-layout as the first table (and as the single/bulk render). Default is a generic
    // full-width tag, used only for list-based output or the no-snapshot fallback.
    private String tableOpenTag = '<table style="width:100%;border-collapse:collapse;table-layout:fixed;">';
    // The authored <thead>…</thead> captured from the snapshot, if the template marked a
    // repeat-header row ({RepeatHeader} / Word's tblHeader). Reproduced in each chunk-break
    // table so the column headers reprint at the top of every page.
    private String theadHtml = '';

    public DocGenGiantQueryAssembler(Id jobId, Id templateId, Id recordId, String giantRelationshipName) {
        this(jobId, templateId, recordId, giantRelationshipName, null, null, null);
    }

    /**
     * 7-arg constructor used by DocGenGiantQueryBatch — passes child object, lookup,
     * and WHERE clause through so resolveGiantAggregateTags works regardless of whether
     * the template uses V1 flat, V2, or V3 query config format. Without these, the
     * resolver has to reparse Query_Config__c and only V3 parses cleanly as JSON.
     */
    public DocGenGiantQueryAssembler(
        Id jobId,
        Id templateId,
        Id recordId,
        String giantRelationshipName,
        String childObjectName,
        String lookupFieldName,
        String whereClauseOverride
    ) {
        this.jobId = jobId;
        this.templateId = templateId;
        this.recordId = recordId;
        this.giantRelationshipName = giantRelationshipName;
        this.childObjectName = childObjectName;
        this.lookupFieldName = lookupFieldName;
        this.whereClauseOverride = whereClauseOverride;
    }

    public void execute(QueueableContext ctx) {
        try {
            // Load ALL fragments in one pass — no Queueable chaining needed.
            // 28K rows × ~5KB/frag = ~2.8MB, well within 12MB Queueable heap.
            // Chaining was limited to 5 depth on some orgs, causing stack overflow.
            String prefix = 'docgen_giant_' + jobId + '_';
            String finalExclude = prefix + 'final';
            String partExclude = prefix + 'part_%';

            String allRows = '';
            Set<Id> fragDocIds = new Set<Id>();

            DocGenFlsGuard.assertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{ 'Title', 'VersionData', 'ContentDocumentId' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentVersion> frags = [
                SELECT Title, VersionData, ContentDocumentId
                FROM ContentVersion
                WHERE Title LIKE :(prefix + '%') AND Title != :finalExclude AND (NOT Title LIKE :partExclude)
                WITH SYSTEM_MODE
                ORDER BY Title
                LIMIT 10000 // NOPMD — need all fragments for assembly
            ];

            for (ContentVersion cv : frags) {
                allRows += cv.VersionData.toString();
                fragDocIds.add(cv.ContentDocumentId);
            }
            frags = null;

            // Render final PDF
            renderFinalPdf(allRows, null);
            allRows = null;

            // Clean up fragments
            if (!fragDocIds.isEmpty() && Schema.sObjectType.ContentDocument.isDeletable()) {
                delete [SELECT Id FROM ContentDocument WHERE Id IN :fragDocIds]; // NOPMD ApexCRUDViolation — CRUD checked above
            }
        } catch (Exception e) {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Failed', Label__c = e.getMessage().left(255)); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
        }
    }

    /**
     * Final pass: wraps accumulated rows in a complete document and renders PDF.
     * For large datasets (>2000 rows), splits into multiple Blob.toPdf() calls
     * to avoid Flying Saucer's "Maximum stack depth" error. Each chunk renders
     * as a separate PDF part; the client merges them via docGenPdfMerger.js.
     */
    private void renderFinalPdf(String allRows, Id accumDocId) {
        // Clean up the accumulation CV
        if (accumDocId != null && Schema.sObjectType.ContentDocument.isDeletable()) {
            delete new ContentDocument(Id = accumDocId); // NOPMD ApexCRUDViolation — CRUD checked above
        }

        if (String.isBlank(allRows)) {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Failed', Label__c = 'No data to render'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
            return;
        }

        // Build the HTML wrapper (template + CSS + parent merge tags)
        String htmlTemplate = buildHtmlTemplate();

        // Insert </table><table> breaks every ROWS_PER_PDF_CHUNK rows to prevent
        // Flying Saucer's "Maximum stack depth" error on very large tables.
        // This keeps everything in ONE Blob.toPdf() call — no gap between chunks.
        //
        // We do NOT prepend a colgroup here: buildHtmlTemplate already leaves the
        // template's FIRST table carrying exactly one (authored) colgroup. Prepending
        // a second one was the half-width bug — two colgroups = 2× the column count =
        // 200% width, so the real cells packed into the left half (see #134 follow-up).
        // Each chunk-break table reproduces the authored <table …> tag + colgroup so
        // every page renders at the same authored width as the first table.
        allRows = insertTableBreaks(allRows, ROWS_PER_PDF_CHUNK, this.tableOpenTag, this.colGroupHtml, this.theadHtml);

        String html = injectRowsIntoTemplate(htmlTemplate, allRows);
        allRows = null;
        htmlTemplate = null;
        DocGenService.ensureTemplateAssetImageAccessForPdf(templateId, recordId, html);

        // DEBUG: save HTML for inspection before Blob.toPdf()
        ContentVersion debugCv = new ContentVersion(
            Title = 'docgen_giant_' + jobId + '_debug_html',
            PathOnClient = 'debug.html',
            VersionData = Blob.valueOf(html.substring(0, Math.min(100000, html.length()))),
            IsMajorVersion = false
        );
        SObjectAccessDecision dbgDec = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<ContentVersion>{ debugCv }
        );
        insert dbgDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible

        Blob pdfBlob;
        try {
            pdfBlob = Blob.toPdf(html);
        } catch (Exception pdfErr) {
            // Flying Saucer stack overflow — fall back to multi-part PDF approach
            pdfBlob = null;
            renderMultiPartPdf(html, htmlTemplate);
            html = null;
            // Failed render still linked its images — don't leave them as Files.
            DocGenService.removeTemplateImageLinksAfterRender(templateId, recordId, null);
            return;
        }
        html = null;
        // #202 follow-up — the image links exist only for the toPdf fetch above;
        // the PDF embeds the bytes, so don't leave image Files on the record.
        DocGenService.removeTemplateImageLinksAfterRender(templateId, recordId, null);

        // v1.90 — honor template Document_Title_Format__c. Pre-fix the title was
        // hardcoded to docgen_giant_<jobId>_final, which is what users saw in
        // the Files section after downloading. Fall back to the legacy name
        // only when no title format is configured on the template.
        String docTitle = DocGenService.computeDocTitle(templateId, recordId);
        String cvTitle = String.isBlank(docTitle) ? ('docgen_giant_' + jobId + '_final') : docTitle;
        ContentVersion pdfCv = new ContentVersion(
            Title = cvTitle,
            PathOnClient = cvTitle + '.pdf',
            VersionData = pdfBlob,
            IsMajorVersion = false
        );
        SObjectAccessDecision pdfDec = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<ContentVersion>{ pdfCv }
        );
        insert pdfDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
        pdfCv.Id = pdfDec.getRecords()[0].Id;

        // Link PDF to the source record
        try {
            Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :pdfCv.Id].ContentDocumentId;
            ContentDocumentLink cdl = new ContentDocumentLink(
                ContentDocumentId = docId,
                LinkedEntityId = recordId,
                ShareType = 'V'
            );
            SObjectAccessDecision cdlDec = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<ContentDocumentLink>{ cdl }
            );
            insert cdlDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
        } catch (Exception linkErr) {
            String noop = linkErr.getMessage(); // NOPMD EmptyCatchBlock — non-fatal
        }

        // v1.90 — record the final CV ID on the job. The controller's
        // getGiantQueryFragments uses this to locate the final PDF regardless
        // of its title (the legacy title-pattern lookup breaks once we honor
        // Document_Title_Format__c).
        update new DocGen_Job__c(Id = jobId, Status__c = 'Completed', Merged_PDF_CV__c = String.valueOf(pdfCv.Id)); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
    }

    /**
     * Builds the HTML template wrapper with CSS and resolved parent merge tags.
     * Returns the template with a {ROWS} placeholder for row injection.
     *
     * Two paths:
     *   - DOCX templates: read the pre-baked `docgen_tmpl_html_<versionId>` CV
     *     (built at version-save time by DocGenHtmlRenderer.convertToHtml), inject
     *     column CSS derived from <w:tblGrid>, resolve parent/aggregate tags,
     *     replace the loop <tr> with {ROWS}.
     *   - HTML templates (v1.61+): read the active version's body CV directly,
     *     resolve parent/aggregate tags, replace the loop <tr>/<li> with {ROWS},
     *     then wrap with @page margin boxes + header/footer/page counters via
     *     DocGenService.wrapHtmlForPdf.
     */
    private String buildHtmlTemplate() {
        // Route HTML-type templates to their own path — simpler, no DOCX-specific
        // column-CSS extraction or <w:tblGrid> parsing.
        // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
        // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
        // calls Schema.SObjectField.getDescribe().isAccessible() on every field
        // the SELECT lists; throws DocGenException with the offending field name
        // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
        // package-build @TestSetup FLS-propagation issue documented in
        // DocGenFlsGuard.cls.
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Type__c', 'Header_Html__c', 'Footer_Html__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> tpls = [
            SELECT Type__c, Header_Html__c, Footer_Html__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!tpls.isEmpty() && DocGenService.isHtmlBacked(tpls[0].Type__c)) {
            // v1.97 — prefer the active version's snapshotted header/footer so
            // editing the template doesn't retroactively rewrite earlier versions.
            String headerHtml = tpls[0].Header_Html__c;
            String footerHtml = tpls[0].Footer_Html__c;
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Header_Html__c', 'Footer_Html__c', 'Template__c', 'Is_Active__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> snap = [
                SELECT Header_Html__c, Footer_Html__c
                FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = TRUE
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!snap.isEmpty()) {
                if (snap[0].Header_Html__c != null) {
                    headerHtml = snap[0].Header_Html__c;
                }
                if (snap[0].Footer_Html__c != null) {
                    footerHtml = snap[0].Footer_Html__c;
                }
            }
            return buildHtmlTemplateForHtmlType(headerHtml, footerHtml);
        }

        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Template__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> vers = [
            SELECT Id
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        String html = null;
        if (!vers.isEmpty()) {
            String htmlTitle = 'docgen_tmpl_html_' + vers[0].Id;
            // Load through the template-version ContentDocumentLink in the same
            // without-sharing helper used for XML parts. A title-only ContentVersion
            // query from this with-sharing queueable can return empty for internal
            // snapshot files, which silently falls back to the bare-table renderer.
            List<ContentVersion> htmlCvs = DocGenService.loadInternalContentVersionsForVersionByTitle(
                vers[0].Id,
                htmlTitle
            );
            if (htmlCvs.isEmpty()) {
                htmlCvs = DocGenService.loadInternalContentVersionsByTitle(htmlTitle);
            }
            if (!htmlCvs.isEmpty()) {
                html = htmlCvs[0].VersionData.toString();
            }
        }

        String columnCss = '';
        // Border CSS for the self-built data rows. Default to the authored grid below;
        // the gray fallback only applies if the table props can't be parsed.
        String cellBorderCss = 'border:0.5pt solid #ccc;';
        try {
            Map<String, Object> cfg = DocGenService.extractGiantQueryFragmentConfig(templateId, giantRelationshipName);
            columnCss = cfg.get('columnCss') != null ? (String) cfg.get('columnCss') : '';
            // Parse column widths from the template's <w:tblGrid>
            String tblPropsXml = cfg.get('tablePropertiesXml') != null ? (String) cfg.get('tablePropertiesXml') : '';
            if (tblPropsXml.contains('<w:tblGrid')) {
                this.colGroupHtml = buildColGroupFromTblGrid(tblPropsXml);
            }
            if (String.isNotBlank(tblPropsXml)) {
                // Prime the style map so a named table style (e.g. TableGrid) resolves to
                // its real border here: this queueable runs in a fresh transaction, so the
                // stylesXml static the snapshot-creation pass set is gone. The cfg already
                // carries the template's styles.xml.
                String capturedStyles = cfg.get('stylesXml') != null ? (String) cfg.get('stylesXml') : '';
                if (String.isNotBlank(capturedStyles)) {
                    DocGenHtmlRenderer.stylesXml = capturedStyles;
                }
                // Style giant data rows with the AUTHORED grid border (same resolution
                // processTable gives the snapshot header), not an invented gray. ''
                // means the table has no borders → data rows get none, as authored.
                cellBorderCss = DocGenHtmlRenderer.resolveCellGridBorderCss(tblPropsXml);
            }
        } catch (Exception e) {
            String noop = e.getMessage();
        } // NOPMD EmptyCatchBlock

        if (html != null) {
            String giantTableCss =
                'table { border-collapse: collapse; border-spacing: 0; table-layout: fixed; max-width: 100%; -fs-table-paginate: paginate; } ' +
                'thead { display: table-header-group; } ' +
                // #245 — table-layout: fixed above means an unbreakable token has nowhere
                // to go; without this it spills across the cell border. Applies to every
                // cell (header, footer, data), not just td.gqc.
                'td, th { word-wrap: break-word; overflow-wrap: break-word; } td.gqc { ' +
                cellBorderCss +
                ' padding: 0pt 5.4pt; } tr { page-break-inside: avoid; } ' +
                columnCss;
            if (html.contains('</style>')) {
                // table-layout:fixed makes the authored colgroup widths authoritative;
                // max-width:100% keeps the authored absolute width from spilling past the
                // printable area (clipping the last column). The authored grid border is
                // scoped to DATA cells only (td.gqc) so it never leaks onto the running
                // header/footer cells — those keep their own authored borders (e.g. a
                // footer's top-rule-only border, not a full box). Header background + bold
                // come from the snapshot's authored inline styles.
                html = html.replace('</style>', giantTableCss + '</style>');
            } else if (html.contains('</head>')) {
                html = html.replace('</head>', '<style>' + giantTableCss + '</style></head>');
            } else {
                html = '<style>' + giantTableCss + '</style>' + html;
            }

            // Resolve parent merge tags on the template (~2KB, before row injection)
            html = resolveParentMergeTags(html);

            // Resolve grand-total aggregate tags ({SUM:Rel.Field}, {COUNT:Rel}, etc.)
            // via a single SOQL aggregate query — works for datasets of any size.
            html = resolveGiantAggregateTags(html);

            // Resolve chart-bucket section tags against the giant relationship via a
            // single SOQL GROUP BY aggregate. Each tag's body is repeated once per
            // bucket with {key}/{count}/{percent}/{max_percent}/{color}/{index}.
            html = resolveGiantChartBuckets(html);

            // Replace the loop row with a placeholder
            String openTag = '{#' + giantRelationshipName + '}';
            if (html.contains(openTag)) {
                Integer openIdx = html.indexOf(openTag);
                Integer loopTrStart = html.lastIndexOf('<tr', openIdx);
                Integer tableEnd = html.indexOf('</table>', openIdx);
                if (loopTrStart != -1 && tableEnd != -1) {
                    html = replaceGiantLoopTableTail(html, openIdx, loopTrStart, tableEnd);
                }
            } else {
                Integer bodyEnd = html.lastIndexOf('</body>');
                html =
                    html.substring(0, bodyEnd) +
                    '<table style="width:100%;border-collapse:collapse;table-layout:fixed;">' +
                    this.colGroupHtml +
                    '{ROWS}</table>' +
                    html.substring(bodyEnd);
            }
        } else {
            // Build a header row from the query config field names
            String headerRow = buildHeaderRowFromConfig();
            html =
                '<html><head><style>' +
                '@page { size: letter; margin: 0.75in; }' +
                'body { font-family: Helvetica, sans-serif; font-size: 9pt; margin: 0; }' +
                'table { width: 100%; border-collapse: collapse; border-spacing: 0; table-layout: fixed; -fs-table-paginate: paginate; }' +
                'thead { display: table-header-group; }' +
                // #245 — break unbreakable tokens rather than overflowing the cell.
                'td, th { border: 0.5pt solid #ccc; padding: 0pt 5.4pt; word-wrap: break-word; overflow-wrap: break-word; }' +
                'th { background-color: #f0f0f0; font-weight: bold; }' +
                'tr { page-break-inside: avoid; }' +
                columnCss +
                '</style></head><body><table>' +
                this.colGroupHtml +
                headerRow +
                '{ROWS}</table></body></html>';
        }
        // Capture the authored <table …> tag + colgroup now embedded in the first
        // table so chunk-break tables can reproduce them verbatim.
        captureTableShell(html);
        return html;
    }

    /**
     * Captures the opening <table …> tag and the single authored <colgroup> that
     * enclose the {ROWS} placeholder, storing them on the instance. Chunk-break
     * tables reuse these so every page renders at the SAME authored width and
     * column widths as the first table (and as the single/bulk render). No-ops
     * for list-based output (no enclosing <table>), leaving the generic defaults.
     */
    private void captureTableShell(String htmlWithPlaceholder) {
        Integer idx = htmlWithPlaceholder.indexOf('{ROWS}');
        if (idx == -1) {
            return;
        }
        Integer tblStart = htmlWithPlaceholder.lastIndexOf('<table', idx);
        if (tblStart == -1) {
            return; // list-based output or no table — keep the generic full-width default
        }
        Integer tblOpenEnd = htmlWithPlaceholder.indexOf('>', tblStart);
        if (tblOpenEnd == -1) {
            return;
        }
        this.tableOpenTag = htmlWithPlaceholder.substring(tblStart, tblOpenEnd + 1);

        // Authored colgroup, if any, sits between the table tag and {ROWS}.
        Integer cgStart = htmlWithPlaceholder.indexOf('<colgroup', tblStart);
        if (cgStart != -1 && cgStart < idx) {
            Integer cgEnd = htmlWithPlaceholder.indexOf('</colgroup>', cgStart);
            if (cgEnd != -1) {
                this.colGroupHtml = htmlWithPlaceholder.substring(cgStart, cgEnd + '</colgroup>'.length());
            }
        }

        // Authored <thead> (repeat-header rows) sits before {ROWS}. Capture it so each
        // chunk-break table reprints the header at the top of the chunk.
        Integer thStart = htmlWithPlaceholder.indexOf('<thead', tblStart);
        if (thStart != -1 && thStart < idx) {
            Integer thEnd = htmlWithPlaceholder.indexOf('</thead>', thStart);
            if (thEnd != -1) {
                this.theadHtml = htmlWithPlaceholder.substring(thStart, thEnd + '</thead>'.length());
            }
        }
    }

    /**
     * Injects row HTML into the template by replacing the {ROWS} placeholder.
     */
    private static String injectRowsIntoTemplate(String template, String rows) {
        return template.replace('{ROWS}', rows);
    }

    /**
     * Replaces the giant-query loop row and the remainder of its source table with
     * {ROWS}. Some Word templates accidentally mark the loop row itself as a
     * repeat-header row, so the DOCX-to-HTML snapshot places it inside <thead>.
     * In that shape, close the header block before injecting rows; otherwise the
     * assembler drops </thead> and Flying Saucer cannot repeat the real headers.
     */
    private static String replaceGiantLoopTableTail(
        String html,
        Integer openIdx,
        Integer loopTrStart,
        Integer tableEnd
    ) {
        Integer theadStart = html.lastIndexOf('<thead', loopTrStart);
        Integer theadEnd = html.indexOf('</thead>', openIdx);
        Boolean loopInsideThead =
            theadStart != -1 &&
            theadEnd != -1 &&
            theadStart < loopTrStart &&
            loopTrStart < theadEnd;
        String prefix = html.substring(0, loopTrStart);
        if (loopInsideThead) {
            prefix += '</thead>';
        }
        return prefix + '{ROWS}' + html.substring(tableEnd);
    }

    /**
     * HTML-type template shell builder. Reads the active version's body CV
     * (already rewritten with /sfc/ image URLs at upload time), resolves
     * parent + aggregate merge tags, inserts a {ROWS} placeholder at the
     * giant-loop boundary, and wraps with the PDF shell (page margin boxes,
     * running header/footer with page counters). Output has the same shape
     * the DOCX path emits: a full HTML doc with {ROWS} ready for row injection.
     */
    private String buildHtmlTemplateForHtmlType(String headerHtml, String footerHtml) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Content_Version_Id__c', 'Template__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> vers = [
            SELECT Id, Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (vers.isEmpty() || String.isBlank(vers[0].Content_Version_Id__c)) {
            throw new DocGenException('HTML template has no active version body.');
        }
        Id bodyCvId = (Id) vers[0].Content_Version_Id__c;
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> cvs = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :bodyCvId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cvs.isEmpty()) {
            throw new DocGenException('HTML template body ContentVersion not found.');
        }
        String rawHtml = cvs[0].VersionData.toString();

        String sourceStyles = DocGenService.extractHtmlStyleBlocks(rawHtml);
        // #245 appends the cell wrap rule here too — this is the HTML-backed giant-query
        // path, which never passes through DocGenHtmlRenderer's stylesheet.
        sourceStyles += '<style>table { border-collapse: collapse; border-spacing: 0; -fs-table-paginate: paginate; } thead { display: table-header-group; } td, th { word-wrap: break-word; overflow-wrap: break-word; }</style>';
        String bodyContent = DocGenService.extractHtmlBodyContent(rawHtml);

        // Resolve parent-level merge tags (outside the loop) and grand-total
        // aggregate tags. Both operate as regex/string replace on HTML —
        // same implementation works for HTML-type templates.
        bodyContent = resolveParentMergeTags(bodyContent);
        bodyContent = resolveGiantAggregateTags(bodyContent);
        bodyContent = resolveGiantChartBuckets(bodyContent);

        // Replace the giant-loop <tr>…</tr> (or <li>…</li>) section with a
        // {ROWS} placeholder. Same boundary logic the DOCX path uses — find
        // the nearest opening tag before {#Rel} and the next closing container.
        String openTag = '{#' + giantRelationshipName + '}';
        if (bodyContent.contains(openTag)) {
            Integer openIdx = bodyContent.indexOf(openTag);
            Integer trStart = bodyContent.lastIndexOf('<tr', openIdx);
            Integer tableEnd = bodyContent.indexOf('</table>', openIdx);
            Integer liStart = bodyContent.lastIndexOf('<li', openIdx);
            Integer listEnd = -1;
            Integer ulEnd = bodyContent.indexOf('</ul>', openIdx);
            Integer olEnd = bodyContent.indexOf('</ol>', openIdx);
            if (ulEnd != -1 && olEnd != -1) {
                listEnd = Math.min(ulEnd, olEnd);
            } else if (ulEnd != -1) {
                listEnd = ulEnd;
            } else if (olEnd != -1) {
                listEnd = olEnd;
            }

            // Prefer the innermost (closest to openTag) container
            Boolean useTable = (trStart != -1 && tableEnd != -1 && (liStart == -1 || trStart > liStart));
            Boolean useList = (liStart != -1 && listEnd != -1 && (trStart == -1 || liStart > trStart));

            if (useTable) {
                bodyContent = replaceGiantLoopTableTail(bodyContent, openIdx, trStart, tableEnd);
            } else if (useList) {
                bodyContent = bodyContent.substring(0, liStart) + '{ROWS}' + bodyContent.substring(listEnd);
            } else {
                // No recognisable container — fall back to replacing the
                // `{#Rel}…{/Rel}` section with {ROWS} directly. The loop body
                // already got rendered per-record into fragments; the shell
                // just needs a drop-in point.
                Integer closeIdx = bodyContent.indexOf('{/' + giantRelationshipName + '}');
                if (closeIdx != -1) {
                    Integer closeEnd = bodyContent.indexOf('}', closeIdx) + 1;
                    bodyContent = bodyContent.substring(0, openIdx) + '{ROWS}' + bodyContent.substring(closeEnd);
                }
            }
        } else {
            // Loop tag not present in parent-resolved body (shouldn't happen,
            // but handle gracefully by appending a table at the end).
            bodyContent += '<table style="width:100%;border-collapse:collapse;">{ROWS}</table>';
        }

        // Resolve field merge tags in the header/footer using the same parent-
        // tag resolver that runs on the body. Without this, `{Name}`, `{Owner.Name}`,
        // `{Field:format}` tags in Header_Html__c / Footer_Html__c would render
        // as literal text in the final PDF.
        String mergedHeader = String.isBlank(headerHtml)
            ? null
            : resolveParentMergeTags(DocGenService.decodeBraceEntities(headerHtml));
        String mergedFooter = String.isBlank(footerHtml)
            ? null
            : resolveParentMergeTags(DocGenService.decodeBraceEntities(footerHtml));

        // Capture the authored <table …> tag + colgroup (when the loop renders into a
        // table) so chunk-break tables reproduce the author's own width / columns.
        captureTableShell(bodyContent);

        return DocGenService.wrapHtmlForPdf(bodyContent, sourceStyles, mergedHeader, mergedFooter);
    }

    /**
     * Builds a table header row from the query config's field names.
     * Reads the child node matching giantRelationshipName and generates
     * <tr><th>...</th></tr> from its fields + parentFields.
     */
    private String buildHeaderRowFromConfig() {
        try {
            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Query_Config__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> tpls = [
                SELECT Query_Config__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (tpls.isEmpty() || String.isBlank(tpls[0].Query_Config__c)) {
                return '';
            }

            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(tpls[0].Query_Config__c.trim());
            List<Object> nodes = (List<Object>) config.get('nodes');
            if (nodes == null) {
                return '';
            }

            for (Object nodeObj : nodes) {
                Map<String, Object> node = (Map<String, Object>) nodeObj;
                String nodeAlias = (String) node.get('alias');
                String effectiveKey = String.isNotBlank(nodeAlias) ? nodeAlias : (String) node.get('relationshipName');
                if (giantRelationshipName.equals(effectiveKey)) {
                    String row = '<tr>';
                    // Parent fields first (e.g., Product2.Name → "Product Name")
                    List<Object> pFields = (List<Object>) node.get('parentFields');
                    if (pFields != null) {
                        for (Object f : pFields) {
                            row += '<th>' + formatFieldLabel(String.valueOf(f)) + '</th>';
                        }
                    }
                    // Then child fields (e.g., UnitPrice → "Unit Price")
                    List<Object> fields = (List<Object>) node.get('fields');
                    if (fields != null) {
                        for (Object f : fields) {
                            row += '<th>' + formatFieldLabel(String.valueOf(f)) + '</th>';
                        }
                    }
                    row += '</tr>';
                    return row;
                }
            }
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD — non-fatal, table works without header
        }
        return '';
    }

    /**
     * Converts an API field name to a human-readable label.
     * Product2.Name → "Product Name", UnitPrice → "Unit Price",
     * My_Custom_Field__c → "My Custom Field".
     */
    private static String formatFieldLabel(String apiName) {
        if (String.isBlank(apiName)) {
            return '';
        }
        // Take the last part after dot (Product2.Name → Name, Product2.ProductCode → ProductCode)
        if (apiName.contains('.')) {
            String parent = apiName.substringBefore('.');
            String field = apiName.substringAfter('.');
            // Clean parent name (Product2 → Product)
            parent = parent.removeEnd('2').replaceAll('__c$', '').replaceAll('__r$', '').replace('_', ' ');
            return parent + ' ' + formatFieldLabel(field);
        }
        // Remove __c suffix, split camelCase, replace underscores
        String label = apiName.removeEnd('__c').removeEnd('__r');
        // Insert space before each uppercase letter (camelCase → camel Case)
        String result = '';
        for (Integer i = 0; i < label.length(); i++) {
            String ch = label.substring(i, i + 1);
            if (i > 0 && ch == ch.toUpperCase() && ch != ch.toLowerCase() && ch != '_') {
                result += ' ';
            }
            result += ch;
        }
        return result.replace('_', ' ').trim();
    }

    /**
     * Resolves parent merge tags in the HTML template:
     *   {Name}, {Owner.Name}              — raw value
     *   {AnnualRevenue:currency}          — via DocGenService formatter
     *   {CloseDate:date:de_DE}            — via DocGenService formatter
     *
     * Aggregate tags ({SUM:...}, {COUNT:...}, etc.) are handled separately by
     * resolveGiantAggregateTags and are skipped here.
     */
    private String resolveParentMergeTags(String html) {
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Base_Object_API__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> tpls = [
                SELECT Base_Object_API__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (tpls.isEmpty()) {
                return html;
            }
            String baseObj = tpls[0].Base_Object_API__c;

            // Collect unique field paths and the full match → format map
            Set<String> fieldPaths = new Set<String>{ 'Name' };
            // fullMatch → [fieldPath, format-or-null]
            List<String> fullMatches = new List<String>();
            List<String> matchedPaths = new List<String>();
            List<String> matchedFormats = new List<String>();

            Pattern p = Pattern.compile('\\{([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)(?::([^}]+))?\\}');
            Matcher m = p.matcher(html);
            Set<String> aggFns = new Set<String>{ 'SUM', 'COUNT', 'AVG', 'MIN', 'MAX' };
            Set<String> builtins = new Set<String>{ 'TODAY', 'NOW' };
            while (m.find()) {
                String path = m.group(1);
                // Skip aggregate tags — handled by resolveGiantAggregateTags
                if (aggFns.contains(path.toUpperCase())) {
                    continue;
                }
                fullMatches.add(m.group(0));
                matchedPaths.add(path);
                matchedFormats.add(m.group(2));
                // Built-ins and {RunningUser.X} bypass schema validation; resolved separately.
                String upper = path.toUpperCase();
                if (!builtins.contains(upper) && !upper.startsWith('RUNNINGUSER.')) {
                    fieldPaths.add(path);
                }
                // {Field:currency:auto[=SourceField]} needs the currency source field
                // queried too so it lands in the per-tag miniMap below. Schema validation
                // drops it if absent (e.g. CurrencyIsoCode in a single-currency org).
                String csf = currencyAutoSourceField(m.group(2));
                if (csf != null) {
                    fieldPaths.add(csf);
                }
                // #297 — {Field:currency:X:convert} on a plain field converts from the
                // record's own CurrencyIsoCode, so it must be queried and seeded into
                // the miniMap the same way (schema validation drops it single-currency).
                if (String.isNotBlank(m.group(2)) && DocGenCurrency.wantsConversion(m.group(2))) {
                    fieldPaths.add('CurrencyIsoCode');
                }
            }

            // Validate field paths against schema
            List<String> validFields = new List<String>();
            Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe()
                .get(baseObj)
                ?.getDescribe()
                ?.fields
                ?.getMap();
            if (fieldMap != null) {
                for (String fn : fieldPaths) {
                    if (fn.contains('.')) {
                        String relName = fn.substringBefore('.');
                        Boolean relFound = false;
                        for (Schema.SObjectField sof : fieldMap.values()) {
                            if (
                                sof.getDescribe().getRelationshipName() != null &&
                                sof.getDescribe().getRelationshipName().equalsIgnoreCase(relName)
                            ) {
                                relFound = true;
                                break;
                            }
                        }
                        if (relFound) {
                            validFields.add(fn);
                        }
                    } else if (fieldMap.containsKey(fn.toLowerCase())) {
                        validFields.add(fn);
                    }
                }
            }
            if (validFields.isEmpty()) {
                return html;
            }

            String soql =
                'SELECT ' +
                String.join(validFields, ', ') +
                ' FROM ' +
                String.escapeSingleQuotes(baseObj) +
                ' WHERE Id = :recordId LIMIT 1';
            List<SObject> recs = Database.query(soql, AccessLevel.USER_MODE);
            if (recs.isEmpty()) {
                return html;
            }
            SObject rec = recs[0];

            // Resolve + format each matched tag. For format-suffix tags we build a
            // 1-field data map and hand the tag to DocGenService.processXmlForTest
            // so currency/number/date formatters stay centralized.
            Set<String> validFieldSet = new Set<String>(validFields);
            for (Integer i = 0; i < fullMatches.size(); i++) {
                String path = matchedPaths.get(i);
                String upperPath = path.toUpperCase();
                String fmt = matchedFormats.get(i);

                Object val = null;
                if (upperPath == 'TODAY') {
                    Date td = Date.today();
                    val = DateTime.newInstance(td.year(), td.month(), td.day());
                } else if (upperPath == 'NOW') {
                    val = DateTime.now();
                } else if (upperPath.startsWith('RUNNINGUSER.')) {
                    // Delegate to DocGenService.processXml — it intercepts {RunningUser.X}
                    // against the cached running-user context. Empty data map is fine —
                    // the RunningUser branch doesn't read from it.
                    String tag = String.isBlank(fmt) ? '{' + path + '}' : '{' + path + ':' + fmt + '}';
                    String resolved;
                    try {
                        resolved = DocGenService.processXmlForTest(tag, new Map<String, Object>());
                    } catch (Exception ruErr) {
                        resolved = '';
                    }
                    html = html.replace(fullMatches.get(i), resolved);
                    continue;
                } else {
                    if (!validFieldSet.contains(path)) {
                        continue;
                    }
                    try {
                        if (path.contains('.')) {
                            List<String> parts = path.split('\\.');
                            SObject cur = rec;
                            for (Integer j = 0; j < parts.size() - 1 && cur != null; j++) {
                                cur = cur.getSObject(parts[j]);
                            }
                            if (cur != null) {
                                val = cur.get(parts[parts.size() - 1]);
                            }
                        } else {
                            val = rec.get(path);
                        }
                    } catch (Exception fieldErr) {
                        String noop = fieldErr.getMessage();
                    } // NOPMD
                }

                String replacement;
                if (val == null) {
                    replacement = '';
                } else if (!String.isBlank(fmt) && fmt.toLowerCase().trim() == 'label') {
                    replacement = resolvePicklistLabel(rec, path, val);
                } else if (String.isBlank(fmt)) {
                    replacement = String.valueOf(val);
                } else {
                    // Build a nested 1-field data map shaped like the path
                    Map<String, Object> miniMap = new Map<String, Object>();
                    if (path.contains('.')) {
                        List<String> parts = path.split('\\.');
                        Map<String, Object> cur = miniMap;
                        for (Integer j = 0; j < parts.size() - 1; j++) {
                            Map<String, Object> next = new Map<String, Object>();
                            cur.put(parts[j], next);
                            cur = next;
                        }
                        cur.put(parts[parts.size() - 1], val);
                    } else {
                        miniMap.put(path, val);
                    }
                    // Seed the currency source field so {…:currency:auto[=Field]} resolves
                    // the ISO from the record (mirrors the row-level data map).
                    String csf = currencyAutoSourceField(fmt);
                    if (csf != null && validFieldSet.contains(csf)) {
                        miniMap.put(csf, rec.get(csf));
                    }
                    // #297 — seed the record's own currency for {…:currency:X:convert}
                    if (
                        String.isNotBlank(fmt) &&
                        DocGenCurrency.wantsConversion(fmt) &&
                        validFieldSet.contains('CurrencyIsoCode')
                    ) {
                        miniMap.put('CurrencyIsoCode', rec.get('CurrencyIsoCode'));
                    }
                    try {
                        replacement = DocGenService.processXmlForTest('{' + path + ':' + fmt + '}', miniMap);
                    } catch (Exception procErr) {
                        replacement = String.valueOf(val);
                    }
                }
                html = html.replace(fullMatches.get(i), replacement);
            }
        } catch (Exception mergeErr) {
            String noop = mergeErr.getMessage(); // NOPMD
        }
        // Resolve {%Image:N} / {%Image:N:SIZE} tags in the parent HTML (headers/footers/summaries)
        html = resolveParentImageTags(html);
        // Resolve {%asset:<key>} / {%asset:<key>:SIZE} shared-asset tags in the parent HTML.
        html = resolveParentAssetTags(html);
        return html;
    }

    private static String resolvePicklistLabel(SObject record, String path, Object value) {
        String fallback = value == null ? '' : String.valueOf(value);
        if (record == null || String.isBlank(path) || value == null) {
            return fallback;
        }
        SObject owner = record;
        String fieldName = path;
        if (path.contains('.')) {
            List<String> parts = path.split('\\.');
            for (Integer i = 0; i < parts.size() - 1 && owner != null; i++) {
                try {
                    owner = owner.getSObject(parts[i]);
                } catch (Exception e) {
                    return fallback;
                }
            }
            fieldName = parts[parts.size() - 1];
        }
        if (owner == null) {
            return fallback;
        }
        Map<String, Schema.SObjectField> fields = owner.getSObjectType().getDescribe().fields.getMap();
        Schema.SObjectField fieldToken = fields.get(fieldName.toLowerCase());
        if (fieldToken == null) {
            return fallback;
        }
        Schema.DescribeFieldResult dfr = fieldToken.getDescribe();
        Schema.DisplayType fieldType = dfr.getType();
        if (fieldType != Schema.DisplayType.PICKLIST && fieldType != Schema.DisplayType.MULTIPICKLIST) {
            return fallback;
        }
        Map<String, String> labelsByValue = new Map<String, String>();
        for (Schema.PicklistEntry entry : dfr.getPicklistValues()) {
            labelsByValue.put(entry.getValue(), entry.getLabel());
        }
        String rawValue = String.valueOf(value);
        if (fieldType == Schema.DisplayType.MULTIPICKLIST) {
            List<String> labels = new List<String>();
            for (String part : rawValue.split(';')) {
                String trimmed = part.trim();
                labels.add(labelsByValue.containsKey(trimmed) ? labelsByValue.get(trimmed) : trimmed);
            }
            return String.join(labels, '; ');
        }
        return labelsByValue.containsKey(rawValue) ? labelsByValue.get(rawValue) : rawValue;
    }

    /**
     * Resolves {%Image:N} and {%Image:N:SIZE} tags at the parent level of a giant-query
     * template — headers, footers, grand-summary rows. Each tag expands to an HTML
     * <img src="/sfc/servlet.shepherd/version/download/<cvId>"> element referencing
     * the Nth oldest image attached to this.recordId. Unlike row-level images, this
     * emits HTML directly (the giant-query path builds HTML, not DOCX XML).
     *
     * Size grammar matches {%Image:N} elsewhere:
     *   "200"     → max dimension, preserves aspect  (style="max-width:200px;max-height:200px")
     *   "200x200" → explicit width × height
     *   "200x"    → width only (auto height)
     *   "x200"    → height only (auto width)
     */
    @TestVisible
    private String resolveParentImageTags(String html) {
        if (String.isBlank(html) || !html.containsIgnoreCase('{%image:'))
            return html;

        Pattern p = Pattern.compile('\\{%[Ii]mage:(\\d+)(?::([^}]+))?\\}');
        Matcher m = p.matcher(html);

        List<String> cachedCvIds = null; // lazy — only query CDL if at least one tag is found
        String result = '';
        Integer last = 0;
        while (m.find()) {
            Integer n = Integer.valueOf(m.group(1));
            String sizeToken = m.group(2);

            if (cachedCvIds == null) {
                cachedCvIds = new List<String>();
                Set<String> imageExts = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff', 'svg' };
                /* code-analyzer-suppress ApexFlsViolation */
                for (ContentDocumentLink cdl : [
                    SELECT ContentDocument.LatestPublishedVersionId
                    FROM ContentDocumentLink
                    WHERE LinkedEntityId = :recordId AND ContentDocument.FileExtension IN :imageExts
                    WITH USER_MODE
                    ORDER BY ContentDocument.CreatedDate ASC, ContentDocument.Id ASC
                    LIMIT 50
                ]) {
                    cachedCvIds.add(String.valueOf(cdl.ContentDocument.LatestPublishedVersionId));
                }
            }

            String replacement = '';
            if (n >= 1 && cachedCvIds.size() >= n) {
                replacement = buildParentImageHtml(cachedCvIds[n - 1], sizeToken);
            }
            result += html.substring(last, m.start()) + replacement;
            last = m.end();
        }
        result += html.substring(last);
        return result;
    }

    /**
     * Builds an HTML <img> element for a ContentVersion ID with optional size token.
     * Salesforce's Blob.toPdf() (Flying Saucer) resolves the relative /sfc/ URL natively.
     */
    private String buildParentImageHtml(String cvId, String sizeToken) {
        String url = '/sfc/servlet.shepherd/version/download/' + cvId;
        Integer widthPx = null;
        Integer heightPx = null;
        Integer maxPx = null;
        if (String.isNotBlank(sizeToken)) {
            String t = sizeToken.trim().toLowerCase();
            if (!t.contains('x')) {
                if (t.isNumeric()) {
                    maxPx = Integer.valueOf(t);
                }
            } else {
                Integer xIdx = t.indexOf('x');
                String w = t.substring(0, xIdx).trim();
                String h = t.substring(xIdx + 1).trim();
                if (String.isNotBlank(w) && w.isNumeric()) {
                    widthPx = Integer.valueOf(w);
                }
                if (String.isNotBlank(h) && h.isNumeric()) {
                    heightPx = Integer.valueOf(h);
                }
            }
        }
        // Shared HTML image builder applies the size-keyed cache-bust so Flying
        // Saucer honors each requested size (see DocGenService.buildHtmlImageMarkup).
        return DocGenService.buildHtmlImageMarkup(url, widthPx, heightPx, maxPx, null);
    }

    /**
     * Resolves {%asset:<key>} and {%asset:<key>:SIZE} shared-asset tags at the
     * parent level of a giant-query template (headers, footers, grand summaries).
     * Each tag resolves its key to the asset's latest ContentVersion Id via the
     * single source of truth — DocGenService.resolveAssetCvIds (active-only,
     * per-transaction cached) — then emits an <img src="/sfc/...">  using the SAME
     * buildParentImageHtml grammar as {%Image:N}, so sizing behaves identically.
     *
     * Missing/inactive assets degrade gracefully: a clear inline placeholder, never
     * a hard failure (consistent with the row-level resolver in DocGenService).
     */
    @TestVisible
    private String resolveParentAssetTags(String html) {
        if (String.isBlank(html) || !html.containsIgnoreCase('{%asset:'))
            return html;

        Pattern p = Pattern.compile('\\{%[Aa]sset:([^:}]+)(?::([^}]+))?\\}');
        Matcher m = p.matcher(html);

        // First pass: collect every referenced key so the resolver does one SOQL.
        // Keys are stored lowercase, so lowercase the tag key to match.
        Set<String> keys = new Set<String>();
        while (m.find()) {
            String key = m.group(1) == null ? '' : m.group(1).trim().toLowerCase();
            if (String.isNotBlank(key)) {
                keys.add(key);
            }
        }
        if (keys.isEmpty()) {
            return html;
        }
        Map<String, String> cvByKey = DocGenService.resolveAssetCvIds(keys);

        // Second pass: substitute.
        m.reset();
        String result = '';
        Integer last = 0;
        while (m.find()) {
            String key = m.group(1) == null ? '' : m.group(1).trim().toLowerCase();
            String sizeToken = m.group(2);
            String cvId = cvByKey.get(key);
            String replacement;
            if (String.isNotBlank(cvId)) {
                replacement = buildParentImageHtml(cvId, sizeToken);
            } else {
                replacement = '[missing asset: ' + key.escapeHtml4() + ']';
            }
            result += html.substring(last, m.start()) + replacement;
            last = m.end();
        }
        result += html.substring(last);
        return result;
    }

    /**
     * Resolves grand-total aggregate tags that reference the giant relationship:
     *   {SUM:Rel.Field}, {COUNT:Rel}, {AVG:Rel.Field}, {MIN:Rel.Field}, {MAX:Rel.Field}
     * with optional numeric format: {SUM:Rel.Field:currency}.
     *
     * One SOQL aggregate query covers all referenced fn/field pairs. Honors the
     * same lookup + WHERE clause used for the row pages, so totals match the rows.
     * Unlike in-memory aggregates this is accurate for arbitrarily large datasets
     * (60K+ rows) because the DB does the math.
     */
    @TestVisible
    private String resolveGiantAggregateTags(String html) {
        if (String.isBlank(html) || String.isBlank(giantRelationshipName)) {
            return html;
        }

        Pattern p = Pattern.compile(
            '\\{(SUM|COUNT|AVG|MIN|MAX):([A-Za-z0-9_]+)(?:\\.([A-Za-z0-9_]+))?(?::([^}]+))?\\}'
        );
        Matcher m = p.matcher(html);

        List<String> fullMatches = new List<String>();
        List<String> fns = new List<String>();
        List<String> fields = new List<String>();
        List<String> fmts = new List<String>();
        Set<String> neededPairs = new Set<String>();

        while (m.find()) {
            String rel = m.group(2);
            if (!giantRelationshipName.equalsIgnoreCase(rel)) {
                continue;
            }
            String fn = m.group(1).toUpperCase();
            String field = m.group(3);
            fullMatches.add(m.group(0));
            fns.add(fn);
            fields.add(field == null ? '' : field);
            fmts.add(m.group(4));
            neededPairs.add(fn + '|' + (field == null ? '' : field));
        }
        if (fullMatches.isEmpty()) {
            return html;
        }

        // Prefer the child/lookup/where passed in via constructor (the batch has them
        // regardless of config format). Only fall back to parsing Query_Config__c if
        // the constructor values are absent — and that path only works for V3 JSON.
        String childObj = this.childObjectName;
        String lookupFld = this.lookupFieldName;
        String whereCls = this.whereClauseOverride;

        if (String.isBlank(childObj) || String.isBlank(lookupFld)) {
            try {
                DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Query_Config__c' });
                /* code-analyzer-suppress ApexFlsViolation */
                List<DocGen_Template__c> tpls = [
                    SELECT Query_Config__c
                    FROM DocGen_Template__c
                    WHERE Id = :templateId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (tpls.isEmpty() || String.isBlank(tpls[0].Query_Config__c)) {
                    return html;
                }
                String cfgStr = tpls[0].Query_Config__c.trim();
                if (!cfgStr.startsWith('{')) {
                    return html;
                } // V1 flat — caller must pass child/lookup explicitly
                Map<String, Object> cfg = (Map<String, Object>) JSON.deserializeUntyped(cfgStr);
                List<Object> nodes = (List<Object>) cfg.get('nodes');
                if (nodes == null) {
                    return html;
                }
                for (Object nodeObj : nodes) {
                    Map<String, Object> node = (Map<String, Object>) nodeObj;
                    String nodeAlias = (String) node.get('alias');
                    String effectiveKey = String.isNotBlank(nodeAlias)
                        ? nodeAlias
                        : (String) node.get('relationshipName');
                    if (giantRelationshipName.equalsIgnoreCase(effectiveKey)) {
                        childObj = (String) node.get('object');
                        lookupFld = (String) node.get('lookupField');
                        whereCls = (String) node.get('where');
                        if (whereCls == null) {
                            whereCls = (String) node.get('whereClause');
                        }
                        // Sanitize the whereCls pulled directly from V3 config — the
                        // batch path passes an already-sanitized value via constructor,
                        // but this fallback (4-arg constructor) reads it raw. Reuse the
                        // canonical sanitizer to block injection (DML keywords, ;, --, /*).
                        if (String.isNotBlank(whereCls)) {
                            whereCls = DocGenDataRetriever.sanitizeWhereClause(whereCls);
                        }
                        break;
                    }
                }
            } catch (DocGenException dge) {
                // Sanitizer rejected the where clause — abort aggregate resolution
                // and leave tags unresolved rather than running the unsafe SOQL.
                return html;
            } catch (Exception e) {
                String noop = e.getMessage(); // NOPMD — aggregate resolution is non-fatal
                return html;
            }
        }

        if (String.isBlank(childObj) || String.isBlank(lookupFld)) {
            return html;
        }
        Schema.SObjectType childType = Schema.getGlobalDescribe().get(childObj);
        if (childType == null) {
            return html;
        }
        // Validate aggregate fields against the child object's schema — this allows
        // aggregating any queryable field, not just columns declared for rendering.
        // Regex already restricts field names to [A-Za-z0-9_]+ so SOQL injection is
        // blocked; Schema existence check is the second line of defense.
        Map<String, Schema.SObjectField> childFieldMap = childType.getDescribe().fields.getMap();
        // Allowlist-validate lookupFld against the child schema. The batch sanitizes
        // its own incoming clauses, but lookupFld is only escapeSingleQuotes'd — that
        // doesn't protect against identifier-level injection (no quotes needed). Reject
        // anything that isn't a real field on the child object.
        if (!childFieldMap.containsKey(lookupFld.toLowerCase())) {
            return html;
        }

        // Build aggregate SELECT clauses — each unique (fn, field) pair gets one alias
        List<String> selectClauses = new List<String>();
        Map<String, String> pairToAlias = new Map<String, String>();
        Integer aliasIdx = 0;
        for (String pair : neededPairs) {
            List<String> parts = pair.split('\\|', 2);
            String fn = parts[0];
            String field = parts.size() > 1 ? parts[1] : '';
            String alias = 'agg' + aliasIdx++;
            if (fn == 'COUNT' && String.isBlank(field)) {
                selectClauses.add('COUNT(Id) ' + alias);
                pairToAlias.put(pair, alias);
            } else if (String.isNotBlank(field) && childFieldMap.containsKey(field.toLowerCase())) {
                selectClauses.add(fn + '(' + field + ') ' + alias);
                pairToAlias.put(pair, alias);
            }
        }
        if (selectClauses.isEmpty()) {
            return html;
        }

        String soql =
            'SELECT ' +
            String.join(selectClauses, ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(childObj) +
            ' WHERE ' +
            String.escapeSingleQuotes(lookupFld) +
            ' = :recordId';
        if (String.isNotBlank(whereCls)) {
            soql += ' AND ' + whereCls;
        }

        AggregateResult agg;
        try {
            List<AggregateResult> results = Database.query(soql, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — child object + fields validated against Schema + declared template fields; lookup and where re-use the same sanitized clauses as row queries
            if (results.isEmpty()) {
                return html;
            }
            agg = results[0];
        } catch (Exception qErr) {
            String noop = qErr.getMessage(); // NOPMD — fall through, tags stay unresolved
            return html;
        }

        // Currency-formatted tags are resolved separately, grouped by CurrencyIsoCode, so a
        // mixed-currency dataset either converts or fails loudly instead of silently adding
        // across currencies. Computed OUTSIDE the per-tag try/catch below — a mixed-currency
        // error must reach the job record, not degrade into the unconverted raw number.
        Map<String, String> currencyReplacements = resolveCurrencyGroupedAggregates(
            fullMatches,
            fns,
            fields,
            fmts,
            childObj,
            lookupFld,
            whereCls,
            childFieldMap
        );

        // Replace each tag occurrence
        Map<String, String> isoCache = new Map<String, String>();
        for (Integer i = 0; i < fullMatches.size(); i++) {
            if (currencyReplacements.containsKey(fullMatches[i])) {
                html = html.replace(fullMatches[i], currencyReplacements.get(fullMatches[i]));
                continue;
            }
            String pair = fns[i] + '|' + fields[i];
            String alias = pairToAlias.get(pair);
            if (alias == null) {
                continue;
            }
            Object raw = agg.get(alias);
            String replacement;
            if (raw == null) {
                replacement = '0';
            } else if (fmts[i] != null) {
                try {
                    // {…:currency:auto[=Field]} — resolve the ISO from the parent record once,
                    // since the parent's field map isn't loaded on the giant-aggregate path.
                    String autoIso = resolveAutoIsoForFormat(fmts[i], isoCache);
                    replacement = DocGenService.formatAggregateValue(
                        Decimal.valueOf(String.valueOf(raw)),
                        fmts[i],
                        autoIso
                    );
                } catch (Exception fmtErr) {
                    replacement = String.valueOf(raw);
                }
            } else {
                replacement = String.valueOf(raw);
            }
            html = html.replace(fullMatches[i], replacement);
        }
        return html;
    }

    /**
     * Resolves currency-formatted grand-total tags with a single `GROUP BY CurrencyIsoCode`
     * aggregate, so datasets spanning multiple currencies are handled explicitly rather than
     * being added together as if they were one.
     *
     * Selecting SUM / MIN / MAX / COUNT per currency group makes every aggregate function
     * exactly derivable after conversion — notably AVG, which is Σ(converted sums) ÷ Σ(counts)
     * rather than an average of per-group averages.
     *
     * Returns an empty map (leaving the caller's ungrouped path in charge) in single-currency
     * orgs, when the child object has no CurrencyIsoCode, or when no tag is currency-formatted.
     * Throws when the data spans currencies and the tag didn't opt into `:convert`.
     */
    private Map<String, String> resolveCurrencyGroupedAggregates(
        List<String> fullMatches,
        List<String> fns,
        List<String> fields,
        List<String> fmts,
        String childObj,
        String lookupFld,
        String whereCls,
        Map<String, Schema.SObjectField> childFieldMap
    ) {
        Map<String, String> out = new Map<String, String>();
        if (!DocGenCurrency.isMultiCurrency() || !childFieldMap.containsKey('currencyisocode')) {
            return out;
        }

        // One alias set per distinct field referenced by a currency-formatted tag.
        Map<String, Integer> fieldSlot = new Map<String, Integer>();
        for (Integer i = 0; i < fullMatches.size(); i++) {
            if (!DocGenCurrency.isCurrencyFormat(fmts[i]) || String.isBlank(fields[i])) {
                continue;
            }
            String key = fields[i].toLowerCase();
            if (childFieldMap.containsKey(key) && !fieldSlot.containsKey(key)) {
                fieldSlot.put(key, fieldSlot.size());
            }
        }
        if (fieldSlot.isEmpty()) {
            return out;
        }

        List<String> selectClauses = new List<String>{ 'CurrencyIsoCode iso' };
        for (String fieldKey : fieldSlot.keySet()) {
            Integer slot = fieldSlot.get(fieldKey);
            String fieldName = childFieldMap.get(fieldKey).getDescribe().getName();
            selectClauses.add('SUM(' + fieldName + ') s' + slot);
            selectClauses.add('MIN(' + fieldName + ') mn' + slot);
            selectClauses.add('MAX(' + fieldName + ') mx' + slot);
            selectClauses.add('COUNT(' + fieldName + ') c' + slot);
        }

        String soql =
            'SELECT ' +
            String.join(selectClauses, ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(childObj) +
            ' WHERE ' +
            String.escapeSingleQuotes(lookupFld) +
            ' = :recordId';
        if (String.isNotBlank(whereCls)) {
            soql += ' AND ' + whereCls;
        }
        soql += ' GROUP BY CurrencyIsoCode';

        List<AggregateResult> groups;
        try {
            groups = Database.query(soql, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — field names resolved through the child Schema describe; lookup and where reuse the same sanitized clauses as row queries
        } catch (Exception qErr) {
            // Grouped read failed — leave these tags to the caller's ungrouped path rather
            // than blocking the render. Same non-fatal posture as the surrounding method.
            String noop = qErr.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock
            return out;
        }
        if (groups.isEmpty()) {
            return out;
        }

        Set<String> distinctIsos = new Set<String>();
        for (AggregateResult g : groups) {
            Object iso = g.get('iso');
            if (iso != null && String.isNotBlank(String.valueOf(iso))) {
                distinctIsos.add(String.valueOf(iso).toUpperCase());
            }
        }

        Map<String, String> isoCache = new Map<String, String>();
        for (Integer i = 0; i < fullMatches.size(); i++) {
            if (!DocGenCurrency.isCurrencyFormat(fmts[i]) || String.isBlank(fields[i])) {
                continue;
            }
            Integer slot = fieldSlot.get(fields[i].toLowerCase());
            if (slot == null) {
                continue;
            }

            if (distinctIsos.size() > 1 && !DocGenCurrency.wantsConversion(fmts[i])) {
                // Strips the trailing format from the quoted tag so the suggested fix reads
                // back as a valid tag the author can paste.
                DocGenCurrency.assertSingleCurrency(
                    distinctIsos,
                    fns[i] + ':' + giantRelationshipName + '.' + fields[i] + ':' + fmts[i]
                );
            }

            String targetIso = DocGenCurrency.explicitTargetIso(fmts[i]);
            if (String.isBlank(targetIso)) {
                targetIso = resolveAutoIsoForFormat(fmts[i], isoCache);
            }
            // Single-currency dataset needs no conversion — the one code IS the total's code.
            if (String.isBlank(targetIso) && distinctIsos.size() == 1) {
                targetIso = new List<String>(distinctIsos)[0];
            }

            Decimal combined = combineCurrencyGroups(groups, fns[i], slot, targetIso);
            if (combined == null) {
                continue;
            }
            out.put(
                fullMatches[i],
                DocGenService.formatAggregateValue(combined, DocGenCurrency.stripConvertSegment(fmts[i]), targetIso)
            );
        }
        return out;
    }

    /**
     * Folds per-currency aggregate groups into one number in `targetIso`.
     *
     * SUM/AVG combine converted totals; MIN/MAX compare converted extremes (a smaller raw
     * number in a stronger currency can still be the larger amount); COUNT is currency-blind.
     */
    private Decimal combineCurrencyGroups(List<AggregateResult> groups, String fn, Integer slot, String targetIso) {
        Decimal totalSum = 0;
        Decimal totalCount = 0;
        Decimal lowest;
        Decimal highest;

        for (AggregateResult g : groups) {
            Object isoRaw = g.get('iso');
            String groupIso = isoRaw == null ? null : String.valueOf(isoRaw);
            Object sumRaw = g.get('s' + slot);
            Object minRaw = g.get('mn' + slot);
            Object maxRaw = g.get('mx' + slot);
            Object cntRaw = g.get('c' + slot);

            if (cntRaw != null) {
                totalCount += Decimal.valueOf(String.valueOf(cntRaw));
            }
            if (sumRaw != null) {
                totalSum += DocGenCurrency.convert(Decimal.valueOf(String.valueOf(sumRaw)), groupIso, targetIso);
            }
            if (minRaw != null) {
                Decimal v = DocGenCurrency.convert(Decimal.valueOf(String.valueOf(minRaw)), groupIso, targetIso);
                if (lowest == null || v < lowest) {
                    lowest = v;
                }
            }
            if (maxRaw != null) {
                Decimal v = DocGenCurrency.convert(Decimal.valueOf(String.valueOf(maxRaw)), groupIso, targetIso);
                if (highest == null || v > highest) {
                    highest = v;
                }
            }
        }

        if (fn == 'SUM') {
            return totalSum;
        }
        if (fn == 'COUNT') {
            return totalCount;
        }
        if (fn == 'MIN') {
            return lowest;
        }
        if (fn == 'MAX') {
            return highest;
        }
        if (fn == 'AVG') {
            // Weighted across groups — an average of per-group averages would be wrong
            // whenever the groups differ in size.
            return totalCount == 0 ? 0 : totalSum.divide(totalCount, 2, RoundingMode.HALF_UP);
        }
        return null;
    }

    /**
     * If `fmt` is a {…:currency:auto[=Field]} specifier, returns the ISO 4217 code read
     * from the parent record's source field (default `CurrencyIsoCode`), else null.
     * Results are cached per source field to avoid repeated single-row queries. Null on
     * any miss (single-currency org, missing/blank field) so the formatter falls back to $.
     */
    private String resolveAutoIsoForFormat(String fmt, Map<String, String> isoCache) {
        String sourceField = currencyAutoSourceField(fmt);
        if (sourceField == null) {
            return null;
        }
        String cacheKey = sourceField.toLowerCase();
        if (isoCache.containsKey(cacheKey)) {
            return isoCache.get(cacheKey);
        }

        String iso = null;
        // CurrencyIsoCode only exists in multi-currency orgs; a custom currency field can
        // exist in either, so don't gate custom fields on isMultiCurrencyOrganization().
        Boolean isStandardIso = sourceField.equalsIgnoreCase('CurrencyIsoCode');
        if (!isStandardIso || UserInfo.isMultiCurrencyOrganization()) {
            try {
                Schema.SObjectType parentType = recordId.getSObjectType();
                Map<String, Schema.SObjectField> pf = parentType.getDescribe().fields.getMap();
                if (pf.containsKey(cacheKey)) {
                    String q =
                        'SELECT ' +
                        sourceField +
                        ' FROM ' +
                        String.escapeSingleQuotes(String.valueOf(parentType)) +
                        ' WHERE Id = :recordId LIMIT 1';
                    List<SObject> rows = Database.query(q, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — source field validated against parent Schema field map; object name from describe; parameterized Id
                    if (!rows.isEmpty()) {
                        Object v = rows[0].get(sourceField);
                        String s = v == null ? null : String.valueOf(v).trim();
                        iso = String.isBlank(s) ? null : s.toUpperCase();
                    }
                }
            } catch (Exception e) {
                String noop = e.getMessage(); // NOPMD — non-fatal, fall back to $ formatting
            }
        }
        isoCache.put(cacheKey, iso);
        return iso;
    }

    /**
     * Returns the currency source field for a {…:currency:auto[=Field]} format string
     * (defaulting to the standard `CurrencyIsoCode`), or null when `fmt` isn't a
     * currency:auto specifier.
     */
    private static String currencyAutoSourceField(String fmt) {
        if (String.isBlank(fmt)) {
            return null;
        }
        List<String> segs = fmt.split(':');
        if (segs.size() < 2 || !segs[0].trim().equalsIgnoreCase('currency')) {
            return null;
        }
        String spec = segs[1].trim();
        String lower = spec.toLowerCase();
        if (lower != 'auto' && !lower.startsWith('auto=')) {
            return null;
        }
        String src = lower == 'auto' ? 'CurrencyIsoCode' : spec.substring(spec.indexOf('=') + 1).trim();
        return String.isBlank(src) ? 'CurrencyIsoCode' : src;
    }

    /**
     * Resolves `{#ChartBucket:rel:field}body{/ChartBucket}` tags whose `rel`
     * matches `giantRelationshipName`, using a single SOQL GROUP BY aggregate
     * so it works for arbitrarily large datasets. Each chart tag is replaced
     * in-place with the per-bucket-expanded body.
     *
     * Charts targeting non-giant relationships in a giant-query template are
     * left untouched (documented v1 limitation): use the inline render path
     * for those, or pre-aggregate via a formula/rollup field.
     *
     * Container caveat: unlike the inline path's auto-expansion at
     * DocGenService.processXml line 2708, the giant-query path does NOT pick
     * up a wrapping `<tr>` around the chart tag. Authors must wrap each
     * bucket's row inside the chart body (e.g., `{#ChartBucket:...}<tr>...
     * </tr>{/ChartBucket}`).
     */
    @TestVisible
    private String resolveGiantChartBuckets(String html) {
        if (String.isBlank(html) || String.isBlank(giantRelationshipName)) {
            return html;
        }
        if (!html.contains('{#ChartBucket:')) {
            return html;
        }

        // Locate every chart tag opener. Field/rel patterns mirror the strict
        // identifier shape used by resolveGiantAggregateTags so SOQL injection
        // can't get a foothold via the tag itself. Group 3 (optional) captures
        // the modifier string after the 3rd colon — `colors=#aaa,#bbb` etc.
        Pattern openerP = Pattern.compile(
            '\\{#ChartBucket:([A-Za-z_][A-Za-z0-9_]*):([A-Za-z_][A-Za-z0-9_]*)(?::([^}]+))?\\}'
        );
        Matcher openerM = openerP.matcher(html);

        List<Integer> openerStarts = new List<Integer>();
        List<Integer> openerEnds = new List<Integer>();
        List<String> relNames = new List<String>();
        List<String> groupFields = new List<String>();
        List<String> tagModifiers = new List<String>();
        while (openerM.find()) {
            openerStarts.add(openerM.start());
            openerEnds.add(openerM.end());
            relNames.add(openerM.group(1));
            groupFields.add(openerM.group(2));
            tagModifiers.add(openerM.group(3)); // null when no 3rd segment
        }
        if (openerStarts.isEmpty()) {
            return html;
        }

        // Resolve child/lookup/where — prefer constructor values, fall back to
        // V3 JSON Query_Config__c parse. Mirrors resolveGiantAggregateTags.
        String childObj = this.childObjectName;
        String lookupFld = this.lookupFieldName;
        String whereCls = this.whereClauseOverride;

        if (String.isBlank(childObj) || String.isBlank(lookupFld)) {
            try {
                DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Query_Config__c' });
                /* code-analyzer-suppress ApexFlsViolation */
                List<DocGen_Template__c> tpls = [
                    SELECT Query_Config__c
                    FROM DocGen_Template__c
                    WHERE Id = :templateId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (tpls.isEmpty() || String.isBlank(tpls[0].Query_Config__c)) {
                    return html;
                }
                String cfgStr = tpls[0].Query_Config__c.trim();
                if (!cfgStr.startsWith('{')) {
                    return html;
                }
                Map<String, Object> cfg = (Map<String, Object>) JSON.deserializeUntyped(cfgStr);
                List<Object> nodes = (List<Object>) cfg.get('nodes');
                if (nodes == null) {
                    return html;
                }
                for (Object nodeObj : nodes) {
                    Map<String, Object> node = (Map<String, Object>) nodeObj;
                    String nodeAlias = (String) node.get('alias');
                    String effectiveKey = String.isNotBlank(nodeAlias)
                        ? nodeAlias
                        : (String) node.get('relationshipName');
                    if (giantRelationshipName.equalsIgnoreCase(effectiveKey)) {
                        childObj = (String) node.get('object');
                        lookupFld = (String) node.get('lookupField');
                        whereCls = (String) node.get('where');
                        if (whereCls == null) {
                            whereCls = (String) node.get('whereClause');
                        }
                        if (String.isNotBlank(whereCls)) {
                            whereCls = DocGenDataRetriever.sanitizeWhereClause(whereCls);
                        }
                        break;
                    }
                }
            } catch (DocGenException dge) {
                return html;
            } catch (Exception e) {
                String noop = e.getMessage(); // NOPMD — non-fatal; leave tags unresolved
                return html;
            }
        }

        if (String.isBlank(childObj) || String.isBlank(lookupFld)) {
            return html;
        }
        Schema.SObjectType childType = Schema.getGlobalDescribe().get(childObj);
        if (childType == null) {
            return html;
        }
        Map<String, Schema.SObjectField> childFieldMap = childType.getDescribe().fields.getMap();
        if (!childFieldMap.containsKey(lookupFld.toLowerCase())) {
            return html;
        }

        // Process matches in REVERSE so splicing doesn't shift later offsets.
        for (Integer i = openerStarts.size() - 1; i >= 0; i--) {
            String rel = relNames[i];
            if (!giantRelationshipName.equalsIgnoreCase(rel)) {
                continue; // Charts for non-giant rels: documented v1 limitation
            }
            String groupField = groupFields[i];
            if (!childFieldMap.containsKey(groupField.toLowerCase())) {
                continue; // Field doesn't exist on child — leave tag, render as-is
            }

            // Parse modifiers — same shape as the inline path. Recognized keys:
            //   colors=#aaa,#bbb   palette override
            //   where=Field='Val'  additional filter (appended to whereCls)
            //   split=;            multi-select delimiter
            //   groupBy=Field__c   pivot dimension (adds cols sub-list)
            Map<String, String> chartMods = DocGenChartBucketResolver.parseTagModifiers(tagModifiers[i]);
            String pivotField = chartMods.get('groupby');
            String chartWhere = chartMods.get('where');
            String splitDelim = chartMods.get('split');

            // Validate pivot field exists on the child schema (when set).
            if (String.isNotBlank(pivotField) && !childFieldMap.containsKey(pivotField.toLowerCase())) {
                continue;
            }

            // Sanitize the optional chart-level where via the same sanitizer
            // the V3 config uses. Any failure → skip this chart (safer than
            // running an unsafe clause).
            String safeChartWhere = null;
            if (String.isNotBlank(chartWhere)) {
                try {
                    safeChartWhere = DocGenDataRetriever.sanitizeWhereClause(chartWhere);
                } catch (Exception sanitizeErr) {
                    continue;
                }
            }

            Integer openerStart = openerStarts[i];
            Integer openerEnd = openerEnds[i];
            Integer closerStart = html.indexOf('{/ChartBucket}', openerEnd);
            if (closerStart == -1) {
                continue; // Unmatched closer — leave as-is
            }
            Integer closerEnd = closerStart + '{/ChartBucket}'.length();
            String body = html.substring(openerEnd, closerStart);

            // Build aggregate SOQL. groupField + childObj + lookupFld are
            // identifier-only (regex enforced + schema validated). whereCls
            // arrives pre-sanitized via the constructor or V3 fallback path.
            String soql = 'SELECT ' + groupField;
            if (String.isNotBlank(pivotField)) {
                soql += ', ' + pivotField;
            }
            soql +=
                ', COUNT(Id) cnt FROM ' +
                String.escapeSingleQuotes(childObj) +
                ' WHERE ' +
                String.escapeSingleQuotes(lookupFld) +
                ' = :recordId';
            if (String.isNotBlank(whereCls)) {
                soql += ' AND (' + whereCls + ')';
            }
            if (safeChartWhere != null) {
                soql += ' AND (' + safeChartWhere + ')';
            }
            soql += ' GROUP BY ' + groupField;
            if (String.isNotBlank(pivotField)) {
                soql += ', ' + pivotField;
            } else {
                soql += ' ORDER BY COUNT(Id) DESC';
            }

            List<AggregateResult> rows;
            try {
                rows = Database.query(soql, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — identifier-only interpolation; child/field/lookup/pivot validated against Schema; whereCls + chartWhere pre-sanitized
            } catch (Exception qErr) {
                String noop = qErr.getMessage(); // NOPMD — non-fatal
                continue;
            }

            // Dispatch to the right bucket-builder shape based on modifiers
            List<String> chartColOrder = DocGenChartBucketResolver.parseColSortModifier(chartMods.get('colsort'));
            List<Map<String, Object>> buckets = DocGenChartBucketResolver.buildBucketsFromAggregateRows(
                rows,
                groupField,
                pivotField,
                childType,
                splitDelim,
                chartColOrder
            );

            // Apply optional palette override from the `colors=` modifier on
            // this chart's tag. Mirrors the inline path so behavior is
            // consistent between in-memory and giant-query rendering.
            List<String> customPalette = DocGenChartBucketResolver.parsePaletteModifier(tagModifiers[i]);
            if (customPalette != null && !customPalette.isEmpty()) {
                for (Integer bi = 0; bi < buckets.size(); bi++) {
                    buckets[bi].put('color', customPalette[Math.mod(bi, customPalette.size())]);
                }
            }

            // Expand body per bucket via processXmlForTest so all the standard
            // merge-tag plumbing (escapeXml, format suffixes, conditionals)
            // applies inside the chart body just like anywhere else.
            String expansion = '';
            for (Map<String, Object> bucket : buckets) {
                try {
                    expansion += DocGenService.processXmlForTest(body, bucket);
                } catch (Exception expandErr) {
                    String noop = expandErr.getMessage(); // NOPMD
                }
            }

            html = html.substring(0, openerStart) + expansion + html.substring(closerEnd);
        }
        return html;
    }

    /**
     * Fallback: renders multiple separate PDFs if the single-call approach fails.
     * This produces the old behavior (gap between chunks) but at least doesn't crash.
     */
    private void renderMultiPartPdf(String fullHtml, String htmlTemplate) {
        // Re-parse: we need the original allRows without table breaks, but we've
        // already modified them. Since this is a fallback for an unexpected failure,
        // just mark the job as failed with a descriptive message.
        update new DocGen_Job__c(
            Id = jobId,
            Status__c = 'Failed',
            Label__c = 'PDF render failed — dataset too large for single-pass rendering. Try reducing child record count.'
        ); // NOPMD ApexCRUDViolation — package-internal
    }

    /**
     * Builds a <colgroup> with percentage column widths from the template's
     * <w:tblGrid><w:gridCol w:w="2400"/>...</w:tblGrid> XML.
     * Widths are in twips (1440 = 1 inch). Converts to percentages of total width.
     */
    private static String buildColGroupFromTblGrid(String tblPropsXml) {
        List<Integer> colWidths = new List<Integer>();
        Integer totalWidth = 0;

        Integer gridStart = tblPropsXml.indexOf('<w:tblGrid');
        Integer gridEnd = tblPropsXml.indexOf('</w:tblGrid>');
        if (gridStart == -1 || gridEnd == -1) {
            return '';
        }

        String gridXml = tblPropsXml.substring(gridStart, gridEnd);
        Integer scanPos = 0;
        while (scanPos < gridXml.length()) {
            Integer colStart = gridXml.indexOf('<w:gridCol', scanPos);
            if (colStart == -1) {
                break;
            }
            Integer wStart = gridXml.indexOf('w:w="', colStart);
            if (wStart == -1) {
                break;
            }
            wStart += 5;
            Integer wEnd = gridXml.indexOf('"', wStart);
            if (wEnd == -1) {
                break;
            }
            try {
                Integer w = Integer.valueOf(gridXml.substring(wStart, wEnd));
                colWidths.add(w);
                totalWidth += w;
            } catch (Exception e) {
                String noop = e.getMessage(); // NOPMD
            }
            scanPos = wEnd + 1;
        }

        if (colWidths.isEmpty() || totalWidth == 0) {
            return '';
        }

        String colGroup = '<colgroup>';
        for (Integer w : colWidths) {
            Decimal pct = (Decimal.valueOf(w) / Decimal.valueOf(totalWidth) * 100).setScale(1);
            colGroup += '<col style="width:' + pct + '%">';
        }
        colGroup += '</colgroup>';
        return colGroup;
    }

    /**
     * Inserts </table><table> breaks every N rows into the row HTML.
     * This resets Flying Saucer's DOM tree depth without splitting into
     * separate PDF files, keeping the output as one continuous document.
     */
    private static String insertTableBreaks(
        String allRows,
        Integer rowsPerBreak,
        String tableOpenTag,
        String colGroupHtml,
        String theadHtml
    ) {
        if (String.isBlank(allRows)) {
            return allRows;
        }
        String openTag = String.isNotBlank(tableOpenTag)
            ? tableOpenTag
            : '<table style="width:100%;border-collapse:collapse;table-layout:fixed;">';
        String theadBlock = String.isNotBlank(theadHtml) ? theadHtml : '';

        final String TR_CLOSE = '</tr>';
        final Integer trCloseLen = TR_CLOSE.length();

        // Use template column widths if available, otherwise calculate equal widths from first row
        String colGroup = String.isNotBlank(colGroupHtml) ? colGroupHtml : '';
        if (String.isBlank(colGroup)) {
            Integer colCount = 0;
            Integer firstTrEnd = allRows.indexOf(TR_CLOSE);
            if (firstTrEnd != -1) {
                String firstRow = allRows.substring(0, firstTrEnd);
                Integer tdIdx = 0;
                while (tdIdx < firstRow.length()) {
                    Integer tdStart = firstRow.indexOf('<td', tdIdx);
                    if (tdStart == -1) {
                        break;
                    }
                    colCount++;
                    tdIdx = tdStart + 3;
                }
            }
            if (colCount > 0) {
                String colWidth = String.valueOf((100.0 / colCount).setScale(2)) + '%';
                colGroup = '<colgroup>';
                for (Integer i = 0; i < colCount; i++) {
                    colGroup += '<col style="width:' + colWidth + '">';
                }
                colGroup += '</colgroup>';
            }
        }

        // Reproduce the authored <table …> tag (captured from the snapshot) so each
        // chunk renders at the same authored width / layout as the first table — and
        // reprint the captured <thead> so column headers repeat on every page.
        final String TABLE_BREAK = '</table>' + openTag + colGroup + theadBlock;

        // Build result with table breaks inserted at row boundaries.
        // Use List<String> + join instead of string concatenation for heap efficiency.
        List<String> parts = new List<String>();
        Integer rowCount = 0;
        Integer scanPos = 0;
        Integer lastBreakPos = 0;

        while (scanPos < allRows.length()) {
            Integer idx = allRows.indexOf(TR_CLOSE, scanPos);
            if (idx == -1) {
                break;
            }
            rowCount++;
            scanPos = idx + trCloseLen;

            if (rowCount >= rowsPerBreak && scanPos < allRows.length()) {
                parts.add(allRows.substring(lastBreakPos, scanPos));
                lastBreakPos = scanPos;
                rowCount = 0;
            }
        }
        // Append remaining rows
        if (lastBreakPos < allRows.length()) {
            parts.add(allRows.substring(lastBreakPos));
        }
        return String.join(parts, TABLE_BREAK);
    }

    /**
     * Splits a large block of <tr> rows into chunks for separate Blob.toPdf() calls.
     * Each chunk contains up to maxRowsPerChunk rows, split at </tr> boundaries.
     */
    private static List<String> splitRowsIntoChunks(String allRows, Integer maxRowsPerChunk) {
        List<String> chunks = new List<String>();
        if (String.isBlank(allRows)) {
            chunks.add('');
            return chunks;
        }

        final String TR_CLOSE = '</tr>';
        final Integer trCloseLen = TR_CLOSE.length();
        Integer chunkStart = 0;
        Integer rowsInChunk = 0;
        Integer scanPos = 0;

        while (scanPos < allRows.length()) {
            Integer idx = allRows.indexOf(TR_CLOSE, scanPos);
            if (idx == -1) {
                break;
            }
            rowsInChunk++;
            scanPos = idx + trCloseLen;

            if (rowsInChunk >= maxRowsPerChunk) {
                chunks.add(allRows.substring(chunkStart, scanPos));
                chunkStart = scanPos;
                rowsInChunk = 0;
            }
        }
        // Remaining rows
        if (chunkStart < allRows.length()) {
            chunks.add(allRows.substring(chunkStart));
        }
        if (chunks.isEmpty()) {
            chunks.add(allRows);
        }
        return chunks;
    }
}
