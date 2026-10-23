trigger DocGenPreparedPlacementTrigger on DocGen_Signature_Placement__c(before insert, before update, before delete) {
    List<DocGen_Signature_Placement__c> rows = Trigger.isDelete ? Trigger.old : Trigger.new;
    Set<Id> requestIds = new Set<Id>();
    for (DocGen_Signature_Placement__c row : rows) {
        requestIds.add(row.Signature_Request__c);
        if (Trigger.isUpdate && Trigger.oldMap.get(row.Id).PDF_Page__c != null)
            requestIds.add(Trigger.oldMap.get(row.Id).Signature_Request__c);
    }
    Map<Id, DocGen_Signature_Request__c> requests = new Map<Id, DocGen_Signature_Request__c>(
        [
            SELECT Id, Status__c, Original_Document_CV_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Id IN :requestIds
            WITH SYSTEM_MODE
        ]
    );
    for (DocGen_Signature_Placement__c row : rows) {
        Id requestId = Trigger.isUpdate && Trigger.oldMap.get(row.Id).PDF_Page__c != null
            ? Trigger.oldMap.get(row.Id).Signature_Request__c
            : row.Signature_Request__c;
        DocGen_Signature_Request__c request = requests.get(requestId);
        DocGen_Signature_Request__c destination = requests.get(row.Signature_Request__c);
        if (
            Trigger.isUpdate &&
            row.Signature_Request__c != Trigger.oldMap.get(row.Id).Signature_Request__c &&
            destination != null &&
            destination.Status__c != 'Draft' &&
            String.isNotBlank(destination.Original_Document_CV_Id__c)
        ) {
            row.addError('Fields cannot be moved into a sent PDF request.');
            continue;
        }
        if (request == null || request.Status__c == 'Draft' || String.isBlank(request.Original_Document_CV_Id__c))
            continue;
        if (Trigger.isInsert) {
            row.addError('Sent PDF signing fields cannot be added.');
        } else if (Trigger.isDelete) {
            row.addError('Sent PDF signing fields cannot be deleted.');
        } else {
            DocGen_Signature_Placement__c previous = Trigger.oldMap.get(row.Id);
            if (
                row.PDF_Page__c != previous.PDF_Page__c ||
                row.PDF_X__c != previous.PDF_X__c ||
                row.PDF_Y__c != previous.PDF_Y__c ||
                row.PDF_Width__c != previous.PDF_Width__c ||
                row.PDF_Height__c != previous.PDF_Height__c ||
                row.PDF_Rotation__c != previous.PDF_Rotation__c ||
                row.Signer__c != previous.Signer__c ||
                row.Signature_Request__c != previous.Signature_Request__c ||
                row.Placement_Type__c != previous.Placement_Type__c
            ) {
                row.addError('Sent PDF signing fields cannot be reassigned or repositioned.');
            }
        }
    }
}
