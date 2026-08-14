/**
 * Watermark opacity — changing it after upload must do something, or say why not.
 *
 *   node scripts/qa/watermark-opacity-route-check.mjs
 *
 * Issue #313, reported by untangleportwood:
 *
 *   "When I try to update the Watermark percentage after I uploaded the image it
 *    doesn't update this value. It works when I change it before I upload the file."
 *
 * The order-dependence is the whole diagnosis. Opacity is baked into the PNG's
 * PIXELS at upload time — Flying Saucer has no CSS opacity, so pre-multiplied
 * alpha is the only thing that renders — which means once an image is stored the
 * control has nothing left to act on. Changing it updated a field nobody read.
 *
 * Re-baking the STORED image is not a fix: 30% of an already-30% wash is 9%, and
 * every change would compound. The original is the only correct source, so the
 * unbaked file is retained for the session.
 *
 * This asserts the routing — which of the three situations each change lands in —
 * because that is where the silence was.
 */

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

/**
 * Mirrors docGenAdmin.handleWatermarkOpacityChange.
 * Returns what the component does: 'stored-for-upload' | 'rebaked' | 'told-to-reupload'.
 */
function onOpacityChange(state, pct) {
    state.watermarkOpacityPct = pct;
    if (!state.editTemplateWatermarkCvId) {
        return 'stored-for-upload';
    }
    if (!state._watermarkSourceFile) {
        return 'told-to-reupload';
    }
    // Re-bakes from the ORIGINAL, never from the stored (already-washed) image.
    state.bakedFrom = state._watermarkSourceFile;
    state.bakedAt = pct;
    return 'rebaked';
}

/** Mirrors the upload handler retaining the unbaked original. */
function onUpload(state, file, cvId) {
    state.editTemplateWatermarkCvId = cvId;
    state._watermarkSourceFile = file;
    state.bakedFrom = file;
    state.bakedAt = state.watermarkOpacityPct;
}

console.log('\nthe order that used to matter');
{
    // BEFORE upload — the case that always worked.
    const s = { watermarkOpacityPct: '30', editTemplateWatermarkCvId: null, _watermarkSourceFile: null };
    ok(onOpacityChange(s, '50') === 'stored-for-upload', 'changing it before upload just records the value');
    onUpload(s, 'logo.png', '068AAA');
    ok(s.bakedAt === '50', 'and the upload bakes at that value');
}
{
    // AFTER upload — the reported case.
    const s = { watermarkOpacityPct: '30', editTemplateWatermarkCvId: null, _watermarkSourceFile: null };
    onUpload(s, 'logo.png', '068AAA');
    ok(s.bakedAt === '30', 'uploaded at 30%');
    const outcome = onOpacityChange(s, '50');
    ok(outcome === 'rebaked', 'changing it after upload now re-bakes rather than doing nothing silently');
    ok(s.bakedAt === '50', 'and the stored image is at the new value');
}

console.log('\nthe re-bake must start from the ORIGINAL, never the stored wash');
{
    const s = { watermarkOpacityPct: '30', editTemplateWatermarkCvId: null, _watermarkSourceFile: null };
    onUpload(s, 'logo.png', '068AAA');
    onOpacityChange(s, '50');
    ok(s.bakedFrom === 'logo.png', 'first change bakes from the original');
    onOpacityChange(s, '15');
    ok(s.bakedFrom === 'logo.png', 'and so does the second — 30% of an already-30% image would be 9%');
    ok(s.bakedAt === '15', 'ending at exactly what was asked for');
}

console.log('\nan image from an earlier session cannot be re-baked, and says so');
{
    // Page reloaded: the CV is on the record but the unbaked original is gone.
    const s = { watermarkOpacityPct: '30', editTemplateWatermarkCvId: '068AAA', _watermarkSourceFile: null };
    ok(
        onOpacityChange(s, '50') === 'told-to-reupload',
        'the author is told to re-upload rather than left thinking it applied'
    );
}

console.log('\nclearing the watermark forgets the original too');
{
    const s = { watermarkOpacityPct: '30', editTemplateWatermarkCvId: null, _watermarkSourceFile: null };
    onUpload(s, 'logo.png', '068AAA');
    // Mirrors handleClearWatermark.
    s.editTemplateWatermarkCvId = null;
    s._watermarkSourceFile = null;
    ok(
        onOpacityChange(s, '50') === 'stored-for-upload',
        'after a clear it is back to recording the value for the next upload'
    );
}

console.log(fail ? `\n${fail} FAILED` : '\nwatermark opacity routing OK');
process.exit(fail ? 1 : 0);
