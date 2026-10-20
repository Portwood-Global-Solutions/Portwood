import { LightningElement, api } from 'lwc';
import PDFJS from '@salesforce/resourceUrl/DocGenPdfPreview';
import getContentVersionBase64 from '@salesforce/apex/DocGenController.getContentVersionBase64';

/** Displays the native PDF in a local resource, without LWS wrapping image-decoder operations. */
export default class DocGenDesignerPdfPreview extends LightningElement {
    @api contentVersionId;
    loading = true;
    status = 'Loading the PDF viewer…';
    error;
    pageCount;
    _requested;
    _request = 0;
    _ready = false;
    _base64;
    _sent;
    _listener;
    _session = Date.now().toString(36) + Math.random().toString(36).slice(2);
    get viewerUrl() {
        return PDFJS + '/viewer.html#' + this._session;
    }
    get pageSummary() {
        return this.pageCount ? 'Native PDF · ' + this.pageCount + ' page(s)' : 'Native PDF';
    }
    get downloadUrl() {
        return '/sfc/servlet.shepherd/version/download/' + this.contentVersionId;
    }
    connectedCallback() {
        this._listener = (event) => this.handleViewerMessage(event);
        window.addEventListener('message', this._listener);
    }
    renderedCallback() {
        if (this.contentVersionId && this._requested !== this.contentVersionId) {
            this._requested = this.contentVersionId;
            this.renderPdf();
        }
    }
    disconnectedCallback() {
        this._request++;
        this._base64 = undefined;
        window.removeEventListener('message', this._listener);
    }
    async renderPdf() {
        const request = ++this._request;
        this.loading = true;
        this.pageCount = undefined;
        this.error = undefined;
        this._base64 = undefined;
        this.status = 'Reading the generated PDF from Salesforce…';
        try {
            // Permission-checked Apex remains the only reader of private Files.
            const base64 = await getContentVersionBase64({ contentVersionId: this.contentVersionId });
            if (request !== this._request) return;
            this._base64 = base64;
            this.status = 'Preparing the PDF pages…';
            this.sendPdf();
        } catch (error) {
            if (request !== this._request) return;
            this.error = error?.body?.message || error?.message || 'The PDF could not be read.';
            this.loading = false;
        }
    }
    sendPdf() {
        const viewer = this.template.querySelector('iframe');
        if (!this._ready || !this._base64 || !viewer || this._sent === this._request) return;
        viewer.contentWindow.postMessage(
            { type: 'docgen-pdf-render', session: this._session, request: this._request, base64: this._base64 },
            window.location.origin
        );
        this._sent = this._request;
        this._base64 = undefined;
    }
    handleViewerMessage(event) {
        const viewer = this.template.querySelector('iframe');
        const data = event.data;
        if (
            event.origin !== window.location.origin ||
            !viewer ||
            event.source !== viewer.contentWindow ||
            data?.session !== this._session
        )
            return;
        if (data.type === 'docgen-pdf-ready') {
            this._ready = true;
            this.sendPdf();
            return;
        }
        if (data.request !== this._request) return;
        if (data.type === 'docgen-pdf-progress') {
            this.status = data.status;
            this.pageCount = data.pageCount;
        } else if (data.type === 'docgen-pdf-complete') {
            this.pageCount = data.pageCount;
            this.loading = false;
        } else if (data.type === 'docgen-pdf-error') {
            this.error = data.message;
            this.loading = false;
        }
        if (Number.isFinite(data.height)) viewer.style.height = Math.min(100000, Math.max(300, data.height)) + 'px';
    }
    handleClose() {
        this.dispatchEvent(new CustomEvent('closepreview'));
    }
}
