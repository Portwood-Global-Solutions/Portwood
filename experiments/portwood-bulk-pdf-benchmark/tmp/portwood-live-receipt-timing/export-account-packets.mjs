import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { request } from 'node:https';
import { dirname, join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { parseArgs } from 'node:util';
import { downloadPart, salesforceConnection, streamAudit } from '../../scripts/lib/salesforce-pdf-transport.mjs';

const { positionals: [runSlug, rawCount, outputPath], values } = parseArgs({
  args: process.argv.slice(2), allowPositionals: true,
  options: {
    'target-org': { type: 'string' }, 'org-id': { type: 'string' },
    first: { type: 'string', default: '1' },
    workers: { type: 'string', default: '16' },
    stats: { type: 'string' },
  },
});
const count = Number(rawCount);
const firstOrdinal = Number(values.first);
const lastOrdinal = firstOrdinal + count - 1;
const targetOrg = values['target-org'];
assert.match(runSlug, /^[a-zA-Z0-9-]{1,60}$/);
assert.ok(Number.isInteger(firstOrdinal) && firstOrdinal >= 1);
assert.ok(Number.isInteger(count) && count > 0 && lastOrdinal <= 100000 && outputPath);
assert.match(targetOrg, /^[A-Za-z0-9][A-Za-z0-9-]+$/);
const expectedOrgId = values['org-id'];
assert.match(expectedOrgId, /^00D[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/);
const workersRequested = Number(values.workers);
assert.ok(Number.isInteger(workersRequested) && workersRequested > 0 && workersRequested <= 24);
const parallelRequests = Math.min(workersRequested, count);
const transportPath = values.stats ?? join(outputPath, 'transport.json');
const titlePrefix = runSlug + '-';
const numberFor = index => String(firstOrdinal + index).padStart(6, '0');
const connection = await salesforceConnection(targetOrg, {
  keepAlive: true, maxSockets: parallelRequests,
});
assert.ok(connection.origin.hostname.endsWith('.scratch.my.salesforce.com'));

function getJson(path) {
  return new Promise((resolve, reject) => {
    const req = request(new URL(path, connection.origin), {
      agent: connection.agent,
      headers: { Authorization: 'Bearer ' + connection.accessToken },
      signal: AbortSignal.timeout(20_000),
    }, async response => {
      try {
        assert.equal(response.statusCode, 200, 'Salesforce query request failed.');
        const chunks = [];
        for await (const block of response) chunks.push(block);
        resolve(JSON.parse(Buffer.concat(chunks).toString()));
      } catch (error) {
        reject(error);
      }
    });
    req.on('error', reject);
    req.end();
  });
}

async function exportStatement(row, path) {
  const saved = await readFile(path).catch(error => {
    if (error.code !== 'ENOENT') throw error;
    return null;
  });
  if (saved?.length === row.ContentSize && createHash('md5').update(saved).digest('hex') === row.Checksum.toLowerCase()) {
    return false;
  }
  const partial = path + '.partial';
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const source = await downloadPart(connection, row.Id, AbortSignal.timeout(30_000));
      const audit = streamAudit(row.ContentSize, 'md5', row.Checksum.toLowerCase());
      await pipeline(source, audit.stream, createWriteStream(partial, { mode: 0o600 }));
      await rename(partial, path);
      return true;
    } catch (error) {
      await rm(partial, { force: true });
      if (attempt === 5) throw new Error('Failed to export ' + row.Title, { cause: error });
      await delay(attempt * 750);
    }
  }
}

try {
  const org = await getJson('/services/data/v68.0/query?q=' + encodeURIComponent('SELECT Id FROM Organization LIMIT 1'));
  assert.equal(org.records[0]?.Id?.slice(0, 15), expectedOrgId.slice(0, 15), 'The authenticated scratch org differs from the requested org.');
  const downloadStart = performance.now();
  const query = `SELECT Id, Title, ContentSize, Checksum, FileType, SharingPrivacy, OwnerId, FirstPublishLocationId
      FROM ContentVersion WHERE IsLatest = true AND Title LIKE '${titlePrefix}%'
      AND Title >= '${titlePrefix + numberFor(0)}' AND Title <= '${titlePrefix + numberFor(count - 1)}'
      ORDER BY Title ASC`;
  let path = '/services/data/v68.0/query?q=' + encodeURIComponent(query);
  const versions = [];
  while (path) {
    const result = await getJson(path);
    versions.push(...result.records);
    path = result.nextRecordsUrl;
  }
  const queryWallMs = Math.round(performance.now() - downloadStart);
  assert.equal(versions.length, count, 'Missing or duplicated statement Files.');
  versions.forEach((row, index) => {
    assert.equal(row.Title, titlePrefix + numberFor(index));
    assert.equal(row.FileType, 'PDF');
    assert.equal(row.SharingPrivacy, 'P');
    assert.ok(!row.FirstPublishLocationId || row.FirstPublishLocationId === row.OwnerId, 'Expected a standalone private File');
    assert.match(row.Checksum, /^[a-f0-9]{32}$/i);
    assert.ok(row.ContentSize > 0);
  });
  await mkdir(outputPath, {recursive: true});
  const downloadStarted = performance.now();
  let next = 0;
  let reusedLocalFiles = 0;
  let stillDownloading = true;
  const workers = await Promise.allSettled(Array.from({ length: parallelRequests }, async () => {
    while (stillDownloading && next < versions.length) {
      const index = next++;
      const row = versions[index];
      const path = join(outputPath, numberFor(index) + '.pdf');
      try {
        if (!(await exportStatement(row, path))) reusedLocalFiles++;
      } catch (error) {
        stillDownloading = false;
        throw error;
      }
    }
  }));
  const failed = workers.find(worker => worker.status === 'rejected');
  if (failed) throw failed.reason;
  const report = {
    targetOrg, firstOrdinal, lastOrdinal, files: count, queryWallMs,
    downloadWallMs: Math.round(performance.now() - downloadStarted), parallelRequests, reusedLocalFiles,
    bytes: versions.reduce((sum, row) => sum + row.ContentSize, 0),
    versionsVerifiedAgainstSalesforceChecksums: count,
  };
  await mkdir(dirname(transportPath), {recursive: true});
  await writeFile(transportPath, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report));
} finally {
  connection.agent.destroy();
}
