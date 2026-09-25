import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { CurrentPageReference } from 'lightning/navigation';
import getEmailButtons from '@salesforce/apex/DocGenButtonController.getEmailButtons';
import getEmailTemplateOptions from '@salesforce/apex/DocGenButtonController.getEmailTemplateOptions';
import getEmailPreviewHtml from '@salesforce/apex/DocGenButtonController.getEmailPreviewHtml';
import getEmailCandidates from '@salesforce/apex/DocGenButtonController.getEmailCandidates';
import sendGeneratedEmail from '@salesforce/apex/DocGenButtonController.sendGeneratedEmail';
import { sanitizePreviewHtml } from 'c/docGenUtils';
import { scopeHtmlForInlinePreview } from 'c/docGenAuthoringKit';

export default class DocGenSendEmailButton extends LightningElement {
    _recordId;
    _pageRef;
    _started = false;
    _waitTimer;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.maybeStart();
    }

    @api objectApiName;

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        this._pageRef = pageRef;
        const pageRecordId = this.resolveRecordId();
        if (pageRecordId && !this._recordId) {
            this._recordId = pageRecordId;
            this.maybeStart();
        }
    }

    loading = true;
    sending = false;
    screen = 'select';
    statusMessage = 'Preparing...';
    errorMessage;
    options = [];
    selectedButton;
    selectedTemplate;
    previewHtml;
    existingEmailOptions = [];
    selectedExistingEmails = [];
    manualEmails = '';
    subject = '';
    body = '';

    connectedCallback() {
        this.maybeStart();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._waitTimer = setTimeout(() => {
            if (!this._started) {
                this.fail('Could not determine the record. Please reopen the record and try again.');
            }
        }, 4000);
    }

    renderedCallback() {
        if (this.screen !== 'preview' || !this.previewHtml) {
            return;
        }
        const host = this.template.querySelector('.preview-html');
        if (host && host.dataset.rendered !== String(this.previewHtml.length)) {
            // The merged HTML contains record data that is not HTML-escaped, so it is hardened first
            // (scripts, handlers, frames, unsafe URLs removed) and its CSS is scoped to the preview
            // page so it cannot restyle the page behind the modal. Same pattern as the Designer preview.
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM write of sanitizePreviewHtml + scopeHtmlForInlinePreview output
            host.innerHTML = scopeHtmlForInlinePreview(sanitizePreviewHtml(this.previewHtml));
            host.dataset.rendered = String(this.previewHtml.length);
        }
    }

    disconnectedCallback() {
        if (this._waitTimer) {
            clearTimeout(this._waitTimer);
        }
    }

    get effectiveRecordId() {
        return this.resolveRecordId();
    }

    resolveRecordId() {
        if (this._recordId) {
            return this._recordId;
        }
        const pageRef = this._pageRef;
        const state = pageRef && pageRef.state;
        const attributes = pageRef && pageRef.attributes;
        const directRecordId = (state && (state.recordId || state.c__recordId)) || (attributes && attributes.recordId);
        if (directRecordId) {
            return directRecordId;
        }
        const contextRecordId = this.recordIdFromContext(state && state.inContextOfRef);
        if (contextRecordId) {
            return contextRecordId;
        }
        return this.recordIdFromUrl();
    }

    recordIdFromContext(encodedContext) {
        if (!encodedContext) {
            return null;
        }
        try {
            const encoded = encodedContext.startsWith('1.') ? encodedContext.substring(2) : encodedContext;
            const normalized = encoded.replace(/-/g, '+').replace(/_/g, '/');
            const decoded = JSON.parse(atob(normalized));
            return decoded && decoded.attributes && decoded.attributes.recordId;
        } catch (e) {
            return null;
        }
    }

    recordIdFromUrl() {
        const path = window && window.location && window.location.pathname;
        if (!path) {
            return null;
        }
        const match = path.match(/\/lightning\/r\/[^/]+\/([a-zA-Z0-9]{15,18})(?:\/|$)/);
        return match ? match[1] : null;
    }

    maybeStart() {
        const recordId = this.effectiveRecordId;
        if (this._started || !recordId) {
            return;
        }
        this._recordId = recordId;
        this._started = true;
        if (this._waitTimer) {
            clearTimeout(this._waitTimer);
        }
        this.init();
    }

    async init() {
        try {
            const opts = await getEmailButtons({ recordId: this.effectiveRecordId });
            if (!opts || opts.length === 0) {
                this.fail('No Portwood Send Email button is configured for this record type.');
                return;
            }
            // The template list depends on the record and the button (a button can pin one
            // template; otherwise only templates built for this record's object are offered).
            const templates = await getEmailTemplateOptions({
                recordId: this.effectiveRecordId,
                configDeveloperName: opts[0].developerName
            });
            this.options = opts.map((opt) => ({
                ...opt,
                value: opt.developerName,
                label: 'Preview/Send Email'
            }));
            this.selectedButton = this.options[0].developerName;
            this.templateOptions = (templates || []).map((template) => ({
                ...template,
                label: this.friendlyTemplateLabel(template.label)
            }));
            this.selectedTemplate = this.templateOptions.length ? this.templateOptions[0].value : null;
            this.loading = false;
        } catch (e) {
            this.fail(this.toMessage(e));
        }
    }

    get isSelectScreen() {
        return this.screen === 'select';
    }

    get isPreviewScreen() {
        return this.screen === 'preview';
    }

    get isComposeScreen() {
        return this.screen === 'compose';
    }

    get currentStepIndex() {
        const order = { select: 0, preview: 1, compose: 2 };
        return order[this.screen] ?? 0;
    }

    get selectStepClass() {
        if (this.screen === 'select') {
            return 'stepper-step stepper-step-active';
        }
        return this.currentStepIndex > 0 ? 'stepper-step stepper-step-complete' : 'stepper-step';
    }

    get previewStepClass() {
        if (this.screen === 'preview') {
            return 'stepper-step stepper-step-active';
        }
        return this.currentStepIndex > 1 ? 'stepper-step stepper-step-complete' : 'stepper-step';
    }

    get composeStepClass() {
        if (this.screen === 'compose') {
            return 'stepper-step stepper-step-active';
        }
        return 'stepper-step';
    }

    get selectLineClass() {
        return this.currentStepIndex > 0 ? 'stepper-line stepper-line-complete' : 'stepper-line';
    }

    get previewLineClass() {
        return this.currentStepIndex > 1 ? 'stepper-line stepper-line-complete' : 'stepper-line';
    }

    get hasOptions() {
        return this.options.length > 0;
    }

    templateOptions = [];

    get hasTemplateOptions() {
        return this.templateOptions.length > 0;
    }

    get hasExistingEmailOptions() {
        return this.existingEmailOptions.length > 0;
    }

    get hasNoExistingEmailOptions() {
        return !this.hasExistingEmailOptions;
    }

    get disablePreviewNext() {
        return this.loading || !this.previewHtml || this.previewHtml.includes('Preview is unavailable');
    }

    get selectedExistingEmail() {
        return this.selectedExistingEmails.length ? this.selectedExistingEmails[0] : '';
    }

    get disableNext() {
        return !this.selectedButton || !this.selectedTemplate || this.loading;
    }

    get disableSend() {
        return (
            this.sending ||
            !this.hasRichTextContent(this.subject) ||
            !this.hasRichTextContent(this.body) ||
            (!this.selectedExistingEmails.length && !this.manualEmails)
        );
    }

    hasRichTextContent(value) {
        if (!value) {
            return false;
        }
        return (
            value
                .replace(/<[^>]*>/g, '')
                .replace(/&nbsp;/g, ' ')
                .trim().length > 0
        );
    }

    friendlyTemplateLabel(label) {
        return label ? label.replace(/\s+\([^)]+\)$/, '') : label;
    }

    handleButtonChoice(event) {
        this.selectedButton = event.detail.value;
    }

    handleTemplateChoice(event) {
        this.selectedTemplate = event.detail.value;
    }

    async handleNextToPreview() {
        this.loading = true;
        this.statusMessage = 'Generating preview...';
        this.errorMessage = null;
        try {
            this.previewHtml = await getEmailPreviewHtml({
                recordId: this.effectiveRecordId,
                configDeveloperName: this.selectedButton,
                templateReference: this.selectedTemplate
            });
            this.screen = 'preview';
            return true;
        } catch (e) {
            this.fail(this.toMessage(e));
            return false;
        } finally {
            this.loading = false;
        }
    }

    async handleNextToCompose() {
        this.loading = true;
        this.statusMessage = 'Loading recipients...';
        try {
            const candidates = await getEmailCandidates({ recordId: this.effectiveRecordId });
            this.existingEmailOptions = candidates || [];
            this.screen = 'compose';
            return true;
        } catch (e) {
            this.fail(this.toMessage(e));
            return false;
        } finally {
            this.loading = false;
        }
    }

    async handleStepClick(event) {
        const target = event.currentTarget.dataset.step;
        const order = { select: 0, preview: 1, compose: 2 };
        const targetIndex = order[target];
        const currentIndex = this.currentStepIndex;

        if (targetIndex === undefined || this.loading || this.sending || targetIndex === currentIndex) {
            return;
        }

        if (targetIndex < currentIndex) {
            this.screen = target;
            this.errorMessage = null;
            return;
        }

        if (target === 'preview') {
            await this.handleNextToPreview();
            return;
        }

        if (target === 'compose') {
            let canCompose = true;
            if (this.screen === 'select') {
                canCompose = await this.handleNextToPreview();
            }
            if (canCompose) {
                await this.handleNextToCompose();
            }
        }
    }

    handleBackToSelect() {
        this.screen = 'select';
        this.errorMessage = null;
    }

    handleBackToPreview() {
        this.screen = 'preview';
        this.errorMessage = null;
    }

    handleExistingChange(event) {
        this.selectedExistingEmails = event.detail.value ? [event.detail.value] : [];
    }

    handleField(event) {
        this[event.target.dataset.field] = event.target.value;
    }

    async handleSend() {
        const recipients = [...this.selectedExistingEmails, this.manualEmails].filter((value) => value);
        const recordId = this.effectiveRecordId;
        this.sending = true;
        this.loading = true;
        this.statusMessage = 'Generating document and sending email...';
        try {
            const res = await sendGeneratedEmail({
                recordId,
                configDeveloperName: this.selectedButton,
                templateReference: this.selectedTemplate,
                toAddresses: recipients,
                subject: this.subject,
                body: this.body
            });
            if (!res || !res.success) {
                this.fail((res && res.errorMessage) || 'Email could not be sent.');
                return;
            }
            this.showToast('Email sent', `${res.fileName} was saved to this record and sent.`, 'success');
            this.close();
        } catch (e) {
            this.fail(this.toMessage(e));
        } finally {
            this.sending = false;
            this.loading = false;
        }
    }

    fail(message) {
        this.loading = false;
        this.sending = false;
        this.errorMessage = message;
        this.showToast('Could not send email', message, 'error');
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleClose() {
        this.close();
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    toMessage(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'Unexpected error.';
    }
}
