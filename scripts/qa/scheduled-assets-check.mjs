/**
 * Real managed-package asset rendering regression test.
 *
 * Fresh org, current managed package:
 *   node scripts/qa/scheduled-assets-check.mjs --org asset-check --create --hub <DevHub>
 * Previously released version:
 *   add --package 04tVx0000015OKTIA2 (3.57.0.2)
 * Namespaced scratch org with source deployed instead of a managed install:
 *   add --source
 * Existing scratch org, package already installed:
 *   node scripts/qa/scheduled-assets-check.mjs --org asset-check
 * Repeat the same fixtures as another authenticated user:
 *   node scripts/qa/scheduled-assets-check.mjs --org asset-check --runner-org <user-alias> --reuse-fixture
 * The other user needs DocGen_User plus Run Flows/access to QA_Asset_Probe.
 * Recheck saved output IDs without creating more records:
 *   add --verify-results <results.json> --output-dir <evidence-directory>
 *
 * Requires sf, pdfimages, pdfinfo, pdftotext, pdftoppm. Writes PDFs, rendered PNGs and JSON evidence.
 * A genuine one-minute scheduled path calls the SAME subflow as the manual
 * control, using the SAME Account, templates and private image File. Both call
 * DocGenGiantQueryFlowAction, matching the supplied customer logs. No public
 * ContentDistribution is created. A successful action alone is never a pass:
 * PDF image occurrence counts and rendered pages must also match.
 * Expected placements: HTML header/body/attribute/footer (4); Word native
 * header/body/footer (3). Missing images are recorded even when both contexts
 * produce the same page. The fixture currently exposes missing Word native
 * header/footer images on the released 3.57.0.2 and 3.59.0.2 packages, in BOTH contexts.
 * This covers a record-triggered scheduled path. Daily schedule-triggered
 * Flows, CPQ and Screen Flow UI behavior require separate checks.
 */
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFileSync, writeFileSync, mkdirSync, cpSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const exec = promisify(execFile);
const root = fileURLToPath(new URL('../../', import.meta.url));
const fixture = join(root, 'scripts/qa/fixtures/scheduled-assets');
const args = process.argv.slice(2);
const value = (key, fallback) => (args.includes(key) ? args[args.indexOf(key) + 1] : fallback);
const org = value('--org');
assert(org, 'Provide --org <scratch-org-alias>.');
const runner = value('--runner-org', org);
const out = resolve(value('--output-dir', join(root, 'output', `scheduled-assets-${runner}`)));
mkdirSync(out, { recursive: true });
const save = (name, value) => writeFileSync(join(out, name), JSON.stringify(value, null, 2) + '\n');

async function command(executable, commandArgs) {
    try {
        return (await exec(executable, commandArgs, { cwd: root, maxBuffer: 64 * 1024 * 1024 })).stdout;
    } catch (error) {
        throw new Error(
            `${executable} ${commandArgs.slice(0, 3).join(' ')} failed:\n${error.stdout || ''}\n${error.stderr || error.message}`
        );
    }
}
async function sf(commandArgs) {
    const result = JSON.parse(await command('sf', [...commandArgs, '--json']));
    assert.equal(result.status, 0, JSON.stringify(result));
    return result.result;
}
async function query(queryText, target = org) {
    return (await sf(['data', 'query', '--target-org', target, '--query', queryText])).records;
}
async function deploy(directory) {
    const result = await sf([
        'project',
        'deploy',
        'start',
        '--target-org',
        org,
        '--metadata-dir',
        directory,
        '--wait',
        '15'
    ]);
    assert.equal(result.status, 'Succeeded', JSON.stringify(result.details));
}
async function api(path, { target = org, body, output } = {}) {
    const commandArgs = ['api', 'request', 'rest', path, '--target-org', target];
    if (body) {
        const bodyPath = join(out, 'request.json');
        writeFileSync(bodyPath, JSON.stringify(body));
        commandArgs.push('--method', 'POST', '--body', `@${bodyPath}`);
    }
    if (output) commandArgs.push('--stream-to-file', output);
    const response = await command('sf', commandArgs);
    return output ? undefined : JSON.parse(response);
}
function summary(record) {
    assert(record.Description, 'Flow has not persisted its result.');
    const [context, ...pairs] = record.Description.split('|');
    return {
        context,
        ...Object.fromEntries(pairs.map((p) => [p.slice(0, p.indexOf('=')), p.slice(p.indexOf('=') + 1)]))
    };
}
async function collect(result, prefix) {
    assert.equal(result.htmlSuccess, 'true', result.htmlError);
    assert.equal(result.wordSuccess, 'true', result.wordError);
    const files = {};
    for (const [format, expected] of [
        ['html', 4],
        ['word', 3]
    ]) {
        const pdf = join(out, `${prefix}-${format}.pdf`);
        await api(`/services/data/v66.0/sobjects/ContentVersion/${result[format]}/VersionData`, { output: pdf });
        const images = await command('pdfimages', ['-list', pdf]);
        writeFileSync(join(out, `${prefix}-${format}-images.txt`), images);
        const imageRows = images.split('\n').filter((line) => /^\s*\d+\s+\d+\s+image\s/.test(line));
        const count = imageRows.length;
        const renderedPpi = imageRows.map((row) => Number(row.trim().split(/\s+/)[12])).sort((a, b) => a - b);
        const expectedPpi = format === 'html' ? [96, 96, 192, 192] : [96, 192, 192];
        for (const row of imageRows) {
            assert.deepEqual(
                row.trim().split(/\s+/).slice(3, 5),
                ['240', '80'],
                `${prefix} ${format}: image dimensions do not match the fixture`
            );
        }
        assert.match(await command('pdfinfo', [pdf]), /Pages:\s+1\b/, 'Fixture should render on one page.');
        const text = await command('pdftotext', [pdf, '-']);
        assert(!/\{%asset:|\[missing asset:/i.test(text), 'Unresolved asset tag in generated PDF.');
        const png = join(out, `${prefix}-${format}`);
        await command('pdftoppm', ['-scale-to', '1100', '-singlefile', '-png', pdf, png]);
        files[format] = {
            contentVersionId: result[format],
            imageOccurrences: count,
            expectedImageOccurrences: expected,
            imagesPassed: count === expected,
            renderedPpi,
            expectedPpi,
            sizingPassed: JSON.stringify(renderedPpi) === JSON.stringify(expectedPpi),
            renderedSha256: createHash('sha256')
                .update(readFileSync(`${png}.png`))
                .digest('hex')
        };
    }
    return files;
}

function finish(results, manualFiles, scheduledFiles) {
    const comparisons = Object.fromEntries(
        ['html', 'word'].map((format) => [
            format,
            {
                sameRenderedPage: manualFiles[format].renderedSha256 === scheduledFiles[format].renderedSha256,
                manualImagesPassed: manualFiles[format].imagesPassed,
                scheduledImagesPassed: scheduledFiles[format].imagesPassed,
                manualSizingPassed: manualFiles[format].sizingPassed,
                scheduledSizingPassed: scheduledFiles[format].sizingPassed
            }
        ])
    );
    const status = Object.values(comparisons).every(
        (c) =>
            c.sameRenderedPage &&
            c.manualImagesPassed &&
            c.scheduledImagesPassed &&
            c.manualSizingPassed &&
            c.scheduledSizingPassed
    )
        ? 'PASS'
        : 'FAIL';
    save('results.json', { ...results, status, comparisons, manualFiles, scheduledFiles });
    console.log(
        `${status}: HTML images ${manualFiles.html.imageOccurrences}/4 manual, ${scheduledFiles.html.imageOccurrences}/4 scheduled; ` +
            `Word images ${manualFiles.word.imageOccurrences}/3 manual, ${scheduledFiles.word.imageOccurrences}/3 scheduled. Evidence: ${out}`
    );
    process.exitCode = status === 'PASS' ? 0 : 1;
}

// Recheck saved run IDs without creating records or scheduling another interview.
if (args.includes('--verify-results')) {
    const results = JSON.parse(readFileSync(value('--verify-results')));
    assert.equal(results.org, org, 'Saved run belongs to a different org.');
    const manualFiles = await collect(results.manual, 'manual');
    const scheduledFiles = await collect(results.scheduled, 'scheduled');
    finish(results, manualFiles, scheduledFiles);
    process.exit(process.exitCode);
}

if (args.includes('--create')) {
    const definition = JSON.parse(readFileSync(join(root, 'config/project-scratch-def.json')));
    definition.orgName = 'QA Scheduled Asset Regression';
    definition.features.push('DefaultWorkflowUser');
    save('scratch-def.json', definition);
    const hub = value('--hub');
    assert(hub, '--create requires --hub <DevHub>.');
    await sf([
        'org',
        'create',
        'scratch',
        '--alias',
        org,
        '--target-dev-hub',
        hub,
        '--definition-file',
        join(out, 'scratch-def.json'),
        '--duration-days',
        '7',
        '--no-namespace',
        '--wait',
        '15'
    ]);
    await sf([
        'package',
        'install',
        '--target-org',
        org,
        '--package',
        value('--package', '04tVx0000019Ki5IAE'),
        '--wait',
        '20',
        '--publish-wait',
        '10',
        '--no-prompt'
    ]);
}
const identity = await sf(['org', 'display', '--target-org', org]);
// Do not persist org-display output: some CLI versions include credentials.
const orgInventory = await sf(['org', 'list']);
assert(
    orgInventory.scratchOrgs.some((candidate) => candidate.orgId === identity.id && !candidate.isExpired),
    'This test only mutates active scratch orgs.'
);
const runningIdentity = await sf(['org', 'display', '--target-org', runner]);
assert.equal(runningIdentity.id, identity.id, 'Runner must belong to this scratch org.');
const installed = await sf(['package', 'installed', 'list', '--target-org', org]);
let packageInfo = installed.find((p) => p.SubscriberPackageNamespace === 'portwoodglobal');
if (!packageInfo && args.includes('--source')) {
    const classes = await sf([
        'data',
        'query',
        '--target-org',
        org,
        '--use-tooling-api',
        '--query',
        "SELECT Id FROM ApexClass WHERE Name = 'DocGenService' AND NamespacePrefix = 'portwoodglobal'"
    ]);
    assert.equal(classes.records.length, 1, '--source requires the Portwood source deployed in its namespace.');
    packageInfo = { sourceDeployment: true, namespace: 'portwoodglobal' };
}
assert(packageInfo, 'Install Portwood before running this test.');

if (!args.includes('--reuse-fixture')) {
    for (const name of ['portwoodglobal__DocGen_Admin', 'portwoodglobal__DocGen_User']) {
        await sf(['org', 'assign', 'permset', '--target-org', org, '--name', name]);
    }
    assert.equal(
        (await query("SELECT Id FROM portwoodglobal__DocGen_Asset__c WHERE portwoodglobal__Asset_Key__c = 'qa-logo'"))
            .length,
        0,
        'Fixtures already exist. Use --reuse-fixture to repeat them.'
    );
    const seedPath = join(out, 'seed.apex');
    writeFileSync(
        seedPath,
        readFileSync(join(fixture, 'seed.apex'), 'utf8').replace('__EXPECTED_ORG_ID__', identity.id)
    );
    const seeded = await sf(['apex', 'run', '--target-org', org, '--file', seedPath]);
    assert(seeded.success, seeded.exceptionMessage || seeded.compileProblem);
    save('seed-result.json', seeded);
    cpSync(join(fixture, 'metadata'), join(out, 'metadata'), { recursive: true });
    await deploy(join(out, 'metadata'));
}

const image = (
    await query("SELECT Id, ContentDocumentId FROM ContentVersion WHERE Title = 'QA Private Image' AND IsLatest = true")
)[0];
assert(image, 'Missing image fixture.');
assert.equal(
    (await query(`SELECT Id FROM ContentDistribution WHERE ContentDocumentId = '${image.ContentDocumentId}'`)).length,
    0,
    'This test requires a private image with no public delivery.'
);
assert.equal(
    (await query(`SELECT Id FROM ContentVersion WHERE Id = '${image.Id}'`, runner)).length,
    1,
    'Runner cannot read the image File before rendering.'
);

const account = await sf([
    'data',
    'create',
    'record',
    '--target-org',
    runner,
    '--sobject',
    'Account',
    '--values',
    "Name='QA Scheduled Asset Probe'"
]);
const flowDefinitions = await sf([
    'data',
    'query',
    '--target-org',
    org,
    '--use-tooling-api',
    '--query',
    "SELECT NamespacePrefix FROM FlowDefinition WHERE DeveloperName = 'QA_Asset_Probe'"
]);
assert.equal(flowDefinitions.records.length, 1, 'Expected exactly one asset probe Flow.');
const flowNamespace = flowDefinitions.records[0].NamespacePrefix;
const flowActionName = (flowNamespace ? flowNamespace + '__' : '') + 'QA_Asset_Probe';
const manualResponse = await api('/services/data/v66.0/actions/custom/flow/' + flowActionName, {
    target: runner,
    body: { inputs: [{ recordId: account.id, contextLabel: 'manual-flow' }] }
});
save('manual-response.json', manualResponse);
assert(manualResponse[0].isSuccess, JSON.stringify(manualResponse[0].errors));
const accountQuery = `SELECT Id, Description FROM Account WHERE Id = '${account.id}'`;
const manual = summary((await query(accountQuery))[0]);
assert.equal(manual.context, 'manual-flow');
save('manual-result.json', manual);
const manualFiles = await collect(manual, 'manual');
console.log(
    'Manual PDFs collected. Waiting for the real scheduled path (Salesforce may run it after the nominal one-minute delay).'
);
const deadline = Date.now() + 12 * 60 * 1000;
let scheduled;
while (Date.now() < deadline) {
    const current = summary((await query(accountQuery))[0]);
    if (current.context === 'scheduled-path') {
        scheduled = current;
        break;
    }
    await new Promise((resolve) => setTimeout(resolve, 20000));
}
assert(scheduled, 'Scheduled path did not finish within 12 minutes. Inspect Time-Based Automations and Flow errors.');
save('scheduled-result.json', scheduled);
assert.equal(scheduled.user, manual.user, 'Running user differs between controls.');
const scheduledFiles = await collect(scheduled, 'scheduled');
finish(
    {
        orgId: identity.id,
        org,
        runner,
        packageInfo,
        accountId: account.id,
        imageVersionId: image.Id,
        publicDeliveryCount: 0,
        manual,
        scheduled
    },
    manualFiles,
    scheduledFiles
);
