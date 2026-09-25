import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getButtonConfigs from '@salesforce/apex/DocGenButtonAdminController.getButtonConfigs';
import getTemplateOptions from '@salesforce/apex/DocGenButtonAdminController.getTemplateOptions';
import getObjectRecordTypes from '@salesforce/apex/DocGenButtonAdminController.getObjectRecordTypes';
import saveButtonConfig from '@salesforce/apex/DocGenButtonAdminController.saveButtonConfig';
import getObjectOptions from '@salesforce/apex/DocGenController.getObjectOptions';

/**
 * docGenButtonBuilder
 * -------------------
 * Command Hub tab for creating/editing the one-click Portwood record-page buttons
 * (DocGen_Button__mdt) from the UI — no Setup > Custom Metadata spelunking.
 * Saves are async (Metadata API), so after a save we re-query on a short delay.
 */
export default class DocGenButtonBuilder extends LightningElement {
    @track buttons = [];
    @track objectOptions = [];
    @track templateOptions = [];
    @track recordTypeOptions = [];
    @track selectedRecordTypes = [];
    @track form = blank();
    showForm = false;
    loading = true;
    saving = false;

    outputFormatLabels = {
        Word: 'Word (DOCX)',
        Excel: 'Excel (XLSX)',
        PowerPoint: 'PowerPoint (PPTX)',
        HTML: 'HTML',
        PDF: 'PDF'
    };

    connectedCallback() {
        this.init();
    }

    async init() {
        try {
            const [objs, tpls] = await Promise.all([getObjectOptions(), getTemplateOptions()]);
            this.objectOptions = (objs || []).map((o) => ({ label: o.label, value: o.value }));
            this.templateOptions = (tpls || []).map((o) => ({
                label: o.label,
                value: o.value,
                templateType: o.templateType,
                lockOutputFormat: o.lockOutputFormat
            }));
            await this.refreshButtons();
        } catch (e) {
            this.toast('Could not load', this.msg(e), 'error');
        } finally {
            this.loading = false;
        }
    }

    async refreshButtons() {
        const rows = await getButtonConfigs();
        this.buttons = (rows || []).map((b) => ({
            ...b,
            recordTypesLabel: b.recordTypeDeveloperNames || 'All record types',
            statusBadgeClass: b.active ? 'slds-badge slds-theme_success' : 'slds-badge slds-badge_inverse',
            statusLabel: b.active ? 'Active' : 'Inactive'
        }));
    }

    get hasButtons() {
        return this.buttons.length > 0;
    }
    get newLabel() {
        return this.showForm ? 'Close' : 'New Button';
    }
    get saveLabel() {
        return this.saving ? 'Saving…' : 'Save Button';
    }
    get formTitle() {
        return this.form.developerName ? 'Edit button' : 'New button';
    }
    get hasRecordTypes() {
        return this.recordTypeOptions.length > 0;
    }
    get selectedTemplate() {
        return this.templateOptions.find((t) => t.value === this.form.template);
    }
    get outputFormatOptions() {
        return this.allowedOutputFormatsForTemplate(this.selectedTemplate);
    }

    handleToggleForm() {
        this.showForm = !this.showForm;
        if (this.showForm && !this.form.developerName) {
            this.form = blank();
            this.selectedRecordTypes = [];
            this.recordTypeOptions = [];
        }
    }

    async handleEdit(event) {
        const dn = event.currentTarget.dataset.name;
        const b = this.buttons.find((x) => x.developerName === dn);
        if (!b) return;
        this.form = {
            developerName: b.developerName,
            label: b.label,
            objectApiName: b.objectApiName,
            template: b.templateApiName ? 'key:' + b.templateApiName : b.templateId ? 'id:' + b.templateId : '',
            documentTitle: b.documentTitle || '',
            outputFormatOverride: b.outputFormatOverride || '',
            saveToRecord: !!b.saveToRecord,
            sortOrder: b.sortOrder,
            active: b.active !== false
        };
        await this.loadRecordTypes(b.objectApiName);
        this.selectedRecordTypes = (b.recordTypeDeveloperNames || '')
            .split(',')
            .map((s) => s.trim())
            .filter((s) => s);
        this.showForm = true;
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const val = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.form = { ...this.form, [field]: val };
    }

    async handleObjectChange(event) {
        const obj = event.detail.value;
        this.form = { ...this.form, objectApiName: obj };
        this.selectedRecordTypes = [];
        await this.loadRecordTypes(obj);
    }

    async loadRecordTypes(obj) {
        this.recordTypeOptions = [];
        if (!obj) return;
        try {
            const rts = await getObjectRecordTypes({ objectApiName: obj });
            this.recordTypeOptions = (rts || []).map((o) => ({ label: o.label, value: o.value }));
        } catch (e) {
            // Objects without record types just show none.
            this.recordTypeOptions = [];
        }
    }

    handleRecordTypeChange(event) {
        this.selectedRecordTypes = event.detail.value;
    }

    handleComboChange(event) {
        const field = event.target.dataset.field;
        const next = { ...this.form, [field]: event.detail.value };
        if (field === 'template') {
            next.outputFormatOverride = this.normalizeOutputFormatForTemplate(next.outputFormatOverride, next.template);
        }
        this.form = next;
    }

    async handleSave() {
        if (!this.form.objectApiName) {
            this.toast('Object required', 'Pick the object whose record page hosts the button.', 'warning');
            return;
        }
        if (!this.form.template) {
            this.toast('Template required', 'Pick the template this button generates.', 'warning');
            return;
        }
        if (!this.form.label || !this.form.label.trim()) {
            this.toast('Label required', 'Give the button a label.', 'warning');
            return;
        }
        const outputFormatOverride = this.normalizeOutputFormatForTemplate(
            this.form.outputFormatOverride,
            this.form.template
        );
        const dto = {
            developerName: this.form.developerName || null,
            label: this.form.label.trim(),
            objectApiName: this.form.objectApiName,
            templateApiName: this.form.template.startsWith('key:') ? this.form.template.substring(4) : null,
            templateId: this.form.template.startsWith('id:') ? this.form.template.substring(3) : null,
            documentTitle: this.form.documentTitle || null,
            outputFormatOverride: outputFormatOverride || null,
            saveToRecord: !!this.form.saveToRecord,
            sortOrder: this.form.sortOrder === '' || this.form.sortOrder == null ? null : this.form.sortOrder,
            active: this.form.active !== false,
            recordTypeDeveloperNames: this.selectedRecordTypes.length ? this.selectedRecordTypes.join(',') : null
        };
        this.saving = true;
        try {
            await saveButtonConfig({ cfg: dto });
            this.toast(
                'Saving button',
                'Your button is deploying (custom metadata) — it appears here in a few seconds and on matching record pages after the deploy finishes.',
                'success'
            );
            this.showForm = false;
            this.form = blank();
            this.selectedRecordTypes = [];
            // Metadata deploy is async — refresh shortly, then once more.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this.refreshButtons(), 4000);
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this.refreshButtons(), 9000);
        } catch (e) {
            this.toast('Save failed', this.msg(e), 'error');
        } finally {
            this.saving = false;
        }
    }

    handleDeactivate(event) {
        const dn = event.currentTarget.dataset.name;
        const b = this.buttons.find((x) => x.developerName === dn);
        if (!b) return;
        this.form = {
            developerName: b.developerName,
            label: b.label,
            objectApiName: b.objectApiName,
            template: b.templateApiName ? 'key:' + b.templateApiName : b.templateId ? 'id:' + b.templateId : '',
            documentTitle: b.documentTitle || '',
            outputFormatOverride: b.outputFormatOverride || '',
            saveToRecord: !!b.saveToRecord,
            sortOrder: b.sortOrder,
            active: false
        };
        this.selectedRecordTypes = (b.recordTypeDeveloperNames || '')
            .split(',')
            .map((s) => s.trim())
            .filter((s) => s);
        this.handleSave();
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error.';
    }
    normalizeOutputFormatForTemplate(rawValue, templateValue) {
        if (!rawValue) {
            return '';
        }
        const aliases = {
            DOCX: 'Word',
            WORD: 'Word',
            XLSX: 'Excel',
            XLSM: 'Excel',
            EXCEL: 'Excel',
            PPTX: 'PowerPoint',
            PPT: 'PowerPoint',
            POWERPOINT: 'PowerPoint',
            PDF: 'PDF',
            HTML: 'HTML'
        };
        const value = aliases[String(rawValue).trim().toUpperCase()] || rawValue;
        const template = this.templateOptions.find((t) => t.value === templateValue);
        if (!template || template.lockOutputFormat) {
            return '';
        }
        return this.allowedOutputFormatsForTemplate(template).some((o) => o.value === value) ? value : '';
    }
    allowedOutputFormatsForTemplate(template) {
        const options = [{ label: 'Template default', value: '' }];
        if (!template || template.lockOutputFormat) {
            return options;
        }
        const type = template.templateType;
        if (type === 'Word') {
            options.push({ label: 'PDF', value: 'PDF' }, { label: this.outputFormatLabels.Word, value: 'Word' });
        } else if (type === 'Excel') {
            options.push({ label: this.outputFormatLabels.Excel, value: 'Excel' });
        } else if (type === 'PowerPoint') {
            options.push({ label: this.outputFormatLabels.PowerPoint, value: 'PowerPoint' });
        } else if (type === 'HTML' || type === 'Canvas') {
            options.push({ label: 'PDF', value: 'PDF' });
        } else if (type === 'PDF') {
            options.push({ label: 'PDF', value: 'PDF' });
        }
        return options;
    }
}

function blank() {
    return {
        developerName: null,
        label: '',
        objectApiName: '',
        template: '',
        documentTitle: '',
        outputFormatOverride: '',
        saveToRecord: false,
        sortOrder: null,
        active: true
    };
}
