#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { startPreview } from './preview.mjs';
import { markdownTables } from './markdown-tables.mjs';

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
    await check('homepage opens setup and the support version check', async () => {
        await page.goto(url);
        await page.getByRole('heading', { name: 'What would you like to do?', exact: true }).waitFor();
        await page.locator('.pg-task[href="#install-portwood"]').waitFor();
        await page.getByRole('link', { name: 'Check my installed version' }).click();
        assert.ok((await page.locator('#pg-prose').innerText()).includes(catalog.product.version));
        await page.goto(url);
        await page.getByRole('heading', { name: 'What would you like to do?' }).waitFor();
        assert.equal(await page.locator('.pg-task').count(), 6);
    });
    await check('license guidance covers public guests, signed-in signers, and the enterprise quote', async () => {
        await page.goto(url);
        await page.getByRole('link', { name: 'Who needs a license?', exact: true }).click();
        await page.getByRole('heading', { name: 'Who needs a Portwood license?', exact: true }).waitFor();
        const article = page.locator('#pg-prose');
        const guest = article.getByRole('row').filter({ hasText: 'A customer opens a public signing link' });
        assert.match(await guest.innerText(), /one Portwood user license to that site’s guest user/);
        assert.match(await guest.innerText(), /Each recipient gets their own private signing link/);
        const signedIn = article.getByRole('row').filter({ hasText: 'signs using their login' });
        assert.match(await signedIn.innerText(), /Portwood site license required/);
        assert.match(await signedIn.innerText(), /specific Screen Flow/);
        assert.match(await signedIn.innerText(), /Portwood Portal Signer/);
        const quote = article.getByRole('link', { name: 'Request a site-license quote', exact: true });
        assert.equal(await quote.getAttribute('href'), 'https://calendar.app.google/HJLhcSFRFDoqxXEM9');
        assert.equal(await article.getByRole('img').count(), 3);
        assert.match(await article.innerText(), /Setup → Company Information/);
        await page.goto(`${url}#install-portwood`);
        await page.getByRole('link', { name: 'See who needs a license, including guests and portal signers' }).click();
        await page.getByRole('heading', { name: 'Who needs a Portwood license?', exact: true }).waitFor();
        assert.equal(catalog.learningPaths.find((path) => path.id === 'team-setup').articles[0], 'user-licenses');
    });
    await check('design studio cards open their recipes and section links move keyboard focus', async () => {
        await page.goto(url);
        await page.locator('.pg-studio a').first().waitFor();
        for (const card of catalog.home.showcase) {
            assert.equal(await page.locator(`.pg-studio a[href="#${card.slug}"] img`).getAttribute('alt'), card.alt);
        }
        await page.locator('.pg-studio a[href="#cpq-quote"]').click();
        await page.getByText('In this lesson', { exact: true }).click();
        const jump = page.getByRole('link', { name: 'Send this exact quote for signature', exact: true });
        await jump.focus();
        await page.keyboard.press('Enter');
        await page.waitForFunction(() => document.activeElement?.textContent === 'Send this exact quote for signature');
        assert.equal(await page.locator(':focus').evaluate((node) => node.tagName), 'H2');
        await page.keyboard.press('Tab');
        assert.match(await page.locator(':focus').getAttribute('href'), /#sign-uploaded-pdf$/);
    });
    await check('all task articles render, keep merge tags, and have no missing screenshot files', async () => {
        for (const article of catalog.articles) {
            await page.goto(`${url}#${article.slug}`);
            await page.getByRole('heading', { name: article.title, exact: true }).waitFor();
            assert.ok((await page.locator('#pg-prose').innerText()).length > 80, article.slug);
            const expected = markdownTables(article.body);
            assert.deepEqual(expected.errors, [], article.slug);
            const tables = page.locator('#pg-prose table');
            assert.equal(
                await tables.count(),
                expected.tables.length,
                `${article.slug}: Markdown tables must render as tables`
            );
            for (let i = 0; i < expected.tables.length; i++) {
                assert.equal(
                    await tables.nth(i).locator('thead th').count(),
                    expected.tables[i].columns,
                    `${article.slug}: table header columns`
                );
                assert.equal(
                    await tables.nth(i).locator('tbody tr').count(),
                    expected.tables[i].rows,
                    `${article.slug}: table data rows`
                );
            }
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
        await page.goto(`${url}#merge-tags`);
        await page.getByRole('heading', { name: 'Find the right merge tag', exact: true }).waitFor();
        assert.equal(await page.locator('#pg-prose table').first().locator('thead th').count(), 3);
        assert.ok((await page.locator('#pg-prose table').first().innerText()).includes('{?poNumber|N/A}'));
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
    await check('signers and admins can follow illustrated steps without opening a project file', async () => {
        const routes = [
            ['event-signing-journey', 'sign-prepare', 'sign-return', 'sign-verify', 'signer-enter-signature', 'signer-consent', 'sign-pending'],
            ['signing-handoff-setup', 'receipt-setup', 'event-definition'],
            ['signing-events', 'trigger-event', 'assign-signer', 'signer-inputs', 'receipt-fields'],
            ['signing-site-handoff', 'publish-event', 'read-receipt', 'find-navigation', 'open-signing-page', 'host-palette', 'host-selected'],
            ['document-studio', 'sample-select', 'sample-file', 'choose-json', 'upload-html', 'generate-json']
        ];
        for (const [slug, ...steps] of routes) {
            await page.goto(`${url}#${slug}`);
            const prose = page.locator('#pg-prose');
            await prose.locator('figure').first().waitFor();
            const pictures = await prose.locator('figure img').evaluateAll((nodes) =>
                nodes.map((img) => img.src.split('/').pop().replace(/\.png$/, ''))
            );
            let previous = -1;
            for (const step of steps) {
                assert.ok(pictures.indexOf(step) > previous, `${slug}: missing or misplaced illustration ${step}`);
                previous = pictures.indexOf(step);
            }
            assert.equal(await prose.locator('a[href*=".flow-meta.xml"]').count(), 0);
            assert.doesNotMatch(await prose.innerText(), /sf project deploy/);
        }
        await page.goto(`${url}#event-signing-journey`);
        await page.locator('#pg-prose a[href="#signing-handoff-setup"]').first().click();
        await page.getByRole('heading', { name: 'Set up a signing receipt and event', exact: true }).waitFor();
    });
    await check('search matches article content and opens a result', async () => {
        await page.goto(url);
        await page.getByRole('heading', { name: 'What would you like to do?', exact: true }).waitFor();
        const search = page.getByRole('searchbox', { name: 'Search the Portwood guide', exact: true });
        await search.fill('email verification');
        await page.locator('.pg-result').first().waitFor();
        assert.ok((await page.locator('.pg-result').count()) > 0);
        await page.locator('.pg-result a').first().click();
        await page.locator('#pg-prose').waitFor();
        // Fragment navigation dispatches both popstate and hashchange. Let the
        // navigation finish before starting another query in the same input.
        await page.evaluate(
            () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
        );
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
        const markdown = await page.locator('#pg-raw-text').innerText();
        assert.ok(markdown.includes('[Check your installed version](#troubleshooting)'));
        assert.ok(markdown.includes('[Who needs a Portwood license?](#user-licenses)'));
        assert.ok(markdown.includes(`The current release is **${catalog.product.version}**`));
        await page.locator('[data-article="first-document"]').click();
        await page.getByRole('heading', { name: 'Make your first document', exact: true }).waitFor();
    });
    await check('phone and tablet layouts have no page overflow and a working topic menu', async () => {
        for (const width of [390, 768, 1024]) {
            await page.setViewportSize({ width, height: 900 });
            for (const slug of ['sign-uploaded-pdf', 'user-licenses', 'site-experience-cloud', 'site-salesforce', 'merge-tags', 'tag-charts', 'apex-surface', 'signing-site-handoff', 'document-studio']) {
                await page.goto(`${url}#${slug}`);
                await page.locator('#pg-prose').waitFor();
                assert.ok(
                    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1),
                    `${width}px overflow in ${slug}`
                );
            }
        }
        await page.setViewportSize({ width: 390, height: 844 });
        await page.goto(`${url}#signing-site-handoff`);
        const detail = page.getByRole('button', { name: /Enlarge screenshot: The three navigation settings/ });
        await detail.click();
        const actual = page.getByRole('button', { name: 'Actual size' });
        await actual.click();
        assert.equal(await actual.getAttribute('aria-pressed'), 'true');
        await page.waitForFunction(() => {
            const img = document.querySelector('#pg-zoom-image');
            const view = document.querySelector('#pg-zoom-view');
            return img.clientWidth === img.naturalWidth && view.scrollWidth > view.clientWidth;
        });
        await page.locator('#pg-zoom-view').evaluate((view) => view.scrollTo(75, 0));
        assert.ok(await page.locator('#pg-zoom-view').evaluate((view) => view.scrollLeft > 0));
        await page.keyboard.press('Escape');
        assert.ok(await detail.evaluate((node) => node === document.activeElement));
        await page.waitForFunction(() => document.querySelector('#pg-zoom-size').getAttribute('aria-pressed') === 'false');
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
