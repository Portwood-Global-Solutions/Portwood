// Run against a scratch org with this branch deployed. Requires the Salesforce CLI and Poppler.
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';
import { available, pdfText } from './lib/pdf.mjs';
import { debugMap, runAnonymous, sf, soql } from './lib/sf.mjs';

const {
    values: { org }
} = parseArgs({ options: { org: { type: 'string' } } });
assert(org, 'Pass --org <scratch-org-alias>.');
assert(await available(), 'Install Poppler to verify the generated PDF.');

const setup = await runAnonymous(
    org,
    `
Account root = new Account(Name='Streamed totals QA');
insert root;
List<Account> groups = new List<Account>();
for(Integer i=0;i<18;i++) {
    groups.add(new Account(Name='Group '+i,ParentId=root.Id));
}
insert groups;
String paid=[SELECT MasterLabel FROM OpportunityStage WHERE IsActive=true AND IsWon=true LIMIT 1].MasterLabel;
String unpaid=[SELECT MasterLabel FROM OpportunityStage WHERE IsActive=true AND IsClosed=false LIMIT 1].MasterLabel;
List<Opportunity> rows=new List<Opportunity>();
List<Decimal> amounts=new List<Decimal>{10,20,null,90,400,600};
List<Integer> owners=new List<Integer>{0,0,0,1,1,2};
for(Integer i=0;i<amounts.size();i++) {
    rows.add(new Opportunity(AccountId=groups[owners[i]].Id,Name='PAY'+i,Amount=amounts[i],
        StageName=i==5?unpaid:paid,CloseDate=Date.newInstance(i==4?2025:2026,1,1)));
}
insert rows;
String groupsKey;
for(Schema.ChildRelationship rel : Account.SObjectType.getDescribe().getChildRelationships()) {
    if(rel.getChildSObject()==Account.SObjectType && rel.getField()==Account.ParentId) {
        groupsKey=rel.getRelationshipName();break;
    }
}
String cfg='Name, (SELECT Name, (SELECT Name,Amount FROM Opportunities WHERE IsWon=true AND CloseDate >= 2026-01-01 AND CloseDate <= 2026-12-31 ORDER BY Name) FROM '+groupsKey+' ORDER BY Name)';
String listKey=groupsKey+'.Opportunities', fieldKey=listKey+'.Amount';
String detail='{#'+groupsKey+'}{#Opportunities}<p>Detail {Name}</p>{/Opportunities}{/'+groupsKey+'}';
String html='<html><body>'+detail+'{#'+groupsKey+'}<p>Group copy {Name}</p>{/'+groupsKey+'}'+
    '<p>Totals {SUM:'+fieldKey+'} / {AVG:'+fieldKey+'} / {MIN:'+fieldKey+'} / {MAX:'+fieldKey+'} / {COUNT:'+listKey+'} / {COUNT:'+fieldKey+'}</p></body></html>';
DocGen_Template__c tpl=new DocGen_Template__c(Name='Streamed totals QA',Base_Object_API__c='Account',Query_Config__c=cfg,
    Type__c='HTML',Output_Format__c='PDF',Giant_Query_Row_Threshold__c=2);
insert tpl;
ContentVersion body=new ContentVersion(Title='Streamed totals QA',PathOnClient='totals.html',VersionData=Blob.valueOf(html));
insert body;
insert new DocGen_Template_Version__c(Template__c=tpl.Id,Content_Version_Id__c=body.Id,Is_Active__c=true);
Map<String,Object> response=DocGenController.generateDocumentGiantQuery(tpl.Id,root.Id);
System.assertEquals(true,response.get('isGiantQuery'));
System.debug('JOB='+response.get('jobId'));
`
);
const jobId = debugMap(setup).JOB;
assert.match(jobId || '', /^[a-zA-Z0-9]{18}$/, setup.slice(-2000));
let job;
const deadline = Date.now() + 10 * 60_000;
do {
    [job] = await soql(org, `SELECT Status__c, Label__c, Merged_PDF_CV__c FROM DocGen_Job__c WHERE Id='${jobId}'`);
    if (['Completed', 'Failed', 'Cancelled'].includes(job?.Status__c)) break;
    await delay(3000);
} while (Date.now() < deadline);
assert.equal(job?.Status__c, 'Completed', job?.Label__c);
assert.match(job.Merged_PDF_CV__c, /^068[a-zA-Z0-9]{15}$/);
const file = join(mkdtempSync(join(tmpdir(), 'portwood-giant-totals-')), 'statement.pdf');
await sf([
    'api',
    'request',
    'rest',
    `/services/data/v66.0/sobjects/ContentVersion/${job.Merged_PDF_CV__c}/VersionData`,
    '--target-org',
    org,
    '--stream-to-file',
    file
]);
const document = await pdfText(readFileSync(file));
assert.deepEqual(
    [...document.text.matchAll(/Detail\s+(PAY\d+)/g)].map((m) => m[1]),
    ['PAY0', 'PAY1', 'PAY2', 'PAY3']
);
assert.equal((document.text.match(/Group copy Group/g) || []).length, 18);
assert.match(document.text.replace(/\s+/g, ' '), /Totals 120 \/ 40 \/ 10 \/ 90 \/ 4 \/ 3\b/);
console.log(`PASS: all five streamed aggregates and both COUNT forms matched the filtered detail. PDF: ${file}`);
