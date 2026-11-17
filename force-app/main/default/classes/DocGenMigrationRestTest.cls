@IsTest
private class DocGenMigrationRestTest {
    @IsTest
    static void refusesReadAndWriteWithoutMigrationPermission() {
        Profile profile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String userName =
            'portwood-migration-' +
            EncodingUtil.convertToHex(Crypto.generateAesKey(128)) +
            '@example.test';
        User user = new User(
            Alias = 'pwmig',
            LastName = 'Migration Test',
            ProfileId = profile.Id,
            Email = userName,
            Username = userName,
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles'
        );
        insert user;
        System.runAs(user) {
            RestContext.request = new RestRequest();
            RestContext.request.requestURI = '/services/apexrest/portwood/migration/v1/capabilities';
            RestContext.response = new RestResponse();
            DocGenMigrationRest.readConfiguration();
            System.assertEquals(403, RestContext.response.statusCode);

            RestContext.request.requestURI = '/services/apexrest/portwood/migration/v1/snippet';
            RestContext.request.requestBody = Blob.valueOf('{"name":"Unauthorized snippet"}');
            RestContext.response = new RestResponse();
            DocGenMigrationRest.createConfiguration();
            System.assertEquals(403, RestContext.response.statusCode);
            System.assertEquals(0, [SELECT COUNT() FROM DocGen_Asset__c]);
        }
    }
}
