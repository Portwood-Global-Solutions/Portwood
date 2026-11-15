@IsTest
private class ApexPdfRangeRestTest {
    @IsTest
    static void readsBinaryAcrossChunkBoundaries() {
        ContentVersion first = save(ApexPdfAppendManifest.CHUNK_DESCRIPTION, EncodingUtil.convertFromHex('255044462d'));
        ContentVersion second = save(ApexPdfAppendManifest.CHUNK_DESCRIPTION, EncodingUtil.convertFromHex('ff000aff'));
        ContentVersion manifest = manifestFor(first, second);

        RestResponse initial = request(manifest.Id, 'bytes=0-4');
        System.assertEquals(206, initial.statusCode);
        System.assertEquals('bytes 0-4/9', initial.headers.get('Content-Range'));
        System.assertEquals('255044462d', EncodingUtil.convertToHex(initial.responseBody));

        RestResponse across = request(manifest.Id, 'bytes=3-6');
        System.assertEquals(206, across.statusCode);
        System.assertEquals('bytes 3-6/9', across.headers.get('Content-Range'));
        System.assertEquals('462dff00', EncodingUtil.convertToHex(across.responseBody));
        System.assertEquals('application/pdf', across.headers.get('Content-Type'));
        System.assertEquals('bytes', across.headers.get('Accept-Ranges'));
        System.assertEquals(initial.headers.get('ETag'), across.headers.get('ETag'));
        System.assertEquals('0', across.headers.get('X-Portwood-Callouts'));
        System.assert(Integer.valueOf(across.headers.get('X-Portwood-Heap-Bytes')) > 0);

        RestResponse suffix = request(manifest.Id, 'bytes=-2');
        System.assertEquals(206, suffix.statusCode);
        System.assertEquals('bytes 7-8/9', suffix.headers.get('Content-Range'));
        System.assertEquals('0aff', EncodingUtil.convertToHex(suffix.responseBody));

        RestResponse clamped = request(manifest.Id, 'bytes=7-9999999999');
        RestResponse openEnded = request(manifest.Id, 'bytes=7-');
        System.assertEquals(206, clamped.statusCode);
        System.assertEquals(clamped.headers.get('Content-Range'), openEnded.headers.get('Content-Range'));
        System.assertEquals(clamped.responseBody, openEnded.responseBody);

        Map<String, Object> download = PortwoodPdfDownloadController.describe(manifest.Id);
        System.assertEquals(9, download.get('totalBytes'));
        System.assertEquals(new List<Integer>{5, 4}, download.get('chunkSizes'));
        Map<String, Object> part = PortwoodPdfDownloadController.readRange(manifest.Id, 3, 6);
        System.assertEquals('462dff00', EncodingUtil.convertToHex(EncodingUtil.base64Decode((String) part.get('data'))));
        System.assertEquals(0, part.get('apexCallouts'));
        System.assertEquals(null, PortwoodPdfDownloadController.readRange(manifest.Id, 7, 9));
    }

    @IsTest
    static void rejectsUnboundedRequestsAndUnrecognizedFiles() {
        ContentVersion first = save(ApexPdfAppendManifest.CHUNK_DESCRIPTION, Blob.valueOf('first'));
        ContentVersion second = save(ApexPdfAppendManifest.CHUNK_DESCRIPTION, Blob.valueOf('next'));
        ContentVersion manifest = manifestFor(first, second);
        System.assertEquals(400, request(manifest.Id, null).statusCode);
        for (String invalid : new List<String>{'bytes=9-10', 'bytes=5-1', 'bytes=0-0,2-2', 'bytes=-0', 'bytes=-'}) {
            RestResponse response = request(manifest.Id, invalid);
            System.assertEquals(400, response.statusCode, invalid);
            System.assertEquals('bytes */9', response.headers.get('Content-Range'), invalid);
        }
        System.assertEquals(404, request(first.Id, 'bytes=0-1').statusCode);
        System.assertEquals(404, request((Id) '068000000000001', 'bytes=0-1').statusCode);

        ContentVersion badData = save(ApexPdfAppendManifest.DESCRIPTION, Blob.valueOf('{]'));
        System.assertEquals(404, request(badData.Id, 'bytes=0-1').statusCode);

        ContentVersion unrelated = save('Unrelated private file', Blob.valueOf('secret'));
        ContentVersion mixed = manifestFor(first, unrelated);
        System.assertEquals(404, request(mixed.Id, 'bytes=4-7').statusCode);

        ContentVersion mismatch = save(ApexPdfAppendManifest.DESCRIPTION, Blob.valueOf(JSON.serialize(
            new Map<String, Object>{'totalBytes' => 6, 'chunks' => new List<Object>{
                new Map<String, Object>{'versionId' => first.Id, 'size' => 6}
            }})));
        System.assertEquals(404, request(mismatch.Id, 'bytes=0-4').statusCode);

        ContentVersion largeSize = save(ApexPdfAppendManifest.DESCRIPTION, Blob.valueOf(JSON.serialize(
            new Map<String, Object>{'totalBytes' => 1048576, 'chunks' => new List<Object>{
                new Map<String, Object>{'versionId' => first.Id, 'size' => 524288},
                new Map<String, Object>{'versionId' => second.Id, 'size' => 524288}
            }})));
        RestResponse oversized = request(largeSize.Id, 'bytes=0-524288');
        System.assertEquals(400, oversized.statusCode);
        System.assertEquals('bytes */1048576', oversized.headers.get('Content-Range'));
    }

    @IsTest
    static void rejectsRevisionForOtherUsers() {
        String random = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        User other = new User(Username = 'range-other-' + random + '@example.test', Alias = 'pwother',
            LastName = 'Portwood range test', Email = 'other@example.test', TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US',
            ProfileId = UserInfo.getProfileId());
        insert other;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ContentVersion first = save(ApexPdfAppendManifest.CHUNK_DESCRIPTION, Blob.valueOf('first'));
            ContentVersion second = save(ApexPdfAppendManifest.CHUNK_DESCRIPTION, Blob.valueOf('next'));
            ContentVersion manifest = manifestFor(first, second);
            Account account = new Account(Name = 'Private PDF archive');
            insert account;
            Id archive = createArchive(account.Id, 'first', 'next');
            System.assertEquals(206, request(manifest.Id, 'bytes=0-4').statusCode);
            System.assertEquals(206, request(archive, 'bytes=0-4').statusCode);
            System.runAs(other) {
                System.assertEquals(404, request(manifest.Id, 'bytes=0-4').statusCode);
                System.assertEquals(null, PortwoodPdfDownloadController.describe(manifest.Id));
                System.assertEquals(null, PortwoodPdfDownloadController.readRange(manifest.Id, 0, 4));
                System.assertEquals(404, request(archive, 'bytes=0-4').statusCode);
                System.assertEquals(null, PortwoodPdfDownloadController.describe(archive));
                System.assertEquals(null, PortwoodPdfDownloadController.readRange(archive, 0, 4));
            }
        }
    }

    @IsTest
    static void readsPrivateArchiveAndRejectsMixedStorage() {
        Account account = new Account(Name = 'Private PDF archive');
        insert account;
        Id archive = createArchive(account.Id, '%PDF-', 'data');

        ApexPdfAppendManifest descriptor = ApexPdfRangeRest.describeRevision(archive);
        System.assertEquals(9, descriptor.totalBytes);
        System.assertEquals('F-da', ApexPdfRangeRest.readRevision(archive, 3, 6).toString());
        System.assertEquals(new List<Integer>{5, 4}, PortwoodPdfDownloadController.describe(archive).get('chunkSizes'));
        RestResponse across = request(archive, 'bytes=3-6');
        System.assertEquals(206, across.statusCode);
        System.assertEquals('F-da', across.responseBody.toString());
        System.assertEquals('bytes 3-6/9', across.headers.get('Content-Range'));
        System.assertEquals('"' + archive + '"', across.headers.get('ETag'));
        System.assertEquals(404, request(descriptor.chunks[0].versionId, 'bytes=0-1').statusCode);

        descriptor.chunks[1].versionId = (Id) '068000000000001';
        Id mixed = PortwoodPdfArchiveStore.commitManifest(account.Id, descriptor);
        System.assertEquals(null, ApexPdfRangeRest.describeRevision(mixed));
        System.assertEquals(null, ApexPdfRangeRest.readRevision(mixed, 0, 1));
        System.assertEquals(404, request(mixed, 'bytes=0-1').statusCode);
    }

    private static Id createArchive(Id accountId, String first, String second) {
        String runKey = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        Blob firstData = Blob.valueOf(first);
        Blob secondData = Blob.valueOf(second);
        List<PortwoodPdfArchive__c> parts = new List<PortwoodPdfArchive__c>{
            PortwoodPdfArchiveStore.part(accountId, runKey, 1, firstData),
            PortwoodPdfArchiveStore.part(accountId, runKey, 2, secondData)
        };
        insert as system parts;
        ApexPdfAppendManifest descriptor = new ApexPdfAppendManifest();
        descriptor.runKey = runKey;
        descriptor.totalBytes = firstData.size() + secondData.size();
        descriptor.chunks = new List<ApexPdfAppendManifest.Chunk>{
            new ApexPdfAppendManifest.Chunk(parts[0].Id, firstData.size()),
            new ApexPdfAppendManifest.Chunk(parts[1].Id, secondData.size())
        };
        return PortwoodPdfArchiveStore.commitManifest(accountId, descriptor);
    }

    private static ContentVersion manifestFor(ContentVersion first, ContentVersion second) {
        List<Object> chunks = new List<Object>{
            new Map<String, Object>{'versionId' => first.Id, 'size' => first.VersionData.size()},
            new Map<String, Object>{'versionId' => second.Id, 'size' => second.VersionData.size()}
        };
        return save(ApexPdfAppendManifest.DESCRIPTION, Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'totalBytes' => first.VersionData.size() + second.VersionData.size(), 'chunks' => chunks
        })));
    }

    private static ContentVersion save(String description, Blob bytes) {
        ContentVersion file = new ContentVersion(Title = 'Portwood test', PathOnClient = 'portwood.part',
            Description = description, SharingPrivacy = 'P', VersionData = bytes);
        insert file;
        return file;
    }

    private static RestResponse request(Id versionId, String rangeHeader) {
        RestRequest request = new RestRequest();
        request.httpMethod = 'GET';
        request.requestURI = '/services/apexrest/portwood/pdf/' + versionId;
        if (rangeHeader != null) request.addHeader('rAnGe', rangeHeader);
        RestContext.request = request;
        RestContext.response = new RestResponse();
        ApexPdfRangeRest.get();
        return RestContext.response;
    }
}
