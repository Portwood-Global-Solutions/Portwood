/** Lightweight capability probe shared by Portwood authoring panels. */
public with sharing class DocGenGettingStartedController {
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getReadiness() {
        return new Map<String, Object>{
            'canCreateAssets' => DocGen_Asset__c.sObjectType.getDescribe().isCreateable(),
            'canEditAssets' => DocGen_Asset__c.sObjectType.getDescribe().isUpdateable(),
            'canDeleteAssets' => DocGen_Asset__c.sObjectType.getDescribe().isDeletable()
        };
    }
}
