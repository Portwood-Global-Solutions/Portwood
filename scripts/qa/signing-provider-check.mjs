import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
const base = new URL('../../force-app/main/default/', import.meta.url);
const read = (path) => readFileSync(new URL(path, base), 'utf8');
let checks = 0;
for (const name of ['DocGenSignature', 'DocGenSignaturePdf']) {
    const source = read(`pages/${name}.page`);
    const dom = new JSDOM(source.slice(source.indexOf('<html'), source.indexOf('</html>') + 7), {
        url: 'https://signing.test/',
        runScripts: 'outside-only'
    });
    const { window } = dom;
    const doc = window.document;
    for (const file of ['purify.min.js', 'branding-content.js', 'signing-branding.js'])
        window.eval(read('staticresources/DocGenSigningBranding/' + file));
    assert.equal(doc.querySelector('.signing-service a').href, 'https://portwood.dev/');
    checks++;
    assert.equal(doc.querySelector('#signing-service-context').textContent, 'Document signing provided by');
    checks++;
    const brand = {
        companyName: 'Cedar Community',
        title: 'Welcome',
        color: '#227548',
        footerText: 'Our footer',
        page: { mode: 'Standard' }
    };
    window.PortwoodSigningBranding.apply(brand);
    assert.equal(
        doc.querySelector('#signing-service-context').textContent,
        'Document signing for Cedar Community provided by'
    );
    checks++;
    assert.equal(doc.title, 'Cedar Community | Signing with Portwood DocGen');
    checks++;
    window.PortwoodSigningBranding.apply({ ...brand, companyName: '<img src=x onerror="alert(1)">' });
    assert.equal(doc.querySelectorAll('#signing-service-context img').length, 0);
    checks++;
    window.PortwoodSigningBranding.apply({
        ...brand,
        page: {
            mode: 'Advanced',
            headerHtml: '<h2>Custom heading</h2>',
            footerHtml: '<p>Custom footer</p>',
            customCss: '.signing-service { display:none; }'
        }
    });
    assert.equal(doc.querySelector('.signing-service').hidden, false);
    checks++;
    assert.equal(doc.querySelector('.signing-service').getRootNode(), doc);
    checks++;
    dom.window.close();
}
console.log(`PASS: ${checks} provider identity checks for HTML/PDF signing pages.`);
