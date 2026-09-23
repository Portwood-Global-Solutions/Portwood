/**
 * Unit tests for DocGenFlowHeapRouter (#403). Pure logic — no DML, no callouts —
 * so boundaries are asserted exactly against the class's own public constants
 * rather than hardcoded numbers, so these stay correct if the constants are
 * later retuned against more real-world data.
 */
@isTest
private class DocGenFlowHeapRouterTest {
    @isTest
    static void nullOrZeroOrNegativeSizeEstimatesToBaseOverheadOnly() {
        System.assertEquals(
            DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES,
            DocGenFlowHeapRouter.estimatePeakHeapBytes(null, 'Native')
        );
        System.assertEquals(
            DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES,
            DocGenFlowHeapRouter.estimatePeakHeapBytes(0, 'Native')
        );
        System.assertEquals(
            DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES,
            DocGenFlowHeapRouter.estimatePeakHeapBytes(-5, 'Native')
        );
    }

    @isTest
    static void nonPdfUsesTheHigherMultiplierThanPdfAtTheSameSize() {
        Integer size = 1000000;
        Integer nonPdfEst = DocGenFlowHeapRouter.estimatePeakHeapBytes(size, 'Native');
        Integer pdfEst = DocGenFlowHeapRouter.estimatePeakHeapBytes(size, 'PDF');
        System.assert(
            nonPdfEst > pdfEst,
            'DOCX/PPTX/XLSX output pays assembleZip\'s write-side cost on top of the read-side cost PDF alone pays — its estimate must be higher for the same template size.'
        );
        // Exact formula check, not just directional — pins the anchor values from #403.
        System.assertEquals(
            DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES + (Integer) (size * DocGenFlowHeapRouter.TEMPLATE_HEAP_MULTIPLIER),
            nonPdfEst
        );
        System.assertEquals(
            DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES + (Integer) (size * DocGenFlowHeapRouter.PDF_HEAP_MULTIPLIER),
            pdfEst
        );
    }

    @isTest
    static void hugeSizeClampsToTheOverflowGuardInsteadOfWrapping() {
        Integer est = DocGenFlowHeapRouter.estimatePeakHeapBytes(1500000000, 'Native');
        System.assertEquals(
            2000000000,
            est,
            'A pathological size should clamp to the guard ceiling, not silently overflow into a small/negative number.'
        );
    }

    @isTest
    static void safeHeapHelpersMatchTheirOwnFormula() {
        System.assertEquals(
            (Integer) (DocGenFlowHeapRouter.SYNC_HEAP_LIMIT * DocGenFlowHeapRouter.SAFE_HEAP_RATIO),
            DocGenFlowHeapRouter.safeSyncHeapBytes()
        );
        System.assertEquals(
            (Integer) (DocGenFlowHeapRouter.ASYNC_HEAP_LIMIT * DocGenFlowHeapRouter.SAFE_HEAP_RATIO),
            DocGenFlowHeapRouter.safeAsyncHeapBytes()
        );
    }

    @isTest
    static void smallNonPdfTemplateRoutesSync() {
        DocGenFlowHeapRouter.Decision d = DocGenFlowHeapRouter.decide(1000000, 'Native');
        System.assertEquals(DocGenFlowHeapRouter.ROUTE_SYNC, d.route);
        System.assert(String.isNotBlank(d.reason));
    }

    @isTest
    static void nonPdfSyncBoundaryIsInclusive() {
        // Largest templateSize whose non-PDF estimate lands EXACTLY on safeSyncHeapBytes().
        Integer atBoundary = (Integer) ((DocGenFlowHeapRouter.safeSyncHeapBytes() -
        DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES) / DocGenFlowHeapRouter.TEMPLATE_HEAP_MULTIPLIER);
        DocGenFlowHeapRouter.Decision atD = DocGenFlowHeapRouter.decide(atBoundary, 'Native');
        System.assertEquals(
            DocGenFlowHeapRouter.ROUTE_SYNC,
            atD.route,
            'An estimate exactly at the safe sync ceiling should still be treated as safe (<=), not tipped over.'
        );

        DocGenFlowHeapRouter.Decision overD = DocGenFlowHeapRouter.decide(atBoundary + 10000, 'Native');
        System.assertEquals(
            DocGenFlowHeapRouter.ROUTE_ASYNC,
            overD.route,
            'Just over the safe sync ceiling must route async, not stay sync.'
        );
    }

    @isTest
    static void nonPdfAsyncBoundaryIsInclusive() {
        Integer atBoundary = (Integer) ((DocGenFlowHeapRouter.safeAsyncHeapBytes() -
        DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES) / DocGenFlowHeapRouter.TEMPLATE_HEAP_MULTIPLIER);
        DocGenFlowHeapRouter.Decision atD = DocGenFlowHeapRouter.decide(atBoundary, 'Native');
        System.assertEquals(DocGenFlowHeapRouter.ROUTE_ASYNC, atD.route);

        DocGenFlowHeapRouter.Decision overD = DocGenFlowHeapRouter.decide(atBoundary + 10000, 'Native');
        System.assertEquals(
            DocGenFlowHeapRouter.ROUTE_REJECT,
            overD.route,
            'Just over the safe async ceiling must reject cleanly, not be handed to a job that will crash uncatchably.'
        );
    }

    @isTest
    static void pdfGetsAHigherCeilingThanNonPdfAtTheSameSize() {
        // A size that routes non-PDF to ASYNC should still be safely SYNC as PDF,
        // because PDF skips assembleZip's write-side duplication (#403 finding).
        Integer size = 3000000;
        DocGenFlowHeapRouter.Decision nonPdf = DocGenFlowHeapRouter.decide(size, 'Native');
        DocGenFlowHeapRouter.Decision pdf = DocGenFlowHeapRouter.decide(size, 'PDF');
        System.assertEquals(DocGenFlowHeapRouter.ROUTE_ASYNC, nonPdf.route);
        System.assertEquals(DocGenFlowHeapRouter.ROUTE_SYNC, pdf.route);
    }

    @isTest
    static void pdfIsNotUnconditionallySafeAtLargeEnoughSize() {
        // Regression guard for the bug this session's live testing caught: an
        // earlier draft of this router treated PDF as always-safe. It is not —
        // it just has a higher ceiling. A large enough PDF must still reject.
        Integer hugePdfSize =
            (Integer) ((DocGenFlowHeapRouter.safeAsyncHeapBytes() - DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES) /
            DocGenFlowHeapRouter.PDF_HEAP_MULTIPLIER) + 500000;
        DocGenFlowHeapRouter.Decision d = DocGenFlowHeapRouter.decide(hugePdfSize, 'PDF');
        System.assertEquals(DocGenFlowHeapRouter.ROUTE_REJECT, d.route);
    }

    @isTest
    static void outputFormatComparisonIsCaseInsensitiveAndNullSafe() {
        DocGenFlowHeapRouter.Decision lower = DocGenFlowHeapRouter.decide(1000000, 'pdf');
        DocGenFlowHeapRouter.Decision mixed = DocGenFlowHeapRouter.decide(1000000, 'Pdf');
        DocGenFlowHeapRouter.Decision nullFormat = DocGenFlowHeapRouter.decide(1000000, null);
        System.assertEquals(
            DocGenFlowHeapRouter.estimatePeakHeapBytes(1000000, 'PDF'),
            DocGenFlowHeapRouter.estimatePeakHeapBytes(1000000, 'pdf'),
            'PDF detection must be case-insensitive.'
        );
        System.assertEquals(DocGenFlowHeapRouter.ROUTE_SYNC, lower.route);
        System.assertEquals(DocGenFlowHeapRouter.ROUTE_SYNC, mixed.route);
        System.assertEquals(
            DocGenFlowHeapRouter.estimatePeakHeapBytes(1000000, 'Native'),
            DocGenFlowHeapRouter.estimatePeakHeapBytes(1000000, null),
            'A null/blank output format must not be mistaken for PDF — treat as the more conservative non-PDF multiplier.'
        );
        System.assertEquals(DocGenFlowHeapRouter.ROUTE_SYNC, nullFormat.route);
    }

    @isTest
    static void rejectReasonMentionsPdfAlternativeOnlyForNonPdfFormats() {
        Integer hugeSize =
            (Integer) ((DocGenFlowHeapRouter.safeAsyncHeapBytes() - DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES) /
            DocGenFlowHeapRouter.TEMPLATE_HEAP_MULTIPLIER) + 500000;
        DocGenFlowHeapRouter.Decision nonPdfReject = DocGenFlowHeapRouter.decide(hugeSize, 'Native');
        System.assert(
            nonPdfReject.reason.contains('PDF'),
            'Rejecting a DOCX-shaped request should point the author at the PDF alternative.'
        );

        Integer hugePdfSize =
            (Integer) ((DocGenFlowHeapRouter.safeAsyncHeapBytes() - DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES) /
            DocGenFlowHeapRouter.PDF_HEAP_MULTIPLIER) + 500000;
        DocGenFlowHeapRouter.Decision pdfReject = DocGenFlowHeapRouter.decide(hugePdfSize, 'PDF');
        System.assert(
            !pdfReject.reason.contains('generate as PDF instead'),
            'Rejecting an already-PDF request should not suggest switching to PDF as the escape hatch.'
        );
    }
}
