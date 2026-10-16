"""Check actual PDF embedding and make review sheets; this does not approve registry rows."""
import json
from pathlib import Path
import pymupdf
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3] / 'font-stress'
ROWS = json.loads((ROOT / 'results.json').read_text())
OUT = ROOT / 'review'
OUT.mkdir(exist_ok=True)
LABEL = ImageFont.load_default(size=22)


def plain(s):
    return s.split('+', 1)[-1].replace(' ', '').replace('-', '').replace('_', '').lower()


tiles = []
for row in ROWS:
    if not row.get('proofFile'):
        continue
    pdf = pymupdf.open(row['proofFile'])
    meta = row['inspectedMetadata']
    expected = plain(meta['postscriptName'] or meta['family'])
    fonts = []
    matching = []
    for page in pdf:
        for f in page.get_fonts(full=True):
            fonts.append({'xref': f[0], 'type': f[2], 'name': f[3], 'encoding': f[5]})
            if plain(f[3]) == expected:
                info = pdf.extract_font(f[0])
                matching.append({'name': f[3], 'type': f[2], 'encoding': f[5], 'embeddedBytes': len(info[3])})
    row['nativeFonts'] = fonts
    row['embeddedMatch'] = bool(matching) and all(f['embeddedBytes'] > 0 and f['encoding'] == 'Identity-H' for f in matching)
    row['proofPages'] = len(pdf)
    row['proofBytes'] = Path(row['proofFile']).stat().st_size
    row['nativeCustomSpans'] = [span for page in pdf for block in page.get_text('dict')['blocks']
                               for line in block.get('lines', []) for span in line['spans']
                               if not span['font'].startswith('Times')]
    visible_ink = 0
    for span in row['nativeCustomSpans']:
        if not span['text'].strip():
            continue
        pix = pdf[0].get_pixmap(matrix=pymupdf.Matrix(2, 2), clip=pymupdf.Rect(span['bbox']), colorspace=pymupdf.csGRAY)
        visible_ink += sum(1 for pixel in pix.samples if pixel < 220)
    row['nativeSampleInkPixels'] = visible_ink
    title = row['id'] + ('  EMBEDDED' if row['embeddedMatch'] and visible_ink else '  CHECK FAILURE')
    tile = Image.new('RGB', (750, 360), 'white')
    draw = ImageDraw.Draw(tile)
    draw.text((10, 8), title, fill='#183452' if row['embeddedMatch'] else '#c00000', font=LABEL)
    draw.text((10, 35), str(meta['family'])[:50] + ' / ' + str(meta['subfamily'])[:24], fill='#444444', font=LABEL)
    pix = pdf[0].get_pixmap(matrix=pymupdf.Matrix(1.3, 1.3), clip=pymupdf.Rect(40, 48, 575, 240))
    image = Image.frombytes('RGB', (pix.width, pix.height), pix.samples)
    tile.paste(image, (10, 80))
    tiles.append(tile)
    pdf.close()

for offset in range(0, len(tiles), 16):
    sheet = Image.new('RGB', (3000, 1440), '#dce5eb')
    for i, tile in enumerate(tiles[offset:offset+16]):
        sheet.paste(tile, ((i % 4) * 750, (i // 4) * 360))
    sheet.save(OUT / ('sheet-' + str(offset // 16 + 1).zfill(2) + '.png'))

(ROOT / 'results.json').write_text(json.dumps(ROWS, indent=2, ensure_ascii=False))
tested = [r for r in ROWS if r.get('proofFile')]
print('Native PDF proofs:', len(tested), 'embedded matches:', sum(r['embeddedMatch'] for r in tested))
print('Failures:', [(r['id'], r['nativeFonts']) for r in tested if not r['embeddedMatch']])
print('Review sheets:', (len(tiles) + 15) // 16)
