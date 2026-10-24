/** Subscriber-side example. Deploy to your org after installing Portwood. */
global with sharing class KBAccountProvider implements portwoodglobal.DocGenDataProvider {
    global Map<String, Object> getData(Id recordId) {
        Account account = [
            SELECT Name, Industry, Phone
            FROM Account
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
        List<Object> contacts = new List<Object>();
        for (Contact contact : [
            SELECT Name, Email, Title
            FROM Contact
            WHERE AccountId = :recordId
            WITH USER_MODE
            ORDER BY Name
            LIMIT 100
        ]) {
            contacts.add(
                new Map<String, Object>{ 'Name' => contact.Name, 'Email' => contact.Email, 'Title' => contact.Title }
            );
        }
        return new Map<String, Object>{
            'Name' => account.Name,
            'Industry' => account.Industry,
            'Phone' => account.Phone,
            'ContactCount' => contacts.size(),
            'Contacts' => new Map<String, Object>{ 'records' => contacts }
        };
    }
    global List<String> getFieldNames() {
        return new List<String>{
            'Name',
            'Industry',
            'Phone',
            'ContactCount',
            'Contacts.Name',
            'Contacts.Email',
            'Contacts.Title'
        };
    }
}
