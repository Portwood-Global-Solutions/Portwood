import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { launch, login } from './lib/browser.mjs';
import { runAnonymous, debugMap } from './lib/sf.mjs';
const org = process.argv[2] || 'portwood-proposal';
const output = new URL('../../output/brand-live-demo/', import.meta.url);
const demo = JSON.parse(await readFile(new URL('links.json', output), 'utf8'));
const log = await runAnonymous(
    org,
    `
System.assertEquals('00DRu00000aiv7VMAQ',UserInfo.getOrganizationId());
DocGen_Signature_Request__c source=[SELECT Original_Document_CV_Id__c,Preparation_Config_CV_Id__c FROM DocGen_Signature_Request__c WHERE Id='${demo.pdfRequestId}'];
ContentVersion pdf=[SELECT VersionData FROM ContentVersion WHERE Id=:source.Original_Document_CV_Id__c];
Map<String,Object> draft=DocGenSignaturePreparationController.uploadPdf('${demo.accountId}','Brand picker - draft.pdf',EncodingUtil.base64Encode(pdf.VersionData));
String configText=[SELECT VersionData FROM ContentVersion WHERE Id=:source.Preparation_Config_CV_Id__c].VersionData.toString();
Map<String,Object> config=(Map<String,Object>)JSON.deserializeUntyped(configText);
config.put('documentId',draft.get('documentId'));
DocGenSignaturePreparationController.saveDraft('${demo.accountId}',(Id)draft.get('draftId'),0,JSON.serialize(config));
System.debug('DRAFT='+draft.get('draftId'));
`
);
const draftId = debugMap(log).DRAFT;
assert.ok(draftId, 'Create a resumable fictional draft.');
const { browser, page } = await launch({ width: 1440, height: 1000 });
let checks = 0;
try {
    const base = await login(page, org);
    const url =
        base.replace('.lightning.force.com', '.my.salesforce.com') +
        `/apex/DocGenSignaturePrepare?recordId=${demo.accountId}&draftId=${draftId}`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    await page.locator('#busy').waitFor({ state: 'hidden', timeout: 60000 });
    await page.locator('[data-step="3"]').click();
    await page.getByLabel('Signing Brand', { exact: true }).waitFor();
    assert.equal(await page.locator('#brandId').inputValue(), demo.brandId);
    checks++;
    assert.equal(await page.locator('.recipient-head').count(), 1);
    checks++;
    await page.locator('#brandId').selectOption('');
    await page.getByRole('button', { name: 'Save draft', exact: true }).click();
    await page.locator('#busy').waitFor({ state: 'hidden' });
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.locator('#busy').waitFor({ state: 'hidden', timeout: 60000 });
    await page.locator('[data-step="3"]').click();
    assert.equal(await page.locator('#brandId').inputValue(), '');
    checks++;
    await page.locator('#brandId').selectOption(demo.brandId);
    await page.getByRole('button', { name: 'Save draft', exact: true }).click();
    await page.locator('#busy').waitFor({ state: 'hidden' });
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.locator('#busy').waitFor({ state: 'hidden', timeout: 60000 });
    await page.locator('[data-step="3"]').click();
    assert.equal(await page.locator('#brandId').inputValue(), demo.brandId);
    checks++;
    await page.screenshot({ path: new URL('preparation-brand-picker.png', output).pathname, fullPage: true });
    await writeFile(new URL('preparation-verification.json', output), JSON.stringify({ checks, draftId }, null, 2));
    console.log(`PASS: ${checks} native PDF Brand picker checks.`);
} finally {
    await browser.close();
}
