import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { JSDOM } from 'jsdom';
const source = await readFile(
    new URL('../../force-app/main/default/lwc/docGenDesignerModel/docGenDesignerModel.js', import.meta.url),
    'utf8'
);
const model = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const utilsSource = await readFile(
    new URL('../../force-app/main/default/lwc/docGenUtils/docGenUtils.js', import.meta.url),
    'utf8'
);
const authoringSource = (
    await readFile(
        new URL('../../force-app/main/default/lwc/docGenAuthoringKit/docGenAuthoringKit.js', import.meta.url),
        'utf8'
    )
).replace(
    "'c/docGenUtils'",
    JSON.stringify('data:text/javascript;base64,' + Buffer.from(utilsSource).toString('base64'))
);
const authoring = await import('data:text/javascript;base64,' + Buffer.from(authoringSource).toString('base64'));
let passed = 0;
const test = (name, fn) => {
    fn();
    passed++;
    console.log('PASS ' + name);
};
const documentFor = (html) =>
    new JSDOM('<!doctype html><main contenteditable="true">' + html + '</main>').window.document;
const fragment = (doc, html) => {
    const t = doc.createElement('template');
    t.innerHTML = html;
    return t.content;
};
test('inserting a table mid-paragraph splits the paragraph and preserves both halves', () => {
    const d = documentFor('<p id="intro" style="color:navy">Before after</p>');
    const root = d.querySelector('main'),
        r = d.createRange();
    r.setStart(d.querySelector('p').firstChild, 7);
    r.collapse(true);
    model.insertFragment(root, r, fragment(d, '<table><tr><td>{Name}</td></tr></table>'));
    assert.deepEqual(
        [...root.children].map((x) => x.tagName),
        ['P', 'TABLE', 'P']
    );
    assert.equal(root.children[0].textContent, 'Before ');
    assert.equal(root.children[2].textContent, 'after');
    assert.equal(root.children[2].style.color, 'navy');
    assert.equal(root.querySelectorAll('#intro').length, 1);
    assert.equal(new JSDOM(root.innerHTML).window.document.querySelectorAll('table').length, 1);
});
test('inline field insertion replaces only the selected wording at its original location', () => {
    const d = documentFor('<p>Hello customer, welcome.</p>'),
        root = d.querySelector('main'),
        r = d.createRange();
    r.setStart(root.firstChild.firstChild, 6);
    r.setEnd(root.firstChild.firstChild, 14);
    model.insertFragment(root, r, fragment(d, '<span data-dg-tag="true">{Account.Name}</span>'));
    assert.equal(root.textContent, 'Hello {Account.Name}, welcome.');
});
test('a detached caret appends without editing another document', () => {
    const d = documentFor('<p>Original</p>'),
        root = d.querySelector('main'),
        outside = d.createElement('p');
    outside.textContent = 'Unrelated';
    const r = d.createRange();
    r.selectNodeContents(outside);
    const result = model.insertFragment(root, r, fragment(d, '<p>Added</p>'));
    assert(result.appended);
    assert.equal(outside.textContent, 'Unrelated');
    assert.equal(root.lastChild.textContent, 'Added');
});
test('moving an entire table both ways preserves cells, tags and style nodes', () => {
    const d = documentFor(
            '<style>.quote{color:red}</style><p>A</p><table><tr><td>{Quantity}</td></tr></table><p>B</p>'
        ),
        root = d.querySelector('main'),
        table = root.querySelector('table');
    const body = table.outerHTML;
    assert(model.moveBlock(table, 'up'));
    assert.equal(root.children[1], table);
    assert.equal(root.firstChild.tagName, 'STYLE');
    assert(model.moveBlock(table, 'down'));
    assert.equal(table.outerHTML, body);
    assert.equal(root.children[2], table);
});
test('paired and nested repeat boundaries move as one unit', () => {
    const d = documentFor(
            '<p>Start</p><p>{#Items}</p><table><tr><td>{Name}</td></tr></table><p>{#Details}</p><p>{Value}</p><p>{/Details}</p><p>{/Items}</p><p>End</p>'
        ),
        root = d.querySelector('main');
    assert(model.moveBlock(root.querySelector('table'), 'down'));
    assert.equal(root.children[1].textContent, 'End');
    assert.equal(root.children[2].textContent, '{#Items}');
    assert.equal(root.lastChild.textContent, '{/Items}');
});
test('duplicate preserves complete table content while removing duplicate HTML ids', () => {
    const d = documentFor('<table id="one"><tr><td id="cell" style="padding:8pt">{Name}</td></tr></table>'),
        root = d.querySelector('main'),
        copy = model.duplicateBlock(root.querySelector('table'));
    assert.equal(copy.textContent, '{Name}');
    assert.equal(copy.querySelector('td').style.padding, '8pt');
    assert.equal(root.querySelectorAll('#one').length, 1);
    assert.equal(root.querySelectorAll('#cell').length, 1);
});
test('duplicating a repeat group preserves literal text without turning it into HTML', () => {
    const d = documentFor('<p>{#Items}</p><p>{Name}</p><p>{/Items}</p>'),
        root = d.querySelector('main'),
        literal = '<img src=x onerror=alert(1)> & customer text';
    root.insertBefore(d.createTextNode(literal), root.lastChild);
    model.duplicateBlock(root.children[1]);
    assert.equal(root.querySelectorAll('img').length, 0);
    assert.equal(root.textContent.split(literal).length - 1, 2);
    assert.equal(root.textContent.split('{#Items}').length - 1, 2);
    assert.equal(root.textContent.split('{/Items}').length - 1, 2);
});
test('removing the last block leaves an editable paragraph and keeps the stylesheet', () => {
    const d = documentFor('<style>p{color:blue}</style><p>Last</p>'),
        root = d.querySelector('main');
    model.removeBlock(root.querySelector('p'));
    assert(root.querySelector('style'));
    assert(root.querySelector('p br'));
});
test('clicking a nested cell resolves the whole table for arrange operations', () => {
    const d = documentFor('<table><tr><td><p><span>Text</span></p></td></tr></table>');
    assert.equal(
        model.selectedBlock(d.querySelector('span').firstChild, d.querySelector('main')),
        d.querySelector('table')
    );
});
test('fixed placement uses a real printable-area wrapper and returns to original flow styles', () => {
    const d = documentFor('<p style="color:navy;margin:8pt">Position me</p><p>Other</p>'),
        root = d.querySelector('main'),
        block = root.querySelector('p'),
        original = block.getAttribute('style'),
        geometry = { width: 8.5, height: 11, margins: [0.5, 0.5, 0.5, 0.5] };
    model.positionBlock(block, root, geometry, 'absolute', { x: 1, y: 2, width: 3 });
    assert.equal(block.style.left, '1in');
    assert.equal(root.querySelector('[data-pw-layout-page]').style.minHeight, '10in');
    assert.equal(block.style.position, 'absolute');
    model.positionBlock(block, root, geometry, 'flow');
    assert.equal(block.getAttribute('style'), original);
});
test('invalid fixed placement does not change document content', () => {
    const d = documentFor('<p>Untouched</p>'),
        root = d.querySelector('main'),
        before = root.innerHTML;
    assert.throws(
        () =>
            model.positionBlock(root.firstChild, root, { width: 8, height: 11, margins: [1, 1, 1, 1] }, 'absolute', {
                x: 5,
                y: 1,
                width: 3
            }),
        /printable width/
    );
    assert.equal(root.innerHTML, before);
});
test('selection bookmarks restore selected text after a complete DOM replacement', () => {
    const d = documentFor('<p>Hello <strong>customer</strong>.</p>'),
        root = d.querySelector('main'),
        r = d.createRange();
    r.selectNodeContents(root.querySelector('strong'));
    const mark = model.bookmarkRange(root, r);
    root.innerHTML = root.innerHTML;
    assert.equal(model.restoreRange(root, mark).toString(), 'customer');
});
test('caret bookmarks survive adjacent text nodes merging during an undo HTML round trip', () => {
    const d = documentFor('<style>p{color:navy}</style><p></p>'),
        root = d.querySelector('main'),
        p = root.querySelector('p');
    p.append(d.createTextNode('Before '), d.createTextNode('adjacent '));
    const pill = d.createElement('span');
    pill.setAttribute('data-dg-tag', 'true');
    pill.setAttribute('contenteditable', 'false');
    pill.textContent = '{Name}';
    p.append(pill);
    p.append(d.createTextNode(' after '), d.createTextNode('selected words'));
    const range = d.createRange();
    range.setStart(p.lastChild, 0);
    range.setEnd(p.lastChild, 8);
    const mark = model.bookmarkRange(root, range);
    root.innerHTML = root.innerHTML;
    const restored = model.restoreRange(root, mark);
    assert.equal(restored.toString(), 'selected');
    const before = d.createRange();
    before.selectNodeContents(root);
    before.setEnd(restored.startContainer, restored.startOffset);
    assert.equal(before.toString().length, mark.startText);
    assert(!restored.startContainer.parentElement.closest('[data-dg-tag]'));
});
const verifiedFace = {
    key: 'a'.repeat(64),
    family: 'Demo Sans',
    weight: 400,
    style: 'normal',
    mergeTag: '{%font:demo:aaaaaaaaaaaaaaaa}'
};
test('font formatting across paragraphs keeps legal block structure and the selected text', () => {
    const d = documentFor('<p>First line</p><p>Second line</p>'),
        root = d.querySelector('main'),
        r = d.createRange();
    r.setStart(root.firstChild.firstChild, 6);
    r.setEnd(root.lastChild.firstChild, 6);
    const result = model.styleRange(root, r, { 'font-family': 'Times New Roman' });
    assert.equal(root.children.length, 2);
    assert.equal(root.querySelectorAll('span p').length, 0);
    assert.equal(result.toString(), 'lineSecond');
});
test('mixed text and atomic field formatting preserves tag syntax and selection order', () => {
    const d = documentFor('<p><span data-dg-tag="true" contenteditable="false">{Name}</span> suffix</p>'),
        root = d.querySelector('main'),
        r = d.createRange();
    r.selectNodeContents(root.firstChild);
    const result = model.styleRange(root, r, {}, verifiedFace);
    assert.equal(root.querySelector('[data-dg-tag]').textContent, '{Name}');
    assert.equal(result.toString(), '{Name} suffix');
    assert.equal(root.querySelector('[data-dg-tag]').getAttribute('data-pw-font-face'), verifiedFace.key);
});
test('switching part of a pinned-font paragraph to a base font preserves bindings on the other runs', () => {
    const d = documentFor(
            '<p style="-pw-font-face:' +
                verifiedFace.key +
                ';font-family:Demo Sans;font-weight:400;font-style:normal">Before selected after</p>'
        ),
        root = d.querySelector('main');
    model.annotateFontBindings(root, [verifiedFace]);
    const r = d.createRange();
    r.setStart(root.firstChild.firstChild, 7);
    r.setEnd(root.firstChild.firstChild, 15);
    model.styleRange(root, r, { 'font-family': 'Times New Roman' });
    model.flattenFontBindings(root, [verifiedFace]);
    model.serializeFontBindings(root, [verifiedFace]);
    assert.equal(root.textContent, 'Before selected after');
    const selected = [...root.querySelectorAll('span')].find((x) => x.textContent === 'selected');
    assert.equal(selected.style.fontFamily.replace(/["']/g, ''), 'Times New Roman');
    assert(!selected.getAttribute('style').includes('-pw-font-face'));
    assert.equal((root.innerHTML.match(/-pw-font-face/g) || []).length, 2);
});
test('font marker survives a browser CSS edit even before font metadata is available', () => {
    const d = documentFor(
            '<p style="-pw-font-face:' +
                verifiedFace.key +
                ';font-family:Demo Sans;font-weight:400;font-style:normal">Keep my binding</p>'
        ),
        root = d.querySelector('main');
    model.annotateFontBindings(root, []);
    root.firstChild.style.fontSize = '14pt';
    model.serializeFontBindings(root, []);
    assert(root.innerHTML.includes(verifiedFace.key));
    assert.equal(root.firstChild.style.fontSize, '14pt');
});
test('font binding normalization retains the selected wording and leaves neighboring paragraphs untouched', () => {
    const d = documentFor('<p>Before</p><p>Selected words</p><p>After</p>'),
        root = d.querySelector('main'),
        r = d.createRange();
    r.selectNodeContents(root.children[1]);
    const result = model.applyFontRange(root, r, {}, verifiedFace, [verifiedFace]);
    assert.equal(result.toString(), 'Selected words');
    assert.equal(root.children[0].innerHTML, 'Before');
    assert.equal(root.children[2].innerHTML, 'After');
    assert.equal(root.querySelectorAll('[data-pw-font-face]').length, 1);
});
test('inserting below the last header row creates normal body cells', () => {
    const d = documentFor(
            '<table><thead><tr><th style="background:navy;color:white">Header</th><th>Qty</th></tr></thead><tbody><tr><td>Item</td><td>2</td></tr></tbody></table>'
        ),
        table = d.querySelector('table');
    const result = model.editTableGrid(table, table.rows[0].cells[0], 'rowAfter');
    assert.equal(table.tHead.rows.length, 1);
    assert.equal(table.tBodies[0].rows.length, 2);
    assert.equal(result.cell.tagName, 'TD');
    assert.equal(result.cell.style.background, '');
});
test('column insertion expands a merged header instead of adding the cell at the wrong index', () => {
    const d = documentFor(
            '<table><tr><th colspan="2">Merged</th><th>Third</th></tr><tr><td>A</td><td>B</td><td>C</td></tr></table>'
        ),
        table = d.querySelector('table');
    model.editTableGrid(table, table.rows[1].cells[0], 'colAfter');
    const grid = model.tableGrid(table);
    assert.equal(grid.width, 4);
    assert.equal(table.rows[0].cells[0].colSpan, 3);
    assert.equal(table.rows[1].cells.length, 4);
    assert.equal(table.rows[1].cells[2].textContent, 'B');
});
test('row insertion through a row span extends the span and fills only uncovered columns', () => {
    const d = documentFor('<table><tr><td rowspan="2">Shared</td><td>A</td></tr><tr><td>B</td></tr></table>'),
        table = d.querySelector('table');
    model.editTableGrid(table, table.rows[0].cells[1], 'rowAfter');
    assert.equal(table.rows[0].cells[0].rowSpan, 3);
    assert.equal(table.rows[1].cells.length, 1);
    assert.equal(model.tableGrid(table).width, 2);
});
test('deleting a row with a spanning cell carries its content into the next row', () => {
    const d = documentFor(
            '<table><tr><td rowspan="2">Keep shared</td><td>Remove row</td></tr><tr><td>Remain</td></tr></table>'
        ),
        table = d.querySelector('table');
    model.editTableGrid(table, table.rows[0].cells[1], 'rowDel');
    assert.equal(table.rows.length, 1);
    assert.equal(table.rows[0].cells[0].textContent, 'Keep shared');
    assert.equal(table.rows[0].cells[0].rowSpan, 1);
    assert.equal(table.rows[0].cells[1].textContent, 'Remain');
});
test('deleting the first or last repeated column preserves the matching loop boundaries', () => {
    const d = documentFor('<table><tr><td>{#Items}{Name}</td><td>{Quantity}</td><td>{Total}{/Items}</td></tr></table>'),
        table = d.querySelector('table');
    model.editTableGrid(table, table.rows[0].cells[0], 'colDel');
    assert(table.rows[0].cells[0].textContent.startsWith('{#Items}'));
    model.editTableGrid(table, table.rows[0].cells[1], 'colDel');
    assert.equal(table.rows[0].cells.length, 1);
    assert.equal(table.rows[0].textContent, '{#Items}{Quantity}{/Items}');
});
test('removing the only table column removes the empty table', () => {
    const d = documentFor('<table><tr><td>Only</td></tr></table>'),
        table = d.querySelector('table');
    assert(model.editTableGrid(table, table.rows[0].cells[0], 'colDel').removed);
    assert.equal(d.querySelector('table'), null);
});
const adminSource = await readFile(
    new URL('../../force-app/main/default/lwc/docGenAdmin/docGenAdmin.js', import.meta.url),
    'utf8'
);
const productionMethod = (name, args, document, dependencies = {}) => {
    let start = adminSource.indexOf('    ' + name + '(' + args + ') {');
    if (start < 0) start = adminSource.indexOf('    async ' + name + '(' + args + ') {');
    assert(start >= 0, 'production method exists: ' + name);
    const end = adminSource.indexOf('\n    }', start) + 6;
    const method = adminSource
        .slice(start, end)
        .trim()
        .replace(name + '(', 'function(');
    return new Function(
        'tableGrid',
        'annotateFontBindings',
        'serializeFontBindings',
        'stripPillCarets',
        'document',
        'window',
        'previewDraftPdf',
        'previewStarterDraft',
        'insertFragment',
        'editTableGrid',
        'salesforceResourceHtml',
        'return (' + method + ');'
    )(
        model.tableGrid,
        model.annotateFontBindings,
        model.serializeFontBindings,
        model.stripPillCarets,
        document,
        document.defaultView,
        dependencies.previewDraftPdf,
        dependencies.previewStarterDraft,
        model.insertFragment,
        model.editTableGrid,
        (html) => {
            const previous = { document: globalThis.document, window: globalThis.window };
            globalThis.document = document;
            globalThis.window = document.defaultView;
            try {
                return authoring.salesforceResourceHtml(html);
            } finally {
                Object.assign(globalThis, previous);
            }
        }
    );
};
test('actual Designer tag cleanup retains a styled field and its pinned font without an undefined-variable failure', () => {
    const d = documentFor(''),
        template = d.createElement('template');
    template.innerHTML =
        '<p><span data-dg-tag="true" data-pw-font-face="' +
        verifiedFace.key +
        '" style="font-family:Demo Sans;font-weight:400;font-style:normal;font-size:14pt">{Name}</span></p>';
    const harness = {
        workspaceFontFaces: [verifiedFace],
        _safeReplace: (old, node) => old.parentNode.replaceChild(node, old)
    };
    productionMethod('_unpillifyTags', 'root', d).call(harness, template.content);
    model.serializeFontBindings(template.content, [verifiedFace]);
    const result = template.content.firstChild;
    assert.equal(result.textContent, '{Name}');
    assert.equal(result.querySelector('span').style.fontSize, '14pt');
    assert(result.innerHTML.includes('-pw-font-face:' + verifiedFace.key));
    assert.equal(result.querySelector('[data-dg-tag]'), null);
});
test('actual staging sanitizer preserves the author stylesheet and font bindings through two saves', () => {
    const d = documentFor(''),
        harness = {
            workspaceFontFaces: [verifiedFace],
            _safeReplace: (old, node) => old.parentNode.replaceChild(node, old)
        };
    harness._unpillifyTags = productionMethod('_unpillifyTags', 'root', d);
    harness._sanitizeStagedHtml = productionMethod('_sanitizeStagedHtml', 'html', d);
    const head =
        '<head><style>@page {size:A4 landscape;@bottom-right{content:counter(page)}} .title{color:navy}</style></head>';
    const source =
        '<!doctype html><html>' +
        head +
        '<body><p class="title"><span data-dg-tag="true" data-pw-font-face="' +
        verifiedFace.key +
        '" style="font-family:Demo Sans;font-weight:400;font-style:normal">{Name}</span></p></body></html>';
    const first = harness._sanitizeStagedHtml(source),
        second = harness._sanitizeStagedHtml(
            first
                .replace('<body>', '<body><div class="dg-pv"><style>.dg-pv{padding:1in}</style>')
                .replace('</body>', '</div></body>')
        );
    assert(second.includes(head));
    assert(second.includes('-pw-font-face:' + verifiedFace.key));
    assert(second.includes('{Name}'));
    assert(!second.includes('data-dg-tag'));
    assert(!second.includes('.dg-pv{'));
});
test('actual running-region mount initializes empty bands without a scope error', () => {
    const d = documentFor(''),
        root = d.querySelector('main');
    root.innerHTML = '<div class="dg-chrome-band_header"></div><div class="dg-chrome-band_footer"></div>';
    const harness = {
        template: root,
        _bandSource: { header: null, footer: null },
        _bandMounted: null,
        editTemplateHeaderHtml: '',
        editTemplateFooterHtml: '',
        _pillifyTags: () => {},
        _matchBandTypographyToPage: () => {},
        _wireSurfaceInteractions: () => {}
    };
    productionMethod('_mountChromeBands', '', d).call(harness);
    assert(root.querySelector('.dg-chrome-band_header').classList.contains('pw-band-empty'));
    assert.equal(root.querySelector('.dg-chrome-band_footer').getAttribute('contenteditable'), 'true');
});
const asyncTest = async (name, fn) => {
    await fn();
    passed++;
    console.log('PASS ' + name);
};
await asyncTest(
    'actual PDF command catches draft serialization failures and always clears the busy state',
    async () => {
        const messages = [],
            harness = {
                editTemplateTestRecordId: 'record',
                useModernDesigner: true,
                activeMainTab: 'design',
                _workspacePreviewRequest: 0,
                _draftSurfaces: () => {
                    throw new Error('Serialization failure');
                },
                showToast: (...args) => messages.push(args)
            };
        await productionMethod('handlePdfPreview', '', documentFor('')).call(harness);
        assert.equal(harness.isPdfPreviewLoading, false);
        assert.equal(messages.length, 1);
        assert.equal(messages[0][0], 'PDF preview failed');
        assert(messages[0][1].includes('Serialization failure'));
    }
);
await asyncTest('actual PDF command submits current draft/record and visibly publishes the returned PDF', async () => {
    let params;
    const harness = {
        editTemplateId: 'template',
        editTemplateTestRecordId: 'record',
        useModernDesigner: true,
        activeMainTab: 'design',
        _workspacePreviewRequest: 0,
        _draftSurfaces: () => ({
            body: '<html><body>Unsaved wording</body></html>',
            header: 'Header',
            footer: 'Footer'
        }),
        showToast: () => {
            throw new Error('Unexpected error');
        }
    };
    const api = async (value) => {
        params = value;
        return { contentDocumentId: 'document', contentVersionId: 'pdf-version' };
    };
    await productionMethod('handlePdfPreview', '', documentFor(''), { previewDraftPdf: api }).call(harness);
    assert(params.draftHtml.includes('Unsaved wording'));
    assert.equal(params.recordId, 'record');
    assert.equal(harness.workspacePreviewId, 'pdf-version');
    assert.equal(harness.workspaceStage, 'preview');
    assert.equal(harness.isPdfPreviewLoading, false);
});
await asyncTest('actual settings open/Done path keeps the same mounted Designer draft', async () => {
    const draft = documentFor('<p>Unsaved draft</p>').querySelector('main');
    const harness = {
        useModernDesigner: true,
        activeMainTab: 'design',
        showHtmlBodyVisual: true,
        _exitVisualMode: () => {
            throw new Error('Draft should stay mounted');
        }
    };
    productionMethod('handleEditTemplateFromDesigner', '', draft.ownerDocument).call(harness);
    assert.equal(harness.activeMainTab, 'design');
    assert.equal(harness.activeEditTab, 'details');
    assert.equal(harness.isEditModalOpen, true);
    await productionMethod('handleCloseEditModal', '', draft.ownerDocument).call(harness);
    assert.equal(harness.isEditModalOpen, false);
    assert.equal(harness.activeMainTab, 'design');
    assert.equal(draft.textContent, 'Unsaved draft');
});
test('a new edit cancels a pending asynchronous font application before it can overwrite the newer selection', () => {
    const harness = { workspaceFontLoading: true, _workspaceFontApply: 3, showHtmlBodyVisual: false };
    productionMethod('_pushUndo', 'label', documentFor('')).call(harness, 'type:insertText');
    assert.equal(harness.workspaceFontLoading, false);
    assert.equal(harness._workspaceFontApply, 4);
});
test('rectangle selection expands existing spans and merges content in reading order', () => {
    const d = documentFor(
        '<table><tbody><tr><td rowspan="2">A</td><td>B</td><td>C</td></tr><tr><td>D</td><td>E</td></tr><tr><td>F</td><td>G</td><td>H</td></tr></tbody></table>'
    );
    const table = d.querySelector('table'),
        cells = [...table.querySelectorAll('td')];
    const rectangle = model.tableRectangle(table, cells[1], cells[5]);
    assert.equal(rectangle.cells.length, 5);
    const merged = model.mergeTableCells(table, cells[1], cells[5]);
    assert.equal(merged.textContent, 'A B D F G');
    assert.equal(merged.rowSpan, 3);
    assert.equal(merged.colSpan, 2);
    assert.equal(model.tableGrid(table).width, 3);
    assert.equal(table.rows[0].cells[1].textContent, 'C');
    assert.equal(table.rows[1].cells[0].textContent, 'E');
});
test('splitting a two-dimensional span restores logical positions alongside another row span', () => {
    const d = documentFor(
        '<table><tr><td rowspan="3">Left</td><td rowspan="2" colspan="2" style="padding:8pt">Merged</td><td>Right</td></tr><tr><td>R2</td></tr><tr><td>A</td><td>B</td><td>C</td></tr></table>'
    );
    const table = d.querySelector('table'),
        cell = table.rows[0].cells[1];
    model.splitTableCell(table, cell);
    const layout = model.tableGrid(table);
    assert.equal(layout.width, 4);
    assert.equal(layout.grid[1][0].textContent, 'Left');
    assert.equal(layout.grid[1][1].textContent.trim(), '');
    assert.equal(layout.grid[1][2].textContent.trim(), '');
    assert.equal(layout.grid[1][3].textContent, 'R2');
    assert.equal(layout.grid[1][1].style.padding, '8pt');
});
test('merge across header and body is rejected without changing the table', () => {
    const d = documentFor(
        '<table><thead><tr><th>Header</th></tr></thead><tbody><tr><td>Body</td></tr></tbody></table>'
    );
    const table = d.querySelector('table'),
        before = table.outerHTML;
    assert.equal(model.mergeTableCells(table, table.rows[0].cells[0], table.rows[1].cells[0]), null);
    assert.equal(table.outerHTML, before);
});
test('actual Shift-click handler retains the anchor and selects the requested rectangle', () => {
    const d = documentFor('<table><tr><td>A</td><td>B</td><td>C</td></tr></table>'),
        cells = [...d.querySelectorAll('td')];
    let selected,
        prevented = false;
    const harness = {
        _cellSelAnchor: cells[0],
        _isInCanvas: () => true,
        _applyCellSelRect: (table, first, last) => {
            selected = model.tableRectangle(table, first, last).cells;
        }
    };
    productionMethod('_cellSelDown', 'e, pv', d).call(
        harness,
        {
            target: cells[1],
            shiftKey: true,
            preventDefault() {
                prevented = true;
            }
        },
        d.querySelector('main')
    );
    assert(prevented);
    assert.equal(harness._cellSelAnchor, cells[0]);
    assert.deepEqual(selected, [cells[0], cells[1]]);
});
test('actual image picker inserts an independent block and returns to its inspector', () => {
    let inserted,
        closed = false;
    const harness = {
        useModernDesigner: true,
        showHtmlBodyVisual: true,
        activePanel: 'images',
        _insertIntoVisualPage: (value) => {
            inserted = value;
        },
        handlePanelClose: () => {
            closed = true;
        },
        showToast: () => {}
    };
    productionMethod('handleInsertTagSnippet', 'event', documentFor('')).call(harness, {
        currentTarget: { dataset: { snippet: '{%asset:logo}' } }
    });
    assert.equal(inserted, '<p>{%asset:logo}</p>');
    assert(closed);
});
test('actual cleanup translates browser underline/strike CSS to the native PDF shorthand', () => {
    const d = documentFor(''),
        template = d.createElement('template');
    template.innerHTML =
        '<p><span style="text-decoration-line:underline line-through;color:navy">Styled text</span><span data-dg-tag="true" style="text-decoration-line:underline">{Name}</span></p>';
    const harness = { workspaceFontFaces: [], _safeReplace: (old, node) => old.parentNode.replaceChild(node, old) };
    productionMethod('_unpillifyTags', 'root', d).call(harness, template.content);
    const result = template.innerHTML;
    assert(!result.includes('text-decoration-line'));
    assert(result.includes('text-decoration: underline line-through'));
    assert(result.includes('text-decoration: underline'));
    assert.equal(template.content.firstChild.textContent, 'Styled text{Name}');
});
test('actual column resize uses unzoomed geometry and honours rowspan column positions', () => {
    const d = documentFor(
            '<table><tr><td rowspan="2">A</td><td>B</td><td>C</td></tr><tr><td>D</td><td>E</td></tr></table>'
        ),
        table = d.querySelector('table');
    table.getBoundingClientRect = () => ({ width: 600 });
    for (const cell of table.querySelectorAll('td')) cell.getBoundingClientRect = () => ({ width: 200 });
    const harness = { designerZoom: 2 };
    const cols = productionMethod('_normalizeTableForResize', 'table', d).call(harness, table);
    assert.deepEqual(
        cols.map((c) => c.style.width),
        ['100px', '100px', '100px']
    );
    assert.equal(table.style.width, '300px');
    assert.equal(productionMethod('_colIndexForCell', 'cell', d).call(harness, table.rows[1].cells[0]), 1);
});
test('actual drag resize changes physical widths and row heights once regardless of zoom', () => {
    const d = documentFor(
            '<table><colgroup><col style="width:100px"><col style="width:100px"></colgroup><tr><td>A</td><td>B</td></tr></table>'
        ),
        root = d.querySelector('main'),
        table = d.querySelector('table'),
        cell = table.rows[0].cells[0];
    table.style.width = '200px';
    const harness = {
        designerZoom: 2,
        _resizeEdgeInfo: () => ({ kind: 'col', cell }),
        _pushUndo: () => {},
        _normalizeTableForResize: () => [...table.querySelectorAll('col')],
        _colIndexForCell: () => 0,
        _clampTablesToCanvas: () => {},
        _syncWorkspaceSelection: () => {}
    };
    const start = productionMethod('_tableResizeStart', 'event, pv', d);
    start.call(harness, { clientX: 100, preventDefault() {} }, root);
    d.dispatchEvent(new d.defaultView.MouseEvent('mousemove', { clientX: 140 }));
    d.dispatchEvent(new d.defaultView.MouseEvent('mouseup'));
    assert.deepEqual(
        [...table.querySelectorAll('col')].map((c) => c.style.width),
        ['120px', '80px']
    );
    cell.parentElement.getBoundingClientRect = () => ({ height: 80 });
    harness._resizeEdgeInfo = () => ({ kind: 'row', cell });
    start.call(harness, { clientY: 100, preventDefault() {} }, root);
    d.dispatchEvent(new d.defaultView.MouseEvent('mousemove', { clientY: 120 }));
    d.dispatchEvent(new d.defaultView.MouseEvent('mouseup'));
    assert.equal(cell.parentElement.style.height, '50px');
});
test('actual resize prefers measured unequal body columns over an averaged merged header', () => {
    const d = documentFor('<table><tr><th colspan="2">Header</th></tr><tr><td>Narrow</td><td>Wide</td></tr></table>'),
        table = d.querySelector('table');
    table.getBoundingClientRect = () => ({ width: 300 });
    table.rows[0].cells[0].getBoundingClientRect = () => ({ width: 300 });
    table.rows[1].cells[0].getBoundingClientRect = () => ({ width: 60 });
    table.rows[1].cells[1].getBoundingClientRect = () => ({ width: 240 });
    const cols = productionMethod('_normalizeTableForResize', 'table', d).call({ designerZoom: 1.5 }, table);
    assert.deepEqual(
        cols.map((c) => c.style.width),
        ['40px', '160px']
    );
});
test('actual insert presets leave paragraphs blank and page-break labels out of saved content', () => {
    const d = documentFor(''),
        choices = productionMethod('get workspaceInsertChoices', '', d).call({});
    assert.equal(fragment(d, choices.find((c) => c.key === 'text').snippet).textContent, '');
    const pageBreak = fragment(d, choices.find((c) => c.key === 'break').snippet);
    assert.equal(pageBreak.textContent, '');
    assert.equal(pageBreak.children[0].style.pageBreakBefore, 'always');
    assert.equal(pageBreak.children[1].tagName, 'P');
});
test('actual heading focus selects its placeholder so typing replaces it', () => {
    const d = documentFor('<h2>Section heading</h2>'),
        root = d.querySelector('main'),
        heading = d.querySelector('h2');
    heading.scrollIntoView = () => {};
    const harness = {
        _surfaceOwning: () => root,
        _bodyCanvas: () => root,
        _setActiveSurface: () => {},
        _recordCaret: () => {}
    };
    productionMethod('_focusWorkspaceBlock', 'block, selectContents = false, reveal = true', d).call(
        harness,
        heading,
        true
    );
    assert.equal(d.defaultView.getSelection().toString(), 'Section heading');
});
test('source preview reads the current textarea and preserves an intentionally empty source', () => {
    const d = documentFor(''),
        editor = d.createElement('textarea');
    editor.value = '<html><head><style>@page {size:A4 landscape}</style></head><body>Unsaved source</body></html>';
    let adopted;
    const harness = {
        showHtmlBodyVisual: false,
        template: { querySelector: () => editor },
        _lastUploadedHtmlText: 'Old saved source',
        _adoptRegions: (value) => {
            adopted = value;
            return { body: value };
        }
    };
    const read = productionMethod('_currentDraftHtml', '', d);
    assert(read.call(harness).includes('Unsaved source'));
    assert(adopted.includes('@page'));
    editor.value = '';
    assert.equal(read.call(harness), '');
});
test('source shortcuts save or preview without consuming regular typing or browser navigation', () => {
    const d = documentFor(''),
        actions = [];
    const harness = {
        useModernDesigner: true,
        showHtmlBodyVisual: false,
        handleWorkspaceCommand: (event) => actions.push(event.detail.action)
    };
    const key = productionMethod('handleSourceKeydown', 'event', d);
    let prevented = 0;
    const event = (value) => ({
        key: value,
        ctrlKey: true,
        preventDefault() {
            prevented++;
        },
        stopPropagation() {}
    });
    key.call(harness, event('s'));
    key.call(harness, event('Enter'));
    key.call(harness, event('z'));
    key.call(harness, { ...event('s'), isComposing: true });
    assert.deepEqual(actions, ['save', 'source-preview']);
    assert.equal(prevented, 2);
});
await asyncTest(
    'preview-current-source command opens native preview without switching through the visual DOM',
    async () => {
        let rendered = false,
            closed = false;
        const harness = {
            handlePanelClose() {
                closed = true;
            },
            handlePdfPreview: async () => {
                rendered = true;
            },
            handleSelectVisualMode() {
                throw new Error('Source must stay mounted');
            }
        };
        await productionMethod('_runWorkspaceCommand', 'event', documentFor('')).call(harness, {
            detail: { action: 'source-preview' }
        });
        assert(rendered && closed);
        assert.equal(harness.workspaceStage, 'preview');
    }
);
test('source edits invalidate an older PDF response and keep the native editor caret status', () => {
    let cursor = false;
    const harness = {
        useModernDesigner: true,
        activeMainTab: 'design',
        _workspacePreviewRequest: 3,
        workspacePreviewId: 'old-pdf',
        handleSourceCursor() {
            cursor = true;
        },
        _refreshCodePreview() {}
    };
    productionMethod('handleHtmlBodyEditorInput', '', documentFor('')).call(harness);
    clearTimeout(harness._codePreviewTimer);
    assert.equal(harness._workspacePreviewRequest, 4);
    assert.equal(harness.workspacePreviewId, undefined);
    assert.equal(harness.htmlEditorDirty, true);
    assert(cursor);
});
test('actual source tag insertion replaces the selected text at its caret and invalidates the preview', () => {
    const d = documentFor(''),
        editor = d.createElement('textarea');
    d.body.append(editor);
    editor.value = '<p>Hello customer</p>';
    editor.setSelectionRange(9, 17);
    d.execCommand = () => false;
    let dirty = false;
    const harness = {
        useModernDesigner: true,
        showHtmlBodyVisual: false,
        template: { querySelector: () => editor },
        handleHtmlBodyEditorInput() {
            dirty = true;
        }
    };
    assert(productionMethod('_insertAtEditorCursor', 'text', d).call(harness, '{Account.Name}'));
    assert.equal(editor.value, '<p>Hello {Account.Name}</p>');
    assert(dirty);
    assert.equal(editor.selectionStart, 23);
});
test('opening Source preserves the author dirty state despite visual normalization', () => {
    const d = documentFor(''),
        editor = d.createElement('textarea');
    editor.value = '<p>Saved source</p>';
    const harness = {
        showHtmlBodyVisual: true,
        htmlEditorDirty: false,
        template: { querySelector: () => editor },
        _exitVisualMode() {
            this.showHtmlBodyVisual = false;
            this.htmlEditorDirty = true;
        }
    };
    const select = productionMethod('handleSelectSourceMode', '', d);
    select.call(harness);
    assert.equal(harness.htmlEditorDirty, false);
    assert.equal(harness._sourceModeDraft, editor.value);
    harness.showHtmlBodyVisual = true;
    harness.htmlEditorDirty = true;
    select.call(harness);
    assert.equal(harness.htmlEditorDirty, true);
});
await asyncTest('changing editing mode cancels an in-flight native preview before returning to editing', async () => {
    let visual = false;
    const harness = {
        _workspacePreviewRequest: 7,
        workspacePreviewId: 'old-pdf',
        workspaceStage: 'preview',
        handlePanelClose() {},
        handleSelectVisualMode() {
            visual = true;
        }
    };
    await productionMethod('_runWorkspaceCommand', 'event', documentFor('')).call(harness, {
        detail: { action: 'mode', value: 'visual' }
    });
    assert(visual);
    assert.equal(harness._workspacePreviewRequest, 8);
    assert.equal(harness.workspacePreviewId, undefined);
    assert.equal(harness.workspaceStage, 'document');
});
// Shared content must remain an atomic reference while arranging and saving a template.
test('shared content insertion keeps the reference and leaves shared wording out of the editable document', () => {
    const d = documentFor('<p>Before</p>'),
        calls = [];
    const harness = {
        sharedSnippets: [{ id: 'terms', name: 'Standard terms', mergeTag: '{%snippet:standard-terms}' }],
        _insertIntoVisualPage: (markup) => calls.push(markup),
        handlePanelClose: () => calls.push('closed')
    };
    productionMethod('handleInsertSharedContent', 'event', d).call(harness, {
        currentTarget: { dataset: { id: 'terms' } }
    });
    assert.equal(calls[0], '<div>{%snippet:standard-terms}</div><p><br></p>');
    assert.equal(calls[1], 'closed');
    const t = d.createElement('template');
    t.innerHTML = '<div><span data-dg-tag="true">{%snippet:standard-terms}</span></div>';
    const cleanup = { _safeReplace: (old, node) => old.parentNode.replaceChild(node, old) };
    productionMethod('_unpillifyTags', 'root', d).call(cleanup, t.content);
    assert.equal(t.content.firstChild.outerHTML, '<div>{%snippet:standard-terms}</div>');
});
test('clicking a shared reference opens shared content rather than record-field formatting', () => {
    const d = documentFor('<div><span data-dg-tag="true">{%snippet:terms}</span></div>');
    let loads = 0;
    const harness = { useModernDesigner: true, _loadSharedSnippets: () => loads++ };
    productionMethod('_openPillMenu', 'pill', d).call(harness, d.querySelector('span'));
    assert.equal(harness.activePanel, 'snippets');
    assert.equal(loads, 1);
});

test('ordinary text dragging across table cells never becomes a cell-range gesture in the new designer', () => {
    const d = documentFor('<table><tr><td>First</td><td>Second</td></tr></table>');
    let changed = false;
    const harness = {
        useModernDesigner: true,
        _cellSelecting: false,
        _cellSelAnchor: d.querySelector('td'),
        _applyCellSelRect: () => {
            changed = true;
        }
    };
    productionMethod('_cellSelMove', 'e, pv', d).call(
        harness,
        {
            buttons: 1,
            target: d.querySelectorAll('td')[1],
            preventDefault() {
                throw Error('native selection must survive');
            }
        },
        d.querySelector('main')
    );
    assert.equal(changed, false);
});
test('table sizing keeps the table footprint and focus in the sidebar at non-default zoom', () => {
    const d = documentFor('<table style="width:100%"><tr><td>A</td><td>B</td><td>C</td></tr></table>');
    const root = d.querySelector('main'),
        table = d.querySelector('table'),
        cell = d.querySelector('td');
    const input = d.createElement('input');
    d.body.append(input);
    input.focus();
    table.getBoundingClientRect = () => ({ width: 1200 });
    for (const c of table.querySelectorAll('td')) c.getBoundingClientRect = () => ({ width: 400 });
    let undo = 0;
    const harness = {
        designerZoom: 2,
        _caret: { cellEl: cell },
        _surfaceOwning: () => root,
        _pushUndo: () => undo++,
        _clampTablesToCanvas() {},
        _syncWorkspaceSelection() {},
        showToast() {
            throw Error('valid size rejected');
        }
    };
    harness._normalizeTableForResize = productionMethod('_normalizeTableForResize', 'table', d);
    harness._workspaceTableColumns = productionMethod('_workspaceTableColumns', 'table', d);
    const resize = productionMethod('_workspaceTableSize', 'metric, value', d);
    resize.call(harness, 'columnWidth', 2.5);
    const widths = [...table.querySelectorAll('col')].map((c) => parseFloat(c.style.width));
    assert.equal(table.style.width, '100%');
    assert.equal(widths[0], 40);
    assert(Math.abs(widths.reduce((a, b) => a + b, 0) - 100) < 0.0001);
    assert.equal(d.activeElement, input);
    resize.call(harness, 'tableWidth', 75);
    assert.equal(table.style.width, '75%');
    resize.call(harness, 'rowHeight', 36);
    assert.equal(cell.parentElement.style.height, '36pt');
    resize.call(harness, 'rowHeight', 0);
    assert.equal(cell.parentElement.style.height, '');
    assert.equal(undo, 4);
    const before = table.outerHTML;
    resize.call(harness, 'tableWidth', 101);
    assert.equal(table.outerHTML, before);
    assert.equal(undo, 4);
});
test('table focus after a sidebar structure edit never scrolls the page', () => {
    const d = documentFor('<table><tr><td>A</td></tr></table>'),
        root = d.querySelector('main'),
        cell = d.querySelector('td');
    cell.scrollIntoView = () => {
        throw Error('unexpected page jump');
    };
    const harness = { _surfaceOwning: () => root, _bodyCanvas: () => root, _setActiveSurface() {}, _recordCaret() {} };
    productionMethod('_focusWorkspaceBlock', 'block, selectContents = false, reveal = true', d).call(
        harness,
        cell,
        false,
        false
    );
    assert.equal(d.defaultView.getSelection().anchorNode, cell);
});
test('@ opens insert commands at a word boundary while email addresses and old triggers remain ordinary text', () => {
    const d = documentFor('<p></p>'),
        root = d.querySelector('main'),
        text = d.createTextNode('');
    root.firstChild.append(text);
    d.defaultView.Range.prototype.getBoundingClientRect = () => ({ width: 1, height: 16 });
    let opened = 0;
    const harness = {
        template: { querySelector: () => root },
        _surfaceContaining: () => root,
        _renderSlashMenu() {
            opened++;
        },
        _closeSlashMenu() {}
    };
    const open = productionMethod('_maybeOpenSlashMenu', '', d);
    for (const value of ['@table', 'Hello @heading', 'email@example.com', '`table', '[table']) {
        text.nodeValue = value;
        const r = d.createRange();
        r.setStart(text, text.length);
        r.collapse(true);
        const selection = d.defaultView.getSelection();
        selection.removeAllRanges();
        selection.addRange(r);
        open.call(harness);
    }
    assert.equal(opened, 2);
});

test('inserting a table on an empty new page leaves a normal paragraph below it', () => {
    const d = documentFor('<p><br></p>'),
        root = d.querySelector('main'),
        r = d.createRange();
    r.setStart(root.firstChild, 0);
    r.collapse(true);
    d.defaultView.getSelection().addRange(r);
    const harness = {
        useModernDesigner: true,
        _insertTargetSurface: () => root,
        _pushUndo() {},
        _pillifyTags() {},
        _isInCanvas: (node, surface) => surface.contains(node),
        _parkCaretAfter() {},
        _focusWorkspaceBlock() {}
    };
    productionMethod('_insertIntoVisualPage', 'markup', d).call(harness, '<table><tr><td>A</td></tr></table>');
    assert.deepEqual(
        [...root.children].map((e) => e.tagName),
        ['TABLE', 'P']
    );
    assert(root.lastChild.querySelector('br'));
});
test('deleting the last table row leaves an editable destination and clears the old cell', () => {
    const d = documentFor('<style>p{color:navy}</style><table><tr><td>A</td></tr></table>'),
        root = d.querySelector('main'),
        cell = d.querySelector('td');
    let focus;
    const harness = {
        showHtmlBodyVisual: true,
        useModernDesigner: true,
        _caret: { cellEl: cell },
        _pushUndo() {},
        _restoreCaret() {},
        _selectedTableCell: () => cell,
        _surfaceOwning: () => root,
        _clearCellSel() {},
        _focusWorkspaceBlock: (target) => (focus = target)
    };
    productionMethod('handleTableAction', 'event', d).call(harness, {
        currentTarget: { dataset: { taction: 'rowDel' } }
    });
    assert.equal(root.querySelector('table'), null);
    assert(root.querySelector('style'));
    assert.equal(focus.tagName, 'P');
    assert(focus.querySelector('br'));
    assert.equal(harness._caret.cellEl, null);
});

console.log(passed + ' document-editing scenarios passed.');
