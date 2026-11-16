/** Plans the PDF placements separately from the child datasets they share. */
public with sharing class DocGenGiantQueryMulti {
    public static final Integer DEFAULT_PAGE_SIZE = 50;
    private static final Integer PAGES_PER_TRANSACTION = 16;
    private static final Integer MAX_PAGE_SIZE = 500;
    private static final Integer LONG_TEXT_LENGTH = 32000;
    private static final Integer MAX_LONG_TEXT_CHARS_PER_PAGE = 1000000;

    public class Dataset {
        public Map<String, Object> childNode;
        public String nestedQuery;
        public List<String> fields = new List<String>();
        public List<DocGenGiantQueryPlan.Slot> slots = new List<DocGenGiantQueryPlan.Slot>();
        public Integer pageSize;
    }

    public class Run {
        public Id jobId;
        public Id templateId;
        public Id recordId;
        public Id templateVersionId;
        public List<Dataset> datasets = new List<Dataset>();
        public List<DocGenGiantQueryPlan.Slot> slots;
        public Map<String, Integer> fragmentCounts = new Map<String, Integer>();
        public Integer harvestedRows = 0;
        public Integer plannedRows = 0;
        public Boolean wordSnapshot = false;

        public String queryConfig;
    }

    private class Worker implements Queueable {
        private Run run;
        private Integer datasetIndex = 0;
        private Integer nextPage = 0;
        private Integer totalRows = 0;
        private Integer cursorRetries = 0;
        private Database.Cursor cursor;

        Worker(Run run) {
            this.run = run;
        }

        public void execute(QueueableContext context) {
            attachFailureHandler(run.jobId);
            Dataset dataset = run.datasets[datasetIndex];
            try {
                if (cursor == null) {
                    Database.Cursor opened = DocGenDataRetriever.openGiantQueryCursor(
                        run.recordId,
                        dataset.childNode,
                        dataset.fields
                    );
                    totalRows = opened.getNumRecords();
                    cursor = opened;
                    run.plannedRows += totalRows * dataset.slots.size();
                }

                for (
                    Integer pages = 0;
                    pages < PAGES_PER_TRANSACTION &&
                    nextPage * pageSize(dataset) < totalRows;
                    pages++
                ) {
                    harvestPage(dataset);
                    if (
                        Limits.getHeapSize() > Limits.getLimitHeapSize() / 2 ||
                        Limits.getCpuTime() > Limits.getLimitCpuTime() / 2
                    ) {
                        break;
                    }
                }
                if (nextPage * pageSize(dataset) >= totalRows) {
                    for (DocGenGiantQueryPlan.Slot slot : dataset.slots) {
                        run.fragmentCounts.put(slot.key, nextPage);
                    }
                    datasetIndex++;
                    nextPage = 0;
                    cursor = null;
                }

                saveProgress();
                if (datasetIndex == run.datasets.size()) {
                    System.enqueueJob(
                        new DocGenGiantQueryAssembler(
                            run.jobId,
                            run.templateId,
                            run.recordId,
                            run.templateVersionId,
                            run.slots,
                            run.fragmentCounts,
                            run.queryConfig,
                            run.wordSnapshot
                        )
                    );
                } else {
                    System.enqueueJob(this);
                }
            } catch (System.TransientCursorException failure) {
                if (cursorRetries >= 1) {
                    throw failure;
                }
                cursorRetries++;
                saveProgress();
                System.enqueueJob(this);
            }
        }

        private Integer pageSize(Dataset dataset) {
            return dataset.nestedQuery == null ? dataset.pageSize : 1;
        }

        private void harvestPage(Dataset dataset) {
            Integer position = nextPage * pageSize(dataset);
            Integer count = Math.min(pageSize(dataset), totalRows - position);
            List<SObject> rows = cursor.fetch(position, count);
            if (rows.size() != count) {
                throw new DocGenException('Giant Query cursor returned an incomplete page: ' + nextPage);
            }
            if ('EmailMessage'.equalsIgnoreCase((String) dataset.childNode.get('object'))) {
                for (String fieldName : dataset.fields) {
                    if ('HtmlBody'.equalsIgnoreCase(fieldName)) {
                        DocGenEmailInlineImages.prepare(rows);
                        break;
                    }
                }
            }

            Map<String, Object> groupData = dataset.nestedQuery == null
                ? null
                : DocGenDataRetriever.loadGiantGroup(run.recordId, dataset.nestedQuery, rows[0]);
            List<ContentVersion> fragments = new List<ContentVersion>();
            for (DocGenGiantQueryPlan.Slot slot : dataset.slots) {
                String title =
                    'docgen_giant_' +
                    run.jobId +
                    '_slot_' +
                    slot.key +
                    '_' +
                    String.valueOf(nextPage).leftPad(5, '0');
                String rendered = groupData == null
                    ? DocGenService.renderLoopBodyForRecords(
                          slot.innerXml,
                          slot.queryKey,
                          rows,
                          dataset.fields,
                          position,
                          'HTML',
                          'PDF'
                      )
                    : DocGenService.mergeGiantHtml(slot.innerXml, groupData, position + 1);
                fragments.add(
                    new ContentVersion(
                        Title = title,
                        PathOnClient = title + '.html',
                        VersionData = Blob.valueOf(rendered),
                        IsMajorVersion = false
                    )
                );
            }
            SObjectAccessDecision writable = Security.stripInaccessible(AccessType.CREATABLE, fragments);
            if (!writable.getRemovedFields().isEmpty()) {
                throw new DocGenException('ContentVersion field access denied for Giant Query fragments.');
            }
            insert writable.getRecords();
            nextPage++;
            run.harvestedRows += rows.size() * dataset.slots.size();
            cursorRetries = 0;
        }

        private void saveProgress() {
            update new DocGen_Job__c(
                Id = run.jobId,
                Status__c = 'Harvesting',
                Total_Records__c = run.plannedRows,
                Success_Count__c = run.harvestedRows
            );
        }
    }

    public static void attachFailureHandler(Id jobId) {
        System.attachFinalizer(new FailureHandler(jobId));
    }

    private class FailureHandler implements Finalizer {
        private Id jobId;

        FailureHandler(Id jobId) {
            this.jobId = jobId;
        }

        public void execute(FinalizerContext context) {
            if (context.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
                update new DocGen_Job__c(
                    Id = jobId,
                    Status__c = 'Failed',
                    Label__c = context.getException().getMessage().left(255)
                );
            }
        }
    }

    public static Run plan(String documentBody, String queryConfig) {
        return plan(documentBody, queryConfig, null, null);
    }

    public static Run plan(String documentBody, String queryConfig, Integer pageSize) {
        return plan(documentBody, queryConfig, pageSize, null);
    }

    /**
     * A Word version already has a small, unmerged HTML snapshot. Render its
     * children into HTML in bounded pages so long email bodies never have to
     * be expanded into Word XML and converted back to HTML.
     */
    public static Run planWordPdf(Id parentId, Id versionId, String queryConfig, Integer pageSize) {
        if (parentId == null || String.isBlank(queryConfig)) {
            throw new DocGenException('Giant Query for Word PDF needs a source record and a query configuration.');
        }
        String snapshot = loadWordPdfSnapshot(versionId);
        Integer configVersion = DocGenDataRetriever.getConfigVersion(queryConfig);
        if (configVersion == 1) {
            queryConfig = wordFlatPlanConfig(parentId, queryConfig);
        } else if (configVersion != 3) {
            throw new DocGenException(
                'Giant Query for Word PDF needs direct child queries. Re-save this template in Query Builder.'
            );
        }
        Run planned = planPlacements(snapshot, queryConfig, pageSize, true, null);
        if (planned == null) {
            throw new DocGenException(
                'Giant Query could not find a direct child loop in the Word template. Place the loop in the document body.'
            );
        }
        return planned;
    }

    public static String loadWordPdfSnapshot(Id versionId) {
        if (versionId != null) {
            DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
            String title = 'docgen_tmpl_html_' + versionId;
            List<ContentVersion> versions = DocGenService.loadInternalContentVersionsForVersionByTitle(
                versionId,
                title
            );
            if (versions.isEmpty()) {
                versions = DocGenService.loadInternalContentVersionsByTitle(title);
            }
            if (!versions.isEmpty() && versions[0].VersionData != null) {
                return versions[0].VersionData.toString();
            }
        }
        throw new DocGenException(
            'The Word template has no prepared PDF snapshot. Re-save the template and try again.'
        );
    }

    private static String wordFlatPlanConfig(Id parentId, String queryConfig) {
        List<Object> nodes = new List<Object>{ new Map<String, Object>{ 'id' => 'word-root' } };
        // Pass the individual subquery to the existing parser. In a flat list
        // it may otherwise match the SELECT from an earlier sibling.
        Matcher children = Pattern.compile('(?i)\\(\\s*SELECT\\s+[^()]+?\\s+FROM\\s+(\\w+)(?:\\s+[^()]*)?\\)')
            .matcher(queryConfig);
        while (children.find()) {
            String relationship = children.group(1);
            Map<String, Object> node = DocGenController.buildNodeConfigFromFlat(
                parentId,
                children.group(),
                relationship
            );
            if (node != null) {
                node.put('id', 'word-child-' + nodes.size());
                node.put('parentNode', 'word-root');
                nodes.add(node);
            }
        }
        return JSON.serialize(new Map<String, Object>{ 'v' => 3, 'nodes' => nodes });
    }

    public static Run plan(String documentBody, String queryConfig, Id recordId) {
        return plan(documentBody, queryConfig, null, recordId);
    }

    public static Run plan(String documentBody, String queryConfig, Integer pageSize, Id recordId) {
        return planPlacements(documentBody, queryConfig, pageSize, false, recordId);
    }

    private static Run planPlacements(String documentBody, String queryConfig, Integer pageSize, Boolean wordSnapshot, Id recordId) {
        if (String.isBlank(documentBody)) {
            return null;
        }
        Map<String, Map<String, Object>> byKey = DocGenDataRetriever.planFlatGiantDatasets(recordId, queryConfig);
        Boolean grouped = !byKey.isEmpty();
        Set<String> duplicates = new Set<String>();
        Set<String> queryKeys = new Set<String>(byKey.keySet());
        if (!grouped) {
            if (DocGenDataRetriever.getConfigVersion(queryConfig) < 3)
                return null;

            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(queryConfig);
            List<Object> configNodes = (List<Object>) config.get('nodes');
            if (configNodes == null)
                return null;

            String rootNodeId;
            for (Object value : configNodes) {
                Map<String, Object> node = (Map<String, Object>) value;
                if (String.isBlank((String) node.get('parentNode'))) {
                    rootNodeId = (String) node.get('id');
                    break;
                }
            }
            if (String.isBlank(rootNodeId))
                return null;

            for (Object value : configNodes) {
                Map<String, Object> node = (Map<String, Object>) value;
                String parentNode = (String) node.get('parentNode');
                String alias = (String) node.get('alias');
                String key = String.isNotBlank(alias) ? alias : (String) node.get('relationshipName');
                if (String.isBlank(key) || String.isBlank(parentNode))
                    continue;
                if (wordSnapshot || parentNode == rootNodeId)
                    queryKeys.add(key);
                if (parentNode != rootNodeId)
                    continue;
                if (byKey.containsKey(key))
                    duplicates.add(key);
                byKey.put(key, node);
            }
        }

        DocGenGiantQueryPlan planned = grouped
            ? DocGenGiantQueryPlan.compileGrouped(
                  documentBody,
                  byKey.keySet(),
                  DocGenDataRetriever.getGroupedGiantRootData(recordId, queryConfig)
              )
            : DocGenGiantQueryPlan.compile(documentBody, queryKeys, wordSnapshot);
        if (!grouped && !wordSnapshot && planned.slots.size() < 2)
            return null;
        if (grouped && planned.slots.isEmpty()) {
            throw new DocGenException('Giant Query requires a top-level relationship loop for the grouped PDF.');
        }
        if (!planned.nestedQueryKeys.isEmpty()) {
            throw new DocGenException(
                'Giant Query requires top-level loops for these child queries: ' +
                String.join(new List<String>(planned.nestedQueryKeys), ', ')
            );
        }
        if (planned.slots.isEmpty()) {
            return null;
        }

        Run run = new Run();
        run.slots = planned.slots;
        run.queryConfig = queryConfig;
        run.wordSnapshot = wordSnapshot;
        Map<String, Dataset> datasets = new Map<String, Dataset>();
        for (DocGenGiantQueryPlan.Slot slot : planned.slots) {
            if (duplicates.contains(slot.queryKey)) {
                throw new DocGenException('Child query alias must be unique: ' + slot.queryKey);
            }
            if (slot.innerXml.contains('{~')) {
                throw new DocGenException(
                    'Root-anchor {~Label} tags are not supported inside giant-query table loops.'
                );
            }
            if (!datasets.containsKey(slot.queryKey)) {
                Dataset dataset = new Dataset();
                dataset.childNode = byKey.get(slot.queryKey);
                if (dataset.childNode == null || dataset.childNode.get('junction') != null) {
                    throw new DocGenException('Giant Query loops require a direct child lookup: ' + slot.queryKey);
                }
                dataset.nestedQuery = (String) dataset.childNode.get('nestedQuery');
                for (String fieldGroup : new List<String>{ 'fields', 'parentFields' }) {
                    List<Object> names = (List<Object>) dataset.childNode.get(fieldGroup);
                    if (names != null) {
                        for (Object name : names) {
                            dataset.fields.add(String.valueOf(name));
                        }
                    }
                }
                dataset.pageSize = pageSizeForFields(
                    pageSize,
                    (String) dataset.childNode.get('object'),
                    dataset.fields
                );
                datasets.put(slot.queryKey, dataset);
                run.datasets.add(dataset);
            }
            datasets.get(slot.queryKey).slots.add(slot);
        }
        return run;
    }

    /** Keep explicit page sizes bounded, then narrow pages for long text fields. */
    public static Integer pageSizeForFields(Integer pageSize, String objectName, List<String> selectedFields) {
        Integer effective = pageSize != null && pageSize > 0 ? Math.min(pageSize, MAX_PAGE_SIZE) : DEFAULT_PAGE_SIZE;
        if (objectName == null || selectedFields == null) {
            return effective;
        }
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectName);
        if (objectType == null) {
            return effective;
        }
        Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
        Integer maxCharacters = 0;
        Set<String> seen = new Set<String>();
        for (String fieldName : selectedFields) {
            if (String.isBlank(fieldName) || seen.contains(fieldName.toLowerCase())) {
                continue;
            }
            seen.add(fieldName.toLowerCase());
            Schema.SObjectField field = fields.get(fieldName.toLowerCase());
            if (field != null) {
                Schema.DescribeFieldResult description = field.getDescribe();
                if (
                    description.getType() == Schema.DisplayType.TextArea &&
                    description.getLength() >= LONG_TEXT_LENGTH
                ) {
                    maxCharacters += description.getLength();
                }
            }
        }
        return maxCharacters == 0
            ? effective
            : Math.min(effective, Math.max(1, MAX_LONG_TEXT_CHARS_PER_PAGE / maxCharacters));
    }

    public static void launch(Run planned, Id jobId, Id templateId, Id recordId, Id templateVersionId) {
        planned.jobId = jobId;
        planned.templateId = templateId;
        planned.recordId = recordId;
        planned.templateVersionId = templateVersionId;
        // Developer and Trial editions otherwise default to five chained jobs.
        AsyncOptions options = new AsyncOptions();
        options.MaximumQueueableStackDepth = 10000;
        System.enqueueJob(new Worker(planned), options);
    }
}
