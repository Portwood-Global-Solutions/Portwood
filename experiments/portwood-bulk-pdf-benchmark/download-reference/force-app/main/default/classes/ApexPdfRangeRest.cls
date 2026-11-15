/** Reads a finalized private PDF revision in bounded byte ranges. */
@RestResource(urlMapping='/portwood/pdf/*')
global with sharing class ApexPdfRangeRest {
    public static final Integer MAX_RANGE_BYTES = 524288;
    private static final Integer MAX_MANIFEST_BYTES = 131072;
    private static final Integer MAX_MANIFEST_CHUNKS = 1024;
    private static final Pattern VERSION_URL = Pattern.compile('.*/portwood/pdf/([A-Za-z0-9]{15}|[A-Za-z0-9]{18})');
    private static final Pattern BYTE_RANGE = Pattern.compile('bytes=([0-9]{0,10})-([0-9]{0,10})');
    private static Integer sampledHeapBytes;

    @HttpGet
    global static void get() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        response.addHeader('Cache-Control', 'private, no-store, no-transform');
        response.addHeader('Accept-Ranges', 'bytes');
        sampledHeapBytes = 0;
        Matcher match = VERSION_URL.matcher(request.requestURI);
        Id revisionId = match.matches() ? parseRevisionId(match.group(1)) : null;
        if (revisionId == null) {
            unavailable(response);
            return;
        }

        Id owner = UserInfo.getUserId();
        try {
            ApexPdfAppendManifest manifest = loadPrivateRevision(revisionId, owner);
            if (manifest == null) {
                unavailable(response);
                return;
            }

            String rangeHeader = findRangeHeader(request);
            if (String.isBlank(rangeHeader)) {
                fail(response, 400, 'A Range header is required.');
                return;
            }

            ByteRange requested = parseRange(rangeHeader, manifest.totalBytes);
            if (requested == null) {
                response.addHeader('Content-Range', 'bytes */' + manifest.totalBytes);
                fail(response, 400, 'Request a single byte range up to 524288 bytes.');
                return;
            }

            Blob body = readBody(manifest, requested, owner, revisionId.getSObjectType());
            if (body == null || body.size() != requested.endByte - requested.start + 1) {
                unavailable(response);
                return;
            }

            response.statusCode = 206;
            response.addHeader('Content-Type', 'application/pdf');
            response.addHeader('Content-Disposition', 'attachment; filename="portwood.pdf"');
            response.addHeader('Content-Range', 'bytes ' + requested.start + '-' + requested.endByte + '/' + manifest.totalBytes);
            response.addHeader('ETag', '"' + revisionId + '"');
            response.responseBody = body;
            sampleHeap();
            response.addHeader('X-Portwood-Callouts', String.valueOf(Limits.getCallouts()));
            response.addHeader('X-Portwood-Heap-Bytes', String.valueOf(sampledHeapBytes));
        } catch (QueryException ignored) {
            unavailable(response);
        }
    }

    public static ApexPdfAppendManifest describeRevision(String revisionId) {
        Id parsedId = parseRevisionId(revisionId);
        ApexPdfAppendManifest manifest = loadPrivateRevision(parsedId, UserInfo.getUserId());
        if (manifest == null || selectSlices(manifest, new ByteRange(0, 0), parsedId.getSObjectType()) == null) return null;
        return manifest;
    }

    public static Blob readRevision(String revisionId, Integer startByte, Integer endByte) {
        if (startByte == null || endByte == null || startByte < 0 || endByte < startByte ||
            endByte - startByte >= MAX_RANGE_BYTES) return null;

        sampledHeapBytes = 0;
        Id owner = UserInfo.getUserId();
        Id parsedId = parseRevisionId(revisionId);
        ApexPdfAppendManifest manifest = loadPrivateRevision(parsedId, owner);
        if (manifest == null || endByte >= manifest.totalBytes) return null;
        return readBody(manifest, new ByteRange(startByte, endByte), owner, parsedId.getSObjectType());
    }

    private static Id parseRevisionId(String revisionId) {
        if (revisionId == null || (revisionId.length() != 15 && revisionId.length() != 18)) return null;
        try {
            Id parsedId = Id.valueOf(revisionId);
            Schema.SObjectType recordType = parsedId.getSObjectType();
            return recordType == ContentVersion.SObjectType || recordType == PortwoodPdfArchive__c.SObjectType ? parsedId : null;
        } catch (Exception invalidId) {
            return null;
        }
    }

    private static Blob readBody(ApexPdfAppendManifest manifest, ByteRange requested, Id owner, Schema.SObjectType recordType) {
        List<ChunkSlice> slices = selectSlices(manifest, requested, recordType);
        return slices == null ? null : readSlices(slices, owner, recordType);
    }

    private static ApexPdfAppendManifest loadPrivateRevision(Id revisionId, Id owner) {
        if (revisionId == null) return null;
        ApexPdfAppendManifest manifest = revisionId.getSObjectType() == PortwoodPdfArchive__c.SObjectType
            ? PortwoodPdfArchiveStore.readDescriptor(revisionId, owner) : readFileManifest(revisionId, owner);
        if (manifest == null || manifest.totalBytes == null || manifest.totalBytes <= 0 ||
            manifest.chunks == null || manifest.chunks.isEmpty() || manifest.chunks.size() > MAX_MANIFEST_CHUNKS) return null;
        return manifest;
    }

    private static ApexPdfAppendManifest readFileManifest(Id versionId, Id owner) {
        List<ContentVersion> rows = [
            SELECT Description, VersionData FROM ContentVersion WHERE Id = :versionId AND OwnerId = :owner
                AND SharingPrivacy = 'P' AND ContentLocation = 'S'
                AND ContentSize > 0 AND ContentSize <= :MAX_MANIFEST_BYTES WITH USER_MODE
        ];
        if (rows.isEmpty() || rows[0].Description != ApexPdfAppendManifest.DESCRIPTION) return null;
        try {
            return (ApexPdfAppendManifest) JSON.deserialize(rows[0].VersionData.toString(), ApexPdfAppendManifest.class);
        } catch (JSONException invalidJson) {
            return null;
        } catch (StringException invalidText) {
            return null;
        }
    }

    private static String findRangeHeader(RestRequest request) {
        for (String name : request.headers.keySet()) {
            if (name.equalsIgnoreCase('Range')) return request.headers.get(name);
        }
        return null;
    }

    private static ByteRange parseRange(String header, Integer total) {
        if (header.length() > 32) return null;
        Matcher match = BYTE_RANGE.matcher(header.trim().toLowerCase());
        if (!match.matches()) return null;
        String startText = match.group(1);
        String endText = match.group(2);
        Long start;
        Long endByte = total - 1;
        if (startText == '') {
            if (endText == '') return null;
            Long length = Long.valueOf(endText);
            if (length == 0) return null;
            start = length >= total ? 0L : total - length;
        } else {
            start = Long.valueOf(startText);
            if (endText != '') {
                Long requestedEnd = Long.valueOf(endText);
                if (requestedEnd < endByte) endByte = requestedEnd;
            }
        }
        if (start > endByte || endByte - start + 1 > MAX_RANGE_BYTES) return null;
        return new ByteRange(start.intValue(), endByte.intValue());
    }

    private static List<ChunkSlice> selectSlices(ApexPdfAppendManifest manifest, ByteRange range, Schema.SObjectType recordType) {
        List<ChunkSlice> result = new List<ChunkSlice>();
        Set<Id> seenIds = new Set<Id>();
        Integer offset = 0;
        for (ApexPdfAppendManifest.Chunk chunk : manifest.chunks) {
            if (chunk == null || chunk.versionId == null || chunk.versionId.getSObjectType() != recordType ||
                seenIds.contains(chunk.versionId) || chunk.size == null || chunk.size <= 0 ||
                chunk.size > MAX_RANGE_BYTES || chunk.size > manifest.totalBytes - offset) {
                return null;
            }
            seenIds.add(chunk.versionId);
            Integer nextOffset = offset + chunk.size;
            if (offset <= range.endByte && nextOffset > range.start) {
                result.add(new ChunkSlice(chunk.versionId, chunk.size, Math.max(0, range.start - offset),
                    Math.min(chunk.size, range.endByte - offset + 1)));
            }
            offset = nextOffset;
        }
        return offset == manifest.totalBytes ? result : null;
    }

    private static Blob readSlices(List<ChunkSlice> slices, Id owner, Schema.SObjectType recordType) {
        Map<Id, Integer> sliceSizes = new Map<Id, Integer>();
        for (ChunkSlice slice : slices) sliceSizes.put(slice.versionId, slice.size);

        Map<Id, Blob> chunks = recordType == PortwoodPdfArchive__c.SObjectType
            ? PortwoodPdfArchiveStore.readParts(sliceSizes, owner) : readFileParts(sliceSizes, owner);
        sampleHeap();
        if (chunks == null || chunks.size() != slices.size()) return null;

        List<String> hexSlices = new List<String>();
        for (ChunkSlice slice : slices) {
            Blob chunk = chunks.remove(slice.versionId);
            if (chunk == null || chunk.size() != slice.size) return null;
            if (slices.size() == 1 && slice.fromByte == 0 && slice.untilByte == slice.size) return chunk;

            String hex = EncodingUtil.convertToHex(chunk);
            hexSlices.add(hex.substring(2 * slice.fromByte, 2 * slice.untilByte));
            sampleHeap();
        }
        String joinedHex = String.join(hexSlices, '');
        Blob result = EncodingUtil.convertFromHex(joinedHex);
        sampleHeap();
        return result;
    }

    private static Map<Id, Blob> readFileParts(Map<Id, Integer> sliceSizes, Id owner) {
        Set<Id> versionIds = sliceSizes.keySet();
        List<ContentVersion> metadata = [
            SELECT Id, Description, ContentSize FROM ContentVersion WHERE Id IN :versionIds AND OwnerId = :owner
                AND SharingPrivacy = 'P' AND ContentLocation = 'S' WITH USER_MODE
        ];
        if (metadata.size() != sliceSizes.size()) return null;
        for (ContentVersion chunk : metadata) {
            if (chunk.Description != ApexPdfAppendManifest.CHUNK_DESCRIPTION || chunk.ContentSize != sliceSizes.get(chunk.Id)) {
                return null;
            }
        }

        // After verifying the stored sizes, this reads at most the range plus two partial chunks.
        Map<Id, Blob> chunks = new Map<Id, Blob>();
        for (ContentVersion chunk : [
            SELECT Id, VersionData FROM ContentVersion WHERE Id IN :versionIds AND OwnerId = :owner
                AND SharingPrivacy = 'P' AND ContentLocation = 'S'
                AND ContentSize > 0 AND ContentSize <= :MAX_RANGE_BYTES WITH USER_MODE
        ]) chunks.put(chunk.Id, chunk.VersionData);
        return chunks;
    }

    private static void sampleHeap() {
        sampledHeapBytes = Math.max(sampledHeapBytes, Limits.getHeapSize());
    }

    private static void unavailable(RestResponse response) {
        fail(response, 404, 'PDF revision is unavailable.');
    }

    private static void fail(RestResponse response, Integer code, String message) {
        response.statusCode = code;
        response.addHeader('Content-Type', 'text/plain; charset=utf-8');
        response.responseBody = Blob.valueOf(message);
    }

    private class ByteRange {
        private final Integer start;
        private final Integer endByte;

        ByteRange(Integer start, Integer endByte) {
            this.start = start;
            this.endByte = endByte;
        }
    }

    private class ChunkSlice {
        private final Id versionId;
        private final Integer size;
        private final Integer fromByte;
        private final Integer untilByte;

        ChunkSlice(Id versionId, Integer size, Integer fromByte, Integer untilByte) {
            this.versionId = versionId;
            this.size = size;
            this.fromByte = fromByte;
            this.untilByte = untilByte;
        }
    }
}
