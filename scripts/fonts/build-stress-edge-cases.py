"""Create explicit QA negatives and size boundaries from licensed fonts; never publish as customer fonts."""
import hashlib
import json
import urllib.parse
import urllib.request
from pathlib import Path
from fontTools.ttLib import TTFont, TTCollection, newTable

ROOT = Path(__file__).resolve().parents[3] / 'font-stress'
OUT = ROOT / 'edge-cases'
OUT.mkdir(exist_ok=True)
CORPUS = json.loads((ROOT / 'corpus.json').read_text())
BASE = next(r for r in CORPUS if r['id'] == 'abel')
RESULTS = []


def record(name, path, expectation='reject', source=None, license_path=None):
    data = path.read_bytes()
    RESULTS.append({'id': 'edge-' + name, 'familySlug': 'qa-edge', 'file': str(path),
        'license': license_path or BASE['license'], 'kind': 'edge-fixture', 'expected': expectation,
        'sourcePath': source or BASE['sourcePath'], 'sourceCommit': BASE['sourceCommit'],
        'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})


def renamed(f, name):
    family = 'PWStress Edge ' + name
    for n in f['name'].names:
        if n.nameID in [1, 2, 3, 4, 6, 16, 17]:
            value = {1: family, 2: 'Regular', 3: family, 4: family,
                     6: 'PWStress-Edge-' + name, 16: family, 17: 'Regular'}[n.nameID]
            n.string = value.encode(n.getEncoding(), errors='replace')
    return f


for name, flags in [('restricted', 2), ('no-subsetting', 256), ('bitmap-only', 512)]:
    f = renamed(TTFont(BASE['file']), name)
    f['OS/2'].fsType = flags
    path = OUT / (name + '.ttf')
    f.save(path)
    record(name, path)

for name, target_bytes in [('exact-9mb', 9 * 1024 * 1024), ('over-9mb', 9 * 1024 * 1024 + 4)]:
    f = renamed(TTFont(BASE['file']), name)
    padding = newTable('PWQA')
    padding.data = b'QA boundary padding - ignored by the renderer'
    f['PWQA'] = padding
    path = OUT / (name + '.ttf')
    f.save(path)
    padding.data += b'\0' * (target_bytes - path.stat().st_size)
    f.save(path)
    assert path.stat().st_size == target_bytes
    record(name, path, 'accept' if name == 'exact-9mb' else 'reject')

for name, table in [('missing-hmtx', 'hmtx'), ('missing-hhea', 'hhea'), ('missing-glyf', 'glyf')]:
    f = renamed(TTFont(BASE['file']), name)
    del f[table]
    path = OUT / (name + '.ttf')
    f.save(path)
    record(name, path)

f = renamed(TTFont(BASE['file']), 'NoUnicode')
f['cmap'].tables = [t for t in f['cmap'].tables if t.platformID not in (0, 3)]
path = OUT / 'no-unicode.ttf'
f.save(path)
record('no-unicode', path)

path = OUT / 'collection.ttf'
collection = TTCollection()
collection.fonts = [renamed(TTFont(BASE['file']), 'Collection')]
collection.save(path)
record('collection', path)

path = OUT / 'truncated.ttf'
path.write_bytes(Path(BASE['file']).read_bytes()[:128])
record('truncated', path)

path = OUT / 'Font With Spaces.ttf'
path.write_bytes(Path(BASE['file']).read_bytes())
record('filename-spaces', path)

if not (ROOT / 'adobe-source-serif-tree.json').exists():
    request = urllib.request.Request('https://api.github.com/repos/adobe-fonts/source-serif/git/trees/release?recursive=1', headers={'User-Agent': 'Portwood-Font-Stress-QA'})
    with urllib.request.urlopen(request, timeout=90) as response:
        (ROOT / 'adobe-source-serif-tree.json').write_bytes(response.read())
adobe = json.loads((ROOT / 'adobe-source-serif-tree.json').read_text())
sha = adobe['sha']
url = 'https://raw.githubusercontent.com/adobe-fonts/source-serif/' + sha + '/'
license_path = OUT / 'SourceSerif-LICENSE.md'
license_path.write_bytes(urllib.request.urlopen(url + 'LICENSE.md', timeout=60).read())
for name, remote in [('cff-otf', 'OTF/SourceSerif4-Regular.otf'),
                     ('woff', 'WOFF/TTF/SourceSerif4-Regular.ttf.woff'),
                     ('woff2', 'WOFF2/TTF/SourceSerif4-Regular.ttf.woff2')]:
    # Keep a normal .ttf upload filename to exercise the signature/content validator too.
    path = OUT / (name + '.ttf')
    path.write_bytes(urllib.request.urlopen(url + urllib.parse.quote(remote), timeout=60).read())
    record(name, path, source=remote, license_path=str(license_path))
    RESULTS[-1]['sourceCommit'] = sha

(ROOT / 'edge-cases.json').write_text(json.dumps(RESULTS, indent=2))
print('Edge cases:', len(RESULTS))
