/** Running grand totals for the already-filtered rows of a grouped Giant Query PDF. */
public with sharing class DocGenGiantQueryTotals {
    private Map<String, String> datasetKeys = new Map<String, String>();
    private Map<String, Map<String, Column>> columnsByDataset = new Map<String, Map<String, Column>>();
    private Boolean finished = false;

    public DocGenGiantQueryTotals(Set<String> keys) {
        for (String key : keys) {
            datasetKeys.put(key.toLowerCase(), key);
        }
    }

    /** The planner sees only tags in visible sections of the authored shell. */
    public String resolve(String tag, Map<String, Object> root) {
        String fn = tag.substringBefore(':').trim().toUpperCase();
        String argument = tag.substringAfter(':').trim();
        Integer formatAt = argument.indexOf(':');
        String fmt = formatAt < 0 ? null : argument.substring(formatAt + 1).trim();
        String path = formatAt < 0 ? argument : argument.substring(0, formatAt).trim();
        Integer fieldAt = path.indexOf('.');
        String dataset = fieldAt < 0 ? path : path.substring(0, fieldAt);
        String field = fieldAt < 0 ? null : path.substring(fieldAt + 1);
        String key = datasetKeys.get(dataset.toLowerCase());
        if (key == null || (field == null && fn != 'COUNT')) {
            return null;
        }
        String isoField;
        if (DocGenCurrency.isCurrencyFormat(fmt) && DocGenCurrency.isMultiCurrency()) {
            isoField = DocGenService.currencyIsoSourceField(fmt) ?? 'CurrencyIsoCode';
        }
        String columnKey = (field ?? '').toLowerCase() + '|' + (isoField ?? '').toLowerCase();
        Map<String, Column> columns = columnsByDataset.get(key);
        if (finished) {
            Column column = columns?.get(columnKey);
            if (column == null) {
                throw new DocGenException('Giant Query totals changed during generation. Generate the document again.');
            }
            return column.result(fn, fmt, tag, root);
        }
        if (columns == null) {
            columns = new Map<String, Column>();
            columnsByDataset.put(key, columns);
        }
        if (!columns.containsKey(columnKey)) {
            columns.put(columnKey, new Column(field, isoField));
        }
        return '{' + tag + '}';
    }

    public Set<String> datasets() {
        return columnsByDataset.keySet();
    }

    public void addRow(String dataset, Map<String, Object> row) {
        Map<String, Column> columns = columnsByDataset.get(dataset);
        if (columns != null) {
            for (Column column : columns.values()) {
                column.addRow(row);
            }
        }
    }

    public void finish() {
        finished = true;
    }

    /** SUM, AVG, MIN, MAX and numeric COUNT share one pass over a field path. */
    private class Column {
        private List<String> path;
        private String isoField;
        private Integer listRows = 0;
        private Map<String, Stats> byCurrency = new Map<String, Stats>();

        Column(String field, String isoField) {
            this.path = field == null ? new List<String>() : field.split('\\.');
            this.isoField = isoField;
        }

        void addRow(Map<String, Object> row) {
            if (path.isEmpty()) {
                listRows++;
            } else {
                visit(row, 0, row);
            }
        }

        private void visit(Map<String, Object> row, Integer index, Map<String, Object> currencyRow) {
            Object value = fieldValue(row, path[index]);
            Boolean last = index + 1 == path.size();
            Map<String, Object> childMap = value instanceof Map<String, Object> ? (Map<String, Object>) value : null;
            Object rows = childMap == null ? value : childMap.get('records');
            // A query-result wrapper also has scalar fields such as totalSize.
            if (
                !last &&
                rows instanceof List<Object> &&
                childMap != null &&
                fieldValue(childMap, path[index + 1]) != null
            ) {
                visit(childMap, index + 1, currencyRow);
            } else if (rows instanceof List<Object>) {
                List<Object> children = (List<Object>) rows;
                if (last) {
                    listRows += children.size();
                } else {
                    for (Object item : children) {
                        if (item instanceof Map<String, Object>) {
                            Map<String, Object> child = (Map<String, Object>) item;
                            visit(child, index + 1, child);
                        }
                    }
                }
            } else if (!last && childMap != null) {
                visit(childMap, index + 1, currencyRow);
            } else if (last && value != null && childMap == null) {
                Decimal amount;
                try {
                    amount = Decimal.valueOf(String.valueOf(value));
                } catch (TypeException nonNumeric) {
                    return;
                }
                String iso = isoField == null ? '' : (DocGenCurrency.isoOfRow(currencyRow, isoField) ?? '');
                if (!byCurrency.containsKey(iso)) {
                    byCurrency.put(iso, new Stats());
                }
                byCurrency.get(iso).add(amount);
            }
        }

        String result(String fn, String fmt, String tag, Map<String, Object> root) {
            Set<String> known = byCurrency.keySet().clone();
            known.remove('');
            String parentIso = DocGenCurrency.isoOfRow(root, DocGenService.currencyIsoSourceField(fmt));
            String targetIso;
            if (known.size() > 1 && !DocGenCurrency.wantsConversion(fmt)) {
                DocGenCurrency.assertSingleCurrency(known, tag);
            }
            if (!known.isEmpty() && DocGenCurrency.wantsConversion(fmt)) {
                targetIso = DocGenCurrency.explicitTargetIso(fmt) ?? parentIso;
                if (String.isBlank(targetIso)) {
                    throw new DocGenException('Cannot convert {' + tag + '}: specify a target currency.');
                }
            }
            Decimal amount;
            Integer numericCount = 0;
            for (String iso : byCurrency.keySet()) {
                Stats stats = byCurrency.get(iso);
                numericCount += stats.count;
                Decimal part = fn == 'MIN' ? stats.low : (fn == 'MAX' ? stats.high : stats.total);
                if (targetIso != null && iso != '' && fn != 'COUNT') {
                    part = DocGenCurrency.convert(part, iso, targetIso);
                }
                if (amount == null) {
                    amount = part;
                } else if (fn == 'MIN') {
                    amount = Math.min(amount, part);
                } else if (fn == 'MAX') {
                    amount = Math.max(amount, part);
                } else {
                    amount += part;
                }
            }
            if (fn == 'COUNT') {
                amount = numericCount + listRows;
            } else if (fn == 'SUM' && amount == null) {
                amount = 0;
            } else if (fn == 'AVG' && numericCount > 0) {
                amount = amount.divide(numericCount, 2, RoundingMode.HALF_UP);
            }
            if (amount != null && String.isBlank(fmt)) {
                return amount.stripTrailingZeros().toPlainString();
            }
            return DocGenService.formatAggregateValue(amount, DocGenCurrency.stripConvertSegment(fmt), parentIso);
        }
    }

    private class Stats {
        Integer count = 0;
        Decimal total = 0;
        Decimal low;
        Decimal high;

        void add(Decimal amount) {
            count++;
            total += amount;
            low = low == null ? amount : Math.min(low, amount);
            high = high == null ? amount : Math.max(high, amount);
        }
    }

    private static Object fieldValue(Map<String, Object> row, String name) {
        if (row.containsKey(name)) {
            return row.get(name);
        }
        for (String key : row.keySet()) {
            if (key.equalsIgnoreCase(name)) {
                return row.get(key);
            }
        }
        return null;
    }
}
