import assert from 'node:assert/strict';
import { readFile, mkdir } from 'node:fs/promises';
import { chromium } from 'playwright';

// Exercise the actual page markup/scripts and shared brand resource in a real
// browser. Only Visualforce remoting and external assets are replaced locally.
const root = new URL('../../', import.meta.url);
const resource = new URL('force-app/main/default/staticresources/DocGenSigningBranding/', root);
const css = await readFile(new URL('signing-branding.css', resource), 'utf8');
const js = await readFile(new URL('signing-branding.js', resource), 'utf8');
const purifier = await readFile(new URL('purify.min.js', resource), 'utf8');
const contentRenderer = await readFile(new URL('branding-content.js', resource), 'utf8');
const output = new URL('output/signing-branding/', root);
await mkdir(output, { recursive: true });
const brand = {
    companyName: 'Cedar Community',
    logoUrl: 'https://branding.test/logo.svg',
    color: '#FFFF00',
    headerColor: '#163E35',
    backgroundColor: '#EDF4F1',
    title: 'Welcome to Cedar Community',
    welcomeText: 'Please review your agreement.\nWe are here if you need help.',
    footerText: 'Cedar Community resident services',
    completionMessage: 'Thank you. Your agreement is complete.',
    supportUrl: 'https://branding.test/help'
};
const browser = await chromium.launch({ headless: true });
let checks = 0;
function checked(method, ...args) {
    assert[method](...args);
    checks++;
}
try {
    for (const name of ['DocGenSignature', 'DocGenSignaturePdf']) {
        const source = await readFile(new URL(`force-app/main/default/pages/${name}.page`, root), 'utf8');
        const markup = source
            .slice(source.indexOf('<html'), source.indexOf('</html>') + 7)
            .replace(/<apex:[^>]+\/>/g, '')
            .replace(
                '</head>',
                `<style>${css}</style><script>${purifier}</script><script>${contentRenderer}</script><script>${js}</script></head>`
            );
        const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
        const page = await context.newPage();
        const errors = [];
        page.on('pageerror', (err) => errors.push(err.message));
        await context.route('**/*', async (route) => {
            if (route.request().url().includes('/logo.svg')) {
                return route.fulfill({
                    contentType: 'image/svg+xml',
                    body: '<svg xmlns="http://www.w3.org/2000/svg" width="44" height="44"><path d="M22 1L42 40H2Z" fill="white"/></svg>'
                });
            }
            if (route.request().url().includes('api.ipify.org')) {
                return route.fulfill({ contentType: 'application/json', body: '{"ip":"127.0.0.1"}' });
            }
            return route.fulfill({ contentType: 'text/html', body: markup });
        });
        await page.addInitScript(
            ({ brand }) => {
                window.Visualforce = {
                    remoting: {
                        Manager: {
                            invokeAction(action, ...args) {
                                const callback = args.find((arg) => typeof arg === 'function');
                                if (action.includes('.validateToken')) {
                                    callback(
                                        {
                                            isValid: !location.search.includes('invalid'),
                                            branding: brand,
                                            requiresPin: true,
                                            signerName: 'Pat Resident',
                                            signerEmail: 'pat@example.com',
                                            documentTitle: 'Community agreement'
                                        },
                                        { status: true }
                                    );
                                }
                            }
                        }
                    }
                };
            },
            { brand }
        );
        await page.goto('https://branding.test/sign?token=' + 'a'.repeat(64));
        await page.locator('#signing-brand-header').waitFor({ state: 'visible' });
        checked('equal', await page.title(), 'Cedar Community | Signing with Portwood DocGen');
        checked('equal', await page.locator('#signing-brand-title').textContent(), brand.title);
        checked('equal', await page.locator('#signing-brand-welcome').textContent(), brand.welcomeText);
        checked('equal', await page.locator('#signing-brand-support').getAttribute('href'), brand.supportUrl);
        checked('equal', await page.locator('#signing-completion-message').textContent(), brand.completionMessage);
        checked('equal', await page.locator('#state-verify').isVisible(), true);
        const action = await page.locator('#btn-send-pin').evaluate((el) => ({
            color: getComputedStyle(el).color,
            background: getComputedStyle(el).backgroundColor
        }));
        checked('deepEqual', action, { color: 'rgb(0, 0, 0)', background: 'rgb(255, 255, 0)' });
        await page.screenshot({ path: new URL(`${name}-desktop.png`, output).pathname, fullPage: true });
        await page.setViewportSize({ width: 375, height: 812 });
        checked(
            'equal',
            await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
            true,
            `${name}: no mobile overflow`
        );
        await page.screenshot({ path: new URL(`${name}-mobile.png`, output).pathname, fullPage: true });
        // Brand settings must not retheme document buttons or links.
        await page.evaluate(() => {
            const doc = document.createElement('div');
            doc.id = 'document-isolation-check';
            doc.innerHTML =
                '<button class="btn btn-brand">Document content</button><p style="color:rgb(19,55,91)">Document copy</p>';
            document.body.appendChild(doc);
        });
        checked(
            'equal',
            await page
                .locator('#document-isolation-check button')
                .evaluate((el) => getComputedStyle(el).backgroundColor),
            'rgb(1, 118, 211)'
        );
        checked(
            'equal',
            await page.locator('#document-isolation-check p').evaluate((el) => getComputedStyle(el).color),
            'rgb(19, 55, 91)'
        );
        // Hostile text remains literal and unsafe URLs never reach DOM attributes.
        await page.evaluate((brand) => {
            window.PortwoodSigningBranding.apply({
                ...brand,
                title: '<img src=x onerror="window.pwned=1">',
                welcomeText: '<script>window.pwned=1</script>',
                logoUrl: 'javascript:alert(1)',
                supportUrl: 'javascript:alert(1)',
                color: 'red;display:none'
            });
        }, brand);
        checked('equal', await page.locator('#signing-brand-title img').count(), 0);
        checked('equal', await page.locator('#signing-brand-support').getAttribute('href'), null);
        checked('equal', await page.locator('#signing-brand-logo').getAttribute('src'), null);
        checked(
            'equal',
            await page.locator('#btn-send-pin').evaluate((el) => getComputedStyle(el).backgroundColor),
            'rgb(1, 118, 211)'
        );
        checked('equal', await page.evaluate(() => window.pwned), undefined);
        // Standard image/layout controls apply on the actual public-page markup.
        const pageSettings = {
            mode: 'Standard',
            logoUrl: 'https://branding.test/logo.svg',
            logoHeight: 88,
            logoAlignment: 'Center',
            bannerUrl: 'https://branding.test/logo.svg',
            bannerAlt: 'Community garden',
            backgroundUrl: 'https://branding.test/logo.svg',
            font: 'Serif',
            spacing: 'Spacious',
            contentWidth: 1200
        };
        await page.evaluate(
            ({ brand, pageSettings }) => window.PortwoodSigningBranding.apply({ ...brand, page: pageSettings }),
            { brand, pageSettings }
        );
        checked(
            'equal',
            await page.locator('#signing-brand-logo').evaluate((el) => getComputedStyle(el).maxHeight),
            '88px'
        );
        checked(
            'equal',
            await page.locator('#signing-brand-header').evaluate((el) => getComputedStyle(el).justifyContent),
            'center'
        );
        checked('equal', await page.locator('#signing-brand-banner').getAttribute('alt'), 'Community garden');
        checked('match', await page.locator('body').evaluate((el) => getComputedStyle(el).backgroundImage), /logo.svg/);
        checked(
            'match',
            await page.locator('#signing-brand-header').evaluate((el) => getComputedStyle(el).fontFamily),
            /Georgia/
        );
        const advanced = {
            ...pageSettings,
            mode: 'Advanced',
            headerHtml:
                '<div class="brand-heading"><img src="{{logoUrl}}" alt="Logo"/><strong>{{companyName}}</strong></div>',
            welcomeHtml:
                '<section class="welcome"><h1>{{title}}</h1><p>{{welcomeText}}</p><div class="columns"><p>One</p><p>Two</p></div></section>',
            footerHtml: '<a href="{{supportUrl}}">Ask our team</a>',
            completionHtml: '<p>Thank you, <strong>{{companyName}}</strong>.</p>',
            customCss:
                '.brand-heading {display:flex;gap:12px;align-items:center}.welcome h1 {font-size:30px;color:#934706}.columns {display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}@media (max-width: 600px) {.columns {grid-template-columns:1fr}}'
        };
        await page.setViewportSize({ width: 1280, height: 900 });
        await page.evaluate(
            ({ brand, advanced }) => window.PortwoodSigningBranding.apply({ ...brand, page: advanced }),
            { brand, advanced }
        );
        checked('equal', await page.locator('#signing-brand-header').isVisible(), false);
        checked('equal', await page.locator('#signing-custom-header strong').textContent(), brand.companyName);
        checked('equal', await page.locator('#signing-custom-welcome h1').textContent(), brand.title);
        checked(
            'equal',
            await page.locator('#signing-custom-welcome h1').evaluate((el) => getComputedStyle(el).color),
            'rgb(147, 71, 6)'
        );
        checked('equal', await page.locator('#signing-custom-footer a').getAttribute('rel'), 'noopener noreferrer');
        checked('match', await page.locator('#signing-custom-completion').textContent(), /Thank you, Cedar Community/);
        checked('equal', await page.locator('#signing-completion-message').isVisible(), false);
        await page.screenshot({ path: new URL(`${name}-advanced-desktop.png`, output).pathname, fullPage: true });
        await page.setViewportSize({ width: 375, height: 812 });
        checked(
            'equal',
            await page.locator('.columns').evaluate((el) => getComputedStyle(el).gridTemplateColumns.split(' ').length),
            1
        );
        checked('equal', await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
        await page.screenshot({ path: new URL(`${name}-advanced-mobile.png`, output).pathname, fullPage: true });
        // Markup/CSS cannot escape its section, clobber controls, or execute code.
        const hostile =
            '<style>body{display:none}</style><script>window.pwned=1</script><iframe src="https://branding.test/evil"></iframe><form><input id="btn-send-pin"/><button>Fake submit</button></form><svg onload="window.pwned=1"></svg><div class="attack" style="position:fixed;inset:0;width:999999px;z-index:9999;color:red">Safe text <a href="javascript:alert(1)" onclick="window.pwned=1">Link</a></div>';
        await page.evaluate(
            ({ brand, advanced, hostile }) =>
                window.PortwoodSigningBranding.apply({
                    ...brand,
                    companyName: '<img src=x onerror="window.pwned=1">',
                    page: {
                        ...advanced,
                        headerHtml: '<p>{{companyName}}</p>',
                        welcomeHtml: hostile,
                        customCss:
                            'body, .signing-action {display:none}.attack {position:fixed;z-index:9999;width:999999px;transform:scale(20);background-image:url(https://branding.test/evil);color:red}@import url(https://branding.test/evil);'
                    }
                }),
            { brand, advanced, hostile }
        );
        checked('equal', await page.locator('#signing-custom-header img').count(), 0);
        checked(
            'equal',
            await page
                .locator(
                    '#signing-custom-welcome script, #signing-custom-welcome iframe, #signing-custom-welcome input, #signing-custom-welcome button, #signing-custom-welcome svg'
                )
                .count(),
            0
        );
        checked('equal', await page.locator('.attack').evaluate((el) => getComputedStyle(el).position), 'static');
        checked('equal', await page.locator('.attack').evaluate((el) => getComputedStyle(el).zIndex), 'auto');
        checked('equal', await page.locator('#btn-send-pin').count(), 1);
        checked('equal', await page.locator('#btn-send-pin').isVisible(), true);
        checked('equal', await page.locator('#signing-custom-welcome a').getAttribute('href'), null);
        checked(
            'equal',
            await page
                .locator('#document-isolation-check button')
                .evaluate((el) => getComputedStyle(el).backgroundColor),
            'rgb(1, 118, 211)'
        );
        checked(
            'equal',
            await page.locator('#document-isolation-check p').evaluate((el) => getComputedStyle(el).color),
            'rgb(19, 55, 91)'
        );
        checked('equal', await page.evaluate(() => window.pwned), undefined);
        await page.evaluate(
            ({ brand, pageSettings }) =>
                window.PortwoodSigningBranding.apply({
                    ...brand,
                    page: { ...pageSettings, mode: 'Advanced', headerHtml: '<script>window.pwned=1</script>' }
                }),
            { brand, pageSettings }
        );
        checked(
            'equal',
            await page.locator('#signing-brand-header').isVisible(),
            true,
            'Empty sanitized HTML restores the Standard header'
        );
        await page.evaluate(
            ({ brand, advanced }) =>
                window.PortwoodSigningBranding.apply({ ...brand, page: { ...advanced, mode: 'Standard' } }),
            { brand, advanced }
        );
        checked('equal', await page.locator('#signing-custom-welcome').isVisible(), false);
        checked('equal', await page.locator('#signing-brand-title').isVisible(), true);
        // Invalid tokens must never present the brand, even if the stub supplies one.
        await page.goto('https://branding.test/sign?token=invalid');
        checked('equal', await page.locator('#signing-brand-header').isVisible(), false);
        checked('equal', await page.locator('#signing-brand-footer').isVisible(), false);
        checked('equal', await page.locator('#state-error').isVisible(), true);
        checked('deepEqual', errors, [], `${name}: no browser script errors`);
        await context.close();
    }
    console.log(
        `PASS: ${checks} signing branding checks across HTML and PDF pages; screenshots in output/signing-branding.`
    );
} finally {
    await browser.close();
}
