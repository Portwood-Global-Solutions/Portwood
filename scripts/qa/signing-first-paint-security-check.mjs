import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { runAnonymous, debugMap } from './lib/sf.mjs';
const org = process.argv[2] || 'portwood-proposal';
const resource = new URL('../../force-app/main/default/staticresources/DocGenSigningBranding/', import.meta.url);
const fixture = debugMap(
    await runAnonymous(
        org,
        `
System.assertEquals('00DRu00000aiv7VMAQ',UserInfo.getOrganizationId());
DocGen_Brand__c brand=new DocGen_Brand__c(Name='First paint security QA',Company_Name__c='Cedar <img src=x onerror=alert(1)> & Partners',Is_Active__c=true,Logo_Url__c='https://example.com/brand.png?a=1&b=2',Signing_Support_Url__c='https://example.com/help?a=1&b=2',Signing_Page_Config__c=DocGenSigningPageConfig.validateAndSerialize('{"mode":"Advanced","headerHtml":"<h2>{{companyName}}</h2>","footerHtml":"<p>Sample footer</p>"}'));
insert brand;
DocGen_Signature_Request__c request=new DocGen_Signature_Request__c(Brand__c=brand.Id,Status__c='Sent',Expires_At__c=Datetime.now().addHours(1));insert request;
String token=EncodingUtil.convertToHex(Crypto.generateAesKey(256));
DocGen_Signer__c signer=new DocGen_Signer__c(Signature_Request__c=request.Id,Signer_Name__c='QA',Signer_Email__c='qa@example.invalid',Status__c='Pending',Secure_Token__c=token,Sort_Order__c=1);insert signer;
System.debug('FIXTURE='+JSON.serialize(new Map<String,Object>{'brandId'=>brand.Id,'requestId'=>request.Id,'signerId'=>signer.Id,'token'=>token,'base'=>DocGenSignatureSenderController.getSiteBaseUrl()}));
`
    )
).FIXTURE;
assert.ok(fixture, 'Create isolated, fictional security fixture.');
const f = JSON.parse(fixture);
let checks = 0;
try {
    for (const name of ['DocGenSignature', 'DocGenSignaturePdf']) {
        const url = f.base + '/apex/' + name + '?token=' + f.token;
        const response = await fetch(url);
        assert.equal(response.status, 200);
        checks++;
        const dom = new JSDOM(await response.text(), { url, runScripts: 'outside-only' });
        const { window } = dom;
        const d = window.document;
        assert.equal(
            d.querySelector('#signing-brand-company').textContent,
            'Cedar <img src=x onerror=alert(1)> & Partners'
        );
        checks++;
        assert.equal(d.querySelector('#signing-brand-company img'), null);
        checks++;
        assert.equal(d.body.getAttribute('onerror'), null);
        checks++;
        assert.match(d.body.style.getPropertyValue('--signing-font'), /"Salesforce Sans"/);
        checks++;
        assert.equal(
            d.querySelector('#signing-brand-logo').getAttribute('src'),
            'https://example.com/brand.png?a=1&b=2'
        );
        checks++;
        assert.equal(
            d.querySelector('#signing-brand-support').getAttribute('href'),
            'https://example.com/help?a=1&b=2'
        );
        checks++;
        const payload = d.querySelector('#signing-initial-brand').textContent;
        assert.equal(payload.includes('<'), false);
        checks++;
        assert.equal(JSON.parse(payload).companyName, 'Cedar <img src=x onerror=alert(1)> & Partners');
        checks++;
        assert.equal(d.body.classList.contains('signing-brand-pending'), true);
        checks++;
        const style = d.createElement('style');
        style.textContent = readFileSync(new URL('signing-branding.css', resource), 'utf8');
        d.head.appendChild(style);
        assert.equal(window.getComputedStyle(d.querySelector('#signing-brand-header')).visibility, 'hidden');
        checks++;
        for (const file of ['purify.min.js', 'branding-content.js', 'signing-branding.js'])
            window.eval(readFileSync(new URL(file, resource), 'utf8'));
        window.eval(d.querySelector('#signing-initial-brand').nextElementSibling.textContent);
        assert.equal(d.body.classList.contains('signing-brand-pending'), false);
        checks++;
        assert.equal(d.querySelector('#signing-custom-header').hidden, false);
        checks++;
        assert.equal(d.querySelector('#signing-custom-header img'), null);
        checks++;
        assert.equal(
            d.querySelector('#signing-custom-header h2').textContent,
            'Cedar <img src=x onerror=alert(1)> & Partners'
        );
        checks++;
        assert.equal(d.querySelector('.signing-service').hidden, false);
        checks++;
        assert.equal(window.pwned, undefined);
        checks++;
        dom.window.close();
    }
    console.log(`PASS: ${checks} live first-paint escaping, CSS and Advanced initialization checks.`);
} finally {
    await runAnonymous(
        org,
        `System.assertEquals('00DRu00000aiv7VMAQ',UserInfo.getOrganizationId());delete [SELECT Id FROM DocGen_Signer__c WHERE Id='${f.signerId}'];delete [SELECT Id FROM DocGen_Signature_Request__c WHERE Id='${f.requestId}'];delete [SELECT Id FROM DocGen_Brand__c WHERE Id='${f.brandId}'];`
    );
}
