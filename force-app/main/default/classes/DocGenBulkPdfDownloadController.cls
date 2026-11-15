/** Remoting boundary for the authenticated combined-PDF download page. */
global with sharing class DocGenBulkPdfDownloadController {
    @RemoteAction
    global static Object describe(String jobId) {
        return DocGenBrowserPdf.describe(parseJobId(jobId));
    }

    @RemoteAction
    global static Object getManifestPage(String jobId, String revisionKey, Integer afterOrdinal) {
        return DocGenBrowserPdf.getManifestPage(parseJobId(jobId), revisionKey, afterOrdinal);
    }

    @RemoteAction
    global static List<String> getSources(String jobId, String revisionKey, List<Integer> ordinals) {
        return DocGenBrowserPdf.getSources(parseJobId(jobId), revisionKey, ordinals);
    }

    private static Id parseJobId(String value) {
        try {
            Id jobId = Id.valueOf(value);
            return jobId.getSObjectType() == DocGen_Job__c.SObjectType ? jobId : null;
        } catch (Exception invalidId) {
            return null;
        }
    }
}
