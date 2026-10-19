/**
 * Multi-currency support for merge-tag aggregates.
 *
 * Two responsibilities, both driven off the same `{…:currency:…}` format specifier
 * the formatter already parses:
 *
 *  1. **Mixed-currency detection.** `{SUM:Lines.Amount:currency:EUR}` over child rows
 *     that carry different CurrencyIsoCode values used to add the raw numbers and stamp
 *     a euro sign on the result — a silently wrong total. `assertSingleCurrency` makes
 *     that case throw instead.
 *
 *  2. **Conversion.** A trailing `:convert` segment converts every row into the target
 *     currency before aggregating, so `{SUM:Lines.Amount:currency:EUR:convert}` gives a
 *     genuine euro total from mixed-currency lines.
 *
 * Rates come from the org's `CurrencyType` records (static conversion rates), read once
 * per transaction. Advanced Currency Management's dated rates (`DatedConversionRate`) are
 * NOT consulted — see the class-level note on `getRates()`.
 *
 * Everything here is a no-op in single-currency orgs: `CurrencyType` isn't queryable and
 * `CurrencyIsoCode` doesn't exist, so callers keep their pre-existing behavior exactly.
 */
public with sharing class DocGenCurrency {
    /** Trailing format segment that opts a tag into rate conversion. */
    private static final String CONVERT_SEGMENT = 'convert';

    /** ISO → static conversion rate, relative to the org's corporate currency. */
    private static Map<String, Decimal> rateCache;

    /** Set once the CurrencyType read has been attempted, successful or not. */
    private static Boolean ratesLoaded = false;

    @TestVisible
    private static Map<String, Decimal> rateOverrideForTest;

    /**
     * True when the running org has multi-currency enabled. Every guard in this class
     * short-circuits on this, so single-currency orgs never pay a query or change behavior.
     */
    public static Boolean isMultiCurrency() {
        return rateOverrideForTest != null || UserInfo.isMultiCurrencyOrganization();
    }

    /**
     * Reads active `CurrencyType` rates once per transaction.
     *
     * Salesforce stores a static rate per currency, expressed against the corporate
     * currency (corporate itself is always 1.0). Converting between two non-corporate
     * currencies therefore goes through corporate as the pivot — see `convert()`.
     *
     * Advanced Currency Management orgs additionally keep `DatedConversionRate` records
     * for period-specific rates on opportunity-family objects. Honoring those needs an
     * as-of date per row, which the merge engine doesn't carry — a template summing
     * historical rows would need the row's own close date, not today's rate. Until that
     * plumbing exists this deliberately uses the static rate and documents the limit
     * rather than silently applying today's rate to last year's numbers.
     *
     * Returns an empty map (never null) in single-currency orgs or if the read fails.
     */
    public static Map<String, Decimal> getRates() {
        if (rateOverrideForTest != null) {
            return rateOverrideForTest;
        }
        if (ratesLoaded) {
            return rateCache;
        }
        ratesLoaded = true;
        rateCache = new Map<String, Decimal>();
        if (!UserInfo.isMultiCurrencyOrganization()) {
            return rateCache;
        }
        try {
            // Dynamic SOQL: CurrencyType is not queryable in single-currency orgs, and a
            // static query would fail to compile the package there.
            for (
                SObject ct : Database.query(
                    DocGenSignatureIpContext.publicQuery(
                        'SELECT IsoCode, ConversionRate FROM CurrencyType WHERE IsActive = true WITH SYSTEM_MODE'
                    )
                )
            ) {
                Object iso = ct.get('IsoCode');
                Object rate = ct.get('ConversionRate');
                if (iso != null && rate != null) {
                    rateCache.put(String.valueOf(iso).toUpperCase(), (Decimal) rate);
                }
            }
        } catch (Exception e) {
            // Non-fatal: without rates, `:convert` reports an actionable error and the
            // mixed-currency guard still fires. Never silently produce a wrong total.
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock
        }
        return rateCache;
    }

    /**
     * Converts `amount` from `fromIso` to `toIso` using static CurrencyType rates,
     * pivoting through the corporate currency. Returns `amount` unchanged when the two
     * codes match. Throws DocGenException when either rate is unknown — a missing rate
     * must never degrade into "return the unconverted number", which is the exact silent
     * corruption this class exists to prevent.
     */
    public static Decimal convert(Decimal amount, String fromIso, String toIso) {
        if (amount == null) {
            return null;
        }
        String src = fromIso == null ? null : fromIso.trim().toUpperCase();
        String dst = toIso == null ? null : toIso.trim().toUpperCase();
        if (String.isBlank(src) || String.isBlank(dst) || src == dst) {
            return amount;
        }
        Map<String, Decimal> rates = getRates();
        Decimal srcRate = rates.get(src);
        Decimal dstRate = rates.get(dst);
        if (srcRate == null || srcRate == 0 || dstRate == null) {
            throw new DocGenException(
                'Cannot convert ' +
                    src +
                    ' to ' +
                    dst +
                    ': no active conversion rate found. ' +
                    'Add both currencies under Setup → Manage Currencies, or drop the ":convert" ' +
                    'suffix to format without converting.'
            );
        }
        // Corporate-pivot: value / srcRate lands in corporate currency, * dstRate lands in target.
        return (amount / srcRate) * dstRate;
    }

    /**
     * True when `fmt` ends with the `:convert` segment, e.g. `currency:EUR:convert`
     * or `currency:EUR:de_DE:convert`. Case-insensitive.
     */
    public static Boolean wantsConversion(String fmt) {
        if (String.isBlank(fmt)) {
            return false;
        }
        List<String> segs = fmt.trim().split(':');
        return segs.size() >= 3 && segs[segs.size() - 1].trim().equalsIgnoreCase(CONVERT_SEGMENT);
    }

    /**
     * Strips the trailing `:convert` segment so the resulting specifier can be handed to
     * the existing formatter unchanged. Returns `fmt` untouched when absent.
     */
    public static String stripConvertSegment(String fmt) {
        if (!wantsConversion(fmt)) {
            return fmt;
        }
        List<String> segs = fmt.trim().split(':');
        segs.remove(segs.size() - 1);
        return String.join(segs, ':');
    }

    /**
     * True when `fmt` is a currency specifier at all (`currency`, `currency:EUR`,
     * `currency:auto`, …). Used to decide whether currency-consistency even applies —
     * a `{SUM:…:number}` tag has no currency semantics to violate.
     */
    public static Boolean isCurrencyFormat(String fmt) {
        if (String.isBlank(fmt)) {
            return false;
        }
        return fmt.trim().split(':')[0].trim().equalsIgnoreCase('currency');
    }

    /**
     * Returns the explicit target ISO from a currency specifier, or null when the tag
     * uses the bare/`auto` forms (which take their code from the record rather than
     * naming one). `currency:EUR:de_DE:convert` → `EUR`.
     */
    public static String explicitTargetIso(String fmt) {
        if (!isCurrencyFormat(fmt)) {
            return null;
        }
        List<String> segs = fmt.trim().split(':');
        if (segs.size() < 2) {
            return null;
        }
        String spec = segs[1].trim();
        String lower = spec.toLowerCase();
        if (lower == 'auto' || lower.startsWith('auto=')) {
            return null;
        }
        return spec.toUpperCase();
    }

    /**
     * Reads the currency ISO code off one child row. Mirrors the case-insensitive lookup
     * the formatter uses for `{…:currency:auto}` — SOQL select-list casing isn't guaranteed.
     * Returns null when the row carries no code (single-currency org, or the author's
     * Query Config omits the field).
     */
    public static String isoOfRow(Map<String, Object> row, String sourceField) {
        if (row == null) {
            return null;
        }
        String target = String.isBlank(sourceField) ? 'CurrencyIsoCode' : sourceField.trim();
        for (String k : row.keySet()) {
            if (k.equalsIgnoreCase(target)) {
                Object v = row.get(k);
                String iso = v == null ? null : String.valueOf(v).trim();
                return String.isBlank(iso) ? null : iso.toUpperCase();
            }
        }
        return null;
    }

    /**
     * Guards an aggregate against silently summing across currencies.
     *
     * Fires only when we can *prove* a conflict — more than one distinct ISO code among
     * the rows actually being aggregated. A single code, no codes at all (the field isn't
     * in the query), or a single-currency org all pass through untouched, so this can
     * never false-positive on an existing template.
     *
     * @param isoCodes distinct ISO codes seen across the aggregated rows
     * @param tag      the merge tag being resolved, quoted back to the author
     */
    public static void assertSingleCurrency(Set<String> isoCodes, String tag) {
        if (isoCodes == null || isoCodes.size() <= 1) {
            return;
        }
        List<String> sorted = new List<String>(isoCodes);
        sorted.sort();
        throw new DocGenException(
            'Mixed currencies in aggregate {' +
                tag +
                '}: the rows being totalled use ' +
                String.join(sorted, ', ') +
                '. Adding them together would produce a meaningless number. ' +
                'Append ":convert" to convert every row into the target currency first ' +
                '(e.g. {' +
                tag +
                ':convert}), or aggregate each currency separately.'
        );
    }

    /** Test seam — clears the per-transaction rate cache between assertions. */
    @TestVisible
    private static void resetForTest() {
        rateCache = null;
        ratesLoaded = false;
        rateOverrideForTest = null;
    }
}
