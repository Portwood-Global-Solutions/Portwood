import { LightningElement, api } from 'lwc';
import { loadFontFace } from 'c/docGenFontLoader';

/** One list for built-in and exact-revision fonts, with real face previews. */
export default class DocGenFontPicker extends LightningElement {
    @api options = [];
    @api value;
    @api label = 'Font family';
    @api hideLabel = false;
    @api disabled = false;
    @api loading = false;
    @api error;
    open = false;
    query = '';
    popupStyle = '';
    previewErrors = [];
    _previews = new Map();
    _observer;
    _focusSearch = false;
    _connected = false;
    connectedCallback() {
        this._connected = true;
        this._outside = (event) => {
            if (this.open && !event.composedPath().includes(this.hostElement || this.template.host)) this.close(false);
        };
        this._resize = () => this.close(false);
        document.addEventListener('mousedown', this._outside);
        window.addEventListener('resize', this._resize);
    }
    disconnectedCallback() {
        this._connected = false;
        this._observer?.disconnect();
        document.removeEventListener('mousedown', this._outside);
        window.removeEventListener('resize', this._resize);
    }
    get selected() {
        return this.options.find((option) => (this.value != null ? option.value === this.value : option.selected));
    }
    get selectedLabel() {
        return this.selected?.label || 'Choose a font';
    }
    previewStyle(option) {
        if (!option) return '';
        const face = option.fontFace;
        const family = face ? `'${face.previewFamily}'` : option.fontFamily || option.value;
        return `font-family:${family};font-weight:${Number(face?.weight) || 400};font-style:${face?.style === 'italic' ? 'italic' : 'normal'};`;
    }
    get selectedStyle() {
        return this.previewStyle(this.selected);
    }
    get rows() {
        const query = this.query.trim().toLowerCase();
        return this.options
            .filter(
                (option) =>
                    !query ||
                    [option.label, option.fontFace?.family, option.detail].join(' ').toLowerCase().includes(query)
            )
            .map((option) => ({
                ...option,
                selected: option.value === this.selected?.value,
                rowClass: 'font-option' + (option.value === this.selected?.value ? ' font-option_selected' : ''),
                previewStyle: this.previewStyle(option),
                previewError: this.previewErrors.includes(option.value)
            }));
    }
    get noResults() {
        return !this.loading && !this.rows.length;
    }
    get resultCount() {
        return this.query.trim()
            ? `${this.rows.length} of ${this.options.length} fonts`
            : `${this.options.length} fonts`;
    }
    handleCapture(event) {
        // Preserve the document selection before the search box takes focus.
        event.preventDefault();
        this.dispatchEvent(new CustomEvent('capture'));
    }
    handleToggle() {
        if (this.disabled) return;
        if (this.open) this.close(true);
        else this.show();
    }
    show() {
        this.dispatchEvent(new CustomEvent('capture'));
        this.query = '';
        for (const value of this.previewErrors) this._previews.delete(value);
        this.previewErrors = [];
        const rect = this.template.querySelector('.font-trigger').getBoundingClientRect();
        const width = Math.min(340, window.innerWidth - 24);
        const below = window.innerHeight - rect.bottom - 18;
        const above = rect.top - 18;
        const downward = below >= Math.min(300, above);
        this.popupStyle =
            `width:${width}px;left:${Math.max(12, Math.min(rect.left, window.innerWidth - width - 12))}px;max-height:${Math.max(100, Math.min(440, downward ? below : above))}px;` +
            (downward ? `top:${rect.bottom + 6}px;` : `bottom:${window.innerHeight - rect.top + 6}px;`);
        this.open = true;
        this._focusSearch = true;
        this.dispatchEvent(new CustomEvent('open'));
    }
    close(focus) {
        this.open = false;
        this._observer?.disconnect();
        if (focus) this.template.querySelector('.font-trigger')?.focus();
    }
    handleInput(event) {
        this.query = event.target.value;
        const list = this.template.querySelector('.font-list');
        if (list) list.scrollTop = 0;
    }
    handleChoose(event) {
        const value = event.currentTarget.dataset.value;
        const option = this.options.find((item) => item.value === value);
        if (!option || option.disabled) return;
        // Return focus before the host restores and formats its document selection.
        this.close(true);
        this.dispatchEvent(new CustomEvent('change', { detail: { value } }));
    }
    handleKeepSelection(event) {
        event.preventDefault();
    }
    handleInside(event) {
        // LWS can retarget document events beyond this component's host.
        // Internal mouse/focus events must never become outside dismissals.
        event.stopPropagation();
    }
    handleTriggerKeydown(event) {
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            this.dispatchEvent(new CustomEvent('capture'));
            if (!this.open && !this.disabled) this.show();
        }
    }
    handlePopupKeydown(event) {
        if (event.key === 'Tab') {
            this.close(true);
            return;
        }
        if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            this.close(true);
            return;
        }
        if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
        const input = this.template.querySelector('.font-search');
        // Home/End retain their normal text-editing behavior inside search.
        if ((event.key === 'Home' || event.key === 'End') && event.target === input) return;
        const buttons = [...this.template.querySelectorAll('.font-option:not(:disabled)')];
        if (!buttons.length) return;
        event.preventDefault();
        const current = buttons.indexOf(event.target);
        let next =
            event.key === 'Home'
                ? 0
                : event.key === 'End'
                  ? buttons.length - 1
                  : current < 0
                    ? event.key === 'ArrowUp'
                        ? buttons.length - 1
                        : 0
                    : (current + (event.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length;
        buttons[next].focus();
        buttons[next].scrollIntoView({ block: 'nearest' });
    }
    handleRetry() {
        this.dispatchEvent(new CustomEvent('retry'));
    }
    loadPreview(option) {
        if (!option?.fontFace?.previewUrl || this._previews.has(option.value)) return;
        const promise = loadFontFace(option.fontFace).catch(() => {
            if (this._connected) this.previewErrors = [...this.previewErrors, option.value];
        });
        this._previews.set(option.value, promise);
    }
    renderedCallback() {
        this.loadPreview(this.selected);
        this._observer?.disconnect();
        if (!this.open) return;
        if (this._focusSearch) {
            this.template.querySelector('.font-search')?.focus();
            this._focusSearch = false;
        }
        const list = this.template.querySelector('.font-list');
        const buttons = [...this.template.querySelectorAll('.font-option')];
        if (typeof IntersectionObserver === 'undefined') {
            for (const option of this.rows) this.loadPreview(option);
            return;
        }
        this._observer = new IntersectionObserver(
            (entries) => {
                if (!this.open || !this._connected) return;
                for (const entry of entries) {
                    if (!entry.isIntersecting) continue;
                    this.loadPreview(this.options.find((option) => option.value === entry.target.dataset.value));
                    this._observer.unobserve(entry.target);
                }
            },
            { root: list, rootMargin: '80px' }
        );
        for (const button of buttons) this._observer.observe(button);
    }
}
