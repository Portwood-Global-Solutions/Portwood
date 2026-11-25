@IsTest
private class DocGenGiantQueryTotalsTest {
    private static String footer(String path) {
        return '{SUM:' +
            path +
            '.Amount:currency} / {AVG:' +
            path +
            '.Amount:currency} / {MIN:' +
            path +
            '.Amount} / {MAX:' +
            path +
            '.Amount} / {COUNT:' +
            path +
            '} / {COUNT:' +
            path +
            '.Amount}';
    }

    @IsTest
    static void filteredGrandTotalsMatchDatabaseAcrossPagesAndRepeatedPlacements() {
        Account root = new Account(Name = 'Statement');
        Account other = new Account(Name = 'Separate statement');
        insert new List<Account>{ root, other };
        List<Account> groups = new List<Account>{
            new Account(Name = 'A', ParentId = root.Id),
            new Account(Name = 'B', ParentId = root.Id),
            new Account(Name = 'C', ParentId = root.Id),
            new Account(Name = 'D', ParentId = other.Id)
        };
        insert groups;
        String paid = [SELECT MasterLabel FROM OpportunityStage WHERE IsActive = TRUE AND IsWon = TRUE LIMIT 1]
        .MasterLabel;
        String unpaid = [SELECT MasterLabel FROM OpportunityStage WHERE IsActive = TRUE AND IsClosed = FALSE LIMIT 1]
        .MasterLabel;
        Date first = Date.newInstance(2026, 1, 1), last = Date.newInstance(2026, 12, 31);
        insert new List<Opportunity>{
            payment(groups[0], '1', paid, first, 10),
            payment(groups[0], '2', paid, last, 20),
            payment(groups[0], '3', paid, first, null),
            payment(groups[1], '4', paid, last, 90),
            payment(groups[2], '5', paid, first.addDays(-1), 400),
            payment(groups[2], '6', paid, last.addDays(1), 500),
            payment(groups[2], '7', unpaid, first, 600),
            payment(groups[3], '8', paid, first, 900)
        };
        String groupRelationship;
        for (Schema.ChildRelationship cr : Account.SObjectType.getDescribe().getChildRelationships()) {
            if (cr.getChildSObject() == Account.SObjectType && cr.getField() == Account.ParentId) {
                groupRelationship = cr.getRelationshipName();
                break;
            }
        }
        String config =
            'Name, (SELECT Name, (SELECT Amount FROM Opportunities WHERE IsWon = true AND CloseDate >= 2026-01-01 AND CloseDate <= 2026-12-31 ORDER BY Name) FROM ' +
            groupRelationship +
            ' ORDER BY Name)';
        String detail =
            '{#' +
            groupRelationship +
            '}<p>{Name}</p>{#Opportunities}<p>{Amount}</p>{/Opportunities}{/' +
            groupRelationship +
            '}';
        String tags = footer(groupRelationship + '.Opportunities');
        String body = detail + detail + tags;
        Map<String, Map<String, Object>> nodes = new Map<String, Map<String, Object>>();
        Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(root.Id, config, nodes);
        Assert.areEqual(3, counts.get(groupRelationship));
        Assert.areEqual(7, nodes.get(groupRelationship).get('rowsIncludingChildren'));
        DocGenGiantQueryRouter.Settings settings = new DocGenGiantQueryRouter.Settings(
            new DocGen_Template__c(Giant_Query_Row_Threshold__c = 5)
        );
        DocGenGiantQueryRouter.Decision route = DocGenGiantQueryRouter.decide(root.Id, config, 'PDF', settings);
        Assert.areEqual(true, route.useGiantPath);
        Assert.areEqual(groupRelationship, route.giantRelationship);
        DocGen_Template__c word = new DocGen_Template__c(
            Name = 'Nested native check',
            Type__c = 'Word',
            Base_Object_API__c = 'Account',
            Query_Config__c = config
        );
        insert word;
        try {
            DocGenService.generateDocumentPartsGiantQuery(word.Id, root.Id, groupRelationship);
            Assert.fail('Native Word must identify the unsupported grouped table.');
        } catch (DocGenException e) {
            Assert.isTrue(e.getMessage().contains('Choose PDF'), e.getMessage());
        }
        DocGenGiantQueryMulti.Run run = DocGenGiantQueryMulti.plan(body, config, root.Id);
        Assert.areEqual(2, run.slots.size());
        Assert.areEqual(1, run.datasets.size());
        DocGenGiantQueryMulti.Dataset dataset = run.datasets[0];
        Database.Cursor cursor = DocGenDataRetriever.openGiantQueryCursor(root.Id, dataset.childNode, dataset.fields);
        Assert.areEqual(3, cursor.getNumRecords());
        for (Integer i = 0; i < cursor.getNumRecords(); i++) {
            SObject row = cursor.fetch(i, 1)[0];
            run.groupedTotals.addRow(
                groupRelationship,
                DocGenDataRetriever.loadGiantGroup(root.Id, dataset.nestedQuery, row)
            );
        }
        run.groupedTotals.finish();
        AggregateResult truth = [
            SELECT
                SUM(Amount) total,
                AVG(Amount) mean,
                MIN(Amount) smallest,
                MAX(Amount) largest,
                COUNT(Id) matched,
                COUNT(Amount) numeric
            FROM Opportunity
            WHERE Account.ParentId = :root.Id AND IsWon = TRUE AND CloseDate >= :first AND CloseDate <= :last
        ];
        String expected = String.join(
            new List<String>{
                DocGenService.formatAggregateValue((Decimal) truth.get('total'), 'currency'),
                DocGenService.formatAggregateValue((Decimal) truth.get('mean'), 'currency'),
                ((Decimal) truth.get('smallest')).stripTrailingZeros().toPlainString(),
                ((Decimal) truth.get('largest')).stripTrailingZeros().toPlainString(),
                String.valueOf(truth.get('matched')),
                String.valueOf(truth.get('numeric'))
            },
            ' / '
        );
        Assert.areEqual('$120.00 / $40.00 / 10 / 90 / 4 / 3', expected);
        DocGenGiantQueryPlan assembled = DocGenGiantQueryPlan.compileGrouped(
            body,
            new Set<String>{ groupRelationship },
            new Map<String, Object>{ 'Name' => root.Name },
            false,
            run.groupedTotals
        );
        Assert.areEqual(run.slots[0].marker + run.slots[1].marker + expected, assembled.shell);
    }

    private static Opportunity payment(Account groupRecord, String name, String stage, Date day, Decimal amount) {
        return new Opportunity(
            AccountId = groupRecord.Id,
            Name = name,
            StageName = stage,
            CloseDate = day,
            Amount = amount
        );
    }

    @IsTest
    static void deepRowsEmptyRowsScalarLookupsAndHiddenTables() {
        Map<String, Object> root = new Map<String, Object>{ 'Name' => 'Parent' };
        DocGenGiantQueryTotals totals = new DocGenGiantQueryTotals(new Set<String>{ 'Groups', 'Hidden' });
        String ref = 'Groups.Sections.Lines__r';
        String body =
            '{#ShowTable}{#Groups}<p>{Name}</p>{/Groups}{/ShowTable}' +
            '{#ShowTable}{SUM:Hidden.Amount}{/ShowTable}' +
            footer(ref) +
            ' / {sum:groups.Sections.Lines__r.Product.Price} / {SUM:Groups.Sections.Lines__r.TOTALSIZE}';
        Map<String, Object> line = new Map<String, Object>{
            'Amount' => -12,
            'Product' => new Map<String, Object>{ 'Price' => 15 }
        };
        Map<String, Object> section = new Map<String, Object>{
            'Lines__r' => new Map<String, Object>{
                'records' => new List<Object>{
                    line,
                    new Map<String, Object>{ 'Amount' => 'n/a' },
                    new Map<String, Object>()
                },
                'totalSize' => 3
            }
        };
        DocGenGiantQueryPlan planned = DocGenGiantQueryPlan.compileGrouped(
            body,
            new Set<String>{ 'Groups', 'Hidden' },
            root,
            false,
            totals
        );
        Assert.areEqual(0, planned.slots.size());
        Assert.areEqual(new Set<String>{ 'Groups' }, totals.datasets());
        totals.addRow('Groups', new Map<String, Object>{ 'Sections' => new List<Object>{ section } });
        totals.addRow('Groups', new Map<String, Object>{ 'Amount' => 999, 'Sections' => new List<Object>() });
        totals.finish();
        Assert.areEqual(
            '-$12.00 / -$12.00 / -12 / -12 / 3 / 1 / 15 / 3',
            DocGenGiantQueryPlan.compileGrouped(body, new Set<String>{ 'Groups', 'Hidden' }, root, false, totals).shell
        );
        DocGenGiantQueryTotals empty = new DocGenGiantQueryTotals(new Set<String>{ 'Groups' });
        DocGenService.mergeGroupedGiantShell(footer(ref), root, empty);
        empty.finish();
        Assert.areEqual('$0.00 / 0 / 0 / 0 / 0 / 0', DocGenService.mergeGroupedGiantShell(footer(ref), root, empty));
    }

    @IsTest
    static void currencySemanticsSpanGroupsAndUseTheLeafRecord() {
        DocGenCurrency.rateOverrideForTest = new Map<String, Decimal>{ 'USD' => 1, 'EUR' => 0.5 };
        Map<String, Object> root = new Map<String, Object>{ 'HomeISO' => 'USD' };
        String path = 'Groups.Lines.Amount';
        String fmt = ':currency:auto=HomeISO:convert}';
        String converted =
            '{SUM:' +
            path +
            fmt +
            ' / {AVG:' +
            path +
            fmt +
            ' / {MIN:' +
            path +
            fmt +
            ' / {MAX:' +
            path +
            fmt;
        String mixed = '{SUM:' + path + ':currency:USD}';
        DocGenGiantQueryTotals totals = new DocGenGiantQueryTotals(new Set<String>{ 'Groups' });
        DocGenService.mergeGroupedGiantShell(converted + mixed, root, totals);
        totals.addRow(
            'Groups',
            new Map<String, Object>{
                'CurrencyIsoCode' => 'USD',
                'Lines' => new List<Object>{
                    new Map<String, Object>{ 'Amount' => 10, 'CurrencyIsoCode' => 'EUR', 'HomeISO' => 'EUR' }
                }
            }
        );
        totals.addRow(
            'Groups',
            new Map<String, Object>{
                'CurrencyIsoCode' => 'USD',
                'Lines' => new List<Object>{
                    new Map<String, Object>{ 'Amount' => 40, 'CurrencyIsoCode' => 'USD', 'HomeISO' => 'USD' }
                }
            }
        );
        totals.finish();
        DocGenGiantQueryTotals single = new DocGenGiantQueryTotals(new Set<String>{ 'Groups' });
        String euros = '{SUM:Groups.Lines.Amount:currency:USD:convert}';
        DocGenService.mergeGroupedGiantShell(euros, root, single);
        single.addRow(
            'Groups',
            new Map<String, Object>{
                'Lines' => new List<Object>{ new Map<String, Object>{ 'Amount' => 10, 'CurrencyIsoCode' => 'EUR' } }
            }
        );
        single.finish();
        Assert.areEqual('$20.00', DocGenService.mergeGroupedGiantShell(euros, root, single));

        Assert.areEqual(
            '$60.00 / $30.00 / $20.00 / $40.00',
            DocGenService.mergeGroupedGiantShell(converted, root, totals)
        );
        try {
            DocGenService.mergeGroupedGiantShell(mixed, root, totals);
            Assert.fail('Expected the mixed currencies from different pages to be identified.');
        } catch (DocGenException e) {
            Assert.isTrue(e.getMessage().contains('Mixed currencies'), e.getMessage());
        }
        Assert.areEqual(
            '0',
            DocGenService.mergeGiantHtml('{SUM:Groups.Amount}', root, null),
            'Grouped shell context is scoped to one merge.'
        );
    }
}
