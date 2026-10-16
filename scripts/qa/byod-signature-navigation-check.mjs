/** Exercises the real LWC state machine without an org. Only imports and @api syntax
 * are replaced; rendering/remoting/window boundaries are mocked. */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import { runInNewContext } from 'node:vm';
const source = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenSignatureSender/docGenSignatureSender.js', import.meta.url),
    'utf8'
);
const posts = [];
const frame = { contentWindow: { postMessage: (data, origin) => posts.push({ data, origin }) } };
const button = { isConnected: true, focus() {} };
let getUrl = async () => '/apex/prepare?recordId=001000000000000AAA';
const context = {
    LightningElement: class {
        template = { querySelector: (selector) => (selector.includes('iframe') ? frame : button) };
    },
    NavigationMixin: (Base) => Base,
    getPreparationUrl: (args) => getUrl(args),
    getContext: async () => ({ drafts: [] }),
    getPendingSignatureRequests: async () => [],
    window: {
        addEventListener() {},
        removeEventListener() {},
        location: { origin: 'https://example.lightning.force.com' }
    },
    crypto: webcrypto,
    URL,
    Uint32Array
};
runInNewContext(
    source
        .replace(/^import .+;\n/gm, '')
        .replace(/@api\s*/g, '')
        .replace('export default class', 'class') + '\nthis.Sender = DocGenSignatureSender;',
    context
);
const sender = new context.Sender();
sender.recordId = '001000000000000AAA';
const event = (source) => ({ currentTarget: { ...button, dataset: { source } } });
const settle = () => new Promise((resolve) => setImmediate(resolve));
sender.openComposer(event());
assert.equal(sender.modalOpen, true);
assert.equal(sender.showSourceChooser, true);
sender.chooseSource(event('templates'));
assert.equal(sender.showSourceChooser, false);
assert.equal(sender.templateStarted, true);
sender.changeSource();
assert.equal(sender.modalOpen, true, 'Change source is navigation inside the request');
assert.equal(sender.templateStarted, true, 'Template form stays mounted to preserve entered values');
sender.chooseSource(event('upload'));
await settle();
const originalUrl = sender.editorUrl;
assert.match(originalUrl, /source=upload/);
sender.changeSource();
sender.chooseSource(event('templates'));
assert.equal(sender.editorUrl, originalUrl, 'Template selection keeps the prepared PDF mounted');
assert.equal(sender.hidePdfEditor, true);
sender.changeSource();
sender.chooseSource(event('upload'));
assert.equal(sender.editorUrl, originalUrl, 'Returning to a source resumes its existing preparation');
assert.equal(posts.length, 0, 'Returning to the same PDF source must not reset its wizard step');
sender.editorOrigin = 'https://example.vf.force.com';
sender.changeSource();
sender.chooseSource(event('files'));
assert.equal(sender.editorUrl, originalUrl, 'Changing PDF sources preserves the frame and recipient data');
assert.equal(posts.at(-1).data.value, 'files');
assert.equal(posts.at(-1).origin, 'https://example.vf.force.com');
sender.handleEditorMessage({
    source: {},
    origin: sender.editorOrigin,
    data: { channel: 'portwood-signatures', nonce: sender.nonce, action: 'choose-source' }
});
assert.equal(sender.showSourceChooser, false, 'Other windows cannot navigate the request');
sender.handleEditorMessage({
    source: frame.contentWindow,
    origin: sender.editorOrigin,
    data: { channel: 'portwood-signatures', nonce: sender.nonce, action: 'choose-source' }
});
assert.equal(sender.showSourceChooser, true);
assert.equal(sender.modalOpen, true);
sender.closeComposer();
assert.equal(sender.modalOpen, false);
// A slower response for an earlier source cannot replace the user's later choice.
const responses = [];
getUrl = () => new Promise((resolve) => responses.push(resolve));
sender.openComposer(event());
sender.chooseSource(event('upload'));
sender.changeSource();
sender.chooseSource(event('files'));
responses[1]('/apex/prepare?recordId=001000000000000AAA');
await settle();
const filesUrl = sender.editorUrl;
responses[0]('/apex/prepare?recordId=001000000000000AAA');
await settle();
assert.equal(sender.editorUrl, filesUrl);
assert.match(filesUrl, /source=files/);
sender.closeComposer();
console.log(
    'PASS: one source chooser, in-dialog navigation, retained PDF/template state, origin-bound source changes, stale-response handling.'
);
