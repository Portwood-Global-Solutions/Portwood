@IsTest
private class DocGenNestedAggregateTest {
    @IsTest
    static void totalsRowsFromFilteredQuery() {
        Account statement = new Account(Name = 'Statement account');
        Account other = new Account(Name = 'Another statement');
        insert new List<Account>{ statement, other };
        List<Account> groups = new List<Account>{
            new Account(Name = 'Group A', ParentId = statement.Id),
            new Account(Name = 'Group B', ParentId = statement.Id),
            new Account(Name = 'Group C', ParentId = statement.Id),
            new Account(Name = 'Other group', ParentId = other.Id)
        };
        insert groups;
        String paid = [SELECT MasterLabel FROM OpportunityStage WHERE IsActive = TRUE AND IsWon = TRUE LIMIT 1]
        .MasterLabel;
        String pending = [SELECT MasterLabel FROM OpportunityStage WHERE IsActive = TRUE AND IsClosed = FALSE LIMIT 1]
        .MasterLabel;
        Date first = Date.newInstance(2026, 1, 1);
        Date last = Date.newInstance(2026, 12, 31);
        insert new List<Opportunity>{
            payment(groups[0], 'First', paid, first, 25),
            payment(groups[0], 'Second', paid, first.addDays(1), 50),
            payment(groups[1], 'Third', paid, last, 100),
            payment(groups[2], 'Blank amount', paid, first, null),
            payment(groups[1], 'Prior year', paid, first.addDays(-1), 400),
            payment(groups[1], 'Next year', paid, last.addDays(1), 500),
            payment(groups[2], 'Unpaid', pending, first, 1000),
            payment(groups[3], 'Other account', paid, first, 2000)
        };

        String groupsRel;
        for (Schema.ChildRelationship rel : Account.SObjectType.getDescribe().getChildRelationships()) {
            if (rel.getChildSObject() == Account.SObjectType && rel.getField() == Account.ParentId) {
                groupsRel = rel.getRelationshipName();
                break;
            }
        }
        Assert.isNotNull(groupsRel);
        String paidFilter = 'IsWon = true AND CloseDate >= 2026-01-01 AND CloseDate <= 2026-12-31';
        String query =
            'Name, (SELECT Name, (SELECT Name, Amount FROM Opportunities WHERE ' +
            paidFilter +
            ' ORDER BY CloseDate ASC) FROM ' +
            groupsRel +
            ' ORDER BY Name ASC)';
        AggregateResult expected = [
            SELECT
                SUM(Amount) total,
                AVG(Amount) meanAmount,
                MIN(Amount) smallest,
                MAX(Amount) largest,
                COUNT(Id) rowCount,
                COUNT(Amount) numericCount
            FROM Opportunity
            WHERE Account.ParentId = :statement.Id AND IsWon = TRUE AND CloseDate >= :first AND CloseDate <= :last
        ];
        String expectedFooter = String.join(
            new List<String>{
                DocGenService.formatAggregateValue((Decimal) expected.get('total'), 'currency'),
                DocGenService.formatAggregateValue((Decimal) expected.get('meanAmount'), 'currency'),
                ((Decimal) expected.get('smallest')).stripTrailingZeros().toPlainString(),
                ((Decimal) expected.get('largest')).stripTrailingZeros().toPlainString(),
                String.valueOf(expected.get('rowCount')),
                String.valueOf(expected.get('numericCount'))
            },
            '|'
        );
        Assert.areEqual('$175.00|$58.33|25|100|4|3', expectedFooter);
        Map<String, Object> data = DocGenDataRetriever.getRecordData(statement.Id, 'Account', query);
        String detail =
            '{#' +
            groupsRel +
            '}{#Opportunities}{Name}={Amount:currency}|{/Opportunities}{/' +
            groupsRel +
            '}';
        String output = DocGenService.processXmlForTest(detail + amountStats(groupsRel + '.Opportunities'), data);
        Assert.areEqual('First=$25.00|Second=$50.00|Third=$100.00|Blank amount=|' + expectedFooter, output);

        Map<String, Object> tree = new Map<String, Object>{
            'v' => 3,
            'root' => 'Account',
            'nodes' => new List<Object>{
                new Map<String, Object>{
                    'id' => 'root',
                    'object' => 'Account',
                    'fields' => new List<Object>{ 'Name' }
                },
                new Map<String, Object>{
                    'id' => 'groups',
                    'parentNode' => 'root',
                    'object' => 'Account',
                    'lookupField' => 'ParentId',
                    'relationshipName' => groupsRel,
                    'alias' => 'Groups',
                    'fields' => new List<Object>{ 'Name' }
                },
                new Map<String, Object>{
                    'id' => 'payments',
                    'parentNode' => 'groups',
                    'object' => 'Opportunity',
                    'lookupField' => 'AccountId',
                    'relationshipName' => 'Opportunities',
                    'alias' => 'Paid',
                    'fields' => new List<Object>{ 'Amount' },
                    'where' => paidFilter
                }
            }
        };
        String tags = amountStats('Groups.Paid');
        Assert.areEqual(
            expectedFooter,
            DocGenService.processXmlForTest(
                tags,
                DocGenDataRetriever.getRecordData(statement.Id, 'Account', JSON.serialize(tree))
            )
        );
        Map<Id, Map<String, Object>> batch = DocGenDataRetriever.getRecordDataV3Bulk(
            new Set<Id>{ statement.Id, other.Id },
            tree
        );
        Assert.areEqual(expectedFooter, DocGenService.processXmlForTest(tags, batch.get(statement.Id)));
        Assert.areEqual(
            '$2,000.00|$2,000.00|2000|2000|1|1',
            DocGenService.processXmlForTest(tags, batch.get(other.Id))
        );
    }

    private static String amountStats(String path) {
        String field = path + '.Amount';
        return String.join(
            new List<String>{
                '{SUM:' +
                field +
                ':currency}',
                '{AVG:' +
                field +
                ':currency}',
                '{MIN:' +
                field +
                '}',
                '{MAX:' +
                field +
                '}',
                '{COUNT:' +
                path +
                '}',
                '{COUNT:' +
                field +
                '}'
            },
            '|'
        );
    }

    private static Opportunity payment(Account groupRecord, String name, String stage, Date paidDate, Decimal amount) {
        return new Opportunity(
            Name = name,
            AccountId = groupRecord.Id,
            StageName = stage,
            CloseDate = paidDate,
            Amount = amount
        );
    }

    @IsTest
    static void traversesListsAndPreservesScalarLookups() {
        List<Object> entries = new List<Object>{
            new Map<String, Object>{ 'Price' => 100, 'Product' => new Map<String, Object>{ 'MSRP' => 225 } },
            new Map<String, Object>{ 'Price' => -25, 'Product' => new Map<String, Object>{ 'MSRP' => 25 } },
            new Map<String, Object>{ 'Price' => null },
            new Map<String, Object>{ 'Price' => 'n/a' }
        };
        Map<String, Object> data = new Map<String, Object>{
            'Orders' => new Map<String, Object>{
                'records' => new List<Object>{
                    new Map<String, Object>{
                        'Lines__r' => new Map<String, Object>{ 'records' => entries, 'totalSize' => 4 }
                    },
                    new Map<String, Object>{
                        'Lines__r' => new List<Object>{ new Map<String, Object>{ 'Price' => 15 } }
                    },
                    new Map<String, Object>{ 'Lines__r' => new List<Object>() },
                    new Map<String, Object>{ 'Price' => 999 }
                }
            }
        };
        String tag =
            '{SUM:Orders.Lines__r.Price}|{AVG:Orders.Lines__r.Price}|{MIN:Orders.Lines__r.Price}' +
            '|{MAX:Orders.Lines__r.Price}|{COUNT:Orders.Lines__r.Price}|{SUM:Orders.Lines__r.Product.MSRP}' +
            '|{SUM:Orders.Lines__r.TOTALSIZE}|{COUNT:Orders.Lines__r:number}';
        Assert.areEqual('90|30|-25|100|3|250|4|5', DocGenService.processXmlForTest(tag, data));
        Map<String, Object> enclosing = new Map<String, Object>{ 'Groups' => new List<Object>{ data, data } };
        Assert.areEqual(
            '180|10|6',
            DocGenService.processXmlForTest(
                '{SUM:Groups.Orders.Lines__r.Price}|{COUNT:Groups.Orders.Lines__r}|{COUNT:Groups.Orders.Lines__r.Price}',
                enclosing
            )
        );
        data.put(
            'Orders',
            new List<Object>{ new Map<String, Object>{ 'Lines__r' => new List<Object>(), 'Price' => 999 } }
        );
        Assert.areEqual('0', DocGenService.processXmlForTest('{SUM:Orders.Lines__r.Price}', data));
        Assert.areEqual('$0.00', DocGenService.processXmlForTest('{SUM:Orders.Lines__r.Price:currency}', data));
        Assert.areEqual('0', DocGenService.processXmlForTest('{COUNT:Orders.Lines__r:number}', data));
        data.put('Orders', new List<Object>());
        Assert.areEqual('$0.00', DocGenService.processXmlForTest('{SUM:Orders.Lines__r.Price:currency}', data));
    }

    @IsTest
    static void aMissingRelationshipCannotSupplyTheParentAmount() {
        Account a = new Account(Name = 'Qualified field');
        insert a;
        Map<String, Object> data = new Map<String, Object>{
            'Rows' => new List<Object>{
                new Map<String, Object>{ 'Id' => a.Id, 'Amount' => 99 },
                new Map<String, Object>{ 'attributes' => new Map<String, Object>{ 'type' => 'Account' }, 'Amount' => 1 }
            }
        };
        Assert.areEqual(
            '0|0|0|0|0|0',
            DocGenService.processXmlForTest(
                '{SUM:Rows.Payments.Amount}|{AVG:Rows.Payments.Amount}|{MIN:Rows.Payments.Amount}' +
                '|{MAX:Rows.Payments.Amount}|{COUNT:Rows.Payments.Amount}|{COUNT:Rows.Payments}',
                data
            )
        );
        Assert.areEqual('100', DocGenService.processXmlForTest('{SUM:Rows.Account.Amount}', data));
    }

    @IsTest
    static void usesLeafCurrency() {
        DocGenCurrency.rateOverrideForTest = new Map<String, Decimal>{ 'USD' => 1, 'EUR' => 0.5 };
        List<Object> groups = new List<Object>();
        for (String iso : new List<String>{ 'USD', 'EUR' }) {
            groups.add(
                new Map<String, Object>{
                    'CurrencyIsoCode' => 'USD',
                    'Payments' => new List<Object>{
                        new Map<String, Object>{ 'Amount' => 10, 'CurrencyIsoCode' => iso }
                    }
                }
            );
        }
        Map<String, Object> data = new Map<String, Object>{ 'Opportunities' => groups };
        try {
            DocGenService.processXmlForTest('{SUM:Opportunities.Payments.Amount:currency:USD}', data);
            Assert.fail('Expected the payments to report mixed currencies');
        } catch (DocGenException e) {
            Assert.isTrue(e.getMessage().contains('Mixed currencies'), e.getMessage());
        }
        Assert.areEqual(
            '$30.00|$15.00|$10.00|$20.00|2',
            DocGenService.processXmlForTest(
                '{SUM:Opportunities.Payments.Amount:currency:USD:convert}' +
                    '|{AVG:Opportunities.Payments.Amount:currency:USD:convert}|{MIN:Opportunities.Payments.Amount:currency:USD:convert}' +
                    '|{MAX:Opportunities.Payments.Amount:currency:USD:convert}|{COUNT:Opportunities.Payments}',
                data
            )
        );
    }

    @IsTest
    static void streamedRelationshipReportsUnsupportedNestedField() {
        DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(
            null,
            null,
            null,
            'Opportunities',
            'Opportunity',
            'AccountId',
            null
        );
        String other = '{SUM:Other.Payments.Amount:currency}';
        Assert.areEqual(other, assembler.resolveGiantAggregateTags(other));
        for (
            String tag : new List<String>{
                '{SUM:Opportunities.Payments.Amount:currency}',
                '{AVG:Opportunities.Payments.Amount}',
                '{MIN:Opportunities.Payments.Amount}',
                '{MAX:Opportunities.Payments.Amount}',
                '{COUNT:Opportunities.Payments.Amount}',
                '{COUNT:Opportunities.OpportunityLineItems:number}'
            }
        ) {
            try {
                assembler.resolveGiantAggregateTags(tag);
                Assert.fail('Expected the streamed path to identify ' + tag);
            } catch (DocGenException e) {
                Assert.isTrue(e.getMessage().contains(tag), e.getMessage());
            }
        }
    }
}
