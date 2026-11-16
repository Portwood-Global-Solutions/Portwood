/** Files available to the running user for Giant Query image tags. */
public with sharing class DocGenGiantMedia {
    public static final Integer MAX_WORD_IMAGE_BYTES = 1048576;
    private static final Set<String> IMAGE_EXTENSIONS = new Set<String>{ 'png', 'jpeg', 'jpg', 'gif', 'bmp' };
    private static final Pattern FILE_ID = Pattern.compile('(?:068|069)[a-zA-Z0-9]{12}(?:[a-zA-Z0-9]{3})?');
    private static final Pattern FILE_DOWNLOAD = Pattern.compile(
        '(?i)^/sfc/servlet\\.shepherd/(?:version|document)/download/(068[a-z0-9]{12}(?:[a-z0-9]{3})?|069[a-z0-9]{12}(?:[a-z0-9]{3})?)/?$'
    );

    /** Recognize a File ID or an approved Salesforce File download link. */
    public static Id fileId(Object value) {
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value).trim();
        try {
            if (FILE_ID.matcher(text).matches()) {
                return (Id) text;
            }
            String approved = DocGenAssetPolicy.assetUrl(text);
            if (approved == null) {
                return null;
            }
            Matcher download = FILE_DOWNLOAD.matcher(new Url(approved).getPath());
            return download.matches() ? (Id) download.group(1) : null;
        } catch (Exception invalid) {
            return null;
        }
    }

    /** Resolve explicit versions and latest document versions with sharing and FLS enforced. */
    public static Map<Id, ContentVersion> readableImages(Set<Id> requestedIds, Integer maxBytes) {
        Map<Id, ContentVersion> result = new Map<Id, ContentVersion>();
        Set<Id> versions = new Set<Id>();
        Set<Id> documents = new Set<Id>();
        for (Id file : requestedIds) {
            if (file == null) {
                continue;
            }
            if (file.getSObjectType() == ContentVersion.sObjectType) {
                versions.add(file);
            } else if (file.getSObjectType() == ContentDocument.sObjectType) {
                documents.add(file);
            }
        }
        if (versions.isEmpty() && documents.isEmpty()) {
            return result;
        }
        for (ContentVersion image : [
            SELECT Id, ContentDocumentId, IsLatest, FileExtension
            FROM ContentVersion
            WHERE
                (Id IN :versions
                OR (ContentDocumentId IN :documents
                AND IsLatest = TRUE))
                AND ContentSize <= :maxBytes
                AND ContentLocation = 'S'
                AND FileExtension IN :IMAGE_EXTENSIONS
            WITH USER_MODE
        ]) {
            if (versions.contains(image.Id)) {
                result.put(image.Id, image);
            }
            if (image.IsLatest && documents.contains(image.ContentDocumentId)) {
                result.put(image.ContentDocumentId, image);
            }
        }
        return result;
    }

    public static Map<String, Object> readWordImage(Id fileId) {
        ContentVersion image = readableImages(new Set<Id>{ fileId }, MAX_WORD_IMAGE_BYTES).get(fileId);
        if (image == null) {
            return null;
        }
        List<ContentVersion> rows = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :image.Id AND ContentSize <= :MAX_WORD_IMAGE_BYTES
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty() || rows[0].VersionData == null) {
            return null;
        }
        return new Map<String, Object>{
            'contentVersionId' => image.Id,
            'extension' => image.FileExtension.toLowerCase(),
            'base64' => EncodingUtil.base64Encode(rows[0].VersionData)
        };
    }
}
