"""Download a commit-pinned OFL corpus and prepare clearly labelled static test derivatives.

Run with the same authoring-only fontTools environment used by build-test-fixtures.py.
Downloads and generated font binaries stay outside the package source tree.
"""
import concurrent.futures
import hashlib
import json
import re
import urllib.parse
import urllib.request
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parents[3] / 'font-stress'
ROOT.mkdir(parents=True, exist_ok=True)
if not (ROOT / 'google-fonts-tree.json').exists():
    request = urllib.request.Request('https://api.github.com/repos/google/fonts/git/trees/main?recursive=1', headers={'User-Agent': 'Portwood-Font-Stress-QA'})
    with urllib.request.urlopen(request, timeout=90) as response:
        (ROOT / 'google-fonts-tree.json').write_bytes(response.read())
TREE = json.loads((ROOT / 'google-fonts-tree.json').read_text())
COMMIT = TREE['sha']
FAMILIES = '''abeezee abel abrilfatface acme aladin alegreya alegreyasans alice allura anton arvo
asar bangers baskervville bebasneue bitter breeserif cabin calistoga cardo caveat cinzel comfortaa
cormorantgaramond courgette crimsontext dancingscript dmmono dmsans dmserifdisplay eczar elsie
firasans firacode fjallaone gentiumbookplus greatvibes heebo inconsolata inter josefinsans kanit
karla lato lekton librebaskerville librefranklin lobster lora merriweather montserrat mulish
newsreader notosans notoserif nunito opensans oswald outfit pacifico playfairdisplay poppins
ptsans ptserif raleway roboto robotomono rubik sacramento sourcesans3 sourceserif4 spacegrotesk
spacemono worksans notosansarabic notonaskharabic amiri arefruqaa lateef scheherazadenew
notosanshebrew notoserifhebrew frankruhllibre davidlibre notosansdevanagari notoserifdevanagari
notosansbengali notosanstamil notosansthai sarabun notosanskhmer notosansmyanmar padauk
notosansjp notosanssc notosanskr notosanstc notosansgeorgian notosansarmenian notosansethiopic
notosanssymbols2 notomusic notosansmath notoemoji notocoloremoji bungeecolor bungeespice honk nabla'''.split()
PATHS = [x['path'] for x in TREE['tree'] if x['type'] == 'blob']


def fetch(remote, local):
    local.parent.mkdir(parents=True, exist_ok=True)
    if not local.exists():
        url = 'https://raw.githubusercontent.com/google/fonts/' + COMMIT + '/' + urllib.parse.quote(remote)
        req = urllib.request.Request(url, headers={'User-Agent': 'Portwood-Font-Stress-QA'})
        with urllib.request.urlopen(req, timeout=90) as response:
            local.write_bytes(response.read())
    return local


def inspect(path):
    f = TTFont(path)
    names = f['name']
    cmap = f.getBestCmap() or {}
    result = {
        'family': names.getDebugName(1), 'subfamily': names.getDebugName(2),
        'postscript': names.getDebugName(6), 'preferredFamily': names.getDebugName(16),
        'variable': 'fvar' in f, 'glyf': 'glyf' in f, 'color': any(t in f for t in ['COLR', 'CBDT', 'sbix', 'SVG ']),
        'glyphs': f['maxp'].numGlyphs, 'characters': len(cmap),
        'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'embeddingFlags': f['OS/2'].fsType,
    }
    f.close()
    return result


def download(family):
    candidates = [p for p in PATHS if p.startswith('ofl/' + family + '/') and p.endswith('.ttf')]
    static = [p for p in candidates if '[' not in p]
    pool = static or candidates
    # Regular upright first; add real bold and italic faces for selected families below.
    remote = sorted(pool, key=lambda p: ('Italic' in p, 'Regular' not in p, len(p), p))[0]
    filename = re.sub(r'[^A-Za-z0-9_-]', '-', Path(remote).stem) + '.ttf'
    local = fetch(remote, ROOT / 'fonts' / family / filename)
    license_path = fetch('ofl/' + family + '/OFL.txt', ROOT / 'fonts' / family / 'OFL.txt')
    return {'id': family, 'familySlug': family, 'file': str(local), 'license': str(license_path),
            'sourcePath': remote, 'sourceCommit': COMMIT, 'kind': 'downloaded', **inspect(local)}


def main():
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for row in pool.map(download, FAMILIES):
            results.append(row)
            print('Downloaded', row['id'], row['bytes'], 'variable' if row['variable'] else 'static', flush=True)
    for family in ['abeezee', 'alegreyasans', 'arvo', 'crimsontext', 'dmmono', 'firasans',
                   'gentiumbookplus', 'kanit', 'lato', 'poppins', 'amiri', 'sarabun', 'spacemono']:
        candidates = [p for p in PATHS if p.startswith('ofl/' + family + '/') and p.endswith('.ttf') and '[' not in p]
        for style in ['Bold', 'Italic']:
            chosen = [p for p in candidates if Path(p).stem.endswith('-' + style)]
            if not chosen:
                continue
            remote = chosen[0]
            local = fetch(remote, ROOT / 'fonts' / family / Path(remote).name)
            results.append({'id': family + '-' + style.lower(), 'familySlug': family, 'file': str(local),
                            'license': str(ROOT / 'fonts' / family / 'OFL.txt'), 'sourcePath': remote,
                            'sourceCommit': COMMIT, 'kind': 'downloaded', **inspect(local)})
    # Test the original variable files as-is, separately from their static derivatives.
    for row in list(results):
        if not row['variable'] or row['bytes'] > 20 * 1024 * 1024:
            continue
        f = TTFont(row['file'])
        axes = {a.axisTag: a.defaultValue for a in f['fvar'].axes}
        if 'wght' in axes:
            a = next(a for a in f['fvar'].axes if a.axisTag == 'wght')
            axes['wght'] = max(a.minValue, min(400, a.maxValue))
        instantiateVariableFont(f, axes, inplace=True)
        # Derivatives have distinct names, respecting OFL reserved font names.
        family = 'PWStress ' + row['familySlug']
        for rec in f['name'].names:
            if rec.nameID in [1, 2, 3, 4, 6, 16, 17]:
                value = {1: family, 2: 'Regular', 3: family + ' QA static', 4: family + ' Regular',
                         6: 'PWStress-' + row['familySlug'] + '-Regular', 16: family, 17: 'Regular'}[rec.nameID]
                rec.string = value.encode(rec.getEncoding(), errors='replace')
        target = ROOT / 'fonts' / row['familySlug'] / ('PWStress-' + row['familySlug'] + '-Regular.ttf')
        f.save(target)
        f.close()
        results.append({**row, 'id': row['id'] + '-static', 'file': str(target),
                        'kind': 'static-derivative', 'derivedFrom': row['sha256'], **inspect(target)})
        print('Instanced', row['id'], target.stat().st_size, flush=True)
    (ROOT / 'corpus.json').write_text(json.dumps(results, indent=2))
    print('TOTAL', len(results), 'downloaded', sum(r['kind'] == 'downloaded' for r in results),
          'static derivatives', sum(r['kind'] == 'static-derivative' for r in results), flush=True)


if __name__ == '__main__':
    main()
