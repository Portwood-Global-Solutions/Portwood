import { LightningElement, api } from 'lwc';
import DOCGEN_LOGO from '@salesforce/resourceUrl/DocGenLogo';

/** A quiet, stable editing shell. The host owns the document and every mutation. */
export default class DocGenDesignerWorkspace extends LightningElement {
    @api templateName;
    @api stage = 'document';
    @api dirty = false;
    @api busy = false;
    @api formatBusy = false;
    @api undoDisabled = false;
    @api redoDisabled = false;
    @api previewBusy = false;
    @api pdfDisplayed = false;
    @api zoomOptions = [];
    @api fontOptions = [];
    @api fontsLoading = false;
    @api fontError;
    @api fontSize = 11;
    @api formatState = {};
    @api objectApiName;
    @api recordId;
    @api realObject = false;
    @api panelOpen = false;
    @api sourceMode = false;
    @api sourceWrap = false;
    @api agentforceAvailable = false;
    @api statusText;
    @api notice;
    @api reviewCount = 0;
    _selection = {};
    @api get selection() {
        return this._selection;
    }
    set selection(value) {
        this._selection = value || {};
        this.positionX = this._selection.x || 0;
        this.positionY = this._selection.y || 0;
        this.positionWidth = this._selection.width || 3;
    }
    positionX = 0;
    positionY = 0;
    positionWidth = 3;
    logoUrl = DOCGEN_LOGO;
    get toolbarClass() {
        return 'format' + (this.pdfDisplayed ? ' pdf-view' : '');
    }
    get isPreview() {
        return this.stage === 'preview';
    }
    get isEditing() {
        return !this.isPreview;
    }
    get visualSelected() {
        return !this.sourceMode;
    }
    get modeDisabled() {
        return this.busy || this.formatBusy;
    }
    get isVisualEditing() {
        return this.isEditing && !this.sourceMode;
    }
    get isSourceEditing() {
        return this.isEditing && this.sourceMode;
    }
    get backToEditingLabel() {
        return this.sourceMode ? 'Back to HTML' : 'Back to editing';
    }
    handleMode(event) {
        this.emit('mode', event.currentTarget.dataset.mode);
    }
    get hasSelection() {
        return !!this._selection.label;
    }
    get imageSelected() {
        return !!this._selection.image;
    }
    get imageWidth() {
        return this._selection.imageWidth || 1;
    }
    get formattingDisabled() {
        return this.formatBusy || (!!this._selection.image && !this._selection.table);
    }
    get tableSelected() {
        return !!this._selection.table;
    }
    get fixedSelected() {
        return !!this._selection.fixed;
    }
    get flowSelected() {
        return !this._selection.fixed;
    }
    get cannotMoveUp() {
        return !this._selection.canUp;
    }
    get cannotMoveDown() {
        return !this._selection.canDown;
    }
    get undoBlocked() {
        return this.undoDisabled || this.sourceMode || this.formatBusy;
    }
    get redoBlocked() {
        return this.redoDisabled || this.sourceMode || this.formatBusy;
    }
    get saveDisabled() {
        return this.busy || this.formatBusy || !this.dirty;
    }
    get status() {
        return this.formatBusy
            ? 'Applying font…'
            : this.busy
              ? 'Saving…'
              : this.dirty
                ? 'Unsaved changes'
                : this.statusText || 'Saved';
    }
    get modeLabel() {
        return this.sourceMode ? 'Visual editor' : 'HTML source';
    }
    get noGuide() {
        return this.panelOpen;
    }
    get previewDisabled() {
        return this.previewBusy || this.formatBusy;
    }
    get pdfLabel() {
        return this.previewBusy ? 'Creating preview…' : 'Generate PDF';
    }
    get boldPressed() {
        return !!this.formatState.bold;
    }
    get italicPressed() {
        return !!this.formatState.italic;
    }
    get underlinePressed() {
        return !!this.formatState.underline;
    }
    get hasReview() {
        return this.reviewCount > 0;
    }
    get reviewLabel() {
        return 'PDF notes (' + this.reviewCount + ')';
    }
    get noticeClass() {
        return 'notice ' + (this.notice?.variant === 'error' ? 'notice-error' : 'notice-help');
    }
    get noticeRole() {
        return this.notice?.variant === 'error' ? 'alert' : 'status';
    }
    emit(action, value, extra = {}) {
        this.dispatchEvent(new CustomEvent('workspacecommand', { detail: { action, value, ...extra } }));
    }
    handleAction(event) {
        const menu = event.currentTarget.closest('details.more');
        if (menu) menu.open = false;
        this.emit(event.currentTarget.dataset.action, event.currentTarget.dataset.value, {
            option: event.currentTarget.dataset.option,
            command: event.currentTarget.dataset.command
        });
    }
    handleImageWidth(event) {
        this.emit('image-width', event.currentTarget.value);
    }
    handleKeydown(event) {
        if (event.key === 'Escape') {
            const menu = this.template.querySelector('details.more[open]');
            if (menu) {
                menu.open = false;
                menu.querySelector('summary').focus();
                event.stopPropagation();
            }
        }
    }
    handleMenu(event) {
        this.emit(event.detail.value);
    }
    handleZoom(event) {
        this.emit('zoom', event.target.value);
    }
    handleFont(event) {
        this.emit('font', event.detail.value);
    }
    handleFontRetry() {
        this.emit('reload-fonts');
    }
    handleSize(event) {
        this.emit('size', event.target.value);
    }
    handleColor(event) {
        this.emit('format', event.target.value, { command: event.currentTarget.dataset.command });
    }
    handleRecord(event) {
        this.emit('record', event.detail.recordId);
    }
    captureSelection() {
        this.emit('capture');
    }
    keepSelection(event) {
        event.preventDefault();
    }
    handlePositionInput(event) {
        this[event.target.dataset.property] = Number(event.target.value);
    }
    handlePositionMode(event) {
        this.emit('position-mode', event.target.value);
    }
    handlePositionApply() {
        this.emit('position', null, { box: { x: this.positionX, y: this.positionY, width: this.positionWidth } });
    }
}
