import { LightningElement } from 'lwc';
import { loadFontFace } from 'c/docGenFontLoader';
import getFontFaces from '@salesforce/apex/DocGenFontController.getFontFaces';
import importUploadedFont from '@salesforce/apex/DocGenFontController.importUploadedFont';
import importUploadedFontArchive from '@salesforce/apex/DocGenFontController.importUploadedFontArchive';
import getFontJobStatus from '@salesforce/apex/DocGenFontController.getFontJobStatus';
import startFontProof from '@salesforce/apex/DocGenFontController.startFontProof';
import verifyFont from '@salesforce/apex/DocGenFontController.verifyFont';
import verifyFonts from '@salesforce/apex/DocGenFontController.verifyFonts';
import retireFont from '@salesforce/apex/DocGenFontController.retireFont';
import retireFonts from '@salesforce/apex/DocGenFontController.retireFonts';
import deleteRetiredFont from '@salesforce/apex/DocGenFontController.deleteRetiredFont';
import deleteRetiredFonts from '@salesforce/apex/DocGenFontController.deleteRetiredFonts';
import getLatestContentVersionId from '@salesforce/apex/DocGenController.getLatestContentVersionId';
import deleteContentVersionDocument from '@salesforce/apex/DocGenController.deleteContentVersionDocument';
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
    sample = 'Portwood 漢 Şahin Şirket\nThe font you choose is the font you print.';
    showUpload = false;
    isBulkUpload = false;
    fontKey = '';
    licenseText = '';
    rights = false;
    uploadedFile;
    bulkUploadedFiles = [];
    acceptedFormats = ['.ttf'];
    bulkAcceptedFormats = ['.ttf', '.zip'];
    pendingJob = '';
    pollTimer;
    pollResolve;
    reviewed = false;
    approvalKeys = [];
    bulkReviewed = false;
    canManage = CAN_MANAGE;
    loaded = new Set();
    previewErrors = [];
    _previewRequests = new Map();
    _faceObserver;
    _connected = false;
    loading = true;
    get working() {
        return this.busy || this.loading;
    }
    get showEmpty() {
        return !this.loading && !this.hasFaces;
    }
    disconnectedCallback() {
        this._connected = false;
        this._faceObserver?.disconnect();
        clearTimeout(this.pollTimer);
        if (this.pollResolve) this.pollResolve();
    }
    async connectedCallback() {
        this._connected = true;
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
            previewStyle: `font-family:'${f.previewFamily}';font-weight:${f.weight};font-style:${f.style};font-synthesis:none;`,
            canPreview: !!f.previewUrl && !this.previewErrors.includes(f.key),
            statusLabel: this.statusLabel(f.status),
            approvalSelected: this.approvalKeys.includes(f.key),
            canBulkApprove: f.status === 'Published' && !!f.proofUrl,
            approvalDisabled: this.busy,
            selectionLabel: `Select ${f.label} for approval`
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
        return f.filename + (f.sizeBytes ? ' ? ' + (f.sizeBytes / 1048576).toFixed(2) + ' MB' : '');
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
    get canDeleteRetired() {
        return this.selected?.status === 'Retired';
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
    get bulkUploadDisabled() {
        return this.busy || !this.bulkUploadedFiles.length || !this.licenseText.trim() || !this.rights;
    }
    get hasBulkUploadedFiles() {
        return this.bulkUploadedFiles.length > 0;
    }
    get bulkUploadCountLabel() {
        return `${this.bulkUploadedFiles.length} font${this.bulkUploadedFiles.length === 1 ? '' : 's'} selected`;
    }
    get approveDisabled() {
        return this.busy || !this.reviewed;
    }
    get hasApprovalSelection() {
        return this.approvalKeys.length > 0;
    }
    get approvalSelectionLabel() {
        return `${this.approvalKeys.length} font${this.approvalKeys.length === 1 ? '' : 's'} selected for approval`;
    }
    get bulkApproveDisabled() {
        return this.busy || !this.selectedPublishedKeys.length || !this.bulkReviewed;
    }
    get selectedFaces() {
        return this.faces.filter((face) => this.approvalKeys.includes(face.key));
    }
    get selectedStagedKeys() {
        return this.selectedFaces.filter((face) => face.status === 'Staged').map((face) => face.key);
    }
    get selectedPublishedKeys() {
        return this.selectedFaces
            .filter((face) => face.status === 'Published' && !!face.proofUrl)
            .map((face) => face.key);
    }
    get selectedRetiredKeys() {
        return this.selectedFaces.filter((face) => face.status === 'Retired').map((face) => face.key);
    }
    get selectedVerifiedKeys() {
        return this.selectedFaces.filter((face) => face.status === 'Verified').map((face) => face.key);
    }
    get bulkProofDisabled() {
        return this.busy || !this.selectedStagedKeys.length;
    }
    get bulkDeleteDisabled() {
        return this.busy || !this.selectedRetiredKeys.length;
    }
    get bulkRetireDisabled() {
        return this.busy || !this.selectedVerifiedKeys.length;
    }
    get hasPublishedSelection() {
        return this.selectedPublishedKeys.length > 0;
    }
    get hasStagedSelection() {
        return this.selectedStagedKeys.length > 0;
    }
    get hasRetiredSelection() {
        return this.selectedRetiredKeys.length > 0;
    }
    get hasVerifiedSelection() {
        return this.selectedVerifiedKeys.length > 0;
    }
    async select(event) {
        this.selectedKey = event.currentTarget.dataset.key;
        this.reviewed = false;
        this.message = '';
        this.error = '';
        await this.preview();
    }
    toggleApproval(event) {
        const key = event.target.dataset.key;
        if (!key) return;
        if (event.target.checked) {
            this.approvalKeys = this.approvalKeys.includes(key) ? this.approvalKeys : [...this.approvalKeys, key];
        } else {
            this.approvalKeys = this.approvalKeys.filter((item) => item !== key);
        }
        this.bulkReviewed = false;
    }
    setBulkReviewed(event) {
        this.bulkReviewed = event.target.checked;
    }
    clearApprovalSelection() {
        this.approvalKeys = [];
        this.bulkReviewed = false;
    }
    async preview() {
        const f = this.selected;
        await this.loadPreview(f);
        if (f && this.previewErrors.includes(f.key)) this.error = 'The browser preview could not load this font File.';
    }
    loadPreview(face) {
        if (!face?.previewUrl || this.loaded.has(face.key)) return Promise.resolve();
        if (!this._previewRequests.has(face.key)) {
            const request = loadFontFace(face)
                .then(() => {
                    if (this._connected) this.loaded.add(face.key);
                })
                .catch(() => {
                    if (this._connected && !this.previewErrors.includes(face.key))
                        this.previewErrors = [...this.previewErrors, face.key];
                });
            this._previewRequests.set(face.key, request);
        }
        return this._previewRequests.get(face.key);
    }
    renderedCallback() {
        this._faceObserver?.disconnect();
        this._faceObserver = null;
        const list = this.template.querySelector('.faces');
        if (!list) return;
        if (typeof IntersectionObserver === 'undefined') {
            for (const face of this.rows) this.loadPreview(face);
            return;
        }
        this._faceObserver = new IntersectionObserver(
            (entries) => {
                if (!this._connected) return;
                for (const entry of entries) {
                    if (!entry.isIntersecting) continue;
                    this.loadPreview(this.faces.find((face) => face.key === entry.target.dataset.key));
                    this._faceObserver.unobserve(entry.target);
                }
            },
            { root: list, rootMargin: '80px' }
        );
        for (const button of list.querySelectorAll('.face')) this._faceObserver.observe(button);
    }
    openUpload() {
        this.showUpload = true;
        this.isBulkUpload = false;
        this.error = '';
    }
    openBulkUpload() {
        this.showUpload = true;
        this.isBulkUpload = true;
        this.uploadedFile = null;
        this.bulkUploadedFiles = [];
        this.licenseText = '';
        this.rights = false;
        this.error = '';
        this.message = '';
    }
    closeUpload() {
        this.showUpload = false;
        this.isBulkUpload = false;
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
    fontKeyFromFilename(filename) {
        const key = (filename || '')
            .replace(/\.[^.]+$/, '')
            .toLowerCase()
            .replace(/[^a-z0-9]+/g, '-')
            .replace(/^-|-$/g, '')
            .slice(0, 40)
            .replace(/-+$/g, '');
        return key || 'font';
    }
    handleUploadFinished(e) {
        this.uploadedFile = e.detail.files?.[0];
        if (!this.fontKey && this.uploadedFile?.name) this.fontKey = this.fontKeyFromFilename(this.uploadedFile.name);
        this.error = '';
    }
    handleBulkUploadFinished(e) {
        const usedKeys = new Set();
        this.bulkUploadedFiles = (e.detail.files || []).map((file) => {
            const isArchive = /\.zip$/i.test(file.name || '');
            const baseKey = this.fontKeyFromFilename(file.name);
            let fontKey = baseKey;
            let suffix = 1;
            while (!isArchive && usedKeys.has(fontKey)) {
                suffix += 1;
                const suffixText = `-${suffix}`;
                fontKey = `${baseKey.slice(0, 40 - suffixText.length)}${suffixText}`;
            }
            if (!isArchive) usedKeys.add(fontKey);
            return {
                ...file,
                fontKey: isArchive ? '' : fontKey,
                displayLabel: isArchive
                    ? `${file.name} (keys derived from each .ttf inside)`
                    : `${file.name} ? ${fontKey}`
            };
        });
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
            if (result.error) {
                const error = new Error(result.error);
                error.fontJobFailed = true;
                throw error;
            }
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
    async discardUploadedFile(file) {
        if (!file?.documentId) return false;
        try {
            const versionId = await getLatestContentVersionId({ contentDocumentId: file.documentId });
            await deleteContentVersionDocument({ contentVersionId: versionId });
            return true;
        } catch (_cleanupError) {
            // Keep the native inspection error visible; cleanup is best effort.
            return false;
        }
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
            const file = this.uploadedFile;
            let jobId = '';
            try {
                jobId = await importUploadedFont({
                    contentDocumentId: file.documentId,
                    fontKey: this.fontKey,
                    licenseText: this.licenseText,
                    hostingRightsConfirmed: this.rights
                });
                await this.waitForJob(jobId);
            } catch (e) {
                // Do not delete a file while a timed-out queueable may still succeed.
                if (!jobId || e?.fontJobFailed) {
                    if (await this.discardUploadedFile(file))
                        this.message = 'Rejected upload removed from Salesforce Files.';
                }
                throw e;
            }
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
            this.isBulkUpload = false;
            this.uploadedFile = null;
            this.licenseText = '';
            this.rights = false;
            this.message = 'Font inspected and saved in Salesforce Files. Generate a PDF specimen to review it.';
        });
    }
    async bulkUpload() {
        await this.run(async () => {
            const files = [...this.bulkUploadedFiles];
            const previous = new Set(this.faces.map((f) => f.key));
            const jobs = [];
            const failures = [];

            for (const file of files) {
                try {
                    const jobId = /\.zip$/i.test(file.name || '')
                        ? await importUploadedFontArchive({
                              contentDocumentId: file.documentId,
                              licenseText: this.licenseText,
                              hostingRightsConfirmed: this.rights
                          })
                        : await importUploadedFont({
                              contentDocumentId: file.documentId,
                              fontKey: file.fontKey,
                              licenseText: this.licenseText,
                              hostingRightsConfirmed: this.rights
                          });
                    jobs.push({ file, jobId });
                } catch (e) {
                    if (await this.discardUploadedFile(file))
                        this.message = 'Rejected upload removed from Salesforce Files.';
                    failures.push(`${file.name}: ${this.err(e)}`);
                }
            }

            let completed = 0;
            for (let i = 0; i < jobs.length; i++) {
                const job = jobs[i];
                try {
                    this.message = `Inspecting font ${i + 1} of ${jobs.length}: ${job.file.name}`;
                    await this.waitForJob(job.jobId);
                    completed += 1;
                } catch (e) {
                    if (e?.fontJobFailed && (await this.discardUploadedFile(job.file)))
                        this.message = 'Rejected upload removed from Salesforce Files.';
                    failures.push(`${job.file.name}: ${this.err(e)}`);
                }
            }

            this.faces = await getFontFaces();
            this.searchTerm = '';
            this.statusFilter = 'all';
            this.page = 1;
            this.selectedKey = this.faces.find((f) => !previous.has(f.key))?.key || this.selectedKey;
            this.page =
                Math.floor(
                    Math.max(
                        0,
                        this.faces.findIndex((f) => f.key === this.selectedKey)
                    ) / this.pageSize
                ) + 1;
            this.showUpload = false;
            this.isBulkUpload = false;
            this.bulkUploadedFiles = [];
            this.licenseText = '';
            this.rights = false;

            if (failures.length) {
                this.error = failures.join('\n');
                this.message = `${completed} of ${files.length} fonts inspected. Review the errors and retry the failed files.`;
            } else {
                this.message = `${completed} fonts inspected and saved in Salesforce Files. Generate PDF specimens to review them.`;
            }
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
    async approveSelected() {
        await this.run(async () => {
            const keys = [...this.selectedPublishedKeys];
            await verifyFonts({ keys, reviewed: this.bulkReviewed });
            this.approvalKeys = this.approvalKeys.filter((key) => !keys.includes(key));
            this.bulkReviewed = false;
            this.message = `${keys.length} font${keys.length === 1 ? '' : 's'} approved and available in Canvas and HTML templates.`;
        });
    }
    async generateSelectedProofs() {
        await this.run(async () => {
            const keys = [...this.selectedStagedKeys];
            const failures = [];
            let completed = 0;
            for (let i = 0; i < keys.length; i++) {
                const key = keys[i];
                const face = this.faces.find((item) => item.key === key);
                try {
                    this.message = `Generating PDF specimen ${i + 1} of ${keys.length}: ${face?.label || key}`;
                    await this.waitForJob(await startFontProof({ key }));
                    completed += 1;
                } catch (e) {
                    failures.push(`${face?.label || key}: ${this.err(e)}`);
                }
            }
            this.bulkReviewed = false;
            if (failures.length) {
                this.error = failures.join('\n');
                this.message = `${completed} of ${keys.length} PDF specimens generated. Review the errors and retry.`;
            } else {
                this.message = `${completed} PDF specimens generated. Review them, then approve the selected fonts.`;
            }
        });
    }
    async deleteSelectedRetired() {
        const keys = [...this.selectedRetiredKeys];
        if (
            !keys.length ||
            !window.confirm(`Delete ${keys.length} selected retired font${keys.length === 1 ? '' : 's'}?`)
        )
            return;
        await this.run(async () => {
            await deleteRetiredFonts({ keys });
            this.approvalKeys = this.approvalKeys.filter((key) => !keys.includes(key));
            this.bulkReviewed = false;
            this.message = `${keys.length} retired font${keys.length === 1 ? '' : 's'} deleted. Active fonts were not changed.`;
        });
    }
    async retireSelected() {
        const keys = [...this.selectedVerifiedKeys];
        if (!keys.length || !window.confirm(`Retire ${keys.length} approved font${keys.length === 1 ? '' : 's'}?`))
            return;
        await this.run(async () => {
            await retireFonts({ keys });
            this.approvalKeys = this.approvalKeys.filter((key) => !keys.includes(key));
            this.bulkReviewed = false;
            this.message = `${keys.length} font${keys.length === 1 ? '' : 's'} retired. Existing template revisions retain them.`;
        });
    }
    async retire() {
        await this.run(async () => {
            await retireFont({ key: this.selectedKey });
            this.message = 'Font retired from new selections. Existing template revisions retain their font.';
        });
    }
    async deleteRetired() {
        if (!this.canDeleteRetired) return;
        if (!window.confirm('Delete this retired font revision? Active and approved fonts cannot be deleted.')) return;
        await this.run(async () => {
            const label = this.selected.label;
            await deleteRetiredFont({ key: this.selectedKey });
            this.faces = this.faces.filter((face) => face.key !== this.selectedKey);
            this.selectedKey = this.faces[0]?.key || '';
            this.message = `${label} was deleted. Active and approved fonts cannot be deleted.`;
        });
    }
    err(e) {
        return e?.body?.message || e?.message || 'The font operation could not be completed.';
    }
}
