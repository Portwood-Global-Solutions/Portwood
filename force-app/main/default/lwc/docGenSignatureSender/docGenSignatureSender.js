import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSignerRolePicklistValues from '@salesforce/apex/DocGenSignatureSenderController.getSignerRolePicklistValues';
import createGuidedPdfSignatureRequestV2 from '@salesforce/apex/DocGenSignatureSenderController.createGuidedPdfSignatureRequestV2';
import getAttachableRecordPdfs from '@salesforce/apex/DocGenSignatureSenderController.getAttachableRecordPdfs';
import markSignerVerifiedInPerson from '@salesforce/apex/DocGenSignatureSenderController.markSignerVerifiedInPerson';
import createPacketSignerRequest from '@salesforce/apex/DocGenSignatureSenderController.createPacketSignerRequestWithTitle';
import getContactInfo from '@salesforce/apex/DocGenSignatureSenderController.getContactInfo';
import getPendingSignatureRequests from '@salesforce/apex/DocGenSignatureSenderController.getPendingSignatureRequests';
import getDocGenTemplates from '@salesforce/apex/DocGenSignatureSenderController.getDocGenTemplatesForRecord';
import getTemplateSignaturePlacements from '@salesforce/apex/DocGenSignatureSenderController.getTemplateSignaturePlacements';
import getDocumentPreviewPdfBase64 from '@salesforce/apex/DocGenSignatureSenderController.getDocumentPreviewPdfBase64';
import resendSignatureRequest from '@salesforce/apex/DocGenSignatureSenderController.resendSignatureRequest';
import cancelSignatureRequest from '@salesforce/apex/DocGenSignatureSenderController.cancelSignatureRequest';

let signerIdCounter = 0;
let templateIdCounter = 0;

export default class DocGenSignatureSender extends NavigationMixin(LightningElement) {
    @api recordId;

    @track isLoading = true;
    @track error;

    // All available templates
    @track docGenTemplateOptions = [];

    // Selected templates (packet support)
    @track selectedTemplates = []; // [{id, templateId, name, placements, placementSummary, docNumber}]

    // Role picklist
    @track roleOptions = [];

    // Aggregated placements from all selected templates
    @track detectedPlacements = [];

    // Signing order
    @track signingOrder = 'Parallel';
    @track documentTitleFormat = '';
    @track emailMessage = ''; // #193 — optional send-time custom message
    @track emailSubject = ''; // #193 — optional send-time custom subject
    // #verification — per-send overrides ('Inherit' falls back to template/org default)
    @track verificationOverride = 'Inherit';
    @track prefillOverride = 'Inherit';
    @track expirationDays = null; // per-send signing-window override (blank = org default)

    // Signers
    @track signers = [];

    // Results
    @track signerResults;

    // Preview modal
    @track showPreviewModal = false;
    @track previewDocuments = [];
    @track previewLoading = false;
    @track previewStatus = '';

    // #412 — existing PDFs on the record (e.g. engineering drawings) shown to signers
    // alongside the template. Single-template sends only.
    @track attachablePdfs = [];
    @track selectedAttachmentIds = [];
    @track attachmentPosition = 'Before';

    // Previous requests
    @track previousRequests = [];
    @track showPreviousRequests = false;

    @wire(getSignerRolePicklistValues)
    wiredRoles({ error, data }) {
        if (data) {
            this.roleOptions = data.map((entry) => ({
                label: entry.label,
                value: entry.value
            }));
        } else if (error) {
            // Role picklist unavailable
        }
        this._checkInitialLoad();
    }

    @wire(getDocGenTemplates, { relatedRecordId: '$recordId' })
    wiredDocGenTemplates({ error, data }) {
        if (data) {
            this.docGenTemplateOptions = data.map((t) => ({
                label: t.Name,
                value: t.Id,
                // #208 — namespace-aware read: prefixed in subscriber orgs, bare in dev.
                defaultMessage: t.Default_Email_Message__c || t.portwoodglobal__Default_Email_Message__c || '',
                // #412 — Off (default) / Optional / Required; same namespace-aware read.
                attachedDocuments: t.Attached_Documents__c || t.portwoodglobal__Attached_Documents__c || 'Off'
            }));
        } else if (error) {
            this.docGenTemplateOptions = [];
        }
        this._checkInitialLoad();
    }

    _wireCallsReturned = 0;
    _checkInitialLoad() {
        this._wireCallsReturned++;
        if (this._wireCallsReturned >= 2) {
            this.isLoading = false;
            if (this.signers.length === 0) {
                this.handleAddSigner();
            }
        }
    }

    connectedCallback() {
        this.loadAttachablePdfs();
    }

    async loadAttachablePdfs() {
        if (!this.recordId) return;
        try {
            this.attachablePdfs = (await getAttachableRecordPdfs({ recordId: this.recordId })) || [];
        } catch (_err) {
            this.attachablePdfs = []; // the picker simply doesn't show
        }
    }

    disconnectedCallback() {
        this._revokePreviewUrls();
    }

    // --- Computed Properties ---

    get hasSelectedTemplates() {
        return this.selectedTemplates.length > 0;
    }

    get isPacketMode() {
        return this.selectedTemplates.length > 1;
    }

    get isGenerateDisabled() {
        if (this.selectedTemplates.length === 0 || this.signers.length === 0) return true;
        if (this.attachmentsRequired && !this.hasSelectedAttachments) return true; // #412
        return this.signers.some((s) => !s.signerName || !s.signerEmail || !s.roleName);
    }

    get isRemoveDisabled() {
        return this.signers.length <= 1;
    }

    /**
     * Role suggestion pills — derived ONLY from the roles that actually appear in
     * the selected template(s)' signature tags. The earlier UI also surfaced the
     * curated Role_Name__c picklist values, but that produced an overwhelming row
     * of generic suggestions ("Buyer", "Seller", "Witness", ...) that rarely
     * matched the doc the admin was about to send. Keeping the pills tied to the
     * document means: if the template defines roles, you get them; otherwise the
     * row stays empty and the free-text role field is the only input.
     */
    get roleSuggestions() {
        const seen = new Set();
        const merged = [];
        for (const p of this.detectedPlacements || []) {
            if (p.role && !seen.has(p.role)) {
                seen.add(p.role);
                merged.push({ label: p.role, value: p.role, title: 'From template tag' });
            }
        }
        return merged;
    }

    get hasRoleSuggestions() {
        return this.roleSuggestions.length > 0;
    }

    get previousRequestsLabel() {
        return this.showPreviousRequests ? 'Hide Previous Requests' : 'Show Previous Requests';
    }

    get hasPreviousRequests() {
        return this.previousRequests.length > 0;
    }

    get hasDetectedPlacements() {
        return this.detectedPlacements.length > 0;
    }

    get availableTemplateOptions() {
        // Filter out already-selected templates
        const selectedIds = new Set(this.selectedTemplates.map((t) => t.templateId));
        return this.docGenTemplateOptions.filter((t) => !selectedIds.has(t.value));
    }

    /**
     * Builds a summary of placements per role across all templates.
     */
    get placementSummaryByRole() {
        if (!this.detectedPlacements || this.detectedPlacements.length === 0) return [];
        const roleMap = {};
        for (const p of this.detectedPlacements) {
            if (!roleMap[p.role]) roleMap[p.role] = { Full: 0, Initials: 0, Date: 0, DatePick: 0 };
            roleMap[p.role][p.placementType] = (roleMap[p.role][p.placementType] || 0) + 1;
        }
        const result = [];
        for (const role of Object.keys(roleMap)) {
            const c = roleMap[role];
            const parts = [];
            if (c.Full > 0) parts.push(c.Full + ' signature' + (c.Full > 1 ? 's' : ''));
            if (c.Initials > 0) parts.push(c.Initials + ' initial' + (c.Initials > 1 ? 's' : ''));
            if (c.Date > 0) parts.push(c.Date + ' date' + (c.Date > 1 ? 's' : ''));
            if (c.DatePick > 0) parts.push(c.DatePick + ' date picker' + (c.DatePick > 1 ? 's' : ''));
            result.push({ role, summary: parts.join(', ') || '1 signature' });
        }
        return result;
    }

    get generateButtonLabel() {
        return this.isPacketMode ? 'Generate Packet Signature Links' : 'Generate Signature Links';
    }

    get signingOrderOptions() {
        return [
            { label: 'All at once (parallel)', value: 'Parallel' },
            { label: 'One at a time (sequential)', value: 'Sequential' }
        ];
    }

    // --- #412 attached documents ---

    get attachmentOptions() {
        return this.attachablePdfs
            .filter((f) => !f.tooLarge)
            .map((f) => ({
                label: [f.title, f.versionNumber ? 'v' + f.versionNumber : null, this._formatBytes(f.size)]
                    .filter(Boolean)
                    .join(' · '),
                value: f.contentDocumentId
            }));
    }

    // #412 — the selected template decides: Off hides the picker entirely (current users see
    // no change); Optional and Required show it; Required also blocks sending with none ticked.
    get attachedDocumentsMode() {
        if (!this.isSingleTemplate) return 'Off';
        const option = this.docGenTemplateOptions.find((o) => o.value === this.selectedTemplates[0].templateId);
        return (option && option.attachedDocuments) || 'Off';
    }

    get showAttachmentPicker() {
        return this.attachedDocumentsMode !== 'Off';
    }

    get attachmentsRequired() {
        return this.attachedDocumentsMode === 'Required';
    }

    get noAttachablePdfs() {
        return this.attachmentOptions.length === 0;
    }

    get attachmentPickerHeading() {
        return this.attachmentsRequired ? 'Attach PDFs from this record' : 'Attach PDFs from this record (optional)';
    }

    get oversizeAttachmentNote() {
        const n = this.attachablePdfs.filter((f) => f.tooLarge).length;
        if (!n) return null;
        // The per-file limit is set in Signature Settings; the server reports it with each file.
        const maxBytes = this.attachablePdfs[0].maxBytes;
        const limit = maxBytes ? 'over ' + Math.round(maxBytes / (1024 * 1024)) + ' MB' : 'over the size limit';
        return n === 1
            ? '1 PDF on this record is ' + limit + ' and cannot be attached.'
            : n + ' PDFs on this record are ' + limit + ' and cannot be attached.';
    }

    get hasSelectedAttachments() {
        return this.selectedAttachmentIds.length > 0;
    }

    get selectAllAttachmentsLabel() {
        return this.selectedAttachmentIds.length === this.attachmentOptions.length ? 'Clear all' : 'Select all';
    }

    get attachmentPositionOptions() {
        return [
            { label: 'Before the template', value: 'Before' },
            { label: 'After the template', value: 'After' }
        ];
    }

    // The ticked files in picker order: what the preview lists and what the send carries, so
    // the two always agree.
    get orderedSelectedAttachments() {
        if (!this.showAttachmentPicker || !this.hasSelectedAttachments) return [];
        const selected = new Set(this.selectedAttachmentIds);
        return this.attachablePdfs.filter((f) => !f.tooLarge && selected.has(f.contentDocumentId));
    }

    get previewAttachments() {
        return this.orderedSelectedAttachments.map((f, i) => ({
            id: f.contentDocumentId,
            label: i + 1 + '. ' + f.title,
            meta: [f.versionNumber ? 'v' + f.versionNumber : null, this._formatBytes(f.size)]
                .filter(Boolean)
                .join(' · ')
        }));
    }

    get hasPreviewAttachments() {
        return this.previewAttachments.length > 0;
    }

    get previewAttachmentsHeading() {
        return 'Attached Documents (' + this.previewAttachments.length + ')';
    }

    get previewAttachmentsPlacement() {
        return this.attachmentPosition === 'After'
            ? 'Shown to signers after the template.'
            : 'Shown to signers before the template.';
    }

    // Salesforce's own file viewer pages through every ticked PDF, at any size.
    handleViewAttachedFiles() {
        const ids = this.previewAttachments.map((a) => a.id);
        if (!ids.length) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { recordIds: ids.join(','), selectedRecordId: ids[0] }
        });
    }

    handleAttachmentsChange(event) {
        this.selectedAttachmentIds = [...event.detail.value];
    }

    handleToggleAllAttachments() {
        const all = this.attachmentOptions.map((o) => o.value);
        this.selectedAttachmentIds = this.selectedAttachmentIds.length === all.length ? [] : all;
    }

    handleAttachmentPositionChange(event) {
        this.attachmentPosition = event.detail.value;
    }

    _formatBytes(n) {
        if (!n) return null;
        if (n < 1024 * 1024) return Math.max(1, Math.round(n / 1024)) + ' KB';
        return (n / (1024 * 1024)).toFixed(1) + ' MB';
    }

    handleSigningOrderChange(event) {
        this.signingOrder = event.detail.value;
    }

    // #verification — per-send controls (single-template path)
    get isSingleTemplate() {
        return this.selectedTemplates && this.selectedTemplates.length === 1;
    }

    get verificationOptions() {
        return [
            { label: 'Default (template / org setting)', value: 'Inherit' },
            { label: 'Require email verification', value: 'Required' },
            { label: 'No verification', value: 'Off' }
        ];
    }

    get prefillOptions() {
        return [
            { label: 'Default (template / org setting)', value: 'Inherit' },
            { label: 'Auto-send code to known email', value: 'Yes' },
            { label: 'Signer types their email', value: 'No' }
        ];
    }

    // Map the tri-state pickers to nullable booleans (null = inherit).
    get requireVerificationValue() {
        if (this.verificationOverride === 'Required') return true;
        if (this.verificationOverride === 'Off') return false;
        return null;
    }
    get prefillValue() {
        if (this.prefillOverride === 'Yes') return true;
        if (this.prefillOverride === 'No') return false;
        return null;
    }

    handleVerificationOverrideChange(event) {
        this.verificationOverride = event.detail.value;
    }
    handlePrefillOverrideChange(event) {
        this.prefillOverride = event.detail.value;
    }

    handleDocumentTitleChange(event) {
        this.documentTitleFormat = event.detail.value || '';
    }

    // #193 — the send-time custom message is offered only for single-template
    // sends (the guided path that threads it through); packets use defaults.
    // (isSingleTemplate getter is defined above, shared with the #verification controls.)
    handleEmailMessageChange(event) {
        this.emailMessage = event.detail.value || '';
        // #208 — once the sender types (or clears) the message, stop auto-filling
        // template defaults for this send.
        this._messageTouched = true;
    }

    handleEmailSubjectChange(event) {
        this.emailSubject = event.detail.value || '';
    }

    handleExpirationDaysChange(event) {
        this.expirationDays = event.detail.value;
    }

    // --- Template Selection ---

    // Synchronous in-flight tracker. selectedTemplates is only appended AFTER an
    // awaited Apex call resolves, so a synchronous .some() check on it can't catch
    // multiple pending picks for the same templateId. This Set is mutated before
    // the await and cleared in finally, giving us a single source of truth for
    // "is this id already being processed".
    _pendingTemplateIds = new Set();

    async handleTemplateSelected(event) {
        const templateId = event.detail.value;
        if (!templateId) return;

        // Guard against three races:
        //   1. Same id already confirmed in selectedTemplates.
        //   2. Same id with an in-flight getTemplateSignaturePlacements await.
        //   3. Two rapid clicks on different ids — handled because each gets its
        //      own pending entry and runs through independently.
        if (
            this._pendingTemplateIds.has(templateId) ||
            this.selectedTemplates.some((t) => t.templateId === templateId)
        ) {
            return;
        }
        this._pendingTemplateIds.add(templateId);

        try {
            const opt = this.docGenTemplateOptions.find((t) => t.value === templateId);
            if (!opt) return;

            // #208 — pre-fill the send-time message with the template's default so
            // the sender sees exactly what will go out. Only when they haven't
            // typed their own text, and only for the first selected template.
            if (
                !this._messageTouched &&
                !this.emailMessage &&
                this.selectedTemplates.length === 0 &&
                opt.defaultMessage
            ) {
                this.emailMessage = opt.defaultMessage;
            }

            // Scan template for placements
            let placements = [];
            try {
                placements = await getTemplateSignaturePlacements({ templateId });
            } catch (_err) {
                // Template may not have signature tags
            }

            // Build placement summary string
            const counts = { Full: 0, Initials: 0, Date: 0, DatePick: 0 };
            for (const p of placements || []) {
                counts[p.placementType] = (counts[p.placementType] || 0) + 1;
            }
            const parts = [];
            if (counts.Full > 0) parts.push(counts.Full + ' signature' + (counts.Full > 1 ? 's' : ''));
            if (counts.Initials > 0) parts.push(counts.Initials + ' initial' + (counts.Initials > 1 ? 's' : ''));
            if (counts.Date > 0) parts.push(counts.Date + ' date' + (counts.Date > 1 ? 's' : ''));
            if (counts.DatePick > 0) parts.push(counts.DatePick + ' date picker' + (counts.DatePick > 1 ? 's' : ''));
            const placementSummary = parts.length > 0 ? parts.join(', ') : 'No signature placements detected';

            // Re-check selectedTemplates after the await — defense-in-depth in case
            // some other code path appended this id while we were awaiting.
            if (this.selectedTemplates.some((t) => t.templateId === templateId)) {
                return;
            }

            this.selectedTemplates = [
                ...this.selectedTemplates,
                {
                    id: ++templateIdCounter,
                    templateId,
                    name: opt.label,
                    placements: placements || [],
                    placementSummary,
                    docNumber: this.selectedTemplates.length + 1
                }
            ];

            this._refreshAggregatedPlacements();
        } finally {
            this._pendingTemplateIds.delete(templateId);
        }
    }

    handleRemoveTemplate(event) {
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        this.selectedTemplates = this.selectedTemplates.filter((_, i) => i !== idx);
        this._refreshAggregatedPlacements();
        // #208 — an auto-filled (never-touched) message belongs to the removed
        // template; clear it so the next selection can pre-fill its own default.
        if (!this._messageTouched && this.selectedTemplates.length === 0) {
            this.emailMessage = '';
        }
    }

    handleMoveTemplateUp(event) {
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        if (idx <= 0) return;
        const arr = [...this.selectedTemplates];
        [arr[idx - 1], arr[idx]] = [arr[idx], arr[idx - 1]];
        this.selectedTemplates = arr;
    }

    handleMoveTemplateDown(event) {
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        if (idx >= this.selectedTemplates.length - 1) return;
        const arr = [...this.selectedTemplates];
        [arr[idx], arr[idx + 1]] = [arr[idx + 1], arr[idx]];
        this.selectedTemplates = arr;
    }

    _refreshAggregatedPlacements() {
        // Renumber documents
        this.selectedTemplates = this.selectedTemplates.map((t, i) => ({
            ...t,
            docNumber: i + 1
        }));

        // Merge all template placements and auto-populate signers
        const all = [];
        for (const t of this.selectedTemplates) {
            for (const p of t.placements) {
                all.push(p);
            }
        }
        this.detectedPlacements = all;

        // Extract unique roles
        const uniqueRoles = [];
        for (const p of all) {
            if (!uniqueRoles.includes(p.role)) uniqueRoles.push(p.role);
        }

        if (uniqueRoles.length > 0) {
            // Preserve existing signer data for roles that already have entries
            const existingByRole = {};
            for (const s of this.signers) {
                if (s.roleName) existingByRole[s.roleName] = s;
            }

            this.signers = uniqueRoles.map((roleName) => {
                if (existingByRole[roleName]) return existingByRole[roleName];
                return {
                    id: ++signerIdCounter,
                    roleName,
                    contactId: '',
                    signerName: '',
                    signerEmail: ''
                };
            });
        }
    }

    // --- Preview Modal ---

    async handleShowPreview() {
        this.showPreviewModal = true;
        this.previewLoading = true;
        this.previewStatus = 'Generating paginated PDF preview...';
        this._revokePreviewUrls();
        this.previewDocuments = [];

        const runId = (this._previewRunId || 0) + 1;
        this._previewRunId = runId;

        // Keep this independent of the Apex promise chain. If an Aura/LWC action
        // stalls and never resolves or rejects, the modal still exits loading
        // state and gives the sender something actionable.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        const timeoutId = setTimeout(() => {
            if (this._previewRunId !== runId || !this.previewLoading) {
                return;
            }
            this.previewDocuments = [
                {
                    id: 'timeout',
                    name: 'Preview',
                    url: '',
                    error: 'Preview generation is still running after 45 seconds. Close this preview and try again.'
                }
            ];
            this.previewStatus = '';
            this.previewLoading = false;
        }, 45000);

        try {
            const docs = [];
            for (let i = 0; i < this.selectedTemplates.length; i++) {
                if (this._previewRunId !== runId) {
                    return;
                }
                const tmpl = this.selectedTemplates[i];
                const label =
                    this.selectedTemplates.length > 1
                        ? 'Document ' + (i + 1) + ' of ' + this.selectedTemplates.length + ': ' + tmpl.name
                        : tmpl.name;
                try {
                    this.previewStatus = 'Rendering ' + label + '...';
                    const pdfBase64 = await getDocumentPreviewPdfBase64({
                        templateId: tmpl.templateId,
                        relatedRecordId: this.recordId
                    });
                    if (this._previewRunId !== runId) {
                        return;
                    }
                    docs.push({
                        id: tmpl.id,
                        name: label,
                        url: pdfBase64 ? this._pdfObjectUrlFromBase64(pdfBase64) : '',
                        error: pdfBase64 ? '' : 'Preview unavailable for ' + tmpl.name
                    });
                } catch (err) {
                    docs.push({
                        id: tmpl.id,
                        name: label,
                        url: '',
                        error: 'Failed to generate preview for ' + tmpl.name + ': ' + this._errorMessage(err)
                    });
                }
            }
            this.previewDocuments = docs;
        } catch (err) {
            if (this._previewRunId !== runId) {
                return;
            }
            this.previewDocuments = [
                {
                    id: 'error',
                    name: 'Preview',
                    url: '',
                    error: 'Failed to generate preview: ' + this._errorMessage(err)
                }
            ];
        } finally {
            clearTimeout(timeoutId);
            if (this._previewRunId === runId) {
                this.previewStatus = '';
                this.previewLoading = false;
            }
        }
    }

    handleClosePreview() {
        this.showPreviewModal = false;
        this.previewStatus = '';
        this._previewRunId = (this._previewRunId || 0) + 1;
        this._revokePreviewUrls();
        this.previewDocuments = [];
    }

    handleSendFromPreview() {
        this.showPreviewModal = false;
        this.previewStatus = '';
        this._previewRunId = (this._previewRunId || 0) + 1;
        this._revokePreviewUrls();
        this.handleGenerate();
    }

    _pdfObjectUrlFromBase64(pdfBase64) {
        const byteCharacters = atob(pdfBase64);
        const byteArrays = [];
        const sliceSize = 1024;
        for (let offset = 0; offset < byteCharacters.length; offset += sliceSize) {
            const slice = byteCharacters.slice(offset, offset + sliceSize);
            const byteNumbers = new Array(slice.length);
            for (let i = 0; i < slice.length; i++) {
                byteNumbers[i] = slice.charCodeAt(i);
            }
            byteArrays.push(new Uint8Array(byteNumbers));
        }
        return URL.createObjectURL(new Blob(byteArrays, { type: 'application/pdf' }));
    }

    _errorMessage(err) {
        if (err && err.body && err.body.message) {
            return err.body.message;
        }
        if (err && err.message) {
            return err.message;
        }
        return 'Unknown error';
    }

    _revokePreviewUrls() {
        for (const doc of this.previewDocuments || []) {
            if (doc.url && doc.url.startsWith('blob:')) {
                URL.revokeObjectURL(doc.url);
            }
        }
    }

    // --- Signer Row Handlers ---

    handleAddSigner() {
        this.signers = [
            ...this.signers,
            { id: ++signerIdCounter, roleName: '', contactId: '', signerName: '', signerEmail: '' }
        ];
    }

    handleRemoveSigner(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.filter((_, i) => i !== index);
    }

    handleRoleChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.map((s, i) => (i === index ? { ...s, roleName: event.detail.value } : s));
    }

    handleRoleSuggestionClick(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const role = event.currentTarget.dataset.role;
        this.signers = this.signers.map((s, i) => (i === index ? { ...s, roleName: role } : s));
    }

    async handleContactChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const contactId = event.detail.recordId;
        if (!contactId) {
            this.signers = this.signers.map((s, i) =>
                i === index ? { ...s, contactId: '', signerName: '', signerEmail: '' } : s
            );
            return;
        }
        this.signers = this.signers.map((s, i) => (i === index ? { ...s, contactId } : s));
        try {
            const info = await getContactInfo({ contactId });
            this.signers = this.signers.map((s, i) =>
                i === index
                    ? { ...s, signerName: info.name || s.signerName, signerEmail: info.email || s.signerEmail }
                    : s
            );
        } catch (_err) {
            /* user can type manually */
        }
    }

    handleNameChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.map((s, i) => (i === index ? { ...s, signerName: event.target.value } : s));
    }

    handleEmailChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.signers = this.signers.map((s, i) => (i === index ? { ...s, signerEmail: event.target.value } : s));
    }

    // --- Generate ---

    async handleGenerate() {
        this.isLoading = true;
        this.error = undefined;
        try {
            const signersPayload = this.signers.map((s) => ({
                roleName: s.roleName,
                contactId: s.contactId || null,
                signerName: s.signerName,
                signerEmail: s.signerEmail
            }));
            const signersJson = JSON.stringify(signersPayload);

            const titleFormat = (this.documentTitleFormat || '').trim() || null;
            if (this.selectedTemplates.length === 1) {
                const single = this.selectedTemplates[0];
                // Consolidated signing (#170): single-template signing always uses the
                // guided PDF path — draw/type on the real PDF, walk field-to-field, with a
                // Certificate of Completion. Templates with {@Signature_Role:Order:Type}
                // tags position chips at those tags; tag-less legacy templates get an
                // auto-appended "Signatures" block server-side (option b). One path for all.
                const options = {
                    templateId: single.templateId,
                    relatedRecordId: this.recordId,
                    signersJson,
                    signingOrder: this.signingOrder,
                    documentTitleFormat: titleFormat,
                    emailMessage: (this.emailMessage || '').trim() || null,
                    emailSubject: (this.emailSubject || '').trim() || null,
                    requireVerification: this.requireVerificationValue,
                    prefillSignerEmail: this.prefillValue,
                    expirationDays: parseInt(this.expirationDays, 10) || null
                };
                // #412 — existing record PDFs shown to the signer alongside the template.
                if (this.orderedSelectedAttachments.length > 0) {
                    options.attachedDocumentIds = this.orderedSelectedAttachments.map((f) => f.contentDocumentId);
                    options.attachedDocumentPosition = this.attachmentPosition;
                }
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                this.signerResults = await createGuidedPdfSignatureRequestV2({ options });
            } else {
                const templateIds = this.selectedTemplates.map((t) => t.templateId);
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                this.signerResults = await createPacketSignerRequest({
                    templateIdsJson: JSON.stringify(templateIds),
                    relatedRecordId: this.recordId,
                    signersJson,
                    signingOrder: this.signingOrder,
                    documentTitleFormat: titleFormat
                });
            }

            this.showToast(
                'Success',
                'Signature links generated for ' + this.signerResults.length + ' signer(s).',
                'success'
            );
            if (this.showPreviousRequests) this.loadPreviousRequests();
        } catch (err) {
            this.error = 'Error generating links: ' + (err.body ? err.body.message : err.message);
        } finally {
            this.isLoading = false;
        }
    }

    // --- Previous Requests ---

    async handleShowPreviousRequests() {
        this.showPreviousRequests = !this.showPreviousRequests;
        if (this.showPreviousRequests && this.previousRequests.length === 0) {
            await this.loadPreviousRequests();
        }
    }

    async loadPreviousRequests() {
        try {
            const data = await getPendingSignatureRequests({ relatedRecordId: this.recordId });
            this.previousRequests = data.map((req) => ({
                ...req,
                actionsDisabled: req.status === 'Signed' || req.status === 'Cancelled',
                statusBadgeClass:
                    req.status === 'Signed'
                        ? 'slds-badge slds-theme_success'
                        : req.status === 'In Progress'
                          ? 'slds-badge slds-theme_warning'
                          : 'slds-badge',
                signers: (req.signers || []).map((s) => ({
                    ...s,
                    statusIcon:
                        s.status === 'Signed'
                            ? 'utility:check'
                            : s.status === 'Viewed'
                              ? 'utility:preview'
                              : 'utility:clock',
                    statusVariant: s.status === 'Signed' ? 'success' : s.status === 'Viewed' ? 'warning' : 'bare'
                }))
            }));
        } catch (err) {
            this.showToast(
                'Error',
                'Failed to load previous requests: ' + (err.body ? err.body.message : err.message),
                'error'
            );
        }
    }

    handleCopyPreviousUrl(event) {
        this._copyToClipboard(event.currentTarget.dataset.url);
        this.showToast('Copied', 'Link copied to clipboard.', 'success');
    }

    handleViewRequest(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: event.currentTarget.dataset.requestId,
                actionName: 'view'
            }
        });
    }

    async handleResendRequest(event) {
        const requestId = event.currentTarget.dataset.requestId;
        const confirmed = window.confirm(
            'Resend this signature request to all unsigned signers?\n\n' +
                'New signing links will be emailed and the previous links will stop working.'
        );
        if (!confirmed) return;
        try {
            await resendSignatureRequest({ requestId });
            this.showToast('Resent', 'New signing links were emailed to all unsigned signers.', 'success');
            await this.loadPreviousRequests();
        } catch (err) {
            this.showToast('Unable to resend', err.body && err.body.message ? err.body.message : err.message, 'error');
        }
    }

    async handleRevokeRequest(event) {
        const requestId = event.currentTarget.dataset.requestId;
        const confirmed = window.confirm(
            'Revoke this signature request?\n\n' +
                'All unsigned signing links become invalid and signers can no longer sign. This cannot be undone.'
        );
        if (!confirmed) return;
        try {
            await cancelSignatureRequest({ requestId });
            this.showToast('Revoked', 'The signature request was revoked.', 'success');
            await this.loadPreviousRequests();
        } catch (err) {
            this.showToast('Unable to revoke', err.body && err.body.message ? err.body.message : err.message, 'error');
        }
    }

    handleCopyUrl(event) {
        this._copyToClipboard(event.currentTarget.dataset.url);
        this.showToast('Copied', 'Link copied to clipboard.', 'success');
    }

    async handleSignInPerson(event) {
        const signerId = event.currentTarget.dataset.signerId;
        const signerName = event.currentTarget.dataset.signerName || 'this signer';
        if (!signerId) {
            this.showToast(
                'Error',
                'Signer record is not available. Re-create the request to use In-Person Signing.',
                'error'
            );
            return;
        }
        const confirmed = window.confirm(
            `Confirm you have verified the identity of ${signerName} in person.\n\n` +
                `This bypasses email PIN verification. Your action will be recorded in the signature audit log.`
        );
        if (!confirmed) return;
        try {
            const url = await markSignerVerifiedInPerson({ signerId });
            if (url) {
                window.open(url, '_blank', 'noopener');
            }
            this.showToast(
                'Verified',
                `${signerName} marked as verified. Signing page opened in a new tab.`,
                'success'
            );
            // Keep the "previous requests" list in sync when the bypass was
            // triggered from a historical row (status flips to Viewed, and the
            // button hides once no longer eligible).
            await this.loadPreviousRequests();
        } catch (e) {
            const msg = e.body && e.body.message ? e.body.message : e.message || 'Unknown error.';
            this.showToast('Unable to mark verified', msg, 'error');
        }
    }

    handleCopyAllUrls() {
        const allText = this.signerResults
            .map((r) => `${r.signerName}${r.roleName ? ' (' + r.roleName + ')' : ''}: ${r.signerUrl}`)
            .join('\n');
        this._copyToClipboard(allText);
        this.showToast('Copied', 'All links copied to clipboard.', 'success');
    }

    _copyToClipboard(text) {
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text);
        } else {
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.left = '-9999px';
            document.body.appendChild(ta);
            ta.focus();
            ta.select();
            try {
                document.execCommand('copy');
            } catch (_e) {
                /* fallback failed */
            }
            document.body.removeChild(ta);
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
