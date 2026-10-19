import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM, VirtualConsole } from 'jsdom';
import { signingPageFixture } from './lib/signing-page-fixture.mjs';
const base = new URL('../../force-app/main/default/', import.meta.url);
const read = (path) => readFileSync(new URL(path, base), 'utf8');
let checks = 0;
for (const name of ['DocGenSignature', 'DocGenSignaturePdf']) {
    const source = read(`pages/${name}.page`);
    const dom = new JSDOM(signingPageFixture(source), {
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
// Exercise the actual page initialization: a later remoting response must not
// overwrite the identity already emitted by the server.
const sharedScripts = ['purify.min.js', 'branding-content.js', 'signing-branding.js']
    .map((file) => '<script>' + read('staticresources/DocGenSigningBranding/' + file) + '</script>')
    .join('');
for (const name of ['DocGenSignature', 'DocGenSignaturePdf']) {
    const brand = {
        companyName: 'Initial Brand',
        color: '#227548',
        title: 'Original heading',
        page: { mode: 'Standard' }
    };
    const markup = signingPageFixture(read(`pages/${name}.page`), brand).replace('</head>', sharedScripts + '</head>');
    const errors = [];
    const virtualConsole = new VirtualConsole();
    virtualConsole.on('jsdomError', (error) => errors.push(error.message));
    const dom = new JSDOM(markup, {
        url: 'https://branding.test/?token=' + 'a'.repeat(64),
        runScripts: 'dangerously',
        virtualConsole,
        beforeParse(window) {
            window.fetch = async () => ({ ok: true, json: async () => ({ ip: '127.0.0.1' }) });
            window.Visualforce = {
                remoting: {
                    Manager: {
                        invokeAction(action, ...args) {
                            const callback = args.find((arg) => typeof arg === 'function');
                            if (action.includes('validateToken'))
                                callback(
                                    {
                                        isValid: true,
                                        requiresPin: true,
                                        documentTitle: 'Test agreement',
                                        branding: { companyName: 'Later Brand', color: '#FF0000' }
                                    },
                                    { status: true }
                                );
                        }
                    }
                }
            };
        }
    });
    assert.equal(dom.window.document.querySelector('#signing-brand-company').textContent, 'Initial Brand');
    checks++;
    assert.equal(dom.window.document.body.style.getPropertyValue('--signing-action'), '#227548');
    checks++;
    assert.equal(dom.window.document.querySelector('#state-verify').style.display, '');
    checks++;
    assert.deepEqual(errors, []);
    checks++;
    dom.window.close();
}
console.log(`PASS: ${checks} provider identity and initial-page checks for HTML/PDF signing pages.`);
