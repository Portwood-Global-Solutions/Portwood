/** Native page-request IP observation, authenticated across stateless VF remoting.
 * The protected setting is internal to the package and is never returned to callers. */
public without sharing class DocGenSignatureIpContext {
    private static final String PREFIX = 'sfip1.';
    private static final String KEY_NAME = 'SignatureIp';
    @TestVisible
    private static final Long LIFETIME_MS = 7200000;

    /** Generic document queries must never bridge access to this package-private key. */
    public static Boolean isPrivateObject(String objectName) {
        return objectName != null && objectName.toLowerCase().endsWith('docgen_security__c');
    }
    public static String publicQuery(String query) {
        if (query != null && query.toLowerCase().contains('docgen_security__c'))
            throw new DocGenException('Package security settings cannot be used as document data.');
        return query;
    }

    /** Called only by installation and existing authorized admin-setup writes. */
    public static void initialize() {
        signingKey(true);
    }

    public static String issue(String token, String ip) {
        if (!validIp(ip) || !validToken(token))
            return '';
        Blob key = signingKey(false);
        if (key == null)
            return '';
        Long nowMs = Datetime.now().getTime();
        String payload = EncodingUtil.base64Encode(
            Blob.valueOf(
                JSON.serialize(
                    new Map<String, Object>{
                        'token' => tokenDigest(token),
                        'ip' => ip,
                        'issued' => String.valueOf(nowMs),
                        'expires' => String.valueOf(nowMs + LIFETIME_MS)
                    }
                )
            )
        );
        return PREFIX +
            payload +
            '.' +
            EncodingUtil.base64Encode(Crypto.generateMac('HmacSHA256', Blob.valueOf(payload), key));
    }

    public static Boolean isContext(String value) {
        return value != null && value.startsWith(PREFIX);
    }

    public static String verify(String token, String context) {
        if (!validToken(token) || !isContext(context) || context.length() > 1500)
            return null;
        try {
            List<String> parts = context.substring(PREFIX.length()).split('\\.');
            if (parts.size() != 2)
                return null;
            Blob key = signingKey(false);
            if (
                key == null ||
                !Crypto.verifyHMac('HmacSHA256', Blob.valueOf(parts[0]), key, EncodingUtil.base64Decode(parts[1]))
            )
                return null;
            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
                EncodingUtil.base64Decode(parts[0]).toString()
            );
            Long issued = Long.valueOf((String) data.get('issued'));
            Long expires = Long.valueOf((String) data.get('expires'));
            Long nowMs = Datetime.now().getTime();
            String ip = (String) data.get('ip');
            return data.get('token') == tokenDigest(token) &&
                validIp(ip) &&
                issued <= nowMs &&
                expires > nowMs &&
                expires - issued == LIFETIME_MS
                ? ip
                : null;
        } catch (Exception ignored) {
            return null;
        }
    }

    private static Boolean validToken(String token) {
        return token != null && Pattern.matches('[a-fA-F0-9]{64}', token);
    }
    public static Boolean validIp(String ip) {
        return String.isNotBlank(ip) && ip.length() <= 45 && Pattern.matches('[0-9a-fA-F:.]+', ip);
    }
    private static String tokenDigest(String token) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(token.toLowerCase())));
    }
    private static Blob signingKey(Boolean createIfMissing) {
        // Protected custom setting: no guest CRUD, field permission or public API.
        List<DocGen_Security__c> rows = [
            SELECT Key__c
            FROM DocGen_Security__c
            WHERE Name = :KEY_NAME
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (rows.isEmpty() && createIfMissing) {
            DocGen_Security__c row = new DocGen_Security__c(
                Name = KEY_NAME,
                Key__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256))
            );
            Database.SaveResult saved = Database.insert(row, false, AccessLevel.SYSTEM_MODE);
            if (saved.isSuccess())
                return EncodingUtil.convertFromHex(row.Key__c);
            // Another first page load may have initialized the key concurrently.
            rows = [SELECT Key__c FROM DocGen_Security__c WHERE Name = :KEY_NAME WITH SYSTEM_MODE LIMIT 1];
            if (rows.isEmpty())
                throw new DocGenException('Unable to prepare the secure signing context. Reload this page.');
        }
        return rows.isEmpty() ? null : EncodingUtil.convertFromHex(rows[0].Key__c);
    }
}
