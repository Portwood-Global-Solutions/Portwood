import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenAdmin/docGenAdmin.js', import.meta.url),
    'utf8'
);
const start = source.indexOf('    handleSignerFieldKeyChange(event)');
const end = source.indexOf('    handleSignerFieldMappedChange(event)', start);
assert.ok(start >= 0 && end > start);
const Admin = new Function('getVersionBody', 'return class Admin {\n' + source.slice(start, end) + '\n}')(
    async ({ versionId }) => {
        assert.equal(versionId, 'active');
        return '<p>{?old_key|fallback}</p>';
    }
);
const editor = new Admin();
editor.signerFields = [{ key: 'old_key', label: 'Old label' }, { key: 'other' }];
editor._signerKeyRenames = {};
editor._buildSignerMergeTag = (key) => '{?' + key + '}';
editor._updateSignerFieldRow = (index, patch) => Object.assign(editor.signerFields[index], patch);
editor.showToast = () => {};
const edit = (key) => {
    const input = {
        dataset: { index: '0' },
        value: key,
        setCustomValidity(error) {
            this.error = error;
        },
        reportValidity() {}
    };
    editor.handleSignerFieldKeyChange({ currentTarget: input });
    return input.error;
};

assert.match(edit('bad key'), /letters/);
assert.match(edit('OTHER'), /unique/);
assert.equal(editor.hasSignerKeyRenames, false);
assert.equal(edit('new_key'), '');
assert.equal(editor.signerFields[0].label, 'Old label');
assert.equal(editor.signerFields[0].mergeTag, '{?new_key}');
assert.equal(
    editor._rewriteSignerTags('{?old_key} {?old_key|fallback} {old_key} {?old_key_suffix} {?other}'),
    '{?new_key} {?new_key|fallback} {old_key} {?old_key_suffix} {?other}'
);
assert.equal(edit('final_key'), '');
assert.equal(editor._rewriteSignerTags('{?old_key} {?other}'), '{?final_key} {?other}');
assert.equal(edit('old_key'), '');
assert.equal(editor.hasSignerKeyRenames, false);
assert.equal(editor._rewriteSignerTags('{?old_key}'), '{?old_key}');
assert.equal(edit('new_key'), '');
editor.editTemplateType = 'HTML';
editor.versions = [{ Id: 'active', isActive: true }];
editor._currentDraftHtml = () => '';
editor._legacyHtmlVersionFileName = (name) => name;
editor.editTemplateHeaderHtml = '<p>{?old_key}</p>';
editor.editTemplateFooterHtml = '<p>{?other}</p>';
editor._processAndSaveHtmlBody = async (_id, body) => {
    assert.equal(body, '<p>{?new_key|fallback}</p>');
};
await editor._stageSignerTagRenames();
assert.equal(editor.editTemplateHeaderHtml, '<p>{?new_key}</p>');
assert.equal(editor.editTemplateFooterHtml, '<p>{?other}</p>');

editor.editTemplateType = 'Word';
await assert.rejects(editor._stageSignerTagRenames(), /source file/);
editor.uploadedContentVersionId = 'replacement';
await editor._stageSignerTagRenames();

console.log(
    'Signer merge tag validation, exact replacement, defaults, repeated renames, and label independence passed.'
);
