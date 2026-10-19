import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
const root = new URL('../../', import.meta.url);
const resource = new URL('force-app/main/default/staticresources/DocGenSigningBranding/', root);
const links = JSON.parse(readFileSync(new URL('output/brand-live-demo/links.json', root)));
let checks = 0;
for (const [name, url] of [
    ['html', links.htmlUrl],
    ['pdf', links.pdfUrl]
]) {
    const response = await fetch(url);
    assert.equal(response.status, 200);
    checks++;
    const source = await response.text();
    const dom = new JSDOM(source, { url, runScripts: 'outside-only' });
    const { window } = dom;
    const doc = window.document;
    const brand = JSON.parse(doc.querySelector('#signing-initial-brand').textContent);
    assert.equal(doc.title, 'Cedar Community | Signing with Portwood DocGen');
    checks++;
    assert.equal(doc.querySelector('#signing-brand-company').textContent, 'Cedar Community');
    checks++;
    assert.equal(doc.querySelector('#signing-brand-title').textContent, 'Welcome to Cedar Community');
    checks++;
    assert.equal(doc.body.style.getPropertyValue('--signing-action'), '#227548');
    checks++;
    assert.equal(doc.body.style.getPropertyValue('--signing-header'), '#163E35');
    checks++;
    assert.equal(doc.body.style.getPropertyValue('--signing-background'), '#EDF4F1');
    checks++;
    assert.equal(doc.querySelector('#signing-brand-header').style.display, '');
    checks++;
    assert.equal(doc.querySelector('#signing-brand-footer').style.display, '');
    checks++;
    assert.equal(JSON.stringify(brand).includes('pat@example.invalid'), false);
    checks++;
    const before = [doc.title, doc.body.getAttribute('style'), doc.querySelector('#signing-brand-company').textContent];
    for (const file of ['purify.min.js', 'branding-content.js', 'signing-branding.js'])
        window.eval(readFileSync(new URL(file, resource), 'utf8'));
    window.PortwoodSigningBranding.initialize(brand);
    assert.deepEqual(
        [doc.title, doc.body.getAttribute('style'), doc.querySelector('#signing-brand-company').textContent],
        before
    );
    checks++;
    assert.equal(source.includes('PortwoodSigningBranding.apply(result.branding)'), false);
    checks++;
    dom.window.close();
    const invalid = await fetch(url.replace(/token=.*/, 'token=' + 'b'.repeat(64)));
    const invalidDom = new JSDOM(await invalid.text());
    assert.equal(invalidDom.window.document.querySelector('#signing-initial-brand').textContent.trim(), 'null');
    checks++;
    assert.equal(invalidDom.window.document.body.classList.contains('signing-branded'), false);
    checks++;
    assert.equal(invalidDom.window.document.querySelector('#signing-brand-company').textContent, '');
    checks++;
    invalidDom.window.close();
}
writeFileSync(
    new URL('output/brand-live-demo/first-paint-verification.json', root),
    JSON.stringify({ checks, serverPresentationBeforeJavaScript: true, noRemotingBrandSwap: true }, null, 2)
);
console.log(`PASS: ${checks} live first-paint HTML/DOM checks; no browser warning was bypassed.`);
