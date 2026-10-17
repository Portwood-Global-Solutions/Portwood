import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const admin = readFileSync('force-app/main/default/lwc/docGenAdmin/docGenAdmin.js', 'utf8');
const modelSource = readFileSync('force-app/main/default/lwc/docGenDesignerModel/docGenDesignerModel.js', 'utf8');
const model = await import('data:text/javascript;base64,' + Buffer.from(modelSource).toString('base64'));
function productionMethod(name, document) {
    const start = admin.indexOf('    ' + name + '(');
    assert(start >= 0, name);
    const end = admin.indexOf('\n    }', start) + 6;
    const source = admin
        .slice(start, end)
        .trim()
        .replace(name + '(', 'function(');
    return new Function('document', 'window', 'NodeFilter', ...Object.keys(model), 'return (' + source + ');')(
        document,
        document.defaultView,
        document.defaultView.NodeFilter,
        ...Object.values(model)
    );
}
function editor(html) {
    const document = new JSDOM('<main contenteditable="true">' + html + '</main>', { pretendToBeVisual: true }).window
        .document;
    const root = document.querySelector('main');
    const selection = document.defaultView.getSelection();
    const harness = {
        workspaceFontFaces: [],
        _surfaceOwning: (node) => (root.contains(node) ? root : null),
        _surfaceContaining: (node) => (root.contains(node) ? root : null),
        _isInCanvas: (node, surface) => surface.contains(node),
        _assetImgFor: () => null,
        _applyPillSpread() {},
        _recordCaret() {
            this._caret = { range: selection.getRangeAt(0).cloneRange() };
        }
    };
    for (const name of [
        '_pillStyleFor',
        '_pillChromeStyles',
        '_pillifyTags',
        '_sizeBarcodePill',
        '_safeReplace',
        '_maybePillifyTyped',
        '_parkCaretAfter',
        '_preparePillTyping',
        '_unpillifyTags',
        '_restylePill'
    ])
        harness[name] = productionMethod(name, document);
    const caret = (node, offset) => {
        const range = document.createRange();
        range.setStart(node, offset);
        range.collapse(true);
        selection.removeAllRanges();
        selection.addRange(range);
    };
    const type = (text) => {
        harness._preparePillTyping(root, { inputType: 'insertText' });
        const range = selection.getRangeAt(0);
        assert.equal(range.startContainer.nodeType, 3, 'Typing uses an editable text node.');
        const node = range.startContainer,
            offset = range.startOffset;
        node.insertData(offset, text);
        caret(node, offset + text.length);
        harness._maybePillifyTyped();
    };
    const clean = () => {
        const template = document.createElement('template');
        template.innerHTML = root.innerHTML;
        harness._unpillifyTags(template.content);
        const result = document.createElement('div');
        result.appendChild(template.content);
        return result;
    };
    return { document, root, selection, harness, caret, type, clean };
}
{
    const { document, root, harness, caret, type, clean } = editor('<p>Before {Name}</p>');
    caret(root.firstChild.firstChild, root.textContent.length);
    harness._maybePillifyTyped();
    const pill = root.querySelector('[data-dg-tag]');
    assert(pill);
    assert.equal(pill.style.backgroundColor, '', 'Editor tint is not a text background the browser can copy.');
    assert.equal(document.defaultView.getComputedStyle(pill).backgroundColor, 'rgba(0, 0, 0, 0)');
    assert.equal(pill.style.getPropertyValue('--dg-pill-tint'), '#ede7fd');
    type(' after');
    const output = clean();
    assert.equal(output.textContent, 'Before {Name} after');
    assert.equal(output.querySelector('[data-dg-caret]'), null);
    assert(!output.innerHTML.includes('\u200b'));
    assert(!output.innerHTML.includes('background'));
    assert(!output.innerHTML.includes('--dg-pill'));
    assert.match(harness._pillChromeStyles(), /::before/);
    assert.equal(root.querySelectorAll('[data-dg-tag]').length, 1);
}
for (const tag of ['{#Items}', '{%snippet:terms}', '{Name}']) {
    const { root, harness, caret, type, clean } = editor('<p>Start ' + tag + '</p>');
    caret(root.firstChild.firstChild, root.textContent.length);
    harness._maybePillifyTyped();
    type(' next');
    type(' {Id}');
    type(' last');
    assert.equal(clean().textContent, 'Start ' + tag + ' next {Id} last');
    assert.equal(root.querySelectorAll('[data-dg-tag]').length, 2);
    assert.equal(root.querySelectorAll('[data-dg-tag] [data-dg-tag]').length, 0);
    assert.equal(root.querySelector('[data-dg-tag]').style.backgroundColor, '');
}
for (const side of ['before', 'after']) {
    const { root, harness, caret, type, clean } = editor('<p>{Name}</p>');
    harness._pillifyTags(root);
    caret(root.firstChild, side === 'before' ? 0 : 1);
    type('ordinary ');
    assert.equal(clean().textContent, side === 'before' ? 'ordinary {Name}' : '{Name}ordinary ');
    assert.equal(
        root.querySelectorAll('[data-dg-caret]').length,
        0,
        'A used caret slot becomes ordinary document text.'
    );
}
{
    const { root, harness, caret, selection, clean } = editor('<p>{Name} trailing words</p>');
    caret(root.firstChild.firstChild, root.textContent.length);
    harness._maybePillifyTyped();
    assert.equal(selection.anchorNode.nodeValue, ' trailing words');
    assert.equal(
        selection.anchorOffset,
        ' trailing words'.length,
        'Pasting a tag with a suffix keeps the caret at the suffix.'
    );
    assert.equal(clean().textContent, '{Name} trailing words');
}
{
    const key = 'a'.repeat(64);
    const { root, harness, caret, type, clean } = editor(
        '<p><span data-pw-font-face="' +
            key +
            '" style="font-family:Parisienne;color:red;background-color:yellow">{Name}</span></p>'
    );
    caret(root.querySelector('span').firstChild, 6);
    harness._maybePillifyTyped();
    type(' authored');
    const output = clean();
    assert.equal(output.textContent, '{Name} authored');
    assert.equal(
        output.querySelector('span').style.backgroundColor,
        'yellow',
        'Author-applied highlights remain intact.'
    );
    assert.equal(output.querySelector('span').style.fontFamily, 'Parisienne');
    assert.equal(output.querySelector('span').getAttribute('data-pw-font-face'), key);
}
{
    const { document, root, harness, caret, clean } = editor('<p>{Name} plain</p>');
    harness._pillifyTags(root);
    const pill = root.querySelector('[data-dg-tag]');
    const range = document.createRange();
    range.selectNode(pill);
    model.styleRange(root, range, { 'background-color': '#fff2b2' });
    harness._restylePill(pill, '{Account.Name}');
    assert.equal(pill.style.backgroundColor, 'rgb(255, 242, 178)');
    caret(root.firstChild.lastChild, 0);
    const output = clean();
    assert.equal(output.querySelector('span').style.backgroundColor, 'rgb(255, 242, 178)');
    assert.equal(output.textContent, '{Account.Name} plain');
    assert.equal(output.querySelector('[data-dg-highlight]'), null);
}
{
    const { root, harness, caret, clean } = editor('<p>author\u200bword {Name}</p>');
    caret(root.firstChild.firstChild, root.textContent.length);
    harness._maybePillifyTyped();
    assert.equal(root.querySelectorAll('[data-dg-caret]').length, 1);
    assert.equal(clean().textContent, 'author\u200bword {Name}', 'Only the editor caret sentinel is stripped.');
}
console.log(
    'PASS merge-tag boundaries: editor tint stays on pills, plain typing before/after, repeated conversion, suffix caret, clean serialization, author fonts/highlights, and intentional zero-width characters.'
);
