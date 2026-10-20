"""Resumable scratch-only native font stress runner. Never prints or persists auth tokens.

Usage: python stress-native.py --target-org SCRATCH_ALIAS --phase import|proof|verify
Approval is a separate, explicit phase after native specimens have been inspected locally.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3] / 'font-stress'
STATE = ROOT / 'results.json'


def literal(s):
    return "'" + str(s).replace('\\', '\\\\').replace("'", "\\'").replace('\r', '\\r').replace('\n', '\\n') + "'"


class Salesforce:
    def __init__(self, alias):
        worker = Path(__file__).with_name('stress-sf-worker.mjs')
        expected = os.environ.get('PORTWOOD_QA_ORG_ID')
        if not expected:
            raise RuntimeError('Set PORTWOOD_QA_ORG_ID to the explicitly authorized development org Id.')
        self.process = subprocess.Popen(['node', str(worker), alias, expected], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        org = self.query('SELECT Id,IsSandbox FROM Organization LIMIT 1')[0]
        if org['Id'][:15] != expected[:15] or not org['IsSandbox']:
            raise RuntimeError('The target must match PORTWOOD_QA_ORG_ID and be a development org.')

    def rpc(self, payload):
        self.process.stdin.write(json.dumps(payload) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('Salesforce worker stopped: ' + self.process.stderr.read()[-1500:])
        result = json.loads(line)
        if not result['ok']:
            raise RuntimeError(result['error'])
        return result['result']

    def request(self, path, body=None, method=None):
        payload = {'op': 'request', 'path': path}
        if body is not None:
            payload['body'] = body
        if method:
            payload['method'] = method
        return self.rpc(payload)

    def query(self, soql):
        return self.request('/services/data/v67.0/query/?q=' + urllib.parse.quote(soql))['records']

    def apex(self, source):
        result = self.rpc({'op': 'apex', 'source': source})
        if not result.get('success'):
            raise RuntimeError(result.get('exceptionMessage') or result.get('compileProblem') or 'Anonymous Apex failed')
        match = re.search(r'\|DEBUG\|STRESS_RESULT:(.*)', result.get('logs', ''))
        return json.loads(match.group(1)) if match else None

    def download(self, cv, target):
        target.parent.mkdir(parents=True, exist_ok=True)
        result = self.rpc({'op': 'download', 'path': '/services/data/v67.0/sobjects/ContentVersion/' + cv + '/VersionData'})
        target.write_bytes(base64.b64decode(result['base64']))


def save(rows):
    STATE.write_text(json.dumps(rows, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--target-org', required=True)
    parser.add_argument('--phase', choices=['ping', 'import', 'proof', 'verify'], required=True)
    args = parser.parse_args()
    sf = Salesforce(args.target_org)
    if args.phase == 'ping':
        print(sf.apex("System.debug('STRESS_RESULT:'+JSON.serialize(new Map<String,Object>{'org'=>UserInfo.getOrganizationId(),'permission'=>FeatureManagement.checkPermission('Manage_DocGen_Fonts')}));"))
        return
    rows = json.loads(STATE.read_text()) if STATE.exists() else json.loads((ROOT / 'corpus.json').read_text())
    if not STATE.exists() and (ROOT / 'edge-cases.json').exists():
        rows.extend(json.loads((ROOT / 'edge-cases.json').read_text()))
    if args.phase == 'import':
        pending_code = []
        pending_rows = []

        def flush_imports():
            if not pending_rows:
                return
            code = 'List<Object> out=new List<Object>();' + ''.join(pending_code) + "System.debug('STRESS_RESULT:'+JSON.serialize(out));"
            results = sf.apex(code)
            for row, result in zip(pending_rows, results, strict=True):
                if result.get('error'):
                    row['importStatus'], row['importError'] = 'Rejected', result['error']
                else:
                    row['importJob'], row['importStatus'] = result['job'], 'Queued'
                print(row['id'], row['importStatus'], row.get('importError', ''), flush=True)
            save(rows)
            pending_rows.clear()
            pending_code.clear()

        for i, row in enumerate(rows):
            if row.get('importStatus'):
                continue
            started = time.monotonic()
            if not row.get('sourceCv'):
                file = Path(row['file'])
                result = sf.request('/services/data/v67.0/sobjects/ContentVersion', {
                    'Title': 'QA font stress ' + row['id'], 'PathOnClient': file.name,
                    'VersionData': base64.b64encode(file.read_bytes()).decode()}, 'POST')
                row['sourceCv'] = result['id']
                save(rows)
            license_text = Path(row['license']).read_text()
            license_hash = hashlib.sha256(license_text.encode()).hexdigest()
            row['revision'] = hashlib.sha256((row['sha256'] + ':' + license_hash).encode()).hexdigest()
            row['assetKey'] = 'qa-stress-' + hashlib.sha256(row['id'].encode()).hexdigest()[:16]
            code = 'try { ContentVersion cv=[SELECT ContentDocumentId FROM ContentVersion WHERE Id=' + literal(row['sourceCv']) + ' LIMIT 1];'
            code += "out.add(new Map<String,Object>{'job'=>DocGenFontController.importUploadedFont(cv.ContentDocumentId," + literal(row['assetKey']) + ',' + literal(license_text) + ",true)});} catch(Exception e){out.add(new Map<String,Object>{'error'=>e.getMessage()});}"
            if pending_rows and sum(map(len, pending_code)) + len(code) > 16000:
                flush_imports()
            pending_rows.append(row)
            pending_code.append(code)
            row['uploadAndQueueSeconds'] = round(time.monotonic() - started, 2)
            save(rows)
            print(i + 1, '/', len(rows), 'Uploaded', row['id'], row['bytes'], flush=True)
            if len(pending_rows) >= 3:
                flush_imports()
        flush_imports()
    if args.phase in ['import', 'proof']:
        job_field = 'importJob' if args.phase == 'import' else 'proofJob'
        status_field = 'importStatus' if args.phase == 'import' else 'proofStatus'
        error_field = 'importError' if args.phase == 'import' else 'proofError'
        if args.phase == 'proof':
            ready = [r for r in rows if r.get('importStatus') == 'Completed' and not r.get('proofStatus')]
            for at in range(0, len(ready), 8):
                batch = ready[at:at + 8]
                source = 'List<Object> out=new List<Object>();'
                for row in batch:
                    source += 'out.add(DocGenFontController.startFontProof(' + literal(row['revision']) + '));'
                result = sf.apex(source + "System.debug('STRESS_RESULT:'+JSON.serialize(out));")
                for row, job in zip(batch, result, strict=True):
                    row['proofJob'], row['proofStatus'] = job, 'Queued'
                    print('Proof queued', row['id'], flush=True)
                save(rows)
        for attempt in range(180):
            pending = [r for r in rows if r.get(status_field) == 'Queued']
            if not pending:
                break
            jobs = sf.query('SELECT Id,Status,ExtendedStatus,CreatedDate,CompletedDate FROM AsyncApexJob WHERE Id IN (' + ','.join(literal(r[job_field]) for r in pending) + ')')
            by_id = {j['Id']: j for j in jobs}
            for row in pending:
                job = by_id[row[job_field]]
                if job['Status'] in ['Completed', 'Failed', 'Aborted']:
                    row[status_field] = job['Status']
                    row[error_field] = job.get('ExtendedStatus')
                    row[args.phase + 'Created'] = job.get('CreatedDate')
                    row[args.phase + 'Completed'] = job.get('CompletedDate')
                    print(args.phase, row['id'], row[status_field], row.get(error_field) or '', flush=True)
            save(rows)
            if any(r.get(status_field) == 'Queued' for r in rows):
                time.sleep(2)
        if args.phase == 'proof':
            faces = {f['Revision_Key__c']: f for f in sf.query('SELECT Id,Revision_Key__c,Proof_CV_Id__c,Metadata_JSON__c,Asset__r.Asset_Key__c,Source_CV_Id__c,Status__c FROM DocGen_Font_Face__c')}
            for row in rows:
                if row.get('proofStatus') != 'Completed':
                    continue
                face = faces[row['revision']]
                if row.get('proofCv') == face['Proof_CV_Id__c'] and row.get('proofFile') and Path(row['proofFile']).exists():
                    continue
                row['faceId'], row['proofCv'] = face['Id'], face['Proof_CV_Id__c']
                row['assetKey'] = face['Asset__r']['Asset_Key__c']
                row['registeredSourceCv'] = face['Source_CV_Id__c']
                row['alreadyVerified'] = face['Status__c'] == 'Verified'
                row['inspectedMetadata'] = json.loads(face['Metadata_JSON__c'])
                row['inspectedMetadata'].pop('licenseText', None)
                row['proofFile'] = str(ROOT / 'proofs' / (row['id'] + '.pdf'))
                sf.download(row['proofCv'], Path(row['proofFile']))
                save(rows)
                print('Downloaded proof', row['id'], flush=True)
    if args.phase == 'verify':
        reviewed = json.loads((ROOT / 'reviewed.json').read_text())
        unique = {}
        for row in rows:
            if row['id'] in reviewed and not row.get('verified'):
                unique.setdefault(row['revision'], row)
        ready = list(unique.values())
        for at in range(0, len(ready), 8):
            batch = ready[at:at + 8]
            code = ''
            for row in batch:
                if not row.get('alreadyVerified'):
                    code += 'DocGenFontController.verifyFont(' + literal(row['revision']) + ',' + literal(row['proofCv']) + ',true);'
            if code:
                sf.apex(code)
            keys = {r['revision'] for r in batch}
            for row in rows:
                if row.get('revision') in keys:
                    row['verified'] = True
                    print('Approved reviewed QA font', row['id'], flush=True)
            save(rows)


if __name__ == '__main__':
    main()
