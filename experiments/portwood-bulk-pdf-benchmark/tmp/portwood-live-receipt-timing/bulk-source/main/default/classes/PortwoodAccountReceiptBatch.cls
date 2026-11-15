/** Scratch benchmark for independent Portwood account PDFs. */
public with sharing class PortwoodAccountReceiptBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {
    private static final Pattern ACCOUNT_NUMBER = Pattern.compile('([A-Za-z0-9-]+-)([0-9]{4,8})');
    private final Id templateId;
    private final String firstAccountNumber;
    private final String lastAccountNumber;
    private final String accountNumberPrefix;
    private final Integer ordinalWidth;
    private final String runKey;
    private final Boolean usePrefetched;
    private Long firstScopeAt;
    private Long sourceQueryMs = 0;
    private Long managedRenderMs = 0;
    private Long fileSaveMs = 0;
    private Long savedBytes = 0;
    private Long sumScopeWallMs = 0;
    private Long sumScopeCpuMs = 0;
    private Integer filesSaved = 0;
    private Integer scopesCompleted = 0;
    private Integer prefetchQueries = 0;
    private Integer apexCallouts = 0;
    private Integer peakScopeHeapBytes = 0;

    public PortwoodAccountReceiptBatch(Id templateId, String firstAccountNumber, String lastAccountNumber,
        String runKey, Boolean usePrefetched) {
        if (templateId == null || String.isBlank(firstAccountNumber) || String.isBlank(lastAccountNumber) ||
            String.isBlank(runKey) || !Pattern.matches('[A-Za-z0-9-]{1,48}', runKey)) {
            throw new IllegalArgumentException('Supply a template, AccountNumber bounds, and a unique run key.');
        }
        Matcher first = ACCOUNT_NUMBER.matcher(firstAccountNumber);
        Matcher last = ACCOUNT_NUMBER.matcher(lastAccountNumber);
        if (!first.matches() || !last.matches() || first.group(1) != last.group(1) ||
            first.group(2).length() != last.group(2).length() ||
            Integer.valueOf(first.group(2)) > Integer.valueOf(last.group(2))) {
            throw new IllegalArgumentException('Account numbers must share a prefix and fixed-width ordinal.');
        }
        this.templateId = templateId;
        this.firstAccountNumber = firstAccountNumber;
        this.lastAccountNumber = lastAccountNumber;
        accountNumberPrefix = first.group(1);
        ordinalWidth = first.group(2).length();
        this.runKey = runKey;
        this.usePrefetched = usePrefetched == true;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        String prefixPattern = accountNumberPrefix + '%';
        return Database.getQueryLocator([
            SELECT Id, Name, AccountNumber, BillingStreet, BillingCity, BillingState, BillingPostalCode
            FROM Account WHERE AccountNumber LIKE :prefixPattern AND AccountNumber >= :firstAccountNumber
                AND AccountNumber <= :lastAccountNumber WITH USER_MODE ORDER BY AccountNumber, Id
        ]);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        Long started = System.now().getTime();
        if (firstScopeAt == null) firstScopeAt = started;
        Integer cpuStarted = Limits.getCpuTime();
        Integer calloutsStarted = Limits.getCallouts();
        Integer queriesStarted = Limits.getQueries();
        List<Account> accounts = new List<Account>();
        for (SObject record : scope) accounts.add((Account) record);
        Map<Id, Map<String, Object>> sourceData;
        Long queryWall = 0;
        if (usePrefetched) {
            sourceData = prefetch(accounts);
            queryWall = System.now().getTime() - started;
            prefetchQueries += Limits.getQueries() - queriesStarted;
        }

        Long renderStarted = System.now().getTime();
        List<ContentVersion> files = new List<ContentVersion>();
        Long scopeBytes = 0;
        for (Account account : accounts) {
            Map<String, Object> result = usePrefetched
                ? portwoodglobal.DocGenService.generatePdfBlobFromData(templateId, account.Id, sourceData.get(account.Id))
                : portwoodglobal.DocGenService.generatePdfBlob(templateId, account.Id);
            Blob pdf = (Blob) result.get('blob');
            if (pdf == null || pdf.size() == 0) throw new IllegalArgumentException('Portwood did not return a PDF.');
            String ordinal = String.valueOf(Integer.valueOf(account.AccountNumber.right(ordinalWidth))).leftPad(6, '0');
            String title = 'PW-ACCOUNT-RECEIPT-' + runKey + '-' + ordinal;
            files.add(new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = pdf,
                SharingPrivacy = 'P', SharingOption = 'R'));
            scopeBytes += pdf.size();
        }
        Long renderWall = System.now().getTime() - renderStarted;
        peakScopeHeapBytes = Math.max(peakScopeHeapBytes, Limits.getHeapSize());
        Long saveStarted = System.now().getTime();
        insert as user files;
        Long saveWall = System.now().getTime() - saveStarted;

        sourceQueryMs += queryWall;
        managedRenderMs += renderWall;
        fileSaveMs += saveWall;
        savedBytes += scopeBytes;
        filesSaved += files.size();
        scopesCompleted++;
        sumScopeWallMs += System.now().getTime() - started;
        sumScopeCpuMs += Limits.getCpuTime() - cpuStarted;
        apexCallouts += Limits.getCallouts() - calloutsStarted;
        System.debug(LoggingLevel.INFO, 'PW_ACCOUNT_RECEIPT_SCOPE=' + JSON.serialize(new Map<String, Object>{
            'runKey' => runKey, 'files' => files.size(), 'bytes' => scopeBytes, 'sourcePrefetchMs' => queryWall,
            'managedRenderMs' => renderWall, 'fileSaveMs' => saveWall, 'cpuMs' => Limits.getCpuTime() - cpuStarted
        }));
    }

    public void finish(Database.BatchableContext context) {
        String summary = JSON.serialize(new Map<String, Object>{
            'batchJobId' => context.getJobId(), 'runKey' => runKey,
            'mode' => usePrefetched ? 'batch-prefetch-portwood-render' : 'portwood-native-query-and-render',
            'firstScopeAtMs' => firstScopeAt, 'finishAtMs' => System.now().getTime(),
            'filesSaved' => filesSaved, 'savedBytes' => savedBytes, 'scopesCompleted' => scopesCompleted,
            'sourcePrefetchWallMs' => sourceQueryMs, 'sourcePrefetchQueries' => prefetchQueries,
            'managedRenderWallMs' => managedRenderMs, 'fileSaveWallMs' => fileSaveMs,
            'sumScopeWallMs' => sumScopeWallMs, 'sumScopeCpuMs' => sumScopeCpuMs,
            'peakScopeHeapBeforeInsertBytes' => peakScopeHeapBytes, 'apexCallouts' => apexCallouts
        });
        System.debug(LoggingLevel.ERROR, 'PW_ACCOUNT_RECEIPT_BATCH=' + summary);
        String title = 'PW-ACCOUNT-RECEIPT-METRICS-' + runKey + '-' + context.getJobId();
        insert as user new ContentVersion(Title = title, PathOnClient = title + '.json',
            VersionData = Blob.valueOf(summary), SharingPrivacy = 'P', SharingOption = 'R');
    }

    private static Map<Id, Map<String, Object>> prefetch(List<Account> scope) {
        Map<Id, List<Map<String, Object>>> opportunities = new Map<Id, List<Map<String, Object>>>();
        for (Account account : scope) opportunities.put(account.Id, new List<Map<String, Object>>());
        Set<Id> accountIds = opportunities.keySet();
        for (Opportunity opportunity : [
            SELECT Id, AccountId, Name, Description, CloseDate, Amount,
                (SELECT Id, Quantity, UnitPrice, TotalPrice, Product2.Name
                    FROM OpportunityLineItems ORDER BY SortOrder ASC, Id ASC)
            FROM Opportunity WHERE AccountId IN :accountIds
            WITH USER_MODE ORDER BY Name ASC
        ]) {
            List<Map<String, Object>> items = new List<Map<String, Object>>();
            for (OpportunityLineItem line : opportunity.OpportunityLineItems) {
                items.add(new Map<String, Object>{'Id' => line.Id, 'Quantity' => line.Quantity,
                    'UnitPrice' => line.UnitPrice, 'TotalPrice' => line.TotalPrice,
                    'Product2' => new Map<String, Object>{'Name' => line.Product2?.Name}});
            }
            opportunities.get(opportunity.AccountId).add(new Map<String, Object>{
                'Id' => opportunity.Id, 'Name' => opportunity.Name, 'Description' => opportunity.Description,
                'CloseDate' => Datetime.newInstanceGmt(opportunity.CloseDate, Time.newInstance(0, 0, 0, 0)).formatGmt('yyyy-MM-dd'),
                'Amount' => opportunity.Amount,
                'OpportunityLineItems' => collection(items)
            });
        }

        Map<Id, Map<String, Object>> result = new Map<Id, Map<String, Object>>();
        for (Account account : scope) {
            result.put(account.Id, new Map<String, Object>{'Id' => account.Id, 'Name' => account.Name,
                'AccountNumber' => account.AccountNumber, 'BillingStreet' => account.BillingStreet,
                'BillingCity' => account.BillingCity, 'BillingState' => account.BillingState,
                'BillingPostalCode' => account.BillingPostalCode, 'Opportunities' => collection(opportunities.get(account.Id))});
        }
        return result;
    }

    private static Map<String, Object> collection(List<Map<String, Object>> records) {
        return new Map<String, Object>{'records' => records, 'totalSize' => records.size()};
    }
}
