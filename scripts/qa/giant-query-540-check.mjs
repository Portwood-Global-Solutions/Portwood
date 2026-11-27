// Run against a scratch org with Portwood source deployed and Poppler installed.
// Baseline: node scripts/qa/giant-query-540-check.mjs --org <alias> --legacy --output-dir <directory>
// Candidate: node scripts/qa/giant-query-540-check.mjs --org <alias> --fixture <baseline/fixture.json>
// Add --ui-launch to call the Apex scout and launch methods used by the document runner.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { available, pdfText } from './lib/pdf.mjs';
import { debugMap, runAnonymous, sf } from './lib/sf.mjs';

const { values: options } = parseArgs({
    options: {
        org: { type: 'string' },
        legacy: { type: 'boolean' },
        'ui-launch': { type: 'boolean' },
        fixture: { type: 'string' },
        'verify-job': { type: 'string' },
        'output-dir': { type: 'string' }
    }
});
const { org } = options;
assert(org, 'Provide --org <scratch-org-alias>.');
assert(!options['verify-job'] || options.fixture, 'Provide --fixture with --verify-job.');
const timestamp = Date.now();
const out = resolve(options['output-dir'] ?? `output/giant-query-540-${timestamp}`);
const rowsPerDataset = 2101;
const markers = ['GQ540TITLE', 'GQ540ACTIVES', 'GQ540INACTIVES', 'GQ540OPPS', 'GQ540REPEATED', 'GQ540END'];
const slots = [
    { dataset: 'active', alias: 'ActiveContacts', token: 'GQ540A', field: 'LastName', column: 'FirstName' },
    { dataset: 'inactive', alias: 'InactiveContacts', token: 'GQ540I', field: 'LastName', column: 'FirstName' },
    { dataset: 'opportunities', alias: 'Opportunities', token: 'GQ540O', field: 'Name', column: null },
    { dataset: 'active', alias: 'ActiveContacts', token: 'GQ540R', field: 'LastName', column: 'Department' }
];

function apexString(value) {
    return `'${value.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'`;
}

function id(value) {
    assert.match(value, /^[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?$/);
    return value;
}

function save(name, value) {
    writeFileSync(join(out, name), JSON.stringify(value, null, 2) + '\n');
}

async function sfJson(args) {
    const data = JSON.parse(await sf([...args, '--json']));
    assert.equal(data.status, 0, data.message ?? `sf ${args[0]} ${args[1]} failed.`);
    return data.result;
}

async function query(soql) {
    // One line: on Windows the sf shim runs through cmd.exe, which drops everything after a newline.
    const flat = soql.replace(/\s+/g, ' ').trim();
    return (await sfJson(['data', 'query', '--target-org', org, '--query', flat])).records;
}

async function runApex(source, key) {
    const raw = await runAnonymous(org, source, { retries: 0 });
    const data = debugMap(raw)[key];
    assert(data, `${key} was missing from the anonymous Apex result.\n${raw.slice(-3500)}`);
    return JSON.parse(data);
}

function childNode(object, relationshipName, fields, orderBy, extra = {}) {
    return {
        id: extra.alias ?? relationshipName,
        parentNode: 'n0',
        lookupField: 'AccountId',
        object,
        relationshipName,
        fields,
        orderBy,
        ...extra
    };
}

const config = JSON.stringify({
    v: 3,
    root: 'Account',
    nodes: [
        { id: 'n0', object: 'Account', fields: ['Name'], parentNode: null },
        childNode('Contact', 'Contacts', ['LastName', 'FirstName', 'Department'], 'FirstName ASC, Id ASC', {
            alias: 'ActiveContacts',
            where: "Department = 'Active'"
        }),
        childNode('Contact', 'Contacts', ['LastName', 'FirstName'], 'FirstName ASC, Id ASC', {
            alias: 'InactiveContacts',
            where: "Department = 'Inactive'"
        }),
        childNode('Opportunity', 'Opportunities', ['Name', 'CloseDate'], 'CloseDate ASC, Id ASC')
    ]
});

function htmlTable(slot, i) {
    const header = `<thead><tr><th>${slot.token}HEADER</th><th>#</th>${slot.column ? `<th>${slot.column}</th>` : ''}</tr></thead>`;
    const cells = `<td>${slot.token}X{${slot.field}}</td><td>{RowNumber}</td>${slot.column ? `<td>{${slot.column}}</td>` : ''}`;
    return `<div>${markers[i + 1]}</div><table>${header}<tbody>{#${slot.alias}}<tr>${cells}</tr>{/${slot.alias}}</tbody></table>`;
}

const html =
    '<html><head><style>body{font-size:6pt}table{width:80%;border-collapse:collapse}' +
    'td,th{padding:0;text-align:left}</style></head><body>' +
    `<div>${markers[0]} {Name}</div>${slots.map(htmlTable).join('')}<div>${markers.at(-1)}</div></body></html>`;

async function seed(orgId) {
    const name = `GQ540-${timestamp}`;
    const result = await runApex(
        `
Account a = new Account(Name = ${apexString(name)});
insert a;
String stage = [SELECT MasterLabel FROM OpportunityStage WHERE IsActive = true ORDER BY SortOrder LIMIT 1].MasterLabel;
for (Integer start = 0; start < ${rowsPerDataset}; start += 500) {
    List<Contact> contacts = new List<Contact>();
    List<Opportunity> opportunities = new List<Opportunity>();
    for (Integer i = start; i < Math.min(start + 500, ${rowsPerDataset}); i++) {
        String label = String.valueOf(i + 1).leftPad(4, '0');
        String sortKey = 'Tie' + String.valueOf(Math.mod(i, 13)).leftPad(2, '0');
        contacts.add(new Contact(AccountId = a.Id, LastName = 'A' + label, FirstName = sortKey, Department = 'Active'));
        contacts.add(new Contact(AccountId = a.Id, LastName = 'I' + label, FirstName = sortKey, Department = 'Inactive'));
        opportunities.add(new Opportunity(AccountId = a.Id, Name = 'O' + label, StageName = stage,
            CloseDate = Date.today().addDays(Math.mod(i, 13))));
    }
    insert contacts;
    insert opportunities;
}
DocGen_Template__c template = new DocGen_Template__c(
    Name = ${apexString(name)}, Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = ${apexString(config)},
    Is_Active__c = true, Test_Record_Id__c = a.Id, Document_Title_Format__c = ${apexString(name)}
);
insert template;
ContentVersion body = new ContentVersion(Title = 'docgen_html_body_' + template.Id + '_' + Datetime.now().getTime(),
    PathOnClient = 'giant-query-540.html', VersionData = Blob.valueOf(${apexString(html)}), FirstPublishLocationId = template.Id);
insert body;
insert new DocGen_Template_Version__c(Template__c = template.Id, Content_Version_Id__c = body.Id,
    Type__c = 'HTML', Is_Active__c = true);
System.debug('GQ540_FIXTURE=' + JSON.serialize(new Map<String, Object>{'accountId' => a.Id, 'templateId' => template.Id}));
`,
        'GQ540_FIXTURE'
    );
    return { ...result, orgId, name };
}

async function waitForJob(jobId) {
    const start = Date.now();
    let previousStatus;
    while (Date.now() < start + 15 * 60_000) {
        const [job] = await query(
            `SELECT Id, Status__c, Label__c, Total_Records__c, Success_Count__c, Error_Count__c, Merged_PDF_CV__c
             FROM DocGen_Job__c WHERE Id = '${id(jobId)}'`
        );
        assert(job, `Could not read Giant Query job ${jobId}.`);
        if (job.Status__c !== previousStatus) {
            console.log(`${job.Id} ${job.Status__c} after ${Math.round((Date.now() - start) / 1000)}s`);
            previousStatus = job.Status__c;
        }
        if (['Completed', 'Failed', 'Cancelled'].includes(job.Status__c)) return job;
        await new Promise((ready) => setTimeout(ready, 5000));
    }
    throw new Error(`Giant Query job ${jobId} did not finish during polling.`);
}

function readSlot(text, slot, expectedRows, sectionStart, sectionEnd) {
    const tokens = [...text.matchAll(new RegExp(`\\b${slot.token}X([AIO]\\d{4})\\b`, 'g'))];
    const rendered = tokens.map((match) => {
        const restOfLine = text.slice(match.index + match[0].length).split('\n', 1)[0];
        const [, number, column] = /^\s+(\d+)(?:\s+(\S+))?/.exec(restOfLine) ?? [];
        return { value: match[1], number: Number(number), column };
    });
    const inOrder =
        rendered.length === expectedRows.length &&
        rendered.every((row, i) => row.value === expectedRows[i][slot.field]);
    const unique = new Set(rendered.map((row) => row.value));
    const numbers = rendered.every((row, i) => row.number === i + 1);
    const columns = !slot.column || rendered.every((row, i) => row.column === expectedRows[i]?.[slot.column]);
    return {
        token: slot.token,
        dataset: slot.dataset,
        expected: expectedRows.length,
        actual: rendered.length,
        unique: unique.size,
        allExpectedRowsPresent:
            unique.size === expectedRows.length && expectedRows.every((row) => unique.has(row[slot.field])),
        inOrder,
        inSection: tokens.length > 0 && tokens[0].index > sectionStart && tokens.at(-1).index < sectionEnd,
        rowNumbersCorrect: rendered.length > 0 && numbers,
        columnValuesCorrect: rendered.length > 0 && columns,
        first: rendered[0],
        last: rendered.at(-1)
    };
}

assert(await available(), 'Install Poppler so the check can read the generated PDF.');
const orgs = await sfJson(['org', 'list', '--skip-connection-status']);
const scratch = orgs.scratchOrgs.find((entry) => entry.alias === org || entry.username === org);
assert(scratch?.orgId, `Use an authenticated scratch org. ${org} was not in the Salesforce CLI scratch org list.`);
mkdirSync(out, { recursive: true });
const fixture = options.fixture ? JSON.parse(readFileSync(options.fixture, 'utf8')) : await seed(scratch.orgId);
assert.equal(fixture.orgId, scratch.orgId, 'The saved fixture belongs to another org.');
save('fixture.json', fixture);
console.log(`Fixture ${fixture.accountId} / ${fixture.templateId} in ${out}`);

const parent = `AccountId = '${id(fixture.accountId)}'`;
const [active, inactive, opportunities] = await Promise.all([
    query(
        `SELECT Id, LastName, FirstName, Department FROM Contact WHERE ${parent} AND Department = 'Active' ORDER BY FirstName ASC, Id ASC`
    ),
    query(
        `SELECT Id, LastName, FirstName FROM Contact WHERE ${parent} AND Department = 'Inactive' ORDER BY FirstName ASC, Id ASC`
    ),
    query(`SELECT Id, Name, CloseDate FROM Opportunity WHERE ${parent} ORDER BY CloseDate ASC, Id ASC`)
]);
const datasets = { active, inactive, opportunities };
for (const [dataset, rows] of Object.entries(datasets)) {
    assert.equal(rows.length, rowsPerDataset, `${dataset} fixture size`);
}

const expectedChildCounts = {
    ActiveContacts: rowsPerDataset,
    InactiveContacts: rowsPerDataset,
    Opportunities: rowsPerDataset
};
const accountId = apexString(id(fixture.accountId));
const templateId = apexString(id(fixture.templateId));
let scout;
let launchCall = `DocGenController.generateDocumentGiantQuery(${templateId}, ${accountId})`;
if (options['ui-launch'] && !options['verify-job']) {
    scout = await runApex(
        `System.debug('GQ540_SCOUT=' + JSON.serialize(DocGenController.scoutChildCounts(${accountId}, ${templateId})));`,
        'GQ540_SCOUT'
    );
    assert.deepEqual(scout.counts, expectedChildCounts);
    const relationship = Object.keys(scout.counts).find((name) => scout.useGiantPath[name]);
    assert(relationship, 'The document runner scout must flag a child relationship for Giant Query.');
    assert(scout.childNodes[relationship], `The scout must return the node config for ${relationship}.`);
    const node = apexString(JSON.stringify(scout.childNodes[relationship]));
    launchCall = `DocGenController.launchGiantQueryPdfBatch(${templateId}, ${accountId}, ${apexString(relationship)}, ${node})`;
    save('scout.json', scout);
}

const start = Date.now();
let jobId = options['verify-job'];
let launch;
if (!jobId) {
    launch = await runApex(`System.debug('GQ540_LAUNCH=' + JSON.serialize(${launchCall}));`, 'GQ540_LAUNCH');
    save('launch.json', launch);
    assert.equal(launch.isGiantQuery, true, 'The fixture must take the Giant Query route.');
    if (scout && !options.legacy)
        assert.equal(launch.isMultiTable, true, 'The document runner must enter multi-table mode.');
    if (!scout) assert.deepEqual(launch.childCounts, expectedChildCounts);
    jobId = launch.jobId;
}
const job = await waitForJob(jobId);
const elapsedMs = launch ? Date.now() - start : undefined;
const report = { fixture, scout, launch, job, elapsedMs };
save('result.json', report);
assert.equal(job.Status__c, 'Completed', job.Label__c);

const fragments = await runApex(
    `System.debug('GQ540_FRAGMENTS=' + JSON.serialize(DocGenController.getGiantQueryFragments(${apexString(id(jobId))})));`,
    'GQ540_FRAGMENTS'
);
report.fragments = fragments;
save('result.json', report);
assert.equal(fragments.finalPdfCvId, job.Merged_PDF_CV__c);
assert.deepEqual(fragments.partPdfCvIds, [], 'The completed job must make a single PDF available for download.');

const file = join(out, 'output.pdf');
await sf([
    'api',
    'request',
    'rest',
    `/services/data/v66.0/sobjects/ContentVersion/${id(fragments.finalPdfCvId)}/VersionData`,
    '--target-org',
    org,
    '--stream-to-file',
    file
]);
const pdf = readFileSync(file);
assert.equal(pdf.subarray(0, 5).toString(), '%PDF-');
const { text, pageCount } = await pdfText(pdf);
const markerOrder = markers.map((marker) => text.indexOf(marker));
const chromeOrdered = markerOrder.every((position, i) => position >= 0 && (i === 0 || position > markerOrder[i - 1]));
const slotMetrics = slots.map((slot, i) =>
    readSlot(text, slot, datasets[slot.dataset], markerOrder[i + 1], markerOrder[i + 2])
);
const rootMerged = text.includes(fixture.name);
const missingHeaders = slots
    .filter((slot, i) => {
        const position = text.indexOf(`${slot.token}HEADER`);
        return position <= markerOrder[i + 1] || position >= markerOrder[i + 2];
    })
    .map((slot) => slot.token);
const unresolvedLoop = /\{\/?#?(?:ActiveContacts|InactiveContacts|Opportunities)\}/.test(text);
save('result.json', {
    ...report,
    pdf: { bytes: pdf.length, sha256: createHash('sha256').update(pdf).digest('hex'), pageCount },
    chromeOrdered,
    rootMerged,
    missingHeaders,
    unresolvedLoop,
    slots: slotMetrics
});
console.table(slotMetrics);
const duration = elapsedMs === undefined ? '' : ` in ${Math.round(elapsedMs / 1000)}s`;
console.log(`${pdf.length} bytes over ${pageCount} pages${duration}. Evidence at ${out}`);

if (options.legacy) {
    assert.equal(
        slotMetrics.filter((slot) => slot.allExpectedRowsPresent).length,
        1,
        'Legacy path should render one full slot.'
    );
    assert.equal(slotMetrics.filter((slot) => slot.actual === 0).length, 3, 'Legacy path should drop three slots.');
} else {
    assert.equal(job.Total_Records__c, rowsPerDataset * slots.length);
    assert.equal(job.Success_Count__c, rowsPerDataset * slots.length);
    assert(chromeOrdered, 'The title, four section headings, and closing text must appear in authored order.');
    assert(rootMerged, 'The title must contain the Account name.');
    assert.deepEqual(missingHeaders, [], 'Every table needs its authored column heading.');
    assert(!unresolvedLoop, 'No child loop tags should appear in the PDF.');
    for (const slot of slotMetrics) {
        assert(
            slot.inOrder && slot.inSection && slot.rowNumbersCorrect && slot.columnValuesCorrect,
            `Unexpected rows in ${slot.token}.`
        );
    }
}
