import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { launch, login, openTab } from './lib/browser.mjs';
import { runAnonymous, debugMap } from './lib/sf.mjs';

const orgIndex = process.argv.indexOf('--org');
const org = orgIndex >= 0 ? process.argv[orgIndex + 1] : 'portwood-proposal';
const output = new URL('../../output/assets-previews/', import.meta.url);
await mkdir(output, { recursive: true });
const stamp = Date.now(),
    key = 'qa-assets-' + stamp,
    name = 'QA Assets Preview ' + stamp;
const quote = (text) => "'" + text.replaceAll('\\', '\\\\').replaceAll("'", "\\'") + "'";
const fixture = debugMap(
    await runAnonymous(
        org,
        [
            'Map<String,Object> active = DocGenSnippetController.saveSnippet(null, ' +
                quote(name) +
                ', ' +
                quote(key) +
                ', \'QA previews\', \'<h2>Payment terms</h2><p>Payment within <strong>30 days</strong>.</p><table style="width:100%;border-collapse:collapse"><tr><td style="padding:8px;border:1px solid #ccc">Delivery</td><td style="padding:8px;border:1px solid #ccc">Included</td></tr></table>\', null, true);',
            'Map<String,Object> inactive = DocGenSnippetController.saveSnippet(null, ' +
                quote(name + ' Inactive') +
                ', ' +
                quote(key + '-inactive') +
                ", 'QA previews', '<h2>Inactive terms</h2><p>Draft clause in <em>italics</em>.</p>', null, false);",
            "System.debug('ACTIVE_ID=' + active.get('id'));",
            "System.debug('INACTIVE_ID=' + inactive.get('id'));",
            'List<Map<String,Object>> fonts = DocGenFontController.getFontFaces();',
            'Map<String,Object> scriptFace, boldFace;',
            "for (Map<String,Object> face : fonts) { if (face.get('previewUrl') == null) continue; if (scriptFace == null || ((String)face.get('label')).toLowerCase().contains('parisienne')) scriptFace = face; if (((String)face.get('label')).toLowerCase().contains('barlow') && String.valueOf(face.get('weight')) == '700') boldFace = face; }",
            "System.debug('FONT=' + JSON.serialize(scriptFace));",
            "System.debug('BOLD_FONT=' + JSON.serialize(boldFace));"
        ].join('\n')
    )
);
assert(fixture.ACTIVE_ID && fixture.INACTIVE_ID, 'Create development snippets before testing the library.');
const font = JSON.parse(fixture.FONT),
    boldFont = JSON.parse(fixture.BOLD_FONT);
assert(font && boldFont, 'The development org must have actual registered font Files to verify their previews.');
const { browser, page, consoleErrors } = await launch({ width: 1500, height: 1100 });
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
    await openTab(page, base, 'DocGen_Command_Hub');
    await page.getByRole('button', { name: 'Assets', exact: true }).click();
    const assets = page.locator('c-doc-gen-assets');
    await assets.waitFor();
    await assets.getByRole('tab', { name: 'Terms & snippets', exact: true }).click();
    const snippets = assets.locator('c-doc-gen-snippet-assets');
    const find = snippets.getByRole('searchbox', { name: 'Find shared content', exact: true });
    const entry = snippets.locator('button.entry[data-id="' + fixture.ACTIVE_ID + '"]');
    const inactiveEntry = snippets.locator('button.entry[data-id="' + fixture.INACTIVE_ID + '"]');
    await check('snippet search results show formatted HTML and tables before selection', async () => {
        await find.fill(name);
        await find.press('Tab');
        await entry.locator('[data-preview-state="ready"]').waitFor();
        assert.equal(await entry.locator('strong').first().innerText(), '30 days');
        assert.equal(await entry.locator('td').count(), 2);
        assert.equal(await entry.locator('code').count(), 0);
        assert(!(await entry.innerText()).includes('{%snippet:'));
    });
    await check('inactive snippets also show their latest saved content', async () => {
        await inactiveEntry.locator('[data-preview-state="ready"]').waitFor();
        assert.equal(await inactiveEntry.locator('em').innerText(), 'italics');
        assert((await inactiveEntry.innerText()).includes('Inactive'));
    });
    await page.screenshot({ path: new URL('snippet-results.png', output).pathname });
    await check('clicking rendered snippet content opens its existing editor', async () => {
        const box = await entry.locator('h2').boundingBox();
        await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
        const input = snippets.getByRole('textbox', { name: 'Name', exact: true });
        await input.waitFor();
        assert.equal(await input.inputValue(), name);
    });
    await check('saving a revision updates the result preview without losing search or selection', async () => {
        await snippets.getByRole('button', { name: 'HTML source', exact: true }).click();
        await snippets
            .getByRole('textbox', { name: 'HTML fragment', exact: true })
            .fill('<h2>Revised payment terms</h2><p>Payment within <strong>45 days</strong>.</p>');
        await snippets.getByRole('button', { name: 'Save new revision', exact: true }).click();
        await entry.getByText('45 days', { exact: true }).waitFor();
        assert.equal(await find.inputValue(), name);
        assert.equal(await snippets.getByRole('textbox', { name: 'Name', exact: true }).inputValue(), name);
        assert(!(await entry.innerText()).includes('30 days'));
    });
    await assets.getByRole('tab', { name: 'Fonts', exact: true }).click();
    const fonts = assets.locator('c-doc-gen-font-assets');
    const fontSearch = fonts.getByPlaceholder('Search fonts by name or file');
    const waitForLoadedFace = async (key) => {
        const sample = fonts.locator('button.face[data-key="' + key + '"] .face-sample');
        await sample.waitFor();
        for (let attempt = 0; attempt < 80; attempt++) {
            const loaded = await sample.evaluate((element) => {
                const family = getComputedStyle(element)
                    .fontFamily.split(',')[0]
                    .replaceAll('"', '')
                    .replaceAll("'", '');
                return [...document.fonts].some(
                    (face) => face.family.replaceAll('"', '').replaceAll("'", '') === family && face.status === 'loaded'
                );
            });
            if (loaded) return sample;
            await page.waitForTimeout(150);
        }
        throw new Error('The font sample must use its downloaded, exact-revision font File.');
    };
    await check('font search results load the actual font and its exact weight', async () => {
        await fontSearch.fill(boldFont.family);
        await fontSearch.press('Tab');
        const sample = await waitForLoadedFace(boldFont.key);
        assert.equal(await sample.evaluate((el) => getComputedStyle(el).fontWeight), '700');
        assert((await sample.evaluate((el) => getComputedStyle(el).fontFamily)).includes(boldFont.previewFamily));
        assert((await sample.innerText()).includes('The quick brown fox'));
    });
    await page.screenshot({ path: new URL('font-results-bold.png', output).pathname });
    await check('searching another font shows its own real sample and keeps the normal specimen controls', async () => {
        await fontSearch.fill(font.family);
        await fontSearch.press('Tab');
        const sample = await waitForLoadedFace(font.key);
        assert((await sample.evaluate((el) => getComputedStyle(el).fontFamily)).includes(font.previewFamily));
        assert.equal(
            await fonts.getByRole('textbox', { name: 'Try your text in the browser', exact: true }).count(),
            1
        );
        assert.equal(await fonts.getByRole('button', { name: 'Copy font tag', exact: true }).count(), 1);
    });
    await page.screenshot({ path: new URL('font-results-script.png', output).pathname });
    await check('empty font searches show no matches without a runtime error', async () => {
        await fontSearch.fill('no-font-' + stamp);
        await fontSearch.press('Tab');
        await fonts.locator('.no-matches').waitFor();
        assert.equal(await fonts.locator('button.face').count(), 0);
        assert.equal(consoleErrors.filter((error) => error.startsWith('pageerror:')).length, 0);
    });
} catch (error) {
    console.log('FAIL ' + error.message);
    await page.screenshot({ path: new URL('failure.png', output).pathname }).catch(() => {});
    console.log('Visible messages:', await page.locator('c-doc-gen-assets .error').allTextContents());
    process.exitCode = 1;
} finally {
    await writeFile(new URL('report.json', output), JSON.stringify({ org, name, results, consoleErrors }, null, 2));
    await browser.close();
}
