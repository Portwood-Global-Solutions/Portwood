import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { isBlobSafeMime as isBlobSafeMimeUtil } from 'c/docGenUtils';
import { scopeHtmlForInlinePreview } from 'c/docGenAuthoringKit';
import getButtons from '@salesforce/apex/DocGenButtonController.getButtons';
import generate from '@salesforce/apex/DocGenButtonController.generate';

/**
 * docGenButton
 * ------------
 * Screen quick action that generates a Portwood document from a pre-configured
 * template (DocGen_Button__mdt) and delivers it per the config's Delivery Mode:
 * download (default), open in the native Salesforce file preview, or both. When
 * exactly one configuration exists for the object it runs immediately; when several
 * exist it shows a small picker. No Portwood Runner, no field choices.
 */
const DELIVERY_DOWNLOAD = 'DOWNLOAD';
const DELIVERY_PREVIEW = 'PREVIEW';
const DELIVERY_PREVIEW_AND_DOWNLOAD = 'PREVIEW_AND_DOWNLOAD';

export default class DocGenButton extends LightningElement {
    _recordId;
    _started = false;
    _waitTimer;
    _previewObjectUrl;
    _previewHtml;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.maybeStart();
    }

    @api objectApiName; // provided by the record action; not used (object is derived from recordId server-side)

    loading = true;
    statusMessage = 'Preparing…';
    errorMessage;
    options = [];
    showPicker = false;
    showPreview = false;
    previewUrl;
    previewFileName;
    previewUnavailable = false;
    previewPdf = false;

    connectedCallback() {
        this.maybeStart();
        // Fallback: if recordId never arrives, don't spin forever.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._waitTimer = setTimeout(() => {
            if (!this._started) {
                this.fail('Could not determine the record. Please reopen the record and try again.');
            }
        }, 4000);
    }

    disconnectedCallback() {
        if (this._waitTimer) {
            clearTimeout(this._waitTimer);
        }
        this.releasePreviewUrl();
    }

    renderedCallback() {
        if (!this.showPreview || (!this._previewHtml && !this.previewPdf)) {
            return;
        }
        if (this.previewPdf) {
            return;
        }
        const host = this.template.querySelector('.docgen-preview-frame');
        if (!host || host.dataset.rendered === 'true') {
            return;
        }
        host.innerHTML = scopeHtmlForInlinePreview(this._previewHtml);
        host.dataset.rendered = 'true';
    }

    /** Runs the flow exactly once, and only after recordId has been injected. */
    maybeStart() {
        if (this._started || !this._recordId) {
            return;
        }
        this._started = true;
        if (this._waitTimer) {
            clearTimeout(this._waitTimer);
        }
        this.init();
    }

    async init() {
        try {
            const opts = await getButtons({ recordId: this.recordId });
            if (!opts || opts.length === 0) {
                this.fail('No Portwood document is configured for this record type.');
                return;
            }
            if (opts.length === 1) {
                this.run(opts[0].developerName);
            } else {
                this.options = opts;
                this.showPicker = true;
                this.loading = false;
            }
        } catch (e) {
            this.fail(this.toMessage(e));
        }
    }

    handlePick(event) {
        const developerName = event.currentTarget.dataset.name;
        this.showPicker = false;
        this.loading = true;
        this.run(developerName);
    }

    async run(configDeveloperName) {
        this.loading = true;
        this.statusMessage = 'Generating document…';
        try {
            const res = await generate({
                recordId: this.recordId,
                configDeveloperName
            });
            if (!res || !res.success) {
                this.fail((res && res.errorMessage) || 'Document generation failed.');
                return;
            }
            const mode = res.deliveryMode || DELIVERY_DOWNLOAD;
            const wantsDownload = mode !== DELIVERY_PREVIEW;
            // Preview needs a ContentDocumentId; without one, fall back to download
            // so the user still gets the file.
            const wantsPreview =
                (mode === DELIVERY_PREVIEW || mode === DELIVERY_PREVIEW_AND_DOWNLOAD) && !!res.contentDocumentId;

            if (wantsDownload || !wantsPreview) {
                this.deliver(res);
            }
            if (wantsPreview) {
                await this.preview(res);
            }
            this.showToast(
                'Document generated',
                this.successMessage(res.fileName, wantsDownload || !wantsPreview, wantsPreview),
                'success'
            );
            if (!wantsPreview) {
                this.close();
            }
        } catch (e) {
            this.fail(this.toMessage(e));
        }
    }

    deliver(res) {
        let href;
        let revoke = false;
        // LWS sanitizes URL.createObjectURL against a MIME allowlist (PDF, images,
        // plain text). Office formats (.docx/.pptx/.xlsx) are rejected, so use the
        // servlet download URL for anything not on the allowlist.
        if (res.base64Data && this.isBlobSafeMime(res.mimeType)) {
            const blob = this.base64ToBlob(res.base64Data, res.mimeType);
            href = URL.createObjectURL(blob);
            revoke = true;
        } else if (res.downloadUrl) {
            href = res.downloadUrl;
        } else if (res.base64Data) {
            const blob = this.base64ToBlob(res.base64Data, res.mimeType);
            href = URL.createObjectURL(blob);
            revoke = true;
        } else {
            return;
        }
        const anchor = document.createElement('a');
        anchor.href = href;
        anchor.download = res.fileName || 'document';
        anchor.target = '_blank';
        document.body.appendChild(anchor);
        anchor.click();
        document.body.removeChild(anchor);
        if (revoke) {
            // Give the browser a moment to start the download before releasing the URL.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => URL.revokeObjectURL(href), 4000);
        }
    }

    /**
     * Shows the generated file inside the quick action. This gives Preview and
     * Preview + Download an actual preview screen instead of relying on async
     * tab/navigation behavior that can be blocked or swallowed by the modal close.
     */
    async preview(res) {
        this.releasePreviewUrl();
        this.previewFileName = res.fileName || 'Selected template';
        this._previewHtml = res.previewHtml || null;
        // Use the generated selected template even when Apex omits inline bytes
        // because the file is larger than the download threshold.
        const previewMimeType = res.templatePreviewMimeType || res.mimeType;
        this.previewPdf = this.isPdf(previewMimeType) && !!(res.templatePreviewUrl || res.downloadUrl);
        this.previewUnavailable = !this._previewHtml && !this.previewPdf;

        if (res.templatePreviewUrl) {
            this.previewUrl = res.templatePreviewUrl;
        } else if (res.base64Data && this.isBlobSafeMime(res.mimeType)) {
            const blob = this.base64ToBlob(res.base64Data, res.mimeType);
            this._previewObjectUrl = URL.createObjectURL(blob);
            this.previewUrl = this._previewObjectUrl;
        } else {
            this.previewUrl = res.templatePreviewUrl || res.downloadUrl;
        }

        if (!this._previewHtml && !this.previewUrl) {
            this.fail('Preview could not be opened because the generated file URL was not returned.');
            return;
        }

        this.loading = false;
        this.showPicker = false;
        this.errorMessage = null;
        this.showPreview = true;

        if (this.previewPdf) {
            await Promise.resolve();
        }
    }

    isPdf(mimeType) {
        return (mimeType || '').toLowerCase() === 'application/pdf';
    }

    releasePreviewUrl() {
        if (this._previewObjectUrl) {
            URL.revokeObjectURL(this._previewObjectUrl);
            this._previewObjectUrl = null;
        }
    }

    successMessage(fileName, downloaded, previewed) {
        const name = fileName || 'Your document';
        if (downloaded && previewed) {
            return `${name} is downloading and opening in preview.`;
        }
        if (previewed) {
            return `${name} is opening in preview.`;
        }
        return `${name} is downloading.`;
    }

    // Delegates to c/docGenUtils so this component and downloadBase64 cannot
    // disagree about what LWS will accept.
    isBlobSafeMime(mimeType) {
        return isBlobSafeMimeUtil(mimeType);
    }

    base64ToBlob(base64, mimeType) {
        const binary = atob(base64);
        const length = binary.length;
        const bytes = new Uint8Array(length);
        for (let i = 0; i < length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return new Blob([bytes], { type: mimeType || 'application/octet-stream' });
    }

    fail(message) {
        this.loading = false;
        this.showPicker = false;
        this.errorMessage = message;
        this.showToast('Could not generate document', message, 'error');
    }

    close() {
        this.releasePreviewUrl();
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
