import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import PDFJS from '@salesforce/resourceUrl/DocGenPdfPreview';
import getContentVersionBase64 from '@salesforce/apex/DocGenController.getContentVersionBase64';

// Both PDF.js endpoints run inside the same LWS sandbox. A local async port
// keeps sandbox proxies out of native MessagePort's structured-clone boundary.
class SandboxPdfPort {
    listeners = new Set();
    postMessage(data) {
        // PDF.js reuses operator/text arrays immediately after posting them.
        const message = snapshotMessage(data);
        Promise.resolve().then(() => {
            for (const listener of this.listeners) listener({ data: message });
        });
    }
    addEventListener(type, listener) {
        if (type === 'message') this.listeners.add(listener);
    }
    removeEventListener(type, listener) {
        if (type === 'message') this.listeners.delete(listener);
    }
    terminate() {
        this.listeners.clear();
    }
}

function snapshotMessage(value, seen = new Map()) {
    if (value === null || typeof value !== 'object') return value;
    if (seen.has(value)) return seen.get(value);
    // These native image values stay in this sandbox; converting them to plain
    // objects would discard the image accepted by CanvasRenderingContext2D.
    if (
        (typeof ImageBitmap !== 'undefined' && value instanceof ImageBitmap) ||
        (typeof OffscreenCanvas !== 'undefined' && value instanceof OffscreenCanvas) ||
        (typeof ImageData !== 'undefined' && value instanceof ImageData) ||
        value instanceof Blob
    ) {
        return value;
    }
    if (value instanceof ArrayBuffer) return value.slice(0);
    if (ArrayBuffer.isView(value)) {
        return value instanceof DataView
            ? new DataView(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength))
            : value.slice();
    }
    const result = Array.isArray(value) ? [] : {};
    seen.set(value, result);
    for (const key of Object.keys(value)) result[key] = snapshotMessage(value[key], seen);
    return result;
}

/** Displays the actual native PDF bytes, independent of asynchronous Files renditions. */
export default class DocGenDesignerPdfPreview extends LightningElement {
    @api contentVersionId;
    loading = true;
    status = 'Loading the PDF viewer…';
    get pageSummary() {
        return this.pageCount ? 'Native PDF · ' + this.pageCount + ' page(s)' : 'Native PDF';
    }
    error;
    pageCount;
    _requested;
    _request = 0;
    _document;
    _loadingTask;
    _worker;
    _port;
    get downloadUrl() {
        return '/sfc/servlet.shepherd/version/download/' + this.contentVersionId;
    }
    renderedCallback() {
        if (this.contentVersionId && this._requested !== this.contentVersionId) {
            this._requested = this.contentVersionId;
            this.renderPdf();
        }
    }
    disconnectedCallback() {
        this._request++;
        this.releasePdf();
    }
    async releasePdf() {
        const task = this._loadingTask;
        const pdf = this._document;
        const worker = this._worker;
        const port = this._port;
        this._loadingTask = undefined;
        this._document = undefined;
        this._worker = undefined;
        this._port = undefined;
        try {
            if (task) await task.destroy();
            else if (pdf) await pdf.destroy();
        } catch {
            // Cancellation when leaving or replacing a preview is expected.
        } finally {
            worker?.destroy();
            port?.terminate();
        }
    }
    async renderPdf() {
        const request = ++this._request;
        const contentVersionId = this.contentVersionId;
        this.releasePdf();
        let phase = 'load the PDF viewer';
        this.loading = true;
        this.pageCount = undefined;
        this.status = 'Loading the PDF viewer…';
        this.error = undefined;
        this.template.querySelector('.pages')?.replaceChildren();
        try {
            await Promise.all([loadScript(this, PDFJS + '/worker.js'), loadScript(this, PDFJS + '/pdf.js')]);
            if (request !== this._request) return;
            const lib = window.pdfjsLib;
            if (!lib?.getDocument) throw new Error('The PDF viewer did not initialize.');
            lib.GlobalWorkerOptions.workerSrc = PDFJS + '/worker.js';
            phase = 'read the generated PDF';
            this.status = 'Reading the generated PDF from Salesforce…';
            // The existing permission-checked reader avoids private Files cross-origin redirects.
            const base64 = await getContentVersionBase64({ contentVersionId });
            if (request !== this._request) return;
            const binary = atob(base64);
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
            phase = 'open the generated PDF';
            this.status = 'Preparing the PDF pages…';
            // LWS cannot import PDF.js's automatic module worker. Connect the pinned,
            // already-loaded worker through its public port API within this sandbox.
            const workerHandler = window.pdfjsWorker?.WorkerMessageHandler;
            if (!workerHandler) throw new Error('The PDF worker did not initialize.');
            const port = new SandboxPdfPort();
            workerHandler.initializeFromPort(port);
            const worker = new lib.PDFWorker({ port });
            this._port = port;
            this._worker = worker;
            this._loadingTask = lib.getDocument({ data: bytes, worker, isEvalSupported: false });
            const pdf = await this._loadingTask.promise;
            if (request !== this._request) {
                await pdf.destroy();
                return;
            }
            this._document = pdf;
            this.pageCount = pdf.numPages;
            const host = this.template.querySelector('.pages');
            phase = 'draw the PDF pages';
            host.replaceChildren();
            const available = Math.max(240, host.clientWidth - 48);
            for (let number = 1; number <= pdf.numPages; number++) {
                if (request !== this._request) return;
                this.status = 'Rendering page ' + number + ' of ' + pdf.numPages + '…';
                const page = await pdf.getPage(number);
                const original = page.getViewport({ scale: 1 });
                const scale = Math.min(1.5, available / original.width);
                const viewport = page.getViewport({ scale });
                const sheet = document.createElement('section');
                sheet.className = 'pdf-page';
                sheet.style.cssText = 'width:max-content;max-width:100%;margin:0 auto 26px;';
                sheet.setAttribute('aria-label', 'PDF page ' + number);
                const canvas = document.createElement('canvas');
                canvas.width = Math.ceil(viewport.width);
                canvas.height = Math.ceil(viewport.height);
                canvas.setAttribute('aria-hidden', 'true');
                canvas.style.cssText =
                    'display:block;max-width:100%;height:auto;background:white;box-shadow:0 1px 5px #18345230;';
                sheet.append(canvas);
                const text = await page.getTextContent();
                const accessible = document.createElement('p');
                accessible.className = 'pdf-text';
                accessible.style.cssText = 'position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0);';
                accessible.textContent = text.items.map((item) => item.str || '').join(' ');
                sheet.append(accessible);
                const label = document.createElement('div');
                label.className = 'pdf-page-label';
                label.style.cssText = 'color:#617181;padding:9px 0;text-align:center;font-size:11px;';
                label.textContent = 'Page ' + number + ' of ' + pdf.numPages;
                sheet.append(label);
                host.append(sheet);
                await page.render({ canvasContext: canvas.getContext('2d'), viewport }).promise;
            }
        } catch (error) {
            if (request !== this._request) return;
            const message = error?.body?.message || error?.message || 'The PDF could not be displayed.';
            console.warn('DocGen Designer could not ' + phase + ': ' + message);
            console.warn(error?.stack || 'No PDF rendering stack available.');
            if (request === this._request) this.error = 'Could not ' + phase + '. ' + message;
        } finally {
            if (request === this._request) this.loading = false;
        }
    }
    handleClose() {
        this.dispatchEvent(new CustomEvent('closepreview'));
    }
}
