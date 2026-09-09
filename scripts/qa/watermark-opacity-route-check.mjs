/**
 * Watermark opacity — changing it after upload must actually apply, in every
 * session, and the strength control must reflect what is stored.
 *
 *   node scripts/qa/watermark-opacity-route-check.mjs
 *
 * Issue #313, reported by untangleportwood:
 *
 *   "When I try to update the Watermark percentage after I uploaded the image it
 *    doesn't update this value. It works when I change it before I upload the file."
 *
 * Opacity is baked into the PNG's PIXELS at upload time — Flying Saucer has no
 * CSS opacity, so pre-multiplied alpha is the only thing that renders — so once
 * an image is stored the control has nothing to act on unless the UNBAKED
 * original is kept and re-baked from. The original is persisted as
 * `docgen_watermark_src_<versionId>` and the chosen wash is encoded into the
 * baked image's file name (`watermark-p50.png`) so the control can seed from it
 * on reload.
 *
 * This checks the two pieces that are pure enough to verify without a browser:
 *   1. the file-name <-> percent contract (JS writes it, Apex reads it back)
 *   2. the source-bake name handling that the reload path depends on
 * plus a routing simulation. Pixel-alpha correctness still needs a real canvas
 * and is verified by hand.
 */

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

// --- 1. the file-name <-> percent contract -------------------------------------

/** Mirrors docGenAdmin._watermarkFileName. */
const watermarkFileName = (pct) => 'watermark-p' + (parseInt(pct, 10) || 100) + '.png';

/** Mirrors DocGenController.WATERMARK_PCT_PATTERN = -p(\d{1,3})(?:\.|$) */
const parsePct = (name) => {
    const m = /-p(\d{1,3})(?:\.|$)/.exec(name || '');
    return m ? parseInt(m[1], 10) : null;
};

console.log('\nthe wash the designer applied round-trips through the file name');
for (const pct of ['15', '30', '50', '100']) {
    const name = watermarkFileName(pct);
    ok(parsePct(name) === parseInt(pct, 10), `${pct}% -> ${name} -> ${parsePct(name)}`);
}
ok(parsePct('legacy-logo.png') === null, 'a name with no encoded percent reads back null, not a guess');
ok(parsePct('') === null, 'a blank name reads back null');
ok(watermarkFileName('') === 'watermark-p100.png', 'a missing percent falls back to 100 (original)');

// --- 2. the source bake must not need a File --------------------------------------
// The reload path fetches the stored original as bytes and re-bakes it. The bug
// this guards: _bakeWatermarkOpacity read `file.name` unconditionally, so a
// nameless Blob threw a TypeError for every wash except 100%.

/** Mirrors the name handling in docGenAdmin._bakeWatermarkOpacity. */
const bakedBaseName = (file) => (file.name || 'watermark').replace(/\.[^.]+$/, '');

console.log('\nre-baking from stored bytes (a nameless Blob) must not throw');
ok(bakedBaseName({}) === 'watermark', 'a nameless blob yields a usable base name');
ok(bakedBaseName({ name: 'logo.png' }) === 'logo', 'a named file still yields its own base name');

// --- 3. routing simulation -------------------------------------------------------
// A logic mirror of docGenAdmin.handleWatermarkOpacityChange — not the real code
// (it needs a DOM). Returns which situation each change lands in.

function onOpacityChange(state, pct) {
    state.watermarkOpacityPct = pct;
    if (!state.editTemplateWatermarkCvId) {
        return 'stored-for-upload';
    }
    if (state.isUploadingWatermark) {
        return 'ignored-mid-flight';
    }
    const source = state._watermarkSourceFile || state.storedSource;
    if (!source) {
        return 'told-to-reupload';
    }
    state.bakedFrom = source;
    state.bakedAt = pct;
    state.savedFileName = watermarkFileName(pct);
    return 'rebaked';
}

function onUpload(state, file, cvId) {
    state.editTemplateWatermarkCvId = cvId;
    state._watermarkSourceFile = file;
    state.storedSource = file; // persisted as docgen_watermark_src_<versionId>
    state.bakedFrom = file;
    state.bakedAt = state.watermarkOpacityPct;
    state.savedFileName = watermarkFileName(state.watermarkOpacityPct);
}

console.log('\nthe order that used to matter');
{
    const s = { watermarkOpacityPct: '30', editTemplateWatermarkCvId: null, _watermarkSourceFile: null };
    ok(onOpacityChange(s, '50') === 'stored-for-upload', 'changing it before upload just records the value');
    onUpload(s, 'logo.png', '068AAA');
    ok(s.bakedAt === '50' && s.savedFileName === 'watermark-p50.png', 'and the upload bakes + names at that value');
}
{
    const s = { watermarkOpacityPct: '30', editTemplateWatermarkCvId: null, _watermarkSourceFile: null };
    onUpload(s, 'logo.png', '068AAA');
    ok(onOpacityChange(s, '50') === 'rebaked', 'changing it after upload now re-bakes instead of doing nothing');
    ok(s.bakedAt === '50', 'the stored image is at the new value');
    ok(s.savedFileName === 'watermark-p50.png', 'and the new file name records it for the next reload');
}

console.log('\nthe re-bake starts from the ORIGINAL, never the stored wash');
{
    const s = { watermarkOpacityPct: '30', editTemplateWatermarkCvId: null, _watermarkSourceFile: null };
    onUpload(s, 'logo.png', '068AAA');
    onOpacityChange(s, '50');
    ok(s.bakedFrom === 'logo.png', 'first change bakes from the original');
    onOpacityChange(s, '15');
    ok(s.bakedFrom === 'logo.png' && s.bakedAt === '15', 'so does the second — no 15%-of-50% compounding');
}

console.log('\nafter a page reload the stored original still drives the re-bake');
{
    // In-session file gone; the persisted source and the seeded percent remain.
    const s = {
        watermarkOpacityPct: String(parsePct('watermark-p50.png')), // seeded by getWatermarkOpacity
        editTemplateWatermarkCvId: '068AAA',
        _watermarkSourceFile: null,
        storedSource: 'stored-bytes'
    };
    ok(s.watermarkOpacityPct === '50', 'the control seeds from the stored file name, not the default');
    ok(onOpacityChange(s, '15') === 'rebaked', 'a reload no longer costs the author a re-upload');
    ok(s.bakedFrom === 'stored-bytes', 'and it re-bakes from the stored ORIGINAL');
}

console.log('\na change mid re-bake is ignored, not queued or lost');
{
    const s = {
        watermarkOpacityPct: '30',
        editTemplateWatermarkCvId: '068AAA',
        _watermarkSourceFile: 'logo.png',
        isUploadingWatermark: true
    };
    ok(onOpacityChange(s, '50') === 'ignored-mid-flight', 'the select is disabled while a re-bake is in flight');
}

console.log('\nonly a pre-#313 watermark has no source, and that one says so');
{
    const s = {
        watermarkOpacityPct: '30',
        editTemplateWatermarkCvId: '068AAA',
        _watermarkSourceFile: null,
        storedSource: null
    };
    ok(onOpacityChange(s, '50') === 'told-to-reupload', 'the author is told to re-upload rather than misled');
}

console.log('\nclearing the watermark forgets the original too');
{
    const s = { watermarkOpacityPct: '30', editTemplateWatermarkCvId: null, _watermarkSourceFile: null };
    onUpload(s, 'logo.png', '068AAA');
    s.editTemplateWatermarkCvId = null;
    s._watermarkSourceFile = null;
    s.storedSource = null; // server drops docgen_watermark_src_<versionId>
    ok(onOpacityChange(s, '50') === 'stored-for-upload', 'after a clear it is back to recording for the next upload');
}

console.log(fail ? `\n${fail} FAILED` : '\nwatermark opacity routing OK');
process.exit(fail ? 1 : 0);
