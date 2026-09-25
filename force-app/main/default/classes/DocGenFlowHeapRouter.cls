/**
 * Decides sync vs async vs reject for DocGenFlowAction's custom-JSON path
 * (issue #403).
 *
 * A DIFFERENT decision from DocGenGiantQueryRouter's, on purpose: that router
 * models heap growth from expanding many child rows into a loop. This one
 * models a completely different mechanism — assembleZip() re-zipping a DOCX
 * template's passthrough entries (media, styles, theme) back into the output
 * file. A customer's single-record, non-loop, ~3.4 MB Word template blew the
 * 6 MB synchronous heap governor (System.LimitException: Apex heap size too
 * large: 6491855) with a matched, non-mismatched JSON payload — proving the
 * cause was template byte size during DOCX reassembly, not row expansion and
 * not (as first suspected) a JSON-key/merge-tag mismatch. See #403 for the
 * full investigation, including a live repro in docgen-verify.
 *
 * TEMPLATE_HEAP_MULTIPLIER is anchored to that real customer data point
 * (3,400,000 bytes -> 6,491,855 bytes peak, ~1.9x), not to this session's
 * synthetic repro (which needed ~5.6-7.0 MB of AES-incompressible padding to
 * fail against the same ceiling, ~1.1-1.3x) — a real template's XML structure
 * and many-small-image layout cost more heap per byte than uniform synthetic
 * padding, and a wrong "safe" verdict here is an uncatchable crash, so this
 * deliberately estimates using the worse of the two ratios.
 *
 * PDF output is NOT exempt, despite never reaching assembleZip's passthrough
 * re-zip (renderPdf() works off the parsed HTML only) — an earlier version of
 * this router treated PDF as unconditionally safe, and live testing in
 * docgen-verify caught that as wrong: an 11.2 MB template that succeeds fine
 * as DOCX-vs-PDF at 7 MB still blows the same uncatchable
 * System.LimitException as PDF once large enough (measured: peak 10,261,198
 * bytes on an 11,207,139-byte template, PDF output). PDF avoids assembleZip's
 * write-side triple-copy, but every format still pays the read-side cost —
 * DocGenTemplateManager.getTemplateFileContent unconditionally base64-loads
 * the full ContentVersion, and mergeTemplate's full-ZIP path (the only path
 * reachable for a template that hasn't been re-saved through the Admin UI's
 * pre-decomposition step) extracts every entry into mr.passthroughEntries
 * regardless of output format. So PDF gets a materially higher ceiling than
 * DOCX (no write-side duplication), not an unlimited one.
 */
public with sharing class DocGenFlowHeapRouter {
    public static final Integer SYNC_HEAP_LIMIT = 6000000;
    public static final Integer ASYNC_HEAP_LIMIT = 12000000;
    // Less sampling uncertainty than DocGenGiantQueryRouter's row-count model
    // (which is estimating an unknown, potentially-unbounded child dataset) —
    // this is a single known number (template ContentVersion size), so less
    // blind headroom is needed once the multiplier itself is conservative.
    public static final Decimal SAFE_HEAP_RATIO = 0.85;

    // DOCX/PowerPoint/Excel output: pays both the read-side cost (below) AND
    // assembleZip's write-side re-zip of every passthrough entry.
    public static final Decimal TEMPLATE_HEAP_MULTIPLIER = 2.0;
    // PDF output: read-side cost only (base64 load + full ZIP extraction into
    // mr.passthroughEntries) — anchored to a measured PDF failure at 11.2 MB
    // (peak 10,261,198 bytes, ratio ~0.92x), rounded up for margin.
    public static final Decimal PDF_HEAP_MULTIPLIER = 1.0;
    // JSON payload + Apex transaction baseline — small relative to the template
    // term for any template worth routing on, but keeps tiny templates from
    // estimating to ~0.
    public static final Integer BASE_OVERHEAD_BYTES = 300000;

    public static final String ROUTE_SYNC = 'SYNC';
    public static final String ROUTE_ASYNC = 'ASYNC';
    public static final String ROUTE_REJECT = 'REJECT';

    public class Decision {
        public String route = ROUTE_SYNC;
        public Integer estimatedPeakHeapBytes = 0;
        public String reason = '';
    }

    public static Integer safeSyncHeapBytes() {
        return (Integer) (SYNC_HEAP_LIMIT * SAFE_HEAP_RATIO);
    }

    public static Integer safeAsyncHeapBytes() {
        return (Integer) (ASYNC_HEAP_LIMIT * SAFE_HEAP_RATIO);
    }

    /** Estimated peak synchronous-equivalent heap (bytes) for generating this output format at this template size. */
    public static Integer estimatePeakHeapBytes(Integer templateSizeBytes, String outputFormat) {
        Long size = (templateSizeBytes == null || templateSizeBytes <= 0) ? 0L : (Long) templateSizeBytes;
        Decimal multiplier = 'PDF'.equalsIgnoreCase(outputFormat) ? PDF_HEAP_MULTIPLIER : TEMPLATE_HEAP_MULTIPLIER;
        Long total = BASE_OVERHEAD_BYTES + (Long) (size * multiplier);
        return total > 2000000000L ? 2000000000 : (Integer) total;
    }

    /**
     * @param templateSizeBytes the template's ContentVersion size (DocGenTemplateManager.getTemplateFileSize)
     * @param outputFormat resolved output format ('PDF', 'Word'/'Native', etc.) — sets which multiplier applies
     */
    public static Decision decide(Integer templateSizeBytes, String outputFormat) {
        Decision d = new Decision();

        d.estimatedPeakHeapBytes = estimatePeakHeapBytes(templateSizeBytes, outputFormat);
        Integer estMb = d.estimatedPeakHeapBytes / 1048576;

        if (d.estimatedPeakHeapBytes <= safeSyncHeapBytes()) {
            d.reason = 'Estimated peak heap ~' + estMb + ' MB fits the synchronous budget.';
            return d;
        }

        if (d.estimatedPeakHeapBytes <= safeAsyncHeapBytes()) {
            d.route = ROUTE_ASYNC;
            d.reason =
                'Estimated peak heap ~' +
                estMb +
                ' MB exceeds the safe synchronous budget for ' +
                outputFormat +
                ' output — routing to background generation.';
            return d;
        }

        d.route = ROUTE_REJECT;
        d.reason =
            'Estimated peak heap ~' +
            estMb +
            ' MB exceeds even the background generation budget for ' +
            outputFormat +
            ' output. Reduce the template size (fewer/smaller embedded images, or split into a main document + ' +
            'appendix generated separately)' +
            ('PDF'.equalsIgnoreCase(outputFormat)
                ? '.'
                : ', or generate as PDF instead if that output format is acceptable — PDF has a higher ceiling ' +
                  'since it skips DOCX/PPTX/XLSX\'s ZIP reassembly step, though it is not unlimited either.');
        return d;
    }
}
