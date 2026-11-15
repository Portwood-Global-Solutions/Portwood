/** Scratch data-storage adapter for owner-only PDF manifests and bounded byte parts. */
public with sharing class PortwoodPdfArchiveStore {
    public class ArchiveException extends Exception {}

    public static final Integer MAX_PART_BYTES = 393216;
    private static final Integer FIELD_CHARACTERS = 131072;
    private static final String PART = 'chunk';
    private static final String MANIFEST_KIND = 'manifest';

    public static Boolean isArchiveId(Id recordId) {
        return recordId != null && recordId.getSObjectType() == PortwoodPdfArchive__c.SObjectType;
    }

    public static PortwoodPdfArchive__c part(Id accountId, String runKey, Integer ordinal, Blob bytes) {
        if (bytes == null || bytes.size() < 1 || bytes.size() > MAX_PART_BYTES) {
            throw new ArchiveException('The PDF archive part exceeds its byte limit.');
        }
        return record(accountId, runKey, PART, ordinal, bytes);
    }

    public static Id commitManifest(Id accountId, ApexPdfAppendManifest manifest) {
        Blob bytes = Blob.valueOf(JSON.serialize(manifest));
        if (bytes.size() > 131072) throw new ArchiveException('The PDF manifest is too large.');
        PortwoodPdfArchive__c descriptor = record(accountId, manifest.runKey, MANIFEST_KIND, null, bytes);
        insert as system descriptor;
        return descriptor.Id;
    }

    public static ApexPdfAppendManifest readDescriptor(Id manifestId, Id owner) {
        if (owner == null || owner != UserInfo.getUserId() || !isArchiveId(manifestId)) return null;
        List<PortwoodPdfArchive__c> matches = [
            SELECT Bytes__c, Data1__c, Data2__c, Data3__c, Data4__c
            FROM PortwoodPdfArchive__c
            WHERE Id = :manifestId AND OwnerId = :owner AND Kind__c = :MANIFEST_KIND WITH SYSTEM_MODE
        ];
        if (matches.isEmpty() || matches[0].Bytes__c < 1 || matches[0].Bytes__c > 131072) return null;
        Blob body = decode(matches[0]);
        if (body == null) return null;
        try {
            return (ApexPdfAppendManifest) JSON.deserialize(body.toString(), ApexPdfAppendManifest.class);
        } catch (Exception invalidManifest) {
            return null;
        }
    }

    public static Map<Id, Blob> readParts(Map<Id, Integer> expectedSizes, Id owner) {
        if (owner == null || owner != UserInfo.getUserId() || expectedSizes == null || expectedSizes.isEmpty()) return null;
        Set<Id> partIds = expectedSizes.keySet();
        Map<Id, Blob> parts = new Map<Id, Blob>();
        for (PortwoodPdfArchive__c value : [
            SELECT Id, Bytes__c, Data1__c, Data2__c, Data3__c, Data4__c
            FROM PortwoodPdfArchive__c
            WHERE Id IN :partIds AND OwnerId = :owner AND Kind__c = :PART WITH SYSTEM_MODE
        ]) {
            if (value.Bytes__c < 1 || value.Bytes__c > MAX_PART_BYTES || value.Bytes__c != expectedSizes.get(value.Id)) {
                return null;
            }
            Blob body = decode(value);
            if (body == null) return null;
            parts.put(value.Id, body);
        }
        return parts.size() == expectedSizes.size() ? parts : null;
    }

    private static PortwoodPdfArchive__c record(Id accountId, String runKey, String kind, Integer ordinal, Blob bytes) {
        String encoded = EncodingUtil.base64Encode(bytes);
        return new PortwoodPdfArchive__c(
            Name = 'PW PDF ' + kind + ' ' + runKey + (ordinal == null ? '' : ' ' + ordinal),
            Account__c = accountId, RunKey__c = runKey, Kind__c = kind, Ordinal__c = ordinal,
            OwnerId = UserInfo.getUserId(), Bytes__c = bytes.size(),
            Data1__c = section(encoded, 0), Data2__c = section(encoded, 1),
            Data3__c = section(encoded, 2), Data4__c = section(encoded, 3)
        );
    }

    private static String section(String encoded, Integer index) {
        Integer start = index * FIELD_CHARACTERS;
        if (start >= encoded.length()) return null;
        return encoded.substring(start, Math.min(start + FIELD_CHARACTERS, encoded.length()));
    }

    private static Blob decode(PortwoodPdfArchive__c value) {
        if (value.Bytes__c == null || value.Data1__c == null) return null;
        List<String> parts = new List<String>{value.Data1__c};
        if (value.Data2__c != null) parts.add(value.Data2__c);
        if (value.Data3__c != null) parts.add(value.Data3__c);
        if (value.Data4__c != null) parts.add(value.Data4__c);
        try {
            Blob bytes = EncodingUtil.base64Decode(String.join(parts, ''));
            return bytes.size() == value.Bytes__c ? bytes : null;
        } catch (Exception corruptData) {
            return null;
        }
    }
}
