import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { launch, login, openTab } from './lib/browser.mjs';
const org = process.argv[2] || 'portwood-proposal';
const output = new URL('../../output/brand-live-demo/', import.meta.url);
await mkdir(output, { recursive: true });
const { browser, page, consoleErrors } = await launch({ width: 1600, height: 1050 });
let checks = 0;
try {
    const base = await login(page, org);
    await openTab(page, base, 'DocGen_Command_Hub');
    await page.getByRole('button', { name: 'Brands', exact: true }).click();
    const search = page.getByRole('searchbox', { name: 'Search brands', exact: true });
    await search.waitFor({ timeout: 60000 });
    await search.fill('no-such-brand-live-qa');
    await page.getByText('No matching brands. Add a Brand or try another search.', { exact: true }).waitFor();
    checks++;
    await search.fill('Cedar Community - live theme');
    const card = page.locator('button.brand-row').filter({ hasText: 'Cedar Community - live theme' });
    await card.waitFor({ timeout: 60000 });
    assert.equal(await page.locator('button.brand-row').count(), 1);
    checks++;
    await card.click();
    const theme = page.getByRole('combobox', { name: 'Live Salesforce theme', exact: true });
    await theme.waitFor();
    await theme.click();
    await page.getByRole('option', { name: 'Use Brand colors and images', exact: true }).click();
    assert.match(await page.locator('.pp-action').getAttribute('style'), /#990099/i);
    checks++;
    await theme.click();
    await page.getByRole('option', { name: 'Cedar Community — live theme demo', exact: true }).click();
    const style = await page.locator('.pp-action').getAttribute('style');
    assert.match(style, /#(227548|2574a9)/i);
    checks++;
    await page.getByRole('button', { name: 'Save Changes', exact: true }).click();
    await page.getByText('Your signing experience', { exact: true }).waitFor({ timeout: 60000 });
    checks++;
    await card.click();
    assert.equal(
        (await theme.getAttribute('data-value')) || (await theme.inputValue().catch(() => '')),
        'Cedar Community — live theme demo'
    );
    checks++;
    await page.screenshot({ path: new URL('brand-library-desktop.png', output).pathname, fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    // Salesforce's desktop navigation has its own minimum width. Constrain the
    // actual LWC to a phone width and measure its content independently.
    const component = page.locator('c-doc-gen-brands');
    await component.evaluate((el) => {
        el.style.display = 'block';
        el.style.width = '360px';
    });
    assert.equal(await page.locator('.brands-workspace').evaluate((el) => el.scrollWidth <= el.clientWidth), true);
    checks++;
    await component.screenshot({ path: new URL('brand-library-mobile.png', output).pathname });
    const errors = consoleErrors.filter((e) => e.startsWith('pageerror:'));
    assert.deepEqual(errors, []);
    checks++;
    await writeFile(new URL('library-verification.json', output), JSON.stringify({ checks, errors }, null, 2));
    console.log(`PASS: ${checks} native Brand library checks.`);
} finally {
    await browser.close();
}
