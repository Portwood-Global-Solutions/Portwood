/**
 * Coverage for multi-currency aggregate semantics.
 *
 * These assertions can't live in the e2e scripts: the behavior only engages in a
 * multi-currency org, and scratch/staging orgs are single-currency. `rateOverrideForTest`
 * stands in for the org's CurrencyType records, and it's @TestVisible private — reachable
 * from a test class, not from anonymous Apex.
 */
@IsTest
private class DocGenCurrencyTest {
    /** USD is corporate (1.0); EUR and GBP are quoted against it. */
    private static void stubRates() {
        DocGenCurrency.rateOverrideForTest = new Map<String, Decimal>{ 'USD' => 1.0, 'EUR' => 0.5, 'GBP' => 0.25 };
    }

    private static Map<String, Object> row(Decimal amount, String iso) {
        return new Map<String, Object>{ 'Amount' => amount, 'CurrencyIsoCode' => iso };
    }

    private static Map<String, Object> dataWith(List<Object> records) {
        return new Map<String, Object>{ 'Items' => new Map<String, Object>{ 'records' => records } };
    }

    @IsTest
    static void mixedCurrencyAggregateThrowsInsteadOfSummingSilently() {
        stubRates();
        Map<String, Object> data = dataWith(new List<Object>{ row(100, 'USD'), row(100, 'EUR') });

        Test.startTest();
        Boolean threw = false;
        String message = '';
        try {
            DocGenService.processXmlForTest('{SUM:Items.Amount:currency:USD}', data);
        } catch (Exception e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        System.assert(threw, 'Summing USD and EUR rows must not silently produce a number');
        System.assert(
            message.contains('Mixed currencies'),
            'Error should name the problem so the author can act on it. Got: ' + message
        );
        System.assert(message.contains('EUR') && message.contains('USD'), 'Error should list the codes: ' + message);
        System.assert(message.contains('convert'), 'Error should point at the fix: ' + message);
    }

    @IsTest
    static void singleCurrencyAggregateIsUnaffected() {
        stubRates();
        Map<String, Object> data = dataWith(new List<Object>{ row(100, 'EUR'), row(50, 'EUR') });

        Test.startTest();
        String result = DocGenService.processXmlForTest('{SUM:Items.Amount:currency:EUR}', data);
        Test.stopTest();

        System.assert(result.contains('150'), 'One currency across all rows still sums normally. Got: ' + result);
    }

    @IsTest
    static void rowsWithoutIsoCodesKeepLegacyBehavior() {
        stubRates();
        // No CurrencyIsoCode on the rows — the author's Query Config omits it. We can't know
        // what they are, so behavior must be exactly what it was before the guard existed.
        Map<String, Object> data = dataWith(
            new List<Object>{ new Map<String, Object>{ 'Amount' => 100 }, new Map<String, Object>{ 'Amount' => 25 } }
        );

        Test.startTest();
        String result = DocGenService.processXmlForTest('{SUM:Items.Amount:currency:EUR}', data);
        Test.stopTest();

        System.assert(result.contains('125'), 'Untagged rows must not start throwing. Got: ' + result);
    }

    @IsTest
    static void convertSuffixProducesGenuineTargetCurrencyTotal() {
        stubRates();
        // 100 USD → 50 EUR (rate 0.5), plus 100 EUR already in target = 150 EUR.
        Map<String, Object> data = dataWith(new List<Object>{ row(100, 'USD'), row(100, 'EUR') });

        Test.startTest();
        String result = DocGenService.processXmlForTest('{SUM:Items.Amount:currency:EUR:convert}', data);
        Test.stopTest();

        System.assert(result.contains('150'), 'Expected 100 USD + 100 EUR = 150 EUR. Got: ' + result);
        System.assert(
            !result.containsIgnoreCase('convert'),
            'The :convert suffix must not leak into output: ' + result
        );
    }

    @IsTest
    static void convertHandlesThreeWayCrossRateThroughCorporate() {
        stubRates();
        // 100 GBP (0.25) → 400 USD corporate → 200 EUR. Plus 100 EUR = 300 EUR.
        Map<String, Object> data = dataWith(new List<Object>{ row(100, 'GBP'), row(100, 'EUR') });

        Test.startTest();
        String result = DocGenService.processXmlForTest('{SUM:Items.Amount:currency:EUR:convert}', data);
        Test.stopTest();

        System.assert(result.contains('300'), 'Cross-rate should pivot through corporate. Got: ' + result);
    }

    @IsTest
    static void minMaxCompareConvertedAmountsNotRawNumbers() {
        stubRates();
        // 100 GBP is worth 400 USD; 200 USD is worth 200 USD. The larger raw number is the
        // smaller amount — comparing unconverted would pick the wrong row.
        Map<String, Object> data = dataWith(new List<Object>{ row(100, 'GBP'), row(200, 'USD') });

        Test.startTest();
        String maxResult = DocGenService.processXmlForTest('{MAX:Items.Amount:currency:USD:convert}', data);
        String minResult = DocGenService.processXmlForTest('{MIN:Items.Amount:currency:USD:convert}', data);
        Test.stopTest();

        System.assert(maxResult.contains('400'), 'MAX should be the 100 GBP row at 400 USD. Got: ' + maxResult);
        System.assert(minResult.contains('200'), 'MIN should be the 200 USD row. Got: ' + minResult);
    }

    @IsTest
    static void unknownRateFailsLoudlyRatherThanReturningUnconvertedNumber() {
        // JPY deliberately absent from the stubbed rate table.
        stubRates();
        Map<String, Object> data = dataWith(new List<Object>{ row(100, 'JPY'), row(100, 'EUR') });

        Test.startTest();
        Boolean threw = false;
        String message = '';
        try {
            DocGenService.processXmlForTest('{SUM:Items.Amount:currency:EUR:convert}', data);
        } catch (Exception e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        System.assert(threw, 'A missing rate must not degrade into an unconverted total');
        System.assert(message.contains('conversion rate'), 'Error should explain the gap. Got: ' + message);
    }

    @IsTest
    static void nonCurrencyAggregatesIgnoreCurrencyEntirely() {
        stubRates();
        // Mixed ISO codes, but the tag asks for a plain number — nothing to violate.
        Map<String, Object> data = dataWith(new List<Object>{ row(100, 'USD'), row(100, 'EUR') });

        Test.startTest();
        String result = DocGenService.processXmlForTest('{SUM:Items.Amount:number}', data);
        Test.stopTest();

        System.assert(result.contains('200'), 'A :number aggregate has no currency semantics. Got: ' + result);
    }

    @IsTest
    static void customCurrencyFieldIsHonoredByTheGuard() {
        stubRates();
        // Author uses an ERP currency field rather than the standard one, and says so via
        // the auto=Field form — the guard must read the same field the formatter does.
        Map<String, Object> data = dataWith(
            new List<Object>{
                new Map<String, Object>{ 'Amount' => 100, 'ErpCur__c' => 'USD' },
                new Map<String, Object>{ 'Amount' => 100, 'ErpCur__c' => 'EUR' }
            }
        );

        Test.startTest();
        Boolean threw = false;
        try {
            DocGenService.processXmlForTest('{SUM:Items.Amount:currency:auto=ErpCur__c}', data);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'The guard must follow auto=Field to the author’s own currency field');
    }

    @IsTest
    static void singleCurrencyOrgSkipsAllCurrencyMachinery() {
        // No rate override: isMultiCurrency() falls through to the real org, which is
        // single-currency under test. Even mixed-looking data must behave as before.
        DocGenCurrency.resetForTest();
        Map<String, Object> data = dataWith(new List<Object>{ row(100, 'USD'), row(100, 'EUR') });

        Test.startTest();
        String result = DocGenService.processXmlForTest('{SUM:Items.Amount:currency:EUR}', data);
        Test.stopTest();

        System.assert(result.contains('200'), 'Single-currency orgs keep the pre-existing behavior. Got: ' + result);
    }

    @IsTest
    static void formatSpecifierParsingHandlesEveryDocumentedShape() {
        System.assertEquals(true, DocGenCurrency.wantsConversion('currency:EUR:convert'), 'ISO + convert');
        System.assertEquals(true, DocGenCurrency.wantsConversion('currency:EUR:de_DE:CONVERT'), 'locale + convert');
        System.assertEquals(false, DocGenCurrency.wantsConversion('currency:EUR'), 'no convert segment');
        System.assertEquals(false, DocGenCurrency.wantsConversion('currency'), 'bare currency');
        System.assertEquals(false, DocGenCurrency.wantsConversion(null), 'null format');

        System.assertEquals('currency:EUR', DocGenCurrency.stripConvertSegment('currency:EUR:convert'), 'strip');
        System.assertEquals(
            'currency:EUR:de_DE',
            DocGenCurrency.stripConvertSegment('currency:EUR:de_DE:convert'),
            'strip keeps locale'
        );
        System.assertEquals('currency:EUR', DocGenCurrency.stripConvertSegment('currency:EUR'), 'strip is a no-op');

        System.assertEquals('EUR', DocGenCurrency.explicitTargetIso('currency:EUR:convert'), 'explicit ISO');
        System.assertEquals(null, DocGenCurrency.explicitTargetIso('currency:auto'), 'auto has no explicit ISO');
        System.assertEquals(null, DocGenCurrency.explicitTargetIso('currency:auto=X__c'), 'auto=Field either');
        System.assertEquals(null, DocGenCurrency.explicitTargetIso('number'), 'not a currency format');

        System.assertEquals(true, DocGenCurrency.isCurrencyFormat('currency:EUR'), 'currency detected');
        System.assertEquals(false, DocGenCurrency.isCurrencyFormat('number'), 'number is not currency');
        System.assertEquals(false, DocGenCurrency.isCurrencyFormat(null), 'null is not currency');
    }

    @IsTest
    static void isoLookupIsCaseInsensitiveAcrossSelectListCasing() {
        System.assertEquals(
            'EUR',
            DocGenCurrency.isoOfRow(new Map<String, Object>{ 'currencyisocode' => 'eur' }, null),
            'lowercase key and value both normalize'
        );
        System.assertEquals(
            null,
            DocGenCurrency.isoOfRow(new Map<String, Object>{ 'CurrencyIsoCode' => '' }, null),
            'blank reads as absent'
        );
        System.assertEquals(null, DocGenCurrency.isoOfRow(null, null), 'null row is safe');
    }

    @IsTest
    static void convertIsIdentityWhenSourceAndTargetMatch() {
        stubRates();
        System.assertEquals(100, DocGenCurrency.convert(100, 'EUR', 'EUR'), 'same currency is a no-op');
        System.assertEquals(100, DocGenCurrency.convert(100, null, 'EUR'), 'unknown source passes through');
        System.assertEquals(null, DocGenCurrency.convert(null, 'USD', 'EUR'), 'null amount stays null');
    }

    // ─── #297: :convert on a PLAIN field, not just aggregates ────────────────
    //
    // It worked on aggregates and nowhere else. On a plain field the segment
    // landed in the LOCALE slot: {Amount:currency:EUR:convert} parsed `convert`
    // as a locale name, failed to match one, and formatted with default
    // separators. The symbol changed to euro and the NUMBER did not move, so a
    // $100 record rendered as a euro figure that was wrong by the exchange rate,
    // in the currency it claimed to be in, with nothing to indicate it.
    //
    // Measured against main before the fix:
    //   {Amount:currency:EUR}          -> EUR100.00
    //   {Amount:currency:EUR:convert}  -> EUR100.00   <-- identical; convert did nothing
    //   {Amount:currency:auto:convert} -> $100.00

    private static String render(String tag, Map<String, Object> data) {
        return DocGenService.processXmlForTest('<p>' + tag + '</p>', data).replace('<p>', '').replace('</p>', '');
    }

    @IsTest
    static void convertOnAPlainFieldActuallyConverts() {
        stubRates(); // USD 1.0, EUR 0.5
        Map<String, Object> data = row(100, 'USD');
        Test.startTest();
        String withConvert = render('{Amount:currency:EUR:convert}', data);
        String without = render('{Amount:currency:EUR}', data);
        Test.stopTest();

        System.assert(withConvert.contains('50'), ':convert must apply the rate. Got: ' + withConvert);
        System.assert(without.contains('100'), 'without :convert the amount is untouched. Got: ' + without);
        System.assertNotEquals(
            without,
            withConvert,
            ':convert produced the same output as no convert — the segment was swallowed again'
        );
    }

    @IsTest
    static void convertComposesWithAnExplicitLocale() {
        stubRates();
        Test.startTest();
        String out = render('{Amount:currency:EUR:de_DE:convert}', row(100, 'USD'));
        Test.stopTest();
        System.assert(out.contains('50'), 'the rate applies with a locale present. Got: ' + out);
        System.assert(out.contains(','), 'and the German decimal separator survives. Got: ' + out);
    }

    @IsTest
    static void convertToTheRecordsOwnCurrencyIsANoOp() {
        stubRates();
        Test.startTest();
        String out = render('{Amount:currency:USD:convert}', row(100, 'USD'));
        Test.stopTest();
        System.assert(out.contains('100'), 'converting USD to USD must not move the number. Got: ' + out);
    }

    @IsTest
    static void convertWithNoSourceCurrencyLeavesTheAmountAlone() {
        stubRates();
        // No CurrencyIsoCode on the record: there is nothing to convert FROM, so
        // the amount must pass through rather than have a rate invented for it.
        Test.startTest();
        String out = render('{Amount:currency:EUR:convert}', new Map<String, Object>{ 'Amount' => 100 });
        Test.stopTest();
        System.assert(out.contains('100'), 'no source currency means no conversion. Got: ' + out);
    }

    @IsTest
    static void plainCurrencyFormsAreUnaffected() {
        stubRates();
        Test.startTest();
        Map<String, Object> data = row(100, 'USD');
        System.assert(render('{Amount:currency}', data).contains('100'), 'bare :currency unchanged');
        System.assert(render('{Amount:currency:EUR}', data).contains('100'), 'ISO with no convert unchanged');
        System.assert(render('{Amount:currency:EUR:de_DE}', data).contains('100'), 'ISO + locale unchanged');
        Test.stopTest();
    }
}
