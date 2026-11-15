import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { request } from 'node:https';
import { resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { parseArgs } from 'node:util';
import { downloadPart, salesforceConnection } from '../../scripts/lib/salesforce-pdf-transport.mjs';

const [action, ...args] = process.argv.slice(2);
const { values } = parseArgs({args, options: {
  org: { type: 'string' }, 'org-id': { type: 'string' }, 'template-id': { type: 'string' },
  first: { type: 'string' }, last: { type: 'string' }, 'run-key': { type: 'string' },
  'account-prefix': { type: 'string', default: 'PW-BENCH-100K-2025-' }, 'account-width': { type: 'string', default: '6' },
  shards: { type: 'string', default: '5' }, scope: { type: 'string', default: '40' }, native: { type: 'boolean', default: false },
  'state-dir': { type: 'string', default: 'tmp/portwood-live-receipt-timing/waves' },
  'wait-minutes': { type: 'string', default: '90' }, 'poll-seconds': { type: 'string', default: '15' },
} });
assert.ok(['plan', 'submit', 'status', 'wait', 'audit'].includes(action),
  'Usage: orchestrate-account-batches.mjs plan|submit|status|wait|audit --org ALIAS --org-id ID --template-id ID --run-key KEY --first N --last N');

const idPattern = /^[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?$/;
const integer = (value, min, max) => {
  const n = Number(value);
  assert.ok(Number.isSafeInteger(n) && n >= min && n <= max, `Expected integer ${min} through ${max}.`);
  return n;
};
const first = integer(values.first, 1, 100_000);
const last = integer(values.last, first, 100_000);
const shardCount = integer(values.shards, 1, Math.min(5, last - first + 1));
const scope = integer(values.scope, 1, 40);
const accountWidth = integer(values['account-width'], 4, 8);
const pollSeconds = integer(values['poll-seconds'], 5, 60);
const waitMinutes = integer(values['wait-minutes'], 1, 360);
const accountPrefix = values['account-prefix'];
const runKey = values['run-key'];
assert.match(accountPrefix, /^[A-Za-z0-9-]{1,30}-$/);
assert.match(runKey, /^[A-Za-z0-9-]{1,48}$/);
assert.ok(String(last).length <= accountWidth, 'The requested ordinal exceeds the AccountNumber width.');
assert.match(values.org, /^[A-Za-z0-9][A-Za-z0-9-]+$/);
assert.match(values['org-id'], /^00D[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/);
assert.match(values['template-id'], idPattern);

const ordinal = n => String(n).padStart(6, '0');
const accountNumber = n => accountPrefix + String(n).padStart(accountWidth, '0');
const filesPrefix = `PW-ACCOUNT-RECEIPT-${runKey}-`;
const waveName = `${runKey}-${ordinal(first)}-${ordinal(last)}`;
const receiptTitle = `PW-ACCOUNT-RECEIPT-SUBMIT-${waveName}`;
const stateBase = resolve(values['state-dir'], waveName);
const count = last - first + 1;
const templateId = values['template-id'];
const shards = Array.from({length: shardCount}, (_, index) => {
  const start = first + Math.floor(index * count / shardCount);
  const end = first + Math.floor((index + 1) * count / shardCount) - 1;
  return { first: start, last: end, accounts: end - start + 1 };
});
const plan = { org: values.org, orgId: values['org-id'], templateId, first, last, accountPrefix, accountWidth,
  runKey, count, scope, usePrefetched: !values.native, shards, filesPrefix, receiptTitle };
const planDigest = createHash('sha256').update(JSON.stringify(plan)).digest('hex');
const terminalStatuses = new Set(['Completed', 'Failed', 'Aborted']);
const apiPath = '/services/data/v68.0';
const qualifiedTitle = jobId => `PW-ACCOUNT-RECEIPT-METRICS-${runKey}-${jobId}`;
const scopeFilter = `IsLatest = true AND Title LIKE '${filesPrefix}%' AND Title >= '${filesPrefix}${ordinal(first)}' AND Title <= '${filesPrefix}${ordinal(last)}'`;
let connection;

function launchApex() {
  const entries = (name, values) => `List<${name}> { ${values.join(', ')} }`;
  const starts = entries('String', shards.map(shard => `'${accountNumber(shard.first)}'`));
  const ends = entries('String', shards.map(shard => `'${accountNumber(shard.last)}'`));
  const sizes = entries('Integer', shards.map(shard => shard.accounts));
  return `String receiptTitle = '${receiptTitle}';
Id owner = UserInfo.getUserId();
String gateNumber = '${accountNumber(first)}';
List<Account> gate = [SELECT Id FROM Account WHERE AccountNumber = :gateNumber WITH USER_MODE LIMIT 2 FOR UPDATE];
Assert.areEqual(1, gate.size(), 'Expected one exact first Account before submitting the wave.');
List<ContentVersion> prior = [SELECT VersionData FROM ContentVersion WHERE IsLatest = true AND Title = :receiptTitle
    AND OwnerId = :owner WITH USER_MODE LIMIT 2];
Assert.isTrue(prior.size() <= 1, 'The submission receipt is ambiguous.');
if (prior.isEmpty()) {
    List<String> starts = new ${starts};
    List<String> ends = new ${ends};
    List<Integer> sizes = new ${sizes};
    String cohort = '${accountPrefix}%';
    List<Id> jobs = new List<Id>();
    for (Integer index = 0; index < starts.size(); index++) {
        String low = starts[index];
        String high = ends[index];
        Integer existing = [SELECT COUNT() FROM Account WHERE AccountNumber LIKE :cohort AND AccountNumber >= :low
            AND AccountNumber <= :high WITH USER_MODE];
        Assert.areEqual(sizes[index], existing, 'The synthetic source shard is incomplete.');
        jobs.add(Database.executeBatch(new PortwoodAccountReceiptBatch('${templateId}', low, high,
            '${runKey}', ${!values.native}), ${scope}));
    }
    Blob receipt = Blob.valueOf(JSON.serialize(new Map<String, Object>{'planDigest' => '${planDigest}', 'jobs' => jobs}));
    insert as user new ContentVersion(Title = receiptTitle, PathOnClient = receiptTitle + '.json',
        VersionData = receipt, SharingPrivacy = 'P', SharingOption = 'R');
}
`;
}

async function saveJson(suffix, value) {
  const file = stateBase + suffix;
  const partial = `${file}.${process.pid}.partial`;
  await writeFile(partial, JSON.stringify(value, null, 2) + '\n', {mode: 0o600});
  await rename(partial, file);
}

async function prepare() {
  await mkdir(resolve(values['state-dir']), {recursive: true});
  const existing = await readFile(stateBase + '.plan.json', 'utf8').catch(error => {
    if (error.code !== 'ENOENT') throw error;
    return null;
  });
  if (existing) assert.equal(JSON.parse(existing).planDigest, planDigest, 'An existing local wave has a different plan.');
  else await saveJson('.plan.json', {...plan, planDigest});
  const path = stateBase + '.apex';
  await writeFile(path, launchApex(), {mode: 0o600});
  return path;
}

function getJson(path) {
  assert.ok(path.startsWith(apiPath + '/'), 'Unexpected Salesforce REST continuation.');
  return new Promise((res, rej) => {
    const req = request(new URL(path, connection.origin), {
      agent: connection.agent, headers: {Authorization: 'Bearer ' + connection.accessToken},
      signal: AbortSignal.timeout(30_000),
    }, async response => {
      try {
        const pieces = [];
        for await (const bytes of response) pieces.push(bytes);
        const json = JSON.parse(Buffer.concat(pieces));
        if (response.statusCode !== 200) throw new Error(`Salesforce REST ${response.statusCode}: ${json[0]?.errorCode ?? 'UNKNOWN'}`);
        res(json);
      } catch (error) {
        rej(error);
      }
    });
    req.on('error', rej);
    req.end();
  });
}

async function queryAll(soql) {
  let path = apiPath + '/query?q=' + encodeURIComponent(soql);
  const rows = [];
  while (path) {
    const page = await getJson(path);
    rows.push(...page.records.map(({attributes, ...row}) => row));
    path = page.nextRecordsUrl;
  }
  return rows;
}

async function smallFileJson(row) {
  assert.equal(row.SharingPrivacy, 'P');
  assert.ok(row.ContentSize > 0 && row.ContentSize <= 64 * 1024, 'Invalid private metrics File size.');
  const source = await downloadPart(connection, row.Id, AbortSignal.timeout(30_000));
  const parts = [];
  let bytes = 0;
  for await (const part of source) {
    bytes += part.length;
    assert.ok(bytes <= row.ContentSize, 'Private metrics File exceeds expected size.');
    parts.push(part);
  }
  assert.equal(bytes, row.ContentSize);
  return JSON.parse(Buffer.concat(parts));
}

async function submissionReceipt() {
  const values = await queryAll("SELECT Id, ContentSize, SharingPrivacy FROM ContentVersion WHERE IsLatest = true AND Title = '" + receiptTitle + "'");
  assert.ok(values.length <= 1, 'Multiple Salesforce submission receipts have the same title.');
  if (values.length === 0) return null;
  const report = await smallFileJson(values[0]);
  assert.equal(report.planDigest, planDigest, 'A submitted Salesforce wave differs from this plan.');
  assert.equal(report.jobs.length, shardCount);
  assert.equal(new Set(report.jobs).size, shardCount);
  assert.ok(report.jobs.every(id => /^707[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/.test(id)));
  return report.jobs;
}

async function submit(apexPath) {
  try {
    execFileSync('sf', ['apex', 'run', '--target-org', plan.org, '--file', apexPath, '--json'], {
      env: {...process.env, SF_DISABLE_TELEMETRY: 'true'}, encoding: 'utf8', timeout: 180_000, maxBuffer: 12 * 1024 * 1024,
    });
  } catch (error) {
    const committed = await submissionReceipt();
    if (committed) return committed;
    let reason;
    try { reason = JSON.parse(error.stdout).message; } catch { /* use generic CLI failure */ }
    throw new Error(reason || 'Wave submission failed. Rerun submit with the same plan to recover safely.');
  }
  const jobs = await submissionReceipt();
  assert.ok(jobs, 'The Salesforce submission receipt is not yet visible. Rerun submit with the same plan.');
  return jobs;
}

async function status(jobs) {
  const ids = jobs.map(id => `'${id}'`).join(',');
  const found = await queryAll(`SELECT Id, CreatedById, CreatedDate, CompletedDate, Status, JobItemsProcessed, TotalJobItems,
    NumberOfErrors, ExtendedStatus FROM AsyncApexJob WHERE Id IN (${ids})`);
  const rows = jobs.map((id, index) => ({...shards[index], ...found.find(row => row.Id === id)}));
  assert.ok(rows.every(row => row.Id), 'One or more submitted jobs are not yet visible.');
  await saveJson('.status.json', { checkedAt: new Date().toISOString(), rows });
  console.log(JSON.stringify(rows));
  return rows;
}

function assertSuccess(rows) {
  assert.ok(rows.every(row => row.Status === 'Completed' && row.NumberOfErrors === 0 &&
    row.JobItemsProcessed === row.TotalJobItems && row.CompletedDate), 'A batch shard failed, aborted, or has unprocessed scopes.');
}

async function audit(rows) {
  assertSuccess(rows);
  const ownerIds = new Set(rows.map(row => row.CreatedById));
  assert.equal(ownerIds.size, 1, 'The batch jobs have different owners.');
  const ownerId = [...ownerIds][0];
  assert.match(ownerId, /^005[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/);
  const titles = rows.map(row => `'${qualifiedTitle(row.Id)}'`).join(',');
  const metricsFiles = await queryAll(`SELECT Id, Title, ContentSize, SharingPrivacy FROM ContentVersion
    WHERE IsLatest = true AND OwnerId = '${ownerId}' AND Title IN (${titles})`);
  assert.equal(metricsFiles.length, shardCount, 'Missing or duplicated metrics Files.');
  const metrics = await Promise.all(rows.map(async row => {
    const file = metricsFiles.find(file => file.Title === qualifiedTitle(row.Id));
    assert.ok(file, `Missing metrics File for ${row.Id}.`);
    const result = await smallFileJson(file);
    assert.equal(result.batchJobId, row.Id);
    assert.equal(result.runKey, runKey);
    assert.equal(result.filesSaved, row.accounts, 'A batch did not write every planned receipt.');
    assert.equal(result.apexCallouts, 0);
    return result;
  }));
  const files = await queryAll(`SELECT Id, ContentDocumentId, Title, ContentSize, Checksum, FileType, SharingPrivacy,
    SharingOption, OwnerId, FirstPublishLocationId FROM ContentVersion WHERE ${scopeFilter} AND OwnerId = '${ownerId}' ORDER BY Title`);
  assert.equal(files.length, count, 'Missing or duplicated statement Files.');
  files.forEach((file, index) => {
    assert.equal(file.Title, filesPrefix + ordinal(first + index));
    assert.equal(file.SharingPrivacy, 'P');
    assert.equal(file.SharingOption, 'R');
    assert.ok(file.FirstPublishLocationId === null || file.FirstPublishLocationId === ownerId, 'A receipt was attached to a record.');
    assert.equal(file.FileType, 'PDF');
    assert.ok(file.ContentSize > 0);
    assert.match(file.Checksum, /^[a-f0-9]{32}$/i);
  });
  const totalBytes = files.reduce((sum, file) => sum + file.ContentSize, 0);
  assert.equal(totalBytes, metrics.reduce((sum, item) => sum + item.savedBytes, 0));
  const createdAt = Math.min(...rows.map(row => Date.parse(row.CreatedDate)));
  const completedAt = Math.max(...rows.map(row => Date.parse(row.CompletedDate)));
  const stages = ['sourcePrefetchWallMs', 'managedRenderWallMs', 'fileSaveWallMs', 'sumScopeWallMs', 'sumScopeCpuMs'];
  const report = { ...plan, planDigest, jobs: rows, metrics, files: files.length, totalBytes,
    firstJobCreatedAt: new Date(createdAt).toISOString(), lastJobCompletedAt: new Date(completedAt).toISOString(),
    generationWallMs: completedAt - createdAt,
    summedScopeTimings: Object.fromEntries(stages.map(stage => [stage, metrics.reduce((sum, item) => sum + item[stage], 0)])),
    manifestPath: stateBase + '.versions.json' };
  await saveJson('.versions.json', {org: plan.org, orgId: plan.orgId, planDigest, first, last, runKey,
    versions: files.map((file, index) => ({ordinal: first + index, ...file}))});
  await saveJson('.audit.json', report);
  console.log(JSON.stringify(report));
}

try {
  const apexPath = await prepare();
  if (action === 'plan') {
    console.log(JSON.stringify({...plan, planDigest, apexPath}, null, 2));
  } else {
    connection = await salesforceConnection(plan.org, { keepAlive: true, maxSockets: 8 });
    assert.match(connection.origin.hostname, /\.scratch\.my\.salesforce\.com$/i, 'Use an authenticated Salesforce scratch org.');
    const org = await queryAll('SELECT Id FROM Organization LIMIT 1');
    assert.equal(org[0]?.Id?.slice(0, 15), plan.orgId.slice(0, 15), 'The authenticated org ID differs from this plan.');
    let jobs = await submissionReceipt();
    if (!jobs && action === 'submit') jobs = await submit(apexPath);
    assert.ok(jobs, 'The wave has no submission receipt. Run submit with this exact plan.');
    await saveJson('.jobs.json', {planDigest, jobs});
    let rows = await status(jobs);
    if (action === 'wait') {
      const stopAt = Date.now() + waitMinutes * 60_000;
      while (!rows.every(row => terminalStatuses.has(row.Status)) && Date.now() < stopAt) {
        await delay(pollSeconds * 1000);
        rows = await status(jobs);
      }
      assertSuccess(rows);
    }
    if (action === 'audit') await audit(rows);
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  connection?.agent.destroy();
}
