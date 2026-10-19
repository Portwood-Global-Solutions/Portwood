import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright';
import { runAnonymous, debugMap } from '../qa/lib/sf.mjs';

// Explicit developer demo, never part of the product or automatic QA runner.
const org = process.argv[2] || 'portwood-proposal';
const output = new URL('../../output/brand-live-demo/', import.meta.url);
await mkdir(output, { recursive: true });
function sf(args) {
    return JSON.parse(
        execFileSync('sf', [...args, '--target-org', org, '--json'], {
            encoding: 'utf8',
            stdio: ['ignore', 'pipe', 'pipe']
        })
    ).result;
}
assert.equal(
    debugMap(
        await runAnonymous(
            org,
            "System.assertEquals('00DRu00000aiv7VMAQ', UserInfo.getOrganizationId(), 'Proposal scratch demo only.'); System.debug('SCOPED=true');"
        )
    ).SCOPED,
    'true',
    'Demo requires the authorized Proposal scratch org.'
);
let theme = sf([
    'data',
    'query',
    '--query',
    "SELECT Id FROM BrandingSet WHERE DeveloperName='Portwood_Cedar_Live_Demo'"
]).records[0];
if (!theme)
    theme = {
        Id: sf([
            'data',
            'create',
            'record',
            '--sobject',
            'BrandingSet',
            '--values',
            "DeveloperName=Portwood_Cedar_Live_Demo MasterLabel='Cedar Community — live theme demo'"
        ]).id
    };
const properties = {};
function setProperty(name, value) {
    const row = sf([
        'data',
        'query',
        '--query',
        `SELECT Id FROM BrandingSetProperty WHERE BrandingSetId='${theme.Id}' AND PropertyName='${name}'`
    ]).records[0];
    const values = `PropertyValue='${value}'`;
    const result = row
        ? sf([
              'data',
              'update',
              'record',
              '--sobject',
              'BrandingSetProperty',
              '--record-id',
              row.Id,
              '--values',
              values
          ])
        : sf([
              'data',
              'create',
              'record',
              '--sobject',
              'BrandingSetProperty',
              '--values',
              `BrandingSetId=${theme.Id} PropertyName=${name} ${values}`
          ]);
    properties[name] = row?.Id || result.id;
}
for (const [name, value] of Object.entries({
    ActionColor: '#2574A9',
    HeaderBackgroundColor: '#143B52',
    PageBackgroundColor: '#EAF2F7',
    PrimaryFont: 'Georgia, serif'
}))
    setProperty(name, value);
const reuse = process.argv.includes('--reuse');
const source = (await readFile(new URL('seed-live-demo.apex', import.meta.url), 'utf8')).replace(
    'BRANDING_SET_ID',
    theme.Id
);
const log = reuse ? '' : await runAnonymous(org, source);
const result = reuse ? await readFile(new URL('links.json', output), 'utf8') : debugMap(log).DEMO;
if (!result) throw new Error('Demo setup failed: ' + log.slice(-2500));
const demo = { ...JSON.parse(result), themeId: theme.Id, properties };
assert.equal(demo.emailsSent, 0);
await writeFile(new URL('links.json', output), JSON.stringify(demo, null, 2));
const browser = await chromium.launch({ headless: true });
let checks = 1;
try {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
    const page = await context.newPage();
    for (const [name, url] of [
        ['html', demo.htmlUrl],
        ['pdf', demo.pdfUrl]
    ]) {
        await page.goto(url, { waitUntil: 'domcontentloaded' });
        await page.waitForSelector('body.signing-branded', { timeout: 60000 });
        if (name === 'pdf') await page.waitForSelector('#pdf-viewer-container canvas', { timeout: 60000 });
        else await page.getByText('Your signature:', { exact: false }).first().waitFor({ timeout: 60000 });
        assert.equal(await page.evaluate(() => document.body.style.getPropertyValue('--signing-action')), '#2574A9');
        checks++;
        await page.getByText('Welcome to Cedar Community', { exact: true }).first().waitFor();
        checks++;
        await page.screenshot({ path: new URL(`${name}-before.png`, output).pathname, fullPage: true });
    }
    const brandModified = sf([
        'data',
        'query',
        '--query',
        `SELECT LastModifiedDate FROM DocGen_Brand__c WHERE Id='${demo.brandId}'`
    ]).records[0].LastModifiedDate;
    // Change only the Salesforce theme. Neither Brand nor either request is resaved.
    setProperty('ActionColor', '#227548');
    setProperty('HeaderBackgroundColor', '#163E35');
    setProperty('PageBackgroundColor', '#EDF4F1');
    for (const [name, url] of [
        ['html', demo.htmlUrl],
        ['pdf', demo.pdfUrl]
    ]) {
        await page.goto(url, { waitUntil: 'domcontentloaded' });
        await page.waitForSelector('body.signing-branded', { timeout: 60000 });
        if (name === 'pdf') await page.waitForSelector('#pdf-viewer-container canvas', { timeout: 60000 });
        else await page.getByText('Your signature:', { exact: false }).first().waitFor({ timeout: 60000 });
        const actual = await page.evaluate(() =>
            Object.fromEntries(
                ['action', 'header', 'background'].map((k) => [
                    k,
                    document.body.style.getPropertyValue('--signing-' + k)
                ])
            )
        );
        assert.deepEqual(actual, { action: '#227548', header: '#163E35', background: '#EDF4F1' });
        checks++;
        await page.screenshot({ path: new URL(`${name}-after.png`, output).pathname, fullPage: true });
        await page.setViewportSize({ width: 390, height: 844 });
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
        checks++;
        await page.screenshot({ path: new URL(`${name}-mobile.png`, output).pathname, fullPage: true });
        await page.setViewportSize({ width: 1440, height: 1000 });
    }
    assert.equal(
        sf(['data', 'query', '--query', `SELECT LastModifiedDate FROM DocGen_Brand__c WHERE Id='${demo.brandId}'`])
            .records[0].LastModifiedDate,
        brandModified
    );
    checks++;
    await page.goto(demo.htmlUrl.replace(/token=.*/, 'token=' + 'a'.repeat(64)), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#state-error', { state: 'visible', timeout: 60000 });
    assert.equal(await page.locator('body.signing-branded').count(), 0);
    checks++;
    await writeFile(
        new URL('verification.json', output),
        JSON.stringify({ checks, themeId: theme.Id, dynamicThemeUpdate: true, emailsSent: 0 }, null, 2)
    );
    console.log(`PASS: ${checks} live guest checks; links and screenshots in output/brand-live-demo.`);
} finally {
    await browser.close();
}
