import { LightningElement } from 'lwc';
import { loadFontFace } from 'c/docGenFontLoader';
import getFontFaces from '@salesforce/apex/DocGenFontController.getFontFaces';
import importUploadedFont from '@salesforce/apex/DocGenFontController.importUploadedFont';
import getFontJobStatus from '@salesforce/apex/DocGenFontController.getFontJobStatus';
import startFontProof from '@salesforce/apex/DocGenFontController.startFontProof';
import verifyFont from '@salesforce/apex/DocGenFontController.verifyFont';
import retireFont from '@salesforce/apex/DocGenFontController.retireFont';
import CAN_MANAGE from '@salesforce/customPermission/Manage_DocGen_Fonts';

export default class DocGenFontAssets extends LightningElement {
    faces = [];
    searchTerm = '';
    statusFilter = 'all';
    page = 1;
    pageSize = 24;
    selectedKey = '';
    busy = false;
    message = '';
    error = '';
    sample = 'Portwood · Şahin Şirket\nThe font you choose is the font you print.';
    showUpload = false;
    fontKey = '';
    licenseText = '';
    rights = false;
    uploadedFile;
    acceptedFormats = ['.ttf'];
    pendingJob = '';
    pollTimer;
    pollResolve;
    reviewed = false;
    canManage = CAN_MANAGE;
    loaded = new Set();
    loading = true;
    get working() {
        return this.busy || this.loading;
    }
    get showEmpty() {
        return !this.loading && !this.hasFaces;
    }
    disconnectedCallback() {
        clearTimeout(this.pollTimer);
        if (this.pollResolve) this.pollResolve();
    }
    async connectedCallback() {
        await this.refresh();
    }
    async refresh() {
        this.loading = true;
        try {
            this.faces = await getFontFaces();
            if (!this.selectedKey && this.faces.length) this.selectedKey = this.faces[0].key;
            await this.preview();
        } catch (e) {
            this.error = this.err(e);
        } finally {
            this.loading = false;
        }
    }
    get filteredFaces() {
        const term = this.searchTerm.trim().toLowerCase();
        return this.faces.filter(
            (f) =>
                (this.statusFilter === 'all' || f.status === this.statusFilter) &&
                (!term || [f.label, f.filename, f.assetKey, f.weight, f.style].join(' ').toLowerCase().includes(term))
        );
    }
    get rows() {
        return this.filteredFaces.slice((this.page - 1) * this.pageSize, this.page * this.pageSize).map((f) => ({
            ...f,
            className: f.key === this.selectedKey ? 'face face_selected' : 'face',
            selected: f.key === this.selectedKey,
            detail: `${f.weight} / ${f.style}`,
            statusLabel: this.statusLabel(f.status)
        }));
    }
    get showLibrary() {
        return this.hasFaces && !this.showUpload;
    }
    get showNoMatches() {
        return this.filteredFaces.length === 0;
    }
    get resultCount() {
        return `${this.filteredFaces.length} of ${this.faces.length} font faces`;
    }
    get pageLabel() {
        return `Page ${this.page} of ${Math.max(1, Math.ceil(this.filteredFaces.length / this.pageSize))}`;
    }
    get previousDisabled() {
        return this.page <= 1 || this.busy;
    }
    get nextDisabled() {
        return this.page * this.pageSize >= this.filteredFaces.length || this.busy;
    }
    get catalogLimitReached() {
        return this.faces.length === 200;
    }
    get statusOptions() {
        return [
            { label: 'All statuses', value: 'all' },
            { label: 'Approved', value: 'Verified' },
            { label: 'Needs a PDF specimen', value: 'Staged' },
            { label: 'Needs approval', value: 'Published' },
            { label: 'Retired', value: 'Retired' }
        ];
    }
    async search(event) {
        this.searchTerm = event.target.value || '';
        await this.filterChanged();
    }
    async filterStatus(event) {
        this.statusFilter = event.detail.value;
        await this.filterChanged();
    }
    async filterChanged() {
        this.reviewed = false;
        this.error = '';
        this.message = '';
        this.page = 1;
        if (!this.filteredFaces.some((f) => f.key === this.selectedKey))
            this.selectedKey = this.filteredFaces[0]?.key || '';
        await this.preview();
    }
    async previousPage() {
        if (this.previousDisabled) return;
        this.page--;
        await this.selectPage();
    }
    async nextPage() {
        if (this.nextDisabled) return;
        this.page++;
        await this.selectPage();
    }
    async selectPage() {
        this.selectedKey = this.rows[0]?.key || '';
        this.reviewed = false;
        await this.preview();
        this.template.querySelector('.faces')?.scrollTo({ top: 0 });
    }
    get emptyHint() {
        return this.canManage
            ? 'Upload a supported static TTF, inspect it, generate a PDF specimen, then review and approve it for Canvas and HTML templates.'
            : 'Ask your Portwood admin to upload and approve a compatible font. You can use built-in fonts now.';
    }
    get nextStep() {
        if (!this.canManage && ['Staged', 'Published'].includes(this.selected?.status))
            return 'Ask your Portwood admin to review a native PDF specimen and approve this face before using it.';
        return {
            Staged: 'Next: generate a PDF specimen, then review and approve it.',
            Published: 'Next: open the PDF specimen and approve this face after review.',
            Verified: 'Ready to use: select this face in Canvas or copy its HTML font tag.',
            Retired: 'Retired: existing template revisions keep this face. Choose an approved face for new work.'
        }[this.selected?.status];
    }
    statusLabel(status) {
        return (
            { Staged: 'Inspected', Published: 'Ready for review', Verified: 'Approved', Retired: 'Retired' }[status] ||
            status
        );
    }
    get selectedStatus() {
        return this.statusLabel(this.selected?.status);
    }
    get selected() {
        return this.faces.find((f) => f.key === this.selectedKey);
    }
    get canCopyFontTag() {
        return !!this.selected?.selectable;
    }
    get htmlFontExample() {
        return this.selected ? '<p style="' + this.selected.mergeTag + ';font-size:12pt">Your text</p>' : '';
    }
    async copyFontTag() {
        try {
            await navigator.clipboard.writeText(this.selected.mergeTag);
            this.message = 'Font tag copied. Paste it inside an HTML element’s style attribute.';
            this.error = '';
        } catch {
            this.error = 'Copy the font tag from the field below.';
        }
    }
    get reviewHint() {
        return this.selected?.hasCedilla
            ? 'Check embedded font identity, live text, layout and actual Ş / ş glyphs in the current PDF. Approval records your review.'
            : 'Check embedded font identity, live text, layout and the glyphs this face covers. This face does not include Ş / ş. Approval records your review.';
    }
    get fontDetail() {
        const f = this.selected;
        if (!f) return '';
        return f.filename + (f.sizeBytes ? ' · ' + (f.sizeBytes / 1048576).toFixed(2) + ' MB' : '');
    }
    get colorFontWarning() {
        return this.selected?.colorFont === true;
    }
    get supplementaryTextWarning() {
        return /[\uD800-\uDBFF][\uDC00-\uDFFF]/.test(this.sample || '');
    }
    get hasFaces() {
        return this.faces.length > 0;
    }
    get specimenStyle() {
        const f = this.selected;
        return f ? `font-family:'${f.previewFamily}';font-weight:${f.weight};font-style:${f.style};` : '';
    }
    get isStaged() {
        return this.selected?.status === 'Staged';
    }
    get canPreview() {
        return !!this.selected?.previewUrl;
    }
    get canProof() {
        return ['Staged', 'Published', 'Verified'].includes(this.selected?.status);
    }
    get canRetire() {
        return this.selected?.status === 'Verified';
    }
    get canReview() {
        return this.selected?.status === 'Published' && this.selected?.proofUrl;
    }
    get hasProof() {
        return !!this.selected?.proofUrl;
    }
    get uploadDisabled() {
        return this.busy || !this.uploadedFile || !this.fontKey || !this.licenseText.trim() || !this.rights;
    }
    get approveDisabled() {
        return this.busy || !this.reviewed;
    }
    async select(event) {
        this.selectedKey = event.currentTarget.dataset.key;
        this.reviewed = false;
        this.message = '';
        this.error = '';
        await this.preview();
    }
    async preview() {
        const f = this.selected;
        if (f?.previewUrl && !this.loaded.has(f.key)) {
            try {
                await loadFontFace(f);
                this.loaded.add(f.key);
            } catch (e) {
                this.error = 'The browser preview could not load the font File: ' + this.err(e);
            }
        }
    }
    openUpload() {
        this.showUpload = true;
        this.error = '';
    }
    closeUpload() {
        this.showUpload = false;
    }
    setKey(e) {
        this.fontKey = e.target.value;
    }
    setLicense(e) {
        this.licenseText = e.target.value;
    }
    setRights(e) {
        this.rights = e.target.checked;
    }
    setReviewed(e) {
        this.reviewed = e.target.checked;
    }
    setSample(e) {
        this.sample = e.target.value;
    }
    handleUploadFinished(e) {
        this.uploadedFile = e.detail.files?.[0];
        if (!this.fontKey && this.uploadedFile?.name)
            this.fontKey = this.uploadedFile.name
                .replace(/\.ttf$/i, '')
                .toLowerCase()
                .replace(/[^a-z0-9]+/g, '-')
                .replace(/^-|-$/g, '')
                .slice(0, 40);
        this.error = '';
    }
    get uploadedFilename() {
        return this.uploadedFile?.name || '';
    }
    async waitForJob(jobId) {
        this.pendingJob = jobId;
        // A pending job survives navigation in Salesforce Apex Jobs; don't start a duplicate after a timeout.
        for (let i = 0; i < 90 && this.isConnected; i++) {
            const result = await getFontJobStatus({ jobId });
            if (result.error) throw new Error(result.error);
            if (result.status === 'Completed') {
                this.pendingJob = '';
                return result;
            }
            this.message = 'Processing font in Salesforce…';
            await new Promise((resolve) => {
                this.pollResolve = resolve;
                this.pollTimer = setTimeout(resolve, 2000);
            });
            this.pollResolve = null;
        }
        throw new Error(
            'The font operation is still running. Check Salesforce Apex Jobs, then reopen Assets to see the result.'
        );
    }
    async run(action) {
        if (this.busy) return;
        this.busy = true;
        this.error = '';
        this.message = '';
        try {
            await action();
            await this.refresh();
        } catch (e) {
            this.error = this.err(e);
        } finally {
            this.busy = false;
        }
    }
    async upload() {
        await this.run(async () => {
            const previous = new Set(this.faces.map((f) => f.key));
            const jobId = await importUploadedFont({
                contentDocumentId: this.uploadedFile.documentId,
                fontKey: this.fontKey,
                licenseText: this.licenseText,
                hostingRightsConfirmed: this.rights
            });
            await this.waitForJob(jobId);
            this.faces = await getFontFaces();
            this.searchTerm = '';
            this.statusFilter = 'all';
            this.page = 1;
            this.selectedKey =
                this.faces.find((f) => !previous.has(f.key))?.key ||
                this.faces.find((f) => f.assetKey === this.fontKey && f.filename === this.uploadedFile.name)?.key ||
                this.selectedKey;
            this.page =
                Math.floor(
                    Math.max(
                        0,
                        this.faces.findIndex((f) => f.key === this.selectedKey)
                    ) / this.pageSize
                ) + 1;
            this.showUpload = false;
            this.uploadedFile = null;
            this.licenseText = '';
            this.rights = false;
            this.message = 'Font inspected and saved in Salesforce Files. Generate a PDF specimen to review it.';
        });
    }
    async proof() {
        await this.run(async () => {
            await this.waitForJob(await startFontProof({ key: this.selectedKey }));
            this.reviewed = false;
            this.message =
                'Native specimen ready. Open it and inspect the embedded font and live text before approval.';
        });
    }
    async approve() {
        await this.run(async () => {
            const id = this.selected.proofUrl.split('/').pop();
            await verifyFont({ key: this.selectedKey, proofVersionId: id, reviewed: this.reviewed });
            this.message = 'Font approved and available in Canvas and HTML templates.';
        });
    }
    async retire() {
        await this.run(async () => {
            await retireFont({ key: this.selectedKey });
            this.message = 'Font retired from new selections. Existing template revisions retain their font.';
        });
    }
    err(e) {
        return e?.body?.message || e?.message || 'The font operation could not be completed.';
    }
}
