// Exercise the actual signing-page functions without an org or deployment.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext, Script } from 'node:vm';
import { JSDOM } from 'jsdom';

const page = readFileSync(
    new URL('../../force-app/main/default/pages/DocGenSignaturePdf.page', import.meta.url),
    'utf8'
);
// Compile every inline script as well as the functions exercised below.
for (const match of page.matchAll(/<script>([\s\S]*?)<\/script>/g)) new Script(match[1]);
const names = [
    'isTypeOnly',
    'openPlacementCapture',
    'openSignModal',
    'syncSignatureInputState',
    'updateSignSubmitState',
    'handleSpotSubmit',
    'handleSignSubmit',
    'formatPickedDate'
];
const functions = names
    .map((name) => {
        const match = page.match(new RegExp(`^ {20}function ${name}\\([\\s\\S]*?^ {20}\\}`, 'm'));
        assert.ok(match, `Signing-page function ${name} exists`);
        return match[0];
    })
    .join('\n');
const drawPad = page.match(/^ {20}var DrawPad = \(function[\s\S]*?^ {20}\}\)\(\);/m)[0];

let checks = 0;
function check(actual, expected, message) {
    assert.equal(actual, expected, message);
    checks++;
}

for (const typeOnly of [false, true]) {
    const dom = new JSDOM(page);
    const document = dom.window.document;
    const input = document.getElementById('modal-typed-name');
    const canvas = document.getElementById('modal-draw-canvas');
    canvas.getContext = () => ({ clearRect() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}, scale() {} });
    canvas.toDataURL = () => 'data:image/png;base64,test';
    const requests = [];
    const context = {
        document,
        window: dom.window,
        signerData: { typeOnly, signerName: 'Test Signer' },
        token: 'test-token',
        capturedIp: '',
        navigator: { userAgent: 'test' },
        modalMode: 'spot',
        signatureInputSource: null,
        legacyConsentStep: false,
        hideFormFields() {},
        showModalMsg() {},
        hasPendingFormFields() {
            return false;
        },
        Visualforce: {
            remoting: {
                Manager: {
                    invokeAction(...args) {
                        requests.push(args);
                    }
                }
            }
        }
    };
    runInNewContext(functions + '\n' + drawPad, context);
    context.DrawPad.init();

    for (const type of ['Full', 'Initials']) {
        context.openPlacementCapture({ placement: { id: type, type } }, false, false);
        check(
            document.getElementById('modal-draw-group').style.display,
            typeOnly ? 'none' : '',
            `${type}: drawing visibility`
        );
        check(input.parentNode.style.display, '', `${type}: typed input remains visible`);
        check(input.disabled, false, `${type}: typed input remains enabled`);
        check(input.value, type === 'Full' ? 'Test Signer' : '', `${type}: preserve existing name prefill`);
        input.value = '';
        context.syncSignatureInputState();
        context.updateSignSubmitState();
        check(document.getElementById('btn-sign-submit').disabled, true, `${type}: empty input cannot be saved`);
        check(document.getElementById('btn-sign-submit-next').disabled, true, `${type}: empty input cannot advance`);
        check(
            document.getElementById('modal-draw-group').style.display,
            typeOnly ? 'none' : '',
            `${type}: clearing name respects restriction`
        );
        // Dispatch a stroke against the real DrawPad event handlers.
        canvas.dispatchEvent(new dom.window.MouseEvent('mousedown', { clientX: 2, clientY: 2 }));
        canvas.dispatchEvent(new dom.window.MouseEvent('mousemove', { clientX: 5, clientY: 5 }));
        dom.window.dispatchEvent(new dom.window.MouseEvent('mouseup'));
        check(context.DrawPad.hasInk(), !typeOnly, `${type}: strokes are accepted only when drawing is allowed`);
        check(
            document.getElementById('btn-sign-submit').disabled,
            typeOnly,
            `${type}: ink alone cannot enable Type Only save`
        );
        context.DrawPad.clear();
        input.value = type === 'Full' ? 'Typed Signer' : 'TS';
        context.updateSignSubmitState();
        check(document.getElementById('btn-sign-submit').disabled, false, `${type}: typed value enables save`);
        context.handleSpotSubmit(false);
        check(requests.at(-1)[3], input.value, `${type}: save submits the typed value`);
    }

    context.openPlacementCapture({ placement: { type: 'DatePick' } }, false, false);
    check(document.getElementById('modal-draw-group').style.display, 'none', 'DatePick never offers drawing');
    check(input.type, 'date', 'DatePick retains the date picker');
    // The no-placement flow starts with a fresh text input, independently of guided fields.
    input.type = 'text';
    context.openSignModal();
    check(
        document.getElementById('modal-draw-group').style.display,
        typeOnly ? 'none' : '',
        'No-placement dialog respects policy'
    );
    input.value = '';
    context.updateSignSubmitState();
    check(document.getElementById('btn-sign-submit').disabled, true, 'No-placement dialog requires signature');
    input.value = 'Typed Signer';
    context.handleSignSubmit();
    check(context.legacyConsentStep, true, 'Typed signature advances to consent');
    check(document.getElementById('btn-sign-submit').disabled, true, 'Consent is still required');
    document.getElementById('modal-consent-checkbox').checked = true;
    context.updateSignSubmitState();
    check(document.getElementById('btn-sign-submit').disabled, false, 'Consent enables final submission');
    dom.window.close();
}
console.log(`PASS: ${checks} signature input regression checks; inline scripts compile.`);
