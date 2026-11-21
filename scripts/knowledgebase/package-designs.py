#!/usr/bin/env python3
"""Rebuild or verify the two downloadable guide projects with only the Python standard library."""
import argparse
from io import BytesIO
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

examples = Path(__file__).resolve().parents[2] / 'docs/knowledgebase/examples'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='verify the checked-in archives')
options = parser.parse_args()

for name in ['document-studio', 'event-signing']:
    source = examples / name
    archive = examples / (name + '.zip')
    buffer = BytesIO()
    with ZipFile(buffer, 'w', compression=ZIP_DEFLATED) as output:
        for file in sorted(source.rglob('*')):
            if not file.is_file() or any(part.startswith('.') for part in file.relative_to(source).parts):
                continue
            info = ZipInfo(file.relative_to(examples).as_posix(), (2020, 1, 1, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            info.compress_type = ZIP_DEFLATED
            output.writestr(info, file.read_bytes())
    if options.check:
        # Different supported zlib builds can compress identical inputs to different bytes.
        with ZipFile(buffer) as generated, ZipFile(archive) as saved:
            if generated.namelist() != saved.namelist() or any(
                generated.read(member) != saved.read(member) for member in generated.namelist()
            ):
                raise SystemExit(f'{archive.name} is stale. Run package-designs.py.')
    else:
        archive.write_bytes(buffer.getvalue())
    print(f"{'Verified' if options.check else 'Wrote'} {archive.name}")
