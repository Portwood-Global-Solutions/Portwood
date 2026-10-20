import { LightningElement, api } from 'lwc';
import converse from '@salesforce/apex/DocGenAiQueryPlanner.converse';

/** Customer conversation stays separate from the generated HTML and its data query. */
export default class DocGenAiConversation extends LightningElement {
    @api available = false;
    @api disabled = false;
    @api referenceDocumentId;
    @api referenceHtml;
    _referenceKey = '';
    @api get referenceKey() {
        return this._referenceKey;
    }
    set referenceKey(value) {
        const key = value || '';
        if (key === this._referenceKey) return;
        this._referenceKey = key;
        this._request++;
        this.busy = false;
        this.plan = null;
        // Keep the customer's requests; old model/schema replies describe a different example.
        this.history = this.history.filter((m) => m.role === 'user');
        this.notice = 'Your example changed. Send a message to update the data plan.';
        this.notify('changed');
    }
    draft = '';
    turns = [];
    history = [];
    plan = null;
    busy = false;
    error = '';
    notice = '';
    progress = '';
    _request = 0;
    _turnId = 0;
    get sendDisabled() {
        return !this.available || this.disabled || this.busy || (!this.draft.trim() && !this.referenceKey);
    }
    get sendLabel() {
        return this.busy ? 'Agentforce is working…' : 'Send to Agentforce';
    }
    get hasUnsentChanges() {
        return !!this.plan && !!this.draft.trim();
    }
    get inputDisabled() {
        return this.disabled || this.busy;
    }
    get sections() {
        return (this.plan?.sections || []).map((s, i) => ({ ...s, id: String(i) }));
    }
    get generatedQuery() {
        return this.plan ? JSON.stringify(JSON.parse(this.plan.queryConfig), null, 2) : '';
    }
    get brief() {
        return this.history
            .filter((m) => m.role === 'user')
            .map((m) => m.content)
            .join('\n\n');
    }
    handleInput(event) {
        this.draft = event.target.value;
        if (this.plan) this.notify(this.draft.trim() ? 'composing' : 'ready');
    }
    handleKeydown(event) {
        if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
            event.preventDefault();
            if (!this.sendDisabled) this.handleSend();
        }
    }
    addTurn(role, content) {
        this._scrollToLatest = true;
        this.turns = [
            ...this.turns,
            {
                id: String(++this._turnId),
                role: role === 'user' ? 'You' : 'Agentforce',
                content,
                styleClass: 'message ' + (role === 'user' ? 'message-user' : 'message-agent')
            }
        ];
    }
    notify(status) {
        this.dispatchEvent(
            new CustomEvent('planchange', {
                detail: { status, brief: this.brief, ...(status === 'ready' ? this.plan : {}) }
            })
        );
    }
    handleStartOver() {
        this._request++;
        this.history = [];
        this.turns = [];
        this.plan = null;
        this.draft = '';
        this.error = '';
        this.notice = '';
        this.busy = false;
        this.notify('reset');
    }
    renderedCallback() {
        const input = this.template.querySelector('textarea');
        // Native textarea value attributes do not clear the live value after Send.
        // Synchronize only when it differs, preserving cursor/selection while typing.
        if (input && input.value !== this.draft) input.value = this.draft;
        if (this._scrollToLatest) {
            const messages = this.template.querySelector('.messages');
            if (messages) messages.scrollTop = messages.scrollHeight;
            this._scrollToLatest = false;
        }
    }
    disconnectedCallback() {
        this._request++;
    }
    async handleSend() {
        if (this.sendDisabled) return;
        const request = ++this._request;
        const text =
            this.draft.trim() ||
            'Closely recreate the uploaded example, using the Salesforce data needed for its contents.';
        this.history = [...this.history, { role: 'user', content: text }];
        this.addTurn('user', text);
        this.draft = '';
        this.plan = null;
        this.error = '';
        this.notice = '';
        this.busy = true;
        this.progress = 'Agentforce is reading your request…';
        this.notify('planning');
        try {
            // Each hop is a separate transaction: schema discovery never uses real record data,
            // and long model calls do not share a single synchronous Apex budget.
            for (let step = 0; step < 8; step++) {
                const response = await converse({
                    historyJson: JSON.stringify(this.history),
                    documentId: this.referenceDocumentId || null,
                    referenceHtml: this.referenceHtml || null
                });
                if (request !== this._request) return;
                this.history = JSON.parse(response.historyJson);
                if (response.kind === 'schema') {
                    this.progress = response.message;
                    continue;
                }
                this.addTurn('assistant', response.message);
                if (response.kind === 'ready') {
                    this.plan = response;
                    this.notify('ready');
                } else this.notify('ask');
                return;
            }
            this.notice =
                'This document needs more schema discovery. Send “Continue” or add a little more detail about the data you need.';
            this.notify('ask');
        } catch (e) {
            if (request !== this._request) return;
            this.error =
                e?.body?.message || e?.message || 'Agentforce could not continue. Your conversation has been kept.';
            this.notify('error');
        } finally {
            if (request === this._request) this.busy = false;
        }
    }
}
