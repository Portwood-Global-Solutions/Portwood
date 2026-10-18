import { LightningElement, api } from 'lwc';
import getSnippetLibraryPreview from '@salesforce/apex/DocGenSnippetController.getSnippetLibraryPreview';

export default class DocGenSnippetPreview extends LightningElement {
    @api assetId;
    @api revision = 0;
    @api imageUrls = {};
    state = 'loading';
    error = '';
    _viewKey;
    _requestKey;
    _html = '';
    _renderedHtml;
    _renderedImages;
    _observer;
    _request = 0;
    _connected = false;
    get imageCount() {
        return Object.keys(this.imageUrls || {}).length;
    }
    get loading() {
        return this.state === 'loading';
    }
    get failed() {
        return this.state === 'error';
    }
    connectedCallback() {
        this._connected = true;
    }
    disconnectedCallback() {
        this._connected = false;
        this._request++;
        this._observer?.disconnect();
        this._observer = null;
        this._requestKey = null;
    }
    renderedCallback() {
        const host = this.template.querySelector('.content');
        if (!host || !this.assetId) return;
        host.setAttribute('inert', '');
        const key = this.assetId + ':' + this.revision;
        if (key !== this._viewKey) {
            this._viewKey = key;
            this._request++;
            this._requestKey = null;
            this._html = '';
            this._renderedHtml = null;
            host.textContent = '';
            this.state = 'loading';
            this.error = '';
            this._observer?.disconnect();
            this._observer = null;
        }
        if (this._html && (this._renderedHtml !== this._html || this._renderedImages !== this.imageUrls)) {
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- The private authoring endpoint validates and expands snippet HTML; this inert thumbnail never edits the source.
            host.innerHTML = this._html;
            for (const image of host.querySelectorAll('img')) {
                const match = /^\{%asset:([a-z0-9-]+)(?::[^}]+)?\}$/i.exec(image.getAttribute('src') || '');
                const url = match && this.imageUrls[match[1].toLowerCase()];
                if (url) image.src = url;
                image.setAttribute('draggable', 'false');
                image.style.maxWidth = '100%';
            }
            this._renderedHtml = this._html;
            this._renderedImages = this.imageUrls;
        }
        if (this._requestKey === key || this._observer) return;
        if (typeof IntersectionObserver === 'undefined') {
            this.load(key);
            return;
        }
        this._observer = new IntersectionObserver(
            (entries) => {
                if (entries.some((entry) => entry.isIntersecting)) {
                    this._observer?.disconnect();
                    this._observer = null;
                    this.load(key);
                }
            },
            { rootMargin: '100px' }
        );
        this._observer.observe(this.template.querySelector('.preview'));
    }
    async load(key) {
        if (!this._connected || key !== this._viewKey || this._requestKey === key) return;
        this._requestKey = key;
        const request = ++this._request;
        try {
            const html = await getSnippetLibraryPreview({ assetId: this.assetId });
            if (!this._connected || request !== this._request) return;
            this._html = html;
            this.state = 'ready';
        } catch (error) {
            if (!this._connected || request !== this._request) return;
            this.error = error?.body?.message || error?.message || 'Could not load this snippet.';
            this.state = 'error';
        }
    }
}
