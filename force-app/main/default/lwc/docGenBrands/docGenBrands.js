import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getBrands from '@salesforce/apex/DocGenBrandController.getBrands';
import saveBrand from '@salesforce/apex/DocGenBrandController.saveBrand';
import getOrgWideEmailAddresses from '@salesforce/apex/DocGenSetupController.getOrgWideEmailAddresses';
import resolveAssetPublicUrl from '@salesforce/apex/DocGenEmailTemplateController.resolveAssetPublicUrl';
import getAssets from '@salesforce/apex/DocGenController.getAssets';

function initialsOf(name) {
    return (name || '')
        .split(' ')
        .filter(Boolean)
        .map((w) => w[0])
        .join('')
        .slice(0, 3)
        .toUpperCase();
}

const BLANK_FORM = {
    id: null,
    name: '',
    owaId: '',
    brandColor: '#5A4FCF',
    logoUrl: '',
    logoAssetKey: '',
    companyName: '',
    footerText: '',
    isActive: true
};

export default class DocGenBrands extends LightningElement {
    @track brands = [];
    @track isLoading = true;
    @track isSaving = false;
    @track showForm = false;
    @track form = { ...BLANK_FORM };
    @track owaOptions = [];

    // "…or override with an Asset file" — same Shared Asset picker pattern as
    // the Email Templates editor. logoAssetKey is PERSISTED on the brand: the
    // renderer resolves the asset's latest file to its public link at send
    // time, so replacing the asset image updates every brand email with no
    // re-save here.
    @track logoAssets = [];

    connectedCallback() {
        this.loadBrands();
        this.loadLogoAssets();
    }

    @wire(getOrgWideEmailAddresses)
    wiredOwas({ data }) {
        if (data) {
            this.owaOptions = data;
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
            this.form = { ...this.form, logoAssetKey: '' };
            return;
        }
        const asset = this.logoAssets.find((a) => a.assetKey === assetKey);
        try {
            // Publish the asset's current file now (admin session) — send-time
            // resolution only reads. The URL also lands in the field as a
            // visible fallback/preview.
            const url = await resolveAssetPublicUrl({ assetId: asset.id });
            this.form = { ...this.form, logoAssetKey: assetKey, logoUrl: url };
            this.toast(
                'Logo linked to Asset',
                'Signature emails now use this asset’s latest image automatically. Save to apply.',
                'success'
            );
        } catch (error) {
            this.toast('Could not use this asset', this.errMsg(error), 'error');
        }
    }

    async loadBrands() {
        this.isLoading = true;
        try {
            this.brands = await getBrands();
        } catch (error) {
            this.toast('Error loading brands', this.errMsg(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    get hasBrands() {
        return this.brands.length > 0;
    }

    get brandRows() {
        return this.brands.map((b) => ({
            ...b,
            swatchStyle: 'background-color:' + (b.brandColor || '#c9c9c9'),
            initials: initialsOf(b.name),
            statusLabel: b.isActive === false ? 'Inactive' : 'Active',
            statusClass: b.isActive === false ? 'status-pill inactive' : 'status-pill active'
        }));
    }

    get formTitle() {
        return this.form.id ? 'Editing ' + this.form.name : 'New brand';
    }

    get saveLabel() {
        return this.isSaving ? 'Saving…' : this.form.id ? 'Save Changes' : 'Save Brand';
    }

    // ===== Live preview — reflects the form as it's typed, before saving =====
    get previewCompanyOrName() {
        return this.form.companyName || this.form.name || 'Your Company';
    }
    get previewColor() {
        return this.form.brandColor || '#5A4FCF';
    }
    get previewHeaderStyle() {
        return 'background-color:' + this.previewColor;
    }
    get previewCtaStyle() {
        return 'background-color:' + this.previewColor;
    }
    get previewInitials() {
        return initialsOf(this.form.name);
    }
    get previewHasInitials() {
        return this.previewInitials.length > 0 && !this.previewHasLogo;
    }
    // Mirrors DocGenEmailTemplateService.wrapChrome's real fallback: an image
    // if a logo URL resolved, else plain company-name text — no badge at all.
    get previewHasLogo() {
        return !!(this.form.logoUrl && this.form.logoUrl.trim());
    }

    handleAddNew() {
        this.form = { ...BLANK_FORM };
        this.showForm = true;
    }

    handleEditRow(event) {
        const id = event.currentTarget.dataset.id;
        const brand = this.brands.find((b) => b.id === id);
        if (!brand) {
            return;
        }
        this.form = {
            id: brand.id,
            name: brand.name || '',
            owaId: brand.owaId || '',
            brandColor: brand.brandColor || '#5A4FCF',
            logoUrl: brand.logoUrl || '',
            logoAssetKey: brand.logoAssetKey || '',
            companyName: brand.companyName || '',
            footerText: brand.footerText || '',
            isActive: brand.isActive !== false
        };
        this.showForm = true;
    }

    handleCancel() {
        this.showForm = false;
        this.form = { ...BLANK_FORM };
    }

    handleNameChange(e) {
        this.form = { ...this.form, name: e.target.value };
    }
    handleOwaChange(e) {
        this.form = { ...this.form, owaId: e.detail.value };
    }
    handleColorChange(e) {
        this.form = { ...this.form, brandColor: e.target.value };
    }
    handleLogoChange(e) {
        // Typing a URL manually supersedes the asset link (which would otherwise win).
        this.form = { ...this.form, logoUrl: e.target.value, logoAssetKey: '' };
    }
    handleCompanyChange(e) {
        this.form = { ...this.form, companyName: e.target.value };
    }
    handleFooterChange(e) {
        this.form = { ...this.form, footerText: e.target.value };
    }
    handleActiveChange(e) {
        this.form = { ...this.form, isActive: e.target.checked };
    }

    // Reads the CURRENT value straight off the rendered input, not the tracked
    // `form` object — defensive against any change/input-event timing gap
    // between typing and clicking Save.
    fieldValue(fieldName) {
        const el = this.template.querySelector('[data-field="' + fieldName + '"]');
        if (!el) {
            return this.form[fieldName];
        }
        return fieldName === 'isActive' ? el.checked : el.value;
    }

    async handleSave() {
        const name = this.fieldValue('name');
        if (!name || !name.trim()) {
            this.toast('Name required', 'Give the brand a name before saving.', 'warning');
            return;
        }
        const dto = {
            id: this.form.id,
            name: name,
            owaId: this.fieldValue('owaId'),
            brandColor: this.fieldValue('brandColor'),
            logoUrl: this.fieldValue('logoUrl'),
            logoAssetKey: this.fieldValue('logoAssetKey'),
            companyName: this.fieldValue('companyName'),
            footerText: this.fieldValue('footerText'),
            isActive: this.fieldValue('isActive')
        };
        this.isSaving = true;
        try {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveBrand({ dto });
            this.toast('Saved', name + ' saved.', 'success');
            this.showForm = false;
            this.form = { ...BLANK_FORM };
            await this.loadBrands();
        } catch (error) {
            // Diagnostic: show exactly what this client attempted to send, so a
            // failure here is provable rather than guessed at.
            this.toast('Save failed', '[sent name: "' + name + '"] ' + this.errMsg(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    errMsg(error) {
        const body = error && error.body;
        if (Array.isArray(body) && body[0] && typeof body[0].message === 'string') {
            return body[0].message;
        }
        if (body && typeof body.message === 'string' && body.message) {
            return body.message;
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
