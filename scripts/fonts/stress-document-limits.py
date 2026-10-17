"""Probe native multi-face, long-document, and missing-glyph behavior in the scratch org."""
import importlib.util
import json
import argparse
from pathlib import Path
import time

ROOT = Path(__file__).resolve().parents[3] / 'font-stress'
spec = importlib.util.spec_from_file_location('stress', Path(__file__).with_name('stress-native.py'))
stress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stress)
parser = argparse.ArgumentParser()
parser.add_argument('--target-org', required=True)
args = parser.parse_args()
sf = stress.Salesforce(args.target_org)
rows = json.loads((ROOT / 'results.json').read_text())
unique = {}
for row in rows:
    if row.get('verified') and row.get('embeddedMatch'):
        unique.setdefault(row['revision'], row)
faces = list(unique.values())[:17]
record = json.loads((ROOT / 'templates.json').read_text())[0]['recordId']
cases = [('16 faces', faces[:16], 1, 'Portwood ABC 0123456789'),
         ('17 faces rejection', faces, 1, 'Portwood ABC 0123456789'),
         ('250 paragraphs', faces[:1], 250, 'Portwood ABC 0123456789'),
         ('Missing merged glyph rejection', faces[:1], 1, '{Description}')]
sf.apex('update new Account(Id=' + stress.literal(record) + ",Description='漢');")
results = []
for name, batch, repetitions, text in cases:
    body = '<p>FONT STRESS / ' + name + '</p><p>Live Account: {Name}</p>'
    for i in range(repetitions):
        for row in batch:
            tag = '{%font:' + row['assetKey'] + ':' + row['revision'][:16] + '}'
            body += '<p style="' + tag + ';font-size:13pt;line-height:1.3;margin:0 0 3pt;">' + text + '</p>'
    source = '<html><head><style>@page{size:letter;margin:0.55in;}body{font-size:10pt;}</style></head><body>' + body + '</body></html>'
    code = "DocGen_Template__c t=new DocGen_Template__c(Name='QA Font Stress - " + name + "',Type__c='HTML',Base_Object_API__c='Account',Query_Config__c='Name,Description',Output_Format__c='PDF',Category__c='Font stress QA',Test_Record_Id__c=" + stress.literal(record) + ");insert t;DocGenController.saveAndPublishHtmlBody(t.Id,'stress-limits.html'," + stress.literal(source) + ",true);System.debug('STRESS_RESULT:'+JSON.serialize(t.Id));"
    if repetitions > 1:
        line = '<p style="{%font:' + batch[0]['assetKey'] + ':' + batch[0]['revision'][:16] + '};font-size:13pt;line-height:1.3;margin:0 0 3pt;">' + text + '</p>'
        prefix = '<html><head><style>@page{size:letter;margin:0.55in;}</style></head><body><p>FONT STRESS / 250 paragraphs</p><p>Live Account: {Name}</p>'
        code = ('String source=' + stress.literal(prefix) + ';for(Integer i=0;i<250;i++)source+=' + stress.literal(line) + ";source+='</body></html>';" + code.replace(stress.literal(source), 'source'))
    template = sf.apex(code)
    started = time.monotonic()
    code = 'try{Map<String,Object> r=DocGenService.generatePdfBlob(' + stress.literal(template) + ',' + stress.literal(record) + ");Blob pdf=(Blob)r.get('blob');ContentVersion cv=new ContentVersion(Title='QA font limit " + name + "',PathOnClient='font-limit.pdf',VersionData=pdf,FirstPublishLocationId=" + stress.literal(record) + ");insert cv;System.debug('STRESS_RESULT:'+JSON.serialize(new Map<String,Object>{'cv'=>cv.Id,'bytes'=>pdf.size(),'queries'=>Limits.getQueries(),'cpuMs'=>Limits.getCpuTime(),'heapAtEnd'=>Limits.getHeapSize()}));}catch(Exception e){System.debug('STRESS_RESULT:'+JSON.serialize(new Map<String,Object>{'error'=>e.getMessage()}));}"
    try:
        result = sf.apex(code)
    except RuntimeError as error:
        result = {'error': str(error)}
    result.update({'case': name, 'templateId': template, 'recordId': record,
                   'faces': [r['id'] for r in batch], 'seconds': round(time.monotonic() - started, 2)})
    if result.get('cv'):
        result['file'] = str(ROOT / 'documents' / (name.replace(' ', '-') + '.pdf'))
        sf.download(result['cv'], Path(result['file']))
    results.append(result)
    (ROOT / 'limits.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(result), flush=True)
catalog = sf.apex("Integer start=Limits.getCpuTime();List<Map<String,Object>> faces=DocGenFontController.getFontFaces();System.debug('STRESS_RESULT:'+JSON.serialize(new Map<String,Object>{'faces'=>faces.size(),'jsonBytes'=>Blob.valueOf(JSON.serialize(faces)).size(),'cpuMs'=>Limits.getCpuTime()-start,'heapAtEnd'=>Limits.getHeapSize(),'queries'=>Limits.getQueries()}));")
(ROOT / 'catalog-performance.json').write_text(json.dumps(catalog, indent=2))
print('Catalog', catalog, flush=True)
