@IsTest
private class PortwoodPdfReadyNotificationTest {
    @IsTest
    static void addressesThePrivateRevisionOnTheAuthenticatedOrg() {
        ContentVersion chunk = save(ApexPdfAppendManifest.CHUNK_DESCRIPTION, Blob.valueOf('%PDF-'));
        ApexPdfAppendManifest revision = new ApexPdfAppendManifest();
        revision.totalBytes = chunk.VersionData.size();
        revision.chunks = new List<ApexPdfAppendManifest.Chunk>{
            new ApexPdfAppendManifest.Chunk(chunk.Id, revision.totalBytes)
        };
        ContentVersion manifest = save(ApexPdfAppendManifest.DESCRIPTION, Blob.valueOf(JSON.serialize(revision)));

        assertTarget(manifest.Id);
        Savepoint beforeEnqueue = Database.setSavepoint();
        Id deliveryJobId = PortwoodPdfReadyNotification.enqueue(manifest.Id);
        Assert.isNotNull(deliveryJobId, 'The caller can monitor the separate notification job.');
        Database.rollback(beforeEnqueue);
    }

    @IsTest
    static void addressesAPrivateArchiveManifest() {
        Blob bytes = Blob.valueOf('%PDF-');
        PortwoodPdfArchive__c chunk = PortwoodPdfArchiveStore.part(null, 'notification-test', 1, bytes);
        insert as system chunk;
        ApexPdfAppendManifest revision = new ApexPdfAppendManifest();
        revision.runKey = 'notification-test';
        revision.totalBytes = bytes.size();
        revision.chunks = new List<ApexPdfAppendManifest.Chunk>{
            new ApexPdfAppendManifest.Chunk(chunk.Id, revision.totalBytes)
        };
        assertTarget(PortwoodPdfArchiveStore.commitManifest(null, revision));
    }

    @IsTest
    static void rejectsAnUnrelatedPrivateFileBeforeSending() {
        ContentVersion unrelated = save('Unrelated private file', Blob.valueOf('unrelated'));
        PortwoodPdfReadyNotification.Delivery delivery = new PortwoodPdfReadyNotification.Delivery(unrelated.Id);
        try {
            delivery.execute(null);
            Assert.fail('A private File outside the PDF revision must be rejected.');
        } catch (IllegalArgumentException expected) {
            Assert.areEqual('The private PDF revision is unavailable.', expected.getMessage());
        }
    }

    private static void assertTarget(Id manifestId) {
        String expectedUrl = URL.getOrgDomainUrl().toExternalForm()
            + Page.PortwoodPdfDownload.getUrl() + '?id=' + manifestId;
        Map<String, Object> reference = (Map<String, Object>) JSON.deserializeUntyped(
            PortwoodPdfReadyNotification.targetPageReference(manifestId));
        Map<String, Object> attributes = (Map<String, Object>) reference.get('attributes');
        Assert.areEqual('standard__webPage', reference.get('type'));
        Assert.areEqual(expectedUrl, attributes.get('url'));
    }

    private static ContentVersion save(String description, Blob bytes) {
        ContentVersion file = new ContentVersion(Title = 'Portwood notification test', PathOnClient = 'portwood.part',
            Description = description, SharingPrivacy = 'P', VersionData = bytes);
        insert file;
        return file;
    }
}
