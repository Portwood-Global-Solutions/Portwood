"""Scratch-only native Apex capacity probe. Requires the PDF QA Python venv.

Auth is read from a gitignored `sf org display --verbose --json` result, never
printed. All documents stay in the explicitly selected scratch org.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor, as_completed
from functools import lru_cache
import hashlib
import io
import json
from pathlib import Path
import random
import re
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
import zlib
import uuid

import pikepdf
from pypdf import PdfReader, PdfWriter
from pypdf.generic import (
    DictionaryObject, EncodedStreamObject, NameObject, NumberObject,
)
from reportlab.pdfgen import canvas

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.tmp/pdf-merge/stress'
AUTH = json.loads((WORK / 'auth.json').read_text())['result'] if (WORK / 'auth.json').exists() else {}
BASE = AUTH.get('instanceUrl', '')
TOKEN = AUTH.get('accessToken', '')
API = '/services/data/v66.0'


def api(path, body=None, raw=False, attempt=0):
    assert TOKEN and 'REDACTED' not in TOKEN, 'Obtain an explicit, private CLI auth export first'
    assert AUTH.get('expirationDate') and AUTH.get('devHubId'), 'This probe requires a scratch org'
    request = Request(BASE + path, data=None if body is None else json.dumps(body).encode(),
                      headers={'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json'})
    try:
        with urlopen(request, timeout=180) as response:
            data = response.read()
            return data if raw else json.loads(data or 'null')
    except HTTPError as error:
        data = error.read().decode()
        try:
            detail = json.loads(data)
        except ValueError:
            detail = data[:2000]
        return {'httpError': error.code, 'detail': detail}
    except URLError:
        if body is not None or attempt >= 4:
            raise
        time.sleep(min(2 ** attempt, 8))
        return api(path, raw=raw, attempt=attempt + 1)


def query(soql):
    return api(API + '/query?' + urlencode({'q': soql}))['records']


def upload(name, path):
    result = api(API + '/sobjects/ContentVersion', {
        'Title': 'PDF stress source ' + name, 'PathOnClient': name + '.pdf',
        'VersionData': base64.b64encode(path.read_bytes()).decode(),
    })
    assert result.get('success'), result
    return result['id']


def text_pdf(path, label, pages=1, modern=False):
    data = io.BytesIO()
    c = canvas.Canvas(data, pagesize=(400, 500), pageCompression=1, invariant=True)
    for page in range(pages):
        c.setFont('Helvetica', 14)
        c.drawString(30, 450, f'STRESS {label} PAGE {page + 1}')
        c.setFont('Helvetica', 10)
        for row in range(12):
            c.drawString(30, 420 - row * 20, f'Native Apex PDF capacity test - row {row + 1}')
        c.showPage()
    c.save()
    if modern:
        with pikepdf.open(io.BytesIO(data.getvalue())) as doc:
            doc.save(path, object_stream_mode=pikepdf.ObjectStreamMode.generate)
    else:
        path.write_bytes(data.getvalue())


def image_pdf(path, target, label):
    # A real, incompressible grayscale image, not trailing padding or an unused stream.
    text_pdf(path, label)
    source = PdfReader(path)
    writer = PdfWriter()
    page = writer.add_page(source.pages[0])
    width = 256
    height = max(1, (target - 2000) // width)
    pixels = random.Random(target).randbytes(width * height)
    image = EncodedStreamObject()
    image._data = zlib.compress(pixels)
    image.update({NameObject('/Type'): NameObject('/XObject'),
                  NameObject('/Subtype'): NameObject('/Image'),
                  NameObject('/Width'): NumberObject(width),
                  NameObject('/Height'): NumberObject(height),
                  NameObject('/ColorSpace'): NameObject('/DeviceGray'),
                  NameObject('/BitsPerComponent'): NumberObject(8),
                  NameObject('/Filter'): NameObject('/FlateDecode')})
    resources = page['/Resources']
    resources[NameObject('/XObject')] = DictionaryObject({NameObject('/Scan'): writer._add_object(image)})
    content = page['/Contents'].get_object()
    drawing = b'\nq 280 0 0 120 30 30 cm /Scan Do Q\n'
    from pypdf.generic import DecodedStreamObject
    stream = DecodedStreamObject()
    stream.set_data(content.get_data() + drawing)
    page[NameObject('/Contents')] = writer._add_object(stream)
    writer.write(path)


def generate():
    WORK.mkdir(parents=True, exist_ok=True)
    manifest_path = WORK / 'sources.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    specs = [(f'text-{i:03}', 'text', i) for i in range(1, 101)]
    specs += [(f'image-{k}k', 'image', k * 1024)
              for k in [16, 32, 64, 96, 128, 160, 192, 256, 320, 384, 512, 768, 1024, 1536, 2048, 2176, 2304, 2432, 2560, 3072, 4096, 5120, 6144, 8192]]
    specs += [(f'pages-{n}', 'pages', n) for n in [10, 25, 50, 100, 200, 400]]
    specs += [(f'modern-{n}', 'modern', n) for n in [1, 25, 100, 200]]
    specs += [('form', 'existing', 0)]
    specs += [(f'blank-modern-{n}', 'blank-modern', n) for n in [1000, 3000, 5000]]
    specs += [('modern-1000', 'modern', 1000)]
    specs += [(f'boundary-{n}', 'boundary', n) for n in [196608, 196609, 393216, 393217]]
    for name, family, value in specs:
        if name in manifest:
            continue
        path = WORK / (name + '.pdf')
        if family == 'image':
            image_pdf(path, value, name)
        elif family == 'boundary':
            image_pdf(path, value - 2048, name)
            padding = value - path.stat().st_size
            assert padding >= 3
            data = path.read_bytes()
            position = data.rfind(b'startxref')
            path.write_bytes(data[:position] + b'%' + b'P' * (padding - 2) + b'\n' + data[position:])
            assert path.stat().st_size == value
        elif family == 'blank-modern':
            writer = PdfWriter()
            for _ in range(value):
                writer.add_blank_page(width=400, height=500)
            data = io.BytesIO()
            writer.write(data)
            with pikepdf.open(io.BytesIO(data.getvalue())) as doc:
                doc.save(path, object_stream_mode=pikepdf.ObjectStreamMode.generate)
        elif family == 'existing':
            fixture_class = (ROOT / 'force-app/main/default/classes/DocGenPdfMergeFixtures.cls').read_text()
            encoded = re.search(r"Blob formAlpha\(\)\s*\{.*?base64Decode\(\s*'([^']+)'", fixture_class, re.S)
            assert encoded, 'Missing formAlpha test fixture'
            path.write_bytes(base64.b64decode(encoded[1]))
        else:
            text_pdf(path, name, value if family in ('pages', 'modern') else 1, family == 'modern')
        reader = PdfReader(path, strict=True)
        with pikepdf.open(path) as doc:
            assert not doc.check_pdf_syntax(), name
        entry = {'id': upload(name, path), 'bytes': path.stat().st_size,
                 'pages': len(reader.pages), 'path': str(path), 'family': family}
        manifest[name] = entry
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        print('SOURCE', name, entry['bytes'], entry['pages'], flush=True)
    return manifest


@lru_cache(maxsize=512)
def fingerprints(path):
    reader = PdfReader(path, strict=True)
    pages = []
    for page in reader.pages:
        images = []
        for ref in page.get('/Resources', {}).get('/XObject', {}).values():
            obj = ref.get_object()
            if obj.get('/Subtype') == '/Image':
                images.append(hashlib.sha256(obj.get_data()).hexdigest())
        pages.append({'text': re.sub(r'\s+', ' ', page.extract_text()).strip(), 'images': sorted(images)})
    with pikepdf.open(path) as doc:
        warnings = doc.check_pdf_syntax()
    return pages, warnings


def execute(case, manifest, recover=False):
    mode, path, names, count, pad = case
    label = f'{mode}-{path}-{names[0]}-{count}' + ('-distinct' if len(names) > 1 else '') + ('-pad' if pad else '')
    result_path = WORK / ('result-' + label + '.json')
    if result_path.exists():
        cached = json.loads(result_path.read_text())
        if not cached.get('verificationError') and cached.get('ids') == [manifest[n]['id'] for n in names]:
            return cached
    config = {'label': label + '-' + uuid.uuid4().hex[:8], 'mode': mode, 'path': path, 'ids': [manifest[n]['id'] for n in names],
              'count': count, 'pad': pad}
    started = time.monotonic()
    result = None
    if recover and mode == 'async':
        assert re.fullmatch(r'[A-Za-z0-9-]+', label)
        logs = query("SELECT Id, Title FROM ContentVersion WHERE Title LIKE 'PDF stress result " + label +
                     "%' AND IsLatest = true ORDER BY CreatedDate DESC LIMIT 10")
        for log in logs:
            remote_label = log['Title'].removeprefix('PDF stress result ')
            if remote_label == label or re.fullmatch(re.escape(label) + r'-[0-9a-f]{8}', remote_label):
                config['label'] = remote_label
                result = api('/services/apexrest/pdf-merge-stress/?' + urlencode({'label': remote_label}))
                result['recoveredServerResult'] = True
                break
    if result is None:
        result = api('/services/apexrest/pdf-merge-stress/', config)
    if 'jobId' in result:
        job_id = result['jobId']
        for _ in range(600):
            time.sleep(2)
            result = api('/services/apexrest/pdf-merge-stress/?' + urlencode({'label': config['label']}))
            if not result.get('pending'):
                break
        result['asyncJobId'] = job_id
    result.update(config)
    result['executionLabel'] = config['label']
    result['label'] = label
    result['inputBytes'] = sum(manifest[names[i % len(names)]]['bytes'] for i in range(count))
    result['expectedPages'] = sum(manifest[names[i % len(names)]]['pages'] +
                                  (manifest[names[i % len(names)]]['pages'] % 2 if pad else 0)
                                  for i in range(count))
    if result.get('success'):
        output = WORK / ('output-' + label + '.pdf')
        data = api(API + '/sobjects/ContentVersion/' + result['outputId'] + '/VersionData', raw=True)
        assert isinstance(data, bytes), data
        output.write_bytes(data)
        result['outputBytes'] = len(data)
        try:
            actual, warnings = fingerprints(output)
            expected = []
            for i in range(count):
                source_pages, source_warnings = fingerprints(Path(manifest[names[i % len(names)]]['path']))
                assert not source_warnings, source_warnings
                expected.extend(source_pages)
                if pad and len(source_pages) % 2:
                    expected.append({'text': '', 'images': []})
            result['verifiedPages'] = len(actual)
            result['contentVerified'] = actual == expected
            result['syntaxWarnings'] = warnings
            assert actual == expected, 'Page text, image hashes, or order differ'
            assert not warnings, warnings
        except Exception as error:
            result['verificationError'] = repr(error)
    result['clientSeconds'] = round(time.monotonic() - started, 2)
    result_path.write_text(json.dumps(result, indent=2) + '\n')
    print('RESULT', label, json.dumps({k: result.get(k) for k in
          ['success', 'inputBytes', 'outputBytes', 'cpuMs', 'heapLimit', 'cpuLimit', 'error', 'httpError',
           'detail', 'verifiedPages', 'verificationError']}), flush=True)
    return result


def cases(phase):
    plans = []
    def add(mode, path, name, count, pad=False):
        plans.append((mode, path, name if isinstance(name, list) else [name], count, pad))
    if phase == 'baseline':
        for mode in ['sync', 'async']:
            for n in [2, 10, 25, 50, 75, 100, 101]:
                add(mode, 'action', [f'text-{i:03}' for i in range(1, min(n, 100) + 1)], n)
            for k in [64, 128, 192, 256, 384, 512]:
                add(mode, 'action', f'image-{k}k', 2)
            for n in [25, 100, 200]:
                add(mode, 'action', f'modern-{n}', 2)
            add(mode, 'action', 'form', 25)
            add(mode, 'action', 'text-001', 50, True)
    elif phase == 'engine':
        for mode in ['sync', 'async']:
            for n in ([100, 150, 250, 400, 750] if mode == 'sync' else [100, 150, 250, 400, 750, 1000, 1500]):
                add(mode, 'engine', [f'text-{i:03}' for i in range(1, 101)], n)
            for k in [192, 256, 384, 512, 768, 1024, 1536, 2048]:
                add(mode, 'engine', f'image-{k}k', 2)
            for n in [100, 200, 400]:
                add(mode, 'engine', f'pages-{n}', 2)
    elif phase == 'fine':
        for mode, size in [('sync', 196608), ('async', 393216)]:
            add(mode, 'action', f'boundary-{size}', 2)
            add(mode, 'action', [f'boundary-{size}', f'boundary-{size + 1}'], 2)
        for mode in ['sync', 'async']:
            # Distinct scanned/image PDFs at the same aggregate size scale.
            for k in [128, 256, 512, 1024]:
                add(mode, 'engine', [f'image-{k}k', f'image-{k // 2}k'], 2)
    elif phase == 'extreme':
        for n in [1000, 1250]:
            add('sync', 'engine', [f'text-{i:03}' for i in range(1, 101)], n)
        for n in [2500, 4000, 5000]:
            add('async', 'engine', [f'text-{i:03}' for i in range(1, 101)], n)
        for mode in ['sync', 'async']:
            for k in [2560, 3072, 4096, 6144, 8192]:
                add(mode, 'engine', f'image-{k}k', 2)
    elif phase == 'complex':
        for mode in ['sync', 'async']:
            for n in [1000, 3000, 5000]:
                add(mode, 'action', f'blank-modern-{n}', 2)
            add(mode, 'action', 'modern-1000', 2)
    elif phase == 'shape':
        for k in [2176, 2304, 2432]:
            add('sync', 'engine', f'image-{k}k', 2)
        add('async', 'engine', 'image-5120k', 2)
        for mode in ['sync', 'async']:
            for k in [2048, 2560, 4096, 6144]:
                add(mode, 'engine', [f'image-{k}k', 'text-001'], 2)
            for n in ([20, 40, 60] if mode == 'sync' else [40, 80, 100]):
                add(mode, 'engine', 'image-128k', n)
    return plans


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['generate', 'baseline', 'engine', 'fine', 'extreme', 'complex', 'shape', 'summarize'])
    parser.add_argument('--workers', type=int, default=3)
    parser.add_argument('--recover', action='store_true', help='Recover completed async results after interrupted polling')
    args = parser.parse_args()
    if args.phase == 'generate':
        generate()
        return
    manifest = json.loads((WORK / 'sources.json').read_text())
    if args.phase != 'summarize':
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = [pool.submit(execute, case, manifest, args.recover) for case in cases(args.phase)]
            for future in as_completed(futures):
                future.result()
    results = [json.loads(path.read_text()) for path in sorted(WORK.glob('result-*.json'))]
    (WORK / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    for result in results:
        error = result.get('error') or result.get('detail') or result.get('verificationError')
        print(result['label'], result.get('success', False), result['inputBytes'], result.get('cpuMs'), str(error)[:160])


if __name__ == '__main__':
    main()
