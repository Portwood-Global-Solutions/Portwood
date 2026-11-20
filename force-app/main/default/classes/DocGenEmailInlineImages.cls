/** Resolves safe inline images from an EmailMessage without fetching external content. */
public with sharing class DocGenEmailInlineImages {
    private static final Integer MAX_FILE_BYTES = 2097152;
    private static final Integer MAX_FILE_LINKS = 1000;
    private static final Integer MAX_TAG_CHARS = 4096;
    private static final Integer MAX_SOURCE_CHARS = 2048;
    private static final Integer MAX_OVERSIZED_TAG_CHARS = 262144;
    private static final Integer MAX_IMAGE_ATTRIBUTES = 64;
    private static final Set<String> FILE_EXTENSIONS = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'bmp' };
    private static final Pattern IMAGE_OPEN = Pattern.compile('(?i)<img(?=[\\s/>])');
    private static final Pattern ATTRIBUTE = Pattern.compile(
        '(?is)\\s+([a-z_:][a-z0-9_:.\\-]*)(?:\\s*=\\s*(?:"([^"]*)"|\\\'([^\\\']*)\\\'|([^\\s<>="\\\']+)))?'
    );

    /** Updates only the fetched SObjects in memory. The stored email is untouched. */
    public static void prepare(List<SObject> emails) {
        Set<Id> withCid = new Set<Id>();
        for (SObject email : emails) {
            String html = (String) email.get('HtmlBody');
            if (html != null && html.containsIgnoreCase('cid:') && email.Id != null) {
                withCid.add(email.Id);
            }
        }
        Map<Id, Map<String, Set<Id>>> files = linkedFiles(withCid);
        for (SObject email : emails) {
            String html = (String) email.get('HtmlBody');
            if (html != null && html.containsIgnoreCase('<img')) {
                email.put('HtmlBody', rewrite(html, files.get(email.Id)));
            }
        }
    }

    private static Map<Id, Map<String, Set<Id>>> linkedFiles(Set<Id> emailIds) {
        Map<Id, Map<String, Set<Id>>> files = new Map<Id, Map<String, Set<Id>>>();
        if (emailIds.isEmpty()) {
            return files;
        }
        Integer limitRows = MAX_FILE_LINKS + 1;
        List<ContentDocumentLink> links;
        try {
            links = [
                SELECT
                    LinkedEntityId,
                    ContentDocumentId,
                    ContentDocument.Title,
                    ContentDocument.FileExtension,
                    ContentDocument.ContentSize,
                    ContentDocument.LatestPublishedVersionId,
                    ContentDocument.LatestPublishedVersion.ContentLocation,
                    ContentDocument.LatestPublishedVersion.PathOnClient
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :emailIds AND ContentDocument.FileExtension IN :FILE_EXTENSIONS
                WITH USER_MODE
                LIMIT :limitRows
            ];
        } catch (QueryException unavailable) {
            // A user who cannot read these Files still gets the message text.
            return files;
        }
        if (links.size() > MAX_FILE_LINKS) {
            // A partial result cannot prove that a filename is unique.
            return files;
        }
        for (ContentDocumentLink link : links) {
            ContentDocument file = link.ContentDocument;
            if (file == null || file.LatestPublishedVersionId == null) {
                continue;
            }
            if (!files.containsKey(link.LinkedEntityId)) {
                files.put(link.LinkedEntityId, new Map<String, Set<Id>>());
            }
            Map<String, Set<Id>> aliases = files.get(link.LinkedEntityId);
            Id versionId = file.LatestPublishedVersionId;
            // Keep rejected files in the ambiguity index. A shepherd URL must
            // never be generated for an external file or a link-backed version.
            ContentVersion latest = file.LatestPublishedVersion;
            Id usable = latest?.ContentLocation == 'S' &&
                file.ContentSize != null &&
                file.ContentSize <= MAX_FILE_BYTES
                ? versionId
                : null;
            String documentId = String.valueOf(link.ContentDocumentId);
            String version = String.valueOf(versionId);
            addAlias(aliases, documentId, usable);
            addAlias(aliases, documentId.left(15), usable);
            addAlias(aliases, version, usable);
            addAlias(aliases, version.left(15), usable);
            if (String.isNotBlank(file.Title)) {
                String title = file.Title.toLowerCase();
                String extension = '.' + file.FileExtension.toLowerCase();
                String filename = title.endsWith(extension) ? title : title + extension;
                addAlias(aliases, 'filename:' + filename, usable);
            }
            if (String.isNotBlank(latest?.PathOnClient)) {
                String path = latest.PathOnClient.replace('\\', '/');
                addAlias(aliases, 'filename:' + path.substring(path.lastIndexOf('/') + 1).toLowerCase(), usable);
            }
        }
        return files;
    }

    private static void addAlias(Map<String, Set<Id>> aliases, String key, Id versionId) {
        if (!aliases.containsKey(key)) {
            aliases.put(key, new Set<Id>());
        }
        aliases.get(key).add(versionId);
    }

    @TestVisible
    private static String rewrite(String html, Map<String, Set<Id>> aliases) {
        Matcher images = IMAGE_OPEN.matcher(html);
        List<String> parts = new List<String>();
        Integer written = 0;
        while (images.find()) {
            Integer start = images.start();
            if (start < written) {
                continue;
            }
            parts.add(html.substring(written, start));
            Integer tagEnd = boundedTagEnd(html, images.end());
            if (tagEnd < 0) {
                OmittedImage omitted = scanOmittedImage(html, images.end());
                if (omitted != null) {
                    tagEnd = omitted.tagEnd;
                    parts.add(replacementAlt(omitted.alt));
                } else {
                    // Consume one damaged tag without passing its URL to PDF rendering.
                    tagEnd = html.indexOf('>', images.end());
                    if (tagEnd < 0) {
                        return String.join(parts, '') + escapeText(html.substring(start));
                    }
                }
            } else {
                parts.add(safeImage(html.substring(images.end(), tagEnd), aliases));
            }
            written = tagEnd + 1;
        }
        if (written == 0) {
            return html;
        }
        parts.add(html.substring(written));
        return String.join(parts, '');
    }

    private static Integer boundedTagEnd(String html, Integer start) {
        Integer quote = 0;
        Integer stop = Math.min(html.length(), start + MAX_TAG_CHARS);
        for (Integer i = start; i < stop; i++) {
            Integer c = html.charAt(i);
            if (c == quote) {
                quote = 0;
            } else if (quote == 0) {
                if (c == 62) {
                    return i;
                }
                if (c == 34 || c == 39) {
                    quote = c;
                }
            }
        }
        return -1;
    }

    private class OmittedImage {
        Integer tagEnd;
        String alt;

        OmittedImage(Integer tagEnd, String alt) {
            this.tagEnd = tagEnd;
            this.alt = alt;
        }
    }

    /**
     * Recover the alt text of an oversized tag without copying or evaluating its
     * source. Email data URIs can be much larger than the normal tag scan.
     */
    private static OmittedImage scanOmittedImage(String html, Integer cursor) {
        Integer stop = Math.min(html.length(), cursor + MAX_OVERSIZED_TAG_CHARS);
        String alt;
        for (Integer attributes = 0; attributes < MAX_IMAGE_ATTRIBUTES; attributes++) {
            cursor = skipSpace(html, cursor, stop);
            if (cursor >= stop) {
                return null;
            }
            Integer current = html.charAt(cursor);
            if (current == 62) {
                return new OmittedImage(cursor, alt);
            }
            if (current == 47 && cursor + 1 < stop && html.charAt(cursor + 1) == 62) {
                return new OmittedImage(cursor + 1, alt);
            }

            Integer nameStart = cursor;
            while (cursor < stop && isAttributeNameChar(html.charAt(cursor))) {
                cursor++;
            }
            if (nameStart == cursor) {
                return null;
            }
            Boolean isAlt = cursor - nameStart == 3 && 'alt'.equalsIgnoreCase(html.substring(nameStart, cursor));
            cursor = skipSpace(html, cursor, stop);
            if (cursor >= stop || html.charAt(cursor) != 61) {
                continue;
            }
            cursor = skipSpace(html, cursor + 1, stop);
            if (cursor >= stop) {
                return null;
            }
            current = html.charAt(cursor);
            Integer valueStart = cursor;
            Integer valueEnd;
            if (current == 34 || current == 39) {
                valueStart++;
                valueEnd = html.indexOf(current == 34 ? '"' : '\'', valueStart);
                if (valueEnd < 0 || valueEnd >= stop) {
                    return null;
                }
                cursor = valueEnd + 1;
            } else {
                while (cursor < stop && !isSpace(html.charAt(cursor)) && html.charAt(cursor) != 62) {
                    if (html.charAt(cursor) == 60) {
                        return null;
                    }
                    cursor++;
                }
                valueEnd = cursor;
            }
            if (isAlt && alt == null && valueEnd - valueStart <= MAX_SOURCE_CHARS) {
                alt = html.substring(valueStart, valueEnd);
            }
        }
        return null;
    }

    private static Integer skipSpace(String html, Integer cursor, Integer stop) {
        while (cursor < stop && isSpace(html.charAt(cursor))) {
            cursor++;
        }
        return cursor;
    }

    private static Boolean isSpace(Integer value) {
        return value == 32 || (value >= 9 && value <= 13);
    }

    private static Boolean isAttributeNameChar(Integer value) {
        return (value >= 65 &&
            value <= 90) ||
            (value >= 97 &&
            value <= 122) ||
            (value >= 48 &&
            value <= 57) ||
            value == 45 ||
            value == 46 ||
            value == 58 ||
            value == 95;
    }

    private static String safeImage(String raw, Map<String, Set<Id>> aliases) {
        Map<String, String> attributes = new Map<String, String>();
        Boolean duplicateSource = false;
        Matcher attr = ATTRIBUTE.matcher(raw);
        while (attr.find()) {
            String name = attr.group(1).toLowerCase();
            if (attributes.containsKey(name)) {
                duplicateSource = duplicateSource || name == 'src';
                continue;
            }
            attributes.put(name, attr.group(2) ?? attr.group(3) ?? attr.group(4));
        }
        String alt = attributes.get('alt');
        String source = attributes.get('src')?.unescapeHtml4()?.trim();
        if (duplicateSource || String.isBlank(source) || source.length() > MAX_SOURCE_CHARS) {
            return replacementAlt(alt);
        }
        if (source.startsWithIgnoreCase('cid:')) {
            source = resolveCid(source.substring(4), aliases);
        }
        if (DocGenAssetPolicy.assetUrl(source) == null) {
            return replacementAlt(alt);
        }
        String safe = '<img src="' + escapeText(source) + '"';
        if (alt != null) {
            safe += ' alt="' + escapeText(alt.unescapeHtml4()) + '"';
        }
        for (String dimension : new List<String>{ 'width', 'height' }) {
            String value = attributes.get(dimension);
            if (value != null && Pattern.matches('[0-9]{1,4}%?', value.trim())) {
                safe += ' ' + dimension + '="' + value.trim() + '"';
            }
        }
        // Emit only the printable attributes. Responsive sources, event handlers
        // and inline CSS on inbound images are not needed for PDF output.
        return safe + '/>';
    }

    private static String resolveCid(String encoded, Map<String, Set<Id>> aliases) {
        if (aliases == null || String.isBlank(encoded)) {
            return null;
        }
        String cid;
        try {
            cid = EncodingUtil.urlDecode(encoded.replace('+', '%2B'), 'UTF-8');
        } catch (Exception invalid) {
            return null;
        }
        Set<Id> matches = aliases.get(cid);
        if (matches == null) {
            matches = aliases.get('filename:' + cid.toLowerCase());
        }
        if (matches == null || matches.size() != 1 || matches.contains(null)) {
            return null;
        }
        return '/sfc/servlet.shepherd/version/download/' + new List<Id>(matches)[0];
    }

    private static String replacementAlt(String alt) {
        return String.isNotBlank(alt) ? '<span>[Image: ' + escapeText(alt.unescapeHtml4()) + ']</span>' : '';
    }

    private static String escapeText(String value) {
        return value.escapeXml();
    }
}
