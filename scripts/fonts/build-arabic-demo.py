"""Prepare the fixed Arabic copy in the bilingual HTML demo for Salesforce's native PDF renderer.

Authoring-only dependencies: arabic-reshaper==3.0.1 and python-bidi==0.6.11.
This does not add automatic shaping for Arabic merge values or a runtime dependency.
Edit Arabic in COPY, then regenerate this HTML; each prepared line must fit without wrapping.
"""
from pathlib import Path
import html
import re
import arabic_reshaper
from bidi.algorithm import get_display

ROOT = Path(__file__).resolve().parents[2]
ARABIC_TAG = '{%font:notosansarabic-black:8885c819382f6f13}'
COPY = {
    'title': 'عرض خدمات',
    'prepared': 'مقدم إلى',
    'welcome': 'مرحبا بكم',
    'intro1': 'نقدم لكم خدمات تساعدكم على تنظيم أعمالكم',
    'intro2': 'وتبسيط الإجراءات وتحسين تجربة عملائكم.',
    'scope': 'نطاق العمل',
    'templates': 'قوالب المستندات',
    'signatures': 'طلبات التوقيع',
    'fonts': 'أصول الخطوط',
    'closing': 'شكرا لكم',
}

def arabic(match):
    name, extra_class = match.group(1), match.group(2) or ''
    logical = COPY[name]
    visual = get_display(arabic_reshaper.reshape(logical))
    # LTR override avoids a second bidi pass in browser previews. PDF already consumes visual order.
    return ('<span class="ar ' + extra_class + '" lang="ar" dir="ltr" data-arabic-source="' +
            html.escape(logical, quote=True) + '" style="' + ARABIC_TAG +
            ';direction:ltr;unicode-bidi:bidi-override;">' + html.escape(visual) + '</span>')

source = '''<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<title>Portwood Arabic + English Services Proposal</title>
<!-- Fixed Arabic copy is shaped at authoring time. Edit scripts/fonts/build-arabic-demo.py.
     Ordinary Arabic merge values still need a shaping step; this demo does not add general RTL support. -->
<style>
@page { size: letter; margin: 0.60in; }
body { color: #183452; }
p { margin: 0 0 9pt; }
table { width: 100%; border-collapse: collapse; }
td { vertical-align: top; }
.eyebrow { color: #206b72; letter-spacing: 1.5pt; margin-bottom: 8pt; }
.hero { border-top: 4pt solid #206b72; padding-top: 7pt; }
.ar { display: block; text-align: right; white-space: nowrap; line-height: 1.4; }
.hero-title { font-size: 33pt; line-height: 1.35; color: #183452; }
.subtitle { text-align: right; color: #526475; margin-top: 2pt; margin-bottom: 13pt; }
.customer { background: #edf5f3; border-right: 4pt solid #206b72; margin: 0 0 15pt; }
.customer td { padding: 11pt 13pt; }
.label { color: #526475; font-size: 9pt; margin-bottom: 3pt; }
.customer-name { font-size: 18pt; margin: 0; }
.prepared { font-size: 17pt; color: #206b72; }
.document-meta { font-size: 10pt; line-height: 1.6; }
.welcome { font-size: 21pt; color: #206b72; margin-bottom: 2pt; }
.intro { font-size: 15pt; line-height: 1.65; }
.translation { color: #526475; font-size: 10.5pt; margin: 5pt 0 12pt; line-height: 1.4; }
.scope-heading { font-size: 19pt; color: #206b72; padding-bottom: 3pt; }
.services { border-top: 1pt solid #ccdce3; }
.services td { border-bottom: 1pt solid #d8e1ea; padding: 9pt 7pt; vertical-align: middle; }
.service-label { font-size: 15pt; }
.service-name { font-size: 11pt; margin-bottom: 3pt; }
.service-detail { font-size: 9.5pt; color: #526475; line-height: 1.35; margin: 0; }
.closing { margin-top: 11pt; font-size: 26pt; color: #206b72; }
.thanks { text-align: right; color: #526475; font-size: 11pt; }
.footer { border-top: 1pt solid #d8e1ea; margin-top: 11pt; padding-top: 7pt; font-size: 8.5pt; color: #526475; }
</style>
</head>
<body style="{%font:barlow:179138cb809b03a1};font-size:11pt;line-height:1.35;">
<p class="eyebrow" style="{%font:barlowcondensed:127b06330968f16b};font-size:12pt;">PORTWOOD / ARABIC + ENGLISH</p>
<div class="hero">[[AR:title:hero-title]]</div>
<p class="subtitle">Services proposal</p>
<table class="customer"><tr>
<td style="width:40%;"><p class="label">SAMPLE PROPOSAL</p><div class="document-meta">Reference: PW-AR-001<br/>Prepared in Salesforce</div></td>
<td style="width:60%;text-align:right;">[[AR:prepared:prepared]]<p class="customer-name">{Name}</p></td>
</tr></table>
[[AR:welcome:welcome]]
[[AR:intro1:intro]]
[[AR:intro2:intro]]
<p class="translation">We help you organize your work, simplify your processes, and improve your customers’ experience.</p>
[[AR:scope:scope-heading]]
<table class="services">
<tr><td style="width:60%;"><p class="service-name" style="{%font:barlow:fcb466c546218b46};">Document templates</p><p class="service-detail">Branded documents with live Salesforce fields.</p></td><td style="width:40%;">[[AR:templates:service-label]]</td></tr>
<tr><td><p class="service-name" style="{%font:barlow:fcb466c546218b46};">Signature requests</p><p class="service-detail">Prepare a signature request directly from a record page.</p></td><td>[[AR:signatures:service-label]]</td></tr>
<tr><td><p class="service-name" style="{%font:barlow:fcb466c546218b46};">Shared font assets</p><p class="service-detail">The same approved font in HTML and Canvas templates.</p></td><td>[[AR:fonts:service-label]]</td></tr>
</table>
[[AR:closing:closing]]
<p class="thanks">Thank you. We look forward to working with you.</p>
<p class="footer">PORTWOOD &nbsp; / &nbsp; Sample proposal for demonstration purposes.</p>
</body>
</html>
'''
source = re.sub(r'\[\[AR:([a-z0-9]+):([a-z-]*)\]\]', arabic, source)
assert '[[AR:' not in source
output = ROOT / 'docs/examples/ArabicServicesProposal.html'
output.write_text(source, encoding='utf-8')
print(output)
