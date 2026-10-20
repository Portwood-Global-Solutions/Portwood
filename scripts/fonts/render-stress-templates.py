"""Create scratch-only, reviewed-font stress templates and render through DocGenService.

Never approves faces; run after the separately reviewed specimen approval phase.
"""
import html
import importlib.util
import json
import argparse
from pathlib import Path
import time
import arabic_reshaper
from bidi.algorithm import get_display

ROOT = Path(__file__).resolve().parents[3] / 'font-stress'
spec = importlib.util.spec_from_file_location('stress', Path(__file__).with_name('stress-native.py'))
stress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stress)
parser = argparse.ArgumentParser()
parser.add_argument('--target-org', required=True)
args = parser.parse_args()
sf = stress.Salesforce(args.target_org)
rows = json.loads((ROOT / 'results.json').read_text())
accepted = [r for r in rows if r.get('verified') and r.get('embeddedMatch')]
SCRIPTS = {
    'arabic': 'مرحبا بالعالم', 'amiri': 'مرحبا بالعالم', 'arefruqaa': 'مرحبا بالعالم',
    'lateef': 'مرحبا بالعالم', 'scheherazadenew': 'مرحبا بالعالم',
    'hebrew': 'שלום עולם', 'frankruhllibre': 'שלום עולם', 'davidlibre': 'שלום עולם',
    'devanagari': 'नमस्ते दुनिया', 'bengali': 'বাংলা ভাষা', 'tamil': 'தமிழ் மொழி',
    'thai': 'สวัสดีชาวโลก', 'sarabun': 'สวัสดีชาวโลก', 'khmer': 'សួស្តីពិភពលោក',
    'myanmar': 'မင်္ဂလာပါ', 'padauk': 'မင်္ဂလာပါ', 'notosansjp': '東京 日本語 漢字',
    'notosanskr': '안녕하세요 세계', 'notosanstc': '繁體中文 漢字',
    'georgian': 'გამარჯობა', 'armenian': 'Բարեւ աշխարհ', 'ethiopic': 'ሰላም ዓለም',
    'music': '♩ ♪ ♫ ♬', 'math': '∑ ∫ √ ∞ ≠ ≤ ≥', 'symbols2': '★ ♞ ☀ ❤',
    'emoji': '❤ ☀ ☺'
}


def has(row, text):
    ranges = row['inspectedMetadata']['coverage']
    return all(any(lo <= ord(ch) <= hi for lo, hi in ranges) for ch in text)


def sample(row):
    for key, text in SCRIPTS.items():
        if key in row['familySlug'] and has(row, text):
            return text
    if has(row, 'Şahin Şirket - café 0123456789'):
        return 'Şahin Şirket - café 0123456789'
    if has(row, 'Portwood - ABC xyz 0123456789'):
        return 'Portwood - ABC xyz 0123456789'
    chars = []
    for lo, hi in row['inspectedMetadata']['coverage']:
        for cp in range(lo, min(hi + 1, lo + 24)):
            if cp > 32 and not 0xd800 <= cp <= 0xdfff and not chr(cp).isspace():
                chars.append(chr(cp))
            if len(chars) >= 12:
                return ''.join(chars)
    return ''.join(chars)


def source(batch, number):
    body = '<p>PORTWOOD FONT STRESS / GROUP ' + str(number) + '</p><p>Live Account: {Name}</p>'
    for row in batch:
        text = sample(row)
        row['templateSample'] = text
        body += '<div style="padding:5pt 0;border-bottom:1pt solid #ccdce3;">'
        body += '<p style="font-size:9pt;margin:0;">' + html.escape(row['id']) + '</p>'
        tag = '{%font:' + row['assetKey'] + ':' + row['revision'][:16] + '}'
        body += '<p style="' + tag + ';font-size:23pt;line-height:1.6;margin:0;">' + html.escape(text) + '</p>'
        if any(0x600 <= ord(c) <= 0x6ff for c in text):
            prepared = get_display(arabic_reshaper.reshape(text))
            if has(row, prepared):
                body += '<p style="font-size:8pt;margin:4pt 0;">Prepared Arabic control:</p><p dir="ltr" style="' + tag + ';font-size:20pt;line-height:1.6;margin:0;direction:ltr;unicode-bidi:bidi-override;">' + prepared + '</p>'
        body += '</div>'
    return '<html><head><meta charset="utf-8"/><style>@page{size:letter;margin:0.55in;}body{font-size:10pt;color:#183452;}p{margin:0 0 4pt;}</style></head><body>' + body + '</body></html>'


record = sf.apex("List<Account> a=[SELECT Id FROM Account WHERE Name='Font Stress QA - Fictional' LIMIT 1];if(a.isEmpty()){Account n=new Account(Name='Font Stress QA - Fictional');insert n;a.add(n);}System.debug('STRESS_RESULT:'+JSON.serialize(a[0].Id));")
outputs = json.loads((ROOT / 'templates.json').read_text()) if (ROOT / 'templates.json').exists() else []
for offset in range(0, len(accepted), 8):
    batch = accepted[offset:offset + 8]
    number = offset // 8 + 1
    if any(o['group'] == number for o in outputs):
        continue
    markup = source(batch, number)
    filename = ROOT / 'templates' / ('group-' + str(number).zfill(2) + '.html')
    filename.parent.mkdir(exist_ok=True)
    filename.write_text(markup)
    code = "DocGen_Template__c t=new DocGen_Template__c(Name='QA Font Stress - Group " + str(number).zfill(2) + "',Type__c='HTML',Base_Object_API__c='Account',Query_Config__c='Name',Output_Format__c='PDF',Category__c='Font stress QA',Test_Record_Id__c=" + stress.literal(record) + ");insert t;DocGenController.saveAndPublishHtmlBody(t.Id,'stress-fonts.html'," + stress.literal(markup) + ",true);System.debug('STRESS_RESULT:'+JSON.serialize(t.Id));"
    template_id = sf.apex(code)
    started = time.monotonic()
    code = 'try { Map<String,Object> result=DocGenService.generatePdfBlob(' + stress.literal(template_id) + ',' + stress.literal(record) + ");Blob bytes=(Blob)result.get('blob');ContentVersion cv=new ContentVersion(Title='QA font stress group " + str(number) + "',PathOnClient='font-stress.pdf',VersionData=bytes,FirstPublishLocationId=" + stress.literal(record) + ");insert cv;System.debug('STRESS_RESULT:'+JSON.serialize(new Map<String,Object>{'cv'=>cv.Id,'bytes'=>bytes.size(),'queries'=>Limits.getQueries(),'cpuMs'=>Limits.getCpuTime(),'heapAtEnd'=>Limits.getHeapSize()}));}catch(Exception e){System.debug('STRESS_RESULT:'+JSON.serialize(new Map<String,Object>{'error'=>e.getMessage()}));}"
    result = sf.apex(code)
    result.update({'group': number, 'templateId': template_id, 'recordId': record,
                   'faces': [r['id'] for r in batch], 'seconds': round(time.monotonic() - started, 2)})
    if result.get('cv'):
        result['file'] = str(ROOT / 'documents' / ('group-' + str(number).zfill(2) + '.pdf'))
        sf.download(result['cv'], Path(result['file']))
    outputs.append(result)
    (ROOT / 'templates.json').write_text(json.dumps(outputs, indent=2))
    print(json.dumps(result), flush=True)
(ROOT / 'results.json').write_text(json.dumps(rows, indent=2, ensure_ascii=False))
