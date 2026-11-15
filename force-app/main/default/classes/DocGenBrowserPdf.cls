/** Owns the ordered, private source manifest for a browser-merged bulk PDF. */
public with sharing class DocGenBrowserPdf {
    public static final Integer MAX_SOURCES = 100000;
    public static final Integer MAX_BLOCK_SIZE = 40;
    public static final Integer MAX_SOURCE_BYTES = 1048576;
    private static final Integer MAX_SOURCES_PER_READ = 16;
    private static final Integer PAGE_SIZE = 100;
    private static final Set<String> PDF_TEMPLATE_TYPES = new Set<String>{ 'Word', 'HTML', 'Canvas' };
    private static final Set<String> INACTIVE_BATCH = new Set<String>{ 'Aborted', 'Completed', 'Failed' };

    public class JobDescription {
        public Id jobId;
        public String revisionKey;
        public String status;
        public Integer totalSources;
        public Integer successCount;
        public Integer errorCount;
        public String filename;
        public Boolean ready;
    }

    public class ManifestPage {
        public List<Source> sources = new List<Source>();
        public Integer nextAfterOrdinal;
        public Boolean done;
    }

    public class Source {
        public Integer ordinal;
        public Id versionId;
        public Integer bytes;
        public String checksum;
    }

    public static Id submit(Id templateId, String condition, String jobLabel, Integer batchSize, String sortOrder) {
        if (templateId == null) {
            throw new DocGenException('Select an active PDF template.');
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{
                'Is_Active__c',
                'Base_Object_API__c',
                'Record_Filter__c',
                'Type__c',
                'Output_Format__c',
                'Required_Permission_Sets__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT
                Id,
                Is_Active__c,
                Base_Object_API__c,
                Record_Filter__c,
                Type__c,
                Output_Format__c,
                Required_Permission_Sets__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
        ];
        if (
            templates.isEmpty() ||
            !templates[0].Is_Active__c ||
            DocGenController.filterTemplatesForSender(templates, null).isEmpty()
        ) {
            throw new DocGenException('Select an active PDF template.');
        }
        DocGen_Template__c template = templates[0];
        if (template.Output_Format__c != 'PDF' || !PDF_TEMPLATE_TYPES.contains(template.Type__c)) {
            throw new DocGenException(
                'Browser PDF Download requires an HTML, Canvas, or Word template with PDF output.'
            );
        }
        if (
            String.isBlank(template.Base_Object_API__c) ||
            !Schema.getGlobalDescribe().containsKey(template.Base_Object_API__c)
        ) {
            throw new DocGenException('The template requires a valid Salesforce source object.');
        }
        String safeFilter = DocGenBulkController.sanitizeConditionInternal(condition);
        String templateFilter = DocGenBulkController.sanitizeConditionInternal(template.Record_Filter__c);
        if (String.isNotBlank(templateFilter)) {
            safeFilter = String.isBlank(safeFilter)
                ? templateFilter
                : '(' + safeFilter + ') AND (' + templateFilter + ')';
        }
        String safeSort = DocGenBulkController.normalizeSortOrder(template.Base_Object_API__c, sortOrder);
        String ordered = String.isBlank(safeSort) ? 'Id ASC' : safeSort;
        if (!Pattern.compile('(?i)(^|,\\s*)Id(\\s|$)').matcher(ordered).find()) {
            ordered += ', Id ASC';
        }

        DocGen_Job__c job = new DocGen_Job__c(
            Template__c = templateId,
            Query_Condition__c = condition,
            Label__c = jobLabel,
            Sort_Order__c = safeSort,
            Status__c = 'Queued',
            Browser_Merge__c = true,
            Browser_Revision__c = newRevision()
        );
        DocGenFlsGuard.assertCreateable(
            job,
            new Set<String>{ 'Template__c', 'Query_Condition__c', 'Label__c', 'Sort_Order__c', 'Status__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(job, AccessLevel.SYSTEM_MODE);
        Integer blockSize = batchSize == null ? 10 : Math.max(1, Math.min(MAX_BLOCK_SIZE, batchSize));
        DocGenBrowserPdfPlanner.enqueue(job.Id, template.Base_Object_API__c, safeFilter, ordered, blockSize);
        return job.Id;
    }

    public static Id retry(Id jobId) {
        // Re-read under lock after checking the current user's job access.
        DocGen_Job__c visibleJob = authorizedJob(jobId);
        Id userId = UserInfo.getUserId();
        if (visibleJob.OwnerId != userId || visibleJob.CreatedById != userId) {
            throw new DocGenException('Only the original owner can retry this download.');
        }
        /* code-analyzer-suppress ApexFlsViolation */
        DocGen_Job__c job = [
            SELECT OwnerId, CreatedById, Status__c, Total_Records__c, Browser_Batch_Id__c, Browser_Merge__c
            FROM DocGen_Job__c
            WHERE Id = :jobId
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        if (job.OwnerId != userId || job.CreatedById != userId || !job.Browser_Merge__c || !retryable(job)) {
            throw new DocGenException('This job has no finished render attempt to retry.');
        }
        Id batchId = Database.executeBatch(new DocGenBrowserPdfBatch(jobId), 1);
        DocGen_Job__c updateJob = new DocGen_Job__c(
            Id = jobId,
            Browser_Revision__c = newRevision(),
            Browser_Batch_Id__c = String.valueOf(batchId),
            Status__c = 'Processing',
            Error_Count__c = 0,
            Error_Log__c = null
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(updateJob, AccessLevel.SYSTEM_MODE);
        return jobId;
    }

    public static JobDescription describe(Id jobId) {
        DocGen_Job__c job = authorizedJob(jobId);
        JobDescription response = new JobDescription();
        response.jobId = jobId;
        response.revisionKey = job.Browser_Revision__c;
        response.status = job.Status__c;
        response.totalSources = count(job.Total_Records__c);
        response.successCount = count(job.Success_Count__c);
        response.errorCount = count(job.Error_Count__c);
        response.ready = isReady(job);
        response.filename =
            (String.isBlank(job.Label__c) ? job.Name : job.Label__c)
                .replaceAll('[^a-zA-Z0-9 ._-]', '_')
                .trim()
                .left(140) + '.pdf';
        return response;
    }

    public static String downloadUrl(Id jobId) {
        if (!describe(jobId).ready) {
            throw new DocGenException('This bulk PDF is not ready to download.');
        }
        return pageUrl(jobId);
    }

    public static String pageUrl(Id jobId) {
        PageReference download = Page.DocGenBulkPdfDownload;
        download.getParameters().put('jobId', String.valueOf(jobId));
        return URL.getOrgDomainUrl().toExternalForm() + download.getUrl();
    }

    public static ManifestPage getManifestPage(Id jobId, String revisionKey, Integer afterOrdinal) {
        DocGen_Job__c job = readyRevision(jobId, revisionKey);
        Integer total = count(job.Total_Records__c);
        Integer cursor = afterOrdinal == null ? 0 : afterOrdinal;
        if (cursor < 0 || cursor > total) {
            throw new DocGenException('Invalid PDF manifest position.');
        }
        Integer last = Math.min(total, cursor + PAGE_SIZE);
        Map<Integer, Id> pins = pinnedVersions(jobId, cursor + 1, last);
        Map<Id, ContentVersion> versions = readableVersions(new Set<Id>(pins.values()));
        ManifestPage response = new ManifestPage();
        for (Integer ordinal = cursor + 1; ordinal <= last; ordinal++) {
            ContentVersion version = versions.get(pins.get(ordinal));
            if (version == null) {
                throw unavailable();
            }
            Source source = new Source();
            source.ordinal = ordinal;
            source.versionId = version.Id;
            source.bytes = version.ContentSize;
            source.checksum = version.Checksum.toLowerCase();
            response.sources.add(source);
        }
        response.nextAfterOrdinal = last;
        response.done = last == total;
        return response;
    }

    public static List<String> getSources(Id jobId, String revisionKey, List<Integer> ordinals) {
        DocGen_Job__c job = readyRevision(jobId, revisionKey);
        if (ordinals == null || ordinals.isEmpty() || ordinals.size() > MAX_SOURCES_PER_READ) {
            throw new DocGenException('Request between 1 and 16 PDF sources.');
        }

        Integer total = count(job.Total_Records__c);
        Integer first = total;
        Integer last = 1;
        Set<Integer> uniqueOrdinals = new Set<Integer>();
        for (Integer ordinal : ordinals) {
            if (ordinal == null || ordinal < 1 || ordinal > total || !uniqueOrdinals.add(ordinal)) {
                throw new DocGenException('Invalid or duplicate PDF source position.');
            }
            first = Math.min(first, ordinal);
            last = Math.max(last, ordinal);
        }
        if (last - first + 1 > PAGE_SIZE) {
            throw new DocGenException('Request PDF sources within a span of 100 positions.');
        }

        Map<Integer, Id> pins = pinnedVersions(jobId, first, last);
        Set<Id> versionIds = new Set<Id>();
        for (Integer ordinal : ordinals) {
            versionIds.add(pins.get(ordinal));
        }
        Map<Id, ContentVersion> metadata = readableVersions(versionIds);
        if (metadata.size() != versionIds.size()) {
            throw unavailable();
        }
        Integer bytesRequested = 0;
        for (Integer ordinal : ordinals) {
            bytesRequested += metadata.get(pins.get(ordinal)).ContentSize;
        }
        if (bytesRequested > MAX_SOURCE_BYTES) {
            throw new DocGenException('A request can read up to 1 MiB of PDF source data.');
        }

        Map<Id, ContentVersion> bodies = new Map<Id, ContentVersion>(
            [
                SELECT Id, VersionData
                FROM ContentVersion
                WHERE
                    Id IN :versionIds
                    AND ContentSize > 0
                    AND ContentSize <= :MAX_SOURCE_BYTES
                    AND FileExtension = 'pdf'
                WITH USER_MODE
            ]
        );
        List<String> result = new List<String>();
        for (Integer ordinal : ordinals) {
            Id versionId = pins.get(ordinal);
            ContentVersion body = bodies.get(versionId);
            if (
                body == null ||
                body.VersionData == null ||
                body.VersionData.size() != metadata.get(versionId).ContentSize
            ) {
                throw unavailable();
            }
            result.add(EncodingUtil.base64Encode(body.VersionData));
        }
        return result;
    }

    private static DocGen_Job__c authorizedJob(Id jobId) {
        if (jobId == null || UserInfo.getUserType() == 'Guest' || jobId.getSObjectType() != DocGen_Job__c.sObjectType) {
            throw unavailable();
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Job__c.sObjectType,
            new Set<String>{
                'Name',
                'OwnerId',
                'CreatedById',
                'Status__c',
                'Total_Records__c',
                'Success_Count__c',
                'Error_Count__c',
                'Browser_Merge__c',
                'Label__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Job__c> jobs = [
            SELECT
                Name,
                OwnerId,
                CreatedById,
                Status__c,
                Total_Records__c,
                Success_Count__c,
                Error_Count__c,
                Browser_Merge__c,
                Browser_Revision__c,
                Browser_Batch_Id__c,
                Label__c
            FROM DocGen_Job__c
            WHERE Id = :jobId AND Browser_Merge__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (jobs.isEmpty() || (jobs[0].OwnerId != UserInfo.getUserId() && !isAdministrator())) {
            throw unavailable();
        }
        return jobs[0];
    }

    private static Boolean isAdministrator() {
        if (FeatureManagement.checkPermission('DocGen_Admin_Access')) {
            return true;
        }
        try {
            List<User> users = [
                SELECT Profile.PermissionsModifyAllData
                FROM User
                WHERE Id = :UserInfo.getUserId()
                WITH USER_MODE
                LIMIT 1
            ];
            return !users.isEmpty() && users[0].Profile.PermissionsModifyAllData == true;
        } catch (QueryException e) {
            return false;
        }
    }

    private static Boolean retryable(DocGen_Job__c job) {
        if (
            String.isBlank(job.Browser_Batch_Id__c) ||
            job.Status__c == 'Completed' ||
            count(job.Total_Records__c) == 0
        ) {
            return false;
        }
        /* code-analyzer-suppress ApexFlsViolation */
        List<AsyncApexJob> attempts = [
            SELECT Status
            FROM AsyncApexJob
            WHERE Id = :job.Browser_Batch_Id__c
            WITH SYSTEM_MODE
        ];
        return !attempts.isEmpty() && INACTIVE_BATCH.contains(attempts[0].Status);
    }

    private static Boolean isReady(DocGen_Job__c job) {
        return job.Status__c == 'Completed' &&
            count(job.Total_Records__c) > 0 &&
            count(job.Success_Count__c) == count(job.Total_Records__c) &&
            count(job.Error_Count__c) == 0 &&
            String.isNotBlank(job.Browser_Revision__c);
    }

    private static DocGen_Job__c readyRevision(Id jobId, String revisionKey) {
        DocGen_Job__c job = authorizedJob(jobId);
        if (!isReady(job) || String.isBlank(revisionKey) || !job.Browser_Revision__c.equals(revisionKey)) {
            throw new DocGenException('This PDF download is no longer ready. Refresh the job and try again.');
        }
        return job;
    }

    private static Map<Integer, Id> pinnedVersions(Id jobId, Integer first, Integer last) {
        Map<Integer, Id> pins = new Map<Integer, Id>();
        if (first > last) {
            return pins;
        }
        // The job has been authorized and the block object is package-internal.
        /* code-analyzer-suppress ApexFlsViolation */
        for (DocGen_Browser_Pdf_Block__c block : [
            SELECT First_Ordinal__c, Last_Ordinal__c, Complete__c, Version_Ids__c
            FROM DocGen_Browser_Pdf_Block__c
            WHERE Job__c = :jobId AND Last_Ordinal__c >= :first AND First_Ordinal__c <= :last
            WITH SYSTEM_MODE
            LIMIT 101
        ]) {
            if (!block.Complete__c || String.isBlank(block.Version_Ids__c)) {
                throw unavailable();
            }
            List<Id> versions = (List<Id>) JSON.deserialize(block.Version_Ids__c, List<Id>.class);
            Integer start = block.First_Ordinal__c.intValue();
            Integer endOrdinal = block.Last_Ordinal__c.intValue();
            if (versions.size() != endOrdinal - start + 1) {
                throw unavailable();
            }
            for (Integer ordinal = Math.max(first, start); ordinal <= Math.min(last, endOrdinal); ordinal++) {
                Id versionId = versions[ordinal - start];
                if (
                    versionId == null ||
                    versionId.getSObjectType() != ContentVersion.sObjectType ||
                    pins.containsKey(ordinal)
                ) {
                    throw unavailable();
                }
                pins.put(ordinal, versionId);
            }
        }
        if (pins.size() != last - first + 1) {
            throw unavailable();
        }
        return pins;
    }

    private static Map<Id, ContentVersion> readableVersions(Set<Id> versionIds) {
        Map<Id, ContentVersion> versions = new Map<Id, ContentVersion>();
        if (versionIds.isEmpty()) {
            return versions;
        }
        for (ContentVersion version : [
            SELECT Id, ContentSize, Checksum
            FROM ContentVersion
            WHERE Id IN :versionIds AND FileExtension = 'pdf' AND ContentSize > 0 AND ContentSize <= :MAX_SOURCE_BYTES
            WITH USER_MODE
        ]) {
            if (version.Checksum != null && Pattern.matches('[0-9A-Fa-f]{32}', version.Checksum)) {
                versions.put(version.Id, version);
            }
        }
        return versions;
    }

    public static Integer count(Decimal value) {
        return value == null ? 0 : value.intValue();
    }

    private static String newRevision() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(128));
    }

    private static DocGenException unavailable() {
        return new DocGenException('The requested bulk PDF or a pinned source file is unavailable.');
    }
}
