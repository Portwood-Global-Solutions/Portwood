// Run against a Portwood source-deployed scratch org with Poppler installed.
// The synthetic Account must have 50,000 Scale A and 50,000 Scale B Contacts.
// Each group uses labels A000001–A050000 or B000001–B050000 and FirstName Tie00–Tie12.
// node scripts/qa/giant-query-540-scale.mjs --org <org> --account <id> --rows 10000 --rows 25000
// Omit --rows for the full 10k/25k/50k/100k matrix. --placements repeats one shared query up to 200k printed rows.
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
        account: { type: 'string' },
        rows: { type: 'string', multiple: true },
        placements: { type: 'string' },
        shape: { type: 'string', default: 'compact' },
        'output-dir': { type: 'string' },
        'wait-seconds': { type: 'string', default: '1200' }
    }
});
const { org, shape } = options;
assert(org, 'Provide --org <scratch-org-alias>.');
assert(options.account, 'Provide --account <synthetic Account ID>.');
assert(['compact', 'rich'].includes(shape), '--shape must be compact or rich.');
const accountId = id(options.account);
const placements = options.placements ? integer(options.placements, 2, 16) : null;
const maxPrintedRows = placements ? Math.min(200000, placements * 50000) : 100000;
const matrix = (options.rows ?? ['10000', '25000', '50000', '100000']).map((rows) =>
    integer(rows, 4002, maxPrintedRows)
);
const waitMs = integer(options['wait-seconds'], 10, 3600) * 1000;
const stamp = Date.now();
const outputDir = resolve(options['output-dir'] ?? `output/giant-query-540-scale-${stamp}`);
const orderBy = 'LastName ASC, Id ASC';

function id(value) {
    assert.match(value, /^[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?$/);
    return value;
}

function integer(value, min, max) {
    const number = Number(value);
    assert(
        Number.isInteger(number) && number >= min && number <= max,
        `Expected an integer from ${min} to ${max}, got ${value}.`
    );
    return number;
}

function apexString(value) {
    return `'${value.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'`;
}

function save(file, value) {
    writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
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

async function apex(source) {
    const raw = await runAnonymous(org, source, { retries: 0 });
    const result = debugMap(raw).SCALE540;
    assert(result, `Missing Apex scale result.\n${raw.slice(-2500)}`);
    return JSON.parse(result);
}

function dataset(group, rows) {
    const end = `${group}${String(rows).padStart(6, '0')}`;
    const alias = `Scale${group}`;
    return {
        group,
        rows,
        node: {
            id: alias,
            alias,
            object: 'Contact',
            relationshipName: 'Contacts',
            parentNode: 'n0',
            lookupField: 'AccountId',
            fields: ['LastName', 'FirstName'],
            where: `Department = 'Scale ${group}' AND LastName >= '${group}000001' AND LastName <= '${end}'`,
            orderBy
        }
    };
}

function plan(printedRows) {
    if (placements) {
        assert.equal(printedRows % placements, 0, 'Printed rows must divide evenly among repeated placements.');
        const datasets = [dataset('A', integer(printedRows / placements, 2001, 50000))];
        return { datasets, slots: Array(placements).fill(datasets[0]) };
    }
    const first = Math.floor(printedRows / 2);
    const datasets = [dataset('A', first), dataset('B', printedRows - first)];
    return { datasets, slots: datasets };
}

function templateBody(slots) {
    const tables = slots.map(({ node }, index) => {
        const token = `S540${String(index + 1).padStart(2, '0')}`;
        const content = `<td>${token}X{LastName}</td><td>{RowNumber}</td><td>{FirstName}</td>`;
        const richContent =
            `<td><strong style="color:#174870;">${token}X{LastName}</strong></td>` +
            '<td style="text-align:right;">{RowNumber}</td><td>{FirstName} ' +
            '<span style="color:#424242; font-style:italic;">Synthetic approval and processing note for historical archive review. ' +
            'Includes a second sentence for denser output and page layout.</span></td>';
        const row =
            shape === 'compact'
                ? `<tr>${content}</tr>`
                : `<tr style="border-bottom:1px solid #ccc;">${richContent}</tr>`;
        return (
            `<div>${token}SECTION</div><table><thead><tr><th>${token}HEADER</th><th>#</th><th>First Name</th></tr></thead>` +
            `<tbody>{#${node.alias}}${row}{/${node.alias}}</tbody></table>`
        );
    });
    return (
        '<html><head><style>body{font-size:6pt}table{width:80%;border-collapse:collapse}' +
        'td,th{padding:0;text-align:left}</style></head><body>' +
        `<div>GQ540SCALETITLE {Name}</div>${tables.join('')}<div>GQ540SCALEEND</div></body></html>`
    );
}

async function createTemplate(name, config, html) {
    return apex(`
DocGen_Template__c template = new DocGen_Template__c(
    Name = ${apexString(name)}, Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = ${apexString(JSON.stringify(config))},
    Is_Active__c = true, Test_Record_Id__c = '${accountId}', Document_Title_Format__c = ${apexString(name)}
);
insert template;
ContentVersion body = new ContentVersion(Title = 'docgen_html_body_' + template.Id + '_' + Datetime.now().getTime(),
    PathOnClient = 'giant-query-540-scale.html', VersionData = Blob.valueOf(${apexString(html)}), FirstPublishLocationId = template.Id);
insert body;
insert new DocGen_Template_Version__c(Template__c = template.Id, Content_Version_Id__c = body.Id,
    Type__c = 'HTML', Is_Active__c = true);
System.debug('SCALE540=' + JSON.serialize(template.Id));
`);
}

async function waitForJob(jobId, requestedRows, report, receipt) {
    const started = Date.now();
    let previous;
    while (Date.now() - started < waitMs) {
        const [job] = await query(`SELECT Id, CreatedDate, LastModifiedDate, Status__c, Label__c, Total_Records__c,
            Success_Count__c, Error_Count__c, Merged_PDF_CV__c FROM DocGen_Job__c WHERE Id = '${id(jobId)}'`);
        assert(job, `Giant Query job ${jobId} cannot be read.`);
        const progress = `${job.Status__c} ${job.Success_Count__c ?? 0}/${requestedRows}`;
        if (progress !== previous) {
            console.log(`${requestedRows} ${job.Id} ${progress} after ${Math.round((Date.now() - started) / 1000)}s`);
            report.progress.push({
                status: job.Status__c,
                rendered: job.Success_Count__c ?? 0,
                elapsedMs: Date.now() - started
            });
            previous = progress;
        }
        report.job = job;
        report.stage = job.Success_Count__c === requestedRows ? 'assemble' : 'harvest';
        if (
            !report.staged &&
            (job.Status__c === 'Failed' || (job.Status__c === 'Harvesting' && report.stage === 'assemble'))
        ) {
            const prefix = `docgen_giant_${jobId}_slot_%`;
            const [storage] = await query(
                `SELECT COUNT(Id) fragments, SUM(ContentSize) bytes FROM ContentVersion WHERE Title LIKE '${prefix}' AND IsLatest = true`
            );
            if (storage?.fragments > 0) {
                report.staged = { fragments: storage.fragments, bytes: storage.bytes };
            }
        }
        save(receipt, report);
        if (['Completed', 'Failed', 'Cancelled'].includes(job.Status__c)) return job;
        await new Promise((ready) => setTimeout(ready, 5000));
    }
    throw new Error(`Timed out while waiting for an active job. Check ${jobId} before starting another matrix.`);
}

async function checkPdf(file, benchmark, report) {
    const pdf = readFileSync(file);
    assert.equal(pdf.subarray(0, 5).toString(), '%PDF-');
    const { text, pageCount } = await pdfText(pdf);
    report.pdf = { bytes: pdf.length, pageCount, sha256: createHash('sha256').update(pdf).digest('hex') };
    assert(
        text.includes('GQ540SCALETITLE') && text.includes('GQ540SCALEEND'),
        'The PDF needs both document boundaries.'
    );
    const tableMetrics = benchmark.slots.map(({ group, node, rows }, index) => {
        const token = `S540${String(index + 1).padStart(2, '0')}`;
        const nextToken =
            benchmark.slots.length === index + 1 ? 'GQ540SCALEEND' : `S540${String(index + 2).padStart(2, '0')}SECTION`;
        const start = text.indexOf(`${token}SECTION`);
        const end = text.indexOf(nextToken);
        const header = text.indexOf(`${token}HEADER`);
        const body = text.slice(header, end);
        // Wrapped rich cells can start on a line above the ID and row number.
        const matches = [...body.matchAll(new RegExp(`\\b${token}X([AB]\\d{6})[ \\t]*(\\d+)`, 'g'))];
        const values = [...body.matchAll(/\bTie(?:0\d|1[0-2])\b/g)];
        const totalMarkers = (text.match(new RegExp(`${token}X[AB]\\d{6}`, 'g')) ?? []).length;
        const perfect =
            start >= 0 &&
            header > start &&
            end > header &&
            matches.length === rows &&
            totalMarkers === rows &&
            values.length === rows &&
            matches.every(
                (match, i) =>
                    match[1] === `${group}${String(i + 1).padStart(6, '0')}` &&
                    Number(match[2]) === i + 1 &&
                    values[i][0] === `Tie${String(i % 13).padStart(2, '0')}`
            );
        return { token, alias: node.alias, expected: rows, actual: matches.length, exactOrderAndValues: perfect };
    });
    report.tables = tableMetrics;
    assert(
        tableMetrics.every((table) => table.exactOrderAndValues),
        'PDF rows, values, or authored table placement differed from the fixture.'
    );
}

async function runCase(printedRows, source) {
    const benchmark = plan(printedRows);
    const directory = join(outputDir, String(printedRows));
    mkdirSync(directory, { recursive: true });
    const receipt = join(directory, 'result.json');
    const start = Date.now();
    const report = {
        org,
        accountId,
        shape,
        source,
        printedRows,
        placements: benchmark.slots.length,
        distinctRows: benchmark.datasets.reduce((total, { rows }) => total + rows, 0),
        stage: 'template',
        progress: []
    };
    try {
        const config = {
            v: 3,
            root: 'Account',
            nodes: [
                { id: 'n0', object: 'Account', fields: ['Name'], parentNode: null },
                ...benchmark.datasets.map(({ node }) => node)
            ]
        };
        report.templateId = id(
            await createTemplate(`GQ540S-${shape}-${printedRows}-${stamp}`, config, templateBody(benchmark.slots))
        );
        report.stage = 'scout';
        report.scout = await apex(
            `System.debug('SCALE540=' + JSON.serialize(DocGenController.scoutChildCounts('${accountId}', '${report.templateId}')));`
        );
        assert.deepEqual(
            report.scout.counts,
            Object.fromEntries(benchmark.datasets.map(({ rows, node }) => [node.alias, rows]))
        );
        const alias = Object.keys(report.scout.counts).find((name) => report.scout.useGiantPath[name]);
        assert(alias && report.scout.childNodes[alias], 'Runner scout did not select the Giant Query route.');
        report.stage = 'launch';
        const node = apexString(JSON.stringify(report.scout.childNodes[alias]));
        const launchedAt = Date.now();
        report.launch = await apex(
            `System.debug('SCALE540=' + JSON.serialize(DocGenController.launchGiantQueryPdfBatch('${report.templateId}', '${accountId}', '${alias}', ${node})));`
        );
        const launchElapsedMs = Date.now() - launchedAt;
        assert(report.launch.isGiantQuery && report.launch.isMultiTable, 'Expected multi-table Giant Query.');
        const job = await waitForJob(report.launch.jobId, printedRows, report, receipt);
        report.generation = {
            launchElapsedMs,
            observedElapsedMs: Date.now() - launchedAt,
            serverElapsedMs: Date.parse(job.LastModifiedDate) - Date.parse(job.CreatedDate)
        };
        assert.equal(job.Status__c, 'Completed', job.Label__c);
        assert.equal(job.Total_Records__c, printedRows);
        assert.equal(job.Success_Count__c, printedRows);
        report.stage = 'publish';
        const publicationStartedAt = Date.now();
        report.files = await apex(
            `System.debug('SCALE540=' + JSON.serialize(DocGenController.getGiantQueryFragments('${id(job.Id)}')));`
        );
        assert.deepEqual(report.files.partPdfCvIds, [], 'The job split the output into browser-merge parts.');
        assert.equal(report.files.finalPdfCvId, job.Merged_PDF_CV__c);
        const file = join(directory, 'output.pdf');
        await sf([
            'api',
            'request',
            'rest',
            `/services/data/v66.0/sobjects/ContentVersion/${id(report.files.finalPdfCvId)}/VersionData`,
            '--target-org',
            org,
            '--stream-to-file',
            file
        ]);
        report.downloadElapsedMs = Date.now() - publicationStartedAt;
        report.stage = 'verify';
        const verificationStartedAt = Date.now();
        await checkPdf(file, benchmark, report);
        report.verificationElapsedMs = Date.now() - verificationStartedAt;
        report.stage = 'complete';
    } catch (error) {
        report.error = error.message;
    }
    report.elapsedMs = Date.now() - start;
    save(receipt, report);
    return report;
}

assert(await available(), 'Install Poppler so the check can read the generated PDF.');
const orgs = await sfJson(['org', 'list', '--skip-connection-status']);
assert(
    orgs.scratchOrgs.some((entry) => !entry.isExpired && (entry.alias === org || entry.username === org)),
    'Use an authenticated scratch org.'
);
const source = {};
for (const group of ['A', 'B']) {
    const { node } = dataset(group, 50000);
    const [count] = await query(
        `SELECT COUNT(Id) total FROM Contact WHERE AccountId = '${accountId}' AND ${node.where}`
    );
    assert.equal(count?.total, 50000, `Synthetic Scale ${group} fixture count`);
    source[group] = count.total;
}

mkdirSync(outputDir, { recursive: true });
const summary = [];
for (const rows of matrix) {
    const report = await runCase(rows, source);
    const { printedRows, distinctRows, stage, elapsedMs, generation, job, pdf, error } = report;
    summary.push({
        printedRows,
        distinctRows,
        stage,
        elapsedMs,
        generation,
        jobId: job?.Id,
        harvestedRows: job?.Success_Count__c,
        pdf,
        error
    });
    save(join(outputDir, 'matrix.json'), summary);
    console.log(JSON.stringify(summary.at(-1)));
    if (error && report.launch?.jobId && !['Completed', 'Failed', 'Cancelled'].includes(job?.Status__c)) break;
}
if (summary.some((entry) => entry.error)) process.exitCode = 1;
