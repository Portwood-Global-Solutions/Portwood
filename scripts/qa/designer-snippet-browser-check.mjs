/** Actual keyboard/mouse checks for @ snippet insertion and reversible canvas previews. */
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { launch, login, openTab } from './lib/browser.mjs';
import { runAnonymous, debugMap } from './lib/sf.mjs';

const orgIndex = process.argv.indexOf('--org');
const org = orgIndex >= 0 ? process.argv[orgIndex + 1] : 'portwood-proposal';
const output = new URL('../../output/designer-snippet-ux/', import.meta.url);
await mkdir(output, { recursive: true });
const stamp = Date.now();
const key = 'qa-snippet-' + stamp;
const name = 'QA Snippet Preview ' + stamp;
const apexString = (value) => "'" + value.replaceAll('\\', '\\\\').replaceAll("'", "\\'") + "'";
const save = (assetKey, label, html) =>
    `DocGenSnippetController.saveSnippet(null, ${apexString(label)}, ${apexString(assetKey)}, 'QA snippets', ${apexString(html)}, null, true)`;
const fixture = debugMap(
    await runAnonymous(
        org,
        [
            save(key + '-clause', name + ' Clause', '<p>Payment within <strong>30 days</strong>.</p>') + ';',
            'Map<String,Object> main = ' +
                save(
                    key,
                    name,
                    '<h2>Payment terms</h2>{%snippet:' +
                        key +
                        '-clause}<table style="width:100%;border-collapse:collapse"><tr><td style="border:1px solid #ccc;padding:8pt">Delivery</td><td style="border:1px solid #ccc;padding:8pt">Included</td></tr></table>'
                ) +
                ';',
            save(
                key + '-alt',
                name + ' Alternative',
                '<h2>Alternative terms</h2><p>Payment within <em>45 days</em>.</p>'
            ) + ';',
            "System.debug('SNIPPET_ID=' + main.get('id'));"
        ].join('\n')
    )
);
assert(fixture.SNIPPET_ID, 'Development snippet fixtures must be created successfully.');
const { browser, page, consoleErrors } = await launch({ width: 1500, height: 1000 });
page.setDefaultTimeout(15000);
const results = [];
const check = async (label, run) => {
    try {
        await run();
        results.push({ label, ok: true });
        console.log('PASS ' + label);
    } catch (error) {
        results.push({ label, ok: false, error: error.message });
        throw error;
    }
};
try {
    const base = await login(page, org);
    await openTab(page, base, 'DocGen_Template_Manager');
    await page.getByRole('tab', { name: 'Create template', exact: true }).click();
    await page.locator('[role="radio"]').filter({ hasText: 'Designer / Canvas' }).click();
    await page.locator('lightning-radio-group label').filter({ hasText: 'Designer —' }).click();
    await page.getByRole('textbox', { name: 'Template Name', exact: true }).fill(name);
    await page.getByRole('button', { name: 'Create & Open Designer', exact: true }).click();
    const canvas = page.locator('.dg-pv');
    await canvas.waitFor({ state: 'visible', timeout: 60000 });
    const workspace = page.locator('c-doc-gen-designer-workspace');
    const preview = canvas.locator('[data-dg-snippet]');
    const source = page.locator('.dg-html-body-editor');
    await check('@ finds snippets by key and inserts the selected reference at the caret', async () => {
        await page.keyboard.type('Before the terms');
        await page.keyboard.press('Enter');
        await page.keyboard.type('@' + key);
        const menu = page.locator('.dg-slash-menu');
        await menu.waitFor({ state: 'visible' });
        const choice = menu.locator('button[data-snippet-key="' + key + '"]');
        await choice.locator('[data-preview-state="ready"]').waitFor();
        assert.equal(await choice.locator('h2').innerText(), 'Payment terms');
        assert.equal(await choice.locator('strong').innerText(), '30 days');
        assert.equal(await choice.locator('td').count(), 2);
        assert(!(await choice.innerText()).includes(name));
        assert(!(await choice.innerText()).includes('{%snippet:'));
        await page.keyboard.press('ArrowDown');
        assert.equal(await menu.locator('.dg-slash-item_active').getAttribute('data-snippet-key'), key + '-alt');
        await page.keyboard.press('ArrowUp');
        assert.equal(await menu.locator('.dg-slash-item_active').getAttribute('data-snippet-key'), key);
        await page.screenshot({ path: new URL('snippet-menu-preview.png', output).pathname });
        const text = await choice.locator('strong').boundingBox();
        await page.mouse.click(text.x + text.width / 2, text.y + text.height / 2);
        await preview.first().waitFor();
        assert.equal(await preview.first().getAttribute('data-dg-tag'), '{%snippet:' + key + '}');
        assert((await canvas.innerText()).includes('Before the terms'));
        assert(!(await canvas.innerText()).includes('@' + key));
    });
    await check('the canvas shows formatted nested snippet text and tables as one read-only section', async () => {
        assert.equal(await preview.first().getAttribute('contenteditable'), 'false');
        assert.equal(await preview.first().locator('h2').innerText(), 'Payment terms');
        assert.equal(await preview.first().locator('strong').innerText(), '30 days');
        assert.equal(await preview.first().locator('td').count(), 2);
        assert(!(await preview.first().innerText()).includes('{%snippet:'));
        assert.equal(await preview.first().locator('[data-dg-tag]').count(), 0);
    });
    await page.screenshot({ path: new URL('rendered-snippet.png', output).pathname });
    await check('double-click changes the rendered section back to its editable merge tag', async () => {
        await preview.first().locator('strong').dblclick();
        const editing = canvas.locator('[data-dg-tag][contenteditable="true"]');
        await editing.waitFor();
        assert.equal(await editing.innerText(), '{%snippet:' + key + '}');
        assert.equal(await editing.locator('h2,p,table').count(), 0);
        await page.keyboard.type('{%snippet:' + key + '-alt');
        await page.screenshot({ path: new URL('editing-snippet-tag.png', output).pathname });
        await page.keyboard.press('Enter');
        await canvas.locator('[data-dg-snippet="' + key + '-alt"]').waitFor();
        assert.equal(await preview.first().locator('em').innerText(), '45 days');
        await page.keyboard.type(' ordinary wording after the snippet');
        assert(!(await preview.first().innerText()).includes('ordinary wording'));
        assert((await canvas.innerText()).includes('ordinary wording after the snippet'));
    });
    await check('a snippet edit is one Undo step and Redo restores the new rendered section', async () => {
        await workspace.getByRole('button', { name: 'Undo last edit', exact: true }).click();
        assert(!(await canvas.innerText()).includes('ordinary wording after the snippet'));
        await workspace.getByRole('button', { name: 'Undo last edit', exact: true }).click();
        await canvas.locator('[data-dg-snippet="' + key + '"]').waitFor();
        assert.equal(await preview.first().locator('strong').innerText(), '30 days');
        await workspace.getByRole('button', { name: 'Redo last edit', exact: true }).click();
        await canvas.locator('[data-dg-snippet="' + key + '-alt"]').waitFor();
        assert.equal(await preview.first().locator('em').innerText(), '45 days');
    });
    await check('a closing brace restores the preview and subsequent typing stays outside', async () => {
        await preview.first().locator('em').dblclick();
        await page.keyboard.type('{%snippet:' + key + '-alt} after closing brace');
        await preview.first().waitFor();
        assert.equal(await preview.first().locator('em').innerText(), '45 days');
        assert(!(await preview.first().innerText()).includes('after closing brace'));
        assert((await canvas.innerText()).includes('after closing brace'));
    });
    await check(
        'source and Save retain only the reference, with no rendered wording or preview attributes',
        async () => {
            await workspace.getByRole('button', { name: 'HTML source', exact: true }).click();
            const html = await source.inputValue();
            assert(html.includes('{%snippet:' + key + '-alt}'));
            assert(html.includes('Before the terms'));
            assert(!html.includes('Alternative terms'));
            assert(!html.includes('45 days'));
            assert(!html.includes('data-dg-snippet'));
            await workspace.getByRole('button', { name: 'Save', exact: true }).click();
            await page.waitForFunction(() => {
                const find = (root) =>
                    [...root.querySelectorAll('button')].some(
                        (el) => el.textContent.trim() === 'Save' && el.disabled
                    ) || [...root.querySelectorAll('*')].some((el) => el.shadowRoot && find(el.shadowRoot));
                return find(document);
            });
            const saved = debugMap(
                await runAnonymous(
                    org,
                    [
                        'String templateName = ' + apexString(name) + ';',
                        'Id templateId = [SELECT Id FROM DocGen_Template__c WHERE Name = :templateName LIMIT 1].Id;',
                        'String html = DocGenController.getHtmlTemplateBody(templateId);',
                        'System.assert(html.contains(' + apexString('{%snippet:' + key + '-alt}') + '));',
                        "System.assert(!html.contains('45 days') && !html.contains('data-dg-snippet'));",
                        "System.debug('SAVED_REFERENCE=true');"
                    ].join('\n')
                )
            );
            assert.equal(saved.SAVED_REFERENCE, 'true', 'The saved Salesforce file contains the reference only.');
            await workspace.getByRole('button', { name: 'Visual editor', exact: true }).click();
            await preview.first().waitFor();
            assert.equal(await preview.first().locator('em').innerText(), '45 days');
        }
    );
    await check('inline snippets survive source round-trips without breaking the surrounding paragraph', async () => {
        await workspace.getByRole('button', { name: 'HTML source', exact: true }).click();
        const html =
            '<!doctype html><html><head><style>@page{size:Letter;margin:.75in}body{font-family:Helvetica;font-size:11pt}</style></head><body><p>Prefix {%snippet:' +
            key +
            '} suffix</p></body></html>';
        await source.fill(html);
        await workspace.getByRole('button', { name: 'Visual editor', exact: true }).click();
        await preview.first().waitFor();
        await canvas.locator('p').last().click();
        await workspace.getByRole('button', { name: 'HTML source', exact: true }).click();
        const after = await source.inputValue();
        assert(after.includes('<p>Prefix {%snippet:' + key + '} suffix</p>'));
        assert(!after.includes('Payment within'));
        await workspace.getByRole('button', { name: 'Visual editor', exact: true }).click();
    });
    await check('missing snippets keep their visible editable tag', async () => {
        await workspace.getByRole('button', { name: 'HTML source', exact: true }).click();
        await source.fill('<html><body><p>{%snippet:qa-missing-' + stamp + '}</p></body></html>');
        await workspace.getByRole('button', { name: 'Visual editor', exact: true }).click();
        const pill = canvas.locator('[data-dg-tag]');
        await page.waitForFunction(() => {
            const find = (root) =>
                [...root.querySelectorAll('[title]')].some((el) => el.title.startsWith('Preview unavailable:')) ||
                [...root.querySelectorAll('*')].some((el) => el.shadowRoot && find(el.shadowRoot));
            return find(document);
        });
        assert.equal(await pill.innerText(), '{%snippet:qa-missing-' + stamp + '}');
        assert.equal(await pill.getAttribute('contenteditable'), 'false');
        await pill.dblclick();
        assert.equal(await pill.getAttribute('contenteditable'), 'true');
        await page.keyboard.press('Escape');
    });
    assert.equal(consoleErrors.filter((message) => message.startsWith('pageerror:')).length, 0);
} catch (error) {
    console.log('FAIL ' + error.message);
    console.log(
        await page
            .locator('.dg-pv')
            .evaluate((el) => ({ text: el.innerText, html: el.innerHTML }))
            .catch(() => null)
    );
    await page.screenshot({ path: new URL('failure.png', output).pathname }).catch(() => {});
    process.exitCode = 1;
} finally {
    await writeFile(
        new URL('report.json', output),
        JSON.stringify({ org, name, key, results, consoleErrors }, null, 2)
    );
    await browser.close();
}
