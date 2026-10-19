import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
const resource = new URL('../../../force-app/main/default/staticresources/DocGenSigningBranding/', import.meta.url);
// Offline fixtures cannot evaluate Visualforce. Materialize its initial public
// presentation here; Apex and live HTTP checks verify the actual server path.
export function signingPageFixture(source, brand = null, completionState = '') {
    const defaults = {
        documentTitle: 'Portwood DocGen | Document signing',
        serviceContext: 'Document signing provided by',
        bodyClass: '',
        bodyStyle: '',
        visibility: 'display:none',
        logoVisibility: 'display:none',
        bannerVisibility: 'display:none',
        supportVisibility: 'display:none',
        footerVisibility: 'display:none',
        introVisibility: 'display:none',
        completionState,
        loadingVisibility: completionState ? 'display:none' : '',
        successVisibility: completionState === 'success' ? '' : 'display:none',
        waitingVisibility: completionState === 'waiting' ? '' : 'display:none',
        json: 'null',
        completionMessage: 'Your document has been signed and processed securely. You may close this window.'
    };
    let markup = source
        .slice(source.indexOf('<html'), source.indexOf('</html>') + 7)
        .replace(/<apex:outputText\b[^>]*value="\{!initialPage\.(\w+)\}"[^>]*\/>/g, (_all, key) => defaults[key] || '')
        .replace(/\{!initialPage\.(\w+)\}/g, (_all, key) => defaults[key] || '')
        .replace(/<\/?apex:[^>]*>/g, '');
    if (!brand) return markup;
    const dom = new JSDOM(markup, { url: 'https://branding.test/', runScripts: 'outside-only' });
    for (const file of ['purify.min.js', 'branding-content.js', 'signing-branding.js'])
        dom.window.eval(readFileSync(new URL(file, resource), 'utf8'));
    dom.window.PortwoodSigningBranding.apply(brand);
    if (completionState) dom.window.document.querySelector('#signing-brand-intro').style.display = 'none';
    dom.window.document.querySelector('#signing-initial-brand').textContent = JSON.stringify(brand).replaceAll(
        '<',
        '\u003c'
    );
    markup = dom.window.document.documentElement.outerHTML;
    dom.window.close();
    return markup;
}
