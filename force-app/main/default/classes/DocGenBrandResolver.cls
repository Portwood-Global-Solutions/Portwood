/**
 * Resolves the Portwood Brand (#369) a signature email should use — the sender
 * identity a Template optionally points at via DocGen_Template__c.Brand__c.
 * Per-transaction cached so a bulk send issues at most one query per distinct
 * request and one per distinct brand, regardless of recipient count.
 */
// "without sharing" + guest FLS-guard variants are load-bearing for the same
// reason DocGenSignatureEmailService and DocGenSignatureController are: the
// completion/PIN/all-signed sends can finish inside the GUEST signer's own
// transaction, where the guest has no sharing on DocGen_Signature_Request__c or
// DocGen_Brand__c — a "with sharing" SYSTEM_MODE query would return no rows and
// brand resolution would silently fall back to the org default.
public without sharing class DocGenBrandResolver {
    private static Map<Id, Id> requestBrandCache = new Map<Id, Id>();
    private static Map<Id, DocGen_Brand__c> brandCache = new Map<Id, DocGen_Brand__c>();

    /**
     * The Brand Id the given signature request's template points at, or null
     * when the request has no template or the template has no Brand. Does NOT
     * check Is_Active__c — getBrand() below is where "active" is enforced, so a
     * brand deactivated after being assigned still resolves here but getBrand()
     * returns null for it, falling through to the org default exactly the same
     * way as if no brand had ever been assigned.
     */
    public static Id resolveBrandForRequest(Id requestId) {
        if (requestId == null) {
            return null;
        }
        if (requestBrandCache.containsKey(requestId)) {
            return requestBrandCache.get(requestId);
        }

        DocGenFlsGuard.guestAssertAccessible(DocGen_Signature_Request__c.sObjectType, new Set<String>{ 'Template__c' });
        DocGenFlsGuard.guestAssertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Brand__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signature_Request__c> reqs = [
            SELECT Template__c, Template__r.Brand__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        Id brandId = (!reqs.isEmpty() && reqs[0].Template__c != null) ? reqs[0].Template__r.Brand__c : null;
        requestBrandCache.put(requestId, brandId);
        return brandId;
    }

    /**
     * The Brand row for a Brand Id, or null when brandId is null, the record no
     * longer exists, or Is_Active__c is false — the single place "is this brand
     * usable right now" is decided.
     */
    public static DocGen_Brand__c getBrand(Id brandId) {
        if (brandId == null) {
            return null;
        }
        if (brandCache.containsKey(brandId)) {
            return brandCache.get(brandId);
        }

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Brand__c.sObjectType,
            new Set<String>{
                'OWA_Id__c',
                'Brand_Color__c',
                'Logo_Url__c',
                'Logo_Url_Extended__c',
                'Logo_Asset_Key__c',
                'Logo_Height__c',
                'Company_Name__c',
                'Footer_Text__c',
                'Is_Active__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Brand__c> rows = [
            SELECT
                Id,
                Name,
                OWA_Id__c,
                Brand_Color__c,
                Logo_Url__c,
                Logo_Url_Extended__c,
                Logo_Asset_Key__c,
                Logo_Height__c,
                Company_Name__c,
                Footer_Text__c,
                Is_Active__c
            FROM DocGen_Brand__c
            WHERE Id = :brandId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        DocGen_Brand__c brand = rows.isEmpty() ? null : rows[0];
        brandCache.put(brandId, brand);
        return brand;
    }

    @TestVisible
    private static void clearCache() {
        requestBrandCache = new Map<Id, Id>();
        brandCache = new Map<Id, DocGen_Brand__c>();
    }
}
