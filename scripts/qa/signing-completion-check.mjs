import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM, VirtualConsole } from 'jsdom';
import { signingPageFixture } from './lib/signing-page-fixture.mjs';

// Execute the actual HTML/PDF page scripts without a browser. Server/Apex checks
// separately verify the token and status gates that authorize this projection.
const base = new URL('../../force-app/main/default/', import.meta.url);
const read = (path) => readFileSync(new URL(path, base), 'utf8');
const shared = ['purify.min.js', 'branding-content.js', 'signing-branding.js']
    .map((file) => '<script>' + read('staticresources/DocGenSigningBranding/' + file) + '</script>')
    .join('');
const brand = {
    companyName: 'Receipt Company',
    title: 'Review your agreement',
    color: '#207568',
    completionMessage: 'Thank you from Receipt Company.',
    page: { mode: 'Standard' }
};
let checks = 0;
function equal(actual, expected) {
    assert.deepEqual(actual, expected);
    checks++;
}
for (const name of ['DocGenSignature', 'DocGenSignaturePdf']) {
    const source = read(`pages/${name}.page`);
    for (const state of ['success', 'waiting']) {
        const markup = signingPageFixture(source, brand, state).replace('</head>', shared + '</head>');
        const initial = new JSDOM(markup);
        equal(initial.window.document.querySelector('#state-' + state).style.display, '');
        equal(initial.window.document.querySelector('#state-loading').style.display, 'none');
        equal(initial.window.document.querySelector('#signing-brand-intro').style.display, 'none');
        equal(initial.window.document.querySelector('#signing-brand-company').textContent, brand.companyName);
        initial.window.close();
        const calls = [];
        const errors = [];
        const virtualConsole = new VirtualConsole();
        virtualConsole.on('jsdomError', (error) => errors.push(error.message));
        const dom = new JSDOM(markup, {
            url: 'https://signing.test/?token=' + 'a'.repeat(64),
            runScripts: 'dangerously',
            virtualConsole,
            beforeParse(window) {
                window.fetch = () => calls.push('fetch');
                window.Visualforce = { remoting: { Manager: { invokeAction: () => calls.push('remoting') } } };
            }
        });
        const doc = dom.window.document;
        equal(doc.querySelector('#state-' + state).style.display, '');
        for (const other of [
            'loading',
            'error',
            'verify',
            'processing',
            'decline',
            state === 'success' ? 'waiting' : 'success'
        ])
            equal(doc.querySelector('#state-' + other).style.display, 'none');
        equal(doc.querySelector(name === 'DocGenSignature' ? '#state-guided' : '#state-pdf').style.display, 'none');
        equal(doc.querySelector('#signing-brand-company').textContent, brand.companyName);
        equal(doc.body.style.getPropertyValue('--signing-action'), brand.color);
        equal(doc.title, brand.companyName + ' | Document signing');
        equal(calls, []);
        equal(errors, []);
        dom.window.close();

        // Another tab may finish between first render and token validation.
        const actions = [];
        const raceErrors = [];
        const raceConsole = new VirtualConsole();
        raceConsole.on('jsdomError', (error) => raceErrors.push(error.message));
        const race = new JSDOM(signingPageFixture(source, brand).replace('</head>', shared + '</head>'), {
            url: 'https://signing.test/?token=' + 'a'.repeat(64),
            runScripts: 'dangerously',
            virtualConsole: raceConsole,
            beforeParse(window) {
                window.fetch = async () => ({ ok: true, json: async () => ({ ip: '127.0.0.1' }) });
                window.Visualforce = {
                    remoting: {
                        Manager: {
                            invokeAction(action, ...args) {
                                actions.push(action);
                                const callback = args.find((arg) => typeof arg === 'function');
                                callback({ isValid: false, completionState: state }, { status: true });
                            }
                        }
                    }
                };
            }
        });
        equal(race.window.document.querySelector('#state-' + state).style.display, '');
        equal(race.window.document.querySelector('#state-error').style.display, 'none');
        equal(race.window.document.querySelector('#signing-brand-company').textContent, brand.companyName);
        equal(actions.length, 1);
        equal(actions[0].includes('validateToken'), true);
        equal(raceErrors, []);
        race.window.close();
    }
}
console.log(`PASS: ${checks} completed-link first-render and initialization checks for HTML/PDF pages.`);
