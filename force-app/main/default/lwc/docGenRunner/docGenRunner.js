import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTemplatesForObject from '@salesforce/apex/DocGenController.getTemplatesForObjectAndRecord';
import generateDocumentParts from '@salesforce/apex/DocGenController.generateDocumentParts';
import getContentVersionBase64 from '@salesforce/apex/DocGenController.getContentVersionBase64';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import saveGeneratedDocument from '@salesforce/apex/DocGenController.saveGeneratedDocument';
import generatePdfAsync from '@salesforce/apex/DocGenController.generatePdfAsync';
import getPdfSampleGenerationStatus from '@salesforce/apex/DocGenController.getPdfSampleGenerationStatus';
import scoutAttachedImageSize from '@salesforce/apex/DocGenController.scoutAttachedImageSize';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import getChildRecordPdfs from '@salesforce/apex/DocGenController.getChildRecordPdfs';
import getRecordPdfs from '@salesforce/apex/DocGenController.getRecordPdfs';
import generateDocumentGiantQuery from '@salesforce/apex/DocGenController.generateDocumentGiantQuery';
import getGiantQueryJobStatus from '@salesforce/apex/DocGenController.getGiantQueryJobStatus';
import getGiantQueryFragments from '@salesforce/apex/DocGenController.getGiantQueryFragments';
import generateDocumentPartsGiantQuery from '@salesforce/apex/DocGenController.generateDocumentPartsGiantQuery';
import cleanupGiantQueryFragments from '@salesforce/apex/DocGenController.cleanupGiantQueryFragments';
import getChildRecordPage from '@salesforce/apex/DocGenController.getChildRecordPage';
import scoutChildCounts from '@salesforce/apex/DocGenController.scoutChildCounts';
import launchGiantQueryPdfBatch from '@salesforce/apex/DocGenController.launchGiantQueryPdfBatch';
import getSortedChildIds from '@salesforce/apex/DocGenController.getSortedChildIds';
import getChildRecordsByIds from '@salesforce/apex/DocGenController.getChildRecordsByIds';
import { NavigationMixin } from 'lightning/navigation';
import { downloadBase64 as downloadBase64Util } from 'c/docGenUtils';
import prepareChartImages from '@salesforce/apex/DocGenChartImageController.prepareChartImages';
import getChartTagsForTemplate from '@salesforce/apex/DocGenChartImageController.getChartTagsForTemplate';
import uploadChartImage from '@salesforce/apex/DocGenChartImageController.uploadChartImage';
import deleteChartImages from '@salesforce/apex/DocGenChartImageController.deleteChartImages';
import { loadScript } from 'lightning/platformResourceLoader';
import CHARTJS_RESOURCE from '@salesforce/resourceUrl/DocGenChartJs';
import {
    newBucketAccumulator,
    accumulatePage,
    finalizeBuckets,
    renderChartPng,
    isStyleSupported,
    prepareChartsClientSide
} from 'c/docGenChartJs';
import { buildDocx } from './docGenZipWriter';
import { mergePdfs } from './docGenPdfMerger';
import { extractFirstImageFromPdfBase64 } from './docGenPdfImageExtractor';
import renderImageAsPdfBase64 from '@salesforce/apex/DocGenController.renderImageAsPdfBase64';
import OUT_FMT_FIELD from '@salesforce/schema/DocGen_Template__c.Output_Format__c';
import TYPE_FIELD from '@salesforce/schema/DocGen_Template__c.Type__c';
import IS_DEFAULT_FIELD from '@salesforce/schema/DocGen_Template__c.Is_Default__c';
import CATEGORY_FIELD from '@salesforce/schema/DocGen_Template__c.Category__c';

// #95 — Custom Labels so the runner UI follows the user's Salesforce language
// (Spanish translations shipped in translations/es.translation-meta.xml).
import LBL_SUBTITLE from '@salesforce/label/c.DocGenRunner_Subtitle';
import LBL_CATEGORY from '@salesforce/label/c.DocGenRunner_Category';
import LBL_SELECT_TEMPLATE from '@salesforce/label/c.DocGenRunner_SelectTemplate';
import LBL_CHOOSE_TEMPLATE from '@salesforce/label/c.DocGenRunner_ChooseTemplate';
import LBL_OUTPUT_DESTINATION from '@salesforce/label/c.DocGenRunner_OutputDestination';
import LBL_CREATE_DOCUMENT from '@salesforce/label/c.DocGenRunner_CreateDocument';
import LBL_DOCUMENT_PACKET from '@salesforce/label/c.DocGenRunner_DocumentPacket';
import LBL_COMBINE_PDFS from '@salesforce/label/c.DocGenRunner_CombinePdfs';
import LBL_CREATE_PACKET from '@salesforce/label/c.DocGenRunner_CreatePacket';
import LBL_COMBINE_PDFS_ACTION from '@salesforce/label/c.DocGenRunner_CombinePdfsAction';
import LBL_DOWNLOAD from '@salesforce/label/c.DocGenRunner_Download';
import LBL_SAVE_TO_RECORD from '@salesforce/label/c.DocGenRunner_SaveToRecord';
import LBL_SAVE_AND_DOWNLOAD from '@salesforce/label/c.DocGenRunner_SaveAndDownload';
import LBL_SELECT_RECORD from '@salesforce/label/c.DocGenRunner_SelectRecord';
import LBL_SEARCH_RECORDS from '@salesforce/label/c.DocGenRunner_SearchRecords';
import LBL_CHOOSE_RECORD_PROMPT from '@salesforce/label/c.DocGenRunner_ChooseRecordPrompt';

// Proper MIME per Office extension for browser downloads. xlsm is resolved
// after the parts call — the server detects macro-enabled workbooks and the
// runner upgrades xlsx → xlsm from the parts payload's isMacroEnabled flag.
const OFFICE_MIME_BY_EXT = {
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    xlsm: 'application/vnd.ms-excel.sheet.macroEnabled.12'
};

export default class DocGenRunner extends NavigationMixin(LightningElement) {
    // Exposed to the template as {label.X}. Custom Labels resolve to the
    // running user's language at runtime (#95).
    label = {
        subtitle: LBL_SUBTITLE,
        category: LBL_CATEGORY,
        selectTemplate: LBL_SELECT_TEMPLATE,
        chooseTemplate: LBL_CHOOSE_TEMPLATE,
        outputDestination: LBL_OUTPUT_DESTINATION,
        download: LBL_DOWNLOAD,
        saveToRecord: LBL_SAVE_TO_RECORD,
        saveAndDownload: LBL_SAVE_AND_DOWNLOAD,
        selectRecord: LBL_SELECT_RECORD,
        searchRecords: LBL_SEARCH_RECORDS,
        chooseRecordPrompt: LBL_CHOOSE_RECORD_PROMPT
    };

    /**
     * Record the runner generates against.
     *
     * On a record page the framework injects this. On an App Page (or a
     * standalone tab) there is no record context, so it comes from one of two
     * places instead: a fixed Id typed into App Builder (still this setter), or
     * the runtime record picker (`_pickedRecordId`, below). The picker wins
     * when both are present — it is the user's explicit choice for this run.
     *
     * This is an accessor rather than a plain field so the ~25 `this.recordId`
     * read sites and the `$recordId` wire config need no change: they all see
     * the resolved value. Wire reactivity still works because the getter reads
     * reactive fields.
     */
    @api
    get recordId() {
        return this._pickedRecordId || this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
    }

    /**
     * Object API name for `recordId`. Injected on record pages; on an App Page
     * it falls back to the picker's configured object once a record is picked,
     * so the template wire has something to filter on.
     */
    @api
    get objectApiName() {
        if (this._objectApiName) {
            return this._objectApiName;
        }
        return this._pickedRecordId ? this.recordPickerObject : undefined;
    }
    set objectApiName(value) {
        this._objectApiName = value;
    }

    /**
     * App Builder: object API name to search when the runner is placed
     * somewhere without record context. Blank = no picker.
     */
    @api recordPickerObject;

    @api showDownloadOption;
    @api showSaveToRecordOption;
    @api showSaveAndDownloadOption;
    @api defaultOutputDestination;
    @api showDocumentPacketOption;
    @api showCombinePdfsOption;
    @api showCombineWithExistingPdfsOption;

    _recordId;
    _objectApiName;
    @track _pickedRecordId = '';

    @track templateOptions = [];
    @track selectedTemplateId = '';
    @track selectedCategory = '__ALL__'; // 1.47 — category filter
    // 1.74 — runtime output format override removed. Templates render in
    // the format they were saved with. To offer both PDF and DOCX from the
    // same source, save the template twice with different Output Format
    // values. Cross-format override produced subtle corruption in either
    // direction (PDF→DOCX gave Word "file is corrupt" errors; DOCX→PDF blew
    // sync heap on real templates) and is no longer worth the maintenance
    // burden against a clean one-template-one-format model.
    // null = the user hasn't picked yet, so the admin's configured default applies.
    // Set to a concrete mode by handleOutputModeChange and by the giant-query router.
    // Always read through resolvedOutputMode, never directly.
    @track outputMode = null;
    @track isLoading = false;
    @track error = '';
    @track loadingMessage = '';
    @track isGiantQueryMode = false;
    @track progressPercent = 0;
    @track showProgressBar = false;

    @track appMode = 'generate'; // generate, packet, mergeOnly, mergeChildren

    // Merge settings
    @track mergeEnabled = false;
    @track recordPdfOptions = [];
    @track selectedPdfCvIds = [];

    // Packet settings
    @track packetTemplateIds = [];
    @track packetIncludeExisting = false;
    @track packetExistingPdfIds = [];

    // Merge Only settings
    @track mergeOnlyCvIds = [];

    // Child Merge settings
    @track childRelationships = [];
    @track selectedChildRel = '';
    @track childFilterClause = '';
    @track childPdfsLoaded = false;
    @track childRecordGroups = [];
    @track selectedChildPdfCvIds = [];

    _templateData = [];

    // --- Modern SaaS Mode Getters ---

    _isEnabled(value) {
        return value !== false && value !== 'false';
    }

    get canDownload() {
        return this._isEnabled(this.showDownloadOption);
    }
    get canSaveToRecord() {
        return this._isEnabled(this.showSaveToRecordOption);
    }
    get canSaveAndDownload() {
        return this._isEnabled(this.showSaveAndDownloadOption);
    }

    /**
     * The admin's "Default Output Destination" pick, normalized to an internal mode.
     * Drives BOTH which pill is pre-selected and which renders first, so the default
     * is always the leftmost one. Unrecognized/blank falls back to 'both'; if that
     * destination isn't available the normal allowed-mode order takes over.
     */
    get configuredDefaultMode() {
        const raw = (this.defaultOutputDestination || '').trim().toLowerCase();
        if (raw === 'download') {
            return 'download';
        }
        if (raw === 'save to record' || raw === 'save') {
            return 'save';
        }
        return 'both';
    }
    get canUseDocumentPacket() {
        return this._isEnabled(this.showDocumentPacketOption);
    }
    get canUseCombinePdfs() {
        return this._isEnabled(this.showCombinePdfsOption);
    }
    get canUseCombineWithExistingPdfs() {
        return this._isEnabled(this.showCombineWithExistingPdfsOption);
    }

    get modernModeOptions() {
        const options = [
            {
                label: LBL_CREATE_DOCUMENT,
                value: 'generate',
                icon: '📄',
                class: this.appMode === 'generate' ? 'seg-btn active' : 'seg-btn'
            }
        ];
        if (this.canUseDocumentPacket) {
            options.push({
                label: LBL_DOCUMENT_PACKET,
                value: 'packet',
                icon: '📚',
                class: this.appMode === 'packet' ? 'seg-btn active' : 'seg-btn'
            });
        }
        if (this.canUseCombinePdfs) {
            options.push({
                label: LBL_COMBINE_PDFS,
                value: 'mergeOnly',
                icon: '🔗',
                class: this.appMode === 'mergeOnly' ? 'seg-btn active' : 'seg-btn'
            });
        }
        return options;
    }

    get showModeSelector() {
        return this.modernModeOptions.length > 1;
    }

    // --- Record picker (App Page / no record context) ---

    /**
     * The picker renders only where it is both configured AND needed: an admin
     * set an object to search, and the placement gave us no record of its own.
     * A record page always injects recordId, so the picker never appears there
     * even if the property is somehow set.
     */
    get showRecordPicker() {
        return !!this.recordPickerObject && !this._recordId;
    }

    get pickedRecordId() {
        return this._pickedRecordId || null;
    }

    /**
     * True when the runner has no record to work with and the user still has a
     * way to give it one. Suppresses the template/output UI (and its "no
     * templates for this record" empty state) until a record is chosen.
     */
    get awaitingRecordSelection() {
        return this.showRecordPicker && !this._pickedRecordId;
    }

    handleRecordPicked(event) {
        const newId = event.detail ? event.detail.recordId : null;
        this._pickedRecordId = newId || '';
        // Everything below is scoped to the previous record — templates reload
        // through the wire, but these were fetched imperatively and would
        // otherwise offer the old record's files against the new one.
        this.error = '';
        this.recordPdfOptions = [];
        this.selectedPdfCvIds = [];
        this.mergeEnabled = false;
        this.packetExistingPdfIds = [];
        this.packetIncludeExisting = false;
        this.childPdfsLoaded = false;
        this.childRecordGroups = [];
        this.selectedChildPdfCvIds = [];
    }

    get _isMobile() {
        return /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent);
    }

    get allowedOutputModes() {
        // Mobile Blob.toPdf has historical base64 + blob-URL download issues
        // (iOS Safari especially), so we restrict mobile to save-to-record only.
        if (this._isMobile) {
            return this.canSaveToRecord ? ['save'] : [];
        }
        // Combine PDFs (mergeOnly) and Document Packet are download-only.
        // Both flows concatenate multiple source PDFs into one output, with
        // every source file's bytes sitting in Apex heap simultaneously
        // during the merge. Total source size has to stay under ~6 MB to
        // survive sync heap. Save-to-Record adds nothing here (sources
        // already live as CVs on the record) and would just amplify heap
        // pressure with the post-merge ContentVersion insert. Download
        // streams the merged blob to the browser without that extra step.
        if (this.appMode === 'mergeOnly' || this.appMode === 'packet') {
            return this.canDownload ? ['download'] : [];
        }
        // Save to Record is always offered (when the admin enabled it) for
        // every output format. Files that exceed the 5 MB Apex single-CV
        // stitch ceiling fall through to a "downloaded — drag here to attach"
        // two-step flow at generate time, so the user always gets a path to
        // attach the file. Previously DOCX/Excel and Giant-Query templates
        // hid this option, which left users without an obvious way to
        // attach generated DOCX output to the record.
        const modes = [];
        if (this.canDownload) {
            modes.push('download');
        }
        if (this.canSaveToRecord) {
            modes.push('save');
        }
        // Save & Download has its own App Builder checkbox, but it is still the
        // combination of the other two rather than a third destination — so it
        // also requires BOTH to be enabled. It must never reintroduce a
        // destination the admin deliberately turned off.
        if (this.canDownload && this.canSaveToRecord && this.canSaveAndDownload) {
            modes.push('both');
        }
        // The admin's configured default leads — this list is both the rendered
        // order and the fallback order, so promoting it here puts the default pill
        // on the left AND makes it the pre-selection. Promotion only, never
        // inclusion: a destination the admin turned off can't be defaulted into.
        const preferred = this.configuredDefaultMode;
        const preferredIdx = modes.indexOf(preferred);
        if (preferredIdx > 0) {
            modes.splice(preferredIdx, 1);
            modes.unshift(preferred);
        }
        return modes;
    }

    get modernOutputOptions() {
        const allowedModes = this.allowedOutputModes;
        const resolvedMode = allowedModes.includes(this.outputMode) ? this.outputMode : allowedModes[0];
        // Rendered left-to-right in allowedOutputModes order, which already puts the
        // admin's configured default first.
        const byMode = {
            download: { label: LBL_DOWNLOAD, icon: '⬇️' },
            save: { label: LBL_SAVE_TO_RECORD, icon: '☁️' },
            both: { label: LBL_SAVE_AND_DOWNLOAD, icon: '⬇️☁️' }
        };
        return allowedModes
            .filter((mode) => byMode[mode])
            .map((mode) => ({
                label: byMode[mode].label,
                value: mode,
                icon: byMode[mode].icon,
                class: resolvedMode === mode ? 'pill-btn active' : 'pill-btn'
            }));
    }

    get showOutputDestinationSelector() {
        // Only when there is an actual choice to make. One surviving option — the
        // admin unchecked the other in App Builder, or the app mode allows only
        // one (mergeOnly/packet are download-only, mobile is save-only) — used to
        // render a lone pill that looked interactive and did nothing.
        //
        // Safe to hide because generation never reads this.outputMode directly:
        // all 13 call sites go through resolvedOutputMode, which falls back to
        // whichever mode IS allowed. Hiding the control cannot strand the user on
        // a mode the runner won't honour.
        return this.modernOutputOptions.length > 1;
    }

    get resolvedOutputMode() {
        const allowedModes = this.allowedOutputModes;
        if (allowedModes.includes(this.outputMode)) {
            return this.outputMode;
        }
        // allowedOutputModes is already ordered with the admin's configured default
        // first, so taking [0] keeps the resolved mode and the active pill in sync
        // by construction rather than by two lists agreeing.
        return allowedModes[0] || 'download';
    }

    /**
     * Waits for the Save-to-Record Queueable to land its ContentVersion.
     *
     * Reuses getPdfSampleGenerationStatus, which already reports job status and,
     * on completion, the ContentVersion created on the record since `requestedAt`.
     *
     * The ceiling is generous on purpose: this path exists FOR the documents too
     * big to render synchronously, and those are exactly the ones that take
     * minutes. A too-short wait would fail the download half on precisely the
     * files the async route was chosen to support.
     */
    async _waitForAsyncSavedPdf(jobId, requestedAt) {
        const MAX_ATTEMPTS = 150;
        const INTERVAL_MS = 2000;
        for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
            // eslint-disable-next-line no-await-in-loop
            const result = await getPdfSampleGenerationStatus({
                jobId,
                recordId: this.recordId,
                requestedAt
            });
            if (result && result.jobStatus === 'Failed') {
                throw new Error(result.extendedStatus || 'Server-side PDF generation failed.');
            }
            if (result && result.jobStatus === 'Aborted') {
                throw new Error(result.extendedStatus || 'Server-side PDF generation was aborted.');
            }
            if (result && result.contentVersionId) {
                return result;
            }
            // eslint-disable-next-line no-await-in-loop
            await new Promise((resolve) => setTimeout(resolve, INTERVAL_MS));
        }
        // The save itself may still succeed — only the download half timed out,
        // so say that rather than implying the document was lost.
        throw new Error(
            'The document is still generating. It will appear on the record when it finishes — ' +
                'download it from there.'
        );
    }

    /**
     * Hands the browser the saved file by URL rather than by bytes.
     *
     * NavigationMixin (not a hand-built anchor) because the runner also lives on
     * Experience Cloud pages, where a bare '/sfc/...' path misses the site prefix;
     * standard__webPage resolves it for the current context. Nothing passes
     * through the Aura response, so file size is irrelevant here.
     */
    _downloadSavedContentVersion(contentVersionId) {
        if (!contentVersionId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: {
                url: `/sfc/servlet.shepherd/version/download/${contentVersionId}`
            }
        });
    }

    /** True when the resolved mode attaches the document to the record. */
    get wantsSaveToRecord() {
        const mode = this.resolvedOutputMode;
        return mode === 'save' || mode === 'both';
    }

    /** True when the resolved mode also hands the file to the browser. */
    get wantsDownload() {
        const mode = this.resolvedOutputMode;
        return mode === 'download' || mode === 'both';
    }

    /**
     * Single exit point for generated bytes: downloads, saves, or both, according
     * to the resolved output mode.
     *
     * Every generation path already held the base64 and chose one of the two —
     * "Save & Download" is just not choosing. That is why this needs no second
     * generate call and no extra Apex: the bytes are in the browser either way,
     * and saveGeneratedDocument is the same call the save-only path already made.
     *
     * Downloads BEFORE saving on purpose. If the ContentVersion insert fails, the
     * user still has the file in hand and gets an error they can act on; the
     * reverse order would lose both.
     *
     * @param {object} opts
     * @param {string} opts.base64 Generated file content
     * @param {string} opts.fileName File name WITHOUT extension
     * @param {string} opts.extension File extension, no dot (pdf, docx, …)
     * @param {string} opts.mimeType MIME type for the browser download
     * @param {number} [opts.byteLength] Decoded size, for the 5 MB save ceiling
     * @param {string} [opts.label] Noun used in the success toast ("PDF", "Document packet")
     */
    async _deliverGeneratedDocument({ base64, fileName, extension, mimeType, byteLength, label }) {
        const fullName = `${fileName}.${extension}`;
        const noun = label || 'Document';
        const wantsSave = this.wantsSaveToRecord;
        const wantsDownload = this.wantsDownload;

        // Above the 5 MB single-CV stitch ceiling the save cannot succeed, so the
        // runner downloads and offers the drag-to-attach box instead. That path is
        // already a download, so a 'both' request is fully satisfied by it.
        const OVERSIZE_LIMIT = 5 * 1024 * 1024;
        if (wantsSave && byteLength && byteLength > OVERSIZE_LIMIT) {
            this.downloadBase64(base64, fullName, mimeType);
            this._oversizedSaveToRecord = {
                fileName: fullName,
                sizeMb: (byteLength / 1024 / 1024).toFixed(1)
            };
            this.showToast(
                'Document downloaded',
                `File is ${this._oversizedSaveToRecord.sizeMb} MB — too large to save automatically. ` +
                    'Drag the just-downloaded file into the upload box that appeared below to attach it to this record.',
                'info'
            );
            return;
        }

        if (wantsDownload) {
            this.downloadBase64(base64, fullName, mimeType);
        }
        if (wantsSave) {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveGeneratedDocument({
                recordId: this.recordId,
                fileName: fileName,
                base64Data: base64,
                extension: extension
            });
        }

        if (wantsSave && wantsDownload) {
            this.showToast('Success', `${noun} saved to record and downloaded.`, 'success');
        } else if (wantsSave) {
            this.showToast('Success', `${noun} saved to record.`, 'success');
        } else {
            this.showToast('Success', `${noun} downloaded.`, 'success');
        }
    }

    get isGenerateMode() {
        return this.appMode === 'generate';
    }
    get isPacketMode() {
        return this.appMode === 'packet';
    }
    get isMergeOnlyMode() {
        return this.appMode === 'mergeOnly';
    }
    get isMergeChildrenMode() {
        return this.appMode === 'mergeChildren';
    }

    get templateOutputFormat() {
        const t = this._templateData.find((tmpl) => tmpl.Id === this.selectedTemplateId);
        return t ? t[OUT_FMT_FIELD.fieldApiName] : null;
    }

    get showMergeOption() {
        return this.templateOutputFormat === 'PDF' && this.canUseCombineWithExistingPdfs;
    }
    get progressBarStyle() {
        return `width: ${this.progressPercent}%`;
    }
    get hasRecordPdfs() {
        return this.recordPdfOptions.length > 0;
    }

    get isGenerateDisabled() {
        return !this.selectedTemplateId || this.isLoading || this.modernOutputOptions.length === 0;
    }
    get isPacketDisabled() {
        return this.packetTemplateIds.length < 1 || this.isLoading || this.modernOutputOptions.length === 0;
    }
    get isMergeOnlyDisabled() {
        return this.mergeOnlyCvIds.length < 2 || this.isLoading || this.modernOutputOptions.length === 0;
    }
    get isMergeChildrenDisabled() {
        return this.selectedChildPdfCvIds.length < 1 || this.isLoading || this.modernOutputOptions.length === 0;
    }

    get generateButtonLabel() {
        if (this.mergeEnabled && this.selectedPdfCvIds.length > 0) {
            return `Create & Combine (${this.selectedPdfCvIds.length + 1} Files) ✨`;
        }
        return `${LBL_CREATE_DOCUMENT} ✨`;
    }

    get packetButtonLabel() {
        const count = this.packetTemplateIds.length;
        return count > 0 ? `Create Packet (${count} Designs) 📚✨` : `${LBL_CREATE_PACKET} ✨`;
    }

    get mergeOnlyButtonLabel() {
        const count = this.mergeOnlyCvIds.length;
        return count > 0 ? `Combine ${count} PDFs 🔗✨` : `${LBL_COMBINE_PDFS_ACTION} ✨`;
    }

    get mergeChildrenButtonLabel() {
        const count = this.selectedChildPdfCvIds.length;
        return count > 0 ? `Combine ${count} Files 📂✨` : 'Combine Files ✨';
    }

    @wire(getTemplatesForObject, { objectApiName: '$objectApiName', recordId: '$recordId' })
    wiredTemplates({ error, data }) {
        if (data) {
            this._templateData = data;
            this._rebuildTemplateOptions();
            this.error = undefined;
            // Preload record PDFs for merge option
            this.loadRecordPdfs();
        } else if (error) {
            this.error = 'Error loading templates: ' + this.normalizeTemplateLoadError(error.body.message);
        }
    }

    normalizeTemplateLoadError(message) {
        const rawMessage = message || '';
        if (rawMessage.includes('Variable does not exist: tmpVar')) {
            return (
                'Unable to load Portwood templates. Ask an admin to verify that at least one active Portwood Template is shared with you for this object. ' +
                'If Portwood Template sharing is Private, share the template record directly or set Setup > Sharing Settings > Portwood Template > Default Internal Access to Public Read.'
            );
        }
        return rawMessage || 'Unknown error';
    }

    /**
     * Rebuilds templateOptions from _templateData applying the current category filter,
     * decorating default templates with a star prefix, and auto-selecting the default
     * (or the first option if no default).
     */
    _rebuildTemplateOptions() {
        const data = this._templateData || [];
        const filtered =
            this.selectedCategory && this.selectedCategory !== '__ALL__'
                ? data.filter((t) => (t[CATEGORY_FIELD.fieldApiName] || '__UNCATEGORIZED__') === this.selectedCategory)
                : data;
        const defaultTemplate = filtered.find((t) => t[IS_DEFAULT_FIELD.fieldApiName]);
        const stillSelected = filtered.some((t) => t.Id === this.selectedTemplateId);
        const selectedTemplateId = stillSelected
            ? this.selectedTemplateId
            : defaultTemplate
              ? defaultTemplate.Id
              : filtered[0]
                ? filtered[0].Id
                : '';
        this.selectedTemplateId = selectedTemplateId;
        this.templateOptions = filtered.map((t) => {
            const isDefault = !!t[IS_DEFAULT_FIELD.fieldApiName];
            const catVal = t[CATEGORY_FIELD.fieldApiName];
            const cat = catVal ? `[${catVal}] ` : '';
            return {
                label: `${isDefault ? '★ ' : ''}${cat}${t.Name}`,
                value: t.Id,
                selected: t.Id === selectedTemplateId
            };
        });
    }

    /**
     * Distinct categories present in the loaded template list, plus an "All" sentinel.
     * Hidden when there's only one category (no point showing a filter with one option).
     */
    get categoryOptions() {
        const data = this._templateData || [];
        const distinct = new Set();
        for (const t of data) {
            const v = t[CATEGORY_FIELD.fieldApiName];
            distinct.add(v ? v : '__UNCATEGORIZED__');
        }
        if (distinct.size <= 1) return [];
        const opts = [{ label: 'All Categories', value: '__ALL__' }];
        const sorted = Array.from(distinct).sort();
        for (const c of sorted) {
            opts.push({ label: c === '__UNCATEGORIZED__' ? '(Uncategorized)' : c, value: c });
        }
        return opts;
    }

    get showCategoryFilter() {
        return this.categoryOptions.length > 0;
    }

    get selectedTemplate() {
        return this._templateData.find((t) => t.Id === this.selectedTemplateId);
    }

    /**
     * Effective Output_Format__c value for THIS run. As of 1.74 the runtime
     * format override picker is gone — the template's saved Output_Format__c
     * is binding. To offer both PDF and DOCX from one source, save the
     * template twice with different Output Format values.
     */
    get effectiveOutputFormat() {
        return this.templateOutputFormat;
    }

    get showEmptyState() {
        return this._templateData && this._templateData.length === 0;
    }

    get emptyStateMessage() {
        return (
            'No templates are ready for ' +
            (this.objectApiName || 'this object') +
            ' yet. Ask your Portwood admin to create or activate a template for this object and share it with you. Admins can open Portwood → Get started for a working Account or Opportunity example, then check the template’s visibility settings.'
        );
    }

    handleCategoryChange(event) {
        this.selectedCategory = event.target.value;
        this._rebuildTemplateOptions();
    }

    @wire(getChildRelationships, { objectName: '$objectApiName' })
    wiredRelationships({ data }) {
        if (data) {
            this.childRelationships = data;
        }
    }

    get childRelComboboxOptions() {
        return this.childRelationships.map((rel) => ({ label: rel.label, value: rel.value }));
    }

    get pdfTemplateOptions() {
        return this._templateData
            .filter((t) => t[OUT_FMT_FIELD.fieldApiName] === 'PDF')
            .map((t) => ({ label: t.Name, value: t.Id }));
    }

    async loadRecordPdfs() {
        try {
            this.recordPdfOptions = await getRecordPdfs({ recordId: this.recordId });
        } catch {
            this.showToast('Error', 'Failed to load record PDFs', 'error');
        }
    }

    // --- Event Handlers ---

    handleModeChangeInternal(event) {
        this.appMode = event.currentTarget.dataset.value;
        this.resetState();
    }

    handleOutputModeChangeInternal(event) {
        this.outputMode = event.currentTarget.dataset.value;
    }

    handleTemplateChangeInternal(event) {
        this.selectedTemplateId = event.target.value;
        this.selectedPdfCvIds = [];
        // Keep templateOptions.selected in sync so the <select> re-renders
        // correctly when the Generate section is destroyed/recreated by lwc:if
        this.templateOptions = this.templateOptions.map((t) => ({
            ...t,
            selected: t.value === this.selectedTemplateId
        }));
    }

    handleMergeToggle(event) {
        this.mergeEnabled = event.target.checked;
        if (this.mergeEnabled && this.recordPdfOptions.length === 0) {
            this.loadRecordPdfs();
        }
    }

    handlePdfSelectionInternal(event) {
        const val = event.target.value;
        if (event.target.checked) {
            this.selectedPdfCvIds = [...this.selectedPdfCvIds, val];
        } else {
            this.selectedPdfCvIds = this.selectedPdfCvIds.filter((id) => id !== val);
        }
    }

    handlePacketTemplateSelection(event) {
        this.packetTemplateIds = event.detail.value;
    }

    handlePacketIncludeToggle(event) {
        this.packetIncludeExisting = event.target.checked;
        if (!this.packetIncludeExisting) {
            this.packetExistingPdfIds = [];
            return;
        }
        // Always re-fetch when the user toggles on — file lists change frequently
        // (record may have new PDFs since last open) and the call is cheap.
        this.loadRecordPdfs();
    }

    handlePacketExistingPdfSelection(event) {
        this.packetExistingPdfIds = event.detail.value || [];
    }

    handleMergeOnlySelection(event) {
        this.mergeOnlyCvIds = event.detail.value;
    }

    handleChildRelChangeInternal(event) {
        this.selectedChildRel = event.target.value;
        this.childPdfsLoaded = false;
        this.selectedChildPdfCvIds = [];
    }

    handleChildFilterChangeInternal(event) {
        this.childFilterClause = event.target.value;
    }

    async handleLoadChildPdfs() {
        this.isLoading = true;
        try {
            const rel = this.childRelationships.find((r) => r.value === this.selectedChildRel);
            const data = await getChildRecordPdfs({
                parentRecordId: this.recordId,
                childObject: rel.childObjectApiName,
                lookupField: rel.lookupField,
                filterClause: this.childFilterClause
            });
            this.childRecordGroups = data;
            this.childPdfsLoaded = true;
        } catch (e) {
            this.showToast('Error', 'Failed to load files: ' + (e.body?.message || e.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    get childRecordGroupsWithState() {
        return this.childRecordGroups.map((group) => ({
            ...group,
            pdfs: group.pdfs.map((pdf) => ({
                ...pdf,
                checked: this.selectedChildPdfCvIds.includes(pdf.value)
            }))
        }));
    }

    handleChildPdfCheckbox(event) {
        const cvId = event.target.dataset.cvid;
        if (event.target.checked) {
            this.selectedChildPdfCvIds = [...this.selectedChildPdfCvIds, cvId];
        } else {
            this.selectedChildPdfCvIds = this.selectedChildPdfCvIds.filter((id) => id !== cvId);
        }
    }

    // --- Core Logic ---

    /**
     * Main entry point for the Generate button. Auto-detects whether the dataset
     * qualifies as a Giant Query (>2000 child records) and routes accordingly.
     * For PDF output, launches async pipeline server-side.
     * For DOCX output, launches harvest batch then assembles client-side.
     * If not giant, falls through to normal generation.
     */
    async handleGenerate() {
        const selected = this._templateData.find((t) => t.Id === this.selectedTemplateId);
        const templateType = selected ? selected[TYPE_FIELD.fieldApiName] : 'Word';
        const isPPT = templateType === 'PowerPoint';
        const isExcel = templateType === 'Excel';
        const isWord = templateType === 'Word' && !isPPT && !isExcel;

        // Giant Query auto-detect: ALWAYS scout first before any generation
        this.isLoading = true;
        this.loadingMessage = 'Analyzing...';
        this.error = null;
        try {
            const scoutResult = await scoutChildCounts({
                recordId: this.recordId,
                templateId: this.selectedTemplateId
            });
            const counts = scoutResult.counts || {};
            const childNodes = scoutResult.childNodes || {};
            const useGiantPath = scoutResult.useGiantPath || {};

            // Heap-aware routing (v1.54.0+): server estimates peak sync-path heap per
            // relationship and flags useGiantPath[rel]=true if the estimate exceeds
            // the safe ratio of the 6MB sync heap limit. No hardcoded record threshold.
            const giantRel = Object.entries(counts).find(([rel]) => useGiantPath[rel]);
            if (giantRel) {
                this.isGiantQueryMode = true;
                this.outputMode = 'download';
                const isPdf = this.templateOutputFormat === 'PDF';
                if (isPdf) {
                    await this._assembleGiantQueryPdf(giantRel[0], counts, childNodes[giantRel[0]]);
                    return;
                }
                if (isWord) {
                    await this._assembleGiantQueryDocxClientSide(giantRel[0], counts, childNodes[giantRel[0]]);
                    return;
                }
                this.isLoading = false;
                this.loadingMessage = '';
                this.error =
                    `This record has ${giantRel[1].toLocaleString()} ${giantRel[0]} records — ` +
                    'too large for sync PowerPoint/Excel output. Please generate as DOCX (Word) or PDF.';
                return;
            }
            // Stash scout data so the sync fallback branch can auto-retry if processXml
            // detects heap pressure mid-flight and returns the heapPressure signal.
            this._scoutCache = { counts, childNodes };
        } catch (e) {
            // Scout failed — fall through to normal generation
            console.error('Portwood: SCOUT FAILED:', e.body ? e.body.message : e.message, e);
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
        }

        // Normal generation — scout confirmed <2000 children (or scout unavailable)
        await this.generateDocument();
    }

    async generateDocument() {
        this.isLoading = true;
        this.error = null;
        try {
            const selected = this._templateData.find((t) => t.Id === this.selectedTemplateId);
            const templateType = selected ? selected[TYPE_FIELD.fieldApiName] : 'Word';
            const isPPT = templateType === 'PowerPoint';
            const isExcel = templateType === 'Excel';
            const isPDF = this.effectiveOutputFormat === 'PDF' && !isPPT && !isExcel;
            const saveToRecord = this.wantsSaveToRecord;
            const shouldMerge = isPDF && this.mergeEnabled && this.selectedPdfCvIds.length > 0;

            if (isPDF) {
                // Pre-flight size check: attached images >30MB will fail the
                // Save-to-Record ContentVersion insert. Warn up front instead
                // of letting the Queueable fail silently.
                //
                // Gated on wantsSaveToRecord, NOT the save-only flag: Save &
                // Download ends in the same ContentVersion insert, so it needs the
                // same guard. Scoped to the non-merge branch because that is the
                // only one that reaches the insert from here.
                if (!shouldMerge && this.wantsSaveToRecord) {
                    const imgBytes = await scoutAttachedImageSize({ recordId: this.recordId });
                    const LIMIT_BYTES = 30 * 1024 * 1024;
                    if (imgBytes > LIMIT_BYTES) {
                        const mb = (imgBytes / 1024 / 1024).toFixed(1);
                        this.showToast(
                            'Cannot Save to Record',
                            `This record has ${mb} MB of attached images — above the 30 MB Save-to-Record limit. Use Download instead (no size limit), or remove some images and try again.`,
                            'error',
                            'sticky'
                        );
                        return;
                    }
                }
                if (shouldMerge) {
                    await this._generateMergedPdf();
                } else if (saveToRecord) {
                    // Save-to-record runs fully server-side via a Queueable so the full
                    // render + big-file DML never holds the Aura request open long enough
                    // to trip Salesforce's CSRF timeout (which returns an "Illegal Request"
                    // HTML page instead of the expected JSON). LWC gets back immediately.
                    //
                    // Save & Download keeps this async render — deliberately. Doing it
                    // synchronously to get the bytes back would reintroduce exactly the
                    // timeout this path exists to avoid, and on the biggest documents
                    // (the ones most likely to be worth both copies) it would also have
                    // to squeeze the file through the Aura response. Instead we let the
                    // Queueable finish, then point the BROWSER at the saved
                    // ContentVersion — the file streams from Salesforce's own file
                    // endpoint, so there is no size ceiling on either half.
                    const requestedAt = new Date().toISOString();
                    this.showToast('Info', 'Generating and saving PDF in the background...', 'info');
                    const jobId = await generatePdfAsync({
                        templateId: this.selectedTemplateId,
                        recordId: this.recordId
                    });

                    if (!this.wantsDownload) {
                        this.showToast(
                            'Success',
                            'PDF is being generated. It will appear on the record in a moment — refresh the page to see it.',
                            'success'
                        );
                        return;
                    }

                    this.loadingMessage = 'Saving to the record, then downloading...';
                    const saved = await this._waitForAsyncSavedPdf(jobId, requestedAt);
                    this._downloadSavedContentVersion(saved.contentVersionId);
                    this.showToast('Success', `${saved.title || 'PDF'} saved to record and downloaded.`, 'success');
                } else {
                    this.showToast('Info', 'Generating PDF...', 'info');
                    const chartContext = await this._prepareCharts();
                    let result;
                    try {
                        result = await generatePdf({
                            templateId: this.selectedTemplateId,
                            recordId: this.recordId,
                            saveToRecord: false,
                            chartCvMap: chartContext.map,
                            chartBucketMap: chartContext.bucketMap || null
                        });
                    } finally {
                        await this._cleanupCharts(chartContext.cvIds);
                    }
                    if (await this._handledHeapPressure(result)) {
                        return;
                    }
                    if (result.base64) {
                        // Download-only. Anything that saves — including Save &
                        // Download — took the async Queueable branch above.
                        await this._deliverGeneratedDocument({
                            base64: result.base64,
                            fileName: result.title || 'Document',
                            extension: 'pdf',
                            mimeType: 'application/pdf',
                            label: 'PDF'
                        });
                    }
                }
            } else {
                // Word DOCX / Excel XLSX / PowerPoint PPTX — client-side assembly.
                // PowerPoint uses the same browser ZIP writer so generated PPTX
                // packages avoid Apex Compression.ZipWriter container quirks.
                // Excel may still upgrade to .xlsm inside _generateOfficeClientSideInner —
                // macro-enabled detection needs the parts payload from the server.
                const ext = isPPT ? 'pptx' : isExcel ? 'xlsx' : 'docx';
                this.showToast('Info', 'Generating document...', 'info');
                await this._generateOfficeClientSide(ext, OFFICE_MIME_BY_EXT[ext]);
            }
        } catch (e) {
            this.error = 'Generation Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
        }
    }

    /**
     * In-flight heap-pressure fallback (v1.54.0+). When sync PDF generation returns
     * { heapPressure: true, giantRelationship: 'OpportunityLineItems' }, transparently
     * re-route to the giant-query batch path using scout data cached during handleGenerate.
     * Returns true if we handled the signal, false otherwise.
     */
    async _handledHeapPressure(result) {
        if (!result || !result.heapPressure) {
            return false;
        }
        if (!this._scoutCache) {
            this.error = 'Dataset exceeds sync heap limit — open the Command Hub and generate via the bulk pipeline.';
            return true;
        }
        const { counts, childNodes } = this._scoutCache;
        // If the server couldn't identify the giant relationship (e.g. Blob.toPdf
        // heap OOM — thrown from deep in the PDF engine, not our typed exception),
        // pick the relationship with the most records. It's almost always the one
        // blowing heap.
        let rel = result.giantRelationship;
        if (!rel) {
            let maxCount = 0;
            for (const [name, count] of Object.entries(counts || {})) {
                if (count > maxCount) {
                    maxCount = count;
                    rel = name;
                }
            }
        }
        if (!rel || !childNodes[rel]) {
            this.error = 'Dataset exceeds sync heap limit — open the Command Hub and generate via the bulk pipeline.';
            return true;
        }
        this.showToast('Info', `Large dataset — switching to giant-query mode for ${rel}.`, 'info');
        this.isGiantQueryMode = true;
        this.outputMode = 'download';
        await this._assembleGiantQueryPdf(rel, counts, childNodes[rel]);
        return true;
    }

    /**
     * #117 chart pipeline. Asks the controller for the SVG fragments needed
     * for this template/record combo, rasterizes each to PNG via the shared
     * docGenUtils helper, and uploads each PNG as a transient ContentVersion.
     * Returns {map, cvIds} — `map` is signature → CV Id (passed to the merge
     * call so the Word path can substitute charts with image tags), `cvIds`
     * is the list of CV IDs to reap once the merge finishes.
     *
     * Returns {map: {}, cvIds: []} for templates with no chart tags (no
     * server round-trip wasted — `prepareChartImages` returns empty for
     * non-Word templates and templates with no {Chart:...} tags).
     */
    /**
     * Rasterizes an SVG string to a base64 PNG via a hidden <canvas>. Inlined
     * here (rather than imported from c/docGenUtils) because LWC cross-bundle
     * compilation can serve a stale runner bundle when only the util's exports
     * change — observed as `TypeError: G.rasterizeSvgToPng is not a function`
     * even after a clean redeploy. Inlining the function avoids the
     * cross-bundle resolution path entirely.
     */
    _rasterizeSvgToPng(svgString, width, height, scale = 4) {
        return new Promise((resolve, reject) => {
            const blob = new Blob([svgString], { type: 'image/svg+xml' });
            const url = URL.createObjectURL(blob);
            const img = new Image();
            img.onload = () => {
                try {
                    const canvas = document.createElement('canvas');
                    canvas.width = width * scale;
                    canvas.height = height * scale;
                    const ctx = canvas.getContext('2d');
                    ctx.imageSmoothingEnabled = true;
                    ctx.imageSmoothingQuality = 'high';
                    ctx.fillStyle = '#ffffff';
                    ctx.fillRect(0, 0, canvas.width, canvas.height);
                    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                    URL.revokeObjectURL(url);
                    resolve(canvas.toDataURL('image/png').split(',')[1]);
                } catch (err) {
                    URL.revokeObjectURL(url);
                    reject(err);
                }
            };
            img.onerror = (err) => {
                URL.revokeObjectURL(url);
                reject(err instanceof Error ? err : new Error('SVG image load failed'));
            };
            img.src = url;
        });
    }

    /**
     * Loads Chart.js from the static resource once per component lifetime.
     * Static resource, not a CDN — the zero-callout constraint still holds.
     */
    async _ensureChartJs() {
        if (window.Chart) {
            return window.Chart;
        }
        await loadScript(this, CHARTJS_RESOURCE);
        return window.Chart;
    }

    /**
     * Chart.js path — buckets the child rows in the browser instead of Apex.
     *
     * Returns {map, cvIds} on success, or null to hand back to the Apex
     * rasterizer. Bailing (rather than half-rendering) keeps the two paths from
     * interleaving: a deck with one unsupported cross-tab chart renders entirely
     * server-side rather than as a mix of styles.
     *
     * The win over `prepareChartImages` is that Apex never sees the rows, so the
     * scout's `rows * 2000` heap estimate never trips and non-groupable fields
     * (long textareas) still chart. Rows are folded page-by-page and dropped, so
     * peak memory is O(distinct values) regardless of row count.
     */
    async _prepareChartsClientSide() {
        let ChartCtor;
        try {
            ChartCtor = await this._ensureChartJs();
        } catch (e) {
            console.warn('Portwood: Chart.js failed to load; using Apex chart path', e);
            return null;
        }
        if (!ChartCtor) {
            return null;
        }
        return prepareChartsClientSide({
            templateId: this.selectedTemplateId,
            recordId: this.recordId,
            ChartCtor,
            onProgress: (swept) => {
                this.loadingMessage = `Aggregating ${swept.toLocaleString()} rows...`;
            }
        });
    }

    async _prepareCharts() {
        // Chart.js first; it is the only path that survives large child sets and
        // non-groupable fields. Falls through to the Apex rasterizer when the
        // template uses a cross-tab style, when the resource fails to load, or
        // in any headless caller (Flow / batch), which never reaches this LWC.
        try {
            const clientResult = await this._prepareChartsClientSide();
            if (clientResult) {
                return clientResult;
            }
        } catch (e) {
            console.warn('Portwood: client-side chart path failed; using Apex chart path', e);
        }

        try {
            const requests = await prepareChartImages({
                templateId: this.selectedTemplateId,
                recordId: this.recordId
            });
            if (!Array.isArray(requests) || requests.length === 0) {
                return { map: {}, cvIds: [] };
            }
            const map = {};
            const cvIds = [];
            for (const req of requests) {
                try {
                    // eslint-disable-next-line no-await-in-loop
                    const pngBase64 = await this._rasterizeSvgToPng(req.svgString, req.width, req.height);
                    // eslint-disable-next-line no-await-in-loop
                    const cvId = await uploadChartImage({
                        recordId: this.recordId,
                        signature: req.signature,
                        base64Png: pngBase64
                    });
                    if (cvId) {
                        // Pack dimensions into the map value so the chart-tag
                        // expander can emit {%__dgchart_<cvId>:WxH}, constraining
                        // the embedded image to its nominal SVG size in Word.
                        // Otherwise Word renders the 4x-rasterized PNG at full
                        // pixel size and the chart fills the whole page.
                        map[req.signature] = cvId + '|' + req.width + 'x' + req.height;
                        cvIds.push(cvId);
                    }
                } catch (chartErr) {
                    // One bad chart shouldn't abort the whole generate — the
                    // tag will fall back to its text-placeholder branch.
                    const errMsg =
                        (chartErr && (chartErr.body ? chartErr.body.message : chartErr.message)) || String(chartErr);
                    console.warn(
                        'Portwood: chart prep failed for signature ' + req.signature + ' — ' + errMsg,
                        chartErr
                    );
                }
            }
            return { map, cvIds };
        } catch (e) {
            console.warn('Portwood: prepareChartImages failed; charts will render as text placeholders', e);
            return { map: {}, cvIds: [] };
        }
    }

    async _cleanupCharts(cvIds) {
        if (!Array.isArray(cvIds) || cvIds.length === 0) {
            return;
        }
        try {
            await deleteChartImages({ cvIds });
        } catch (cleanupErr) {
            // Cleanup failure is non-fatal — the cleanup schedulable (or
            // Salesforce's own CV recycle bin sweep) will catch these later.
            console.warn('Portwood: chart CV cleanup failed', cleanupErr);
        }
    }

    async handleGiantQuery() {
        this.isLoading = true;
        this.error = null;
        try {
            this.showToast('Info', 'Checking dataset size...', 'info');
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            const result = await generateDocumentGiantQuery({
                templateId: this.selectedTemplateId,
                recordId: this.recordId
            });
            if (result.isGiantQuery) {
                this.showToast(
                    'Success',
                    'Large dataset detected \u2014 generating asynchronously. Check Job History for progress.',
                    'success'
                );
            } else if (result.base64) {
                await this._deliverGeneratedDocument({
                    base64: result.base64,
                    fileName: result.title || 'Document',
                    extension: 'pdf',
                    mimeType: 'application/pdf',
                    label: 'PDF'
                });
            }
        } catch (e) {
            this.error = 'Giant Query Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
        }
    }

    async _generateMergedPdf() {
        const totalPdfs = this.selectedPdfCvIds.length + 1;
        this.showToast('Info', `Generating and merging ${totalPdfs} PDFs...`, 'info');
        const result = await generatePdf({
            templateId: this.selectedTemplateId,
            recordId: this.recordId,
            saveToRecord: false
        });
        if (!result || !result.base64) {
            throw new Error('Template PDF generation returned empty result.');
        }
        const docTitle = result.title || 'Document';
        const pdfBytesArray = [this._base64ToUint8Array(result.base64)];
        for (const cvId of this.selectedPdfCvIds) {
            const b64 = await getContentVersionBase64({ contentVersionId: cvId });
            if (b64) {
                pdfBytesArray.push(this._base64ToUint8Array(b64));
            }
        }
        const mergedBytes = mergePdfs(pdfBytesArray);
        const mergedBase64 = this._uint8ArrayToBase64(mergedBytes);
        await this._deliverGeneratedDocument({
            base64: mergedBase64,
            fileName: docTitle,
            extension: 'pdf',
            mimeType: 'application/pdf',
            byteLength: mergedBytes.length,
            label: 'Merged PDF'
        });
    }

    async generatePacket() {
        this.isLoading = true;
        this.error = null;
        try {
            const templateCount = this.packetTemplateIds.length;
            const existingCount = this.packetIncludeExisting ? this.packetExistingPdfIds.length : 0;
            this.showToast('Info', `Generating packet (${templateCount + existingCount} documents)...`, 'info');
            const pdfBytesArray = [];
            for (const templateId of this.packetTemplateIds) {
                const result = await generatePdf({ templateId, recordId: this.recordId, saveToRecord: false });
                if (result && result.base64) {
                    pdfBytesArray.push(this._base64ToUint8Array(result.base64));
                }
            }
            if (this.packetIncludeExisting && this.packetExistingPdfIds.length > 0) {
                for (const cvId of this.packetExistingPdfIds) {
                    const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                    if (b64) {
                        pdfBytesArray.push(this._base64ToUint8Array(b64));
                    }
                }
            }
            if (pdfBytesArray.length === 0) {
                throw new Error('No documents were generated.');
            }
            let finalBase64;
            if (pdfBytesArray.length === 1) {
                finalBase64 = this._uint8ArrayToBase64(pdfBytesArray[0]);
            } else {
                finalBase64 = this._uint8ArrayToBase64(mergePdfs(pdfBytesArray));
            }
            await this._deliverGeneratedDocument({
                base64: finalBase64,
                fileName: 'Document Packet',
                extension: 'pdf',
                mimeType: 'application/pdf',
                label: 'Document packet'
            });
        } catch (e) {
            this.error = 'Packet Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
        }
    }

    async mergeOnlyDocument() {
        this.isLoading = true;
        this.error = null;
        try {
            const count = this.mergeOnlyCvIds.length;
            this.showToast('Info', `Merging ${count} PDFs...`, 'info');
            const pdfBytesArray = [];
            for (const cvId of this.mergeOnlyCvIds) {
                const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                if (b64) {
                    pdfBytesArray.push(this._base64ToUint8Array(b64));
                }
            }
            if (pdfBytesArray.length < 2) {
                throw new Error('Need at least 2 PDFs to merge.');
            }
            const mergedBytes = mergePdfs(pdfBytesArray);
            const mergedBase64 = this._uint8ArrayToBase64(mergedBytes);
            await this._deliverGeneratedDocument({
                base64: mergedBase64,
                fileName: 'Merged Document',
                extension: 'pdf',
                mimeType: 'application/pdf',
                byteLength: mergedBytes.length,
                label: 'Merged PDF'
            });
        } catch (e) {
            this.error = 'Merge Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
        }
    }

    async mergeChildrenDocument() {
        this.isLoading = true;
        this.error = null;
        try {
            const count = this.selectedChildPdfCvIds.length;
            this.showToast('Info', `Merging ${count} PDFs from child records...`, 'info');
            const pdfBytesArray = [];
            for (const cvId of this.selectedChildPdfCvIds) {
                const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                if (b64) {
                    pdfBytesArray.push(this._base64ToUint8Array(b64));
                }
            }
            if (pdfBytesArray.length < 1) {
                throw new Error('No PDFs could be loaded.');
            }
            let finalBytes;
            if (pdfBytesArray.length === 1) {
                finalBytes = pdfBytesArray[0];
            } else {
                finalBytes = mergePdfs(pdfBytesArray);
            }
            const finalBase64 = this._uint8ArrayToBase64(finalBytes);
            await this._deliverGeneratedDocument({
                base64: finalBase64,
                fileName: 'Merged Child PDFs',
                extension: 'pdf',
                mimeType: 'application/pdf',
                byteLength: finalBytes.length,
                label: 'Merged PDF'
            });
        } catch (e) {
            this.error = 'Merge Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
        }
    }

    // --- Helpers ---

    resetState() {
        // Keep selectedTemplateId so it persists when switching back to generate mode
        this.selectedPdfCvIds = [];
        this.packetTemplateIds = [];
        this.mergeOnlyCvIds = [];
        this.selectedChildPdfCvIds = [];
        this.childPdfsLoaded = false;
    }

    /**
     * Client-side Office document assembly (DOCX or XLSX).
     * Server merges XML, client fetches images, assembles ZIP.
     * Note: Rich text images from rtaImage servlet URLs render in PDF only.
     * For DOCX images, use {%FieldName} tags with ContentVersion IDs.
     */
    async _generateOfficeClientSide(extension, mimeType) {
        // #117 chart pipeline: rasterize any {Chart:...} tags in the template
        // body to PNGs (uploaded as transient CVs) before kicking off the
        // server-side merge. The merge sees the signature → CV Id map and
        // substitutes each chart tag with the existing image-tag path.
        //
        // Cleanup MUST run after buildDocx finishes — the server returns
        // chart CV IDs in `imageCvIdMap`, and the client-side ZIP assembly
        // (below) fetches each CV's bytes via getContentVersionBase64. If
        // we delete the CVs in a tight try/finally around
        // generateDocumentParts, those fetches return empty and the DOCX
        // ships with no chart images. Hold the chartContext across the
        // whole flow and reap only after the document is fully assembled.
        const chartContext = await this._prepareCharts();
        try {
            await this._generateOfficeClientSideInner(extension, mimeType, chartContext);
        } finally {
            await this._cleanupCharts(chartContext.cvIds);
        }
    }

    async _generateOfficeClientSideInner(extension, mimeType, chartContext) {
        const parts = await generateDocumentParts({
            templateId: this.selectedTemplateId,
            recordId: this.recordId,
            chartCvMap: chartContext.map,
            chartBucketMap: chartContext.bucketMap || null
        });
        if (!parts || !parts.allXmlParts) {
            throw new Error('Document generation returned empty result.');
        }
        const docTitle = parts.title || 'Document';

        // Macro-enabled workbook: the server flags it from the template's content
        // types / vbaProject.bin part. Upgrade the extension so Excel opens the
        // file without stripping the VBA project.
        let resolvedExtension = extension;
        let resolvedMimeType = mimeType;
        if (extension === 'xlsx' && parts.isMacroEnabled) {
            resolvedExtension = 'xlsm';
            resolvedMimeType = OFFICE_MIME_BY_EXT.xlsm;
        }

        const allImages = { ...(parts.imageBase64Map || {}) };
        if (parts.imageCvIdMap) {
            const uniqueCvIds = new Map();
            for (const [mediaPath, cvId] of Object.entries(parts.imageCvIdMap)) {
                if (!uniqueCvIds.has(cvId)) {
                    uniqueCvIds.set(cvId, []);
                }
                uniqueCvIds.get(cvId).push(mediaPath);
            }
            for (const [cvId, mediaPaths] of uniqueCvIds) {
                try {
                    const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                    if (b64) {
                        for (const mp of mediaPaths) {
                            allImages[mp] = b64;
                        }
                    }
                } catch (imgErr) {
                    console.warn('Portwood: Failed to fetch image CV ' + cvId, imgErr);
                }
            }
        }
        // Lightning rich text inline images (0EM ContentReference) — only path:
        // server renders single-image PDF via Blob.toPdf (privileged URL resolver),
        // client extracts the embedded JPEG XObject. PDF is in-memory only.
        if (parts.imageUrlMap) {
            for (const [mediaPath, url] of Object.entries(parts.imageUrlMap)) {
                if (!/rtaImage/i.test(url)) continue;
                try {
                    // eslint-disable-next-line no-await-in-loop
                    const pdfB64 = await renderImageAsPdfBase64({ imageUrl: url });
                    if (!pdfB64) continue;
                    // eslint-disable-next-line no-await-in-loop
                    const extracted = await extractFirstImageFromPdfBase64(pdfB64);
                    if (extracted && extracted.base64) {
                        allImages[mediaPath] = extracted.base64;
                        if (extracted.width && extracted.height) {
                            this._updateDocxImageSizeIfNotExplicit(parts, mediaPath, extracted.width, extracted.height);
                        }
                    }
                } catch (urlErr) {
                    console.warn('Portwood: rich text image extract failed for ' + url, urlErr);
                }
            }
        }

        const fileBytes = buildDocx(parts.allXmlParts, allImages);
        const fileBase64 = this._uint8ArrayToBase64(fileBytes);
        // Apex can stitch chunked uploads up to ~5 MB binary into a single CV
        // before the 12 MB queueable heap (binary + base64 round-trip) OOMs.
        // Above 5 MB we download the file and surface a drag-to-attach
        // affordance instead — lightning-file-upload chunks internally up to
        // 2 GB, so the user does the upload themselves with platform-native
        // progress feedback. No new chunked Apex required.
        // The 5 MB ceiling and its drag-to-attach fallback now live in
        // _deliverGeneratedDocument, which every generation path shares.
        await this._deliverGeneratedDocument({
            base64: fileBase64,
            fileName: docTitle,
            extension: resolvedExtension,
            mimeType: resolvedMimeType,
            byteLength: fileBytes.length,
            label: resolvedExtension.toUpperCase()
        });
    }

    @track _oversizedSaveToRecord = null;

    get hasOversizedSaveToRecord() {
        return !!this._oversizedSaveToRecord;
    }

    /**
     * Pre-generation hint shown when the user has Save to Record selected
     * AND the run is going through the client-side DOCX/XLSX assembly path
     * (which has to round-trip the assembled bytes through Aura — capped at
     * ~5 MB). PDF generation is fully server-side, save-to-record happens
     * inline on the server, so there's no Aura ceiling to warn about.
     */
    get showSaveToRecordSizeHint() {
        // wantsSaveToRecord, not `=== 'save'` — Save & Download attaches to the record
        // too, so it hits the same Aura ceiling. Matters more now that it's the default.
        if (!this.wantsSaveToRecord) return false;
        return this.effectiveOutputFormat !== 'PDF';
    }

    handleOversizedDragUpload(event) {
        const uploaded = event.detail.files;
        if (uploaded && uploaded.length) {
            this.showToast('Attached', uploaded[0].name + ' attached to this record.', 'success');
        }
        this._oversizedSaveToRecord = null;
    }

    dismissOversizedSaveToRecord() {
        this._oversizedSaveToRecord = null;
    }

    /**
     * Polls a Giant Query harvest batch, fetches fragments, injects into the template
     * shell, and builds a DOCX ZIP entirely client-side. No heap limit.
     * @param {string} jobId - The DocGen_Job__c record ID
     * @param {string} giantRelationship - The child relationship name being harvested
     */
    async _assembleGiantQueryDocx(jobId, giantRelationship) {
        this.isLoading = true;
        this.error = null;
        try {
            // 1. Poll harvest batch until completed
            this.loadingMessage = 'Processing records...';
            let status = 'Harvesting';
            while (status !== 'Completed' && status !== 'Failed') {
                // eslint-disable-next-line no-await-in-loop
                await new Promise((resolve) => {
                    setTimeout(resolve, 3000);
                }); // NOSONAR — intentional poll delay
                // eslint-disable-next-line no-await-in-loop
                const jobStatus = await getGiantQueryJobStatus({ jobId });
                status = jobStatus.status;
                if (status === 'Failed') {
                    throw new Error('Giant Query harvest failed: ' + (jobStatus.label || 'Unknown error'));
                }
                const done = jobStatus.successCount || 0;
                const total = jobStatus.totalRecords || 0;
                if (total > 0) {
                    const batchesDone = done;
                    const totalBatches = Math.ceil(total / 50);
                    this.loadingMessage = `Processing ${total.toLocaleString()} records (batch ${batchesDone}/${totalBatches})...`;
                }
            }

            // 2. Get template shell with placeholder where giant loop goes
            this.loadingMessage = 'Preparing template...';
            const parts = await generateDocumentPartsGiantQuery({
                templateId: this.selectedTemplateId,
                recordId: this.recordId,
                giantRelationshipName: giantRelationship
            });
            if (!parts || !parts.allXmlParts) {
                throw new Error('Template parts generation returned empty result.');
            }
            const docTitle = parts.title || 'Document';
            const placeholder = parts.placeholder || '<!--DOCGEN_GIANT_LOOP_PLACEHOLDER-->';

            // 3. Fetch fragment CV IDs
            this.loadingMessage = 'Fetching fragments...';
            const fragResult = await getGiantQueryFragments({ jobId });
            const fragmentIds = fragResult.fragmentIds || [];

            // 4. Fetch each fragment and concatenate XML
            let allFragmentXml = '';
            for (let i = 0; i < fragmentIds.length; i++) {
                this.loadingMessage = `Assembling document (fragment ${i + 1}/${fragmentIds.length})...`;
                // eslint-disable-next-line no-await-in-loop
                const fragB64 = await getContentVersionBase64({ contentVersionId: fragmentIds[i] });
                if (fragB64) {
                    // Decode base64 to string (fragment is UTF-8 XML text)
                    allFragmentXml += atob(fragB64);
                }
            }

            // 5. Inject fragment XML into the template at the placeholder position
            const docXmlKey = 'word/document.xml';
            if (parts.allXmlParts[docXmlKey]) {
                parts.allXmlParts[docXmlKey] = parts.allXmlParts[docXmlKey].replace(placeholder, allFragmentXml);
            }

            // 6. Fetch images (same logic as _generateOfficeClientSide)
            this.loadingMessage = 'Fetching images...';
            const allImages = { ...(parts.imageBase64Map || {}) };
            if (parts.imageCvIdMap) {
                const uniqueCvIds = new Map();
                for (const [mediaPath, cvId] of Object.entries(parts.imageCvIdMap)) {
                    if (!uniqueCvIds.has(cvId)) {
                        uniqueCvIds.set(cvId, []);
                    }
                    uniqueCvIds.get(cvId).push(mediaPath);
                }
                for (const [cvId, mediaPaths] of uniqueCvIds) {
                    try {
                        // eslint-disable-next-line no-await-in-loop
                        const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                        if (b64) {
                            for (const mp of mediaPaths) {
                                allImages[mp] = b64;
                            }
                        }
                    } catch (imgErr) {
                        console.warn('Portwood: Failed to fetch image CV ' + cvId, imgErr);
                    }
                }
            }
            if (parts.imageUrlMap) {
                for (const [mediaPath, url] of Object.entries(parts.imageUrlMap)) {
                    if (!/rtaImage/i.test(url)) continue;
                    try {
                        // eslint-disable-next-line no-await-in-loop
                        const pdfB64 = await renderImageAsPdfBase64({ imageUrl: url });
                        if (!pdfB64) continue;
                        // eslint-disable-next-line no-await-in-loop
                        const extracted = await extractFirstImageFromPdfBase64(pdfB64);
                        if (extracted && extracted.base64) {
                            allImages[mediaPath] = extracted.base64;
                            // wp:extent rewrite temporarily disabled — was breaking
                            // image rendering in Word. Re-enable once root cause known.
                            // if (extracted.width && extracted.height) {
                            //     this._updateDocxImageSizeIfNotExplicit(parts, mediaPath, extracted.width, extracted.height);
                            // }
                        }
                    } catch (urlErr) {
                        console.warn('Portwood: rich text image extract failed for ' + url, urlErr);
                    }
                }
            }

            // 7. Build DOCX ZIP
            this.loadingMessage = 'Building DOCX...';
            const fileBytes = buildDocx(parts.allXmlParts, allImages);
            const fileBase64 = this._uint8ArrayToBase64(fileBytes);

            // 8. Download or save (5 MB single-CV stitch ceiling — see _generateOfficeClientSide)
            await this._deliverGeneratedDocument({
                base64: fileBase64,
                fileName: docTitle,
                extension: 'docx',
                mimeType: 'application/octet-stream',
                byteLength: fileBytes.length,
                label: 'DOCX'
            });

            // 9. Clean up fragment CVs server-side
            try {
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                await cleanupGiantQueryFragments({ jobId });
            } catch (cleanupErr) {
                console.warn('Portwood: Fragment cleanup failed (non-fatal)', cleanupErr);
            }
        } catch (e) {
            this.error = 'Giant Query DOCX Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
        }
    }

    /**
     * Pure client-side Giant Query DOCX assembly.
     * No server-side batch, no fragment CVs — queries child records page by page
     * via getChildRecordPage (2,000 rows per call), renders XML in JS, builds DOCX.
     */
    async _assembleGiantQueryDocxClientSide(giantRelationship, childCounts, serverChildNode) {
        this.isLoading = true;
        this.error = null;
        try {
            const totalRecords = childCounts ? childCounts[giantRelationship] || 0 : 0;

            // 1. Get template shell with placeholder
            this.loadingMessage = 'Preparing template...';
            const parts = await generateDocumentPartsGiantQuery({
                templateId: this.selectedTemplateId,
                recordId: this.recordId,
                giantRelationshipName: giantRelationship
            });
            if (!parts || !parts.allXmlParts) {
                throw new Error('Template parts generation returned empty result.');
            }

            const docTitle = parts.title || 'Document';
            const placeholder = parts.placeholder || '<!--DOCGEN_GIANT_LOOP_PLACEHOLDER-->';

            // 2. Use server-resolved child node metadata (works for V1, V2, V3)
            if (!serverChildNode) {
                throw new Error('Could not find child node configuration for ' + giantRelationship);
            }

            const childObject = serverChildNode.object;
            const lookupField = serverChildNode.lookupField;
            const childFields = serverChildNode.fields || [];
            const parentFields = serverChildNode.parentFields || [];
            const allFields = ['Id', ...childFields.filter((f) => f !== 'Id'), ...parentFields].join(', ');

            // 3. Get the loop body XML from the template (extracted by generateDocumentPartsGiantQuery)
            const innerXml = parts.giantLoopBodyXml || '';
            if (!innerXml) {
                throw new Error('Could not extract loop body XML from template for ' + giantRelationship);
            }

            // 4. Page through child records and render XML client-side
            const orderBy = serverChildNode.orderBy || '';
            const whereClause = serverChildNode.where || '';
            let allRenderedXml = '';
            let fetched = 0;
            const pageSize = 500;

            if (orderBy) {
                // Sorted path: pre-query all IDs in sort order, then fetch by chunk
                this.loadingMessage = 'Sorting records...';
                const sortedIds = await getSortedChildIds({
                    childObject,
                    lookupField,
                    parentId: this.recordId,
                    orderByClause: orderBy,
                    whereClause: whereClause || null
                });

                for (let i = 0; i < sortedIds.length; i += pageSize) {
                    const chunk = sortedIds.slice(i, i + pageSize);
                    this.loadingMessage = `Loading records (${fetched.toLocaleString()} / ${totalRecords.toLocaleString()})...`;

                    // eslint-disable-next-line no-await-in-loop
                    const records = await getChildRecordsByIds({
                        childObject,
                        fields: allFields,
                        recordIds: chunk
                    });

                    fetched += records.length;
                    this._renderGiantDocxRows(records, innerXml, childFields, parentFields, (xml) => {
                        allRenderedXml += xml;
                    });

                    this.progressPercent = Math.round((fetched / totalRecords) * 80);
                }
            } else {
                // Unsorted cursor path (original behavior)
                let lastCursorId = null;
                let hasMore = true;

                while (hasMore) {
                    this.loadingMessage = `Loading records (${fetched.toLocaleString()} / ${totalRecords.toLocaleString()})...`;

                    // eslint-disable-next-line no-await-in-loop
                    const page = await getChildRecordPage({
                        childObject,
                        lookupField,
                        parentId: this.recordId,
                        lastCursorId,
                        fields: allFields,
                        pageSize
                    });

                    const records = page.records || [];
                    lastCursorId = page.lastId;
                    hasMore = page.hasMore;
                    fetched += records.length;

                    this._renderGiantDocxRows(records, innerXml, childFields, parentFields, (xml) => {
                        allRenderedXml += xml;
                    });

                    this.progressPercent = Math.round((fetched / totalRecords) * 80);
                }
            }

            this.loadingMessage = `Loaded ${fetched.toLocaleString()} records. Building document...`;

            // 5. Inject rendered XML into template at placeholder
            const docXmlKey = 'word/document.xml';
            if (parts.allXmlParts[docXmlKey]) {
                parts.allXmlParts[docXmlKey] = parts.allXmlParts[docXmlKey].replace(placeholder, allRenderedXml);
            }
            allRenderedXml = null; // free memory

            // 6. Fetch images
            this.loadingMessage = 'Fetching images...';
            const allImages = { ...(parts.imageBase64Map || {}) };
            if (parts.imageCvIdMap) {
                const uniqueCvIds = new Map();
                for (const [mediaPath, cvId] of Object.entries(parts.imageCvIdMap)) {
                    if (!uniqueCvIds.has(cvId)) {
                        uniqueCvIds.set(cvId, []);
                    }
                    uniqueCvIds.get(cvId).push(mediaPath);
                }
                for (const [cvId, mediaPaths] of uniqueCvIds) {
                    try {
                        // eslint-disable-next-line no-await-in-loop
                        const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                        if (b64) {
                            for (const mp of mediaPaths) {
                                allImages[mp] = b64;
                            }
                        }
                    } catch (imgErr) {
                        console.warn('Portwood: Failed to fetch image CV ' + cvId, imgErr);
                    }
                }
            }
            if (parts.imageUrlMap) {
                for (const [mediaPath, url] of Object.entries(parts.imageUrlMap)) {
                    if (!/rtaImage/i.test(url)) continue;
                    try {
                        // eslint-disable-next-line no-await-in-loop
                        const pdfB64 = await renderImageAsPdfBase64({ imageUrl: url });
                        if (!pdfB64) continue;
                        // eslint-disable-next-line no-await-in-loop
                        const extracted = await extractFirstImageFromPdfBase64(pdfB64);
                        if (extracted && extracted.base64) {
                            allImages[mediaPath] = extracted.base64;
                            // wp:extent rewrite temporarily disabled — was breaking
                            // image rendering in Word. Re-enable once root cause known.
                            // if (extracted.width && extracted.height) {
                            //     this._updateDocxImageSizeIfNotExplicit(parts, mediaPath, extracted.width, extracted.height);
                            // }
                        }
                    } catch (urlErr) {
                        console.warn('Portwood: rich text image extract failed for ' + url, urlErr);
                    }
                }
            }

            // 7. Build DOCX ZIP
            this.loadingMessage = 'Building DOCX...';
            const fileBytes = buildDocx(parts.allXmlParts, allImages);
            const fileBase64 = this._uint8ArrayToBase64(fileBytes);

            // 8. Giant Query always downloads — file size exceeds Aura 4MB payload limit
            const fileSizeMB = ((fileBase64.length * 0.75) / 1048576).toFixed(1);
            this.downloadBase64(fileBase64, docTitle + '.docx', 'application/octet-stream');
            this.showToast(
                'Success',
                `DOCX downloaded (${fileSizeMB}MB) — ${fetched.toLocaleString()} ${giantRelationship} rows.`,
                'success'
            );
        } catch (e) {
            this.error = 'Giant Query Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
            this.isGiantQueryMode = false;
        }
    }

    /**
     * Giant Query PDF: launches server batch that renders XML fragments, then
     * assembles into a single PDF server-side via Blob.toPdf() in finish().
     * Client just polls, fetches the final PDF, and downloads.
     * @param {string} giantRelationship - The child relationship name
     * @param {Object} childCounts - Map of relationship name to record count
     * @param {Object} childNodeConfig - Child node config from scout
     */
    /**
     * Renders DOCX XML rows for a batch of records. Used by both sorted and
     * cursor-based Giant Query DOCX assembly paths.
     */
    _renderGiantDocxRows(records, innerXml, childFields, parentFields, appendFn) {
        for (const rec of records) {
            let rowXml = innerXml;
            for (const field of [...childFields, ...parentFields]) {
                let value = '';
                if (field.includes('.')) {
                    const fieldParts = field.split('.');
                    let current = rec;
                    for (let i = 0; i < fieldParts.length && current; i++) {
                        current = current[fieldParts[i]];
                    }
                    value = current != null ? String(current) : '';
                } else {
                    value = rec[field] != null ? String(rec[field]) : '';
                }
                const escaped = value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                rowXml = rowXml.split('{' + field + '}').join(escaped);
                rowXml = rowXml.split('{*' + field + '}').join(escaped);
                rowXml = rowXml.split('{%QR:' + field + '}').join(escaped);
                rowXml = rowXml.split('{%BARCODE:' + field + '}').join(escaped);
                rowXml = rowXml.split('{%' + field + '}').join(escaped);
            }
            rowXml = rowXml.replace(/\{(\w[\w.]*?)(?::([^}]+))?\}/g, (match, fieldName, format) => {
                let val = rec[fieldName];
                if (fieldName.includes('.')) {
                    const parts = fieldName.split('.');
                    let cur = rec;
                    for (let i = 0; i < parts.length && cur; i++) {
                        cur = cur[parts[i]];
                    }
                    val = cur;
                }
                if (val == null) return '';
                if (format === 'currency' && typeof val === 'number') {
                    return val.toLocaleString('en-US', { style: 'currency', currency: 'USD' });
                }
                if (format === 'number' && typeof val === 'number') {
                    return val.toLocaleString();
                }
                return String(val).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            });
            appendFn(rowXml);
        }
    }

    async _assembleGiantQueryPdf(giantRelationship, childCounts, childNodeConfig) {
        this.isLoading = true;
        this.error = null;
        try {
            const totalRecords = childCounts ? childCounts[giantRelationship] || 0 : 0;

            if (!childNodeConfig) {
                throw new Error('Child node configuration not available for ' + giantRelationship);
            }

            // 1. Launch batch
            this.showProgressBar = true;
            this.progressPercent = 0;
            this.loadingMessage = 'Starting PDF generation...';
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            const giantResult = await launchGiantQueryPdfBatch({
                templateId: this.selectedTemplateId,
                recordId: this.recordId,
                giantRelationship,
                childNodeConfigJson: JSON.stringify(childNodeConfig)
            });
            if (!giantResult.isGiantQuery || !giantResult.jobId) {
                throw new Error('Giant Query batch failed to launch.');
            }
            const jobId = giantResult.jobId;

            // 2. Poll until completed — server assembles the final PDF in finish()
            this.loadingMessage = `Processing ${totalRecords.toLocaleString()} records... Do not leave this page.`;
            let status = 'Harvesting';
            while (status !== 'Completed' && status !== 'Failed') {
                // eslint-disable-next-line no-await-in-loop
                await new Promise((resolve) => {
                    setTimeout(resolve, 3000);
                }); // NOSONAR — intentional poll delay
                // eslint-disable-next-line no-await-in-loop
                const jobStatus = await getGiantQueryJobStatus({ jobId });
                status = jobStatus.status;
                if (status === 'Failed') {
                    throw new Error('PDF generation failed: ' + (jobStatus.label || 'Unknown error'));
                }
                const done = jobStatus.successCount || 0;
                const total = jobStatus.totalRecords || 0;
                if (total > 0) {
                    const totalBatches = Math.ceil(total / 50);
                    this.progressPercent = Math.min(95, Math.round((done / totalBatches) * 95));
                    this.loadingMessage = `Generating PDF (batch ${done}/${totalBatches})... Do not leave this page.`;
                }
            }

            // 3. Fetch result — single part is saved to record, multiple parts need client merge
            this.progressPercent = 97;
            this.loadingMessage = 'Finalizing PDF... Do not leave this page.';
            const fragResult = await getGiantQueryFragments({ jobId });
            const finalCvId = fragResult.finalPdfCvId;
            const partIds = fragResult.partPdfCvIds || [];

            if (finalCvId) {
                // Single PDF. The batch always saves it to the record — but the
                // runner forced outputMode='download' at the routing decision,
                // so we ALSO need to trigger a browser download here. Fetch
                // the bytes and hand them to downloadBase64. Leave the record
                // CV in place so refreshing-the-page-and-coming-back finds the
                // result; ~zero harm in having both copies for the user.
                this.progressPercent = 100;
                try {
                    const finalB64 = await getContentVersionBase64({ contentVersionId: finalCvId });
                    if (finalB64) {
                        const docTitle = (fragResult && fragResult.docTitle) || 'Document';
                        this.downloadBase64(finalB64, docTitle + '.pdf', 'application/pdf');
                    }
                } catch (dlErr) {
                    // Download failure is non-fatal — the PDF is still on the
                    // record's Files tab so the user can retrieve it manually.
                    console.warn('Portwood: giant PDF download fetch failed', dlErr);
                }
                this.showToast(
                    'Success',
                    `PDF downloaded and saved to record — ${totalRecords.toLocaleString()} ${giantRelationship} rows.`,
                    'success'
                );
            } else if (partIds.length > 0) {
                // Multiple parts — fetch and merge client-side
                const pdfParts = [];
                for (let i = 0; i < partIds.length; i++) {
                    this.loadingMessage = `Merging PDF parts (${i + 1}/${partIds.length})... Do not leave this page.`;
                    // eslint-disable-next-line no-await-in-loop
                    const partB64 = await getContentVersionBase64({ contentVersionId: partIds[i] });
                    if (partB64) {
                        pdfParts.push(this._base64ToUint8Array(partB64));
                    }
                }
                this.loadingMessage = 'Assembling final PDF...';
                const mergedPdf = mergePdfs(pdfParts);
                const mergedBase64 = this._uint8ArrayToBase64(mergedPdf);
                const fileSizeMB = ((mergedBase64.length * 0.75) / 1048576).toFixed(1);
                // v1.90 — use the Document_Title_Format__c title from the
                // server so the download filename matches the saved-to-record
                // CV name instead of a generic 'Document.pdf'.
                const docTitle = (fragResult && fragResult.docTitle) || 'Document';
                this.downloadBase64(mergedBase64, docTitle + '.pdf', 'application/pdf');
                this.progressPercent = 100;
                this.showToast(
                    'Success',
                    `PDF downloaded (${fileSizeMB}MB) — ${totalRecords.toLocaleString()} ${giantRelationship} rows.`,
                    'success'
                );
                // Clean up parts
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                try {
                    await cleanupGiantQueryFragments({ jobId });
                } catch (cleanupErr) {
                    console.warn('Cleanup:', cleanupErr);
                }
            } else {
                throw new Error('PDF generation completed but no output found.');
            }
        } catch (e) {
            this.error = 'Giant Query PDF Error: ' + (e.body ? e.body.message : e.message || 'Unknown error');
        } finally {
            this.isLoading = false;
            this.loadingMessage = '';
            this.isGiantQueryMode = false;
            this.showProgressBar = false;
            this.progressPercent = 0;
        }
    }

    _base64ToUint8Array(base64) {
        const binaryStr = atob(base64);
        const bytes = new Uint8Array(binaryStr.length);
        for (let i = 0; i < binaryStr.length; i++) {
            bytes[i] = binaryStr.charCodeAt(i);
        }
        return bytes;
    }

    _uint8ArrayToBase64(bytes) {
        let binary = '';
        for (let i = 0; i < bytes.length; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    }

    /**
     * Updates the wp:extent values in document.xml for an image whose native
     * dimensions weren't known at server-merge time. Only applies when the
     * server didn't mark the drawing with descr="DOCGEN_EXPLICIT_SIZE" — i.e.
     * the user didn't set width/height in the rich text. We derive the relId
     * from the rels XML by media filename, then find the matching <a:blip
     * r:embed="..."/> in document.xml and rewrite its enclosing <wp:extent>
     * (and the inner <a:ext> on <pic:spPr>) to native pixel dimensions in EMU.
     */
    _updateDocxImageSizeIfNotExplicit(parts, mediaPath, widthPx, heightPx) {
        if (!parts || !parts.allXmlParts) return;
        const docXml = parts.allXmlParts['word/document.xml'];
        const relsXml = parts.allXmlParts['word/_rels/document.xml.rels'];
        if (!docXml || !relsXml) return;

        // mediaPath like "word/media/docgen_image_1.png" → look up rels Target
        const targetName = mediaPath.replace(/^word\//, ''); // "media/docgen_image_1.png"
        const relMatch = relsXml.match(
            new RegExp(
                '<Relationship\\s+Id="([^"]+)"[^>]*?Target="' + targetName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '"',
                'i'
            )
        );
        if (!relMatch) return;
        const relId = relMatch[1];

        // Find <a:blip r:embed="relId"/> in doc XML, then walk back to enclosing <w:drawing>
        const blipIdx = docXml.indexOf('r:embed="' + relId + '"');
        if (blipIdx === -1) return;
        const drawStart = docXml.lastIndexOf('<w:drawing', blipIdx);
        const drawEnd = docXml.indexOf('</w:drawing>', blipIdx);
        if (drawStart === -1 || drawEnd === -1) return;

        const drawingXml = docXml.substring(drawStart, drawEnd + '</w:drawing>'.length);
        // If server marked this as explicit-size, leave it alone
        if (drawingXml.indexOf('DOCGEN_EXPLICIT_SIZE') !== -1) return;

        const cxEmu = widthPx * 9525;
        const cyEmu = heightPx * 9525;
        let updated = drawingXml.replace(
            /<wp:extent\s+cx="\d+"\s+cy="\d+"\s*\/>/,
            '<wp:extent cx="' + cxEmu + '" cy="' + cyEmu + '"/>'
        );
        updated = updated.replace(
            /<a:ext\s+cx="\d+"\s+cy="\d+"\s*\/>/,
            '<a:ext cx="' + cxEmu + '" cy="' + cyEmu + '"/>'
        );
        if (updated !== drawingXml) {
            parts.allXmlParts['word/document.xml'] =
                docXml.substring(0, drawStart) + updated + docXml.substring(drawEnd + '</w:drawing>'.length);
        }
    }

    downloadBase64(base64Data, fileName, mimeType) {
        downloadBase64Util(base64Data, fileName, mimeType);
    }

    showToast(title, message, variant, mode) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}
