#!/usr/bin/env node
// Creates examples in a disposable subscriber org; never deploys package source.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const org = process.argv[2];
if (!org) throw new Error('Usage: node scripts/knowledgebase/seed-templates.mjs <scratch-org-alias>');
const sf = (args) =>
    JSON.parse(
        execFileSync('sf', args.concat('--json'), { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] })
    );
const info = sf(['org', 'display', '--target-org', org]).result;
if (!info.instanceUrl?.includes('.scratch.')) throw new Error('Example seeding is restricted to a scratch org.');
const q = (str) =>
    "'" + str.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\r', '').replaceAll('\n', '\\n') + "'";
const examples = [
    {
        name: 'Account Brief',
        api: 'KB_Account_Brief',
        object: 'Account',
        file: 'account-brief.html',
        query: {
            v: 3,
            root: 'Account',
            nodes: [
                {
                    id: 'n0',
                    object: 'Account',
                    fields: ['Name', 'Industry', 'Phone', 'BillingCity', 'BillingState', 'AnnualRevenue'],
                    parentFields: [],
                    parentNode: null,
                    lookupField: null,
                    relationshipName: null
                },
                {
                    id: 'n1',
                    object: 'Contact',
                    fields: ['FirstName', 'LastName', 'Email', 'Title'],
                    parentFields: [],
                    parentNode: 'n0',
                    lookupField: 'AccountId',
                    relationshipName: 'Contacts',
                    orderBy: 'LastName ASC'
                },
                {
                    id: 'n2',
                    object: 'Opportunity',
                    fields: ['Name', 'StageName', 'Amount'],
                    parentFields: [],
                    parentNode: 'n0',
                    lookupField: 'AccountId',
                    relationshipName: 'Opportunities',
                    orderBy: 'Name ASC'
                }
            ]
        }
    },
    {
        name: 'Opportunity Summary',
        api: 'KB_Opportunity_Summary',
        object: 'Opportunity',
        file: 'opportunity-summary.html',
        query: 'Name, Account.Name, Amount, StageName, CloseDate, IsWon'
    },
    {
        name: 'Signing Practice',
        api: 'KB_Signing_Practice',
        object: 'Account',
        file: 'signing-practice.html',
        query: 'Name'
    }
];
const lines = [
    "Id sampleAccount = [SELECT Id FROM Account WHERE Name = 'Northstar Bikes' LIMIT 1].Id;",
    "Id sampleOpportunity = [SELECT Id FROM Opportunity WHERE Name = 'Northstar - Spring Service' LIMIT 1].Id;"
];
for (const e of examples) {
    const html = fs.readFileSync(path.join(root, 'docs/knowledgebase/examples', e.file), 'utf8');
    const query = typeof e.query === 'string' ? e.query : JSON.stringify(e.query);
    lines.push(`{
        List<portwoodglobal__DocGen_Template__c> existing = [SELECT Id FROM portwoodglobal__DocGen_Template__c WHERE portwoodglobal__API_Name__c = ${q(e.api)} LIMIT 1];
        if (existing.isEmpty()) {
            ContentVersion body = new ContentVersion(Title=${q(e.name + ' body')}, PathOnClient=${q(e.file)}, VersionData=EncodingUtil.base64Decode(${q(Buffer.from(html).toString('base64'))}));
            insert body;
            portwoodglobal__DocGen_Template__c template = new portwoodglobal__DocGen_Template__c(Name=${q(e.name)}, portwoodglobal__API_Name__c=${q(e.api)}, portwoodglobal__Type__c='HTML', portwoodglobal__Output_Format__c='PDF', portwoodglobal__Base_Object_API__c=${q(e.object)}, portwoodglobal__Query_Config__c=${q(query)}, portwoodglobal__Is_Active__c=true, portwoodglobal__Category__c='Knowledgebase examples', portwoodglobal__Test_Record_Id__c=${e.object === 'Account' ? 'sampleAccount' : 'sampleOpportunity'});
            insert template;
            insert new portwoodglobal__DocGen_Template_Version__c(portwoodglobal__Template__c=template.Id,portwoodglobal__Is_Active__c=true,portwoodglobal__Content_Version_Id__c=body.Id);
        }
    }`);
}
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'portwood-kb-'));
try {
    const file = path.join(temp, 'seed.apex');
    fs.writeFileSync(file, lines.join('\n'));
    const result = sf(['apex', 'run', '--target-org', org, '--file', file]);
    if (!result.result?.success)
        throw new Error(result.result?.exceptionMessage || result.result?.compileProblem || 'Example seeding failed.');
    console.log('Three knowledgebase example templates are ready. No emails were sent.');
} finally {
    fs.rmSync(temp, { recursive: true });
}
