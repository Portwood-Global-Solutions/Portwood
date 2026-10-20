import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const utils =
    'data:text/javascript;base64,' +
    Buffer.from(read('force-app/main/default/lwc/docGenUtils/docGenUtils.js')).toString('base64');
const source = read('force-app/main/default/lwc/docGenAuthoringKit/docGenAuthoringKit.js').replace(
    "'c/docGenUtils'",
    JSON.stringify(utils)
);
const kit = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const dom = new JSDOM('', { url: 'https://example.lightning.force.com', runScripts: 'outside-only' });
globalThis.document = dom.window.document;
globalThis.window = dom.window;
let checks = 0;
const eq = (a, b) => {
    assert.deepEqual(a, b);
    checks++;
};
for (const url of [
    'https://example.com/image.png',
    '//example.com/image.png',
    'javascript:alert(1)',
    'https://example.com/font.woff2'
])
    eq(kit.salesforceAssetUrl(url), '');
eq(kit.salesforceAssetUrl('/resource/logo'), '/resource/logo');
eq(
    kit.salesforceAssetUrl('https://example.my.salesforce.com/resource/123/QuoteFonts/Regular.ttf'),
    '/resource/123/QuoteFonts/Regular.ttf'
);
eq(kit.salesforceAssetUrl('https://other.my.salesforce.com/resource/123/QuoteFonts/Regular.ttf'), '');
eq(
    kit.salesforceResourceCss(
        '@font-face{src:url(https://example.my.salesforce.com/resource/123/QuoteFonts/Regular.ttf)}'
    ),
    '@font-face{src:url("/resource/123/QuoteFonts/Regular.ttf")}'
);
eq(
    kit.salesforceAssetUrl('https://example.file.force.com/sfc/dist/version/download/?d=x'),
    'https://example.file.force.com/sfc/dist/version/download/?d=x'
);
eq(kit.salesforceAssetUrl('{%asset:logo}'), '{%asset:logo}');
eq(kit.salesforceAssetUrl('data:font/ttf;base64,AAAA'), 'data:font/ttf;base64,AAAA');
eq(
    kit
        .salesforceResourceCss('background:url(https://example.file.force.com/sfc/dist/version/download/?d=x)')
        .includes('https://example.file.force.com'),
    true
);
const clean = kit.salesforceResourceHtml(
    '<style>@import "https://example.com/font.css"; p{background:url(https://example.com/track)}</style><img src="https://example.com/track" srcset="https://example.com/2x 2x"><img src="https://example.file.force.com/sfc/dist/version/download/?d=x"><iframe src="https://example.com"></iframe><a href="https://example.com/support" ping="https://example.com/track">Support</a><svg><image href="https://example.com/track"/></svg>'
);
const fragment = document.createElement('template');
fragment.innerHTML = clean;
eq(fragment.content.querySelector('img').getAttribute('src'), null);
eq(fragment.content.querySelector('img').hasAttribute('srcset'), false);
eq(
    fragment.content.querySelectorAll('img')[1].getAttribute('src'),
    'https://example.file.force.com/sfc/dist/version/download/?d=x'
);
eq(fragment.content.querySelector('a').getAttribute('href'), 'https://example.com/support');
eq(fragment.content.querySelector('a').hasAttribute('ping'), false);
eq(fragment.content.querySelectorAll('iframe,link,script').length, 0);
eq(fragment.content.querySelector('svg image').hasAttribute('href'), false);
const svg = kit.salesforceResourceHtml(
    '<svg><rect fill="url(#g)"/><image href="https://example.com/track"/><set attributeName="href" to="https://example.com/track"/></svg>'
);
eq(svg.includes('url(&quot;#g&quot;)'), true);
eq(svg.includes('https://'), false);
eq(svg.includes('<set'), false);
eq(fragment.content.querySelector('style').textContent.includes('https://'), false);
for (const css of [
    'background:u\\72l(https://example.com/image)',
    'background:image-set("https://example.com/image" 1x)',
    '@import "https://example.com/style";'
])
    eq(kit.salesforceResourceCss(css), '');
eq(kit.salesforceResourceCss('color:red;background:url(/resource/logo)').includes('url("/resource/logo")'), true);
const inline = kit.scopeHtmlForInlinePreview(
    '<html><head><style>p{color:red}</style></head><body><p>{Account.Name}</p><table><tr><td>Cell</td></tr></table><img src="https://example.com/tracker"></body></html>'
);
eq(inline.includes('{Account.Name}'), true);
eq(inline.includes('<table>'), true);
eq(inline.includes('src="https://example.com/tracker"'), false);
const tableTemplate =
    '<table><thead><tr>{#IF ShowPrice}<th>Price</th>{/IF}</tr></thead><tbody>{#Items}{#IF Heading}<tr><td>{Heading}</td></tr>{/IF}<tr><td>{Name}<table>{#Details}<tr><td>{Value}</td></tr>{/Details}</table></td><td>{#IF Price}{Price}{/IF}</td></tr>{/Items}</tbody></table>';
const protectedTable = kit.salesforceResourceHtml(tableTemplate);
const tableDom = document.createElement('template');
tableDom.innerHTML = protectedTable;
eq(tableDom.content.firstChild.tagName, 'TABLE');
eq(tableDom.content.querySelector('tbody').firstChild.data, '{#Items}');
eq(tableDom.content.querySelector('tbody').lastChild.data, '{/Items}');
eq(tableDom.content.querySelector('tr').firstChild.data, '{#IF ShowPrice}');
eq(protectedTable.includes('<td>{#IF Price}{Price}{/IF}</td>'), true);
eq(kit.salesforceResourceHtml(protectedTable), protectedTable);
eq(kit.protectTableMergeTags('<p>{#Items}{Name}{/Items}</p>'), '<p>{#Items}{Name}{/Items}</p>');
eq(
    kit.protectTableMergeTags('<table>{~Root}<tr><td>{Name}</td></tr>{/Root}</table>'),
    '<table><!--{~Root}--><tr><td>{Name}</td></tr><!--{/Root}--></table>'
);
for (const name of ['DocGenSignature', 'DocGenSignaturePdf'])
    eq(read('force-app/main/default/pages/' + name + '.page').includes('api.ipify.org'), false);
eq(/http-equiv=["']refresh/i.test(read('force-app/main/default/pages/DocGenGuide.page')), false);
const loader = await import(
    'data:text/javascript;base64,' +
        Buffer.from(read('force-app/main/default/lwc/docGenFontLoader/docGenFontLoader.js')).toString('base64')
);
await assert.rejects(
    loader.loadFontFace({ key: 'external', previewFamily: 'External', previewUrl: 'https://example.com/font.ttf' }),
    /Salesforce Files/
);
checks++;
dom.window.eval(read('force-app/main/default/staticresources/DocGenSigningBranding/branding-content.js'));
eq(dom.window.PortwoodBrandContent.assetUrl('https://example.com/resource/tracker'), '');
eq(
    dom.window.PortwoodBrandContent.assetUrl('https://example.file.force.com/sfc/dist/version/download/?d=x'),
    'https://example.file.force.com/sfc/dist/version/download/?d=x'
);
eq(dom.window.PortwoodBrandContent.assetUrl('/resource/logo'), '/resource/logo');
dom.window.close();
delete globalThis.document;
delete globalThis.window;
console.log(`PASS: ${checks} Salesforce-only resource and no-external-lookup checks.`);
