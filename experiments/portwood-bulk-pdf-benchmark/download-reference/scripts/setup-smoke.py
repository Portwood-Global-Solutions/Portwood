#!/usr/bin/env python3
"""Generate a synthetic PDF and optionally stage it in an authorized scratch org."""

import argparse
from base64 import b64encode
from contextlib import closing
from hashlib import sha256
from http.client import HTTPSConnection
import json
from pathlib import Path
import re
from urllib.parse import urlsplit
from uuid import uuid4

from org_auth import org_auth


PAGES = 6
CHUNK_BYTES = 262144
VERSION_ID = re.compile(r'068[A-Za-z0-9]{15}')
CONTENT_VERSION = '/services/data/v68.0/sobjects/ContentVersion'


def fixture_pdf():
    contents = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        f'<< /Type /Pages /Count {PAGES} /Kids [{" ".join(f"{4 + 2 * i} 0 R" for i in range(PAGES))}] >>'.encode(),
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ]
    for page in range(1, PAGES + 1):
        page_object = len(contents) + 1
        stream_object = page_object + 1
        contents.append((f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
                         f'/Resources << /Font << /F1 3 0 R >> >> /Contents {stream_object} 0 R >>').encode())
        stream = (f'0.15 0.36 0.27 rg 54 690 504 4 re f\n'
                  f'BT /F1 19 Tf 54 712 Td (Portwood synthetic download sample) Tj ET\n'
                  f'BT /F1 11 Tf 54 663 Td (Page {page} of {PAGES} - sample, not issued) Tj ET\n').encode()
        stream += (f'% Synthetic checkpoint padding for page {page:02d}; contains no record data.\n'.encode()) * 12500
        contents.append(f'<< /Length {len(stream)} >>\nstream\n'.encode() + stream + b'endstream')

    pdf = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offsets = []
    for number, content in enumerate(contents, 1):
        offsets.append(len(pdf))
        pdf.extend(f'{number} 0 obj\n'.encode() + content + b'\nendobj\n')
    xref = len(pdf)
    pdf.extend(f'xref\n0 {len(offsets) + 1}\n0000000000 65535 f \n'.encode())
    for offset in offsets:
        pdf.extend(f'{offset:010d} 00000 n \n'.encode())
    pdf.extend(f'trailer\n<< /Size {len(offsets) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    return bytes(pdf)


def insert_file(connection, token, title, description, file_name, body):
    data = json.dumps({
        'Title': title, 'Description': description, 'PathOnClient': file_name,
        'SharingPrivacy': 'P', 'VersionData': b64encode(body).decode('ascii'),
    }).encode()
    connection.request('POST', CONTENT_VERSION, data, {'Authorization': 'Bearer ' + token,
                                                       'Content-Type': 'application/json'})
    response = connection.getresponse()
    response_body = response.read()
    if response.status != 201:
        raise RuntimeError(f'Scratch ContentVersion insert returned HTTP {response.status} for {file_name}.')
    result = json.loads(response_body)
    version_id = result.get('id')
    if result.get('success') is not True or not VERSION_ID.fullmatch(version_id or ''):
        raise RuntimeError(f'Scratch ContentVersion insert returned an invalid response for {file_name}.')
    return version_id


def stage(alias, pdf):
    base, token = org_auth(alias)
    run_key = uuid4().hex
    title = f'PW Download Smoke {run_key}'
    chunks = []
    with closing(HTTPSConnection(urlsplit(base).netloc, timeout=30)) as connection:
        for ordinal, start in enumerate(range(0, len(pdf), CHUNK_BYTES), 1):
            payload = pdf[start:start + CHUNK_BYTES]
            name = f'chunk-{ordinal:03d}'
            version_id = insert_file(connection, token, f'{title} {name}', 'Portwood PDF Append Chunk v1',
                                     f'{name}.part', payload)
            chunks.append({'versionId': version_id, 'size': len(payload)})
        manifest = json.dumps({'runKey': run_key, 'sourceCount': 1, 'pages': PAGES,
                               'totalBytes': len(pdf), 'chunks': chunks}).encode()
        version_id = insert_file(connection, token, f'{title} manifest', 'Portwood PDF Range Manifest v1',
                                 'manifest.json', manifest)
    return {'manifestId': version_id, 'browserUrl': f'{base}/apex/PortwoodPdfDownload?id={version_id}',
            'chunkCount': len(chunks), 'titlePrefix': title}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--org', help='Existing scratch alias. Omit for offline generation only.')
    parser.add_argument('--output', type=Path, default=Path('scratch-output/fixture.pdf'))
    args = parser.parse_args()
    try:
        pdf = fixture_pdf()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(pdf)
        result = {'pages': PAGES, 'bytes': len(pdf), 'sha256': sha256(pdf).hexdigest()}
        if args.org:
            result.update(stage(args.org, pdf))
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f'{error}\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
