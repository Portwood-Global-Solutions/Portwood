public with sharing class PortwoodPdfReadyNotification {
    public static Id enqueue(Id manifestId) {
        return System.enqueueJob(new Delivery(manifestId));
    }

    public static void send(Id manifestId) {
        String pageReference = targetPageReference(manifestId);
        CustomNotificationType notificationType = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = 'Portwood_Pdf_Ready'
            LIMIT 1
        ];
        new Messaging.CustomNotification(notificationType.Id, null, 'Your Portwood PDF is ready',
            'Open the download page to save your PDF.', null, pageReference).send(new Set<String>{UserInfo.getUserId()});
    }

    @TestVisible
    private static String targetPageReference(Id manifestId) {
        if (manifestId == null || ApexPdfRangeRest.describeRevision(String.valueOf(manifestId)) == null) {
            throw new IllegalArgumentException('The private PDF revision is unavailable.');
        }

        PageReference downloadPage = Page.PortwoodPdfDownload;
        downloadPage.getParameters().put('id', String.valueOf(manifestId));
        String downloadUrl = URL.getOrgDomainUrl().toExternalForm() + downloadPage.getUrl();
        return JSON.serialize(new Map<String, Object>{
            'type' => 'standard__webPage',
            'attributes' => new Map<String, String>{'url' => downloadUrl}
        });
    }

    @TestVisible
    private class Delivery implements Queueable {
        private final Id manifestId;

        @TestVisible
        private Delivery(Id manifestId) {
            this.manifestId = manifestId;
        }

        public void execute(QueueableContext context) {
            PortwoodPdfReadyNotification.send(manifestId);
        }
    }
}
