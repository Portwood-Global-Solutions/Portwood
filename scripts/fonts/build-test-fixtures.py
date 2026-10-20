"""Regenerate renamed OFL subsets for Apex tests. Requires fonttools; never changes demo sources."""
from pathlib import Path
from io import BytesIO
import base64
from fontTools.ttLib import TTFont
from fontTools import subset

ROOT = Path(__file__).resolve().parents[2]
CLASSES = ROOT / 'force-app/main/default/classes'
parts = [
    '/** Renamed test-only subsets of OFL Parisienne and Barlow. Original copyright and licenses are retained below. */',
    '@IsTest',
    'public class DocGenFontTestData {'
]
for filename, method, family, postscript in [
    ('Parisienne-Regular.ttf', 'regular', 'Portwood Test Script', 'PortwoodTestScript-Regular'),
    ('Barlow-Bold.ttf', 'bold', 'Portwood Test Sans', 'PortwoodTestSans-Bold')
]:
    source = next((ROOT / 'scripts/fonts/fixtures').rglob(filename))
    font = TTFont(source)
    options = subset.Options()
    options.name_IDs = ['*']
    options.name_legacy = True
    options.name_languages = ['*']
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=list(range(32, 127)) + [350, 351])
    subsetter.subset(font)
    # Reserved font names remain in copyright/license notices, never in the derivative family.
    for name in font['name'].names:
        if name.nameID in [1, 4, 6, 16]:
            value = postscript if name.nameID == 6 else family
            name.string = value.encode(name.getEncoding())
    buffer = BytesIO()
    font.save(buffer)
    encoded = base64.b64encode(buffer.getvalue()).decode('ascii')
    chunks = ' +\n'.join("'" + encoded[i:i + 12000] + "'" for i in range(0, len(encoded), 12000))
    parts.append('    public static Blob ' + method + '() { return EncodingUtil.base64Decode(' + chunks + '); }')
    license_text = '\n'.join(line.rstrip() for line in (source.parent / 'LICENSE.txt').read_text().splitlines()).replace('*/', '* /')
    parts.append('/*\n' + license_text + '\n*/')
parts.append('}')
(CLASSES / 'DocGenFontTestData.cls').write_text('\n'.join(parts) + '\n')
print('Regenerated DocGenFontTestData.cls. Run Prettier and DocGenFontTest before deploying.')
