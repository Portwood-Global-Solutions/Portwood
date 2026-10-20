/**
 * Upload-time fidelity report for Word/PowerPoint templates (issue #272).
 *
 * DocGenTemplateLinter is the HTML/Canvas sibling; this class is the DOCX/PPTX
 * equivalent. The offline reference is scripts/docgen-template-lint.js (the
 * zero-dep Node preflight that QA runs against .docx files) — these checks are
 * the same rules, computed at save time in Apex so the author sees them in the
 * Designer instead of discovering them after a generation that silently
 * degraded.
 *
 * Every check is advisory and individually guarded: lint() never throws and
 * never touches the author's bytes. A warning is a heads-up, not a blocker —
 * the save has already succeeded before lint runs (see saveTemplate) and a
 * failing check costs its own findings, never the report, and never the save.
 *
 * Checks ported from the blueprint:
 *   1. Fragmented merge tags  —  a {Field} split across multiple <w:r> runs by
 *      mid-tag editing. Text tags are healed at merge time (mergeRunsInTags),
 *      but chart tags split across runs fall back to literal text (#130) — so
 *      this is a warning either way.
 *   2. Loop pairing (stack-based, mirroring DocGenService.findBalancedEnd) —
 *      {#Rel} without {/Rel}, and stray {/Rel}. {#IF expr} balances on the
 *      bare key "IF" exactly as the engine does.
 *   3. Closing-tag containment — a {#Rel}…{/Rel} pair that no <w:tr> fully
 *      encloses makes the engine fall back to paragraph repeat (or worse).
 *   4. Closing-tag placement — a {/Rel} outside any structural container is
 *      almost always an escaped cell.
 *   5. Nested loops on the same relationship — almost always a typo (the
 *      canonical {^Rel}{:else}…{#Rel}…{/Rel}…{/Rel} inverse pattern is allowed).
 *   6. Empty / whitespace-only loops.
 *   7. Row-binding collision — parent + nested loop bound to the SAME <w:tr>.
 *   8. Entity-encoded IF operators (&gt;/&lt;) — the IF parser does not decode
 *      entities before operator parsing, so the expression always evaluates
 *      false on installs before v1.69 (left in so templates stay portable).
 *   9. Nested IF blocks — findBalancedEnd can't depth-track nested {#IF} on
 *      installs before v1.72 (left in for the same portability reason).
 *
 * The row-binding collision check only applies to Word documents (its
 * <w:tr> semantics); PowerPoint slides get the text-level checks 1, 2, 5, 6,
 * 8 and 9, whose tables use <a:tr> and would otherwise false-positive on a
 * paragraph fallback warning.
 */
public with sharing class DocGenDocxTemplateLinter {
    /**
     * Lints a DOCX/PPTX upload's bytes against the merge engine's semantics.
     * Best-effort: returns whatever warnings completed checks produced; a
     * failing check (or an unreadable archive) yields no findings from that
     * part, never an exception.
     */
    public static List<DocGenAiHtmlValidator.Finding> lint(Blob fileBytes) {
        List<DocGenAiHtmlValidator.Finding> findings = new List<DocGenAiHtmlValidator.Finding>();
        if (fileBytes == null) {
            return findings;
        }
        try {
            Compression.ZipReader reader = new Compression.ZipReader(fileBytes);
            // Word: the body lives in word/document.xml. PowerPoint: each slide
            // in ppt/slides/slideN.xml. We lint each part independently so a tag
            // pair never appears to close across a part boundary it could not.
            for (Compression.ZipEntry e : reader.getEntries()) {
                if (e.getName() == 'word/document.xml') {
                    lintXml(reader.extract(e.getName()).toString(), true, findings);
                } else if (e.getName().startsWith('ppt/slides/slide') && e.getName().endsWith('.xml')) {
                    lintXml(reader.extract(e.getName()).toString(), false, findings);
                }
            }
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD — lint is advisory; one unreadable file must not sink the report
        }
        return findings;
    }

    private static void lintXml(String xml, Boolean isWordPart, List<DocGenAiHtmlValidator.Finding> findings) {
        if (String.isBlank(xml)) {
            return;
        }
        checkFragmentedTags(xml, findings);

        VisibleStream vs = buildVisibleText(xml);
        List<RawTag> tags = tagsFromVisibleText(vs);
        PairResult pr = findMatchingPairs(tags);

        checkUnmatchedTags(pr, findings);
        checkEmptyLoops(pr, vs, findings);
        checkNestedSameRel(pr.pairs, findings);
        checkNestedIfs(pr.pairs, findings);
        checkEntityEncodedIf(xml, findings);
        if (isWordPart) {
            // Table-structure semantics are WordprocessingML-specific.
            checkStructuralPlacement(xml, pr, findings);
            checkRowBindingCollision(xml, pr.pairs, findings);
        }
    }

    // -----------------------------------------------------------------------
    // 1. Fragmented merge tags — {Na<w:r>me</w:r>} reads as two runs to the
    //    merger. Text tags heal; chart tags fall back to literal text (#130).
    // -----------------------------------------------------------------------

    private static void checkFragmentedTags(String xml, List<DocGenAiHtmlValidator.Finding> findings) {
        Integer i = 0;
        Integer len = xml.length();
        while (i < len) {
            Integer open = xml.indexOf('{', i);
            if (open == -1) {
                break;
            }
            if (!isInsideOpenTextRun(xml, open)) {
                i = open + 1;
                continue;
            }
            Integer close = xml.indexOf('}', open);
            if (close == -1) {
                break;
            }
            String between = xml.substring(open + 1, close);
            if (between.indexOf('<') != -1 || between.indexOf('>') != -1) {
                String visible = stripMarkup(between);
                String reconstructed = '{' + visible + '}';
                addFinding(
                    findings,
                    'Merge tag split across runs',
                    'Merge tag is split across multiple Word runs: ' +
                        reconstructed +
                        '. Text tags heal at merge time, but chart tags split across runs can fall back to literal text. Cleanest fix: delete the whole tag in Word and retype it in one continuous burst, without backspacing or formatting changes mid-tag.',
                    1
                );
            }
            i = close + 1;
        }
    }

    /** Is this '{' inside a <w:t>/<a:t> text run? Approximate, like the blueprint. */
    private static Boolean isInsideOpenTextRun(String xml, Integer pos) {
        Integer fromIdx = Math.max(0, pos - 200);
        String recent = xml.substring(fromIdx, pos);
        Integer lastWtOpen = recent.lastIndexOf('<w:t');
        Integer lastWtClose = recent.lastIndexOf('</w:t>');
        Integer lastAtOpen = recent.lastIndexOf('<a:t');
        Integer lastAtClose = recent.lastIndexOf('</a:t>');
        Boolean inWt = lastWtOpen != -1 && (lastWtClose == -1 || lastWtClose < lastWtOpen);
        Boolean inAt = lastAtOpen != -1 && (lastAtClose == -1 || lastAtClose < lastAtOpen);
        return inWt || inAt;
    }

    // -----------------------------------------------------------------------
    // Visible-text stream — concatenate every text run, mapping each character
    // back to its XML offset so hits in clean text can be located structurally.
    // -----------------------------------------------------------------------

    private static VisibleStream buildVisibleText(String xml) {
        VisibleStream vs = new VisibleStream();
        List<Integer> ends = new List<Integer>();
        List<String> contents = new List<String>();
        // Share the merge engine's linear scanner. A whole-document Matcher can
        // throw an uncatchable LimitException even when this report is advisory.
        DocGenService.collectTextRunBodies(xml, vs.xmlStarts, ends, contents);
        Integer offset = 0;
        for (String text : contents) {
            vs.visibleStarts.add(offset);
            offset += text.length();
        }
        vs.text = String.join(contents, '');
        return vs;
    }

    private static List<RawTag> tagsFromVisibleText(VisibleStream vs) {
        List<RawTag> tags = new List<RawTag>();
        Integer scan = 0;
        while (scan < vs.text.length()) {
            Integer start = vs.text.indexOf('{', scan);
            if (start == -1)
                break;
            Integer endIdx = vs.text.indexOf('}', start + 1);
            if (endIdx == -1)
                break;
            Integer nested = vs.text.indexOf('{', start + 1);
            if (nested != -1 && nested < endIdx) {
                scan = nested;
                continue;
            }
            scan = endIdx + 1;
            if (endIdx == start + 1)
                continue;
            RawTag t = new RawTag();
            t.raw = vs.text.substring(start, endIdx + 1);
            t.visStart = start;
            t.visEnd = endIdx + 1;
            t.xmlStart = visibleXmlOffset(vs, start);
            t.xmlEnd = visibleXmlOffset(vs, endIdx) + 1;
            tags.add(t);
        }
        return tags;
    }

    private static Integer visibleXmlOffset(VisibleStream vs, Integer offset) {
        Integer low = 0;
        Integer high = vs.visibleStarts.size() - 1;
        while (low < high) {
            Integer mid = (low + high + 1) / 2;
            if (vs.visibleStarts[mid] <= offset)
                low = mid;
            else
                high = mid - 1;
        }
        return vs.xmlStarts[low] + offset - vs.visibleStarts[low];
    }

    // -----------------------------------------------------------------------
    // 2. Loop pairing. Both {#Rel} and {^Rel} are openers (findBalancedEnd
    //    treats '#' and '^' as equivalent depth-up); {/Rel} closes. {#IF expr}
    //    balances on the bare key "IF", mirroring the engine.
    // -----------------------------------------------------------------------

    private static PairResult findMatchingPairs(List<RawTag> tags) {
        List<Opener> opens = new List<Opener>();
        PairResult r = new PairResult();
        for (RawTag t : tags) {
            if (t.raw.startsWith('{#')) {
                opens.add(makeOpener(t, '#'));
            } else if (t.raw.startsWith('{^')) {
                opens.add(makeOpener(t, '^'));
            } else if (t.raw.startsWith('{/')) {
                String rel = t.raw.substring(2, t.raw.length() - 1);
                String key = balanceKey(rel);
                Integer found = -1;
                for (Integer j = opens.size() - 1; j >= 0; j--) {
                    if (opens[j].key == key) {
                        found = j;
                        break;
                    }
                }
                if (found >= 0) {
                    Pair p = new Pair();
                    p.open = opens[found];
                    p.close = t;
                    p.rel = opens[found].rel;
                    r.pairs.add(p);
                    opens.remove(found);
                } else {
                    r.unmatchedCloses.add(t);
                }
            }
        }
        r.unmatchedOpens = opens;
        return r;
    }

    private static Opener makeOpener(RawTag t, String variant) {
        Opener o = new Opener();
        o.tag = t;
        o.variant = variant;
        o.rel = t.raw.substring(2, t.raw.length() - 1);
        o.key = balanceKey(o.rel);
        return o;
    }

    /** The balance key DocGenService.findBalancedEnd pairs on. */
    private static String balanceKey(String rel) {
        String trimmed = rel.trim();
        String upper = trimmed.toUpperCase();
        if (upper == 'IF' || upper.startsWith('IF ')) {
            return 'IF';
        }
        return trimmed;
    }

    private static void checkUnmatchedTags(PairResult pr, List<DocGenAiHtmlValidator.Finding> findings) {
        for (Opener o : pr.unmatchedOpens) {
            addFinding(
                findings,
                'Loop opener with no closer',
                'Loop opener {#' +
                    o.rel +
                    '} has no matching closing tag {/' +
                    o.rel +
                    '}. Generation fails the whole merge with a malformed-loop error — add the closing tag, or delete the opener if it was leftover.',
                1
            );
        }
        for (RawTag c : pr.unmatchedCloses) {
            String rel = c.raw.substring(2, c.raw.length() - 1);
            addFinding(
                findings,
                'Loop closer with no opener',
                'Loop closer {/' +
                    rel +
                    '} has no matching opener {#' +
                    rel +
                    '} (possible duplicate). Check the relationship name spelling and that the {#…} opener was not lost to formatting or a stray copy/paste.',
                1
            );
        }
    }

    // -----------------------------------------------------------------------
    // 3 + 4. Structural placement: the enclosing <w:tr> and where the closing
    //    tag sits. Word-only.
    // -----------------------------------------------------------------------

    private static void checkStructuralPlacement(
        String xml,
        PairResult pr,
        List<DocGenAiHtmlValidator.Finding> findings
    ) {
        for (Pair pair : pr.pairs) {
            Integer[] enclosingRow = findEnclosingRow(xml, pair.open.tag.xmlStart, pair.close.xmlEnd);
            if (enclosingRow != null) {
                continue;
            }
            String closeContainer = isInsideAnyContainer(xml, pair.close.xmlStart);
            if (closeContainer == null) {
                addFinding(
                    findings,
                    'Closing tag outside a container',
                    'Closing tag {/' +
                        pair.rel +
                        '} is not inside any structural container (table row, cell, or paragraph). The closing tag has escaped its intended cell — cut it and paste it back inside the same cell as the opening tag, or inside the cell that contains the related sub-table.',
                    1
                );
            } else {
                addFinding(
                    findings,
                    'Loop not inside a single table row',
                    'No table row encloses both {#' +
                        pair.open.variant +
                        pair.rel +
                        '} and {/' +
                        pair.rel +
                        '}. The merge engine falls back to paragraph-level repeat — usually fine for non-table loops, but unexpected for table-based templates. If you want a table row to repeat, both loop tags must live inside cells of the same row (or inside a single cell that contains the entire repeat block).',
                    1
                );
            }
        }
    }

    /** Nearest <w:tr> that fully encloses both tags, or null. Mirrors extractLoopBody. */
    private static Integer[] findEnclosingRow(String xml, Integer openOffset, Integer closeEnd) {
        List<Integer[]> ranges = new List<Integer[]>();
        List<Integer> stack = new List<Integer>();
        Integer scan = 0;
        while (scan < xml.length()) {
            Integer start = xml.indexOf('<', scan);
            if (start == -1)
                break;
            Boolean closing = xml.indexOf('</', start) == start;
            Integer nameStart = start + (closing ? 2 : 1);
            scan = start + 1;
            if (nameStart + 4 >= xml.length())
                continue;
            String name = xml.substring(nameStart, nameStart + 4);
            if ((!name.equals('w:tr') && !name.equals('a:tr')) || !isTagBoundary(xml.charAt(nameStart + 4)))
                continue;
            if (!closing) {
                stack.add(start);
            } else if (!stack.isEmpty()) {
                Integer rowStart = stack.remove(stack.size() - 1);
                ranges.add(new List<Integer>{ rowStart, nameStart + 5 });
            }
        }
        Integer[] best = null;
        for (Integer[] r : ranges) {
            if (r[0] < openOffset && r[1] >= closeEnd) {
                if (best == null || (r[1] - r[0]) < (best[1] - best[0])) {
                    best = r;
                }
            }
        }
        return best;
    }

    /** The kind of WordprocessingML container this offset sits inside, or null. */
    private static String isInsideAnyContainer(String xml, Integer offset) {
        String before = xml.substring(0, offset);
        if (countOpenMinusClose(before, 'w:tc') > 0) {
            return 'cell';
        }
        if (countOpenMinusClose(before, 'w:tr') > 0) {
            return 'row';
        }
        if (countOpenMinusClose(before, 'w:p') > 0) {
            Integer lastPOpen = Math.max(xml.lastIndexOf('<w:p>', offset), xml.lastIndexOf('<w:p ', offset));
            Integer lastPClose = xml.lastIndexOf('</w:p>', offset);
            if (lastPOpen > lastPClose && xml.substring(lastPOpen, offset).contains('<w:numPr')) {
                return 'numbered paragraph';
            }
            return 'paragraph';
        }
        return null;
    }

    private static Integer countOpenMinusClose(String s, String tag) {
        Integer open = 0;
        Integer scan = 0;
        String prefix = '<' + tag;
        while (scan < s.length()) {
            Integer hit = s.indexOf(prefix, scan);
            if (hit == -1)
                break;
            Integer after = hit + prefix.length();
            if (after < s.length() && isTagBoundary(s.charAt(after)))
                open++;
            scan = after;
        }
        Integer close = s.countMatches('</' + tag + '>');
        return open - close;
    }

    private static Boolean isTagBoundary(Integer c) {
        return c == 62 || c == 32 || c == 9 || c == 10 || c == 11 || c == 12 || c == 13;
    }

    private static String stripMarkup(String text) {
        List<String> parts = new List<String>();
        Integer scan = 0;
        while (scan < text.length()) {
            Integer start = text.indexOf('<', scan);
            if (start == -1)
                break;
            Integer endIdx = text.indexOf('>', start + 1);
            if (endIdx == -1)
                break;
            parts.add(text.substring(scan, start));
            scan = endIdx + 1;
        }
        parts.add(text.substring(scan));
        return String.join(parts, '');
    }

    // -----------------------------------------------------------------------
    // 5. Nested loops on the same relationship. The canonical inverse-loop
    //    conditional {^Rel}{:else}…{#Rel}…{/Rel}…{/Rel} is allowed.
    // -----------------------------------------------------------------------

    private static void checkNestedSameRel(List<Pair> pairs, List<DocGenAiHtmlValidator.Finding> findings) {
        for (Integer i = 0; i < pairs.size(); i++) {
            for (Integer j = 0; j < pairs.size(); j++) {
                if (i == j) {
                    continue;
                }
                Pair a = pairs[i];
                Pair b = pairs[j];
                if (a.rel != b.rel) {
                    continue;
                }
                if (a.open.tag.xmlStart < b.open.tag.xmlStart && a.close.xmlEnd > b.close.xmlEnd) {
                    if (a.open.variant == '^' && b.open.variant == '#') {
                        continue;
                    }
                    addFinding(
                        findings,
                        'Nested loops on the same relationship',
                        'Two loops over "' +
                            a.rel +
                            '" are nested inside each other. This is almost always a typo — did you mean to nest a different relationship inside? (The canonical inverse-loop conditional {^Rel}{:else}…{#Rel}…{/Rel}…{/Rel} is allowed.)',
                        1
                    );
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // 6. Empty loops.
    // -----------------------------------------------------------------------

    private static void checkEmptyLoops(PairResult pr, VisibleStream vs, List<DocGenAiHtmlValidator.Finding> findings) {
        for (Pair p : pr.pairs) {
            String innerVis = vs.text.substring(p.open.tag.visEnd, p.close.visStart).trim();
            if (innerVis.length() == 0) {
                addFinding(
                    findings,
                    'Empty loop',
                    'Loop {#' +
                        p.rel +
                        '} … {/' +
                        p.rel +
                        '} has no content between the tags. It will iterate but produce no output — probably leftover from a deleted cell.',
                    1
                );
            }
        }
    }

    // -----------------------------------------------------------------------
    // 7. Row-binding collision — parent + nested loop bound to the same <w:tr>
    //    fight over the same container. Word-only.
    // -----------------------------------------------------------------------

    private static void checkRowBindingCollision(
        String xml,
        List<Pair> pairs,
        List<DocGenAiHtmlValidator.Finding> findings
    ) {
        List<PairRow> withRows = new List<PairRow>();
        for (Pair p : pairs) {
            Integer[] row = findEnclosingRow(xml, p.open.tag.xmlStart, p.close.xmlEnd);
            if (row != null) {
                withRows.add(new PairRow(p, row));
            }
        }
        for (Integer i = 0; i < withRows.size(); i++) {
            for (Integer j = 0; j < withRows.size(); j++) {
                if (i == j) {
                    continue;
                }
                PairRow outerRow = withRows[i];
                PairRow innerRow = withRows[j];
                if (
                    outerRow.p.open.tag.xmlStart < innerRow.p.open.tag.xmlStart &&
                    outerRow.p.close.xmlEnd > innerRow.p.close.xmlEnd
                ) {
                    if (outerRow.row[0] == innerRow.row[0] && outerRow.row[1] == innerRow.row[1]) {
                        addFinding(
                            findings,
                            'Row-binding collision',
                            '{#' +
                                innerRow.p.rel +
                                '} is nested inside {#' +
                                outerRow.p.rel +
                                '} but both bind to the same table row. Wrap the inner tag and its content in a borderless single-cell mini-table so it binds to the mini-table row instead of fighting the outer loop for the same container.',
                            1
                        );
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // 8. Entity-encoded IF operators — &gt;/&lt; are not decoded before the
    //    IF parser matches operators, so the expression always evaluates false
    //    on installs before v1.69.
    // -----------------------------------------------------------------------

    private static void checkEntityEncodedIf(String xml, List<DocGenAiHtmlValidator.Finding> findings) {
        Integer scan = 0;
        while (scan < xml.length()) {
            Integer start = xml.indexOf('{#', scan);
            if (start == -1)
                break;
            scan = start + 2;
            if (start + 4 >= xml.length() || !xml.substring(start + 2, start + 4).equalsIgnoreCase('IF'))
                continue;
            Integer c = xml.charAt(start + 4);
            if (c != 32 && c != 9 && c != 10 && c != 11 && c != 12 && c != 13)
                continue;
            Integer endIdx = xml.indexOf('}', start + 5);
            if (endIdx == -1)
                break;
            String raw = xml.substring(start, endIdx + 1);
            Integer gt = raw.indexOf('&gt;');
            Integer lt = raw.indexOf('&lt;');
            if (gt == -1 && lt == -1)
                continue;
            String entity = gt != -1 && (lt == -1 || gt < lt) ? '&gt;' : '&lt;';
            String decoded = entity == '&gt;' ? '>' : '<';
            addFinding(
                findings,
                'HTML-encoded IF operator',
                'IF expression uses \'' +
                    decoded +
                    '\' which is HTML-encoded as \'' +
                    entity +
                    '\' in the file — the IF parser does not decode entities before parsing operators, so this expression will always evaluate false: ' +
                    raw +
                    '. Rewrite the condition using \'!=\' or \'=\' (which are not HTML-encoded). Example: instead of {#IF Field > 0}, use {#IF Field != 0}.',
                1
            );
        }
    }

    // -----------------------------------------------------------------------
    // 9. Nested IF blocks — findBalancedEnd cannot depth-track nested {#IF} on
    //    installs before v1.72.
    // -----------------------------------------------------------------------

    private static void checkNestedIfs(List<Pair> pairs, List<DocGenAiHtmlValidator.Finding> findings) {
        List<Pair> ifPairs = new List<Pair>();
        for (Pair p : pairs) {
            String rel = p.rel.trim().toUpperCase();
            if (rel == 'IF' || rel.startsWith('IF ')) {
                ifPairs.add(p);
            }
        }
        for (Integer i = 0; i < ifPairs.size(); i++) {
            for (Integer j = 0; j < ifPairs.size(); j++) {
                if (i == j) {
                    continue;
                }
                Pair ifOuter = ifPairs[i];
                Pair ifInner = ifPairs[j];
                if (
                    ifOuter.open.tag.xmlStart < ifInner.open.tag.xmlStart &&
                    ifOuter.close.xmlEnd > ifInner.close.xmlEnd
                ) {
                    addFinding(
                        findings,
                        'Nested IF blocks',
                        'IF block {#' +
                            ifInner.rel +
                            '} is nested inside IF block {#' +
                            ifOuter.rel +
                            '} — package versions before v1.72 cannot disambiguate nested IFs and will pair the inner {/IF} with the outer {#IF}, corrupting the parser state. Upgrade to v1.72+ to use nested IFs natively; for older installs, restructure to avoid nesting.',
                        1
                    );
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private static void addFinding(
        List<DocGenAiHtmlValidator.Finding> findings,
        String rule,
        String detail,
        Integer occurrences
    ) {
        findings.add(new DocGenAiHtmlValidator.Finding('warning', rule, occurrences, detail));
    }

    // -----------------------------------------------------------------------
    // Inner records
    // -----------------------------------------------------------------------

    private class RawTag {
        String raw;
        Integer visStart;
        Integer visEnd;
        Integer xmlStart;
        Integer xmlEnd;
    }

    private class Opener {
        RawTag tag;
        String rel;
        String key;
        String variant;
    }

    private class Pair {
        Opener open;
        RawTag close;
        String rel;
    }

    private class PairRow {
        Pair p;
        Integer[] row;

        PairRow(Pair p, Integer[] row) {
            this.p = p;
            this.row = row;
        }
    }

    private class PairResult {
        List<Pair> pairs = new List<Pair>();
        List<Opener> unmatchedOpens = new List<Opener>();
        List<RawTag> unmatchedCloses = new List<RawTag>();
    }

    private class VisibleStream {
        String text;
        List<Integer> xmlStarts = new List<Integer>();
        List<Integer> visibleStarts = new List<Integer>();
    }
}
