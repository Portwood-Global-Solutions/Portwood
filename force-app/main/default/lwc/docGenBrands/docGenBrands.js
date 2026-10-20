import { salesforceAssetUrl } from 'c/docGenAuthoringKit';
import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { loadScript } from 'lightning/platformResourceLoader';
import brandingResource from '@salesforce/resourceUrl/DocGenSigningBranding';
import getBrands from '@salesforce/apex/DocGenBrandController.getBrands';
import getBrandingSets from '@salesforce/apex/DocGenBrandController.getBrandingSets';
import saveBrand from '@salesforce/apex/DocGenBrandController.saveBrand';
import getOrgWideEmailAddresses from '@salesforce/apex/DocGenSetupController.getOrgWideEmailAddresses';
import resolveAssetPublicUrl from '@salesforce/apex/DocGenEmailTemplateController.resolveAssetPublicUrl';
import getAssets from '@salesforce/apex/DocGenController.getAssets';
import getSettingsFresh from '@salesforce/apex/DocGenSetupController.getSettingsFresh';

function initialsOf(name) {
    return (name || '')
        .split(' ')
        .filter(Boolean)
        .map((w) => w[0])
        .join('')
        .slice(0, 3)
        .toUpperCase();
}

function safeColor(value, fallback) {
    return /^#[0-9a-f]{6}$/i.test(value || '') ? value : fallback;
}
function foreground(hex) {
    const rgb = hex
        .slice(1)
        .match(/../g)
        .map((channel) => {
            const value = parseInt(channel, 16) / 255;
            return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
        });
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722 > 0.179 ? '#000000' : '#FFFFFF';
}
function safeHttps(value) {
    try {
        const url = new URL(value);
        return url.protocol === 'https:' && !url.username && !url.password ? url.href : '';
    } catch (_e) {
        return '';
    }
}

const PAGE_DEFAULTS = {
    version: 2,
    brandingSetId: '',
    mode: 'Standard',
    logoUrl: '',
    logoAssetKey: '',
    logoHeight: 56,
    logoAlignment: 'Left',
    bannerUrl: '',
    bannerAssetKey: '',
    bannerAlt: '',
    backgroundUrl: '',
    backgroundAssetKey: '',
    font: 'System',
    spacing: 'Comfortable',
    contentWidth: 1040,
    headerHtml: '',
    welcomeHtml: '',
    footerHtml: '',
    completionHtml: '',
    customCss: ''
};
function pageConfig(source) {
    try {
        return { ...PAGE_DEFAULTS, ...JSON.parse(source || '{}') };
    } catch (_e) {
        return { ...PAGE_DEFAULTS };
    }
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
    signingColor: '',
    signingHeaderColor: '',
    signingBackgroundColor: '',
    signingTitle: '',
    signingWelcomeText: '',
    signingFooterText: '',
    signingCompletionMessage: '',
    signingSupportUrl: '',
    isActive: true
};

export default class DocGenBrands extends LightningElement {
    @api embedded = false;
    get cardTitle() {
        return this.embedded ? null : 'Brands';
    }
    get cardIcon() {
        return this.embedded ? null : 'utility:apps';
    }
    get cardClass() {
        return this.embedded ? 'embedded-card' : '';
    }
    @track brands = [];
    @track brandingSets = [];
    searchTerm = '';
    themeNotice = '';
    @track isLoading = true;
    @track isSaving = false;
    @track showForm = false;
    @track form = { ...BLANK_FORM };
    @track owaOptions = [];
    @track orgDefaults = {};
    @track page = { ...PAGE_DEFAULTS };
    @track customSections = {};
    @track htmlNotice = '';
    contentReady = false;
    pendingImageCount = 0;
    _previewSignature;
    _imageRequests = {};
    _editSession = 0;

    // "…or override with an Asset file" — same Shared Asset picker pattern as
    // the Email Templates editor. logoAssetKey is PERSISTED on the brand: the
    // renderer resolves the asset's latest file to its public link at send
    // time, so replacing the asset image updates every brand email with no
    // re-save here.
    @track logoAssets = [];

    connectedCallback() {
        this.loadBrands();
        this.loadBrandingSets();
        this.loadLogoAssets();
        this.loadOrgDefaults();
        this.loadContentRenderer();
    }

    @wire(getOrgWideEmailAddresses)
    wiredOwas({ data }) {
        if (data) {
            this.owaOptions = data;
        }
    }

    async loadContentRenderer() {
        try {
            await loadScript(this, brandingResource + '/purify.min.js');
            await loadScript(this, brandingResource + '/branding-content.js');
            this.contentReady = true;
            this.renderedCallback();
        } catch (_e) {
            this.htmlNotice = 'HTML preview could not load. Reload Brands to try again.';
        }
    }

    renderedCallback() {
        if (!this.showForm || !this.contentReady) return;
        const tokens = {
            companyName: this.previewCompanyOrName,
            logoUrl: this.pageLogoUrl,
            bannerUrl: salesforceAssetUrl(this.page.bannerUrl),
            backgroundUrl: salesforceAssetUrl(this.page.backgroundUrl),
            title: this.pageTitle,
            welcomeText: this.pageWelcome,
            footerText: this.pageFooter,
            completionMessage: this.pageCompletion,
            supportUrl: this.pageSupportUrl
        };
        const signature = JSON.stringify([this.page, tokens]);
        if (signature === this._previewSignature) return;
        const states = {};
        let omitted = false;
        for (const section of ['header', 'welcome', 'footer', 'completion']) {
            const host = this.template.querySelector('[data-html-section="' + section + '"]');
            if (!host) return;
            const result = window.PortwoodBrandContent.render(
                host,
                this.isAdvanced ? this.page[section + 'Html'] : '',
                this.page.customCss,
                tokens
            );
            states[section] = result.rendered;
            omitted = omitted || result.omitted;
        }
        this._previewSignature = signature;
        this.customSections = states;
        this.htmlNotice = omitted
            ? 'Preview omitted unsupported markup or CSS. Scripts, forms, fixed positioning, and external stylesheets are not supported.'
            : '';
    }

    async loadOrgDefaults() {
        try {
            this.orgDefaults = (await getSettingsFresh()) || {};
        } catch (_e) {
            this.orgDefaults = {};
        }
    }

    async loadLogoAssets() {
        try {
            const assets = await getAssets();
            this.logoAssets = (assets || []).filter(
                (a) => a.isActive && a.latestVersionCvId && a.assetType === 'Image'
            );
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
        const session = this._editSession;
        this.pendingImageCount++;
        try {
            // Publish the asset's current file now (admin session) — send-time
            // resolution only reads. The URL also lands in the field as a
            // visible fallback/preview.
            const url = await resolveAssetPublicUrl({ assetId: asset.id });
            if (session !== this._editSession) return;
            this.form = { ...this.form, logoAssetKey: assetKey, logoUrl: url };
            this.toast(
                'Logo linked to Asset',
                'Signature emails and signing pages now use this asset’s latest image automatically. Save to apply.',
                'success'
            );
        } catch (error) {
            this.toast('Could not use this asset', this.errMsg(error), 'error');
        } finally {
            this.pendingImageCount--;
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

    async loadBrandingSets() {
        try {
            this.brandingSets = (await getBrandingSets()) || [];
            this.themeNotice = '';
        } catch (_e) {
            this.themeNotice = 'Salesforce themes could not load. You can still use the Brand colors below.';
        }
    }
    get brandingSetOptions() {
        const options = [
            { label: 'Use Brand colors and images', value: '' },
            ...this.brandingSets.map(({ label, value }) => ({ label, value }))
        ];
        if (this.page.brandingSetId && !this.brandingSets.some((set) => set.value === this.page.brandingSetId)) {
            options.push({ label: 'Previously linked theme (unavailable)', value: this.page.brandingSetId });
        }
        return options;
    }
    get liveTheme() {
        return this.brandingSets.find((set) => set.value === this.page.brandingSetId)?.theme || {};
    }
    get hasLiveTheme() {
        return !!this.page.brandingSetId;
    }
    handleSearch(event) {
        this.searchTerm = event.target.value || '';
    }
    handleRefresh() {
        this.loadBrands();
        this.loadBrandingSets();
    }

    get hasMatchingBrands() {
        return this.brandRows.length > 0;
    }
    get hasBrands() {
        return this.brands.length > 0;
    }

    get brandRows() {
        const term = this.searchTerm.trim().toLowerCase();
        return this.brands
            .filter((b) => [b.name, b.companyName, b.signingTitle].join(' ').toLowerCase().includes(term))
            .map((b) => {
                const config = pageConfig(b.signingPageConfig);
                const theme = this.brandingSets.find((set) => set.value === config.brandingSetId)?.theme || {};
                return {
                    ...b,
                    swatchStyle: 'background-color:' + safeColor(theme.color || b.brandColor, '#c9c9c9'),
                    rowClass: 'brand-row' + (this.form.id === b.id && this.showForm ? ' selected' : ''),
                    thumbnailStyle:
                        'background:' +
                        safeColor(theme.backgroundColor || b.signingBackgroundColor, '#F3F2F2') +
                        ';border-top-color:' +
                        safeColor(theme.color || b.signingColor || b.brandColor, '#5A4FCF'),
                    thumbnailTitle: b.signingTitle || 'Review and sign',
                    thumbnailCompany: b.companyName || b.name,
                    thumbnailLogo:
                        salesforceAssetUrl(theme.logoUrl) ||
                        salesforceAssetUrl(config.logoUrl) ||
                        salesforceAssetUrl(b.logoUrl),
                    themeLabel: config.brandingSetId ? 'Live Salesforce theme' : 'Brand colors',
                    initials: initialsOf(b.name),
                    statusLabel: b.isActive === false ? 'Inactive' : 'Active',
                    statusClass: b.isActive === false ? 'status-pill inactive' : 'status-pill active'
                };
            });
    }

    get formTitle() {
        return this.form.id ? 'Editing ' + this.form.name : 'New brand';
    }

    get saveDisabled() {
        return this.isSaving || this.pendingImageCount > 0;
    }

    get saveLabel() {
        if (this.pendingImageCount) return 'Linking image…';
        return this.isSaving ? 'Saving…' : this.form.id ? 'Save Changes' : 'Save Brand';
    }

    // ===== Live preview — reflects the form as it's typed, before saving =====
    get previewCompanyOrName() {
        return this.form.companyName.trim() || this.orgDefaults.Company_Name__c || 'Document signing';
    }
    get previewColor() {
        return safeColor(this.form.brandColor, '#5A4FCF');
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
        return !!this.previewLogoUrl;
    }

    get previewLogoUrl() {
        return (
            salesforceAssetUrl(this.form.logoUrl) || salesforceAssetUrl(this.orgDefaults.Signature_Email_Logo_Url__c)
        );
    }
    get placeholderGuide() {
        return '{{companyName}}, {{logoUrl}}, {{bannerUrl}}, {{backgroundUrl}}, {{title}}, {{welcomeText}}, {{footerText}}, {{completionMessage}}, {{supportUrl}}';
    }
    get pageModeOptions() {
        return ['Standard', 'Advanced'].map((value) => ({ label: value, value }));
    }
    get alignmentOptions() {
        return ['Left', 'Center', 'Right'].map((value) => ({ label: value, value }));
    }
    get fontOptions() {
        return [
            { label: 'System sans serif', value: 'System' },
            { label: 'Classic serif', value: 'Serif' },
            { label: 'Humanist sans serif', value: 'Humanist' }
        ];
    }
    get spacingOptions() {
        return ['Compact', 'Comfortable', 'Spacious'].map((value) => ({ label: value, value }));
    }
    get isAdvanced() {
        return this.page.mode === 'Advanced';
    }
    get hasCustomHeader() {
        return !!this.customSections.header;
    }
    get hasCustomWelcome() {
        return !!this.customSections.welcome;
    }
    get hasCustomFooter() {
        return !!this.customSections.footer;
    }
    get hasCustomCompletion() {
        return !!this.customSections.completion;
    }
    get pageLogoUrl() {
        return (
            salesforceAssetUrl(this.liveTheme.logoUrl) || salesforceAssetUrl(this.page.logoUrl) || this.previewLogoUrl
        );
    }
    get pageHasLogo() {
        return !!this.pageLogoUrl;
    }
    get pageBannerUrl() {
        return salesforceAssetUrl(this.page.bannerUrl);
    }
    get pageFont() {
        return (
            (/^[a-zA-Z0-9 ,"'_-]{1,180}$/.test(this.liveTheme.fontFamily || '') ? this.liveTheme.fontFamily : '') ||
            { Serif: 'Georgia, serif', Humanist: '"Trebuchet MS", Verdana, sans-serif' }[this.page.font] ||
            '"Salesforce Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
        );
    }
    get pagePadding() {
        return { Compact: '0.75rem', Spacious: '1.5rem' }[this.page.spacing] || '1rem';
    }
    get pageContentStyle() {
        return 'padding:' + this.pagePadding;
    }
    get pageLogoStyle() {
        return 'max-height:' + Math.max(24, Math.min(160, Number(this.page.logoHeight) || 56)) + 'px;';
    }
    get pagePreviewStyle() {
        const background = safeColor(
            this.liveTheme.backgroundColor,
            safeColor(this.form.signingBackgroundColor, '#F3F2F2')
        );
        const image = salesforceAssetUrl(this.page.backgroundUrl);
        const rgb = background
            .slice(1)
            .match(/../g)
            .map((v) => parseInt(v, 16))
            .join(',');
        return (
            'background-color:' +
            background +
            ';color:' +
            foreground(background) +
            ';font-family:' +
            this.pageFont +
            (image
                ? ';background-image:linear-gradient(rgba(' +
                  rgb +
                  ',0.92),rgba(' +
                  rgb +
                  ',0.92)),url("' +
                  image.replace(/["\\\r\n]/g, encodeURIComponent) +
                  '");background-size:cover'
                : '')
        );
    }
    get pageHeaderStyle() {
        const background = safeColor(this.liveTheme.headerColor, safeColor(this.form.signingHeaderColor, '#FFFFFF'));
        return (
            'background:' +
            background +
            ';color:' +
            foreground(background) +
            ';padding:' +
            this.pagePadding +
            ';justify-content:' +
            ({ Center: 'center', Right: 'flex-end' }[this.page.logoAlignment] || 'flex-start')
        );
    }
    get pageActionStyle() {
        const background = safeColor(this.liveTheme.color, safeColor(this.form.signingColor, this.previewColor));
        return 'background:' + background + ';color:' + foreground(background);
    }
    get pageTitle() {
        return this.form.signingTitle.trim() || 'Review and sign';
    }
    get pageWelcome() {
        return this.form.signingWelcomeText.trim() || 'Please review your document and complete the required fields.';
    }
    get pageFooter() {
        return (
            this.form.signingFooterText.trim() ||
            this.form.footerText.trim() ||
            this.orgDefaults.Signature_Email_Footer_Text__c
        );
    }
    get pageCompletion() {
        return (
            this.form.signingCompletionMessage ||
            'Your document has been signed and processed securely. You may close this window.'
        );
    }
    get pageSupportUrl() {
        return safeHttps(this.form.signingSupportUrl);
    }
    handleConfigChange(event) {
        const key = event.target.dataset.config;
        const value = event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
        this.page = { ...this.page, [key]: value };
        if (['logoUrl', 'bannerUrl', 'backgroundUrl'].includes(key)) {
            const image = key.slice(0, -3);
            this.page = { ...this.page, [image + 'AssetKey']: '' };
            this._imageRequests[image] = Symbol();
        }
    }

    async handlePageAssetChange(event) {
        const image = event.target.dataset.image;
        const assetKey = event.detail.value;
        const request = Symbol();
        const session = this._editSession;
        this._imageRequests[image] = request;
        if (!assetKey) {
            this.page = { ...this.page, [image + 'AssetKey']: '' };
            return;
        }
        const asset = this.logoAssets.find((item) => item.assetKey === assetKey);
        if (!asset) return;
        this.pendingImageCount++;
        try {
            const url = await resolveAssetPublicUrl({ assetId: asset.id });
            if (this._imageRequests[image] !== request || session !== this._editSession) return;
            this.page = { ...this.page, [image + 'AssetKey']: assetKey, [image + 'Url']: url };
        } catch (error) {
            this.toast('Image could not be linked', this.errMsg(error), 'error');
        } finally {
            this.pendingImageCount--;
        }
    }

    handleStarterLayout() {
        this.page = {
            ...this.page,
            mode: 'Advanced',
            headerHtml:
                '<div class="brand-heading"><img src="{{logoUrl}}" alt="" /><strong>{{companyName}}</strong></div>',
            welcomeHtml: '<section class="welcome-panel"><h1>{{title}}</h1><p>{{welcomeText}}</p></section>',
            footerHtml:
                '<div class="brand-footer"><span>{{footerText}}</span><a href="{{supportUrl}}">Get help</a></div>',
            completionHtml: '<p class="completion-copy">{{completionMessage}}</p>',
            customCss:
                '.brand-heading, .brand-footer { display: flex; align-items: center; justify-content: space-between; gap: 16px; }\n.brand-heading img { max-height: 64px; max-width: 180px; }\n.welcome-panel { padding: 16px 0; }\n.welcome-panel h1 { font-size: 28px; font-weight: 700; margin: 0 0 12px; }\n.completion-copy { font-size: 18px; line-height: 1.5; }\n@media (max-width: 600px) { .brand-heading, .brand-footer { flex-direction: column; align-items: flex-start; } }'
        };
    }

    handlePageChange(event) {
        this.form = { ...this.form, [event.target.dataset.field]: event.target.value };
    }

    handleAddNew() {
        this.form = { ...BLANK_FORM };
        this.page = { ...PAGE_DEFAULTS };
        this._editSession++;
        this._previewSignature = null;
        this.showForm = true;
    }

    handleEditRow(event) {
        const id = event.currentTarget.dataset.id;
        const brand = this.brands.find((b) => b.id === id);
        if (!brand) {
            return;
        }
        this.page = pageConfig(brand.signingPageConfig);
        this._editSession++;
        this._previewSignature = null;
        this.form = {
            id: brand.id,
            name: brand.name || '',
            owaId: brand.owaId || '',
            brandColor: brand.brandColor || '#5A4FCF',
            logoUrl: brand.logoUrl || '',
            logoAssetKey: brand.logoAssetKey || '',
            companyName: brand.companyName || '',
            footerText: brand.footerText || '',
            signingColor: brand.signingColor || '',
            signingHeaderColor: brand.signingHeaderColor || '',
            signingBackgroundColor: brand.signingBackgroundColor || '',
            signingTitle: brand.signingTitle || '',
            signingWelcomeText: brand.signingWelcomeText || '',
            signingFooterText: brand.signingFooterText || '',
            signingCompletionMessage: brand.signingCompletionMessage || '',
            signingSupportUrl: brand.signingSupportUrl || '',
            isActive: brand.isActive !== false
        };
        this.showForm = true;
    }

    handleCancel() {
        this._editSession++;
        this._previewSignature = null;
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
        if (this.saveDisabled) return;
        const controls = [...this.template.querySelectorAll('lightning-input, lightning-textarea')];
        if (controls.some((control) => !control.reportValidity())) return;
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
            signingColor: this.fieldValue('signingColor'),
            signingHeaderColor: this.fieldValue('signingHeaderColor'),
            signingBackgroundColor: this.fieldValue('signingBackgroundColor'),
            signingTitle: this.fieldValue('signingTitle'),
            signingWelcomeText: this.fieldValue('signingWelcomeText'),
            signingFooterText: this.fieldValue('signingFooterText'),
            signingCompletionMessage: this.fieldValue('signingCompletionMessage'),
            signingSupportUrl: this.fieldValue('signingSupportUrl'),
            signingPageConfig: JSON.stringify(this.page),
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
