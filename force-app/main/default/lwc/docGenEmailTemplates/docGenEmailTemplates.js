import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplates from '@salesforce/apex/DocGenEmailTemplateController.getTemplates';
import saveTemplate from '@salesforce/apex/DocGenEmailTemplateController.saveTemplate';
import getDefault from '@salesforce/apex/DocGenEmailTemplateController.getDefault';
import renderPreview from '@salesforce/apex/DocGenEmailTemplateController.renderPreview';
import sendTest from '@salesforce/apex/DocGenEmailTemplateController.sendTest';
import resolveAssetPublicUrl from '@salesforce/apex/DocGenEmailTemplateController.resolveAssetPublicUrl';
import getAssets from '@salesforce/apex/DocGenController.getAssets';
// #369 — Brand selector
import getBrands from '@salesforce/apex/DocGenBrandController.getBrands';
import saveBrand from '@salesforce/apex/DocGenBrandController.saveBrand';
import getOrgWideEmailAddresses from '@salesforce/apex/DocGenSetupController.getOrgWideEmailAddresses';

export default class DocGenEmailTemplates extends LightningElement {
    @track rows = [];
    @track selectedType;
    @track isLoading = true;

    // Working copy of the selected template (edited in place, saved on demand).
    @track recordId;
    @track name = '';
    @track subject = '';
    @track bodyHtml = '';
    @track bodyPlain = '';
    @track brandColor = '';
    @track logoUrl = '';
    @track footerText = '';
    @track layoutMode = 'Managed';
    @track isActive = true;
    @track tokens = [];

    @track testEmail = '';
    @track previewHtml = '';
    @track isSaving = false;
    @track isTesting = false;

    // "Override with Asset File" — Shared Asset images selectable as the logo.
    // logoAssetKey is PERSISTED on the template: the renderer resolves the asset's
    // latest file to its public link at send time, so replacing the asset image
    // updates the logo without re-saving any template.
    @track logoAssets = [];
    @track logoAssetKey = '';
    @track logoHeight = null;

    // #369 — Brand selector: which (type, brand) combination is being edited.
    @track selectedBrandId = '';
    @track brandOptions = [{ label: 'Shared / Default (all brands)', value: '' }];
    @track isBrandSpecific = false;

    // #369 — inline "+ New Brand…" quick-create, opened from the selector.
    @track showAddBrandForm = false;
    @track isSavingBrand = false;
    @track newBrandName = '';
    @track newBrandOwaId = '';
    @track newBrandColor = '#5A4FCF';
    @track newBrandCompany = '';
    @track newBrandLogoUrl = '';
    @track newBrandLogoAssetKey = '';
    @track newBrandFooter = '';
    @track owaOptions = [];

    _previewDirty = false;

    connectedCallback() {
        this.loadTemplates();
        this.loadLogoAssets();
        this.loadBrands();
    }

    @wire(getOrgWideEmailAddresses)
    wiredOwas({ data }) {
        if (data) {
            this.owaOptions = data;
        }
    }

    async loadBrands() {
        try {
            const brands = await getBrands();
            this.brandOptions = [
                { label: 'Shared / Default (all brands)', value: '' },
                ...(brands || []).filter((b) => b.isActive !== false).map((b) => ({ label: b.name, value: b.id })),
                { label: '+ New Brand…', value: '__add__' },
                { label: 'Manage brands…', value: '__manage__' }
            ];
        } catch (_e) {
            // Brands tab optional — selector just stays at Shared/Default.
        }
    }

    async loadLogoAssets() {
        try {
            const assets = await getAssets();
            this.logoAssets = (assets || []).filter((a) => a.isActive && a.latestVersionCvId);
        } catch (_e) {
            this.logoAssets = []; // Assets tab optional — picker just disables
        }
    }

    get logoAssetOptions() {
        const opts = this.logoAssets.map((a) => ({
            label: a.name + (a.category ? ' (' + a.category + ')' : ''),
            value: a.assetKey
        }));
        opts.unshift({ label: '— None (use the URL above) —', value: '' });
        return opts;
    }

    get logoAssetsUnavailable() {
        return this.logoAssets.length === 0;
    }

    async handleLogoAssetChange(event) {
        const assetKey = event.detail.value;
        if (!assetKey) {
            this.logoAssetKey = '';
            this._previewDirty = true;
            this.refreshPreview();
            return;
        }
        const asset = this.logoAssets.find((a) => a.assetKey === assetKey);
        try {
            // Publish the asset's current file now (admin session) — send-time
            // resolution only reads. The URL also lands in the field as a fallback.
            const url = await resolveAssetPublicUrl({ assetId: asset.id });
            this.logoAssetKey = assetKey;
            this.logoUrl = url;
            this._previewDirty = true;
            this.toast(
                'Logo linked to Asset',
                'Emails now use this asset\u2019s latest image automatically. Save to apply.',
                'success'
            );
            this.refreshPreview();
        } catch (error) {
            this.toast('Could not use this asset', this.errMsg(error), 'error');
        }
    }

    handleLogoHeightChange(event) {
        this.logoHeight = event.detail.value ? parseInt(event.detail.value, 10) : null;
        this._previewDirty = true;
    }

    async loadTemplates() {
        this.isLoading = true;
        try {
            this.rows = await getTemplates({ brandId: this.selectedBrandId });
            if (this.rows.length) {
                const keep = this.rows.find((r) => r.type === this.selectedType) || this.rows[0];
                this.applyRow(keep);
            }
        } catch (error) {
            this.toast('Error loading templates', this.errMsg(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    applyRow(row) {
        this.selectedType = row.type;
        this.recordId = row.recordId;
        this.name = row.name;
        this.subject = row.subject || '';
        this.bodyHtml = row.bodyHtml || '';
        this.bodyPlain = row.bodyPlain || '';
        this.brandColor = row.brandColor || '';
        this.logoUrl = row.logoUrl || '';
        this.footerText = row.footerText || '';
        this.layoutMode = row.layoutMode || 'Managed';
        this.isActive = row.isActive !== false;
        this.tokens = (row.tokens || []).map((t) => '{' + t + '}');
        this.logoAssetKey = row.logoAssetKey || '';
        this.logoHeight = row.logoHeight || null;
        this.isBrandSpecific = row.isBrandSpecific === true;
        this.refreshPreview();
    }

    get typeOptions() {
        return this.rows.map((r) => ({ label: r.typeLabel, value: r.type }));
    }

    get currentData() {
        return {
            type: this.selectedType,
            recordId: this.recordId,
            name: this.name,
            subject: this.subject,
            bodyHtml: this.bodyHtml,
            bodyPlain: this.bodyPlain,
            brandColor: this.brandColor,
            logoUrl: this.logoUrl,
            logoAssetKey: this.logoAssetKey,
            logoHeight: this.logoHeight,
            footerText: this.footerText,
            layoutMode: this.layoutMode,
            isActive: this.isActive,
            brandId: this.selectedBrandId
        };
    }

    get statusLabel() {
        if (!this.selectedBrandId) {
            return this.recordId ? 'Saved template' : 'Built-in default (not yet saved as a record)';
        }
        const brand = this.brandOptions.find((b) => b.value === this.selectedBrandId);
        const brandName = brand ? brand.label : 'this brand';
        return this.isBrandSpecific
            ? 'Customized for ' + brandName
            : 'Inherited from shared default — edit to customize for ' + brandName;
    }

    get layoutModeOptions() {
        return [
            { label: 'Portwood layout — edit body, branded chrome', value: 'Managed' },
            { label: 'Full custom HTML — your entire document', value: 'Full_Html' }
        ];
    }

    get isFullHtml() {
        return this.layoutMode === 'Full_Html';
    }

    get isManaged() {
        return this.layoutMode !== 'Full_Html';
    }

    handleLayoutModeChange(event) {
        this.layoutMode = event.detail.value;
        this.refreshPreview();
    }

    // ===== Field handlers =====
    handleTypeChange(event) {
        const row = this.rows.find((r) => r.type === event.detail.value);
        if (row) {
            this.applyRow(row);
        }
    }
    // #369 — the Brand selector. Named distinctly from handleBrandChange below
    // (that one is the per-type Brand Color Override text field).
    handleBrandSelectorChange(event) {
        const val = event.detail.value;
        if (val === '__add__') {
            this.showAddBrandForm = true;
            return;
        }
        if (val === '__manage__') {
            // The full Brands screen already exists as its own Command Hub tab —
            // navigate there rather than duplicating a list+edit UI inline.
            this.dispatchEvent(new CustomEvent('managebrands'));
            return;
        }
        this.selectedBrandId = val;
        this.loadTemplates();
    }

    // ===== #369 — inline "+ New Brand…" quick-create =====
    handleNewBrandNameChange(e) {
        this.newBrandName = e.target.value;
    }
    handleNewBrandOwaChange(e) {
        this.newBrandOwaId = e.detail.value;
    }
    handleNewBrandColorChange(e) {
        this.newBrandColor = e.target.value;
    }
    handleNewBrandCompanyChange(e) {
        this.newBrandCompany = e.target.value;
    }
    handleNewBrandLogoChange(e) {
        // Typing a URL manually supersedes the asset link (which would otherwise win).
        this.newBrandLogoUrl = e.target.value;
        this.newBrandLogoAssetKey = '';
    }
    async handleNewBrandLogoAssetChange(e) {
        const assetKey = e.detail.value;
        if (!assetKey) {
            this.newBrandLogoAssetKey = '';
            return;
        }
        const asset = this.logoAssets.find((a) => a.assetKey === assetKey);
        try {
            // Same asset-linking pattern as the per-type Logo field below and the
            // full Brands screen — publishes the asset's current file now (admin
            // session) and lands the resulting URL as a visible fallback/preview.
            const url = await resolveAssetPublicUrl({ assetId: asset.id });
            this.newBrandLogoAssetKey = assetKey;
            this.newBrandLogoUrl = url;
        } catch (error) {
            this.toast('Could not use this asset', this.errMsg(error), 'error');
        }
    }
    handleNewBrandFooterChange(e) {
        this.newBrandFooter = e.target.value;
    }

    handleCancelAddBrand() {
        this.showAddBrandForm = false;
        this.newBrandName = '';
        this.newBrandOwaId = '';
        this.newBrandColor = '#5A4FCF';
        this.newBrandCompany = '';
        this.newBrandLogoUrl = '';
        this.newBrandLogoAssetKey = '';
        this.newBrandFooter = '';
    }

    // Reads the CURRENT value straight off the rendered input, not the tracked
    // newBrandXxx properties — defensive against any change/input-event timing
    // gap between typing and clicking Save Brand.
    newBrandFieldValue(fieldName) {
        const el = this.template.querySelector('[data-field="' + fieldName + '"]');
        return el ? el.value : '';
    }

    async handleCreateBrand() {
        const name = this.newBrandFieldValue('name');
        if (!name || !name.trim()) {
            this.toast('Name required', 'Give the brand a name before saving.', 'warning');
            return;
        }
        this.isSavingBrand = true;
        try {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            const newId = await saveBrand({
                dto: {
                    name: name,
                    owaId: this.newBrandFieldValue('owaId'),
                    brandColor: this.newBrandFieldValue('brandColor'),
                    companyName: this.newBrandFieldValue('companyName'),
                    logoUrl: this.newBrandFieldValue('logoUrl'),
                    logoAssetKey: this.newBrandFieldValue('logoAssetKey'),
                    footerText: this.newBrandFieldValue('footerText'),
                    isActive: true
                }
            });
            this.toast('Saved', name + ' created.', 'success');
            this.handleCancelAddBrand();
            await this.loadBrands();
            this.selectedBrandId = newId;
            await this.loadTemplates();
        } catch (error) {
            // Diagnostic: show exactly what this client attempted to send, so a
            // failure here is provable rather than guessed at.
            this.toast('Save failed', '[sent name: "' + name + '"] ' + this.errMsg(error), 'error');
        } finally {
            this.isSavingBrand = false;
        }
    }
    handleSubjectChange(event) {
        this.subject = event.target.value;
    }
    handleBodyChange(event) {
        this.bodyHtml = event.target.value;
    }
    handleBrandChange(event) {
        this.brandColor = event.target.value;
    }
    handleLogoChange(event) {
        this.logoUrl = event.target.value;
        this.logoAssetKey = ''; // manual URL supersedes the asset link (which would otherwise win)
    }
    handleFooterChange(event) {
        this.footerText = event.target.value;
    }
    handleActiveChange(event) {
        this.isActive = event.target.checked;
    }
    handleTestEmailChange(event) {
        this.testEmail = event.target.value;
    }

    // ===== Actions =====
    async handleSave() {
        this.isSaving = true;
        try {
            const id = await saveTemplate({ data: this.currentData });
            this.recordId = id;
            this.toast('Saved', 'Email template saved.', 'success');
            await this.loadTemplates();
        } catch (error) {
            this.toast('Save failed', this.errMsg(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleReset() {
        try {
            const def = await getDefault({ type: this.selectedType });
            this.subject = def.subject || '';
            this.bodyHtml = def.bodyHtml || '';
            this.toast('Reset to default', 'Default content loaded — click Save to keep it.', 'info');
            this.refreshPreview();
        } catch (error) {
            this.toast('Error', this.errMsg(error), 'error');
        }
    }

    async refreshPreview() {
        try {
            const r = await renderPreview({ data: this.currentData });
            this.previewHtml = r.htmlBody;
        } catch (error) {
            this.previewHtml =
                '<p style="color:#c23934;padding:16px;font-family:sans-serif;">Preview error: ' +
                this.errMsg(error) +
                '</p>';
        }
        // previewHtml is not bound in the template, so setting it does not
        // re-render — push it into the iframe imperatively. The frame already
        // exists (refreshPreview runs after first render); renderedCallback is
        // the backstop for the first paint if it doesn't yet.
        this._previewDirty = true;
        this.updatePreviewFrame();
    }

    updatePreviewFrame() {
        const surface = this.template.querySelector('.preview-surface');
        if (surface && this._previewDirty) {
            // Render the email markup directly (not an iframe — Salesforce CSP
            // blocks iframe srcdoc/data: frames). lwc:dom="manual" lets us set
            // innerHTML; LWS sanitizes it (our content is style-only, no script).
            // The <!DOCTYPE>/<html>/<body> wrappers are dropped by the parser;
            // the inline-styled tables that carry the branding survive.
            // Justified suppression: the preview renders ONLY admin-authored
            // (FLS-gated) template HTML through the lwc:dom="manual" escape hatch,
            // Lightning Web Security strips scripts/event handlers, and there is no
            // LWC-native way to render arbitrary table+inline-style markup otherwise.
            // See code-analyzer.yml + DocGen_False_Positive_Report.md.
            // eslint-disable-next-line @lwc/lwc/no-inner-html
            surface.innerHTML = this.previewHtml || '';
            this._previewDirty = false;
        }
    }

    handleRefreshPreview() {
        this.refreshPreview();
    }

    async handleSendTest() {
        if (!this.testEmail) {
            this.toast('Enter an address', 'Type an email address to send the test to.', 'warning');
            return;
        }
        this.isTesting = true;
        try {
            await sendTest({ data: this.currentData, toAddress: this.testEmail });
            this.toast('Test sent', 'A test email was sent to ' + this.testEmail + '.', 'success');
        } catch (error) {
            this.toast('Test failed', this.errMsg(error), 'error');
        } finally {
            this.isTesting = false;
        }
    }

    renderedCallback() {
        // Backstop for the first paint: if the preview resolved before the
        // iframe existed, push it now that the frame is in the DOM.
        this.updatePreviewFrame();
    }

    // ===== Helpers =====
    errMsg(error) {
        const body = error && error.body;
        if (Array.isArray(body) && body[0] && typeof body[0].message === 'string') {
            return body[0].message;
        }
        if (body && typeof body.message === 'string' && body.message) {
            return body.message;
        }
        if (body && body.pageErrors && body.pageErrors[0] && body.pageErrors[0].message) {
            return String(body.pageErrors[0].message);
        }
        if (error && typeof error.message === 'string' && error.message) {
            return error.message;
        }
        return 'An unexpected error occurred.';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
