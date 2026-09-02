/**
 * Optional-dependency shim for the `ContentDistribution` SObject — the object
 * behind Setup → "Content Deliveries and Public Links".
 *
 * Security-hardened orgs disable that org preference, which removes
 * `ContentDistribution` as a *compilable* Apex type. Any class that names the
 * type statically (`List<ContentDistribution>`, `new ContentDistribution()`,
 * `[SELECT ... FROM ContentDistribution]`, `ContentDistribution.sObjectType`)
 * then fails to compile, which aborts package install/upgrade and takes down
 * every downstream Flow action ("No Apex action available for 'Apex method'").
 * See issue #384.
 *
 * Every reference to the type is therefore routed through this class as a
 * *dynamic* reference (`Schema.getGlobalDescribe()` + `Database.query` +
 * `SObject.newSObject()`), so Portwood compiles and runs whether the feature is
 * on or off. When it is off, `isAvailable()` returns false and callers fall
 * back to relative `/sfc/servlet.shepherd/version/download/<cvId>` URLs (or, for
 * the email-logo path that genuinely needs an anonymously-fetchable URL, a clear
 * "enable Content Deliveries" message).
 */
public with sharing class DocGenContentDelivery {
    /** Fixed select list for every distribution read here — a static string so
     *  Code Analyzer sees no injection surface. */
    private static final String SELECT_FIELDS =
        'Id, ContentVersionId, DistributionPublicUrl, ContentDownloadUrl, PreferencesExpires, ExpiryDate';

    /** Test / e2e hook: force the feature on (`true`) or off (`false`) regardless
     *  of the org preference. Null = describe the real org. Package-internal
     *  (`public`, so anonymous-Apex e2e scripts can flip it too — not `global`,
     *  so it is invisible to subscribers). */
    public static Boolean availabilityOverride;

    private static Boolean cachedAvailable;

    /** True when `ContentDistribution` exists in this org (the org preference is
     *  on). False means every method below is a safe no-op. */
    public static Boolean isAvailable() {
        if (availabilityOverride != null) {
            return availabilityOverride;
        }
        if (cachedAvailable == null) {
            cachedAvailable = Schema.getGlobalDescribe().get('ContentDistribution') != null;
        }
        return cachedAvailable;
    }

    /** The dynamic SObjectType, for `DocGenFlsGuard` calls. Null when unavailable. */
    public static Schema.SObjectType sObjectType() {
        return isAvailable() ? Schema.getGlobalDescribe().get('ContentDistribution') : null;
    }

    /** An unsaved `ContentDistribution` with the given fields set, or null when
     *  the feature is unavailable. */
    public static SObject newDistribution(Map<String, Object> fields) {
        Schema.SObjectType t = sObjectType();
        if (t == null) {
            return null;
        }
        SObject dist = t.newSObject();
        if (fields != null) {
            for (String f : fields.keySet()) {
                dist.put(f, fields.get(f));
            }
        }
        return dist;
    }

    /** Existing distribution for a ContentVersion, or null. SYSTEM_MODE — callers
     *  gate access with `DocGenFlsGuard` first. */
    public static SObject findByContentVersion(Id contentVersionId) {
        if (!isAvailable() || contentVersionId == null) {
            return null;
        }
        /* code-analyzer-suppress ApexSOQLInjection, ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<SObject> rows = Database.query(
            'SELECT ' + SELECT_FIELDS + ' FROM ContentDistribution WHERE ContentVersionId = :contentVersionId LIMIT 1',
            AccessLevel.SYSTEM_MODE
        );
        return rows.isEmpty() ? null : rows[0];
    }

    /** Existing distributions for a set of ContentVersions, keyed by
     *  ContentVersionId (first row wins). Empty map when unavailable. */
    public static Map<Id, SObject> findByContentVersions(Set<Id> contentVersionIds) {
        Map<Id, SObject> byCv = new Map<Id, SObject>();
        if (!isAvailable() || contentVersionIds == null || contentVersionIds.isEmpty()) {
            return byCv;
        }
        /* code-analyzer-suppress ApexSOQLInjection, ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<SObject> rows = Database.query(
            'SELECT ' + SELECT_FIELDS + ' FROM ContentDistribution WHERE ContentVersionId IN :contentVersionIds',
            AccessLevel.SYSTEM_MODE
        );
        for (SObject row : rows) {
            Id cvId = (Id) row.get('ContentVersionId');
            if (!byCv.containsKey(cvId)) {
                byCv.put(cvId, row);
            }
        }
        return byCv;
    }

    /** Re-reads a just-inserted distribution for its server-generated URLs. */
    public static SObject reload(Id distributionId) {
        if (!isAvailable() || distributionId == null) {
            return null;
        }
        /* code-analyzer-suppress ApexSOQLInjection, ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<SObject> rows = Database.query(
            'SELECT ' + SELECT_FIELDS + ' FROM ContentDistribution WHERE Id = :distributionId LIMIT 1',
            AccessLevel.SYSTEM_MODE
        );
        return rows.isEmpty() ? null : rows[0];
    }
}
