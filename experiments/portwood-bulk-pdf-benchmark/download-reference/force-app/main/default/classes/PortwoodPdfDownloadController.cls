/** Serves bounded reads to the authenticated PDF download page. */
global with sharing class PortwoodPdfDownloadController {
    @RemoteAction
    global static Map<String, Object> describe(String revisionId) {
        ApexPdfAppendManifest manifest = ApexPdfRangeRest.describeRevision(revisionId);
        if (manifest == null) return null;

        List<Integer> chunkSizes = new List<Integer>();
        for (ApexPdfAppendManifest.Chunk chunk : manifest.chunks) chunkSizes.add(chunk.size);

        return new Map<String, Object>{
            'revisionKey' => String.valueOf(Id.valueOf(revisionId)),
            'ownerKey' => String.valueOf(UserInfo.getUserId()),
            'totalBytes' => manifest.totalBytes,
            'rangeBytes' => ApexPdfRangeRest.MAX_RANGE_BYTES,
            'fileName' => 'portwood.pdf',
            'chunkSizes' => chunkSizes
        };
    }

    @RemoteAction
    global static Map<String, Object> readRange(String revisionId, Integer startByte, Integer endByte) {
        Blob bytes = ApexPdfRangeRest.readRevision(revisionId, startByte, endByte);
        if (bytes == null || bytes.size() != endByte - startByte + 1) return null;

        return new Map<String, Object>{
            'data' => EncodingUtil.base64Encode(bytes),
            'apexCallouts' => Limits.getCallouts()
        };
    }
}
