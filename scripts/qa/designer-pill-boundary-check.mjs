import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const admin = readFileSync('force-app/main/default/lwc/docGenAdmin/docGenAdmin.js', 'utf8');
const modelSource = readFileSync('force-app/main/default/lwc/docGenDesignerModel/docGenDesignerModel.js', 'utf8');
const model = await import('data:text/javascript;base64,' + Buffer.from(modelSource).toString('base64'));
function productionMethod(name, document, dependencies = {}) {
    const start = admin.indexOf('    ' + name + '(');
    assert(start >= 0, name);
    const end = admin.indexOf('\n    }', start) + 6;
    const source = admin
        .slice(start, end)
        .trim()
        .replace(name + '(', 'function(');
    return new Function(
        'document',
        'window',
        'NodeFilter',
        ...Object.keys(model),
        ...Object.keys(dependencies),
        'return (' + source + ');'
    )(
        document,
        document.defaultView,
        document.defaultView.NodeFilter,
        ...Object.values(model),
        ...Object.values(dependencies)
    );
}
function editor(html) {
    const document = new JSDOM('<main contenteditable="true">' + html + '</main>', { pretendToBeVisual: true }).window
        .document;
    const root = document.querySelector('main');
    const selection = document.defaultView.getSelection();
    const harness = {
        workspaceFontFaces: [],
        sharedSnippets: [],
        _snippetPreviewByKey: {},
        _snippetPreviewErrors: {},
        _snippetPreviewRequests: new Map(),
        _requestSnippetPreview() {},
        _allSurfaces: () => [root],
        template: document,
        snapshots: [],
        _pushUndo() {
            this.snapshots.push(root.innerHTML);
        },
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
        '_restylePill',
        '_pillEditParts',
        '_beginPillEdit',
        '_snippetPreviewFor',
        '_renderSnippetPreviews',
        '_writeSnippetContent',
        '_renderSlashSnippetPreviews'
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
        template.innerHTML = model.designerMarkup(root);
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
for (const tag of ['{Name}', '{#Items}', '{%snippet:terms}']) {
    const { root, harness, caret, type, clean } = editor('<p>' + tag + '</p>');
    harness._pillifyTags(root);
    const pill = root.querySelector('[data-dg-tag]');
    harness._beginPillEdit(pill);
    const edited = tag === '{Name}' ? '{Account.Name}' : tag;
    pill.textContent = edited;
    caret(pill.firstChild, edited.length);
    harness._maybePillifyTyped({ inputType: 'insertText', data: '}' });
    assert.equal(pill.getAttribute('contenteditable'), 'false', 'A closing brace ends inline field editing.');
    assert.equal(harness._editingPill, null);
    type(' ordinary text');
    assert.equal(pill.textContent, edited);
    assert.equal(clean().textContent, edited + ' ordinary text');
    assert.equal(harness.snapshots.length, 1);
    assert(
        !harness.snapshots[0].includes('contenteditable="true"'),
        'Undo captures the atomic field before editing begins.'
    );
}
for (const key of ['Enter', 'Escape', 'Tab', 'ArrowRight', 'End']) {
    const { root, harness, caret, type, clean } = editor('<p>{Name}</p>');
    harness._pillifyTags(root);
    const pill = root.querySelector('[data-dg-tag]');
    harness._beginPillEdit(pill);
    pill.textContent = key === 'ArrowRight' ? '{Account.Name}' : '{Account.Name';
    caret(pill.firstChild, pill.textContent.length);
    let prevented = false;
    harness._pillEditKeydown({
        key,
        preventDefault() {
            prevented = true;
        },
        stopPropagation() {}
    });
    assert(prevented, key + ' exits the field instead of editing the containing paragraph.');
    type(' after');
    assert.equal(pill.textContent, '{Account.Name}');
    assert.equal(clean().textContent, '{Account.Name} after');
}
{
    const { root, harness, caret, type, clean } = editor('<p>{Name}</p>');
    harness._pillifyTags(root);
    const pill = root.querySelector('[data-dg-tag]');
    harness._beginPillEdit(pill);
    caret(pill.firstChild, pill.textContent.length - 1);
    harness._pillEditKeydown({ key: '}', preventDefault() {}, stopPropagation() {} });
    type(' after');
    assert.equal(clean().textContent, '{Name} after', 'Typing an existing closing brace exits without duplicating it.');
}
{
    const { root, harness, caret, type, clean } = editor('<p>{Name}</p>');
    harness._pillifyTags(root);
    const pill = root.querySelector('[data-dg-tag]');
    harness._beginPillEdit(pill);
    pill.textContent = '{Account.Name} pasted suffix';
    caret(pill.firstChild, pill.textContent.length);
    harness._maybePillifyTyped({ inputType: 'insertFromPaste' });
    type(' more');
    assert.equal(pill.textContent, '{Account.Name}');
    assert.equal(clean().textContent, '{Account.Name} pasted suffix more');
    assert(!root.querySelector('[data-dg-tag] [data-dg-tag]'));
}
{
    const { root, harness, caret, type, clean } = editor('<p>{Name}</p>');
    harness._pillifyTags(root);
    const pill = root.querySelector('[data-dg-tag]');
    harness._beginPillEdit(pill);
    caret(pill.firstChild, pill.textContent.length);
    type(' boundary');
    assert.equal(pill.getAttribute('contenteditable'), 'false');
    assert.equal(
        clean().textContent,
        '{Name} boundary',
        'Typing beyond a complete field exits before native insertion.'
    );
    harness._beginPillEdit(pill);
    caret(pill.firstChild, 0);
    harness._pillEditKeydown({ key: 'ArrowLeft', preventDefault() {}, stopPropagation() {} });
    type('before ');
    assert.equal(clean().textContent, 'before {Name} boundary');
}
{
    const { root, harness, caret, type, clean } = editor('<p>{Name}</p>');
    harness._pillifyTags(root);
    const pill = root.querySelector('[data-dg-tag]');
    for (const name of ['Account.Name', 'Account.Id', 'Account.Phone']) {
        harness._beginPillEdit(pill);
        pill.textContent = '{' + name + '}';
        caret(pill.firstChild, pill.textContent.length);
        harness._maybePillifyTyped({ inputType: 'insertText', data: '}' });
        assert.equal(pill.textContent, '{' + name + '}');
        assert.equal(harness._finishPillEdit, null);
    }
    type(' after repeated edits');
    assert.equal(clean().textContent, '{Account.Phone} after repeated edits');
}
{
    const { root, harness, caret, type, clean } = editor('<p>{Name}</p>');
    harness._pillifyTags(root);
    const pill = root.querySelector('[data-dg-tag]');
    harness._beginPillEdit(pill);
    pill.textContent = '';
    caret(pill, 0);
    harness._pillEditKeydown({ key: 'Enter', preventDefault() {}, stopPropagation() {} });
    type('ordinary');
    assert.equal(clean().textContent, 'ordinary');
    assert.equal(root.querySelector('[data-dg-tag]'), null);
}
{
    const { root, harness } = editor('<p><span data-dg-tag="true" contenteditable="true">{Name}</span></p>');
    harness._pillifyTags(root);
    assert.equal(
        root.querySelector('[data-dg-tag]').getAttribute('contenteditable'),
        'false',
        'Restored markup cannot reopen an untracked editable pill.'
    );
}
{
    const { document, root, harness, caret, clean } = editor('<p>{Name}</p>');
    harness._pillifyTags(root);
    const pill = root.querySelector('[data-dg-tag]');
    harness._beginPillEdit(pill);
    const pasted = document.createTextNode('{Phone} pasted words');
    pill.parentNode.replaceChild(pasted, pill);
    caret(pasted, pasted.length);
    harness._maybePillifyTyped({ inputType: 'insertFromPaste' });
    assert.equal(root.querySelector('[data-dg-tag]').textContent, '{Phone}');
    assert.equal(root.querySelector('[data-dg-tag]').getAttribute('contenteditable'), 'false');
    assert.equal(clean().textContent, '{Phone} pasted words');
    assert.equal(harness._editingPill, null);
}
console.log(
    'PASS inline pill edits: closing brace, Enter, Escape, Tab, arrow exits, pasted suffix, repeated edits, empty-field exit and atomic undo state.'
);
console.log(
    'PASS merge-tag boundaries: editor tint stays on pills, plain typing before/after, repeated conversion, suffix caret, clean serialization, author fonts/highlights, and intentional zero-width characters.'
);

{
    const { root, harness, caret, type, clean } = editor('<p>Before {%snippet:terms} after</p>');
    harness.sharedSnippets = [{ name: 'Standard terms', assetKey: 'terms' }];
    harness._snippetPreviewByKey.terms =
        '<h2>Terms</h2><p>Payment within <strong>30 days</strong>.</p><table><tr><td>One</td><td>Two</td></tr></table>';
    harness._snippetPreviewByKey.other = '<p>Different shared wording.</p>';
    harness._pillifyTags(root);
    const preview = root.querySelector('[data-dg-snippet]');
    assert(preview);
    assert.equal(preview.getAttribute('contenteditable'), 'false');
    assert.equal(preview.querySelector('strong').textContent, '30 days');
    assert.equal(preview.querySelectorAll('td').length, 2);
    assert.equal(
        model.selectedBlock(preview.querySelector('td'), root),
        root.firstChild,
        'Preview tables are not editable document tables.'
    );
    const before = clean().innerHTML;
    assert.equal(
        before,
        '<p>Before {%snippet:terms} after</p>',
        'Inline block previews collapse before HTML parsing and retain the entire paragraph.'
    );
    harness._pillifyTags(root);
    assert.equal(
        root.querySelectorAll('[data-dg-snippet]').length,
        1,
        'Repeated hydration never nests preview content.'
    );
    const duplicate = model.duplicateBlock(root.firstChild);
    harness._pillifyTags(duplicate);
    assert.equal(root.querySelectorAll('[data-dg-snippet]').length, 2);
    assert.equal(clean().innerHTML, before + before, 'Duplicating a snippet copies its reference only.');
    harness._beginPillEdit(root.querySelector('[data-dg-snippet]'));
    const editing = harness._editingPill;
    assert.equal(editing.textContent, '{%snippet:terms}');
    assert.equal(editing.querySelector('p,table'), null);
    editing.textContent = '{%snippet:other';
    caret(editing.firstChild, editing.textContent.length);
    harness._pillEditKeydown({ key: 'Enter', preventDefault() {}, stopPropagation() {} });
    assert.equal(root.querySelector('[data-dg-snippet="other"]').textContent, 'Different shared wording.');
    type(' ordinary');
    assert.equal(clean().innerHTML, '<p>Before {%snippet:other} ordinary after</p>' + before);
    assert(!clean().innerHTML.includes('30 days'));
}
{
    const { document, root, harness, caret, clean } = editor('<div>{%snippet:terms}</div><div>{%snippet:terms}</div>');
    let resolve;
    let requests = 0;
    harness._requestSnippetPreview = productionMethod('_requestSnippetPreview', document, {
        getSnippetPreview: () => {
            requests++;
            return new Promise((done) => {
                resolve = done;
            });
        }
    });
    harness._pillifyTags(root);
    assert.equal(requests, 1, 'Repeated references share a single preview request.');
    const pending = [...harness._snippetPreviewRequests.values()];
    harness._beginPillEdit(root.querySelector('[data-dg-tag]'));
    resolve('<h2>Loaded clause</h2><p>Shared wording</p>');
    await Promise.all(pending);
    assert.equal(
        harness._editingPill.getAttribute('contenteditable'),
        'true',
        'A late preview cannot interrupt tag editing.'
    );
    assert.equal(root.querySelectorAll('[data-dg-snippet]').length, 1);
    caret(harness._editingPill.firstChild, harness._editingPill.textContent.length);
    harness._pillEditKeydown({ key: 'Enter', preventDefault() {}, stopPropagation() {} });
    assert.equal(root.querySelectorAll('[data-dg-snippet]').length, 2);
    assert.equal(clean().textContent, '{%snippet:terms}{%snippet:terms}');
    assert.equal(requests, 1);
}
{
    const { document, root, harness, clean } = editor('<p>{%snippet:missing}</p>');
    harness._requestSnippetPreview = productionMethod('_requestSnippetPreview', document, {
        getSnippetPreview: () => Promise.reject(new Error('Missing or inactive shared content.'))
    });
    harness._pillifyTags(root);
    await Promise.all([...harness._snippetPreviewRequests.values()]);
    assert.equal(root.querySelector('[data-dg-snippet]'), null);
    assert.match(root.querySelector('[data-dg-tag]').title, /Preview unavailable.*Missing or inactive/);
    assert.equal(
        clean().innerHTML,
        '<p>{%snippet:missing}</p>',
        'A failed preview retains the editable, saveable tag.'
    );
}
{
    const { document, harness } = editor('');
    harness.sharedSnippets = [
        { name: 'Standard terms', assetKey: 'standard-terms', category: 'Legal', mergeTag: '{%snippet:standard-terms}' }
    ];
    harness.blockPaletteSections = [];
    harness.tagPaletteSections = [];
    const catalog = productionMethod('_slashCatalog', document, { extractQueryShape: () => ({ children: [] }) }).call(
        harness
    );
    const entry = catalog.find((item) => item.label === 'Standard terms');
    assert(entry);
    for (const term of ['snippet', 'standard-terms', 'Legal', '{%snippet:standard-terms}'])
        assert(entry.keywords.includes(term));
    assert.equal(entry.snippet, '<div>{%snippet:standard-terms}</div><p><br></p>');
}
console.log(
    'PASS snippet previews: formatted read-only content, inline source round-trip, atomic duplication, double-click tag editing, Enter restore, async deduplication, edit races, failure fallback and @ catalog search.'
);

{
    const { document, root, harness, caret, selection } = editor('<p>Existing document</p>');
    caret(root.firstChild.firstChild, 8);
    const before = root.innerHTML;
    const menu = document.createElement('div');
    menu.className = 'dg-slash-menu';
    menu.innerHTML =
        '<button><span data-slash-snippet="terms"></span></button><button><span data-slash-snippet="later"></span></button><button><span data-slash-snippet="missing"></span></button>';
    document.body.append(menu);
    harness.slashMenu = { items: [] };
    harness._snippetPreviewByKey.terms =
        '<h2>Actual terms</h2><p>Pay within <strong>30 days</strong>.</p><table><tr><td>Included</td></tr></table>';
    harness._snippetPreviewErrors.missing = 'This snippet is inactive.';
    const calls = [];
    let onIntersection;
    let disconnected = 0;
    harness._requestSnippetPreview = (key) => calls.push(key);
    harness._renderSlashSnippetPreviews = productionMethod('_renderSlashSnippetPreviews', document, {
        IntersectionObserver: class {
            constructor(callback) {
                onIntersection = callback;
            }
            observe() {}
            disconnect() {
                disconnected++;
            }
        }
    });
    harness._renderSlashSnippetPreviews();
    const ready = menu.querySelector('[data-slash-snippet="terms"]');
    assert.equal(ready.dataset.previewState, 'ready');
    assert.equal(ready.querySelector('strong').textContent, '30 days');
    assert.equal(ready.querySelector('td').textContent, 'Included');
    assert.match(ready.parentElement.getAttribute('aria-label'), /Actual terms.*30 days/);
    assert.equal(menu.querySelector('[data-slash-snippet="missing"]').textContent, 'Preview unavailable');
    assert.equal(calls.length, 0, 'Offscreen snippet cards do not fetch the library.');
    onIntersection([{ isIntersecting: false, target: menu.querySelector('[data-slash-snippet="later"]') }]);
    assert.equal(calls.length, 0);
    onIntersection([{ isIntersecting: true, target: menu.querySelector('[data-slash-snippet="later"]') }]);
    assert.deepEqual(calls, ['later']);
    assert.equal(root.innerHTML, before, 'Menu hydration never changes the document.');
    assert.equal(selection.anchorNode, root.firstChild.firstChild);
    assert.equal(selection.anchorOffset, 8, 'Preview loading cannot steal the typing caret.');
    productionMethod('_closeSlashMenu', document).call(harness);
    assert.equal(harness.slashMenu, null);
    assert.equal(disconnected, 1, 'Closing the menu stops preview observation.');
}
console.log(
    'PASS @ snippet cards: rendered HTML and tables, content labels, visible-only loading, unavailable previews, caret preservation and observer cleanup.'
);
