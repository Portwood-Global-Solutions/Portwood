import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import LightningConfirm from 'lightning/confirm';
import getSnippets from '@salesforce/apex/DocGenSnippetController.getSnippets';
import getSnippet from '@salesforce/apex/DocGenSnippetController.getSnippet';
import saveSnippet from '@salesforce/apex/DocGenSnippetController.saveSnippet';
import getReadiness from '@salesforce/apex/DocGenGettingStartedController.getReadiness';

const slug = (text) =>
    (text || '')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .slice(0, 40)
        .replace(/-+$/, '');
const message = (e) => e?.body?.message || e?.message || 'Could not load shared content. Try again.';
export default class DocGenSnippetAssets extends LightningElement {
    items = [];
    search = '';
    editing = false;
    draft = {};
    dirty = false;
    busy = false;
    error = '';
    status = '';
    mode = 'visual';
    canCreate = false;
    canEdit = false;
    wiredCatalog;
    keyTouched = false;
    @wire(getReadiness) readiness({ data }) {
        if (data) {
            this.canCreate = !!data.canCreateAssets;
            this.canEdit = !!data.canEditAssets;
        }
    }
    @wire(getSnippets) catalog(result) {
        this.wiredCatalog = result;
        if (result.data) this.items = result.data;
        if (result.error) this.error = message(result.error);
    }
    get rows() {
        const q = this.search.toLowerCase().trim();
        return this.items
            .filter((a) => !q || `${a.name} ${a.category || ''} ${a.assetKey}`.toLowerCase().includes(q))
            .map((a) => ({
                ...a,
                state: a.isActive ? 'Active' : 'Inactive',
                categoryLabel: a.category || 'HTML snippet',
                cssClass: a.id === this.draft.id ? 'entry entry_selected' : 'entry'
            }));
    }
    get hasRows() {
        return this.rows.length > 0;
    }
    get canNew() {
        return !this.canCreate || this.busy;
    }
    get readOnly() {
        return this.busy || (this.draft.id ? !this.canEdit : !this.canCreate);
    }
    get saveDisabled() {
        return this.readOnly || this.busy || !this.dirty || !this.draft.name?.trim() || !this.draft.html?.trim();
    }
    get keyDisabled() {
        return !!this.draft.id || this.readOnly;
    }
    get tag() {
        return '{%snippet:' + (slug(this.draft.assetKey || this.draft.name) || 'your-key') + '}';
    }
    get isVisual() {
        return this.mode === 'visual';
    }
    get isSource() {
        return this.mode === 'source';
    }
    get isPreview() {
        return this.mode === 'preview';
    }
    get visualVariant() {
        return this.isVisual ? 'brand' : 'neutral';
    }
    get sourceVariant() {
        return this.isSource ? 'brand' : 'neutral';
    }
    get previewVariant() {
        return this.isPreview ? 'brand' : 'neutral';
    }
    get formats() {
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
            'link',
            'color',
            'background',
            'table',
            'header'
        ];
    }
    get historyOptions() {
        return (this.draft.history || []).map((v) => ({
            label: `Revision ${v.number} · ${new Date(v.createdAt).toLocaleString()}`,
            value: v.id
        }));
    }
    get hasHistory() {
        return this.historyOptions.length > 0;
    }
    get isOldRevision() {
        return this.draft.versionId && this.draft.versionId !== this.draft.currentVersionId;
    }
    get saveLabel() {
        return this.draft.id ? 'Save new revision' : 'Create shared content';
    }
    get revisionLabel() {
        return this.draft.versionNumber ? `Revision ${this.draft.versionNumber}` : 'New shared content';
    }
    handleSearch(e) {
        this.search = e.target.value;
    }
    async leaveDraft() {
        if (!this.dirty) return true;
        return LightningConfirm.open({
            message: 'Discard your unsaved shared content edits?',
            label: 'Unsaved changes',
            variant: 'headerless'
        });
    }
    async handleNew() {
        if (!(await this.leaveDraft())) return;
        this.draft = {
            name: '',
            assetKey: '',
            category: 'Terms & Conditions',
            html: '<h2>Terms &amp; conditions</h2><p>Add your reusable content here.</p>',
            isActive: true
        };
        this.editing = true;
        this.dirty = true;
        this.keyTouched = false;
        this.mode = 'visual';
        this.error = '';
        this.status = '';
    }
    async handleSelect(e) {
        if (!(await this.leaveDraft())) return;
        await this.load(e.currentTarget.dataset.id);
    }
    async load(assetId, versionId = null) {
        this.busy = true;
        this.error = '';
        this.status = '';
        try {
            this.draft = await getSnippet({ assetId, versionId });
            this.editing = true;
            this.dirty = false;
            this.keyTouched = true;
        } catch (e) {
            this.error = message(e);
        } finally {
            this.busy = false;
        }
    }
    handleField(e) {
        const field = e.target.dataset.field;
        const value = field === 'isActive' ? e.target.checked : e.target.value;
        this.draft = { ...this.draft, [field]: value };
        if (field === 'assetKey') this.keyTouched = true;
        if (field === 'name' && !this.draft.id && !this.keyTouched) this.draft.assetKey = slug(value);
        this.dirty = true;
        this.status = '';
    }
    handleHtml(e) {
        this.draft = { ...this.draft, html: e.detail.value };
        this.dirty = true;
        this.status = '';
    }
    handleMode(e) {
        this.mode = e.currentTarget.dataset.mode;
    }
    async handleRevision(e) {
        if (!(await this.leaveDraft())) return;
        await this.load(this.draft.id, e.detail.value);
    }
    handleRestore() {
        this.dirty = true;
        this.status = 'This revision is ready to restore. Save a new revision to publish it.';
    }
    async handleSave() {
        this.busy = true;
        this.error = '';
        this.status = '';
        try {
            const d = this.draft;
            this.draft = await saveSnippet({
                assetId: d.id || null,
                name: d.name,
                assetKey: d.assetKey,
                category: d.category || '',
                html: d.html,
                expectedVersionId: d.currentVersionId || null,
                isActive: !!d.isActive
            });
            this.dirty = false;
            this.status = 'Saved. Future documents using this tag will use this revision.';
            await refreshApex(this.wiredCatalog);
        } catch (e) {
            this.error = message(e);
        } finally {
            this.busy = false;
        }
    }
    async handleCopy() {
        try {
            await navigator.clipboard.writeText(this.tag);
            this.status = 'Tag copied. Paste it on its own line in an HTML template or Designer.';
        } catch {
            this.status = 'Select and copy the tag shown below.';
        }
    }
}
