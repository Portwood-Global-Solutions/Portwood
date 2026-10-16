/** Scratch-org-only stress harness. Never include in the managed package. */
@RestResource(urlMapping='/pdf-merge-stress/*')
global with sharing class PdfMergeStress {
    public class Config {
        public String label;
        public String mode;
        public String path;
        public List<Id> ids;
        public Integer count;
        public Boolean pad;
    }

    @HttpPost
    global static void post() {
        Config config = (Config) JSON.deserialize(RestContext.request.requestBody.toString(), Config.class);
        if (config.mode == 'async') {
            Id job = System.enqueueJob(new Job(config));
            respond(new Map<String, Object>{ 'jobId' => job });
        } else {
            respond(run(config));
        }
    }

    @HttpGet
    global static void get() {
        String title = 'PDF stress result ' + RestContext.request.params.get('label');
        List<ContentVersion> logs = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Title = :title AND IsLatest = TRUE
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (logs.isEmpty()) {
            RestContext.response.statusCode = 202;
            respond(new Map<String, Object>{ 'pending' => true });
        } else {
            RestContext.response.addHeader('Content-Type', 'application/json');
            RestContext.response.responseBody = logs[0].VersionData;
        }
    }

    private static Map<String, Object> run(Config config) {
        List<Id> ids = new List<Id>();
        Integer count = config.count == null ? config.ids.size() : config.count;
        for (Integer i = 0; i < count; i++)
            ids.add(config.ids[Math.mod(i, config.ids.size())]);
        Map<Id, ContentVersion> sizes = new Map<Id, ContentVersion>(
            [SELECT Id, ContentSize FROM ContentVersion WHERE Id IN :ids WITH USER_MODE]
        );
        Integer inputBytes = 0;
        for (Id id : ids)
            inputBytes += sizes.get(id).ContentSize;
        Map<String, Object> result = new Map<String, Object>{
            'label' => config.label,
            'mode' => config.mode,
            'path' => config.path,
            'count' => count,
            'uniqueCount' => sizes.size(),
            'inputBytes' => inputBytes,
            'heapLimit' => Limits.getLimitHeapSize(),
            'cpuLimit' => Limits.getLimitCpuTime(),
            'queryLimit' => Limits.getLimitQueries(),
            'heapBefore' => Limits.getHeapSize()
        };
        Integer cpu = Limits.getCpuTime();
        Integer queries = Limits.getQueries();
        Long started = DateTime.now().getTime();
        try {
            if (config.path == 'action') {
                DocGenPdfMergeFlowAction.Request request = new DocGenPdfMergeFlowAction.Request();
                request.contentVersionIds = new List<String>();
                for (Id id : ids)
                    request.contentVersionIds.add(String.valueOf(id));
                request.documentTitle = 'PDF stress output ' + config.label;
                request.padOddDocuments = config.pad;
                DocGenPdfMergeFlowAction.Response response = DocGenPdfMergeFlowAction.mergePdfs(
                    new List<DocGenPdfMergeFlowAction.Request>{ request }
                )[0];
                result.put('success', response.success);
                result.put('error', response.errorMessage);
                result.put('outputId', response.contentVersionId);
            } else {
                Blob output = DocGenPdfMerger.mergePdfCvs(ids, config.pad == true);
                result.put('outputBytes', output.size());
                ContentVersion cv = new ContentVersion(
                    Title = 'PDF stress output ' + config.label,
                    PathOnClient = config.label + '.pdf',
                    VersionData = output
                );
                insert as user cv;
                result.put('outputId', cv.Id);
                result.put('success', true);
            }
        } catch (Exception e) {
            result.put('success', false);
            result.put('error', e.getTypeName() + ': ' + e.getMessage());
            result.put('stack', e.getStackTraceString());
        }
        result.put('cpuMs', Limits.getCpuTime() - cpu);
        result.put('wallMs', DateTime.now().getTime() - started);
        result.put('heapAfter', Limits.getHeapSize());
        result.put('queries', Limits.getQueries() - queries);
        return result;
    }

    private static void respond(Object value) {
        RestContext.response.addHeader('Content-Type', 'application/json');
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(value));
    }

    private static void save(String label, Object result) {
        insert as user new ContentVersion(
            Title = 'PDF stress result ' + label,
            PathOnClient = label + '.json',
            VersionData = Blob.valueOf(JSON.serialize(result))
        );
    }

    public class Job implements Queueable, Finalizer {
        private Config config;
        public Job(Config config) {
            this.config = config;
        }
        public void execute(QueueableContext context) {
            System.attachFinalizer(this);
            save(config.label, run(config));
        }
        public void execute(FinalizerContext context) {
            if (String.valueOf(context.getResult()) == 'SUCCESS')
                return;
            Exception error = context.getException();
            save(
                config.label,
                new Map<String, Object>{
                    'label' => config.label,
                    'mode' => config.mode,
                    'path' => config.path,
                    'count' => config.count,
                    'success' => false,
                    'fatal' => true,
                    'jobId' => context.getAsyncApexJobId(),
                    'error' => error == null ? String.valueOf(context.getResult()) : error.getMessage(),
                    'stack' => error == null ? null : error.getStackTraceString()
                }
            );
        }
    }
}
