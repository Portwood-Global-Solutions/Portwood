import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<main><button id="outside">Outside</button></main>', { pretendToBeVisual: true });
const { document } = dom.window;
const events = [],
    previews = [];
let observer;
class Observer {
    constructor(callback) {
        this.callback = callback;
        observer = this;
    }
    observe() {}
    unobserve() {}
    disconnect() {}
}
const loader = fs.readFileSync('force-app/main/default/lwc/docGenFontLoader/docGenFontLoader.js', 'utf8');
const { fontPickerOptions } = vm.runInNewContext(loader.replace(/^export /gm, '') + '\n({fontPickerOptions});');
const source = fs
    .readFileSync('force-app/main/default/lwc/docGenFontPicker/docGenFontPicker.js', 'utf8')
    .replace(/^import .*;$/gm, '')
    .replace(/@api\b/g, '')
    .replace('export default class', 'class');
const Picker = vm.runInNewContext(source + '\nDocGenFontPicker;', {
    LightningElement: class {
        dispatchEvent(event) {
            events.push({ type: event.type, detail: event.detail });
        }
    },
    CustomEvent: dom.window.CustomEvent,
    document,
    window: dom.window,
    IntersectionObserver: Observer,
    loadFontFace: async (face) => {
        previews.push(face);
    }
});
const builtins = ['Helvetica', 'Times', 'Courier', 'Unicode'].map((name) => ({ label: name, value: name }));
const faces = Array.from({ length: 16 }, (_, index) => ({
    label: index === 15 ? 'Parisienne / Regular' : 'Family ' + index,
    family: index === 15 ? 'Parisienne' : 'Family ' + index,
    key: String(index).padStart(64, 'a'),
    selectable: true,
    weight: index === 4 ? 700 : 400,
    style: index === 5 ? 'italic' : 'normal',
    previewFamily: 'PW_' + index,
    previewUrl: '/font-' + index
}));
const options = fontPickerOptions(builtins, [...faces, { ...faces[0], selectable: false, label: 'Unapproved' }]);
assert.equal(options.length, 20, 'All usable faces share the initial menu with the built-ins.');
assert.equal(options.at(-1).label, 'Parisienne / Regular');
assert.equal(options[8].detail, 'Bold');
assert.equal(options[9].detail, 'Regular Italic');
const host = document.createElement('section');
document.querySelector('main').append(host);
const root = host.attachShadow({ mode: 'open' });
root.innerHTML = '<button class="font-trigger">Fonts</button><input class="font-search"><div class="font-list"></div>';
const picker = new Picker();
picker.template = root;
picker.options = options;
picker.value = options.at(-1).value;
picker.connectedCallback();
const trigger = root.querySelector('button');
trigger.getBoundingClientRect = () => ({ left: 1000, top: 120, bottom: 154 });
picker.query = 'Old search';
picker.show();
assert.equal(picker.query, '', 'Each opening starts with the full list, not a retained filter.');
assert.equal(picker.rows.length, 20);
assert.equal(picker.selectedLabel, 'Parisienne / Regular');
assert.match(picker.selectedStyle, /font-family:'PW_15'/);
assert.match(picker.popupStyle, /position|left:/);
assert.equal(picker.rows.filter((row) => row.selected).length, 1);
assert.match(picker.rows[8].previewStyle, /font-weight:700/);
assert.match(picker.rows[9].previewStyle, /font-style:italic/);
for (const option of picker.rows) {
    const button = document.createElement('button');
    button.className = 'font-option';
    button.dataset.value = option.value;
    button.scrollIntoView = () => {};
    root.querySelector('.font-list').append(button);
}
picker.renderedCallback();
await Promise.resolve();
assert.equal(root.activeElement, root.querySelector('input'));
assert.equal(picker.open, true, 'Focus inside the popup must not dismiss it.');
assert.equal(previews.length, 1, 'Only the selected face loads before rows come into view.');
observer.callback([{ isIntersecting: true, target: root.querySelectorAll('.font-option')[4] }]);
await Promise.resolve();
assert.equal(previews.length, 2, 'Scrolling loads only the visible font preview.');
assert.equal(previews[1].key, faces[0].key, 'Previews use the actual exact-revision font.');
picker.handleInput({ target: { value: 'parisienne' } });
assert.equal(picker.rows.length, 1);
assert.equal(picker.resultCount, '1 of 20 fonts');
picker.handleInput({ target: { value: '' } });
const search = root.querySelector('input');
const down = { key: 'ArrowDown', target: search, preventDefault() {} };
picker.handlePopupKeydown(down);
assert.equal(root.activeElement, root.querySelector('.font-option'));
const buttons = root.querySelectorAll('.font-option');
picker.handlePopupKeydown({ ...down, target: buttons[19] });
assert.equal(root.activeElement, buttons[0], 'Keyboard navigation wraps through the complete list.');
let prevented = false;
picker.handleCapture({
    preventDefault() {
        prevented = true;
    }
});
assert.equal(prevented, true);
assert.equal(events.at(-1).type, 'capture', 'Capture the document selection before search takes focus.');
picker.handleChoose({ currentTarget: { dataset: { value: options.at(-1).value } } });
assert.equal(events.at(-1).detail.value, options.at(-1).value, 'Choosing a preview emits the exact face key.');
assert.equal(picker.open, false);
assert.equal(root.activeElement, trigger);
picker.show();
document.querySelector('#outside').dispatchEvent(new dom.window.MouseEvent('mousedown', { bubbles: true }));
assert.equal(picker.open, false, 'Clicking outside dismisses the popup.');
picker.disconnectedCallback();

const admin = fs.readFileSync('force-app/main/default/lwc/docGenAdmin/docGenAdmin.js', 'utf8');
function method(source, name) {
    const start = source.indexOf('    ' + name);
    assert.ok(start >= 0, name);
    return source.slice(start, source.indexOf('\n    }', start) + 6);
}
const Host = vm.runInNewContext('class Host {' + method(admin, 'get workspaceFontOptions()') + '}; Host;', {
    fontPickerOptions
});
const editor = new Host();
editor.fontChoices = builtins;
editor.workspaceFontFaces = faces;
editor.workspaceFontFamily = faces[4].family;
editor.panelSearch = 'Parisienne';
editor._fontFaceAtCaret = () => faces[4];
assert.equal(editor.workspaceFontOptions.length, 20, 'The toolbar ignores filters in other panels.');
assert.equal(editor.workspaceFontOptions.filter((option) => option.selected).length, 1);
assert.equal(editor.workspaceFontOptions.find((option) => option.selected).value, 'face:' + faces[4].key);
const canvas = fs.readFileSync('force-app/main/default/lwc/docGenCanvas/docGenCanvas.js', 'utf8');
const TableEditor = vm.runInNewContext(
    'class TableEditor {' + method(canvas, 'handleRowTextChange(event)') + '}; TableEditor;',
    { isUnicodeFont: () => false }
);
const table = new TableEditor();
table.selectedBox = { kind: 'table' };
table.selHeaderText = { font: 'Helvetica', color: 'navy', size: 11 };
table.fontPatch = (value) => ({ fontFaceKey: value });
table._patchTable = (patch) => {
    table.patch = patch;
};
table.handleRowTextChange({
    currentTarget: { dataset: { which: 'header', key: 'font' } },
    target: { value: 'old bound value' },
    detail: { value: 'face:script' }
});
assert.equal(table.patch.headerText.fontFaceKey, 'face:script', 'Table-band font changes use the new choice.');
assert.equal(table.patch.headerText.color, 'navy');
console.log(
    'PASS: full single font list, real preview families and styles, lazy preview loading, selected revision, filter reset, keyboard navigation, selection capture, outside dismissal, and editor integration.'
);
