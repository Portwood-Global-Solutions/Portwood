#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { startPreview } from './preview.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const args = process.argv.slice(2);
const website = args.includes('--website')
    ? path.resolve(args[args.indexOf('--website') + 1])
    : path.join(root, 'website');
const catalog = JSON.parse(await fs.readFile(path.join(root, 'docs/knowledgebase/catalog.json'), 'utf8'));
const { server, url } = await startPreview({ website, port: 0 });
let browser;
const passed = [];
const check = async (name, fn) => {
    await fn();
    passed.push(name);
    console.log(`PASS ${name}`);
};
try {
    try {
        browser = await chromium.launch({ headless: true, channel: 'chrome' });
    } catch (_) {
        browser = await chromium.launch({ headless: true });
    }
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
    const page = await context.newPage();
    page.setDefaultTimeout(8000);
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await check('homepage loads the local catalog and correct release', async () => {
        await page.goto(url);
        await page.getByRole('heading', { name: 'What would you like to do?', exact: true }).waitFor();
        assert.equal(await page.locator('#pg-release').innerText(), `Portwood ${catalog.product.version}`);
        assert.equal(await page.locator('.pg-task').count(), 6);
    });
    await check('all task articles render, keep merge tags, and have no missing screenshot files', async () => {
        for (const article of catalog.articles) {
            await page.goto(`${url}#${article.slug}`);
            await page.getByRole('heading', { name: article.title, exact: true }).waitFor();
            assert.ok((await page.locator('#pg-prose').innerText()).length > 80, article.slug);
            const broken = await page.locator('#pg-prose img').evaluateAll(async (images) => {
                await Promise.all(
                    images.map((img) => {
                        img.loading = 'eager';
                        return img.decode().catch(() => {});
                    })
                );
                return images.filter((img) => !img.naturalWidth).map((img) => img.src);
            });
            assert.deepEqual(broken, [], article.slug);
        }
        await page.goto(`${url}#first-document`);
        assert.ok((await page.locator('#pg-prose').innerText()).includes('{Name}'));
    });
    await check('legacy GitHub and site anchors resolve', async () => {
        const aliases = catalog.articles.flatMap((a) => (a.aliases || []).map((alias) => [alias, a.title]));
        // Exercise every legacy route, including old double-hyphen headings.
        for (const [alias, title] of aliases) {
            await page.evaluate(
                (hash) =>
                    new Promise((resolve) => {
                        window.addEventListener('hashchange', () => requestAnimationFrame(resolve), { once: true });
                        location.hash = hash;
                    }),
                alias
            );
            await page.getByRole('heading', { name: title, exact: true }).waitFor();
        }
    });
    await check('search matches article content and opens a result', async () => {
        const search = page.getByRole('searchbox', { name: 'Search the Portwood guide', exact: true });
        await search.fill('email verification');
        await page.locator('.pg-result').first().waitFor();
        assert.ok((await page.locator('.pg-result').count()) > 0);
        await page.locator('.pg-result a').first().click();
        await page.locator('#pg-prose').waitFor();
        assert.equal(await search.inputValue(), '');
        await search.fill('zqxvnonexistent');
        await page.getByText('No exact match yet.', { exact: false }).waitFor();
        await page.locator('.pg-overview').click();
        await page.getByRole('heading', { name: 'What would you like to do?', exact: true }).waitFor();
    });
    await check('screenshot zoom opens, closes with Escape, and restores focus', async () => {
        await page.goto(`${url}#first-document`);
        const button = page.locator('.pg-screenshot').first();
        await button.click();
        assert.ok(await page.getByRole('dialog', { name: 'Screenshot enlarged' }).isVisible());
        await page.keyboard.press('Escape');
        assert.equal(await page.getByRole('dialog', { name: 'Screenshot enlarged' }).isVisible(), false);
        assert.ok(await button.evaluate((e) => e === document.activeElement));
    });
    await check('learning paths advance and remember a stable article slug', async () => {
        await page.goto(`${url}?path=first-pdf#first-document`);
        await page.getByRole('button', { name: 'Done, next lesson', exact: true }).click();
        await page.getByRole('heading', { name: 'Add Portwood to a record page', exact: true }).waitFor();
        const saved = await page.evaluate(() => JSON.parse(localStorage.getItem('portwood-guide-progress-v1')));
        assert.ok(saved.done.includes('first-document'));
        assert.equal(saved.last.slug, 'add-to-record-page');
    });
    await check('raw Markdown compatibility and return navigation work', async () => {
        await page.goto(`${url}?raw=1`);
        await page.locator('#pg-raw-text').filter({ hasText: '# Portwood Knowledgebase' }).waitFor();
        assert.ok((await page.locator('#pg-raw-text').innerText()).includes(catalog.product.packageId));
        await page.locator('[data-article="first-document"]').click();
        await page.getByRole('heading', { name: 'Make your first document', exact: true }).waitFor();
    });
    await check('phone and tablet layouts have no page overflow and a working topic menu', async () => {
        for (const width of [390, 768, 1024]) {
            await page.setViewportSize({ width, height: 900 });
            for (const slug of ['sign-uploaded-pdf', 'site-salesforce', 'merge-tags', 'tag-charts', 'apex-surface']) {
                await page.goto(`${url}#${slug}`);
                await page.locator('#pg-prose').waitFor();
                assert.ok(
                    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1),
                    `${width}px overflow in ${slug}`
                );
            }
        }
        await page.setViewportSize({ width: 390, height: 844 });
        const menu = page.getByRole('button', { name: 'Browse topics', exact: true });
        await menu.click();
        assert.equal(await menu.getAttribute('aria-expanded'), 'true');
        await page.locator('#pg-nav details').first().locator('summary').click();
        await page.locator('#pg-nav details').first().locator('summary').click();
        await page.locator('[data-article="welcome"]').click();
        await page.getByRole('heading', { name: 'Welcome to Portwood', exact: true }).waitFor();
        assert.equal(await menu.getAttribute('aria-expanded'), 'false');
    });
    await check('print keeps the lesson visible', async () => {
        await page.emulateMedia({ media: 'print' });
        assert.ok(await page.locator('.pg-main').isVisible());
        assert.equal(await page.locator('.pg-nav').isVisible(), false);
        await page.emulateMedia({ media: 'screen' });
    });
    await check('catalog HTML cannot execute scripts or event handlers', async () => {
        const adversarial = structuredClone(catalog);
        adversarial.articles[0].body +=
            '\n<script>window.__guideInjected=true</script><img src="javascript:alert(1)" onerror="window.__guideInjected=true"><a href="javascript:alert(1)">Unsafe example</a>';
        await page.route('**/source/docs/knowledgebase/catalog.json', (route) => route.fulfill({ json: adversarial }));
        await page.goto(`${url}#${adversarial.articles[0].slug}`);
        await page.locator('#pg-prose').waitFor();
        assert.equal(await page.evaluate(() => Boolean(window.__guideInjected)), false);
        assert.equal(
            await page.locator('#pg-prose script, #pg-prose [onerror], #pg-prose [href^="javascript:"]').count(),
            0
        );
        await page.unroute('**/source/docs/knowledgebase/catalog.json');
    });
    await check('load failure offers a readable fallback and retry', async () => {
        await page.route('**/source/docs/knowledgebase/catalog.json', (route) =>
            route.fulfill({ status: 503, body: 'Unavailable' })
        );
        await page.goto(url);
        await page.getByRole('heading', { name: 'The guide could not load.', exact: true }).waitFor();
        assert.ok(
            (await page.getByRole('link', { name: 'Read the guide', exact: true }).getAttribute('href')).endsWith(
                'UserGuide.md'
            )
        );
        await page.unroute('**/source/docs/knowledgebase/catalog.json');
        await page.getByRole('button', { name: 'Try again', exact: true }).click();
        await page.getByRole('heading', { name: 'What would you like to do?', exact: true }).waitFor();
    });
    assert.deepEqual(errors, []);
    console.log(
        `${passed.length} reader checks passed; ${catalog.articles.length} articles and all legacy routes exercised.`
    );
} finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
}
