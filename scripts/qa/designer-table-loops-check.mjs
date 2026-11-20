/**
 * Run with node scripts/qa/designer-table-loops-check.mjs.
 * Uses Chromium's HTML parser to exercise the Designer's preview/serialize path.
 */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromium } from 'playwright';

const lwc = new URL('../../force-app/main/default/lwc/', import.meta.url);
const moduleUrl = (source) => 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
const utilities = moduleUrl(await readFile(new URL('docGenUtils/docGenUtils.js', lwc), 'utf8'));
const authoring = moduleUrl(
    (await readFile(new URL('docGenAuthoringKit/docGenAuthoringKit.js', lwc), 'utf8')).replace(
        "'c/docGenUtils'",
        JSON.stringify(utilities)
    )
);

const template =
    '<table><thead><tr>{#IF ShowPrice}<th>Price</th>{:else}<th>Hidden</th>{/IF}</tr></thead>' +
    '<tbody>{#Items}<tr title="Amount > 0"><td>{Name}</td><td>{Price}</td></tr>{/Items}</tbody></table>';
const browser = await chromium.launch({ channel: process.env.PORTWOOD_CHROME_CHANNEL || undefined });
try {
    const page = await browser.newPage();
    const result = await page.evaluate(
        async ({ authoring, template }) => {
            const { scopeHtmlForInlinePreview } = await import(authoring);
            const mount = () => document.createElement('div');
            const unprotected = mount();
            unprotected.innerHTML = template;
            const roundTrip = (source) => {
                const host = mount();
                host.innerHTML = scopeHtmlForInlinePreview(source);
                const saved = document.createElement('template');
                saved.innerHTML = host.querySelector('.dg-pv').innerHTML;
                const table = saved.content.querySelector('table');
                return table.outerHTML;
            };
            const first = roundTrip(template);
            return {
                fostered: unprotected.firstChild.nodeType === Node.TEXT_NODE,
                first,
                second: roundTrip(first)
            };
        },
        { authoring, template }
    );
    assert(result.fostered, 'Fixture reproduces the browser moving raw table controls ahead of the table');
    assert.match(
        result.first,
        /<tr><!--\{#IF ShowPrice\}--><th>Price<\/th><!--\{:else\}--><th>Hidden<\/th><!--\{\/IF\}--><\/tr>/
    );
    assert.match(
        result.first,
        /<tbody><!--\{#Items\}--><tr title="Amount &gt; 0"><td>\{Name\}<\/td><td>\{Price\}<\/td><\/tr><!--\{\/Items\}--><\/tbody>/
    );
    assert.equal(result.second, result.first, 'Saving and reopening preserves control boundaries exactly');
    console.log('Designer table loop and conditional round-trip passed in Chromium.');
} finally {
    await browser.close();
}
