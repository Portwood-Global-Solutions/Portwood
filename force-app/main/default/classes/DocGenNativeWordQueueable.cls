/** Copy a static Word package in async heap without expanding all media at once. */
public with sharing class DocGenNativeWordQueueable implements Queueable {
    private Id sourceId;
    private Id recordId;
    private String title;

    public DocGenNativeWordQueueable(Id sourceId, Id recordId, String title) {
        this.sourceId = sourceId;
        this.recordId = recordId;
        this.title = title;
    }

    public void execute(QueueableContext context) {
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
        // sourceId was resolved from the authorized template's active version.
        Blob source = [SELECT VersionData FROM ContentVersion WHERE Id = :sourceId WITH SYSTEM_MODE].VersionData;
        Blob result = copyIfStatic(source);
        if (result == null)
            return; // Real merge tags use the existing merge engine.
        ContentVersion file = new ContentVersion(
            Title = String.isBlank(title) ? 'Document' : title,
            PathOnClient = outputPath(context.getJobId()),
            VersionData = result
        );
        if (recordId != null)
            file.FirstPublishLocationId = recordId;
        DocGenFlsGuard.assertCreateable(
            file,
            new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId' }
        );
        Database.insert(file, AccessLevel.USER_MODE);
    }

    public static String outputPath(Id jobId) {
        // enqueueJob can retain a 15-character Id in tests/callers while the
        // QueueableContext supplies 18. Normalize through the String overload.
        Id canonicalId = Id.valueOf(String.valueOf(jobId));
        return 'docgen_native_word_' + canonicalId + '.docx';
    }

    @TestVisible
    private static Blob copyIfStatic(Blob source) {
        Compression.ZipReader reader = new Compression.ZipReader(source);
        Boolean hasBody = false;
        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            if (name == 'word/document.xml')
                hasBody = true;
            if (
                name == 'word/document.xml' ||
                (name.startsWith('word/header') && name.endsWith('.xml')) ||
                (name.startsWith('word/footer') && name.endsWith('.xml'))
            ) {
                if (hasMergeText(reader.extract(name).toString()))
                    return null;
            }
        }
        if (!hasBody)
            throw new DocGenException('Word document body is missing.');
        Compression.ZipWriter writer = new Compression.ZipWriter();
        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            Blob part = reader.extract(name);
            if (name.endsWith('.rels')) {
                String xml = removeAttachedTemplate(part.toString(), true);
                DocGenAssetPolicy.assertOfficeRelationshipXml(xml);
                part = Blob.valueOf(xml);
            } else if (name == 'word/settings.xml') {
                part = Blob.valueOf(removeAttachedTemplate(part.toString(), false));
            }
            // ZipWriter compresses each entry while it is added. Never retain a
            // passthrough map of expanded EMF/PNG blobs or a base64 archive copy.
            writer.addEntry(name, part);
        }
        return writer.getArchive();
    }

    private static Boolean hasMergeText(String xml) {
        if (xml.containsIgnoreCase('<!DOCTYPE') || xml.containsIgnoreCase('<!ENTITY'))
            throw new DocGenException('Unsupported Word XML declarations.');
        if (xml.contains('&#123;') || xml.containsIgnoreCase('&#x7b;'))
            return true;
        // Match the engine's GUID exemption. Every other opener, including a
        // fragmented or malformed tag and tags using another namespace prefix,
        // belongs to the normal merge engine. Only tiny GUID candidates see regex.
        Integer scan = 0;
        while (scan < xml.length()) {
            Integer start = xml.indexOf('{', scan);
            if (start == -1)
                break;
            Integer endIdx = xml.indexOf('}', start + 1);
            if (endIdx != start + 37 || !DocGenService.isOoxmlGuidToken(xml.substring(start + 1, endIdx)))
                return true;
            scan = endIdx + 1;
        }
        return false;
    }

    private static String attribute(String tag, String name) {
        for (String quote : new List<String>{ '"', '\'' }) {
            String marker = name + '=' + quote;
            Integer start = tag.indexOf(marker);
            if (start == -1)
                continue;
            start += marker.length();
            Integer endIdx = tag.indexOf(quote, start);
            if (endIdx != -1)
                return tag.substring(start, endIdx);
        }
        return null;
    }

    /** An attached .dotx path is Word editing metadata, never an output asset. */
    private static String removeAttachedTemplate(String xml, Boolean relationships) {
        List<String> parts = new List<String>();
        Integer cursor = 0;
        Integer scan = 0;
        while (scan < xml.length()) {
            Integer start = xml.indexOf('<', scan);
            if (start == -1)
                break;
            Integer endIdx = xml.indexOf('>', start);
            if (endIdx == -1)
                break;
            scan = endIdx + 1;
            String tag = xml.substring(start, scan);
            Integer nameEnd = 1;
            while (
                nameEnd < tag.length() &&
                tag.charAt(nameEnd) != 32 &&
                tag.charAt(nameEnd) != 9 &&
                tag.charAt(nameEnd) != 10 &&
                tag.charAt(nameEnd) != 13 &&
                tag.charAt(nameEnd) != 47 &&
                tag.charAt(nameEnd) != 62
            )
                nameEnd++;
            String name = tag.substring(1, nameEnd);
            String local = name.contains(':') ? name.substringAfterLast(':') : name;
            String relationshipType = relationships ? attribute(tag, 'Type') : null;
            Boolean remove = relationships
                ? local.equals('Relationship') &&
                  relationshipType != null &&
                  relationshipType.endsWith('/attachedTemplate')
                : local.equals('attachedTemplate');
            if (!remove)
                continue;
            if (!tag.endsWith('/>')) {
                Integer close = xml.indexOf('</' + name + '>', scan);
                if (close == -1)
                    throw new DocGenException('Invalid attached template metadata.');
                scan = close + name.length() + 3;
            }
            parts.add(xml.substring(cursor, start));
            cursor = scan;
        }
        if (cursor == 0)
            return xml;
        parts.add(xml.substring(cursor));
        return String.join(parts, '');
    }
}
