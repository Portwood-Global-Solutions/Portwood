import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getPreparationUrl from '@salesforce/apex/DocGenSignaturePreparationController.getPreparationUrl';
import getContext from '@salesforce/apex/DocGenSignaturePreparationController.getContext';
import getPendingSignatureRequests from '@salesforce/apex/DocGenSignatureSenderController.getPendingSignatureRequests';

export default class DocGenSignatureSender extends NavigationMixin(LightningElement) {
    _recordId;
    _connected = false;
    _generation = 0;
    modalOpen = false;
    showSourceChooser = true;
    source;
    pdfSource;
    templateStarted = false;
    pdfComplete = false;
    templateComplete = false;
    editorUrl;
    editorOrigin;
    error;
    composerError;
    requests = [];
    drafts = [];
    loading = false;
    nonce;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (this._connected && value) this.refreshRequests();
    }
    connectedCallback() {
        this._connected = true;
        this._messageHandler = this.handleEditorMessage.bind(this);
        window.addEventListener('message', this._messageHandler);
        if (this.recordId) this.refreshRequests();
    }
    disconnectedCallback() {
        window.removeEventListener('message', this._messageHandler);
        this._connected = false;
    }
    renderedCallback() {
        if (this._focusSourceChooser && this.showSourceChooser && this.modalOpen) {
            this._focusSourceChooser = false;
            this.template.querySelector('.source-choices button')?.focus();
        }
        if (this._returnFocus && !this.modalOpen) {
            this._returnFocus = false;
            const button = this._launchButton?.isConnected
                ? this._launchButton
                : this.template.querySelector('.new-request');
            button?.focus();
        }
    }
    get hasRequests() {
        return this.requests.length > 0;
    }
    get hasDrafts() {
        return this.drafts.length > 0;
    }
    get hasPdfEditor() {
        return !!this.editorUrl;
    }
    get showPdfLoading() {
        return this.loading && !this.showSourceChooser && this.source !== 'templates';
    }
    get visibleComposerError() {
        return !this.showSourceChooser && this.source !== 'templates' ? this.composerError : null;
    }
    get hasPreparation() {
        return this.hasPdfEditor || this.templateStarted;
    }
    get hidePdfEditor() {
        return this.showSourceChooser || this.source === 'templates';
    }
    get hideTemplateEditor() {
        return this.showSourceChooser || this.source !== 'templates';
    }
    get showChangeSource() {
        return !this.showSourceChooser;
    }
    get isComplete() {
        return this.source === 'templates' ? this.templateComplete : this.pdfComplete;
    }
    get sourceActionLabel() {
        return this.isComplete ? 'New request' : 'Change source';
    }
    get modalTitle() {
        if (this.showSourceChooser) return 'New signature request';
        if (this.isComplete) return 'Signature request created';
        return this.source === 'templates' ? 'Prepare a Portwood template' : 'Prepare your PDF';
    }
    async refreshRequests() {
        try {
            const [requests, context] = await Promise.all([
                getPendingSignatureRequests({ relatedRecordId: this.recordId }),
                getContext({ recordId: this.recordId })
            ]);
            this.requests = requests.filter((request) => request.status !== 'Draft').slice(0, 5);
            this.drafts = (context.drafts || []).map((draft) => ({
                id: draft.Id,
                title: draft.Document_Title_Format__c || draft.portwoodglobal__Document_Title_Format__c || draft.Name
            }));
            this.error = null;
        } catch (err) {
            this.error = this.errorText(err);
        }
    }
    resetPreparation() {
        this._generation++;
        this.editorUrl = null;
        this.editorOrigin = null;
        this._pendingSource = null;
        this.source = null;
        this.pdfSource = null;
        this.templateStarted = false;
        this.pdfComplete = false;
        this.templateComplete = false;
        this.composerError = null;
        this.loading = false;
    }
    openComposer(event) {
        this._launchButton = event?.currentTarget;
        const draft = event?.currentTarget?.dataset?.draft;
        this.resetPreparation();
        this.modalOpen = true;
        this.showSourceChooser = !draft;
        if (draft) {
            this.source = 'upload';
            this.preparePdf('upload', draft);
        } else {
            this._focusSourceChooser = true;
        }
    }
    chooseSource(event) {
        const source = event.currentTarget.dataset.source;
        if (!['upload', 'files', 'templates'].includes(source)) return;
        this.source = source;
        this.showSourceChooser = false;
        this.composerError = null;
        if (source === 'templates') {
            this.templateStarted = true;
        } else if (this.editorUrl && !this.pdfComplete) {
            // The frame stays mounted, so returning to the same source resumes its exact step.
            if (this.pdfSource !== source) {
                this.pdfSource = source;
                this._pendingSource = source;
                this.sendSourceToEditor();
            }
        } else {
            this.pdfComplete = false;
            this.preparePdf(source);
        }
    }
    async preparePdf(source, draft = '') {
        const generation = ++this._generation;
        this.loading = true;
        this.pdfSource = source;
        try {
            const path = await getPreparationUrl({ recordId: this.recordId });
            if (!this.modalOpen || generation !== this._generation) return;
            this.nonce = Array.from(crypto.getRandomValues(new Uint32Array(4)), (n) => n.toString(16)).join('');
            this.editorUrl =
                path +
                '&source=' +
                encodeURIComponent(source) +
                '&draftId=' +
                encodeURIComponent(draft) +
                '&parentOrigin=' +
                encodeURIComponent(window.location.origin) +
                '&nonce=' +
                this.nonce;
        } catch (err) {
            if (generation === this._generation) this.composerError = this.errorText(err);
        } finally {
            if (generation === this._generation) this.loading = false;
        }
    }
    changeSource() {
        if (this.isComplete) this.resetPreparation();
        this.showSourceChooser = true;
        this._focusSourceChooser = true;
    }
    closeComposer() {
        this.modalOpen = false;
        this.resetPreparation();
        this._returnFocus = true;
        this.refreshRequests();
    }
    handleComposerKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.closeComposer();
        }
    }
    sendSourceToEditor() {
        const frame = this.template.querySelector('iframe.preparation-frame');
        if (!frame || !this.editorOrigin || !this._pendingSource) return;
        frame.contentWindow.postMessage(
            { channel: 'portwood-signatures', nonce: this.nonce, action: 'source', value: this._pendingSource },
            this.editorOrigin
        );
        this._pendingSource = null;
    }
    handleEditorMessage(event) {
        const frame = this.template.querySelector('iframe.preparation-frame');
        const message = event.data;
        if (
            !frame ||
            event.source !== frame.contentWindow ||
            !message ||
            message.channel !== 'portwood-signatures' ||
            message.nonce !== this.nonce
        )
            return;
        let origin;
        try {
            origin = new URL(event.origin);
        } catch (_err) {
            return;
        }
        if (
            origin.protocol !== 'https:' ||
            !/\.(vf\.force\.com|visualforce\.com|salesforce\.com|force\.com)$/.test(origin.hostname)
        )
            return;
        this.editorOrigin = event.origin;
        if (message.action === 'ready') this.sendSourceToEditor();
        if (message.action === 'choose-source') this.changeSource();
        if (message.action === 'new-request') {
            this.resetPreparation();
            this.showSourceChooser = true;
            this._focusSourceChooser = true;
        }
        if (message.action === 'sent') this.pdfComplete = true;
        if (message.action === 'saved' || message.action === 'sent') this.refreshRequests();
    }
    handleTemplateRequestCreated() {
        this.templateComplete = true;
        this.refreshRequests();
    }
    viewRequest(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, actionName: 'view' }
        });
    }
    errorText(err) {
        return err?.body?.message || err?.message || 'The signature sender could not load.';
    }
}
