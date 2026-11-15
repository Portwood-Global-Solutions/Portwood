from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import time

_, directory, run_key, accounts, orgs, shards, alias_prefix = sys.argv
lab = Path(directory)
account_count, org_count, batch_shards = map(int, (accounts, orgs, shards))
browser_path = lab / 'artifacts' / f'portwood-salesforce-receipts-{account_count}-uninterrupted.json'
merged = lab / 'output' / f'portwood-cedar-waters-account-statements-{account_count}.pdf'
report_path = lab / 'artifacts' / f'portwood-cedar-waters-account-statements-{account_count}.json'
stage_names = {
    'sourcePrefetchWallMs': 'prefetch',
    'managedRenderWallMs': 'render',
    'fileSaveWallMs': 'savePrivateFiles',
}

def read_json(path):
    return json.loads(path.read_text())

def time_ms(iso):
    return round(datetime.fromisoformat(iso.replace('Z', '+00:00')).timestamp() * 1000)

def epoch_ms(path):
    return int(path.read_text()) * 1000

org_reports = []
for index in range(1, org_count + 1):
    alias = f'{alias_prefix}-{index:02d}'
    shard = lab / alias
    first, last = (index - 1) * account_count // org_count + 1, index * account_count // org_count
    count = last - first + 1
    wave = shard / f'{run_key}-{first:06d}-{last:06d}.audit.json'
    data, generated, exported = [read_json(path) for path in (shard / 'manifest.json', wave, shard / 'export.json')]
    assert (data['firstOrdinal'], data['lastOrdinal'], data['accountCount']) == (first, last, count)
    assert data['orgId'][:15] == generated['orgId'][:15]
    assert (generated['first'], generated['last'], generated['files']) == (first, last, count)
    assert (exported['firstOrdinal'], exported['lastOrdinal'], exported['files']) == (first, last, count)
    assert exported['targetOrg'] == alias
    assert exported['versionsVerifiedAgainstSalesforceChecksums'] == count
    assert exported['bytes'] == generated['totalBytes']
    assert len(generated['jobs']) == batch_shards
    assert all(row['Status'] == 'Completed' and not row['NumberOfErrors'] for row in generated['jobs'])
    assert all(item['apexCallouts'] == 0 for item in generated['metrics'])
    org_reports.append({
        'alias': alias,
        'orgId': data['orgId'],
        'firstOrdinal': first,
        'lastOrdinal': last,
        'accounts': data['accountCount'],
        'opportunities': data['opportunityCount'],
        'lineItems': data['opportunityLineItemCount'],
        'privatePdfs': generated['files'],
        'pdfBytes': generated['totalBytes'],
        'orgReadyAtMs': epoch_ms(shard / 'org-ready.epoch'),
        'setupReadyAtMs': epoch_ms(shard / 'setup-ready.epoch'),
        'seedReadyAtMs': epoch_ms(shard / 'seed-ready.epoch'),
        'firstBatchSubmittedAtMs': time_ms(generated['firstJobCreatedAt']),
        'lastBatchCompletedAtMs': time_ms(generated['lastJobCompletedAt']),
        'generationWallMs': generated['generationWallMs'],
        'downloadStartedAtMs': epoch_ms(shard / 'export-start.epoch'),
        'downloadCompletedAtMs': epoch_ms(shard / 'export-ready.epoch'),
        'downloadWallMs': exported['downloadWallMs'],
        'verifiedDownloadChecksums': exported['versionsVerifiedAgainstSalesforceChecksums'],
        'storageAfter': read_json(shard / 'storage-after.json'),
        'jobs': generated['jobs'],
        'scopeMetrics': generated['metrics'],
        'summedSalesforceStageMs': {stage: generated['summedScopeTimings'][key] for key, stage in stage_names.items()},
    })

browser = read_json(browser_path)
verification = read_json(lab / 'verified-content.json')
assert browser['sourceCount'] == account_count
assert browser['verifiedPageTexts'] == account_count
assert browser['bytes'] == merged.stat().st_size
with merged.open('rb') as stream:
    assert hashlib.file_digest(stream, 'sha256').hexdigest() == browser['sha256']
assert [verification[key] for key in ('verifiedAccounts', 'verifiedOpportunities', 'verifiedOpportunityLineItems')] == [account_count, account_count * 2, account_count * 4]
all_files_bytes = sum(org['pdfBytes'] for org in org_reports)
assert browser['requests']['initial']['bytes'] == all_files_bytes
browser['output'] = str(merged.relative_to(lab))

provision_started = epoch_ms(lab / 'run-start.epoch')
seeding_started = epoch_ms(lab / 'seed-start.epoch')
first_job = min(org['firstBatchSubmittedAtMs'] for org in org_reports)
last_job = max(org['lastBatchCompletedAtMs'] for org in org_reports)
all_downloaded = max(org['downloadCompletedAtMs'] for org in org_reports)
completed = round(time.time() * 1000)
timing = {
    'provisioningThroughLastOrgReadyMs': max(org['orgReadyAtMs'] for org in org_reports) - provision_started,
    'setupThroughLastTemplateReadyMs': max(org['setupReadyAtMs'] for org in org_reports) - provision_started,
    'seedingThroughLastCohortVerifiedMs': max(org['seedReadyAtMs'] for org in org_reports) - seeding_started,
    'salesforceGenerationFirstJobToLastJobMs': last_job - first_job,
    'slowestScratchOrgGenerationMs': max(org['generationWallMs'] for org in org_reports),
    'exportFirstTransferToLastTransferMs': all_downloaded - min(org['downloadStartedAtMs'] for org in org_reports),
    'browserMergeAndSaveMs': browser['timingMs']['downloaded'],
    'startFromProvisioningThroughFinalVerificationMs': completed - provision_started,
    'startFromFirstBatchThroughFinalVerificationMs': completed - first_job,
}
report = {
    'run': f'Portwood Cedar Waters {account_count:,} Account statements',
    'data': 'Synthetic records, two Opportunities per Account and two line items per Opportunity',
    'renderer': 'Portwood managed HTML generation backed by native Blob.toPdf()',
    'merger': 'Browser PDF writer, reading checksum verified Salesforce files via localhost',
    'scratchOrgs': len(org_reports),
    'sourcePdfBytes': all_files_bytes,
    'apexCallouts': 0,
    'timingMs': timing,
    'summedSalesforceStageMs': {
        stage: sum(org['summedSalesforceStageMs'][stage] for org in org_reports) for stage in stage_names.values()
    },
    'browser': browser,
    'mergedContentVerification': verification,
    'verifiedAt': datetime.fromtimestamp(completed / 1000, tz=timezone.utc).isoformat(),
    'orgs': org_reports,
}
report_path.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({key: value for key, value in report.items() if key != 'orgs'}, indent=2))
