/**
 * Plans the physical placements of top-level giant query loops in one template.
 * A placement owns its authored row markup and ordinal independently of the query
 * alias supplying rows, so one query can feed more than one placement.
 */
public with sharing class DocGenGiantQueryPlan {
    private static final String MARKER_PREFIX = '<!--docgen-giant-slot-';
    private static final String MARKER_SUFFIX = '-->';

    public class Slot {
        public final Integer ordinal;
        public final String key;
        public final String queryKey;
        public final String innerXml;
        public final String marker;
        public final Integer startOffset;
        public final Integer endOffset;

        public Slot(Integer ordinal, String queryKey, String innerXml, Integer startOffset, Integer endOffset) {
            this.ordinal = ordinal;
            this.key = String.valueOf(ordinal).leftPad(5, '0');
            this.queryKey = queryKey;
            this.innerXml = innerXml;
            this.marker = MARKER_PREFIX + key + MARKER_SUFFIX;
            this.startOffset = startOffset;
            this.endOffset = endOffset;
        }
    }

    private class OpenTag {
        public final String closingKey;
        public final Boolean isQuery;
        public final Integer startOffset;
        public final Integer endOffset;

        public OpenTag(String closingKey, Boolean isQuery, Integer startOffset, Integer endOffset) {
            this.closingKey = closingKey;
            this.isQuery = isQuery;
            this.startOffset = startOffset;
            this.endOffset = endOffset;
        }
    }

    public final String shell;
    public final List<Slot> slots;
    public final Set<String> nestedQueryKeys;

    private DocGenGiantQueryPlan(String shell, List<Slot> slots, Set<String> nestedQueryKeys) {
        this.shell = shell;
        this.slots = slots;
        this.nestedQueryKeys = nestedQueryKeys;
    }

    public static DocGenGiantQueryPlan compile(String template, Set<String> queryKeys) {
        return compile(template, queryKeys, false);
    }

    public static DocGenGiantQueryPlan compileGrouped(
        String template,
        Set<String> queryKeys,
        Map<String, Object> rootData
    ) {
        DocGenGiantQueryPlan plan = compile(template, queryKeys, true);
        String mergedShell = DocGenService.mergeGiantHtml(plan.shell, rootData, null);
        List<Slot> visibleSlots = new List<Slot>();
        for (Slot slot : plan.slots) {
            if (mergedShell.contains(slot.marker)) {
                visibleSlots.add(slot);
            }
        }
        return new DocGenGiantQueryPlan(mergedShell, visibleSlots, plan.nestedQueryKeys);
    }

    private static DocGenGiantQueryPlan compile(String template, Set<String> queryKeys, Boolean allowRootConditions) {
        String normalized = DocGenService.normalizeGiantQueryTemplate(template);
        List<Slot> slots = new List<Slot>();
        Set<String> nestedQueryKeys = new Set<String>();
        if (String.isBlank(normalized) || queryKeys == null || queryKeys.isEmpty()) {
            return new DocGenGiantQueryPlan(normalized, slots, nestedQueryKeys);
        }
        if (normalized.contains(MARKER_PREFIX)) {
            throw new DocGenException('Template already contains a reserved giant query slot marker.');
        }

        List<OpenTag> stack = new List<OpenTag>();
        List<String> shellParts = new List<String>();
        Integer writtenThrough = 0;
        Integer nextOffset = 0;
        while (nextOffset < normalized.length()) {
            Integer brace = normalized.indexOf('{', nextOffset);
            if (brace == -1) {
                break;
            }
            Integer marker = skipWhitespace(normalized, brace + 1);
            if (marker >= normalized.length()) {
                break;
            }
            String sigil = normalized.substring(marker, marker + 1);
            nextOffset = marker + 1;
            if (sigil != '#' && sigil != '/' && sigil != '^' && sigil != '~') {
                // Keep scanning inside non-tag braces, such as a CSS or JS block.
                nextOffset = brace + 1;
                continue;
            }
            Integer closingBrace = normalized.indexOf('}', nextOffset);
            if (closingBrace == -1) {
                break;
            }
            Integer nestedBrace = normalized.indexOf('{', nextOffset);
            if (nestedBrace != -1 && nestedBrace < closingBrace) {
                nextOffset = nestedBrace;
                continue;
            }
            String key = normalized.substring(nextOffset, closingBrace).trim();
            nextOffset = closingBrace + 1;
            if (String.isBlank(key)) {
                continue;
            }
            if (sigil != '/') {
                Boolean isQuery = sigil == '#' && queryKeys.contains(key);
                stack.add(new OpenTag(sectionClosingKey(key), isQuery, brace, nextOffset));
                continue;
            }
            if (stack.isEmpty() || !stack[stack.size() - 1].closingKey.equals(key)) {
                continue;
            }
            OpenTag open = stack.remove(stack.size() - 1);
            if (!open.isQuery) {
                continue;
            }
            if (!stack.isEmpty() && (!allowRootConditions || containsQuerySection(stack))) {
                nestedQueryKeys.add(open.closingKey);
                continue;
            }
            Slot slot = buildSlot(normalized, open, brace, nextOffset, slots.size());
            if (slot.startOffset < writtenThrough) {
                throw new DocGenException('Giant query loop placements overlap in the template.');
            }
            slots.add(slot);
            shellParts.add(normalized.substring(writtenThrough, slot.startOffset));
            shellParts.add(slot.marker);
            writtenThrough = slot.endOffset;
        }

        for (OpenTag unclosed : stack) {
            if (unclosed.isQuery) {
                throw new DocGenException('Missing closing tag for giant query loop ' + unclosed.closingKey + '.');
            }
        }
        shellParts.add(normalized.substring(writtenThrough));
        return new DocGenGiantQueryPlan(String.join(shellParts, ''), slots, nestedQueryKeys);
    }

    public String fill(Map<String, String> rowsBySlot) {
        return fill(shell, rowsBySlot);
    }

    /** Inserts fragments after any parent-field resolution or HTML wrapping of the shell. */
    public String fill(String formattedShell, Map<String, String> rowsBySlot) {
        if (slots.isEmpty()) {
            return formattedShell;
        }
        List<String> parts = new List<String>();
        Integer cursor = 0;
        for (Slot slot : slots) {
            if (rowsBySlot == null || !rowsBySlot.containsKey(slot.key)) {
                throw new DocGenException('Missing rows for giant query slot ' + slot.key + '.');
            }
            Integer start = formattedShell == null ? -1 : formattedShell.indexOf(MARKER_PREFIX, cursor);
            Integer markerEnd = start + slot.marker.length();
            if (
                start == -1 ||
                markerEnd > formattedShell.length() ||
                !formattedShell.substring(start, markerEnd).equals(slot.marker)
            ) {
                throw new DocGenException('Missing, duplicated, or reordered giant query slot ' + slot.key + '.');
            }
            parts.add(formattedShell.substring(cursor, start));
            String rows = rowsBySlot.get(slot.key);
            parts.add(rows == null ? '' : rows);
            cursor = markerEnd;
        }
        if (formattedShell.indexOf(MARKER_PREFIX, cursor) != -1) {
            throw new DocGenException('Unexpected giant query slot marker in the formatted shell.');
        }
        parts.add(formattedShell.substring(cursor));
        return String.join(parts, '');
    }

    private static Slot buildSlot(String xml, OpenTag open, Integer closeStart, Integer closeEnd, Integer ordinal) {
        List<Integer> bounds = DocGenService.giantQueryLoopContainer(xml, open.startOffset, closeEnd);
        Integer start = bounds[0];
        Integer finish = bounds[1];
        // Multiple independent loops may share a row. Preserve the row and the
        // intervening cells if one loop cannot own the whole row safely.
        if (hasSectionMarker(xml, start, open.startOffset) || hasSectionMarker(xml, closeEnd, finish)) {
            start = open.startOffset;
            finish = closeEnd;
        }
        String innerXml =
            xml.substring(start, open.startOffset) +
            xml.substring(open.endOffset, closeStart) +
            xml.substring(closeEnd, finish);
        return new Slot(ordinal, open.closingKey, innerXml, start, finish);
    }

    private static Boolean containsQuerySection(List<OpenTag> stack) {
        for (OpenTag tag : stack) {
            if (tag.isQuery) {
                return true;
            }
        }
        return false;
    }

    private static Boolean hasSectionMarker(String text, Integer start, Integer finish) {
        Integer brace = text.indexOf('{', start);
        while (brace != -1 && brace < finish) {
            Integer marker = skipWhitespace(text, brace + 1);
            if (marker < finish) {
                String sigil = text.substring(marker, marker + 1);
                if (sigil == '#' || sigil == '/' || sigil == '^' || sigil == '~') {
                    return true;
                }
            }
            brace = text.indexOf('{', brace + 1);
        }
        return false;
    }

    private static Integer skipWhitespace(String text, Integer offset) {
        while (offset < text.length()) {
            Integer code = text.charAt(offset);
            if (code != 32 && (code < 9 || code > 13)) {
                break;
            }
            offset++;
        }
        return offset;
    }

    private static String sectionClosingKey(String key) {
        if (key.startsWithIgnoreCase('IF ')) {
            return 'IF';
        }
        if (key.startsWithIgnoreCase('GroupBy ')) {
            return 'GroupBy';
        }
        if (key.startsWithIgnoreCase('ChartBucket:')) {
            return 'ChartBucket';
        }
        return key;
    }
}
