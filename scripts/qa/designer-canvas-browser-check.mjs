/** Real keyboard/mouse regression check for the modern Designer. Creates a QA template in a development org. */
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { launch, login, openTab } from './lib/browser.mjs';

const orgIndex = process.argv.indexOf('--org');
const org = orgIndex >= 0 ? process.argv[orgIndex + 1] : 'portwood-proposal';
const output = new URL('../../output/designer-canvas-ux/', import.meta.url);
await mkdir(output, { recursive: true });
const { browser, page, consoleErrors } = await launch({ width: 1500, height: 1000 });
page.setDefaultTimeout(15000);
const results = [];
const check = async (name, fn) => {
    try {
        await fn();
        results.push({ name, ok: true });
        console.log('PASS ' + name);
    } catch (error) {
        results.push({ name, ok: false, error: error.message });
        console.log('FAIL ' + name + ': ' + error.message);
        throw error;
    }
};
const templateName = 'QA Canvas UX ' + new Date().toISOString().slice(0, 19).replaceAll(':', '-');
try {
    const base = await login(page, org);
    await openTab(page, base, 'DocGen_Template_Manager');
    await page.getByRole('tab', { name: 'Create template', exact: true }).click();
    await page.locator('[role="radio"]').filter({ hasText: 'Designer / Canvas' }).click();
    await page.locator('lightning-radio-group label').filter({ hasText: 'Designer —' }).click();
    await page.getByRole('textbox', { name: 'Template Name', exact: true }).fill(templateName);
    await page.getByRole('button', { name: 'Create & Open Designer', exact: true }).click();
    const canvas = page.locator('.dg-pv');
    await canvas.waitFor({ state: 'visible', timeout: 60000 });
    const workspace = page.locator('c-doc-gen-designer-workspace');
    const scroll = page.locator('.dg-designer-canvas-col');
    if (!process.argv.includes('--pills-only')) {
        await check('new documents start blank and ready to type', async () => {
            assert.equal((await canvas.innerText()).trim(), '');
            await page.keyboard.type('Proposal for our customer');
            assert((await canvas.innerText()).includes('Proposal for our customer'));
        });
        await check('double-click selects a word and right-sidebar Bold formats that selection', async () => {
            await canvas
                .locator('p')
                .first()
                .dblclick({ position: { x: 28, y: 8 } });
            assert.equal((await page.evaluate(() => getSelection().toString())).trim(), 'Proposal');
            await workspace.getByRole('button', { name: 'Bold', exact: true }).click();
            await canvas.locator('b,strong,span[style*="font-weight"]').first().waitFor();
            assert(
                await canvas
                    .locator('p')
                    .first()
                    .evaluate((e) =>
                        [...e.querySelectorAll('*')].some(
                            (el) => el.textContent === 'Proposal' && Number(getComputedStyle(el).fontWeight) >= 600
                        )
                    )
            );
        });
        await check('@table opens the insert menu and Enter inserts at the caret', async () => {
            await canvas.locator('p').first().click();
            await page.keyboard.press('End');
            await page.keyboard.type(' @table');
            await page.locator('.dg-slash-menu').waitFor({ state: 'visible' });
            await page.keyboard.press('Enter');
            await canvas.locator('table').waitFor();
            assert(!(await canvas.innerText()).includes('@table'));
        });
        const table = canvas.locator('table');
        await table.locator('tbody td').first().click();
        await page.keyboard.type('Consulting services');
        await check('double-click in a table selects native text', async () => {
            await table
                .locator('tbody td')
                .first()
                .dblclick({ position: { x: 45, y: 13 } });
            assert.equal((await page.evaluate(() => getSelection().toString())).trim(), 'Consulting');
        });
        await check('table width applies without moving the table or stealing sidebar focus', async () => {
            const before = await table.boundingBox(),
                top = await scroll.evaluate((e) => e.scrollTop);
            await workspace.getByRole('spinbutton', { name: 'Table width percent', exact: true }).fill('75');
            await page.keyboard.press('Tab');
            const after = await table.boundingBox();
            assert(Math.abs(after.width / before.width - 0.75) < 0.02);
            assert(Math.abs(after.y - before.y) < 1);
            assert.equal(await scroll.evaluate((e) => e.scrollTop), top);
            assert(
                await workspace
                    .getByRole('spinbutton', { name: 'Selected column width in inches', exact: true })
                    .evaluate((e) => e === e.getRootNode().activeElement)
            );
        });
        await check('column sizing preserves the table footprint', async () => {
            const before = await table.boundingBox();
            await workspace
                .getByRole('spinbutton', { name: 'Selected column width in inches', exact: true })
                .fill('2.5');
            await page.keyboard.press('Tab');
            const after = await table.boundingBox();
            assert(Math.abs(after.width - before.width) < 1);
            assert(Math.abs(after.y - before.y) < 1);
        });
        await check('row minimum height targets the selected row', async () => {
            await workspace
                .getByRole('spinbutton', { name: 'Selected row minimum height in points', exact: true })
                .fill('40');
            await page.keyboard.press('Tab');
            assert.equal(
                await table
                    .locator('tbody tr')
                    .first()
                    .evaluate((e) => e.style.height),
                '40pt'
            );
        });
        await check('adding columns and rows keeps the table in place', async () => {
            const before = await table.boundingBox();
            await workspace.getByRole('button', { name: 'Column right', exact: true }).click();
            assert.equal(await table.locator('thead th').count(), 4);
            const after = await table.boundingBox();
            assert(Math.abs(after.width - before.width) < 1);
            assert(Math.abs(after.y - before.y) < 1);
            await workspace.getByRole('button', { name: 'Row below', exact: true }).click();
            assert.equal(await table.locator('tr').count(), 4);
            assert(Math.abs((await table.boundingBox()).y - before.y) < 1);
        });
        await check('Undo and Redo restore the inserted row', async () => {
            await workspace.getByRole('button', { name: 'Undo last edit', exact: true }).click();
            assert.equal(await table.locator('tr').count(), 3);
            assert.equal(
                await workspace.locator('.notice-error').count(),
                0,
                (await workspace.locator('.notice-error').allTextContents()).join(' ')
            );
            await workspace.getByRole('button', { name: 'Redo last edit', exact: true }).click();
            assert.equal(await table.locator('tr').count(), 4);
        });
        await check('emails and the retired shortcut characters remain ordinary text', async () => {
            await canvas.locator('p').last().click();
            await page.keyboard.press('End');
            await page.keyboard.type(' user@example.com [literal] `literal');
            assert.equal(await page.locator('.dg-slash-menu').count(), 0);
        });
        await check('Shift-click selects cells explicitly', async () => {
            const cells = table.locator('tbody tr').first().locator('td');
            await cells.first().click();
            await cells.nth(1).click({ modifiers: ['Shift'] });
            assert.equal(await table.locator('[data-dg-selcell]').count(), 2);
        });
        await workspace.locator('summary').filter({ hasText: 'Cell and table options' }).click();
        await workspace.getByRole('button', { name: 'Borders, fill and spacing', exact: true }).click();
        const appearance = page.locator('.dg-float-panel');
        const cellStyles = () =>
            table
                .locator('tbody tr')
                .first()
                .locator('td')
                .evaluateAll((cells) =>
                    cells.map((cell) => ({ fill: cell.style.backgroundColor, border: cell.style.borderColor }))
                );
        await check('cell fill remains a draft until Apply, then affects selected cells only', async () => {
            const before = await cellStyles();
            await appearance.getByRole('textbox', { name: 'Cell fill hex', exact: true }).fill('#d9ead3');
            assert.deepEqual(await cellStyles(), before);
            await appearance.getByRole('button', { name: 'Apply cell fill', exact: true }).click();
            const after = await cellStyles();
            assert.equal(after[0].fill, 'rgb(217, 234, 211)');
            assert.equal(after[1].fill, 'rgb(217, 234, 211)');
            assert.equal(after[2].fill, before[2].fill);
        });
        await check('border colour remains a draft until Apply, then affects selected cells only', async () => {
            const before = await cellStyles();
            await appearance.getByRole('textbox', { name: 'Border colour hex', exact: true }).fill('#235fa4');
            assert.deepEqual(await cellStyles(), before);
            await appearance.getByRole('button', { name: 'Apply border colour', exact: true }).click();
            const after = await cellStyles();
            assert.equal(after[0].border, 'rgb(35, 95, 164)');
            assert.equal(after[1].border, 'rgb(35, 95, 164)');
            assert.equal(after[2].border, before[2].border);
            await workspace.getByRole('button', { name: 'Undo last edit', exact: true }).click();
            assert.deepEqual(await cellStyles(), before);
            await workspace.getByRole('button', { name: 'Redo last edit', exact: true }).click();
            assert.deepEqual(await cellStyles(), after);
        });
        await check('Apply reuses the same fill on a different cell without another picker change', async () => {
            await table.locator('tbody tr').first().locator('td').nth(2).click();
            await appearance.getByRole('button', { name: 'Apply cell fill', exact: true }).click();
            assert.equal((await cellStyles())[2].fill, 'rgb(217, 234, 211)');
            await appearance.getByRole('button', { name: 'Clear cell fill', exact: true }).click();
            const after = await cellStyles();
            assert.equal(after[2].fill, '');
            assert.equal(after[0].fill, 'rgb(217, 234, 211)');
        });
        await check('Apply to Row fills the active row only, stays in place and supports Undo/Redo', async () => {
            await table.locator('tbody tr').first().locator('td').nth(1).click();
            const before = await cellStyles();
            const otherRows = () =>
                table.evaluate((el) =>
                    [...el.rows]
                        .filter((row) => row !== el.tBodies[0].rows[0])
                        .map((row) => [...row.cells].map((cell) => cell.style.backgroundColor))
                );
            const otherBefore = await otherRows();
            const position = await table.boundingBox();
            const top = await scroll.evaluate((e) => e.scrollTop);
            await appearance.getByRole('textbox', { name: 'Cell fill hex', exact: true }).fill('#cfe2f3');
            assert.deepEqual(await cellStyles(), before);
            await appearance.getByRole('button', { name: 'Apply cell fill to row', exact: true }).click();
            const after = await cellStyles();
            assert(after.every((cell) => cell.fill === 'rgb(207, 226, 243)'));
            assert.deepEqual(await otherRows(), otherBefore);
            assert(Math.abs((await table.boundingBox()).y - position.y) < 1);
            assert.equal(await scroll.evaluate((e) => e.scrollTop), top);
            await workspace.getByRole('button', { name: 'Undo last edit', exact: true }).click();
            assert.deepEqual(await cellStyles(), before);
            await workspace.getByRole('button', { name: 'Redo last edit', exact: true }).click();
            assert.deepEqual(await cellStyles(), after);
        });
        await check('Apply to Row also fills header cells without changing body cells', async () => {
            const bodyBefore = await cellStyles();
            await table.locator('thead th').nth(1).click();
            await appearance.getByRole('button', { name: 'Apply cell fill to row', exact: true }).click();
            assert(
                await table
                    .locator('thead th')
                    .evaluateAll((cells) => cells.every((cell) => cell.style.backgroundColor === 'rgb(207, 226, 243)'))
            );
            assert.deepEqual(await cellStyles(), bodyBefore);
        });
        await page.screenshot({ path: new URL('table-colour-apply.png', output).pathname });
        await appearance.locator('.dg-float-panel-head button').click();
        await check('sidebar table edits preserve scroll deep in a document, including at 75% zoom', async () => {
            await workspace.getByRole('button', { name: 'HTML source', exact: true }).click();
            const source = page.locator('.dg-html-body-editor');
            const html = await source.inputValue();
            const paragraphs = Array.from(
                { length: 70 },
                (_, i) => '<p>Project detail ' + (i + 1) + ': scope, timing and deliverables.</p>'
            ).join('');
            await source.fill(html.replace(/<table\b/i, paragraphs + '<table'));
            await workspace.getByRole('button', { name: 'Visual editor', exact: true }).click();
            for (const zoom of [null, '75%']) {
                if (zoom)
                    await workspace
                        .getByRole('combobox', { name: 'Document zoom', exact: true })
                        .selectOption({ label: zoom });
                await table.locator('tbody td').first().click();
                const before = await table.boundingBox(),
                    top = await scroll.evaluate((e) => e.scrollTop);
                assert(top > 100, 'The table must actually be below the fold');
                await workspace
                    .getByRole('spinbutton', { name: 'Table width percent', exact: true })
                    .fill(zoom ? '70' : '80');
                await page.keyboard.press('Tab');
                const after = await table.boundingBox();
                assert(Math.abs(after.y - before.y) < 1);
                assert.equal(await scroll.evaluate((e) => e.scrollTop), top);
                await workspace.getByRole('button', { name: 'Column right', exact: true }).click();
                assert(Math.abs((await table.boundingBox()).y - before.y) < 1);
                assert.equal(await scroll.evaluate((e) => e.scrollTop), top);
            }
        });
        await check('saving retains table content, sizes and clean HTML', async () => {
            await workspace.getByRole('button', { name: 'Save', exact: true }).click();
            await workspace.getByRole('button', { name: 'Save', exact: true }).waitFor({ state: 'visible' });
            await page.waitForFunction(() => {
                const find = (root) =>
                    [...root.querySelectorAll('button')].some((e) => e.textContent.trim() === 'Save' && e.disabled) ||
                    [...root.querySelectorAll('*')].some((e) => e.shadowRoot && find(e.shadowRoot));
                return find(document);
            });
            assert((await table.innerText()).includes('Consulting services'));
            assert.equal(await table.evaluate((e) => e.style.width), '70%');
            await workspace.getByRole('button', { name: 'HTML source', exact: true }).click();
            const saved = await page.locator('.dg-html-body-editor').inputValue();
            assert(saved.includes('Consulting services'));
            assert(!saved.includes('data-dg-paint'));
            assert(!saved.includes('data-dg-selcell'));
            await workspace.getByRole('button', { name: 'Visual editor', exact: true }).click();
        });
    }
    await workspace.getByRole('button', { name: 'HTML source', exact: true }).click();
    await page
        .locator('.dg-html-body-editor')
        .fill(
            '<!doctype html><html><head><style>@page{size:Letter;margin:.75in}body{font-family:Helvetica;font-size:11pt}</style></head><body><p>Fields: </p></body></html>'
        );
    await workspace.getByRole('button', { name: 'Visual editor', exact: true }).click();
    await canvas.locator('p').first().click();
    await page.keyboard.press('End');
    const canvasWording = async () => (await canvas.innerText()).replaceAll('\u00a0', ' ').replaceAll('\u200b', '');
    await check('freshly typed fields stop at the closing brace', async () => {
        await page.keyboard.type('{Name} ordinary text');
        const pill = canvas.locator('[data-dg-tag]').first();
        assert.equal(await pill.innerText(), '{Name}');
        assert.equal(await pill.getAttribute('contenteditable'), 'false');
        assert((await canvasWording()).includes('{Name} ordinary text'));
    });
    await check('closing brace ends a purple field edit and subsequent typing is outside', async () => {
        const pill = canvas.locator('[data-dg-tag]').first();
        await pill.dblclick();
        await page.keyboard.type('{Phone} after edit');
        assert.equal(await pill.innerText(), '{Phone}');
        assert.equal(await pill.getAttribute('contenteditable'), 'false');
        assert((await canvasWording()).includes('{Phone} after edit ordinary text'));
        assert.equal(await pill.locator('[data-dg-tag]').count(), 0);
    });
    await check('Enter closes an incomplete field without inserting a paragraph', async () => {
        const pill = canvas.locator('[data-dg-tag]').first();
        const paragraphs = await canvas.locator('p').count();
        await pill.dblclick();
        await page.keyboard.type('Industry');
        await page.keyboard.press('Enter');
        await page.keyboard.type(' after Enter');
        assert.equal(await pill.innerText(), '{Industry}');
        assert.equal(await pill.getAttribute('contenteditable'), 'false');
        assert.equal(await canvas.locator('p').count(), paragraphs);
        assert((await canvasWording()).includes('{Industry} after Enter'));
    });
    await check('an existing closing brace, Arrow Right and Escape all exit the field', async () => {
        const pill = canvas.locator('[data-dg-tag]').first();
        for (const key of ['}', 'ArrowRight', 'Escape']) {
            await pill.dblclick();
            await pill.evaluate((element, key) => {
                const range = document.createRange();
                range.setStart(element.firstChild, element.textContent.length - (key === '}' ? 1 : 0));
                range.collapse(true);
                const selection = window.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
            }, key);
            await page.keyboard.press(key);
            await page.keyboard.type(' outside');
            assert.equal(await pill.innerText(), '{Industry}');
            assert.equal(await pill.getAttribute('contenteditable'), 'false');
        }
    });
    await check('keyboard navigation out of a field clears its editable state', async () => {
        const pill = canvas.locator('[data-dg-tag]').first();
        await pill.dblclick();
        await page.keyboard.press('End');
        await page.keyboard.type(' outside navigation');
        assert.equal(await pill.innerText(), '{Industry}');
        assert.equal(await pill.getAttribute('contenteditable'), 'false');
    });
    await check('green pills finish on closing brace and a field edit undoes in one step', async () => {
        await canvas.locator('p').first().click();
        await page.keyboard.press('End');
        await page.keyboard.type(' {#Contacts}');
        const pill = canvas.locator('[data-dg-tag]').last();
        assert.equal(await pill.innerText(), '{#Contacts}');
        await pill.dblclick();
        await page.keyboard.type('{#Cases}');
        assert.equal(await pill.innerText(), '{#Cases}');
        assert.equal(await pill.getAttribute('contenteditable'), 'false');
        await workspace.getByRole('button', { name: 'Undo last edit', exact: true }).click();
        assert.equal(await pill.innerText(), '{#Contacts}');
        assert.equal(await pill.getAttribute('contenteditable'), 'false');
        await workspace.getByRole('button', { name: 'Redo last edit', exact: true }).click();
        assert.equal(await pill.innerText(), '{#Cases}');
        assert.equal(await pill.getAttribute('contenteditable'), 'false');
        await page.keyboard.type(' outside green');
        assert.equal(await pill.innerText(), '{#Cases}');
        assert((await canvasWording()).includes('{#Cases} outside green'));
    });
    await check('pasted wording after a completed field remains outside its pill', async () => {
        const pill = canvas.locator('[data-dg-tag]').first();
        await pill.dblclick();
        await page.keyboard.insertText('{Name} pasted suffix');
        assert.equal(await pill.innerText(), '{Name}');
        assert.equal(await pill.getAttribute('contenteditable'), 'false');
        assert((await canvasWording()).includes('{Name} pasted suffix'));
    });
    await page.screenshot({ path: new URL('pill-edit-boundaries.png', output).pathname });
    await page.screenshot({ path: new URL('desktop.png', output).pathname });
    await check('no uncaught designer runtime errors', async () => {
        assert.equal(consoleErrors.filter((e) => e.startsWith('pageerror:')).length, 0);
    });
} catch (error) {
    console.log('Browser check failed:', error.message);
    console.log(
        'Canvas state:',
        await page
            .locator('.dg-pv')
            .evaluate((e) => ({
                text: e.innerText,
                html: [...e.children]
                    .filter((x) => x.tagName !== 'STYLE')
                    .map((x) => x.outerHTML)
                    .join('')
            }))
            .catch(() => null)
    );
    console.log('Designer messages:', await page.locator('c-doc-gen-designer-workspace .notice').allTextContents());
    await page.screenshot({ path: new URL('failure.png', output).pathname }).catch(() => {});
    process.exitCode = 1;
} finally {
    await writeFile(
        new URL('report.json', output),
        JSON.stringify({ org, templateName, results, consoleErrors }, null, 2)
    );
    await browser.close();
}
