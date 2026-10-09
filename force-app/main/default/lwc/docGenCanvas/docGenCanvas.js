import { LightningElement, api, track } from 'lwc';
import getHtmlTemplateBody from '@salesforce/apex/DocGenController.getHtmlTemplateBody';
import saveAndPublishHtmlBody from '@salesforce/apex/DocGenController.saveAndPublishHtmlBody';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import getTemplateVersions from '@salesforce/apex/DocGenController.getTemplateVersions';
import getVersionBody from '@salesforce/apex/DocGenController.getVersionBody';
import getAssets from '@salesforce/apex/DocGenController.getAssets';
import activateVersion from '@salesforce/apex/DocGenController.activateVersion';
import { extractQueryShape } from 'c/docGenAuthoringKit';
import { loadScript } from 'lightning/platformResourceLoader';
import CHARTJS_RESOURCE from '@salesforce/resourceUrl/DocGenChartJs';
import { renderChartToCanvas, SAMPLE_CHART_BUCKETS, prepareChartsClientSide } from 'c/docGenChartJs';
import { updateRecord } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import ID_FIELD from '@salesforce/schema/DocGen_Template__c.Id';
import QUERY_FIELD from '@salesforce/schema/DocGen_Template__c.Query_Config__c';
import TEST_RECORD_FIELD from '@salesforce/schema/DocGen_Template__c.Test_Record_Id__c';
import {
    blankDocument,
    newTextBox,
    newArtboard,
    cloneArtboard,
    pageGeometry,
    serialize,
    deserialize,
    clampBox,
    inToPx,
    pxToIn,
    FONT_CHOICES,
    DEFAULT_STYLE,
    GRID_STYLES,
    SAFE_SYMBOLS,
    symbolMarkup,
    newTableBox,
    tablePreviewHtml,
    snapBox,
    suggestTotals,
    buildQueryConfig,
    sanitizeInline,
    newImageBox,
    newShapeBox,
    SHAPE_CHOICES,
    PAGE_SIZES,
    DEFAULT_MARGINS,
    normalizeMargins,
    DEFAULT_CUSTOM_PAGE,
    normalizeCustomPage,
    newCodeBox,
    codeBoxSize,
    CODE_TYPES,
    CHART_STYLES,
    chartConfigIssue,
    newSignatureBox,
    newChartBox,
    signatureBoxSize,
    SIGNATURE_TYPES,
    htmlToCanvas,
    buildAnchorGroups,
    anchorRoot,
    wouldCycle,
    boxLabel,
    normalizeCustomPage as normalizeCustom,
    canRenderBold
} from './canvasModel';

/**
 * Arial Unicode MS has no bold face in the PDF engine (Blob.toPdf), so a bold this font
 * carries silently prints regular. The canvas disables the Bold control for it, so
 * authoring and output agree.
 *
 * Derived from canvasModel's canRenderBold rather than restating it. This began as a
 * second copy of the rule with a comment asking future editors to keep the two as exact
 * inverses — which is how layerLabel came to disagree with boxLabel in this same file,
 * silently, for as long as it took someone to notice a name showing up in three places
 * out of four. One function decides; this reads it.
 */
function isUnicodeFont(font) {
    return !canRenderBold(font);
}

/**
 * Canvas editor — a Canva-style artboard for Portwood's Canvas template type.
 *
 * DELIBERATELY NET NEW, not a mode inside docGenAdmin. That component is ~15k lines
 * built on treating a contenteditable DOM as the document, which is what produced the
 * Lightning Web Security bug class (missing replaceWith, cloneNode dropping nodes)
 * that only reproduces in a namespaced install. Here the scene graph in canvasModel is
 * the document and the DOM is a disposable projection of it, so there is nothing to
 * read back and nothing for LWS to distort.
 *
 * SLICE ONE: place, move, resize and type into text boxes; save; reload. No formatting
 * panel, no images, no merge-tag rail yet — those hang off the same model once the
 * geometry is trustworthy. The one thing that must be exactly right first is that a
 * box at 2.4in x 3.1in on screen is at 2.4in x 3.1in in the PDF.
 */
export default class DocGenCanvas extends LightningElement {
    @api recordId;

    /**
     * Reloads whenever the template changes.
     *
     * The canvas element STAYS MOUNTED when you open a different template — only this
     * property changes — so connectedCallback never fires again. With the load gated by
     * a one-shot flag, the editor went on showing the previous template's document, and
     * saving from there would have written that layout onto the new template.
     */
    @api
    get templateId() {
        return this._templateId;
    }
    set templateId(value) {
        if (value === this._templateId) {
            return;
        }
        this._templateId = value;
        this.resetForTemplate();
    }
    /**
     * Accepted for API compatibility, but NOT what the canvas draws.
     *
     * These carry the template RECORD's page fields. For a Canvas template the body's
     * own @page rule is the source of truth — the engine defers to a source @page
     * (v1.90) — so letting the record drive the editor gave two answers to one
     * question, and a brand-new canvas opened on whatever the record happened to say
     * rather than on a clean page. Writing back to them from inside was its own hazard:
     * a parent re-render would overwrite whatever had been read out of the saved @page.
     */
    @api pageSize = 'Letter';
    @api orientation = 'Portrait';

    // What the canvas actually uses. A NEW canvas is Letter, portrait, no margins —
    // the page and the artboard then coincide, so a box at 0,0 is at the paper corner.
    @track canvasPageSize = 'Letter';
    @track canvasOrientation = 'Portrait';
    @api queryConfig;
    @api baseObject;
    @api sampleRecordId;

    @track doc = blankDocument();
    @track selectedId = null;
    @track zoom = 1;
    @track activeTool = 'select';

    // Live Chart.js instances keyed by box id. Chart.js registers per canvas, so
    // an instance must be destroyed before its box is repainted or the registry
    // leaks and every later render slows down.
    _chartInstances = new Map();
    @track isSaving = false;
    @track statusText = '';
    // Alignment guides for the box being dragged. Cleared on mouseup.
    @track guides = [];
    @track previewUrl = null;
    @track isPreviewing = false;
    @track queryDraft = null;
    @track saveError = null;
    @track versions = [];
    @track activeVersionId = null;
    // Page setup lives on the component, is serialized into @page, and is read back on
    // load — the canvas owns its own page. The engine defers to a source @page rule
    // (v1.90), so what is set here is what the PDF uses.
    @track margins = { ...DEFAULT_MARGINS };
    @track customPage = { ...DEFAULT_CUSTOM_PAGE };
    @track imageLibrary = [];
    @track imageLoading = false;
    _assetsPromise = null;
    @track _showPageSetup = false;

    _loaded = false;
    _templateId = null;
    _connected = false;
    // The document as STORED, so unsaved-change detection compares like with like.
    _savedHtml = null;
    // Live drag state. Kept off @track on purpose: it changes on every mousemove and
    // re-rendering the whole board 60 times a second would make dragging feel awful.
    _drag = null;

    get geo() {
        return pageGeometry(this.canvasPageSize, this.canvasOrientation, this.margins, this.customPage);
    }

    get isCustomPage() {
        return this.canvasPageSize === 'Custom';
    }

    get customPageW() {
        return this.customPage.w;
    }

    get customPageH() {
        return this.customPage.h;
    }

    handleCustomPageChange(event) {
        this.pushHistory('page');
        const key = event.currentTarget.dataset.key;
        this.customPage = normalizeCustomPage({ ...this.customPage, [key]: event.target.value });
        this.reflowToPage();
    }

    // ---- Page setup ------------------------------------------------------
    get pageSizeOptions() {
        return PAGE_SIZES;
    }

    get orientationOptions() {
        return [
            { label: 'Portrait', value: 'Portrait' },
            { label: 'Landscape', value: 'Landscape' }
        ];
    }

    get pageAreaLabel() {
        const m = this.margins;
        const zero = !m.top && !m.right && !m.bottom && !m.left;
        return (
            this.geo.w.toFixed(2) +
            'in x ' +
            this.geo.h.toFixed(2) +
            'in of usable page' +
            (zero ? ' — the canvas is the whole page, so what you place is exactly where it prints' : '')
        );
    }

    get marginTop() {
        return this.margins.top;
    }
    get marginRight() {
        return this.margins.right;
    }
    get marginBottom() {
        return this.margins.bottom;
    }
    get marginLeft() {
        return this.margins.left;
    }

    handlePageSizeChange(event) {
        this.pushHistory('page');
        this.canvasPageSize = event.detail.value;
        this.reflowToPage();
    }

    handleOrientationChange(event) {
        this.pushHistory('page');
        this.canvasOrientation = event.detail.value;
        this.reflowToPage();
    }

    handleMarginChange(event) {
        this.pushHistory('page');
        const key = event.currentTarget.dataset.key;
        this.margins = normalizeMargins({ ...this.margins, [key]: event.target.value });
        this.reflowToPage();
    }

    handleMarginZero() {
        this.pushHistory('page');
        this.margins = normalizeMargins({ top: 0, right: 0, bottom: 0, left: 0 });
        this.reflowToPage();
    }

    handleMarginPreset(event) {
        this.pushHistory('page');
        const v = event.currentTarget.dataset.all;
        this.margins = normalizeMargins({ top: v, right: v, bottom: v, left: v });
        this.reflowToPage();
    }

    get showPageSetup() {
        return this._showPageSetup === true;
    }

    handleTogglePageSetup() {
        this._showPageSetup = !this._showPageSetup;
    }

    handleClosePageSetup() {
        this._showPageSetup = false;
    }

    /**
     * Shrinking the page must not silently push boxes off it. Every box is re-clamped
     * to the new content area, so a layout authored on Letter and switched to A4 stays
     * entirely on the page — moved, but never lost past the edge where the author
     * cannot select it to move it back.
     */
    reflowToPage() {
        const geo = this.geo;
        // Not pushed here — the page handlers snapshot BEFORE changing the setting, so
        // undo restores the old page as well as the box positions it moved.
        this.doc = {
            ...this.doc,
            artboards: this.doc.artboards.map((b) => ({
                ...b,
                boxes: b.boxes.map((x) => clampBox(x, geo))
            }))
        };
        this.statusText = 'Page set to ' + this.canvasPageSize + ' ' + this.canvasOrientation.toLowerCase();
    }

    /**
     * The paper around the artboard.
     *
     * The artboard IS the printable area — margins are subtracted from it — so a box
     * can never sit in a margin. What was missing was any sign of the paper: with a
     * 1in margin the author saw a 6.5in canvas and no indication that the sheet is
     * 8.5in, or how much of it the margins were eating.
     */
    get paperStyle() {
        const m = this.margins;
        const z = this.zoom;
        return (
            'padding:' +
            inToPx(m.top, z) +
            'px ' +
            inToPx(m.right, z) +
            'px ' +
            inToPx(m.bottom, z) +
            'px ' +
            inToPx(m.left, z) +
            'px;'
        );
    }

    /**
     * The record Preview renders from.
     *
     * Held separately from the @api input rather than written back onto it: a parent
     * re-render would overwrite the choice, which is the same trap the page-setup
     * fields fell into.
     */
    @track _sampleOverride = null;

    get effectiveSampleRecordId() {
        return this._sampleOverride || this.sampleRecordId;
    }

    async handleSampleRecordChange(event) {
        const id = event.detail ? event.detail.recordId : null;
        this._sampleOverride = id;
        if (!id || !this.templateId) {
            return;
        }
        try {
            // Persist, so the next session previews against the same record instead of
            // silently falling back to whatever the template was created with.
            const fields = {};
            fields[ID_FIELD.fieldApiName] = this.templateId;
            fields[TEST_RECORD_FIELD.fieldApiName] = id;
            await updateRecord({ fields });
            this.statusText = 'Preview record saved on the template';
        } catch (e) {
            this.statusText = 'Using that record for preview (not saved: ' + this.errText(e) + ')';
        }
    }

    /**
     * Every element on the page, as a clickable list.
     *
     * Stacked boxes are the case the canvas cannot serve on its own: once one box sits
     * on top of another, the one underneath is unreachable by clicking, and a
     * full-bleed background makes everything under it unreachable at once. The list is
     * the way back to any element regardless of what is covering it.
     *
     * Ordered front-to-back — highest z first — because that is the order they are
     * stacked on the page, and reading a layer list bottom-up is a puzzle.
     */
    get layerItems() {
        const out = [];
        for (const board of this.doc.artboards || []) {
            for (const b of board.boxes || []) {
                out.push({
                    id: b.id,
                    z: b.z || 0,
                    y: b.y,
                    label: this.layerLabel(b),
                    kindLabel: this.layerKind(b),
                    cls: b.id === this.selectedId ? 'dg-layer dg-layer_on' : 'dg-layer'
                });
            }
        }
        return out.sort((a, c) => c.z - a.z || a.y - c.y);
    }

    @track showLayers = false;

    handleToggleLayers() {
        this.showLayers = !this.showLayers;
    }

    get hasLayers() {
        return this.layerItems.length > 0;
    }

    layerKind(b) {
        const k = b.kind || 'text';
        return k.charAt(0).toUpperCase() + k.slice(1);
    }

    /**
     * A label you can recognise the box by, not its id.
     *
     * Delegates to boxLabel so this list, the properties heading, the on-canvas badge
     * and the Follows picker all say the same thing. This used to be a second
     * implementation of the same idea, and it had already drifted: it did not know
     * about author-given names, so naming a block renamed it everywhere EXCEPT the one
     * list whose whole job is telling you which block is which.
     *
     * The two things it did better are kept below — an image and a signature are worth
     * identifying by what they point at, which matters more in a list of every element
     * than it does in an anchor picker.
     */
    layerLabel(b) {
        if (b.name && b.name.trim()) {
            return boxLabel(b);
        }
        if (b.kind === 'image') {
            const img = b.image || {};
            return img.assetKey || img.tag || 'No image chosen';
        }
        if (b.kind === 'code') {
            const c = b.code || {};
            return (c.type || 'qr').toUpperCase() + (c.field ? ' · ' + c.field : '');
        }
        if (b.kind === 'signature') {
            const sig = b.signature || {};
            return (sig.type || 'Full') + ' · ' + (sig.role || 'Signer');
        }
        const derived = boxLabel(b);
        // boxLabel names an empty text box by its kind, which reads oddly in a list of
        // every element — here "Empty text box" is the more useful answer.
        return derived === 'Text' ? 'Empty text box' : derived;
    }

    handleLayerClick(event) {
        this.selectedId = event.currentTarget.dataset.id;
        this.activeTool = 'select';
    }

    get selCondition() {
        const b = this.selectedBox;
        return b ? b.condition || '' : '';
    }

    get selVariantGroup() {
        const b = this.selectedBox;
        return b ? b.variantGroup || '' : '';
    }

    /** A literal example tag cannot live in the markup — LWC compiles {…} as a binding. */
    get conditionPlaceholder() {
        return 'Amount > 200';
    }

    get variantGroupPlaceholder() {
        return 'Customer Type';
    }

    handleConditionChange(event) {
        const box = this.selectedBox;
        if (!box) return;
        // Stored WITHOUT the {#IF …} wrapper: the serializer adds it. Accepting a
        // pasted whole tag and storing it raw would emit {#IF {#IF x}} on the next save.
        const raw = (event.target.value || '')
            .trim()
            .replace(/^\{#IF\s*/i, '')
            .replace(/\}$/, '');
        this.applyToBox(box.id, { condition: raw });
    }

    handleVariantGroupChange(event) {
        const box = this.selectedBox;
        if (!box) return;
        this.applyToBox(box.id, { variantGroup: (event.target.value || '').trim() });
    }

    get selZ() {
        const b = this.selectedBox;
        return b ? b.z || 0 : 0;
    }

    /**
     * Moves the box one step through the stack rather than setting a raw number.
     *
     * Stepping past the neighbour's level (not just +/-1) is what makes the button do
     * what its label says: with two boxes both at z=0, incrementing to 1 works, but
     * against a box at z=5 a single step would change nothing visible and the control
     * would look broken.
     */
    handleZStep(event) {
        const dir = event.currentTarget.dataset.dir === 'up' ? 1 : -1;
        const box = this.selectedBox;
        if (!box) return;
        const others = this.layerItems.filter((l) => l.id !== box.id).map((l) => l.z);
        const cur = box.z || 0;
        const candidates = others.filter((z) => (dir > 0 ? z >= cur : z <= cur));
        const target = candidates.length
            ? dir > 0
                ? Math.max(...candidates) + 1
                : Math.min(...candidates) - 1
            : cur + dir;
        this.applyToBox(box.id, { z: target });
        this.statusText = dir > 0 ? 'Moved forward' : 'Moved back';
    }

    handleZFront() {
        const box = this.selectedBox;
        if (!box) return;
        const zs = this.layerItems.filter((l) => l.id !== box.id).map((l) => l.z);
        this.applyToBox(box.id, { z: zs.length ? Math.max(...zs) + 1 : 1 });
        this.statusText = 'Brought to front';
    }

    handleZBack() {
        const box = this.selectedBox;
        if (!box) return;
        const zs = this.layerItems.filter((l) => l.id !== box.id).map((l) => l.z);
        this.applyToBox(box.id, { z: zs.length ? Math.min(...zs) - 1 : -1 });
        this.statusText = 'Sent to back';
    }

    // ---- Import an existing HTML document ---------------------------------
    @track importReport = null;

    get hasImportReport() {
        return !!this.importReport;
    }

    get importDropped() {
        return ((this.importReport || {}).dropped || []).map((d, i) => ({ key: 'd' + i, text: d }));
    }

    get importNotes() {
        return ((this.importReport || {}).notes || []).map((n, i) => ({ key: 'n' + i, text: n }));
    }

    get importSummary() {
        const r = this.importReport || {};
        return 'Imported ' + (r.boxes || 0) + ' element(s).';
    }

    handleDismissImport() {
        this.importReport = null;
    }

    triggerImport() {
        const input = this.template.querySelector('.dg-import-input');
        if (input) {
            input.click();
        }
    }

    /**
     * Converts an HTML file into this canvas.
     *
     * Nothing is destroyed by this. The existing layout goes onto the undo stack first,
     * and a canvas only reaches the template when it is SAVED — which writes a new
     * version, leaving the previous body intact and restorable from the version picker.
     * The one thing it must never do is change an HTML template into a Canvas one in
     * place, and it cannot: the file is read here and written to whichever Canvas
     * template is already open.
     */
    /**
     * Downloads the canvas as a standalone .html file.
     *
     * Deliberately the SAME output `serialize` writes on save, not a cleaned-up
     * or flattened variant. It therefore still carries the data-dg-* authoring
     * attributes, which is what lets Import HTML read it straight back — export
     * then import is a round trip, so this doubles as "take this template to
     * another org" and as a backup before a risky edit.
     */
    handleExportHtml() {
        try {
            const html = serialize(this.doc, this.geo);
            // data: URI rather than URL.createObjectURL(new Blob(...)).
            //
            // Lightning Web Security refuses the Blob route outright —
            //   "Cannot 'createObjectURL' using an unsecure [object Blob]"
            // — and it refuses it whether the Blob is built from a string or from
            // a typed array, so this is not about the Blob's contents. A data URI
            // never touches createObjectURL, so it works with LWS on or off.
            //
            // The size ceiling that normally rules data URIs out does not bite
            // here: a canvas body is markup for one page design, a few KB, not an
            // embedded document. encodeURIComponent also percent-encodes as UTF-8,
            // so an em dash or a non-ASCII field label survives intact.
            const href = 'data:text/html;charset=utf-8,' + encodeURIComponent(html);
            const a = document.createElement('a');
            a.href = href;
            a.download = this.exportFileName;
            // Anchor must be in the document for the click to register in Firefox.
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            this.statusText = 'Exported ' + this.exportFileName;
        } catch (e) {
            this.statusText = 'Export failed: ' + (e && e.message ? e.message : 'unknown error');
        }
    }

    get exportFileName() {
        const base = String(this.baseObject || 'canvas').replace(/[^A-Za-z0-9_-]+/g, '-');
        return 'portwood-' + base.toLowerCase() + '-canvas.html';
    }

    async handleImportFile(event) {
        const file = (event.target.files || [])[0];
        // Cleared immediately so re-picking the same file fires change again.
        const input = event.target;
        if (!file) {
            return;
        }
        try {
            const text = await file.text();
            if (this.boxCount > 0) {
                const go = await LightningConfirm.open({
                    message:
                        'Replace what is on this canvas with the imported document? ' +
                        'Undo restores it, and saving creates a new version rather than overwriting the old one.',
                    label: 'Replace this canvas?',
                    theme: 'warning'
                });
                if (!go) {
                    input.value = null;
                    return;
                }
            }
            this.pushHistory('import');
            // A canvas document is OPENED, not converted — the same rule loadBody
            // already follows, and for the same reason: htmlToCanvas() groups
            // consecutive blocks into single boxes, which is right for foreign HTML
            // and destroys every box, condition and coordinate in a canvas-exported
            // one, because a box's `position: absolute` lives in the .dg-pin/.dg-flow
            // CLASS rule, not on the box's own inline style, so htmlToCanvas never
            // recognizes it as already positioned.
            const parsed = deserialize(text);
            if (parsed) {
                this.readPageSetup(text);
                this.doc = parsed;
                const boxes = parsed.artboards.reduce((n, b) => n + (b.boxes || []).length, 0);
                this.importReport = {
                    dropped: [],
                    notes: ['Opened as a Canvas document — every element came across exactly as it was saved.'],
                    boxes
                };
            } else {
                const { doc, page, report } = htmlToCanvas(text);
                if (page) {
                    this.canvasPageSize = page.size;
                    this.canvasOrientation = page.orientation;
                    this.margins = { ...page.margins };
                    if (page.custom) {
                        this.customPage = normalizeCustom(page.custom);
                    }
                }
                this.doc = doc;
                this.importReport = report;
            }
            this.selectedId = null;
            this.reseedEditor();
            this.statusText = 'Imported ' + file.name;
            // Assets may be referenced by the imported markup.
            this.loadImageLibrary().then(() => this.hydrateImageSources());
        } catch (e) {
            this.saveError = 'Could not import that file — ' + this.errText(e);
        } finally {
            input.value = null;
        }
    }

    // ---- Panel sizing ----------------------------------------------------
    //
    // Editing text in a fixed 340px strip is the complaint this answers. The column is
    // draggable in X and the editor in Y, so the panel can be made a real writing
    // surface when that is what you are doing and pushed back out of the way when it
    // is not.
    @track panelWidth = 340;
    @track editorHeight = 220;

    get panelStyle() {
        return 'width:' + this.panelWidth + 'px;';
    }

    get editorStyle() {
        return '--dg-editor-h:' + this.editorHeight + 'px;';
    }

    handlePanelResizeStart(event) {
        event.preventDefault();
        const startX = event.clientX;
        const startW = this.panelWidth;
        const move = (e) => {
            // Floor keeps the controls usable; ceiling keeps a canvas on screen.
            this.panelWidth = Math.max(300, Math.min(760, startW + (e.clientX - startX)));
        };
        const up = () => {
            window.removeEventListener('mousemove', move, true);
            window.removeEventListener('mouseup', up, true);
        };
        window.addEventListener('mousemove', move, true);
        window.addEventListener('mouseup', up, true);
    }

    handleEditorResizeStart(event) {
        event.preventDefault();
        const startY = event.clientY;
        const startH = this.editorHeight;
        const move = (e) => {
            this.editorHeight = Math.max(140, Math.min(900, startH + (e.clientY - startY)));
        };
        const up = () => {
            window.removeEventListener('mousemove', move, true);
            window.removeEventListener('mouseup', up, true);
        };
        window.addEventListener('mousemove', move, true);
        window.addEventListener('mouseup', up, true);
    }

    // ---- Undo / redo -----------------------------------------------------
    //
    // Snapshots of the whole document, taken BEFORE each change. Whole-document rather
    // than per-action inverse operations: an inverse for every mutation is a second
    // implementation of the editor that has to be kept in step, and the one that gets
    // it wrong corrupts the document instead of restoring it. The documents here are
    // small enough that copying one is cheap.
    _past = [];
    _future = [];
    _suppressHistory = false;

    get canUndo() {
        return this._past.length > 0;
    }

    get canRedo() {
        return this._future.length > 0;
    }

    // `disabled` needs the inverse — a template cannot negate an expression.
    get undoDisabled() {
        return !this.canUndo;
    }

    get redoDisabled() {
        return !this.canRedo;
    }

    get undoClass() {
        return this.canUndo ? 'dg-qb-btn' : 'dg-qb-btn dg-qb-btn_off';
    }

    get redoClass() {
        return this.canRedo ? 'dg-qb-btn' : 'dg-qb-btn dg-qb-btn_off';
    }

    _snapshot() {
        return {
            doc: JSON.stringify(this.doc),
            pageSize: this.canvasPageSize,
            orientation: this.canvasOrientation,
            margins: { ...this.margins },
            customPage: { ...this.customPage },
            selectedId: this.selectedId
        };
    }

    /** Anything that replaces the document wholesale has to re-seed the editor. */
    reseedEditor() {
        this._syncedFor = null;
        this.richSeed = this.richTextValue;
    }

    _restore(snap) {
        this.doc = JSON.parse(snap.doc);
        this.canvasPageSize = snap.pageSize;
        this.canvasOrientation = snap.orientation;
        this.margins = { ...snap.margins };
        this.customPage = { ...snap.customPage };
        // Only reselect if that box still exists — undoing a delete should restore the
        // selection, undoing a create must not leave a selection pointing at nothing.
        const ids = new Set();
        for (const b of this.doc.artboards || []) {
            for (const x of b.boxes || []) ids.add(x.id);
        }
        this.selectedId = ids.has(snap.selectedId) ? snap.selectedId : null;
    }

    /**
     * Records the state about to be replaced.
     *
     * `tag` coalesces a run of the same action into ONE undo step — without it, typing
     * a sentence into the rich-text editor would take a separate undo per keystroke and
     * the feature would be useless for the thing people most want it for. Different
     * tag, or a pause, starts a new step.
     */
    pushHistory(tag) {
        if (this._suppressHistory) {
            return;
        }
        const now = Date.now();
        const top = this._past[this._past.length - 1];
        if (top && top.tag === tag && now - top.at < 700) {
            top.at = now;
            return;
        }
        this._past.push({ ...this._snapshot(), tag, at: now });
        // Bounded: an unbounded stack in a long session is a slow memory leak.
        if (this._past.length > 60) {
            this._past.shift();
        }
        this._future = [];
    }

    handleUndo() {
        if (!this._past.length) {
            return;
        }
        this._future.push(this._snapshot());
        this._restore(this._past.pop());
        this.statusText = 'Undone';
    }

    handleRedo() {
        if (!this._future.length) {
            return;
        }
        this._past.push({ ...this._snapshot(), tag: 'redo', at: Date.now() });
        this._restore(this._future.pop());
        this.statusText = 'Redone';
    }

    /**
     * Ctrl/Cmd+Z and Ctrl/Cmd+Shift+Z (or Ctrl+Y).
     *
     * Deliberately ignored while a text field has focus: the rich-text editor keeps its
     * own undo stack, and hijacking the shortcut there would undo a whole box's worth
     * of layout when the author meant to take back a word.
     */
    handleKeyDown(e) {
        const key = (e.key || '').toLowerCase();
        if (!(e.metaKey || e.ctrlKey) || (key !== 'z' && key !== 'y')) {
            return;
        }
        const t = e.target;
        const tag = t && t.tagName ? t.tagName.toUpperCase() : '';
        if (tag === 'INPUT' || tag === 'TEXTAREA' || (t && t.isContentEditable)) {
            return;
        }
        e.preventDefault();
        if (key === 'y' || e.shiftKey) {
            this.handleRedo();
        } else {
            this.handleUndo();
        }
    }

    /**
     * Copies a page and everything on it, straight after the original.
     *
     * This is how a header, footer or letterhead gets onto a second page: build it
     * once, duplicate, and edit only what differs. A pinned box does not repeat across
     * pages by itself — the engine only repeats running elements — so without this the
     * only route was rebuilding the furniture by hand on every page.
     */
    handleDuplicateArtboard(event) {
        const id = event.currentTarget.dataset.boardId;
        const boards = this.doc.artboards || [];
        const idx = boards.findIndex((b) => b.id === id);
        if (idx === -1) {
            return;
        }
        this.pushHistory('duplicate-page');
        const copy = cloneArtboard(boards[idx]);
        const next = [...boards.slice(0, idx + 1), copy, ...boards.slice(idx + 1)];
        this.doc = { ...this.doc, artboards: next };
        this.statusText = 'Page duplicated with its ' + (copy.boxes.length || 0) + ' element(s)';
    }

    get boardStyle() {
        return (
            'width:' +
            inToPx(this.geo.w, this.zoom) +
            'px;height:' +
            inToPx(this.geo.h, this.zoom) +
            'px;position:relative;background:#fff;box-shadow:0 1px 4px rgba(0,0,0,0.18);'
        );
    }

    /**
     * Boxes projected to screen pixels. The model stays in inches; nothing here ever
     * writes back a pixel value, so zoom can never drift the document.
     */
    get renderedBoards() {
        const canDelete = (this.doc.artboards || []).length > 1;
        return this.doc.artboards.map((board, idx) => {
            const layout = this.screenFollowLayout(board);
            return {
                id: board.id,
                index: idx + 1,
                canDelete,
                boxes: board.boxes.map((b) => this.renderedBox(b, board, layout))
            };
        });
    }

    renderedBox(b, board, layout) {
        const pos = layout.get(b.id) || { x: b.x, y: b.y, h: b.h };
        return {
            ...b,
            style:
                'position:absolute;left:' +
                inToPx(pos.x, this.zoom) +
                'px;top:' +
                inToPx(pos.y, this.zoom) +
                'px;width:' +
                inToPx(b.w, this.zoom) +
                'px;min-height:' +
                inToPx(pos.h, this.zoom) +
                'px;z-index:' +
                (b.z || 0) +
                ';' +
                this.screenStyle(b),
            cls: b.id === this.selectedId ? 'dg-cbox dg-cbox_selected' : 'dg-cbox',
            isSelected: b.id === this.selectedId,
            readout:
                (b.name ? b.name + ' · ' : '') +
                b.x.toFixed(2) +
                'in, ' +
                b.y.toFixed(2) +
                'in · ' +
                b.w.toFixed(2) +
                'in',
            modeLabel: this.boxModeLabel(b, board)
        };
    }

    screenFollowLayout(board) {
        const layout = new Map();
        for (const b of board.boxes || []) {
            layout.set(b.id, { x: b.x, y: b.y, h: this.screenBoxHeightIn(b) });
        }
        for (const group of buildAnchorGroups(board.boxes || [])) {
            if (group.length < 2) {
                continue;
            }
            const head = group[0];
            let visualBottom = head.y + this.screenBoxHeightIn(head);
            let authoredBottom = head.y + head.h;
            group.slice(1).forEach((member) => {
                const authoredGap = Math.max(0, member.y - authoredBottom);
                const y = visualBottom + authoredGap;
                const h = this.screenBoxHeightIn(member);
                layout.set(member.id, { x: member.x, y, h });
                visualBottom = y + h;
                authoredBottom = member.y + member.h;
            });
        }
        return layout;
    }

    screenBoxHeightIn(box) {
        if (!box) {
            return 0;
        }
        if (box.kind === 'text') {
            const st = { ...DEFAULT_STYLE, ...(box.style || {}) };
            const borderPt = st.borderWidth > 0 ? st.borderWidth * 2 : 0;
            const contentWidth = Math.max(0.1, (box.w || 0.5) - ((st.padding || 0) * 2 + borderPt) / 72);
            const charsPerLine = Math.max(1, Math.floor((contentWidth * 72) / Math.max(6, st.size || 11) / 0.55));
            const source = String(box.html != null && box.html !== '' ? box.html : box.text || '')
                .replace(/<br\s*\/?\s*>/gi, '\n')
                .replace(/<[^>]*>/g, '');
            const lines = source
                .split(/\r?\n/)
                .reduce((count, line) => count + Math.max(1, Math.ceil(line.length / charsPerLine)), 0);
            const lineIn = (Math.max(6, st.size || 11) * 1.2 + (st.padding || 0) * 2 + borderPt) / 72;
            return Math.max(box.h || 0, lines * lineIn);
        }
        if (box.kind !== 'table') {
            return box ? box.h : 0;
        }
        const t = box.table || {};
        const padPt = t.cellPadding == null ? 6 : t.cellPadding;
        const lineIn = (size) => (Math.max(6, size || 11) * 1.2 + padPt * 2) / 72;
        let rows = 0;
        let h = 0;
        if (t.showHeader) {
            h += lineIn((t.headerText || {}).size || 10.5);
        }
        const sampleRows = t.relationship ? 2 : (t.rows || []).length ? 0 : 1;
        rows += sampleRows;
        if (t.relationship) {
            rows += 1;
        }
        rows += (t.rows || []).length;
        if (t.totals && t.totals.enabled) {
            rows += 1;
        }
        const subRows = (t.subRelationship || '').trim() && (t.subColumns || []).length ? sampleRows : 0;
        h += rows * lineIn((t.rowText || {}).size || 11);
        h += subRows * lineIn((t.subText || {}).size || 10);
        return Math.max(box.h || 0, h);
    }

    boxModeLabel(b, board) {
        if (b.positionMode === 'follows') {
            const target = (board.boxes || []).find((x) => x.id === b.anchorTo);
            return target ? 'Follows ' + boxLabel(target) : 'Follows (element deleted)';
        }
        return b.mode === 'flow' ? 'Flows' : 'Pinned';
    }

    /**
     * The line drawn from an anchor to the box that follows it.
     *
     * Only for the selected box's own chain. Drawing every link on the page turns a
     * document with a few groups into a cat's cradle, and the question an author is
     * asking is always about the thing they just clicked.
     */
    get tethers() {
        const sel = this.selectedBox;
        if (!sel) {
            return [];
        }
        const board = this._boardOf(sel.id);
        if (!board) {
            return [];
        }
        const byId = new Map(board.boxes.map((b) => [b.id, b]));
        // The whole chain the selection belongs to, not just its own link — seeing
        // where a group starts is the point.
        const root = anchorRoot(sel, byId);
        if (!root) {
            return [];
        }
        const out = [];
        for (const b of board.boxes) {
            if (b.positionMode !== 'follows' || !b.anchorTo) {
                continue;
            }
            if (anchorRoot(b, byId) !== root) {
                continue;
            }
            const a = byId.get(b.anchorTo);
            if (!a) {
                continue;
            }
            const z = this.zoom;
            out.push({
                key: 'tether-' + b.id,
                x1: inToPx(a.x + a.w / 2, z),
                y1: inToPx(a.y + a.h, z),
                x2: inToPx(b.x + b.w / 2, z),
                y2: inToPx(b.y, z)
            });
        }
        return out;
    }

    get hasTethers() {
        return this.tethers.length > 0;
    }

    /**
     * Box styling in SCREEN units. Point sizes scale by zoom so 11pt at 200% looks
     * twice as big, matching every design tool — the model still stores points.
     */
    screenStyle(b) {
        const st = { ...DEFAULT_STYLE, ...(b.style || {}) };
        const z = this.zoom || 1;
        let css =
            'font-family:' +
            st.font +
            ';font-size:' +
            (st.size * z).toFixed(2) +
            'pt;color:' +
            st.color +
            ';text-align:' +
            st.align +
            ';padding:' +
            (st.padding * z).toFixed(2) +
            'pt;';
        if (st.bold) css += 'font-weight:bold;';
        if (st.italic) css += 'font-style:italic;';
        if (st.underline) css += 'text-decoration:underline;';
        if (st.fill) css += 'background:' + st.fill + ';';
        if (st.borderWidth > 0) css += 'border:' + (st.borderWidth * z).toFixed(2) + 'pt solid ' + st.borderColor + ';';
        return css;
    }

    /**
     * The tool rail, as data.
     *
     * Every tool carries its own glyph, so adding one to this list is the whole job —
     * it cannot ship without an icon, which is what happened when the rail was
     * hand-written markup. The glyphs are inline SVG paths rather than
     * `lightning-icon icon-name="utility:..."` because a name SLDS does not publish
     * (utility:pointer, utility:shape_alt, utility:qrcode — all invented) renders
     * nothing at all and reports no error, leaving a blank button.
     *
     * 24x24 viewBox, stroked with currentColor so the icon follows the rail's text
     * colour and the active state without a second set of rules.
     */
    get railTools() {
        const T = [
            {
                id: 'select',
                label: 'Select',
                title: 'Select, move and resize',
                action: 'tool',
                d: 'M5 3l13 8-5.6 1.6L15 19l-2.4 1-2.6-6.6L5 17z'
            },
            {
                id: 'text',
                label: 'Text',
                title: 'Add a text box',
                action: 'tool',
                d: 'M5 7V5h14v2M12 5v14M9 19h6'
            },
            {
                id: 'table',
                label: 'Table',
                title: 'Add a table',
                action: 'tool',
                d: 'M3 5h18v14H3zM3 10h18M9 10v9M15 10v9'
            },
            {
                id: 'image',
                label: 'Image',
                title: 'Add an image from Portwood Assets',
                action: 'tool',
                d: 'M3 5h18v14H3zM3 16l5-5 4 4 3-3 6 6M8.5 9.5h.01'
            },
            {
                id: 'code',
                label: 'Code',
                title: 'Add a QR code or barcode',
                action: 'tool',
                d: 'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h3v3h-3zM18 18h3v3h-3z'
            },
            {
                id: 'chart',
                label: 'Chart',
                title: 'Add a chart over a related list',
                action: 'tool',
                d: 'M3 21h18M6 21V10M11 21V4M16 21v-7M21 21v-11'
            },
            {
                id: 'signature',
                label: 'Signature',
                title: 'Add a place for someone to sign',
                action: 'tool',
                d: 'M3 17c3-1 4-9 7-9s2 7 5 7 3-4 6-4M3 21h18'
            },
            {
                id: 'shape',
                label: 'Shape',
                title: 'Add a rectangle or a line',
                action: 'tool',
                d: 'M3 4h11v11H3zM10 16a5 5 0 1 0 10 0 5 5 0 1 0-10 0'
            },
            {
                id: 'layers',
                label: 'Elements',
                title: 'List every element — reach one that is underneath another',
                action: 'layers',
                d: 'M12 3l9 5-9 5-9-5zM3 13l9 5 9-5M3 17l9 5 9-5'
            },
            {
                id: 'data',
                label: 'Data',
                title: 'Choose the fields this document uses',
                action: 'data',
                d: 'M12 3c4.4 0 8 1.3 8 3s-3.6 3-8 3-8-1.3-8-3 3.6-3 8-3M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3'
            },
            {
                id: 'pagesetup',
                label: 'Page',
                title: 'Page size, orientation and margins',
                action: 'pagesetup',
                d: 'M6 3h9l4 4v14H6zM15 3v4h4M9 12h7M9 16h5'
            },
            {
                id: 'addpage',
                label: 'Add page',
                title: 'Add another page',
                action: 'addpage',
                d: 'M12 5v14M5 12h14'
            }
        ];
        return T.map((t) => ({
            ...t,
            cls: this.isRailToolActive(t) ? 'dg-tool dg-tool_active' : 'dg-tool'
        }));
    }

    isRailToolActive(t) {
        if (t.action === 'tool') return this.activeTool === t.id;
        if (t.action === 'data') return this.showData === true;
        if (t.action === 'pagesetup') return this.showPageSetup === true;
        if (t.action === 'layers') return this.showLayers === true;
        return false;
    }

    handleRailClick(event) {
        const action = event.currentTarget.dataset.action;
        if (action === 'data') {
            this.handleToggleData();
            return;
        }
        if (action === 'pagesetup') {
            this.handleTogglePageSetup();
            return;
        }
        if (action === 'addpage') {
            this.handleAddArtboard();
            return;
        }
        if (action === 'layers') {
            this.handleToggleLayers();
            return;
        }
        this.activeTool = event.currentTarget.dataset.tool;
        if (this.activeTool === 'image') {
            // Load the asset list while the author is still choosing where to click.
            this.loadImageLibrary();
        }
    }

    get selectedIsTable() {
        const b = this.selectedBox;
        return !!b && b.kind === 'table';
    }

    get selTableRel() {
        return ((this.selectedBox || {}).table || {}).relationship || '';
    }

    get selTableHeader() {
        return !!((this.selectedBox || {}).table || {}).showHeader;
    }

    get selTableColumns() {
        const t = (this.selectedBox || {}).table || {};
        return (t.columns || []).map((c, i) => ({ ...c, idx: i, num: i + 1 }));
    }

    _patchTable(patch) {
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        this.applyToBox(box.id, { table: { ...box.table, ...patch } });
    }

    handleTableRelChange(event) {
        this._patchTable({ relationship: (event.target.value || '').trim() });
    }

    handleTableHeaderToggle(event) {
        this._patchTable({ showHeader: event.target.checked });
    }

    handleColumnChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const key = event.currentTarget.dataset.key;
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        const columns = box.table.columns.map((c, i) => (i === idx ? { ...c, [key]: event.target.value } : c));
        this._patchTable({ columns });
    }

    get gridStyleOptions() {
        return GRID_STYLES;
    }

    get selGridStyle() {
        return ((this.selectedBox || {}).table || {}).gridStyle || 'rows';
    }

    get selTableHeaderFill() {
        return ((this.selectedBox || {}).table || {}).headerFill || '#eeeeee';
    }
    get selTableHeaderBold() {
        return !!((this.selectedBox || {}).table || {}).headerBold;
    }
    get selTableGridColor() {
        return ((this.selectedBox || {}).table || {}).gridColor || '#999999';
    }
    get selTableGridWidth() {
        const t = (this.selectedBox || {}).table || {};
        return t.gridWidth == null ? 0.5 : t.gridWidth;
    }
    get selTableCellPadding() {
        const t = (this.selectedBox || {}).table || {};
        return t.cellPadding == null ? 3 : t.cellPadding;
    }
    get selTableTotals() {
        return !!(((this.selectedBox || {}).table || {}).totals || {}).enabled;
    }
    /**
     * Extra rows, one input PER COLUMN.
     *
     * They were a single pipe-separated field, which meant the author had to know that
     * `|` was a delimiter, count columns by hand, and could not leave one blank without
     * counting the empty segments. The cells carry the column's label so it is obvious
     * which one is being typed into.
     */
    get selTableRows() {
        const t = (this.selectedBox || {}).table || {};
        const cols = t.columns || [];
        return (t.rows || []).map((cells, i) => ({
            idx: i,
            num: i + 1,
            cells: cols.map((c, j) => ({
                key: i + '_' + j,
                // BOTH indices. The cell inputs carry data-idx and data-col, and
                // without idx on the cell itself data-idx resolved to undefined, so
                // every keystroke was written to row NaN and silently discarded.
                idx: i,
                col: j,
                label: c.label || 'Column ' + (j + 1),
                value: cells[j] || ''
            }))
        }));
    }

    handleTableStyleChange(event) {
        const key = event.currentTarget.dataset.key;
        const raw = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        const val = event.target.type === 'number' ? parseFloat(raw) : raw;
        this._patchTable({ [key]: val });
    }

    handleAddRow() {
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        this._patchTable({ rows: [...(box.table.rows || []), box.table.columns.map(() => '')] });
    }

    handleRowChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const col = parseInt(event.currentTarget.dataset.col, 10);
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        const width = (box.table.columns || []).length;
        const rows = (box.table.rows || []).map((r, i) => {
            if (i !== idx) return r;
            // Pad to the column count first: a row saved when the table had two columns
            // has two cells, and writing to index 3 on it would leave a hole that
            // serializes as `undefined`.
            const cells = [];
            for (let j = 0; j < width; j += 1) cells.push(r[j] || '');
            cells[col] = event.target.value;
            return cells;
        });
        this._patchTable({ rows });
    }

    handleRemoveRow(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        this._patchTable({ rows: (box.table.rows || []).filter((r, i) => i !== idx) });
    }

    handleTotalsToggle(event) {
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        const on = event.target.checked;
        const existing = (box.table.totals || {}).cells || [];
        this._patchTable({
            totals: {
                enabled: on,
                // Suggest {SUM:Rel.Field} per column on first enable, then leave the
                // author's edits alone.
                cells: existing.length ? existing : suggestTotals(box.table)
            }
        });
    }

    handleTotalsCellChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        const cells = [...((box.table.totals || {}).cells || [])];
        cells[idx] = event.target.value;
        this._patchTable({ totals: { ...box.table.totals, cells } });
    }

    get selTableTotalsCells() {
        const t = (this.selectedBox || {}).table || {};
        const cells = (t.totals || {}).cells || [];
        return (t.columns || []).map((c, i) => ({ idx: i, label: c.label, value: cells[i] || '' }));
    }

    get selHeaderText() {
        const t = (this.selectedBox || {}).table || {};
        return { size: 11, color: '#1a1a1a', bold: true, align: 'left', ...(t.headerText || {}) };
    }

    // ---- Nested (grandchild) rows ---------------------------------------
    /** LWC compiles a literal {…} in markup as a binding, so example tags are getters. */
    get columnTagPlaceholder() {
        return '{Name}';
    }

    get selSubRel() {
        return ((this.selectedBox || {}).table || {}).subRelationship || '';
    }

    get selSubColumns() {
        const t = (this.selectedBox || {}).table || {};
        return (t.subColumns || []).map((c, i) => ({ ...c, idx: i, num: i + 1 }));
    }

    get hasSubRel() {
        return !!this.selSubRel;
    }

    get selSubText() {
        const t = (this.selectedBox || {}).table || {};
        return { size: 10, color: '#41546b', bold: false, align: 'left', ...(t.subText || {}) };
    }

    get selSubFill() {
        return ((this.selectedBox || {}).table || {}).subFill || '#f7f9fc';
    }

    get selSubIndent() {
        const t = (this.selectedBox || {}).table || {};
        return t.subIndent == null ? 12 : t.subIndent;
    }

    handleSubRelChange(event) {
        const rel = (event.target.value || '').trim();
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        const patch = { subRelationship: rel };
        // Seed one column the moment a relationship is named. A relationship with no
        // columns emits nothing at all, so the setting would look like it did not take.
        if (rel && !(box.table.subColumns || []).length) {
            patch.subColumns = [{ label: 'Column 1', tag: '', width: '' }];
        }
        this._patchTable(patch);
    }

    /**
     * The NESTED relationship's own fields, offered as chips.
     *
     * Without these an author types tags into the nested cells blind, and the failure mode
     * is quiet: a field the nested object does not have renders empty, and a standard
     * field can mean something unexpected — OpportunityLineItem.Name is composed by the
     * platform as "<Opportunity> <Product>", so it looks like the wrong record's data
     * when it is really the right field doing what Salesforce defined it to do.
     *
     * extractQueryShape flattens grandchildren into the same children list, so the
     * lookup is the same as the parent's.
     */
    get subPickableFields() {
        const rel = this.selSubRel;
        if (!rel) {
            return [];
        }
        const shape = this.querySpace;
        const child = (shape.children || []).find((c) => (c.relationshipName || c.alias) === rel);
        return ((child && child.fields) || []).map((f) => ({ key: rel + f, label: f, tag: '{' + f + '}' }));
    }

    get hasSubPickableFields() {
        return this.subPickableFields.length > 0;
    }

    /** Clicking a nested-field chip adds a cell for it, mirroring the column chips. */
    handlePickSubField(event) {
        const tag = event.currentTarget.dataset.tag;
        const label = event.currentTarget.dataset.label;
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        this._patchTable({
            subColumns: [...(box.table.subColumns || []), { label, tag, width: '' }]
        });
        this.statusText = 'Nested cell added: ' + label;
    }

    handleSubColumnChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const key = event.currentTarget.dataset.key;
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        const subColumns = (box.table.subColumns || []).map((c, i) =>
            i === idx ? { ...c, [key]: event.target.value } : c
        );
        this._patchTable({ subColumns });
    }

    handleAddSubColumn() {
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        const cur = box.table.subColumns || [];
        this._patchTable({
            subColumns: [...cur, { label: 'Column ' + (cur.length + 1), tag: '', width: '' }]
        });
    }

    handleRemoveSubColumn(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        this._patchTable({ subColumns: (box.table.subColumns || []).filter((c, i) => i !== idx) });
    }

    get selTotalsText() {
        const t = (this.selectedBox || {}).table || {};
        return { size: 11, color: '#1a1a1a', bold: true, align: 'left', ...(t.totalsText || {}) };
    }

    get selTotalsFill() {
        return ((this.selectedBox || {}).table || {}).totalsFill || '#eeeeee';
    }

    get totalsBoldClass() {
        return this.selTotalsText.bold && !this.totalsBoldDisabled ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }
    get totalsBoldDisabled() {
        return isUnicodeFont(this.selTotalsFont);
    }
    get totalsBoldTitle() {
        return this.totalsBoldDisabled ? 'Bold not available for Arial Unicode' : 'Bold';
    }
    get subBoldDisabled() {
        return isUnicodeFont(this.selSubFont);
    }

    /** Align is a button, not a field, so it carries its value in data-align. */
    handleTotalsAlign(event) {
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        this._patchTable({
            totalsText: { ...this.selTotalsText, align: event.currentTarget.dataset.align }
        });
    }

    get selRowText() {
        const t = (this.selectedBox || {}).table || {};
        return { size: 11, color: '#1a1a1a', bold: false, align: 'left', ...(t.rowText || {}) };
    }

    get headerBoldClass() {
        return this.selHeaderText.bold && !this.headerBoldDisabled ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }
    get headerBoldDisabled() {
        return isUnicodeFont(this.selHeaderFont);
    }
    get headerBoldTitle() {
        return this.headerBoldDisabled ? 'Bold not available for Arial Unicode' : 'Bold';
    }

    get rowBoldClass() {
        return this.selRowText.bold && !this.rowBoldDisabled ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }
    get rowBoldDisabled() {
        return isUnicodeFont(this.selRowFont);
    }
    get rowBoldTitle() {
        return this.rowBoldDisabled ? 'Bold not available for Arial Unicode' : 'Bold';
    }

    /** Header and body rows are styled separately — see DEFAULT_HEADER_TEXT. */
    get selHeaderFont() {
        return this.selHeaderText.font || this.selFont;
    }

    get selRowFont() {
        return this.selRowText.font || this.selFont;
    }

    get selTotalsFont() {
        return this.selTotalsText.font || this.selFont;
    }

    get selSubFont() {
        return this.selSubText.font || this.selFont;
    }

    handleRowTextChange(event) {
        const which = event.currentTarget.dataset.which;
        const key = event.currentTarget.dataset.key;
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        const current =
            which === 'header'
                ? this.selHeaderText
                : which === 'totals'
                  ? this.selTotalsText
                  : which === 'sub'
                    ? this.selSubText
                    : this.selRowText;
        let value;
        if (key === 'bold') {
            // Arial Unicode MS has no bold face — refuse the toggle for that band.
            const bandDisabled =
                which === 'header'
                    ? this.headerBoldDisabled
                    : which === 'totals'
                      ? this.totalsBoldDisabled
                      : which === 'sub'
                        ? this.subBoldDisabled
                        : this.rowBoldDisabled;
            if (bandDisabled) {
                return;
            }
            value = !current.bold;
        } else if (key === 'size') {
            value = parseFloat(event.target.value);
            if (isNaN(value)) return;
        } else {
            value = event.target.value;
        }
        const field =
            which === 'header'
                ? 'headerText'
                : which === 'totals'
                  ? 'totalsText'
                  : which === 'sub'
                    ? 'subText'
                    : 'rowText';
        const patch = { [key]: value };
        if (key === 'font' && isUnicodeFont(value) && current.bold) {
            patch.bold = false;
        }
        this._patchTable({ [field]: { ...current, ...patch } });
    }

    handleAddColumn() {
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') return;
        this._patchTable({
            columns: [...box.table.columns, { label: 'Column ' + (box.table.columns.length + 1), tag: '', width: '' }]
        });
    }

    handleRemoveColumn(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const box = this.selectedBox;
        if (!box || box.kind !== 'table' || box.table.columns.length <= 1) return;
        this._patchTable({ columns: box.table.columns.filter((c, i) => i !== idx) });
    }

    // Placeholders that LOOK like merge tags have to come from getters: LWC parses a
    // leading "{" in an attribute as a template expression, so placeholder="{Field}"
    // compiles as a binding to a property called Field and renders empty.
    get tagPlaceholder() {
        return '{Field}';
    }

    get totalsPlaceholder() {
        return '{SUM:Rel.Field}';
    }

    /** What the template's Query Config currently exposes, for the field picker. */
    get querySpace() {
        return extractQueryShape(this.queryConfig, this.baseObject);
    }

    get relationshipOptions() {
        return (this.querySpace.children || []).map((c) => ({
            label: c.relationshipName || c.alias,
            value: c.relationshipName || c.alias
        }));
    }

    /**
     * Fields offered for the CURRENT selection: a table offers its relationship's
     * fields, a text box offers the record's own and its parents'. Clicking one is the
     * whole point — nobody should be typing {Name} from memory and finding out at
     * render time whether they got it right.
     */
    get pickableFields() {
        const shape = this.querySpace;
        const box = this.selectedBox;
        if (box && box.kind === 'table') {
            const rel = (box.table || {}).relationship;
            const child = (shape.children || []).find((c) => (c.relationshipName || c.alias) === rel);
            return ((child && child.fields) || []).map((f) => ({ key: rel + f, label: f, tag: '{' + f + '}' }));
        }
        return [...(shape.baseFields || []), ...(shape.parentFields || [])].map((f) => ({
            key: f,
            label: f,
            tag: '{' + f + '}'
        }));
    }

    /**
     * Field chips insert a merge tag, so they only make sense where a tag can go: into
     * a text box's content or a table's columns. An image binds to a field through its
     * own input, and a shape has nowhere to put one.
     */
    get hasPickableFields() {
        const box = this.selectedBox;
        const kind = box ? box.kind || 'text' : null;
        return this.pickableFields.length > 0 && (kind === 'text' || kind === 'table' || kind === 'code');
    }

    /**
     * True when the table points at a relationship the Query Config does not contain.
     *
     * This used to fail in silence: the field list simply came back empty with no
     * explanation, and the author was left to guess whether they had mistyped the
     * relationship or the query was missing it. Both are fixable in one click — the
     * dropdown only offers real relationships, and "Update the template's query" adds
     * whatever the canvas actually uses.
     */
    get relationshipMissingFromQuery() {
        const box = this.selectedBox;
        if (!box || box.kind !== 'table') {
            return false;
        }
        const rel = (box.table || {}).relationship;
        if (!rel) {
            return false;
        }
        return !(this.querySpace.children || []).some((c) => (c.relationshipName || c.alias) === rel);
    }

    get relationshipChoices() {
        const opts = this.relationshipOptions;
        return [{ label: '— none (fixed table) —', value: '' }, ...opts];
    }

    get hasRelationshipChoices() {
        return this.relationshipOptions.length > 0;
    }

    handleRelPick(event) {
        this._patchTable({ relationship: event.detail.value });
    }

    handlePickField(event) {
        const tag = event.currentTarget.dataset.tag;
        const label = event.currentTarget.dataset.label;
        const box = this.selectedBox;
        if (!box) {
            return;
        }
        if (box.kind === 'table') {
            this._patchTable({
                columns: [...(box.table.columns || []), { label, tag, width: '' }]
            });
            this.statusText = 'Column added: ' + label;
        } else if (box.kind === 'code') {
            this.bindFieldToCode(box, tag);
        } else if (box.kind === 'chart') {
            this.bindFieldToChart(box, tag);
        } else {
            // Append to the RICH TEXT content. It used to append to box.text, which
            // stopped being what the box renders when editing moved into the rich-text
            // editor — so clicking a field appeared to do nothing at all.
            const current = box.html != null ? box.html : box.text || '';
            const sep = current && !/(\s|>)$/.test(current) ? ' ' : '';
            this.applyToBox(box.id, { html: current + sep + tag });
            this.statusText = 'Inserted ' + tag;
        }
    }

    /**
     * Preview saves FIRST, then generates.
     *
     * Previewing an unsaved canvas would show the last saved state and quietly imply
     * the edits were fine — the worst possible outcome for a button whose entire job
     * is telling you the truth about what will print.
     */
    async handlePreview() {
        if (!this.templateId) {
            return;
        }
        if (!this.effectiveSampleRecordId) {
            this.statusText = 'Pick a record to preview with — Data in the left rail';
            this.showData = true;
            return;
        }
        this.isPreviewing = true;
        this.statusText = 'Saving, then generating…';
        // Open the tab NOW, synchronously inside the click, and point it at the PDF
        // once it exists. Opening after the await is what trips popup blockers — the
        // flow designer works around that by making you click Preview twice, and one
        // click is better. about:blank is explicitly allowed by LWS.
        const win = window.open('', '_blank');
        try {
            await this.handleSave();
            if (!this._saveOk) {
                // Generating anyway would render the LAST SAVED body and present it as
                // a preview of what is on screen — the most misleading thing this
                // button could do. The save banner already says what went wrong.
                this.statusText = '';
                if (win) win.close();
                return;
            }
            // Charts must be prepared BEFORE generating. Passing null here meant
            // every {Chart:...} fell through to the HTML CSS-bar path, which only
            // implements bar/pivot/clustered/stacked — so a column, pie, donut,
            // line or area chart came back as a "supported ... only via
            // htmlRender=svg" error block instead of a picture.
            const charts = await this.prepareChartsForPreview();
            const res = await generatePdf({
                templateId: this.templateId,
                recordId: this.effectiveSampleRecordId,
                saveToRecord: false,
                chartCvMap: charts.map,
                chartBucketMap: charts.bucketMap
            });
            if (!res || !res.base64) {
                this.statusText = 'Preview did not return a document';
                if (win) win.close();
                return;
            }
            const bytes = atob(res.base64);
            const arr = new Uint8Array(bytes.length);
            for (let i = 0; i < bytes.length; i++) arr[i] = bytes.charCodeAt(i);
            if (this.previewUrl) {
                URL.revokeObjectURL(this.previewUrl);
            }
            // A blob URL in an <iframe src> is blocked outright by Lightning Web
            // Security — "HTMLIFrameElement.src supports http://, https:// schemes,
            // relative urls and about:blank". window.open with the same URL is fine,
            // which is why the preview is a tab rather than a panel.
            this.previewUrl = URL.createObjectURL(new Blob([arr], { type: 'application/pdf' }));
            if (win) {
                win.location = this.previewUrl;
            }
            this.statusText = 'Preview of ' + (res.title || 'document') + ' opened in a new tab';
        } catch (e) {
            this.statusText = 'Preview failed: ' + (e.body ? e.body.message : e.message);
            if (win) win.close();
        } finally {
            this.isPreviewing = false;
        }
    }

    handleDismissError() {
        this.saveError = null;
    }

    handleClosePreview() {
        if (this.previewUrl) {
            URL.revokeObjectURL(this.previewUrl);
        }
        this.previewUrl = null;
    }

    get hasPreview() {
        return !!this.previewUrl;
    }

    /** The config the Data picker binds to, and what Save writes back. */
    get queryText() {
        return this.queryDraft == null ? this.queryConfig || '' : this.queryDraft;
    }

    @track showData = false;

    /**
     * The DATA panel — docGenTreeBuilder, the component docGenAdmin actually renders.
     * Not docGenQueryBuilder: that one is the older standalone build speaking the V1
     * flat format, and wiring it was how the first attempt broke.
     */
    handleToggleData() {
        this.showData = !this.showData;
    }

    async handleCloseData() {
        this.showData = false;
        if (this.queryDraft != null && this.queryDraft !== (this.queryConfig || '')) {
            await this.handleSaveQuery();
        }
    }

    /**
     * The builder re-emits on its own round-trips, so only a REAL change is kept —
     * otherwise opening the panel and closing it would rewrite the stored query with
     * the builder's regeneration of it, a silent edit nobody asked for.
     */
    handleBuilderConfigChange(event) {
        const cfg = event.detail && event.detail.queryConfig;
        if (cfg != null && cfg !== (this.queryConfig || '')) {
            this.queryDraft = cfg;
        }
    }

    /**
     * The tree builder needs a base object to build anything — without one it renders
     * an empty shell, which reads as "the Data button is broken".
     */
    get hasBaseObject() {
        return !!this.baseObject;
    }

    handleUseGenerated() {
        this.queryDraft = this.generatedQuery;
    }

    async handleSaveQuery() {
        if (!this.templateId) {
            return;
        }
        try {
            const fields = {};
            fields[ID_FIELD.fieldApiName] = this.templateId;
            fields[QUERY_FIELD.fieldApiName] = this.queryText;
            await updateRecord({ fields });
            this.statusText = 'Query saved';
            this.dispatchEvent(new CustomEvent('queryupdated', { detail: { query: this.queryText } }));
        } catch (e) {
            this.statusText = 'Could not save the query: ' + (e.body ? e.body.message : e.message);
        }
    }

    /** Hands off to the host, which owns the template's full edit surface. */
    handleEditTemplate() {
        this.dispatchEvent(new CustomEvent('edittemplate', { bubbles: true, composed: true }));
    }

    get generatedQuery() {
        return buildQueryConfig(this.doc);
    }

    get queryDiffers() {
        return (this.queryConfig || '').trim() !== this.generatedQuery.trim();
    }

    /**
     * Writes the derived Query Config back to the template.
     *
     * Explicitly a button, never automatic. A generated query that silently replaced a
     * hand-tuned WHERE or ORDER BY would be a worse bug than the blank-tag problem it
     * solves, so the author sees what it will become and chooses.
     */
    async handleApplyQuery() {
        if (!this.templateId) {
            return;
        }
        try {
            const fields = {};
            fields[ID_FIELD.fieldApiName] = this.templateId;
            fields[QUERY_FIELD.fieldApiName] = this.generatedQuery;
            await updateRecord({ fields });
            this.statusText = 'Query updated from the canvas';
            this.dispatchEvent(new CustomEvent('queryupdated', { detail: { query: this.generatedQuery } }));
        } catch (e) {
            this.statusText = 'Could not update the query: ' + (e.body ? e.body.message : e.message);
        }
    }

    get fontOptions() {
        return FONT_CHOICES;
    }

    get selectedStyle() {
        return { ...DEFAULT_STYLE, ...((this.selectedBox || {}).style || {}) };
    }

    get selFont() {
        return this.selectedStyle.font;
    }
    get selSize() {
        return this.selectedStyle.size;
    }
    get selColor() {
        return this.selectedStyle.color;
    }
    get selFill() {
        return this.selectedStyle.fill || '#ffffff';
    }
    get selPadding() {
        return this.selectedStyle.padding;
    }
    get selBorderWidth() {
        return this.selectedStyle.borderWidth;
    }
    get selBorderColor() {
        return this.selectedStyle.borderColor;
    }
    get boldClass() {
        return this.selectedStyle.bold && !this.boxBoldDisabled ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }
    /** Arial Unicode MS has no bold face in the PDF — the Bold toggle is a no-op for it. */
    get boxBoldDisabled() {
        return isUnicodeFont(this.selFont);
    }
    get boldTitle() {
        return this.boxBoldDisabled
            ? 'Bold is not available for Arial Unicode — it has no bold face in the PDF'
            : 'Bold';
    }
    get italicClass() {
        return this.selectedStyle.italic ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }
    get underlineClass() {
        return this.selectedStyle.underline ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }
    get alignLeftClass() {
        return this.selectedStyle.align === 'left' ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }
    get alignCenterClass() {
        return this.selectedStyle.align === 'center' ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }
    get alignRightClass() {
        return this.selectedStyle.align === 'right' ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }

    /** One entry point for every style change — keeps the patch shape in one place. */
    _patchStyle(patch) {
        const box = this.selectedBox;
        if (!box) return;
        this.applyToBox(box.id, { style: { ...DEFAULT_STYLE, ...(box.style || {}), ...patch } });
    }

    handleStyleToggle(event) {
        const key = event.currentTarget.dataset.key;
        // Arial Unicode MS has no bold face — a bold this box carries would silently
        // print regular in the PDF. Refuse the toggle so the canvas can't promise it.
        if (key === 'bold' && this.boxBoldDisabled) {
            return;
        }
        this._patchStyle({ [key]: !this.selectedStyle[key] });
    }

    handleAlign(event) {
        this._patchStyle({ align: event.currentTarget.dataset.align });
    }

    handleFontChange(event) {
        const font = event.detail.value;
        // Switching to Arial Unicode MS clears an active bold: it has no bold face, so
        // keeping bold on would show a weight the PDF cannot print (see canRenderBold).
        const patch = { font };
        if (isUnicodeFont(font) && this.selectedStyle.bold) {
            patch.bold = false;
        }
        this._patchStyle(patch);
    }

    handleNumChange(event) {
        const key = event.currentTarget.dataset.key;
        const n = parseFloat(event.target.value);
        if (!isNaN(n)) this._patchStyle({ [key]: n });
    }

    handleColorChange(event) {
        this._patchStyle({ [event.currentTarget.dataset.key]: event.target.value });
    }

    handleClearFill() {
        this._patchStyle({ fill: '' });
    }

    get renderedGuides() {
        return this.guides.map((g, i) => ({
            key: g.axis + i,
            style:
                g.axis === 'v'
                    ? 'position:absolute;top:0;bottom:0;left:' + inToPx(g.at, this.zoom) + 'px;width:1px;'
                    : 'position:absolute;left:0;right:0;top:' + inToPx(g.at, this.zoom) + 'px;height:1px;'
        }));
    }

    get selectedBox() {
        for (const board of this.doc.artboards) {
            const hit = board.boxes.find((b) => b.id === this.selectedId);
            if (hit) return hit;
        }
        return null;
    }

    get hasSelection() {
        return !!this.selectedBox;
    }

    /** The author's name for the selection, or '' — never the derived label. */
    get selectedName() {
        const b = this.selectedBox;
        return (b && b.name) || '';
    }

    /**
     * The panel heading. "Box" told the author nothing they could not already see;
     * naming the selection is how you know which of six similar blocks you are editing.
     */
    get selectedBoxLabel() {
        const b = this.selectedBox;
        return b ? boxLabel(b) : 'Box';
    }

    handleNameChange(event) {
        const box = this.selectedBox;
        if (!box) {
            return;
        }
        // Trimmed, and an all-whitespace name is no name — it would render as a blank
        // row in the Follows picker and read as a bug.
        this.applyToBox(box.id, { name: (event.target.value || '').trim() });
    }

    get selectedIsFlow() {
        const b = this.selectedBox;
        return !!b && b.mode === 'flow';
    }

    get zoomPercent() {
        return Math.round(this.zoom * 100) + '%';
    }

    async connectedCallback() {
        this._connected = true;
        this._onKey = (e) => this.handleKeyDown(e);
        window.addEventListener('keydown', this._onKey);
        await this.loadBody();
        await this.loadVersions();
    }

    disconnectedCallback() {
        this._connected = false;
        if (this._onKey) {
            window.removeEventListener('keydown', this._onKey);
            this._onKey = null;
        }
        // Chart.js holds a registry entry per canvas; without this, reopening the
        // designer accumulates dead instances for the lifetime of the page.
        for (const chart of this._chartInstances.values()) {
            chart.destroy();
        }
        this._chartInstances.clear();
        if (this.previewUrl) {
            URL.revokeObjectURL(this.previewUrl);
            this.previewUrl = null;
        }
    }

    /**
     * Everything that belongs to the OLD template, cleared.
     *
     * Named per-field rather than swapping in a fresh object because a missed field is
     * the whole bug class: a stale version list points the picker at another template's
     * versions, and a stale saved-html snapshot makes a fresh document look dirty.
     */
    resetForTemplate() {
        this._loaded = false;
        this._savedHtml = null;
        this.doc = blankDocument();
        this.selectedId = null;
        this.activeTool = 'select';
        this.zoom = 1;
        this.guides = [];
        this.versions = [];
        this.activeVersionId = null;
        this.imageLibrary = [];
        this.queryDraft = null;
        this.saveError = null;
        this.statusText = '';
        this.showData = false;
        this._showPageSetup = false;
        this._sampleOverride = null;
        this._past = [];
        this._future = [];
        this.margins = { ...DEFAULT_MARGINS };
        this.customPage = { ...DEFAULT_CUSTOM_PAGE };
        // A new canvas starts Letter / portrait / no margins. An existing one has these
        // overwritten by readPageSetup from its own saved @page rule.
        this.canvasPageSize = 'Letter';
        this.canvasOrientation = 'Portrait';
        if (this.previewUrl) {
            URL.revokeObjectURL(this.previewUrl);
            this.previewUrl = null;
        }
        if (this._connected) {
            this.loadBody();
            this.loadVersions();
        }
    }

    /**
     * True when the canvas differs from what is stored.
     *
     * Compared by serializing rather than by tracking a dirty flag through every
     * mutation — a flag has to be set at each of the a dozen places that change the
     * document, and the one that gets missed is the one that loses someone's work.
     */
    get hasUnsavedChanges() {
        if (this._savedHtml == null) {
            return this.boxCount > 0;
        }
        return serialize(this.doc, this.geo) !== this._savedHtml;
    }

    async handleBack() {
        if (this.hasUnsavedChanges) {
            const discard = await LightningConfirm.open({
                message: 'This canvas has changes that have not been saved. Leave and discard them?',
                label: 'Discard changes?',
                theme: 'warning'
            });
            if (!discard) {
                return;
            }
        }
        this.dispatchEvent(new CustomEvent('back'));
    }

    /**
     * Versions, newest first, with the active one marked.
     *
     * The canvas reads and writes the ACTIVE VERSION's body. Reading the loose
     * docgen_html_body_* CV while generation read the version's is exactly how a
     * template came to show five boxes on screen and render two, with nothing
     * reporting a problem — so the editor now looks at the same bytes the renderer
     * does, by construction rather than by convention.
     */
    async loadVersions() {
        if (!this.templateId) {
            return;
        }
        try {
            const rows = (await getTemplateVersions({ templateId: this.templateId })) || [];
            this.versions = rows.map((v) => {
                const isActive = v.Is_Active__c === true || v.portwoodglobal__Is_Active__c === true;
                const when = v.CreatedDate ? new Date(v.CreatedDate).toLocaleString() : '';
                return {
                    label: (isActive ? '★ ' : '') + (v.Name || 'Version') + (when ? ' · ' + when : ''),
                    value: v.Id,
                    isActive
                };
            });
            const active = this.versions.find((v) => v.isActive);
            this.activeVersionId = active ? active.value : (this.versions[0] || {}).value || null;
        } catch (e) {
            this.versions = [];
        }
    }

    get versionOptions() {
        return this.versions.map((v) => ({ label: v.label, value: v.value }));
    }

    get hasVersions() {
        return this.versions.length > 0;
    }

    /**
     * Switching version makes it active AND reloads the canvas from it, so the editor,
     * the preview and the generated document all agree immediately. Activating without
     * reloading would leave the canvas showing one version while everything downstream
     * used another — the same divergence in a new costume.
     */
    async handleVersionChange(event) {
        const id = event.detail.value;
        this.activeVersionId = id;
        try {
            await activateVersion({ versionId: id });
            const html = await getVersionBody({ versionId: id });
            this.readPageSetup(html);
            const parsed = deserialize(html);
            this.doc = parsed || blankDocument();
            this.selectedId = null;
            this._savedHtml = serialize(this.doc, this.geo);
            this.hydrateImageSources();
            this.statusText = parsed ? 'Loaded that version' : 'That version has no canvas content';
            await this.loadVersions();
        } catch (e) {
            this.saveError = 'Could not switch version — ' + (e.body ? e.body.message : e.message);
        }
    }

    async loadBody() {
        if (this._loaded || !this.templateId) {
            return;
        }
        this._loaded = true;
        await this.loadVersions();
        try {
            const html = this.activeVersionId
                ? await getVersionBody({ versionId: this.activeVersionId })
                : await getHtmlTemplateBody({ templateId: this.templateId });
            this.readPageSetup(html);
            const parsed = deserialize(html);
            // Snapshot what is STORED, re-serialized from the parsed model rather than
            // taken from the raw bytes: a round trip is not byte-identical (attribute
            // order, whitespace), so comparing against the raw html would report every
            // freshly opened template as unsaved.
            if (parsed) {
                this.doc = parsed;
                this.statusText = 'Loaded';
            } else if (html && html.trim()) {
                // A stored body that is not canvas-shaped is CONVERTED, not discarded.
                //
                // Showing a blank artboard over a real body was the dangerous option —
                // the first save would have replaced the document with nothing. It is
                // also how a starter arrives: the wizard writes the chosen design as
                // ordinary HTML and the canvas turns it into boxes on first open, so
                // there is one conversion path to keep correct rather than two.
                //
                // Non-destructive by construction: saving writes a NEW version, so the
                // original body stays exactly where it was and the version picker can
                // go back to it.
                const imported = htmlToCanvas(html);
                this.doc = imported.doc;
                if (imported.page) {
                    this.canvasPageSize = imported.page.size;
                    this.canvasOrientation = imported.page.orientation;
                    this.margins = { ...imported.page.margins };
                    if (imported.page.custom) {
                        this.customPage = normalizeCustom(imported.page.custom);
                    }
                }
                this.importReport = imported.report;
                this.reseedEditor();
                this.statusText = 'Converted an existing HTML body into ' + imported.report.boxes + ' element(s)';
            } else {
                this.doc = blankDocument();
                this.statusText = 'New canvas';
            }
            this._savedHtml = serialize(this.doc, this.geo);
            // The asset list is loaded for EVERY template, not only when a box is found
            // that needs one. Conditioning it on the document's contents meant the
            // picker was empty until something happened to trigger a load, and which
            // something varied — a box that already had a preview URL, or a template
            // with no image box yet, both left it unloaded and looking broken. It is
            // one cheap metadata query; making it unconditional removes the whole class
            // of "why didn't it load this time".
            //
            // Not awaited: the layout is already correct, and pictures filling in a
            // moment later beats holding the canvas blank on a slow query.
            this.loadImageLibrary().then(() => this.hydrateImageSources());
        } catch (e) {
            this.doc = blankDocument();
            this.statusText = 'Could not load the saved body: ' + (e.body ? e.body.message : e.message);
        }
    }

    /**
     * Seeds each text box's contenteditable body from the model.
     *
     * contenteditable cannot be data-bound: re-rendering it on every keystroke
     * destroys the caret. So the body is lwc:dom="manual" and written here — but ONLY
     * when it actually differs and is not the element being typed into. Writing
     * innerHTML into the focused box would move the caret to the start on every
     * character, which is the same class of bug as the designer's insert caret landing
     * to the left of the tag.
     */
    renderedCallback() {
        // Re-sync the property inputs whenever the SELECTION changes.
        //
        // These are plain <input> elements holding values that come from getters. When
        // you click from one box to another, LWC reuses the same elements, and an
        // input the user has typed into keeps the DOM value it had — so the panel
        // showed the previous box's numbers. Keying off the selected id makes the
        // hand-off explicit instead of relying on the diff to notice.
        if (this._syncedFor !== this.selectedId) {
            this._syncedFor = this.selectedId;
            // Re-seed the editor for the newly selected box. Only here: doing it on
            // every render would put the caret back to the start on every keystroke.
            this.richSeed = this.richTextValue;
            const st = this.selectedStyle;
            const map = {
                size: st.size,
                borderWidth: st.borderWidth,
                borderColor: st.borderColor,
                color: st.color,
                fill: st.fill || '#ffffff',
                padding: st.padding
            };
            for (const el of this.template.querySelectorAll('[data-key]')) {
                const want = map[el.dataset.key];
                if (want !== undefined && el.value !== String(want)) {
                    el.value = want;
                }
            }
        }
        // A <textarea> takes its content from its TEXT CHILD, not from a value
        // attribute — `value={x}` in the markup renders an empty box with a stray
        // attribute on it, which is why switching to the HTML view showed nothing.
        // Written here, and only when it actually differs and is not being typed into,
        // so the caret cannot be thrown to the start mid-edit.
        const src = this.template.querySelector('.dg-source-edit');
        if (src) {
            const want = this.richTextValue || '';
            if (src !== this.template.activeElement && src.value !== want) {
                src.value = want;
            }
        }
        const byId = new Map();
        for (const board of this.doc.artboards) {
            for (const b of board.boxes) byId.set(b.id, b);
        }
        // Every box renders read-only from the SAME code that serializes it, so the
        // artboard cannot drift from the PDF.
        for (const el of this.template.querySelectorAll('.dg-cbox-body')) {
            const model = byId.get(el.dataset.id);
            if (!model) continue;
            const want = this.previewHtmlFor(model);
            // The comparison is a READ; the write below is this component's own
            // sanitized preview markup, never author input straight from the page.
            // eslint-disable-next-line @lwc/lwc/no-inner-html
            if (el.innerHTML !== want) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html
                el.innerHTML = want;
            }
        }
        this.syncRenderedTableHeights(byId);
        this.paintChartPreviews();
    }

    /**
     * Tables can grow after their model height was chosen: extra rows, totals, nested
     * rows and wrapping all change the real footprint. Snap guides read `box.h`, so
     * after the browser has laid out the preview, copy that rendered height back into
     * the model in inches.
     */
    syncRenderedTableHeights(byId) {
        const patches = new Map();
        for (const el of this.template.querySelectorAll('.dg-cbox[data-id]')) {
            const model = byId.get(el.dataset.id);
            if (!model || model.kind !== 'table') {
                continue;
            }
            const rect = el.getBoundingClientRect();
            if (!rect || rect.height <= 0) {
                continue;
            }
            const h = pxToIn(rect.height, this.zoom);
            if (Math.abs(h - (parseFloat(model.h) || 0)) > 0.005) {
                patches.set(model.id, h);
            }
        }
        if (!patches.size) {
            return;
        }
        this.doc = {
            ...this.doc,
            artboards: this.doc.artboards.map((board) => ({
                ...board,
                boxes: board.boxes.map((b) => (patches.has(b.id) ? { ...b, h: patches.get(b.id) } : b))
            }))
        };
    }

    /**
     * Draws every configured chart box onto its canvas.
     *
     * Runs after the painter has written the placeholders, because setting
     * innerHTML replaces the canvas element and would discard anything drawn
     * into the old one.
     *
     * Preview data is representative, not live: the designer is a layout tool
     * and an author is choosing shape, colours and proportions here. Rendering
     * real aggregates would mean paging the child list on every keystroke, and
     * the sample record often has too little data to show what the chart will
     * look like in production anyway.
     */
    async paintChartPreviews() {
        const canvases = this.template.querySelectorAll('.dg-chart-canvas');
        if (!canvases || !canvases.length) {
            return;
        }
        let ChartCtor;
        try {
            ChartCtor = await this.ensureChartJs();
        } catch (e) {
            // No preview is a cosmetic loss; the tag still generates correctly.
            return;
        }
        if (!ChartCtor) {
            return;
        }
        const byId = new Map();
        for (const board of this.doc.artboards) {
            for (const b of board.boxes) byId.set(b.id, b);
        }
        for (const canvas of canvases) {
            const model = byId.get(canvas.dataset.chartFor);
            if (!model) continue;
            const wPx = Math.max(40, inToPx(model.w, this.zoom));
            const hPx = Math.max(30, inToPx(model.h, this.zoom));
            if (
                canvas.width === wPx &&
                canvas.height === hPx &&
                canvas.dataset.painted === this.chartFingerprint(model)
            ) {
                continue;
            }
            canvas.width = wPx;
            canvas.height = hPx;
            canvas.dataset.painted = this.chartFingerprint(model);
            const existing = this._chartInstances.get(model.id);
            if (existing) {
                existing.destroy();
            }
            const c = model.chart || {};
            const palette = String(c.colors || '')
                .split(',')
                .map((x) => x.trim())
                .filter(Boolean);
            const buckets = SAMPLE_CHART_BUCKETS.map((b, i) => ({
                ...b,
                color: palette.length ? palette[i % palette.length] : b.color
            }));
            try {
                this._chartInstances.set(
                    model.id,
                    renderChartToCanvas(ChartCtor, canvas, buckets, {
                        style: c.style || 'bar',
                        title: c.title || '',
                        // The preview has to honour the label size too, or the artboard
                        // shows one thing and the PDF prints another — which is the
                        // whole premise of this editor.
                        fontSize: c.fontSize
                    })
                );
            } catch (e) {
                // Leave the canvas blank rather than break the board.
            }
        }
    }

    /** Any change that should force a repaint. */
    chartFingerprint(model) {
        const c = model.chart || {};
        return [c.style, c.title, c.colors, model.w, model.h, this.zoom].join('|');
    }

    async ensureChartJs() {
        if (window.Chart) {
            return window.Chart;
        }
        await loadScript(this, CHARTJS_RESOURCE);
        return window.Chart;
    }

    /**
     * Rasterizes the document's charts against the sample record before a
     * preview is generated.
     *
     * The board preview draws representative buckets, but the PDF must show the
     * sample record's real numbers — this is the author's check that the tag
     * points at the right relationship and field. Failure is non-fatal: an empty
     * map falls through to the server-side path, same as any other caller.
     */
    async prepareChartsForPreview() {
        const none = { map: null, bucketMap: null };
        if (!this.templateId || !this.effectiveSampleRecordId) {
            return none;
        }
        try {
            const ChartCtor = await this.ensureChartJs();
            if (!ChartCtor) {
                return none;
            }
            this.statusText = 'Building charts…';
            const res = await prepareChartsClientSide({
                templateId: this.templateId,
                recordId: this.effectiveSampleRecordId,
                ChartCtor
            });
            return res || none;
        } catch (e) {
            console.warn('Portwood: chart preparation failed; falling back to the server path', e);
            return none;
        }
    }

    refreshChartPreview() {
        // The painter runs on the next render; nudging tracked state is enough.
        this.paintChartPreviews();
    }

    /**
     * Recovers page size, orientation and margins from the saved document's @page rule.
     *
     * The @page rule IS the record of the author's page setup — there is nowhere else
     * it is stored, and the engine renders from it. Without this, reopening a canvas
     * authored on A4 landscape with 1in margins showed it on Letter portrait at 0.5in
     * and the first save wrote that wrong page back over the right one.
     */
    readPageSetup(html) {
        const rule = /@page\s*\{([^}]*)\}/.exec(html || '');
        if (!rule) {
            return;
        }
        // A custom size is two lengths rather than a named page.
        const custom = /size:\s*([0-9.]+)in\s+([0-9.]+)in/i.exec(rule[1]);
        if (custom) {
            this.canvasPageSize = 'Custom';
            this.canvasOrientation = 'Portrait';
            this.customPage = normalizeCustomPage({ w: custom[1], h: custom[2] });
        }
        const size = custom ? null : /size:\s*([A-Za-z0-9]+)\s*(portrait|landscape)?/i.exec(rule[1]);
        if (size) {
            const named = ['Letter', 'A4', 'Legal'].find((n) => n.toLowerCase() === size[1].toLowerCase());
            if (named) this.canvasPageSize = named;
            this.canvasOrientation = (size[2] || 'portrait').toLowerCase() === 'landscape' ? 'Landscape' : 'Portrait';
        }
        const marg = /margin:\s*([^;]+)/i.exec(rule[1]);
        if (marg) {
            const parts = marg[1]
                .trim()
                .split(/\s+/)
                .map((v) => parseFloat(v))
                .filter((v) => !isNaN(v));
            // CSS shorthand: 1, 2 or 4 values. Anything else is not something we wrote.
            if (parts.length === 1) {
                this.margins = normalizeMargins({ top: parts[0], right: parts[0], bottom: parts[0], left: parts[0] });
            } else if (parts.length === 2) {
                this.margins = normalizeMargins({ top: parts[0], right: parts[1], bottom: parts[0], left: parts[1] });
            } else if (parts.length === 4) {
                this.margins = normalizeMargins({
                    top: parts[0],
                    right: parts[1],
                    bottom: parts[2],
                    left: parts[3]
                });
            }
        }
    }

    // ---- Image box -------------------------------------------------------
    get selectedIsImage() {
        const b = this.selectedBox;
        return !!b && b.kind === 'image';
    }

    get selImage() {
        return (this.selectedBox || {}).image || {};
    }

    get selImageHasSource() {
        const img = this.selImage;
        return !!(img.src || img.tag);
    }

    /**
     * A merge tag cannot be written literally in the markup — LWC compiles `{...}` as a
     * binding expression and the deploy fails outright. Every example tag in this
     * component comes from a getter for that reason.
     */
    get imageTagPlaceholder() {
        return '{%Logo__c}';
    }

    get selImageKeepRatio() {
        return this.selImage.keepRatio !== false;
    }

    get imageChoices() {
        const current = this.selImage.assetKey;
        return (this.imageLibrary || []).map((a) => ({
            ...a,
            previewUrl: a.latestVersionCvId ? '/sfc/servlet.shepherd/version/download/' + a.latestVersionCvId : '',
            cls: a.assetKey === current ? 'dg-imgcard dg-imgcard_on' : 'dg-imgcard'
        }));
    }

    get hasImageChoices() {
        return (this.imageLibrary || []).length > 0;
    }

    /**
     * The library is the org's Portwood ASSETS, not org files or static resources.
     *
     * An asset is referenced by key, and `{%asset:<key>}` resolves to that asset's
     * latest version every time a document is generated — so replacing the logo in the
     * Assets tab updates every template at once. Listing raw files here instead would
     * pin each document to one ContentVersion, and nothing would show that a template
     * had gone stale.
     *
     * Inactive assets are filtered out because the merge resolver ignores them: the tag
     * would render a placeholder, which is a broken document that looked fine while
     * being authored.
     */
    async loadImageLibrary() {
        // Return the IN-FLIGHT promise rather than bailing out.
        //
        // Bailing meant a second caller resolved immediately with the list still
        // empty, and whatever it was going to do with the assets it did with nothing —
        // which is how a box's picture could stay blank while a load it was waiting on
        // was already running.
        if (this._assetsPromise) {
            return this._assetsPromise;
        }
        this.imageLoading = true;
        this._assetsPromise = (async () => {
            try {
                const rows = (await getAssets()) || [];
                this.imageLibrary = rows.filter((a) => a.isActive && a.latestVersionCvId);
            } catch (e) {
                this.statusText = 'Could not load assets: ' + this.errText(e);
            } finally {
                this.imageLoading = false;
                this._assetsPromise = null;
            }
        })();
        return this._assetsPromise;
    }

    handleRefreshAssets() {
        this.imageLibrary = [];
        this.loadImageLibrary().then(() => this.hydrateImageSources());
    }

    /**
     * Puts the preview URL back on every image box after a load.
     *
     * A saved image box carries only its ASSET KEY — the resolved /sfc/ URL is a
     * preview convenience and is deliberately never serialized, because baking a
     * ContentVersion id into the document would pin it to one version of the asset. The
     * cost is that a reloaded box has a key and no picture, so the canvas drew the
     * "Pick an image" placeholder over a box that was correctly configured, and the
     * only way out looked like re-picking the image.
     *
     * Resolving the key against the asset list restores the picture without touching
     * what gets saved: src is not serialized while an assetKey is set, so the document
     * is byte-identical before and after this runs and the unsaved-changes check is
     * unaffected.
     */
    async hydrateImageSources() {
        const needs = [];
        for (const board of this.doc.artboards || []) {
            for (const b of board.boxes || []) {
                if (b.kind === 'image' && b.image && b.image.assetKey && !b.image.src) {
                    needs.push(b.id);
                }
            }
        }
        if (!needs.length) {
            return;
        }
        if (!(this.imageLibrary || []).length) {
            await this.loadImageLibrary();
        }
        if (!(this.imageLibrary || []).length) {
            return;
        }
        const byKey = new Map();
        for (const a of this.imageLibrary || []) {
            if (a.latestVersionCvId) {
                byKey.set(a.assetKey, '/sfc/servlet.shepherd/version/download/' + a.latestVersionCvId);
            }
        }
        let changed = false;
        const artboards = (this.doc.artboards || []).map((board) => ({
            ...board,
            boxes: (board.boxes || []).map((b) => {
                if (b.kind !== 'image' || !b.image || !b.image.assetKey || b.image.src) {
                    return b;
                }
                const url = byKey.get(b.image.assetKey);
                if (!url) {
                    return b;
                }
                changed = true;
                return { ...b, image: { ...b.image, src: url } };
            })
        }));
        if (changed) {
            this.doc = { ...this.doc, artboards };
        }
    }

    handlePickImage(event) {
        const key = event.currentTarget.dataset.key;
        const url = event.currentTarget.dataset.url;
        const name = event.currentTarget.dataset.name;
        const box = this.selectedBox;
        if (!box || box.kind !== 'image') return;
        this.applyToBox(box.id, {
            image: { ...box.image, assetKey: key, src: url, tag: '', fileName: name }
        });
        this.statusText = 'Image set to ' + key;
    }

    handleImageTagChange(event) {
        const box = this.selectedBox;
        if (!box || box.kind !== 'image') return;
        // A field tag and an asset key are alternatives, not layers — setting one has
        // to clear the other or the serializer silently picks for you.
        this.applyToBox(box.id, {
            image: { ...box.image, tag: (event.target.value || '').trim(), assetKey: '', src: '' }
        });
    }

    handleImageRatioToggle(event) {
        const box = this.selectedBox;
        if (!box || box.kind !== 'image') return;
        this.applyToBox(box.id, { image: { ...box.image, keepRatio: event.target.checked } });
    }

    handleImageClear() {
        const box = this.selectedBox;
        if (!box || box.kind !== 'image') return;
        this.applyToBox(box.id, { image: { ...box.image, assetKey: '', src: '', tag: '', fileName: '' } });
    }

    /** Escapes what would otherwise break out of the markup being built. */
    escAttr(v) {
        return String(v == null ? '' : v)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    /** Apex errors arrive as e.body.message; JS errors as e.message. */
    errText(e) {
        return (e && e.body ? e.body.message : e && e.message) || 'Unknown error';
    }

    // ---- QR / barcode ----------------------------------------------------
    get selectedIsCode() {
        const b = this.selectedBox;
        return !!b && b.kind === 'code';
    }

    get selCode() {
        return (this.selectedBox || {}).code || {};
    }

    get codeTypeOptions() {
        return CODE_TYPES;
    }

    get selCodeIsQr() {
        return (this.selCode.type || 'qr') === 'qr';
    }

    get codeSizeLabel() {
        const b = this.selectedBox;
        if (!b) return '';
        return b.w.toFixed(2) + 'in x ' + b.h.toFixed(2) + 'in';
    }

    /**
     * Changing a code's type or size RESIZES THE BOX to match.
     *
     * That is the point of having a code tool rather than typing the tag into a text
     * box: the box on the canvas is the footprint the symbol will occupy, so the rest
     * of the layout can be built around it instead of guessed at and corrected after
     * the first render.
     */
    // ---------------------------------------------------------------- chart
    get selectedIsChart() {
        const b = this.selectedBox;
        return !!b && b.kind === 'chart';
    }

    get selChart() {
        return (this.selectedBox || {}).chart || {};
    }

    get chartStyleOptions() {
        return CHART_STYLES;
    }

    /**
     * Cross-tab styles need a second dimension; the plain ones must not show
     * those inputs or an author will fill them in and wonder why nothing
     * changed.
     */
    /** Surfaced in the inspector so the reason a chart is blank is visible. */
    get selChartIssue() {
        return this.selectedIsChart ? chartConfigIssue(this.selectedBox) : null;
    }

    get selChartIsCrossTab() {
        return ['stacked', 'clustered', 'pivot'].indexOf(this.selChart.style || 'bar') !== -1;
    }

    handleChartChange(event) {
        const key = event.currentTarget.dataset.key;
        const box = this.selectedBox;
        if (!box || box.kind !== 'chart') return;
        const value = event.detail && event.detail.value != null ? event.detail.value : event.target.value;
        const chart = { ...box.chart, [key]: value };
        this.applyToBox(box.id, { chart });
        this.refreshChartPreview(box.id);
    }

    /**
     * Clicking a field chip with a chart box selected binds it — relationship
     * first (it is the one the author cannot guess), then the bucket field.
     */
    bindFieldToChart(box, token) {
        // Strip the braces and any format suffix — a chart groups by the raw
        // field, and `{Amount:currency}` would not resolve.
        const clean = String(token || '')
            .trim()
            .replace(/^\{|\}$/g, '')
            .split(':')[0];
        const chart = { ...box.chart };
        if (!chart.relationship) {
            chart.relationship = clean;
            this.statusText = 'Chart reads ' + clean;
        } else {
            chart.field = clean;
            this.statusText = 'Chart groups by ' + clean;
        }
        this.applyToBox(box.id, { chart });
        this.refreshChartPreview();
    }

    handleCodeChange(event) {
        const key = event.currentTarget.dataset.key;
        const box = this.selectedBox;
        if (!box || box.kind !== 'code') return;
        let value = event.detail && event.detail.value != null ? event.detail.value : event.target.value;
        if (key === 'size' || key === 'height') {
            value = parseFloat(value);
            if (isNaN(value)) return;
        }
        const code = { ...box.code, [key]: value };
        const size = codeBoxSize(code);
        this.applyToBox(box.id, { code, w: size.w, h: size.h });
    }

    /** Clicking a field chip with a code box selected binds the code to that field. */
    bindFieldToCode(box, tag) {
        const field = String(tag || '')
            .trim()
            .replace(/^\{|\}$/g, '')
            .split(':')[0];
        this.applyToBox(box.id, { code: { ...box.code, field } });
        this.statusText = 'Code reads ' + field;
    }

    // ---- Signature -------------------------------------------------------
    get selectedIsSignature() {
        const b = this.selectedBox;
        return !!b && b.kind === 'signature';
    }

    get selSignature() {
        return (this.selectedBox || {}).signature || {};
    }

    get signatureTypeOptions() {
        return SIGNATURE_TYPES;
    }

    /** The tag as it will be written, so the author can see what the box produces. */
    get signatureTagPreview() {
        const sig = this.selSignature;
        const role = String(sig.role || 'Signer')
            .trim()
            .replace(/\s+/g, '_')
            .replace(/[^A-Za-z0-9_]/g, '');
        return '{@Signature_' + (role || 'Signer') + ':' + (sig.order || 1) + ':' + (sig.type || 'Full') + '}';
    }

    /**
     * Changing the TYPE resizes the box, the same way the code tool does — initials and
     * a date need a fraction of the room a signature does, and leaving a signature-sized
     * rectangle behind for a date field means every layout starts by fixing it.
     */
    handleSignatureChange(event) {
        const key = event.currentTarget.dataset.key;
        const box = this.selectedBox;
        if (!box || box.kind !== 'signature') return;
        let value =
            event.target.type === 'checkbox'
                ? event.target.checked
                : event.detail && event.detail.value != null
                  ? event.detail.value
                  : event.target.value;
        if (key === 'order') {
            value = parseInt(value, 10);
            if (isNaN(value) || value < 1) return;
        }
        const signature = { ...box.signature, [key]: value };
        const patch = { signature };
        if (key === 'type') {
            const size = signatureBoxSize(signature);
            patch.w = size.w;
            patch.h = size.h;
        }
        this.applyToBox(box.id, patch);
    }

    // ---- Shape box -------------------------------------------------------
    get selectedIsShape() {
        const b = this.selectedBox;
        return !!b && b.kind === 'shape';
    }

    get selShape() {
        return (this.selectedBox || {}).shape || {};
    }

    get shapeOptions() {
        return SHAPE_CHOICES;
    }

    get selShapeIsRect() {
        return (this.selShape.type || 'rect') === 'rect';
    }

    handleShapeChange(event) {
        const key = event.currentTarget.dataset.key;
        const box = this.selectedBox;
        if (!box || box.kind !== 'shape') return;
        let value = event.detail && event.detail.value != null ? event.detail.value : event.target.value;
        if (key === 'borderWidth') {
            value = parseFloat(value);
            if (isNaN(value)) return;
        }
        this.applyToBox(box.id, { shape: { ...box.shape, [key]: value } });
    }

    handleShapeFillNone() {
        const box = this.selectedBox;
        if (!box || box.kind !== 'shape') return;
        this.applyToBox(box.id, { shape: { ...box.shape, fill: '' } });
    }

    /**
     * What a box looks like ON THE CANVAS. Everything here mirrors what the serializer
     * emits — the canvas is only worth having if the two agree.
     */
    previewHtmlFor(model) {
        if (model.kind === 'chart') {
            // A <canvas> placeholder only. Chart.js paints into it after the DOM
            // settles (paintChartPreviews) — drawing here would be wiped by the
            // very next innerHTML comparison in the painter loop.
            // Same validator the serializer uses, so what the board says is
            // missing is exactly what stops the tag being written.
            const issue = chartConfigIssue(model);
            if (issue) {
                // `issue` is a controlled string — the only interpolation is a
                // style name from the fixed CHART_STYLES list.
                return '<div class="dg-chart-empty"><strong>Chart</strong><br/>' + issue + '</div>';
            }
            return '<canvas class="dg-chart-canvas" data-chart-for="' + model.id + '"></canvas>';
        }
        if (model.kind === 'table') {
            return tablePreviewHtml(model);
        }
        if (model.kind === 'image') {
            const img = model.image || {};
            const imgHPx = Math.max(1, inToPx(model.h, this.zoom));
            if (img.src) {
                const fit = img.keepRatio === false ? 'fill' : 'contain';
                return (
                    '<img src="' +
                    img.src +
                    '" style="width:100%;height:' +
                    imgHPx +
                    'px;object-fit:' +
                    fit +
                    ';" alt="" draggable="false" />'
                );
            }
            // A merge-tag image cannot be previewed — the picture depends on the record.
            // Say so rather than showing an empty box the author reads as broken.
            const label = img.tag ? img.tag : 'Pick an image';
            return (
                '<div style="width:100%;height:' +
                imgHPx +
                'px;border:1px dashed #a8b3c2;color:#5a6b7f;' +
                'font:11px sans-serif;display:table-cell;text-align:center;vertical-align:middle;">' +
                label +
                '</div>'
            );
        }
        if (model.kind === 'code') {
            const c = model.code || {};
            // A placeholder at the exact footprint, not a drawn symbol. The real one is
            // rendered by the engine from the record's value, which does not exist here
            // — and a client-side encoder would be a second implementation to keep in
            // step with the server's for no gain. What the author needs on the canvas
            // is the SPACE it takes, which this is exact about.
            const wPx = Math.max(1, inToPx(model.w, this.zoom));
            const hPx = Math.max(1, inToPx(model.h, this.zoom));
            const label = c.field ? c.type.toUpperCase() + ' · ' + c.field : c.type.toUpperCase() + ' · pick a field';
            return (
                '<div style="width:' +
                wPx +
                'px;height:' +
                hPx +
                'px;border:1px dashed #7a8a9c;background:repeating-linear-gradient(0deg,#f3f5f8,#f3f5f8 4px,#e6eaf0 4px,#e6eaf0 8px);' +
                'color:#41546b;font:10px sans-serif;display:table-cell;text-align:center;vertical-align:middle;">' +
                label +
                '</div>'
            );
        }
        if (model.kind === 'signature') {
            const sig = model.signature || {};
            const wPx = Math.max(1, inToPx(model.w, this.zoom));
            const hPx = Math.max(1, inToPx(model.h, this.zoom));
            const T = { Full: 'Signature', Initials: 'Initials', Date: 'Date signed', DatePick: 'Date picker' };
            const label = (T[sig.type] || 'Signature') + ' · ' + (sig.role || 'Signer');
            // A signing line, because that is what the reader will see space for. The
            // tag itself is stripped from an ordinary render, so drawing the tag text
            // would show something the document never contains.
            return (
                '<div style="width:' +
                wPx +
                'px;height:' +
                hPx +
                'px;border:1px dashed #7a8a9c;background:#fbfcfe;position:relative;' +
                'font:10px sans-serif;color:#41546b;">' +
                '<span style="position:absolute;left:4px;bottom:2px;">' +
                label +
                '</span>' +
                '<span style="position:absolute;left:4px;right:4px;bottom:14px;border-bottom:1px solid #7a8a9c;"></span>' +
                '</div>'
            );
        }
        if (model.kind === 'shape') {
            const sh = model.shape || {};
            // An EXPLICIT pixel height, not height:100%.
            //
            // The body element these previews are written into is auto-height (it sizes
            // to its text), so a percentage height resolved against nothing and every
            // rectangle drew as a flat line. The box's own height in inches is the real
            // answer, projected to screen pixels the same way the box itself is.
            const hPx = Math.max(1, inToPx(model.h, this.zoom));
            if (sh.type === 'hline') {
                return (
                    '<div style="width:100%;height:0;border-top:' +
                    Math.max(0.5, sh.borderWidth) +
                    'pt solid ' +
                    sh.borderColor +
                    ';"></div>'
                );
            }
            if (sh.type === 'vline') {
                return (
                    '<div style="height:' +
                    hPx +
                    'px;width:0;border-left:' +
                    Math.max(0.5, sh.borderWidth) +
                    'pt solid ' +
                    sh.borderColor +
                    ';"></div>'
                );
            }
            return (
                '<div style="width:100%;height:' +
                hPx +
                'px;box-sizing:border-box;' +
                (sh.fill ? 'background:' + sh.fill + ';' : '') +
                (sh.borderWidth > 0 ? 'border:' + sh.borderWidth + 'pt solid ' + sh.borderColor + ';' : '') +
                '"></div>'
            );
        }
        return model.html != null ? model.html : model.text || '';
    }

    handleToolSelect(event) {
        this.activeTool = event.currentTarget.dataset.tool;
    }

    /** Click the artboard with the Text tool armed to place a box where you clicked. */
    handleBoardClick(event) {
        const PLACING = ['text', 'table', 'image', 'shape', 'code', 'signature', 'chart'];
        if (PLACING.indexOf(this.activeTool) === -1) {
            if (event.target.classList.contains('dg-board')) {
                this.selectedId = null;
            }
            return;
        }
        const board = event.currentTarget;
        const rect = board.getBoundingClientRect();
        const x = pxToIn(event.clientX - rect.left, this.zoom);
        const y = pxToIn(event.clientY - rect.top, this.zoom);
        const boardId = board.dataset.boardId;
        const target = this.doc.artboards.find((b) => b.id === boardId);
        if (!target) return;
        const tool = this.activeTool;
        let fresh;
        if (tool === 'table') {
            fresh = newTableBox(x, y, Math.min(6.5, this.geo.w - x - 0.2));
        } else if (tool === 'image') {
            fresh = newImageBox(x, y, 1.5, 1);
        } else if (tool === 'shape') {
            fresh = newShapeBox(x, y, 2, 1);
        } else if (tool === 'code') {
            fresh = newCodeBox(x, y);
        } else if (tool === 'chart') {
            fresh = newChartBox(x, y, 4.5, 2.8);
        } else if (tool === 'signature') {
            fresh = newSignatureBox(x, y);
        } else {
            fresh = newTextBox(x, y, 2.5, 0.4);
        }
        this.pushHistory('place');
        const followTarget = this.autoFollowTarget(fresh, target.boxes || []);
        if (followTarget) {
            Object.assign(fresh, this.followPatch(fresh, followTarget));
        }
        const box = clampBox(fresh, this.geo);
        target.boxes = [...target.boxes, box];
        this.doc = { ...this.doc };
        this.selectedId = box.id;
        this.activeTool = 'select';
        // Read the tool from `tool`, not from this.activeTool — that was just reset to
        // 'select' above, so the status line always said "Text box placed".
        const LABELS = {
            table: 'Table',
            image: 'Image',
            shape: 'Shape',
            code: 'Code',
            signature: 'Signature',
            text: 'Text box'
        };
        this.statusText = followTarget
            ? (LABELS[tool] || 'Box') + ' placed, following ' + boxLabel(followTarget)
            : (LABELS[tool] || 'Box') + ' placed';
        if (tool === 'image') {
            this.loadImageLibrary();
        }
    }

    autoFollowTarget(box, siblings) {
        if (!box || box.positionMode === 'follows') {
            return null;
        }
        const overlapsX = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w;
        return (
            (siblings || [])
                .filter((candidate) => candidate && candidate.id !== box.id)
                .filter((candidate) => overlapsX(box, candidate))
                .filter((candidate) => box.y >= candidate.y + this.screenBoxHeightIn(candidate))
                .sort((a, b) => {
                    const aBottom = a.y + this.screenBoxHeightIn(a);
                    const bBottom = b.y + this.screenBoxHeightIn(b);
                    return bBottom - aBottom;
                })[0] || null
        );
    }

    followPatch(box, target) {
        const visualGap = Math.max(0, box.y - (target.y + this.screenBoxHeightIn(target)));
        return {
            positionMode: 'follows',
            anchorTo: target.id,
            y: Math.round((target.y + target.h + visualGap) * 1000) / 1000
        };
    }

    handleBoxMouseDown(event) {
        // Let the inner editor own its own clicks — dragging from inside the text
        // would fight text selection.
        // Let the textarea own its own clicks — dragging from inside the text would
        // fight text selection and caret placement.
        if (event.target.classList.contains('dg-cbox-body')) {
            this.selectedId = event.currentTarget.dataset.id;
            return;
        }
        event.preventDefault();
        const id = event.currentTarget.dataset.id;
        this.selectedId = id;
        const handle = event.target.dataset.handle || null;
        const box = this.selectedBox;
        if (!box) return;
        // Snapshot at mousedown, so a drag is one undo step rather than one per
        // mousemove — applyToBox coalescing alone would still split a slow drag.
        this.pushHistory('drag:' + id);
        this._drag = {
            id,
            handle,
            startX: event.clientX,
            startY: event.clientY,
            origin: { x: box.x, y: box.y, w: box.w, h: box.h }
        };
        this._onMove = (e) => this.onDragMove(e);
        this._onUp = () => this.onDragEnd();
        window.addEventListener('mousemove', this._onMove, true);
        window.addEventListener('mouseup', this._onUp, true);
    }

    onDragMove(e) {
        const d = this._drag;
        if (!d) return;
        // The whole drag was already recorded at mousedown.
        this._suppressHistory = true;
        const dx = pxToIn(e.clientX - d.startX, this.zoom);
        const dy = pxToIn(e.clientY - d.startY, this.zoom);
        const next = { ...d.origin };
        if (d.handle === 'se') {
            next.w = Math.max(0.3, d.origin.w + dx);
            next.h = Math.max(0.2, d.origin.h + dy);
        } else if (d.handle === 'e') {
            next.w = Math.max(0.3, d.origin.w + dx);
        } else if (d.handle === 's') {
            next.h = Math.max(0.2, d.origin.h + dy);
        } else {
            next.x = d.origin.x + dx;
            next.y = d.origin.y + dy;
            // Snap only when MOVING. Snapping a resize would fight the author trying to
            // set an exact width, which is the one thing this editor promises.
            const others = [];
            for (const board of this.doc.artboards) {
                for (const b of board.boxes) {
                    if (b.id !== d.id) others.push(b);
                }
            }
            const snapped = snapBox({ ...next, w: d.origin.w, h: d.origin.h }, others, this.geo);
            next.x = snapped.x;
            next.y = snapped.y;
            this.guides = snapped.guides;
        }
        this.applyToBox(d.id, next);
    }

    onDragEnd() {
        this._suppressHistory = false;
        window.removeEventListener('mousemove', this._onMove, true);
        window.removeEventListener('mouseup', this._onUp, true);
        this._drag = null;
        this.guides = [];
    }

    applyToBox(id, patch) {
        // One snapshot per RUN of same-kind edits (see pushHistory) — the patch keys
        // identify the kind, so typing coalesces while a move and a recolour stay
        // separate undo steps.
        this.pushHistory('box:' + id + ':' + Object.keys(patch).sort().join(','));
        const geo = this.geo;
        this.doc = {
            ...this.doc,
            artboards: this.doc.artboards.map((board) => ({
                ...board,
                boxes: board.boxes.map((b) => (b.id === id ? clampBox({ ...b, ...patch }, geo) : b))
            }))
        };
    }

    /**
     * Commits the text box's own contenteditable content back to the model.
     *
     * This is the ONE place a DOM read feeds the document, and it is scoped to a
     * single box — the browser's contenteditable restructuring cannot escape it, so
     * it cannot corrupt the document the way reading back a whole canvas can.
     */
    // The selection-mark toolbar that used to live here is gone with the textarea.
    // Formatting is now the rich-text editor's job, which does it against a real
    // selection instead of by wrapping the text in markers the author could see.

    /** Content for the panel editor — the selected box's markup. */
    get richTextValue() {
        const box = this.selectedBox;
        if (!box || box.kind === 'table') {
            return '';
        }
        return box.html != null ? box.html : box.text || '';
    }

    /**
     * Typography controls belong to TABLES only.
     *
     * A text box gets its font, size, weight, colour and alignment from the rich-text
     * editor, applied to whatever the author selected. Repeating those as box-level
     * controls gave two places to set the same thing with different scopes, and the
     * box-level one silently won on save — the definition of a confusing panel.
     *
     * A table has no rich-text editor: its cells hold merge tags, so the typography
     * has to be set for the box and pushed onto the cells. That is why the controls
     * stay for tables and go for text.
     */
    get showBoxTypography() {
        return this.selectedIsTable;
    }

    /**
     * Fill, border and padding on the box wrapper. Hidden for a shape, which has its
     * own fill and border — two sets of controls writing to different properties, both
     * labelled "Fill", is a guessing game rather than an editor.
     */
    get showBoxChrome() {
        const box = this.selectedBox;
        return !!box && box.kind !== 'shape';
    }

    /**
     * Only formats the PDF engine actually renders.
     *
     * link and image are deliberately absent: a link is dead in a printed document and
     * an inline image from this editor is a data URI, which Blob.toPdf rejects
     * outright — it renders as a broken box. Offering a control that silently produces
     * nothing is worse than not offering it, and images belong on the canvas as their
     * own box where they can be positioned.
     */
    get richTextFormats() {
        return [
            'font',
            'size',
            'bold',
            'italic',
            'underline',
            'strike',
            'list',
            'indent',
            'align',
            'color',
            'background',
            'header',
            'clean',
            'table'
            // 'link' is deliberately absent, and links are still supported — see the
            // Link control in the panel.
            //
            // The editor's own link button opens an absolutely-positioned overlay that
            // this column clips: the panel scrolls, and a scrolling box clips on BOTH
            // axes, so the overlay lost its left edge and its URL field could not be
            // reached. Widening the column moved the problem without solving it. The
            // panel control below cannot be clipped because it is ordinary content, so
            // it works regardless of where an overlay would have opened.
        ];
    }

    /**
     * Only a TEXT box has text to edit.
     *
     * This used to be "anything that is not a table", which put a rich-text editor
     * under every image and shape — a content field for objects that have no content,
     * where anything typed would be silently discarded by the serializer.
     */
    // ---- Rich text / HTML source ------------------------------------------
    //
    // A text box holds real markup, and the rich-text toolbar can only reach part of
    // it. Tables are the obvious case — the editor has no table button, but the
    // serializer and the PDF engine both handle tables fine — so without a way to type
    // markup directly, a whole class of layout is unreachable inside a box.
    //
    // The source view is the SAME html the rich-text view edits, sanitized on the way
    // in, so the two cannot drift and neither can smuggle markup the engine will not
    // render.
    @track sourceMode = false;

    get showSourceEditor() {
        return this.canEditRichText && this.sourceMode;
    }

    get showRichEditor() {
        return this.canEditRichText && !this.sourceMode;
    }

    get isSourceMode() {
        return this.sourceMode;
    }

    get isRichMode() {
        return !this.sourceMode;
    }

    get richModeClass() {
        return this.sourceMode ? 'dg-sbtn' : 'dg-sbtn dg-sbtn_on';
    }

    get sourceModeClass() {
        return this.sourceMode ? 'dg-sbtn dg-sbtn_on' : 'dg-sbtn';
    }

    handleShowRich() {
        this.sourceMode = false;
        // Re-seed: the selection has not changed, so the usual re-seed will not fire,
        // and edits just made in the HTML view would otherwise be invisible here — the
        // editor would show what the box held before the source edit and write that
        // stale text back on the next keystroke.
        this.richSeed = this.richTextValue;
    }

    handleShowSource() {
        this.sourceMode = true;
    }

    // ---- Link ------------------------------------------------------------
    @track linkText = '';
    @track linkUrl = '';

    get canInsertLink() {
        return !!this.selectedBox && this.canEditRichText;
    }

    get linkInsertDisabled() {
        return !(this.linkText || '').trim() || !this.isSafeLinkUrl;
    }

    /** http, https and in-document anchors — the three the PDF turns into annotations. */
    get isSafeLinkUrl() {
        const v = (this.linkUrl || '').trim();
        return v.startsWith('#') || /^https?:\/\//i.test(v);
    }

    get linkUrlHint() {
        const v = (this.linkUrl || '').trim();
        if (!v) {
            return 'https://example.com, or #anchor to jump within the document.';
        }
        if (this.isSafeLinkUrl) {
            return 'Clickable in the PDF.';
        }
        if (/^mailto:/i.test(v)) {
            return 'mailto: renders as text — the PDF engine makes no link for it.';
        }
        return 'Only http, https and #anchors become clickable links.';
    }

    handleLinkTextChange(event) {
        this.linkText = event.target.value;
    }

    handleLinkUrlChange(event) {
        this.linkUrl = event.target.value;
    }

    /**
     * Appends a link to the box's content.
     *
     * Appends rather than wrapping a selection because the selection lives inside the
     * rich-text editor's shadow DOM and is not reachable from here. Adding the link and
     * letting the author move it is a smaller compromise than a control that cannot be
     * used at all, which is what the editor's own overlay amounted to in this column.
     */
    handleInsertLink() {
        const box = this.selectedBox;
        if (!box || this.linkInsertDisabled) {
            return;
        }
        const url = this.linkUrl.trim();
        const text = this.linkText.trim();
        const current = box.html != null ? box.html : box.text || '';
        const sep = current && !/(\s|>)$/.test(current) ? ' ' : '';
        const anchor = '<a href="' + this.escAttr(url) + '">' + this.escAttr(text) + '</a>';
        this.applyToBox(box.id, { html: sanitizeInline(current + sep + anchor) });
        this.linkText = '';
        this.linkUrl = '';
        this.statusText = 'Link added';
    }

    // ---- Table inside a text box -----------------------------------------
    //
    // The Table TOOL is the right answer for a data table — it binds a relationship,
    // loops, totals and stays editable. This is for the other case: a small fixed table
    // inside a paragraph of text, where a whole box would be overkill.
    //
    // Built here rather than left to the editor's toolbar because that toolbar belongs
    // to lightning-input-rich-text and what it offers is not ours to change. `table` is
    // already in the formats we pass, so nothing on our side is holding it back.
    @track tableRows = 2;
    @track tableCols = 2;

    handleTableRowsChange(event) {
        const v = parseInt(event.target.value, 10);
        if (!isNaN(v) && v > 0) this.tableRows = Math.min(20, v);
    }

    handleTableColsChange(event) {
        const v = parseInt(event.target.value, 10);
        if (!isNaN(v) && v > 0) this.tableCols = Math.min(10, v);
    }

    /** Matches the canvas table look: banded header, rules under rows, no vertical lines. */
    handleInsertTable() {
        const box = this.selectedBox;
        if (!box) {
            return;
        }
        const rows = this.tableRows;
        const cols = this.tableCols;
        const head =
            'border: 0; border-bottom: 1pt solid #d5dde6; padding: 6pt; ' +
            'font-size: 10.5pt; color: #ffffff; font-weight: bold; background: #1f3a5f;';
        const cell = 'border: 0; border-bottom: 0.75pt solid #d5dde6; padding: 6pt; font-size: 11pt;';
        let html = '<table style="width: 100%; border-collapse: collapse;"><thead><tr>';
        for (let c = 0; c < cols; c++) {
            html += '<th style="' + head + '">Heading ' + (c + 1) + '</th>';
        }
        html += '</tr></thead><tbody>';
        for (let r = 0; r < rows; r++) {
            html += '<tr>';
            for (let c = 0; c < cols; c++) {
                html += '<td style="' + cell + '">&nbsp;</td>';
            }
            html += '</tr>';
        }
        html += '</tbody></table>';
        const current = box.html != null ? box.html : box.text || '';
        this.applyToBox(box.id, { html: sanitizeInline(current + html) });
        this.statusText = rows + 'x' + cols + ' table added';
    }

    // ---- Symbols ---------------------------------------------------------
    //
    // Offered because typing one directly is a trap: under the generic families a
    // checkmark renders as NOTHING — no glyph, no substitute — and the author finds
    // out from a customer. Inserted from here it carries the font that draws it.
    get safeSymbols() {
        return SAFE_SYMBOLS.map((sym) => ({ ...sym, key: sym.name }));
    }

    handleInsertSymbol(event) {
        const box = this.selectedBox;
        if (!box) {
            return;
        }
        const name = event.currentTarget.dataset.name;
        const sym = SAFE_SYMBOLS.find((x) => x.name === name);
        if (!sym) {
            return;
        }
        // symbolMarkup wraps the ones the base fonts cannot draw in the Unicode face,
        // so a checkmark renders whatever the box's own font is set to.
        const current = box.html != null ? box.html : box.text || '';
        this.applyToBox(box.id, { html: sanitizeInline(current + symbolMarkup(sym)) });
        this.reseedEditor();
        this.statusText = 'Inserted ' + sym.name;
    }

    handleSourceChange(event) {
        const box = this.selectedBox;
        if (!box) return;
        // Sanitized like any other authored markup: a paste from a web page must not
        // put an absolutely-positioned div inside an artboard whose whole layout
        // contract is position.
        this.applyToBox(box.id, { html: sanitizeInline(event.target.value) });
    }

    get canEditRichText() {
        const box = this.selectedBox;
        return !!box && (box.kind === 'text' || !box.kind);
    }

    /**
     * The box's content is authored HERE, not on the artboard.
     *
     * Moving editing into the panel removes three problems at once.
     * lightning-input-rich-text is a real Salesforce input, so Lightning's "/" hotkey
     * leaves it alone — no document-capture interceptor, no focus recovery, neither of
     * which I could make work reliably on the artboard. The artboard can then render
     * the formatted result read-only, so what you see is finally what prints. And the
     * value is read off a supported base component instead of scraped out of a
     * contenteditable, which is the exact thing LWS keeps distorting in docGenAdmin.
     *
     * Sanitised on the way in: the editor emits more than the PDF engine honours.
     */
    /**
     * The value the editor is SEEDED with — set when the selection changes, never while
     * typing.
     *
     * Binding the model straight back into the editor is what threw the caret to the
     * start on every keystroke: each character fired change, the model updated, the
     * getter returned a new string, LWC pushed it into the component, and the editor
     * rebuilt its contents from scratch — losing the cursor with them. It is the same
     * reason the box bodies on the artboard are written manually and only when they
     * differ.
     *
     * So the editor is left alone while it has focus. It is the source of truth for its
     * own text; the model is the source of truth for everything else.
     */
    @track richSeed = '';

    get richEditorValue() {
        return this.richSeed;
    }

    handleRichTextChange(event) {
        const box = this.selectedBox;
        if (!box) {
            return;
        }
        // Deliberately does NOT touch richSeed — see above.
        this.applyToBox(box.id, { html: sanitizeInline(event.target.value) });
    }

    // The "/" workaround that used to live here is gone. Nothing is typed on the
    // artboard any more; text is authored in the panel's rich-text editor, which
    // Lightning already exempts from its global hotkeys, so the problem that needed an
    // interceptor and a focus recovery simply does not arise on this surface.

    handleModeToggle() {
        const box = this.selectedBox;
        if (!box) return;
        this.applyToBox(box.id, { mode: box.mode === 'flow' ? 'pinned' : 'flow' });
        this.statusText =
            box.mode === 'flow'
                ? 'Pinned — lands exactly here, does not repeat on continuation pages'
                : 'Flows — content can grow and spill onto following pages';
    }

    // ---- Position: where a box goes when the content above it grows --------
    //
    // Three answers to one question, so one control rather than two. The model keeps
    // them on separate fields — `mode` is pinned/flow, `positionMode`+`anchorTo` is the
    // link — but an author choosing between "stays put", "flows" and "follows that" is
    // making a single decision, and surfacing it as two independent toggles is how the
    // panel ended up reporting a linked box as "Pinned".

    /** Every box on the same page as the selection, by id. Links do not cross pages. */
    get _siblingsById() {
        const map = new Map();
        const board = this._boardOf(this.selectedId);
        for (const b of (board && board.boxes) || []) {
            map.set(b.id, b);
        }
        return map;
    }

    _boardOf(boxId) {
        return this.doc.artboards.find((b) => b.boxes.some((x) => x.id === boxId)) || null;
    }

    get positionModeOptions() {
        return [
            { label: 'Stays put', value: 'pinned' },
            { label: 'Flows down the page', value: 'flow' },
            { label: 'Follows another element', value: 'follows' }
        ];
    }

    get selectedPositionMode() {
        const b = this.selectedBox;
        if (!b) {
            return 'pinned';
        }
        if (b.positionMode === 'follows') {
            return 'follows';
        }
        return b.mode === 'flow' ? 'flow' : 'pinned';
    }

    get isSelectedFollowing() {
        return this.selectedPositionMode === 'follows';
    }

    /**
     * What this box may be linked to.
     *
     * Itself and anything that would close a loop are left out entirely rather than
     * shown disabled — a combobox cannot disable one option, and an author who picks a
     * greyed-looking row and gets nothing has learned nothing. Same page only, because
     * a group is emitted inside one artboard.
     */
    get anchorOptions() {
        const box = this.selectedBox;
        if (!box) {
            return [];
        }
        const byId = this._siblingsById;
        const opts = [];
        for (const cand of byId.values()) {
            if (cand.id === box.id || wouldCycle(box, cand.id, byId)) {
                continue;
            }
            opts.push({ label: boxLabel(cand), value: cand.id, y: cand.y });
        }
        // Down the page, which is the order the author is looking at.
        opts.sort((a, b) => a.y - b.y);
        return opts.map((o) => ({ label: o.label, value: o.value }));
    }

    get selectedAnchorId() {
        const b = this.selectedBox;
        return (b && b.anchorTo) || '';
    }

    get selectedKeepTogether() {
        const b = this.selectedBox;
        return !!(b && b.keepTogether);
    }

    get hasAnchorOptions() {
        return this.anchorOptions.length > 0;
    }

    /**
     * Anything wrong with the current link, in the author's words.
     *
     * A dangling anchor is the case that matters: the target was deleted, so the box
     * silently stopped travelling. Nothing else in the editor would say so.
     */
    get anchorIssue() {
        const box = this.selectedBox;
        if (!box || box.positionMode !== 'follows') {
            return null;
        }
        if (!box.anchorTo) {
            return 'Pick the element this should follow. Until you do, it stays where it is.';
        }
        const byId = this._siblingsById;
        if (!byId.has(box.anchorTo)) {
            return 'The element this followed has been deleted, so it no longer moves. Pick another.';
        }
        if (!anchorRoot(box, byId)) {
            return 'This link loops back on itself, so it cannot be followed. Pick a different element.';
        }
        return null;
    }

    /** "Follows the Contacts table" — the one line that says what the link does. */
    get anchorSummary() {
        const box = this.selectedBox;
        if (!box || box.positionMode !== 'follows' || !box.anchorTo) {
            return '';
        }
        const target = this._siblingsById.get(box.anchorTo);
        return target ? boxLabel(target) : '';
    }

    handlePositionModeChange(event) {
        const box = this.selectedBox;
        if (!box) {
            return;
        }
        const next = event.detail ? event.detail.value : event.target.value;
        if (next === 'follows') {
            // Default to the nearest element ABOVE, which is what "follows" almost
            // always means and saves a second interaction. Falls back to the first
            // legal target when there is nothing above.
            const above = this.anchorOptions
                .map((o) => this._siblingsById.get(o.value))
                .filter((b) => b && b.y <= box.y)
                .pop();
            const pick = (above && above.id) || (this.anchorOptions[0] || {}).value || '';
            const target = this._siblingsById.get(pick);
            this.applyToBox(
                box.id,
                target ? this.followPatch(box, target) : { positionMode: 'follows', anchorTo: pick }
            );
            this.statusText = target
                ? 'Now follows ' + boxLabel(target)
                : 'Set to follow — pick the element it should travel with';
            return;
        }
        // Leaving 'follows' clears the anchor rather than keeping it around to be
        // re-applied invisibly if the mode is switched back.
        this.applyToBox(box.id, {
            positionMode: 'fixed',
            anchorTo: '',
            keepTogether: false,
            mode: next === 'flow' ? 'flow' : 'pinned'
        });
        this.statusText =
            next === 'flow'
                ? 'Flows — content can grow and spill onto following pages'
                : 'Stays put — lands exactly here';
    }

    handleAnchorChange(event) {
        const box = this.selectedBox;
        if (!box) {
            return;
        }
        const id = event.detail ? event.detail.value : event.target.value;
        // Belt and braces: the picker already excludes these, but a stale option could
        // still arrive if the target was deleted between render and change.
        if (!id || id === box.id || wouldCycle(box, id, this._siblingsById)) {
            this.statusText = 'That element cannot be followed — it would loop back on itself';
            return;
        }
        const target = this._siblingsById.get(id);
        this.applyToBox(box.id, target ? this.followPatch(box, target) : { positionMode: 'follows', anchorTo: id });
        this.statusText = target ? 'Now follows ' + boxLabel(target) : 'Link updated';
    }

    handleKeepTogetherChange(event) {
        const box = this.selectedBox;
        if (!box) {
            return;
        }
        this.applyToBox(box.id, { keepTogether: !!event.target.checked });
    }

    /**
     * Removes a page and everything on it.
     *
     * Refuses to remove the last one: a document with no artboard has nowhere to put a
     * box, and the canvas would render an empty void with no way back except reload.
     * Confirmed when the page has content, because this is the only destructive action
     * in the editor and there is no undo yet.
     */
    handleDeleteArtboard(event) {
        const id = event.currentTarget.dataset.boardId;
        const boards = this.doc.artboards || [];
        if (boards.length <= 1) {
            this.statusText = 'A document needs at least one page';
            return;
        }
        const board = boards.find((b) => b.id === id);
        const count = board ? (board.boxes || []).length : 0;
        if (count > 0) {
            // eslint-disable-next-line no-alert
            const ok = window.confirm(
                'Delete this page and the ' + count + (count === 1 ? ' box' : ' boxes') + ' on it?'
            );
            if (!ok) {
                return;
            }
        }
        this.pushHistory('delete-page');
        this.doc = { ...this.doc, artboards: boards.filter((b) => b.id !== id) };
        if (board && (board.boxes || []).some((b) => b.id === this.selectedId)) {
            this.selectedId = null;
        }
        this.statusText = 'Page deleted';
    }

    handleAddArtboard() {
        this.pushHistory('add-page');
        this.doc = { ...this.doc, artboards: [...this.doc.artboards, newArtboard()] };
        this.statusText = 'Page added';
    }

    handleDelete() {
        if (!this.selectedId) return;
        this.pushHistory('delete-box');
        this.doc = {
            ...this.doc,
            artboards: this.doc.artboards.map((b) => ({
                ...b,
                boxes: b.boxes.filter((x) => x.id !== this.selectedId)
            }))
        };
        this.selectedId = null;
    }

    handleZoom(event) {
        const dir = event.currentTarget.dataset.dir;
        const next = dir === 'in' ? this.zoom + 0.1 : this.zoom - 0.1;
        this.zoom = Math.min(2, Math.max(0.4, Math.round(next * 10) / 10));
    }

    get boxCount() {
        return (this.doc.artboards || []).reduce((n, b) => n + (b.boxes || []).length, 0);
    }

    async handleSave() {
        if (!this.templateId) {
            this.saveError = 'No template id — cannot save.';
            this._saveOk = false;
            return;
        }
        // Catch the empty case HERE, with an explanation. The server refuses to
        // overwrite a real body with an empty one — a guard that exists because a read
        // failure once destroyed someone's document — but it can only tell you after
        // the round trip, and only in a status line. If the canvas has no boxes, the
        // likely cause is that it opened without loading them, and saving would be the
        // destructive move.
        if (this.boxCount === 0) {
            this._saveOk = false;
            this.saveError =
                'Nothing to save — this canvas has no boxes. If the template had content, it did not load: ' +
                'close and reopen it rather than saving over it.';
            return;
        }
        this.saveError = null;
        this._saveOk = false;
        this.isSaving = true;
        try {
            const html = serialize(this.doc, this.geo);
            const res = await saveAndPublishHtmlBody({
                templateId: this.templateId,
                fileName: 'canvas.html',
                htmlContent: html,
                // A new version per save, so the picker can actually take you back.
                newVersion: true
            });
            this.statusText = 'Saved as a new version';
            this._saveOk = true;
            this._savedHtml = html;
            // Follow the version that was just created, by ID.
            //
            // Reloading the list and re-deriving "which one is active" would work only
            // if the fresh row is visible and flagged by the time the query runs, and
            // when it was not, the editor stayed pointed at the SUPERSEDED version —
            // so the next reload showed the previous canvas and the save looked lost.
            // The server just told us the id; use it.
            if (res && res.versionId) {
                this.activeVersionId = res.versionId;
            }
            await this.loadVersions();
            if (res && res.versionId) {
                this.activeVersionId = res.versionId;
            }
            // #272 — the linter's warnings ride the save response; hand them to
            // the host so its fidelity report can show them. Extra detail keys
            // are additive — existing 'saved' listeners only read detail.html.
            this.dispatchEvent(new CustomEvent('saved', { detail: { html, warnings: (res && res.warnings) || [] } }));
        } catch (e) {
            // Surfaced as a banner, not a status line: a save that silently did not
            // happen is the single worst thing this editor can do.
            this.saveError = 'Save failed — ' + (e.body ? e.body.message : e.message);
            this.statusText = '';
            this._saveOk = false;
        } finally {
            this.isSaving = false;
        }
    }

    /** Exposed so a host or a test can read exactly what would be stored. */
    @api
    getSerializedHtml() {
        return serialize(this.doc, this.geo);
    }
}
