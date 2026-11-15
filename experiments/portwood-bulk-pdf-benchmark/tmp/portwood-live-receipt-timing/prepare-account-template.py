from pathlib import Path
import base64
import json
import sys

root = Path(__file__).resolve().parents[2]
fixture = root / 'scripts/bench/portwood-account-contribution-statement.html'
output = Path(sys.argv[1])
encoded = base64.b64encode(fixture.read_bytes()).decode('ascii')
config = json.dumps({'v': 3, 'nodes': [
    {'id': 'accounts', 'object': 'Account', 'parentNode': None,
     'fields': ['Name', 'AccountNumber', 'BillingStreet', 'BillingCity', 'BillingState', 'BillingPostalCode']},
    {'id': 'gifts', 'object': 'Opportunity', 'parentNode': 'accounts', 'lookupField': 'AccountId',
     'relationshipName': 'Opportunities', 'fields': ['Name', 'Description', 'CloseDate', 'Amount'], 'orderBy': 'Name ASC'},
    {'id': 'allocations', 'object': 'OpportunityLineItem', 'parentNode': 'gifts', 'lookupField': 'OpportunityId',
     'relationshipName': 'OpportunityLineItems', 'fields': ['Quantity', 'UnitPrice', 'TotalPrice'],
     'parentFields': ['Product2.Name'], 'orderBy': 'SortOrder ASC, Id ASC'},
]}, separators=(',', ':'))
common = f"""portwoodglobal__Type__c = 'HTML',
    portwoodglobal__Output_Format__c = 'PDF',
    portwoodglobal__Base_Object_API__c = 'Account',
    portwoodglobal__Query_Config__c = '{config}',
    portwoodglobal__Document_Title_Format__c = 'Annual Contribution Statement - {{AccountNumber}}',
    portwoodglobal__Description__c = 'Synthetic year-end statements with contribution detail and fund allocations',
    portwoodglobal__Page_Size__c = 'Letter',
    portwoodglobal__Page_Orientation__c = 'Portrait',
    portwoodglobal__Is_Active__c = true"""
output.write_text(f"""Blob html = EncodingUtil.base64Decode('{encoded}');
portwoodglobal__DocGen_Template__c template = new portwoodglobal__DocGen_Template__c(
    Name = 'PW Bench - Cedar Waters Account Contribution Statement',
    {common}
);
insert template;
ContentVersion body = new ContentVersion(
    Title = 'docgen_html_body_' + template.Id + '_' + Datetime.now().getTime(),
    PathOnClient = 'statement.html',
    VersionData = html,
    FirstPublishLocationId = template.Id
);
insert body;
insert new portwoodglobal__DocGen_Template_Version__c(
    portwoodglobal__Template__c = template.Id,
    portwoodglobal__Content_Version_Id__c = String.valueOf(body.Id),
    {common}
);
System.debug(LoggingLevel.ERROR, 'PW_ACCOUNT_TEMPLATE=' + template.Id);
""")
