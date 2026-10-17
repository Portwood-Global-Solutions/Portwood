"""Verify fonts in full merged documents and render compact review sheets."""
import json
from pathlib import Path
import pymupdf
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3] / 'font-stress'
rows = {r['id']: r for r in json.loads((ROOT / 'results.json').read_text())}
groups = json.loads((ROOT / 'templates.json').read_text())
out = ROOT / 'document-review'
out.mkdir(exist_ok=True)
label = ImageFont.load_default(size=24)
tiles = []


def plain(s):
    return s.split('+', 1)[-1].replace(' ', '').replace('-', '').replace('_', '').lower()


for group in groups:
    if not group.get('file'):
        continue
    pdf = pymupdf.open(group['file'])
    fonts = {plain(font[3]) for page in pdf for font in page.get_fonts(full=True)}
    group['missingEmbeddedFaces'] = []
    for face in group['faces']:
        row = rows[face]
        expected = plain(row['inspectedMetadata']['postscriptName'])
        row['mergedPdfEmbedded'] = expected in fonts
        row['mergedPdfGroup'] = group['group']
        if expected not in fonts:
            group['missingEmbeddedFaces'].append(face)
    group['pages'] = len(pdf)
    group['liveAccountPresent'] = 'Font Stress QA - Fictional' in '\n'.join(p.get_text() for p in pdf)
    assert not group['missingEmbeddedFaces'], group
    assert group['liveAccountPresent'], group
    for i, page in enumerate(pdf):
        pix = page.get_pixmap(matrix=pymupdf.Matrix(1.1, 1.1))
        full = Image.frombytes('RGB', (pix.width, pix.height), pix.samples)
        full.save(out / ('group-' + str(group['group']).zfill(2) + '-page-' + str(i + 1) + '.png'))
        full.thumbnail((660, 860))
        tile = Image.new('RGB', (680, 920), 'white')
        ImageDraw.Draw(tile).text((10, 5), 'Group ' + str(group['group']) + ' / page ' + str(i + 1), fill='#183452', font=label)
        tile.paste(full, (10, 45))
        tiles.append(tile)
    pdf.close()

for offset in range(0, len(tiles), 4):
    sheet = Image.new('RGB', (1360, 1840), '#dce5eb')
    for i, tile in enumerate(tiles[offset:offset + 4]):
        sheet.paste(tile, ((i % 2) * 680, (i // 2) * 920))
    sheet.save(out / ('sheet-' + str(offset // 4 + 1).zfill(2) + '.png'))
(ROOT / 'templates.json').write_text(json.dumps(groups, indent=2))
(ROOT / 'results.json').write_text(json.dumps(list(rows.values()), indent=2, ensure_ascii=False))
print('Full merged documents:', len(groups), 'pages:', len(tiles), 'faces embedded:', sum(r.get('mergedPdfEmbedded', False) for r in rows.values()))
print('Review sheets:', (len(tiles) + 3) // 4)
