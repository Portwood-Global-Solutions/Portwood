/**
 * Admin CRUD for Portwood Brands (#369) — reusable sender identities a
 * Template can point at via Brand__c. Mirrors DocGenSetupController's
 * admin-gate + FLS-guard pattern.
 */
public with sharing class DocGenBrandController {
    public class BrandDto {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String owaId;
        @AuraEnabled
        public String brandColor;
        @AuraEnabled
        public String logoUrl;
        @AuraEnabled
        public String logoAssetKey;
        @AuraEnabled
        public String companyName;
        @AuraEnabled
        public String footerText;
        @AuraEnabled
        public Boolean isActive;
    }

    private static final Set<String> READ_FIELDS = new Set<String>{
        'OWA_Id__c',
        'Brand_Color__c',
        'Logo_Url__c',
        'Logo_Url_Extended__c',
        'Logo_Asset_Key__c',
        'Company_Name__c',
        'Footer_Text__c',
        'Is_Active__c'
    };

    /**
     * Every active AND inactive brand — the admin screen needs both (to show
     * "Active" state and let an admin reactivate one), the template-picker
     * caller filters to active client-side.
     */
    // cacheable=false deliberately — this screen creates/edits brands on the
    // same page, and a cacheable imperative call can return a stale (pre-save)
    // result right after a mutation. Matches DocGenEmailTemplateController.getTemplates'
    // same choice for the same reason.
    @AuraEnabled(cacheable=false)
    public static List<BrandDto> getBrands() {
        DocGenFlsGuard.assertAccessible(DocGen_Brand__c.sObjectType, READ_FIELDS);
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
                Company_Name__c,
                Footer_Text__c,
                Is_Active__c
            FROM DocGen_Brand__c
            WITH SYSTEM_MODE
            ORDER BY Name
        ]; // NOPMD - package-internal object; CRUD via Portwood permission sets
        List<BrandDto> dtos = new List<BrandDto>();
        for (DocGen_Brand__c r : rows) {
            dtos.add(toDto(r));
        }
        return dtos;
    }

    /**
     * Creates (no 'id' key/blank) or updates (id set) one Brand. Admin-gated —
     * a brand's identity (sender address, logo, color) is org-wide-visible
     * material, not something every template editor should be able to change.
     *
     * Takes Map<String, Object>, not the BrandDto class, deliberately — that's
     * the pattern every other save method in this codebase already uses
     * (DocGenEmailTemplateController.saveTemplate, etc.). A custom Apex class
     * as an @AuraEnabled parameter type populated from a plain LWC object did
     * not deserialize correctly in this org (dto.name arrived null despite the
     * client provably sending a real value) — Map<String, Object> is the
     * proven-reliable shape here.
     */
    @AuraEnabled
    public static Id saveBrand(Map<String, Object> dto) {
        if (!FeatureManagement.checkPermission('DocGen_Admin_Access') && !isCurrentUserAdmin()) {
            throw DocGenService.ahe('Insufficient privileges to manage Portwood Brands.');
        }
        String name = dto == null ? null : (String) dto.get('name');
        if (String.isBlank(name)) {
            throw DocGenService.ahe('A brand needs a name.');
        }

        Id existingId = dto.get('id') == null ? null : (Id) String.valueOf(dto.get('id'));
        DocGen_Brand__c b = new DocGen_Brand__c(Id = existingId);
        b.Name = name;
        b.OWA_Id__c = (String) dto.get('owaId');
        b.Brand_Color__c = (String) dto.get('brandColor');
        // Long field wins — Logo_Url__c is a platform Url field capped at 255
        // chars; Logo_Url_Extended__c carries Files delivery URLs and other
        // long links (same split as DocGen_Email_Template__c).
        String logoUrl = (String) dto.get('logoUrl');
        if (String.isNotBlank(logoUrl) && logoUrl.length() > 255) {
            b.Logo_Url_Extended__c = logoUrl;
        } else {
            b.Logo_Url__c = logoUrl;
        }
        b.Logo_Asset_Key__c = (String) dto.get('logoAssetKey');
        b.Company_Name__c = (String) dto.get('companyName');
        b.Footer_Text__c = (String) dto.get('footerText');
        b.Is_Active__c = dto.get('isActive') == null ? true : (Boolean) dto.get('isActive');

        Set<String> writeFields = new Set<String>{
            'Name',
            'OWA_Id__c',
            'Brand_Color__c',
            'Logo_Url__c',
            'Logo_Url_Extended__c',
            'Logo_Asset_Key__c',
            'Company_Name__c',
            'Footer_Text__c',
            'Is_Active__c'
        };
        if (existingId == null) {
            DocGenFlsGuard.assertCreateable(b, writeFields);
        } else {
            DocGenFlsGuard.assertUpdateable(b, writeFields);
        }
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.upsert(b, AccessLevel.SYSTEM_MODE);
        } catch (DmlException e) {
            throw DocGenService.dmlAhe(e, DocGen_Brand__c.sObjectType);
        }
        return b.Id;
    }

    private static BrandDto toDto(DocGen_Brand__c r) {
        BrandDto d = new BrandDto();
        d.id = r.Id;
        d.name = r.Name;
        d.owaId = r.OWA_Id__c;
        d.logoUrl = String.isNotBlank(r.Logo_Url_Extended__c) ? r.Logo_Url_Extended__c.trim() : r.Logo_Url__c;
        d.logoAssetKey = r.Logo_Asset_Key__c;
        d.brandColor = r.Brand_Color__c;
        d.companyName = r.Company_Name__c;
        d.footerText = r.Footer_Text__c;
        d.isActive = r.Is_Active__c;
        return d;
    }

    private static Boolean isCurrentUserAdmin() {
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<User> rows = [
                SELECT Profile.PermissionsModifyAllData
                FROM User
                WHERE Id = :UserInfo.getUserId()
                WITH USER_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - read-only User self-lookup
            return !rows.isEmpty() && rows[0].Profile != null && rows[0].Profile.PermissionsModifyAllData == true;
        } catch (Exception e) {
            return false;
        }
    }
}
