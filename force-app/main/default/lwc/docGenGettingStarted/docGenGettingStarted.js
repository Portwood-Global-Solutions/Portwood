import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getReadiness from '@salesforce/apex/DocGenGettingStartedController.getReadiness';
import createStarter from '@salesforce/apex/DocGenGettingStartedController.createStarter';
import renderStarter from '@salesforce/apex/DocGenGettingStartedController.renderStarter';

const EXAMPLES = {
    quote: {
        title: 'Quote PDF',
        object: 'Quote',
        icon: 'standard:quotes',
        description: 'A quote with products, quantities, discounts, tax, shipping, and Salesforce totals.',
        includes: 'Quote details, product pricing, line discounts, tax, shipping, and the grand total from Salesforce.',
        dataHint:
            'Choose a Salesforce quote with line items. Totals come from the quote; this template does not calculate tax or add charges.',
        action: 'Start with a quote',
        previewTotal: '$23,850',
        previewLabel: 'Grand total',
        previewLineTotal: '$12,600'
    },
    opportunity: {
        title: 'Opportunity proposal',
        object: 'Opportunity',
        icon: 'standard:opportunity',
        description: 'Turn an opportunity and its products into a customer-ready proposal.',
        includes: 'Product names, quantities, unit prices, line totals, and the proposal total.',
        action: 'Start with an opportunity',
        previewTotal: '$24,500',
        previewLabel: 'Products and services',
        previewLineTotal: '$14,000',
        dataHint:
            'Choose an opportunity with products for a complete proposal. Opportunities without products show a clear empty state.'
    },
    account: {
        title: 'Account summary',
        object: 'Account',
        icon: 'standard:account',
        description: 'Bring the account, its open deals, and its support activity into one briefing.',
        includes: 'Open opportunities, open cases, pipeline totals, and key contacts.',
        dataHint:
            'Closed opportunities and closed cases are excluded. Empty sections explain when there is no activity.'
    }
};
export default class DocGenGettingStarted extends NavigationMixin(LightningElement) {
    @api active = false;
    phase = 'choose';
    exampleKey = 'opportunity';
    dataMode = 'sample';
    recordId;
    templateId;
    result;
    busy = false;
    busyLabel = '';
    error = '';
    canCreate = false;
    loading = true;
    quoteAvailable = false;
    @wire(getReadiness)
    readiness({ data, error }) {
        if (data) {
            this.canCreate = data.canCreate;
            this.quoteAvailable = data.quoteAvailable === true;
            this.loading = false;
        }
        if (error) {
            this.error = this.errorText(error);
            this.loading = false;
        }
    }
    get choosing() {
        return this.phase === 'choose';
    }
    get configuring() {
        return this.phase === 'record';
    }
    get finished() {
        return this.phase === 'done';
    }
    get showAccessHelp() {
        return !this.loading && !this.canCreate;
    }
    get example() {
        return EXAMPLES[this.exampleKey];
    }
    get salesExampleKey() {
        return this.quoteAvailable ? 'quote' : 'opportunity';
    }
    get salesExample() {
        return EXAMPLES[this.salesExampleKey];
    }
    get usingSample() {
        return this.dataMode === 'sample';
    }
    get usingRecord() {
        return !this.usingSample;
    }
    get renderDisabled() {
        return this.busy || this.loading || !this.canCreate || (this.usingRecord && !this.recordId);
    }
    get sampleClass() {
        return this.usingSample ? 'data-choice selected' : 'data-choice';
    }
    get recordClass() {
        return this.usingRecord ? 'data-choice selected' : 'data-choice';
    }
    get downloadUrl() {
        return this.result ? '/sfc/servlet.shepherd/version/download/' + this.result.contentVersionId : '';
    }
    get recordUrl() {
        return this.recordId ? '/lightning/r/' + this.example.object + '/' + this.recordId + '/view' : '';
    }
    get resultDescription() {
        return this.result?.sampleData
            ? 'Rendered with fictional Northstar data. Your reusable template is ready; no sample CRM records were created.'
            : 'Rendered from your Salesforce record. The PDF is in your private Files; the source record has not been changed.';
    }
    get steps() {
        const current = this.choosing ? 0 : this.configuring ? 1 : 2;
        return ['Choose an example', 'Choose your data', 'View your PDF'].map((label, i) => ({
            label,
            number: i + 1,
            className: i === current ? 'step current' : i < current ? 'step complete' : 'step',
            ariaCurrent: i === current ? 'step' : null
        }));
    }
    choose(event) {
        const key = event.currentTarget.dataset.key;
        if (this.exampleKey !== key) {
            this.recordId = null;
            this.templateId = null;
            this.result = null;
        }
        this.exampleKey = key;
        this.error = '';
        this.phase = 'record';
    }
    back() {
        this.phase = 'choose';
        this.error = '';
    }
    setDataMode(event) {
        this.dataMode = event.currentTarget.dataset.mode;
        this.error = '';
    }
    selectRecord(event) {
        this.recordId = event.detail.recordId;
        this.error = '';
    }
    async generate() {
        if (this.renderDisabled) return;
        this.busy = true;
        this.error = '';
        try {
            const sourceRecordId = this.usingSample ? null : this.recordId;
            this.busyLabel = 'Preparing your reusable template…';
            const created = await createStarter({ exampleKey: this.exampleKey, recordId: sourceRecordId });
            this.templateId = created.templateId;
            this.busyLabel = 'Rendering your PDF in Salesforce…';
            this.result = await renderStarter({
                exampleKey: this.exampleKey,
                templateId: this.templateId,
                recordId: sourceRecordId
            });
            this.phase = 'done';
            this.dispatchEvent(new CustomEvent('startercreated'));
            if (this.active) this.viewPdf();
        } catch (error) {
            this.error = this.errorText(error);
        } finally {
            this.busy = false;
            this.busyLabel = '';
        }
    }
    viewPdf() {
        if (!this.result) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: this.result.contentDocumentId }
        });
    }
    anotherRecord() {
        this.dataMode = 'record';
        this.phase = 'record';
        this.error = '';
    }
    customize() {
        this.dispatchEvent(
            new CustomEvent('customizestarter', {
                detail: { templateId: this.templateId, recordId: this.result?.sampleData ? null : this.recordId }
            })
        );
    }
    showTemplates() {
        this.dispatchEvent(new CustomEvent('journeynavigate', { detail: { section: 'templates' } }));
    }
    showAssets() {
        this.dispatchEvent(new CustomEvent('journeynavigate', { detail: { section: 'assets' } }));
    }
    errorText(error) {
        return (
            error?.body?.message ||
            error?.message ||
            'This step could not finish. Try again, or choose the other example.'
        );
    }
}
