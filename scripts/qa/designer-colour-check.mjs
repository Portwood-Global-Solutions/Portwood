import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';

const admin = readFileSync('force-app/main/default/lwc/docGenAdmin/docGenAdmin.js', 'utf8');
const modelSource = readFileSync('force-app/main/default/lwc/docGenDesignerModel/docGenDesignerModel.js', 'utf8');
const model = await import('data:text/javascript;base64,' + Buffer.from(modelSource).toString('base64'));
function productionMethod(name, document) {
    let start = admin.indexOf('    ' + name + '(');
    if (start < 0) start = admin.indexOf('    async ' + name + '(');
    assert(start >= 0, name);
    const end = admin.indexOf('\n    }', start) + 6;
    const source = admin
        .slice(start, end)
        .trim()
        .replace(name + '(', 'function(');
    return new Function('styleRange', 'document', 'window', 'return (' + source + ');')(
        model.styleRange,
        document,
        document.defaultView
    );
}
const workspaceSource = readFileSync(
    'force-app/main/default/lwc/docGenDesignerWorkspace/docGenDesignerWorkspace.js',
    'utf8'
)
    .replace(/^import .*;$/gm, '')
    .replace(/@api\b/g, '')
    .replace('export default class', 'class');
const events = [];
const Workspace = vm.runInNewContext(workspaceSource + '\nDocGenDesignerWorkspace;', {
    LightningElement: class {
        dispatchEvent(event) {
            events.push(event.detail);
        }
    },
    CustomEvent: class {
        constructor(name, options) {
            this.detail = options.detail;
        }
    },
    DOCGEN_LOGO: '/logo'
});
const workspace = new Workspace();
const controls = new JSDOM(
    '<details class="more" open><input data-hex="textColor"><input data-hex="highlightColor"></details>'
).window.document;
workspace.template = controls;
const hex = controls.querySelector('[data-hex="textColor"]');
hex.dataset.property = 'textColor';
hex.dataset.command = 'foreColor';
hex.value = '#b91c1c';
workspace.handleColorDraft({ currentTarget: hex });
assert.equal(events.length, 0, 'Choosing a custom colour only updates the draft until Apply.');
workspace.handleColorApply({ currentTarget: hex });
assert.equal(events.at(-1).action, 'color');
assert.equal(events.at(-1).value, '#b91c1c');
assert.equal(events.at(-1).command, 'foreColor');
assert.equal(controls.querySelector('details').open, false);
workspace.textColor = 'invalid';
workspace.handleColorApply({ currentTarget: hex });
assert.equal(events.length, 1, 'Invalid hex does not apply a colour or close the picker.');
assert.equal(hex.validity.customError, true);
hex.value = '#abc';
workspace.handleColorDraft({ currentTarget: hex });
let prevented = false;
workspace.handleColorKeydown({
    key: 'Enter',
    currentTarget: hex,
    preventDefault() {
        prevented = true;
    }
});
assert(prevented);
assert.equal(events.at(-1).value, '#aabbcc', 'Enter accepts short hex and applies the normalized colour.');
assert.equal(hex.validity.customError, false);
workspace.handleColorApply({ currentTarget: hex });
assert.equal(events.length, 3, 'The same colour can be applied again without another native change event.');

function editor(html) {
    const document = new JSDOM(
        '<main contenteditable="true">' + html + '</main><aside contenteditable="true">Menu</aside>',
        { pretendToBeVisual: true }
    ).window.document;
    const root = document.querySelector('main');
    const selection = document.defaultView.getSelection();
    const snapshots = [],
        messages = [];
    document.execCommand = () => {
        throw new Error('Colours must not depend on native execCommand.');
    };
    const harness = {
        showHtmlBodyVisual: true,
        _cellSel: [],
        _surfaceOwning: (node) => (root.contains(node) ? root : null),
        _isInCanvas: (node, surface) => surface.contains(node),
        _surfaceContaining() {},
        _selectedTableCell: () => null,
        _expandCaretToWord() {},
        _pushUndo: () => snapshots.push(root.innerHTML),
        _repaintCellSel() {},
        _refreshFmtState() {},
        _recordCaret() {
            this._caret = { range: selection.getRangeAt(0).cloneRange() };
        },
        showToast: (...args) => messages.push(args)
    };
    for (const method of [
        '_restoreCaret',
        'handleColorPickMouseDown',
        '_applyDesignerColor',
        'handleColorPickChange',
        'handleFormatAction',
        '_runWorkspaceCommand'
    ])
        harness[method] = productionMethod(method, document);
    const select = (node, from = 0, to = node.nodeValue?.length ?? node.childNodes.length) => {
        const range = document.createRange();
        range.setStart(node, from);
        range.setEnd(node, to);
        selection.removeAllRanges();
        selection.addRange(range);
        harness._caret = { range: range.cloneRange() };
        return range;
    };
    return { document, root, selection, harness, snapshots, messages, select };
}
{
    const { document, root, harness, select, selection, snapshots } = editor('<p>Before customer after.</p>');
    const before = root.innerHTML;
    select(root.firstChild.firstChild, 7, 15);
    harness.handleColorPickMouseDown();
    const saved = harness._savedFmtRange;
    select(document.querySelector('aside').firstChild);
    harness.handleColorPickMouseDown();
    assert.equal(harness._savedFmtRange, saved, 'Toolbar focus cannot overwrite the captured document selection.');
    select(root.firstChild.firstChild, 0, 0);
    await harness._runWorkspaceCommand({ detail: { action: 'color', command: 'foreColor', value: '#b91c1c' } });
    assert.equal(selection.toString(), 'customer', 'Captured text wins over a collapsed caret left by the picker.');
    assert.equal(root.querySelector('span').style.color, 'rgb(185, 28, 28)');
    assert.equal(root.textContent, 'Before customer after.');
    assert.equal(snapshots.length, 1);
    assert.equal(snapshots[0], before, 'One undo snapshot captures the unchanged document before application.');
    assert(harness.htmlEditorDirty);
    select(root.firstChild.lastChild, 1, 6);
    harness.handleColorPickMouseDown();
    harness.handleColorPickChange({ currentTarget: { dataset: { cmd: 'foreColor' }, value: '#b91c1c' } });
    assert.equal(selection.toString(), 'after');
    assert.equal(root.querySelectorAll('span').length, 2, 'Reusing the same colour formats the newly selected text.');
}
{
    const key = 'a'.repeat(64);
    const { root, harness, selection, document } = editor(
        '<p><span data-pw-font-face="' +
            key +
            '" style="font-family:Parisienne;font-weight:400">Hello <span data-dg-tag="true" contenteditable="false">{Name}</span></span></p><p>Second paragraph</p>'
    );
    const range = document.createRange();
    range.setStart(root.firstChild.firstChild.firstChild, 0);
    range.setEnd(root.lastChild.firstChild, 6);
    selection.addRange(range);
    harness.handleFormatAction({ currentTarget: { dataset: { cmd: 'foreColor', value: '#236b4a' } } });
    assert.equal(root.children.length, 2);
    assert.equal(root.querySelectorAll('span p').length, 0);
    assert.equal(root.querySelector('[data-dg-tag]').textContent, '{Name}');
    assert.equal(root.querySelector('[data-dg-tag]').style.color, 'rgb(35, 107, 74)');
    assert.equal(root.querySelector('[data-pw-font-face]').getAttribute('data-pw-font-face'), key);
    assert.equal(root.querySelector('[data-pw-font-face]').style.fontFamily, 'Parisienne');
    harness.handleColorPickMouseDown();
    harness._applyDesignerColor('hiliteColor', '#fff2b2', harness._savedFmtRange);
    assert.equal(root.querySelector('[data-dg-tag]').style.backgroundColor, 'rgb(255, 242, 178)');
    assert.equal(selection.toString(), 'Hello {Name}Second');
}
{
    const { root, harness, select, document } = editor(
        '<table><tr><td><span style="color:red">One</span></td><td><strong style="color:blue">Two</strong></td><td>Untouched</td></tr></table>'
    );
    const cells = [...root.querySelectorAll('td')];
    select(cells[0].firstChild.firstChild);
    harness._cellSel = cells.slice(0, 2);
    harness._applyDesignerColor('foreColor', '#236b4a');
    for (const cell of cells.slice(0, 2)) {
        const text = cell.querySelector('span span, strong span');
        assert.equal(document.defaultView.getComputedStyle(text).color, 'rgb(35, 107, 74)');
    }
    assert.equal(cells[2].innerHTML, 'Untouched', 'Colour reaches selected cells with existing styles only.');
}
{
    const { document, root, harness, select, snapshots, messages } = editor('<p>Original</p>');
    const detached = root.firstChild.firstChild;
    select(detached);
    harness.handleColorPickMouseDown();
    root.innerHTML = '<p>Replaced</p>';
    select(document.querySelector('aside').firstChild);
    harness._applyDesignerColor('foreColor', '#b91c1c', harness._savedFmtRange);
    assert.equal(root.innerHTML, '<p>Replaced</p>', 'A stale range cannot colour another document.');
    assert.equal(snapshots.length, 0);
    assert.equal(messages.length, 1, 'Missing selection receives a visible instruction.');
}
console.log(
    'PASS Designer colours: explicit Apply, hex validation/Enter, repeated colour, captured selection, native-command independence, exact text/merge fields/font bindings, table text, undo snapshot and stale-range protection.'
);
