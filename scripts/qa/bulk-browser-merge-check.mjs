// Run with: node scripts/qa/bulk-browser-merge-check.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const runnerPath = '../../force-app/main/default/lwc/docGenBulkRunner/docGenBulkRunner';
const source = readFileSync(new URL(runnerPath + '.js', import.meta.url), 'utf8');
const markup = readFileSync(new URL(runnerPath + '.html', import.meta.url), 'utf8');
const executable = source
    .replace(/^import .+;$/gm, '')
    .replace(/^ *@wire\(.+\)\s*$/gm, '')
    .replace(/@track /g, '')
    .replace(/^export default class /m, 'class ');

const userId = '005-current';
const navigate = Symbol('navigation');
const field = (name) => ({ fieldApiName: 'portwoodglobal__' + name });
const configuredFormat = field('Output_Format__c');
const configuredType = field('Type__c');
const browserMergeField = field('Browser_Merge__c');
const statusField = field('Status__c');
const successField = field('Success_Count__c');
const errorField = field('Error_Count__c');
const totalField = field('Total_Records__c');
const labelField = field('Label__c');
const args = [];
const toasts = [];
const pages = [];
const NavigationMixin = (Base) =>
    class extends Base {
        [navigate](page) {
            pages.push(page);
        }
    };
NavigationMixin.Navigate = navigate;
const toPlain = (value) => JSON.parse(JSON.stringify(value));

const context = {
    LightningElement: class {},
    NavigationMixin,
    window: { location: { assign: (url) => pages.push({ url }) } },
    CURRENT_USER_ID: userId,
    OUT_FMT_FIELD: configuredFormat,
    TEMPLATE_TYPE_FIELD: configuredType,
    JOB_BROWSER_MERGE_FIELD: browserMergeField,
    JOB_STATUS_FIELD: statusField,
    JOB_SUCCESS_FIELD: successField,
    JOB_ERROR_FIELD: errorField,
    JOB_TOTAL_FIELD: totalField,
    JOB_LABEL_FIELD: labelField,
    console,
    analyzeJob: async (input) => {
        args.push({ action: 'analyze', ...input });
        return { canProceed: true, items: [] };
    },
    submitJob: async (input) => {
        args.push({ action: 'submit', ...input });
        return 'legacy-job';
    },
    submitBrowserMergeJob: async (input) => {
        args.push({ action: 'browser-submit', ...input });
        return 'browser-job';
    },
    getBrowserMergeDownloadUrl: async (input) => {
        args.push({ action: 'download', ...input });
        return 'https://portwood.example.test/apex/portwoodglobal__DocGenBulkPdfDownload?jobId=' + input.jobId;
    },
    retryBrowserMergeJob: async (input) => {
        args.push({ action: 'retry', ...input });
        return input.jobId;
    }
};

const Runner = runInNewContext(executable + '\nDocGenBulkRunner;', context);
const component = new Runner();
component.showToast = (...toast) => toasts.push(toast);
component.startPolling = () => args.push({ action: 'poll' });
component.jobLabel = 'Private receipt job';
component.batchSize = 10;
component.condition = 'Id != null';
component.sortField = 'Name';
component.sortDirection = 'DESC';
component.selectedTemplateId = 'template';
component.recordCount = 12;
component.filterValidated = true;
const legacyModes = ['individual', 'combined', 'both'];
const choices = () => toPlain(component.outputModeOptions.map((option) => option.value));

assert.equal(component.outputMode, 'combined', 'legacy mode remains the default');
assert.deepEqual(choices(), legacyModes);
for (const [type, format, expectBrowserMerge] of [
    ['HTML', 'PDF', true],
    ['Word', 'PDF', true],
    ['Canvas', 'PDF', true],
    ['Word', 'Native', false],
    ['PDF', 'PDF', false],
    ['Excel', 'PDF', false],
    ['PowerPoint', 'PDF', false]
]) {
    component._templateDataMap.template = {
        [configuredFormat.fieldApiName]: format,
        [configuredType.fieldApiName]: type
    };
    assert.deepEqual(
        choices(),
        expectBrowserMerge ? [...legacyModes, 'browserMerge'] : legacyModes,
        type + ' / ' + format
    );
}

component._templateDataMap.template[configuredType.fieldApiName] = 'HTML';
component.duplexPadding = true;
component.handleOutputModeChange({ detail: { value: 'browserMerge' } });
assert.equal(component.duplexPadding, false);
assert.equal(component.showDuplexPadding, false);
assert.equal(args.at(-1).mergePdf, false);
assert.equal(args.at(-1).duplexPadding, false);
await component.handleRun();
assert.equal(component.jobId, 'browser-job');
assert.equal(component.jobStatus, 'Queued');
assert.deepEqual(toPlain(args.at(-2)), {
    action: 'browser-submit',
    templateId: 'template',
    condition: 'Id != null',
    jobLabel: 'Private receipt job',
    batchSize: 10,
    sortOrder: 'Name DESC'
});
for (const [mode, mergePdf, mergeOnly] of [
    ['combined', true, true],
    ['both', true, false],
    ['individual', false, false]
]) {
    component.outputMode = mode;
    component.isProcessing = false;
    component.duplexPadding = true;
    await component.handleRun();
    assert.equal(component.jobId, 'legacy-job');
    assert.equal(args.at(-2).action, 'submit');
    assert.equal(args.at(-2).mergePdf, mergePdf);
    assert.equal(args.at(-2).mergeOnly, mergeOnly);
    assert.equal(args.at(-2).duplexPadding, mergePdf);
}

function job(Id, status, { owner = userId, creator = userId, browserMerge = true, success = 12, total = 12 } = {}) {
    return {
        Id,
        Name: Id,
        OwnerId: owner,
        CreatedById: creator,
        CreatedDate: '2026-10-04T00:00:00.000Z',
        [browserMergeField.fieldApiName]: browserMerge,
        [statusField.fieldApiName]: status,
        [successField.fieldApiName]: success,
        [errorField.fieldApiName]: total - success,
        [totalField.fieldApiName]: total
    };
}
context.getRecentJobs = async () => [
    job('ready', 'Completed'),
    job('failed', 'Completed with Errors', { success: 11 }),
    job('transferred', 'Completed with Errors', { creator: '005-other', success: 11 }),
    job('incomplete', 'Completed', { success: 11 }),
    job('no-sources', 'Failed', { success: 0, total: 0 }),
    job('other', 'Completed', { owner: '005-other' }),
    job('legacy', 'Completed', { browserMerge: false }),
    job('queued', 'Queued', { success: 0 })
];
await component.loadRecentJobs();
const history = Object.fromEntries(component.recentJobs.map((row) => [row.id, row]));
assert.ok(history.ready.downloadReady && !history.ready.retryReady);
assert.ok(history.failed.retryReady && !history.failed.downloadReady);
assert.ok(!history.transferred.retryReady);
assert.ok(!history.incomplete.downloadReady);
assert.ok(!history['no-sources'].retryReady);
assert.ok(!history.other.downloadReady && !history.other.retryReady);
assert.ok(!history.legacy.downloadReady);
assert.ok(history.queued.isRunning && !history.queued.downloadReady);

const events = [];
const click = (jobid) => ({
    currentTarget: { dataset: { jobid } },
    stopPropagation: () => events.push('stopped')
});

await component.handleOpenBrowserDownload(click('ready'));
assert.deepEqual(toPlain(pages[0]), {
    url: 'https://portwood.example.test/apex/portwoodglobal__DocGenBulkPdfDownload?jobId=ready'
});
context.getBrowserMergeDownloadUrl = async () => {
    throw { body: { message: 'The private revision is unavailable.' } };
};
await component.handleOpenBrowserDownload(click('other'));
assert.equal(pages.length, 1);
assert.deepEqual(toasts.at(-1), ['Download Error', 'The private revision is unavailable.', 'error']);
assert.equal(component.isOpeningBrowserDownload, false);
assert.equal(events.length, 2, 'the history row click should not navigate to its job record');

component.isProcessing = false;
await component.handleRetryBrowserMerge(click('failed'));
assert.equal(component.jobId, 'failed');
assert.equal(component.jobStatus, 'Queued');
assert.equal(component.isProcessing, true);
context.getJobStatus = async () => job('failed', 'Completed');
await component.pollJob();
assert.equal(component.jobProgress.percent, 100);
assert.ok(component.jobBrowserActions.downloadReady);

component._templateDataMap.template[configuredType.fieldApiName] = 'PDF';
component.outputMode = 'browserMerge';
assert.ok(component.isRunDisabled);
component.resetUnsupportedBrowserMerge();
assert.equal(component.outputMode, 'individual');

assert.equal((markup.match(/onclick=\{handleOpenBrowserDownload\}/g) ?? []).length, 2);
assert.equal((markup.match(/onclick=\{handleRetryBrowserMerge\}/g) ?? []).length, 2);
console.log('Bulk browser merge mode, native compatibility, ready download, and retry checks passed.');
