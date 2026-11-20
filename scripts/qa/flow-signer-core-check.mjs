// Flow signer core check: exercises the pure logic in docGenFlowSigner/signerCore.js against the
// REAL pdf-lib shipped as a static resource. No browser and no org needed:
//   node scripts/qa/flow-signer-core-check.mjs
//
// What it guards: the fail-closed rules (an unsupported document must never be half-signed),
// anchor location incl. a sentinel split across text runs, the one-to-one placement mapping
// (issue #407), compositing + the certificate page on a real PDF, the WinAnsi guard on typed
// text, the base64 helpers on large input, and the Lightning Web Security clone shim.
import { createRequire } from 'node:module';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const root = new URL('../../', import.meta.url);
const dir = mkdtempSync(path.join(tmpdir(), 'portwood-signer-core-'));
const corePath = path.join(dir, 'signerCore.mjs');
writeFileSync(corePath, readFileSync(new URL('force-app/main/default/lwc/docGenFlowSigner/signerCore.js', root), 'utf8'));
const core = await import('file:///' + corePath.replace(/\\/g, '/') + '?v=' + Date.now());

const require = createRequire(import.meta.url);
const PDFLib = require(new URL('force-app/main/default/staticresources/pdflib/pdf-lib.min.js', root).pathname.replace(/^\/([A-Za-z]:)/, '$1'));

let pass = 0;
let fail = 0;
function check(name, cond, detail) {
    if (cond) {
        pass++;
    } else {
        fail++;
        console.log('FAIL: ' + name + (detail ? ' :: ' + detail : ''));
    }
}
const eq = (name, a, b) => check(name, JSON.stringify(a) === JSON.stringify(b), 'got ' + JSON.stringify(a) + ' want ' + JSON.stringify(b));

const TOK = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

// ---- parseToken
eq('parseToken: explicit token wins', core.parseToken('https://x/apex/P?token=' + 'f'.repeat(64), TOK), TOK);
eq('parseToken: from url', core.parseToken('https://s.my.site.com/apex/portwoodglobal__DocGenSignaturePdf?token=' + TOK, undefined), TOK);
eq('parseToken: url with other params', core.parseToken('https://x/y?a=1&token=' + TOK + '&b=2', null), TOK);
eq('parseToken: too short', core.parseToken('https://x/y?token=abc', null), null);
eq('parseToken: 65 hex is not a token', core.parseToken('https://x/y?token=' + TOK + 'a', null), null);
eq('parseToken: nothing', core.parseToken(undefined, undefined), null);
eq('parseToken: invalid explicit falls back to url', core.parseToken('?token=' + TOK, 'nope'), TOK);

// ---- classifyStatus
eq('classify: signed beats everything', core.classifyStatus({ isSigned: true, isUnavailable: true, isExpired: true }), 'signed');
eq('classify: unavailable', core.classifyStatus({ isUnavailable: true }), 'unavailable');
eq('classify: expired', core.classifyStatus({ isExpired: true }), 'expired');
eq('classify: proceed', core.classifyStatus({}), 'proceed');
eq('classify: no status is unavailable', core.classifyStatus(null), 'unavailable');

// ---- assessSupport (fail closed)
const goodPlc = [
    { id: 'p1', type: 'Initials', tagText: '@@SIG-0@@' },
    { id: 'p2', type: 'Full', tagText: '@@SIG-1@@' },
    { id: 'p3', type: 'Date', tagText: '@@SIG-2@@' }
];
const ok = core.assessSupport({ status: {}, placements: goodPlc, pdfRevision: null });
check('support: a normal request is supported', ok.ok === true && ok.legacy === false);
check('support: DatePick is supported', core.assessSupport({ status: {}, placements: [{ type: 'DatePick', tagText: 'x' }] }).ok === true);
eq('support: prepared pdf (status)', core.assessSupport({ status: { isPreparedPdf: true }, placements: goodPlc }).code, 'prepared-pdf');
eq('support: prepared pdf (revision)', core.assessSupport({ status: {}, placements: goodPlc, pdfRevision: 3 }).code, 'prepared-pdf');
check('support: the prepared-pdf message points at the emailed link', /signing link the sender emailed/.test(core.assessSupport({ status: { isPreparedPdf: true } }).message));
check('support: the early pass (no placements fetched yet) accepts a clean request', core.assessSupport({ status: {} }).ok === true);
eq('support: the early pass still rejects a prepared PDF', core.assessSupport({ status: { isPreparedPdf: true } }).code, 'prepared-pdf');
const none = core.assessSupport({ status: {}, placements: [] });
check('support: zero placements is the legacy typed-name flow, not an error', none.ok === true && none.legacy === true);
eq('support: coordinate placement', core.assessSupport({ status: {}, placements: [{ type: 'Full', tagText: 'x', pdfRect: { x: 1 } }] }).code, 'coordinate-placements');
eq('support: an unknown type is refused', core.assessSupport({ status: {}, placements: [{ type: 'Checkbox', tagText: 'x' }] }).code, 'unsupported-type');
eq('support: missing tagText', core.assessSupport({ status: {}, placements: [{ type: 'Full' }] }).code, 'unlocatable');
eq('support: placements not an array', core.assessSupport({ status: {}, placements: 'x' }).code, 'no-placements');

// ---- DatePick, form fields, returning signers
eq('formatPickedDate: ISO to long form', core.formatPickedDate('2026-01-05'), 'January 5, 2026');
eq('formatPickedDate: no off-by-one at a month edge', core.formatPickedDate('2026-03-01'), 'March 1, 2026');
eq('formatPickedDate: empty', core.formatPickedDate(''), '');
eq('formatPickedDate: not ISO passes through', core.formatPickedDate('soon'), 'soon');
eq('formatPickedDate: impossible date passes through', core.formatPickedDate('2026-13-45') === '2026-13-45' || /\d{4}/.test(core.formatPickedDate('2026-13-45')), true);

const defs = [
    { key: 'po', label: 'PO number', type: 'text', required: true },
    { key: 'ack', label: 'I acknowledge', type: 'checkbox', required: true },
    { key: 'note', label: 'Note', type: 'text', required: false },
    { key: 'tier', label: 'Tier', type: 'picklist', required: false, choices: ['A', 'B'] }
];
let v = core.validateFormValues(defs, { po: '  PO-1  ', ack: true });
check('formValues: valid answers pass and are trimmed', v.valid && v.values.po === 'PO-1' && v.values.ack === true && v.values.note === '');
v = core.validateFormValues(defs, { po: '', ack: false });
check('formValues: a missing required text and an unticked required checkbox both fail', !v.valid && v.errors.po && v.errors.ack);
v = core.validateFormValues(defs, { po: '   ', ack: true });
check('formValues: whitespace-only counts as missing', !v.valid && v.errors.po);
v = core.validateFormValues(defs, { po: '李', ack: true });
check('formValues: text the PDF cannot encode is refused up front', !v.valid && /can't be placed/.test(v.errors.po));
v = core.validateFormValues(defs, { po: 'ok', ack: 'true' });
check('formValues: the string "true" counts as a ticked checkbox', v.valid && v.values.ack === true);
check('formValues: an optional blank field is fine', core.validateFormValues(defs, { po: 'x', ack: true, note: '' }).valid);
eq('formFieldNeedles', core.formFieldNeedles(defs).slice(0, 2), ['@@FF-po@@', '@@FF-ack@@']);
eq('formFieldDisplay: checkbox yes/no', [core.formFieldDisplay(defs[1], true), core.formFieldDisplay(defs[1], false), core.formFieldDisplay(defs[0], 'x')], ['Yes', 'No', 'x']);

{
    const spots = [
        { signed: true, imageData: null, value: 'Signed (drawn)', placement: { signedValue: 'Signed (drawn)', type: 'Full' } },
        { signed: true, imageData: null, value: 'Jordan Rivera', placement: { signedValue: 'Jordan Rivera', type: 'Full' } },
        { signed: true, imageData: null, value: 'November 10, 2026', placement: { signedValue: 'November 10, 2026', type: 'Date' } },
        { signed: false, imageData: null, value: null, placement: { signedValue: null, type: 'Full' } }
    ];
    const n = core.restoreLostMarks(spots, 'Jordan Rivera');
    eq('restoreLostMarks: only the drawn marker is replaced', n, 1);
    check('restoreLostMarks: the lost drawing falls back to the typed name, not the marker text', spots[0].value === 'Jordan Rivera' && spots[0].restored === true);
    check('restoreLostMarks: a typed mark, a date and a pending field are left alone', spots[1].value === 'Jordan Rivera' && !spots[1].restored && spots[2].value === 'November 10, 2026' && spots[3].value === null);
    const kept = [{ signed: true, imageData: 'data:image/png;base64,AAAA', value: null, placement: { signedValue: 'Signed (drawn)', type: 'Full' } }];
    eq('initialsOf', [core.initialsOf('Jordan Rivera'), core.initialsOf('  ana  maria  lopez '), core.initialsOf(''), core.initialsOf(null)], ['JR', 'AML', '', '']);
    const ini = [{ signed: true, imageData: null, value: 'Signed (drawn)', placement: { signedValue: 'Signed (drawn)', type: 'Initials' } }];
    core.restoreLostMarks(ini, 'Jordan Rivera');
    eq('restoreLostMarks: a lost INITIALS mark falls back to initials, not the full name', ini[0].value, 'JR');
    eq('restoreLostMarks: a drawing still held in this session is never replaced', core.restoreLostMarks(kept, 'X'), 0);
    eq('restoreLostMarks: no signer name still never stamps the marker text', (() => { const s = [{ signed: true, imageData: null, value: 'Signed (drawn)', placement: { signedValue: 'Signed (drawn)' } }]; core.restoreLostMarks(s, ''); return s[0].value; })(), 'Signed');
}

// ---- branding helpers
eq('safeColor: #rrggbb', core.safeColor('#0176D3'), '#0176d3');
eq('safeColor: #rgb expands', core.safeColor('#0af'), '#00aaff');
eq('safeColor: junk is rejected', [core.safeColor('red'), core.safeColor('#12'), core.safeColor('#12345g'), core.safeColor(null), core.safeColor('#0176d3;background:url(x)')], [null, null, null, null, null]);
eq('hexToRgba', core.hexToRgba('#0176d3', 0.14), 'rgba(1,118,211,0.14)');
eq('hexToRgba: a bad color falls back to the default blue', core.hexToRgba('nope', 1), 'rgba(1,118,211,1)');
eq('safeUrl: https and site-relative pass', [core.safeUrl('https://x.com/a.png'), core.safeUrl('/resource/logo')], ['https://x.com/a.png', '/resource/logo']);
eq('safeUrl: javascript:, data:, http: and protocol-relative are rejected', [core.safeUrl('javascript:alert(1)'), core.safeUrl('data:image/png;base64,AA'), core.safeUrl('http://x.com/a.png'), core.safeUrl('//evil.com/a.png'), core.safeUrl(undefined)], ['', '', '', '', '']);

// ---- anchor location. Build a viewport like pdf.js's at scale 1 for a 612x792 page:
// transform maps PDF space (bottom-left) to device space (top-left): [1,0,0,-1,0,792].
const viewport = { transform: [1, 0, 0, -1, 0, 792], scale: 1, height: 792 };
function item(str, x, y, w, h = 12) {
    return { str, transform: [h, 0, 0, h, x, y], width: w };
}
// "Signature: @@SIG-1@@" merged into ONE text run (the engine does this), plus body text above.
const pageText = {
    pageNum: 1,
    viewport,
    textContent: {
        items: [
            item('Some contract body text above the field', 72, 520, 230),
            item('Signature: @@SIG-1@@', 72, 460, 200),
            // sits under the sentinel (which starts ~x=182 after the "Signature: " label), so it counts
            item('Member Signature', 182, 430, 90)
        ]
    }
};
let hits = core.locateAnchors([pageText], ['@@SIG-1@@']);
eq('locate: found once', hits.length, 1);
check('locate: box starts after the label, not at the line start', hits[0].box.x > 72 + 40, 'x=' + hits[0].box.x);
check('locate: box is narrower than the whole run', hits[0].box.w < 200, 'w=' + hits[0].box.w);
check('locate: clearance above is the gap to the body text', hits[0].clearAbove > 20 && hits[0].clearAbove < 60, 'above=' + hits[0].clearAbove);
check('locate: clearance below is the gap to the label', hits[0].clearBelow > 5 && hits[0].clearBelow < 40, 'below=' + hits[0].clearBelow);

// A sentinel split across two text runs is still found, and unioned into one box.
const split = {
    pageNum: 2,
    viewport,
    textContent: { items: [item('@@SIG-', 72, 300, 30), item('2@@', 102, 300, 18)] }
};
hits = core.locateAnchors([split], ['@@SIG-2@@']);
eq('locate: split sentinel found', hits.length, 1);
check('locate: split box spans both runs', Math.abs(hits[0].box.w - 48) < 0.5, 'w=' + hits[0].box.w);
eq('locate: reports its page', hits[0].page, 2);

// ---- buildSpots (the one-to-one mapping, fail closed)
const plc = [
    { id: 'a', type: 'Initials', tagText: '@@SIG-0@@', sequence: 1 },
    { id: 'b', type: 'Full', tagText: '@@SIG-1@@', sequence: 2 },
    { id: 'c', type: 'Date', tagText: '@@SIG-2@@', sequence: 3 }
];
const pages2 = [
    {
        pageNum: 1,
        viewport,
        textContent: { items: [item('@@SIG-0@@', 440, 604, 55), item('@@SIG-1@@', 72, 460, 55), item('@@SIG-2@@', 317, 460, 55)] }
    }
];
const allHits = core.locateAnchors(pages2, ['@@SIG-0@@', '@@SIG-1@@', '@@SIG-2@@']);
let built = core.buildSpots(plc, allHits);
check('buildSpots: maps all three', built.ok && built.spots.length === 3);
eq('buildSpots: ordered by sequence', built.spots.map((s) => s.placement.id), ['a', 'b', 'c']);
built = core.buildSpots(plc, allHits.slice(0, 2));
check('buildSpots: a missing anchor fails closed', built.ok === false);
built = core.buildSpots(plc.slice(0, 2), allHits);
check('buildSpots: an extra anchor occurrence fails closed (#407)', built.ok === false);
// duplicate needle: two placements, two occurrences, mapped in document order
const dupPlc = [
    { id: 'x', type: 'Full', tagText: '@@SIG-9@@', sequence: 1 },
    { id: 'y', type: 'Full', tagText: '@@SIG-9@@', sequence: 2 }
];
const dupHits = core.locateAnchors(
    [
        { pageNum: 1, viewport, textContent: { items: [item('@@SIG-9@@', 72, 700, 55)] } },
        { pageNum: 2, viewport, textContent: { items: [item('@@SIG-9@@', 72, 200, 55)] } }
    ],
    ['@@SIG-9@@']
);
built = core.buildSpots(dupPlc, dupHits);
check('buildSpots: duplicate needles map in document order', built.ok && built.spots[0].hit.page === 1 && built.spots[1].hit.page === 2);

// ---- hitToPdfRect: a device box at y=604 (top-left) must land at the right PDF y (bottom-left)
const rect = core.hitToPdfRect(allHits[0], { 1: pages2[0] });
check('hitToPdfRect: page index', rect.pageIndex === 0);
check('hitToPdfRect: yBottom is flipped to bottom-left origin', Math.abs(rect.yBottom - 604) < 1, 'yBottom=' + rect.yBottom);
check('hitToPdfRect: unknown page is null', core.hitToPdfRect({ page: 9, box: {} }, { 1: pages2[0] }) === null);

// ---- helpers
check('isWinAnsiSafe: plain + accents', core.isWinAnsiSafe('Jordan Rivera, José Núñez'));
check('isWinAnsiSafe: smart quotes + euro', core.isWinAnsiSafe('“quoted” €5 – ok'));
check('isWinAnsiSafe: CJK is not', !core.isWinAnsiSafe('李小龍'));
check('isWinAnsiSafe: emoji is not', !core.isWinAnsiSafe('ok 😀'));
eq('captionSafe: replaces only the unencodable characters', core.captionSafe('Ana 李 Ruiz'), 'Ana ? Ruiz');
const big = new Uint8Array(1500000).map((_, i) => i % 251);
const roundTrip = core.b64ToBytes(core.bytesToB64(big));
check('base64: 1.5MB round trip (no stack overflow)', roundTrip.length === big.length && roundTrip[123456] === big[123456]);
check('nowStamp: matches the server audit format', /^[A-Z][a-z]+ \d{1,2}, \d{4} \d{1,2}:\d{2} (AM|PM)/.test(core.nowStamp(new Date(2026, 10, 10, 15, 4))), core.nowStamp(new Date(2026, 10, 10, 15, 4)));
check('nowStamp: 3:04 PM', /3:04 PM/.test(core.nowStamp(new Date(2026, 10, 10, 15, 4))));
check('nowStamp: midnight is 12:xx AM', /12:05 AM/.test(core.nowStamp(new Date(2026, 10, 10, 0, 5))));

// ---- drawn-mark export sizing (measured: the full pad cost ~5s per mark under LWS)
{
    const r = core.cropRect({ minX: 100, minY: 40, maxX: 400, maxY: 120 }, 5, 1200, 160);
    eq('cropRect: ink bounds plus padding', r, { sx: 95, sy: 35, sw: 310, sh: 90 });
    check('cropRect: a tight crop is a fraction of the full pad', r.sw * r.sh < (1200 * 160) / 5, 'pixels=' + r.sw * r.sh);
    const dot = core.cropRect({ minX: 600, minY: 80, maxX: 600, maxY: 80 }, 5, 1200, 160);
    check('cropRect: a single tap still exports a usable size', dot.sw >= 48 && dot.sh >= 24, JSON.stringify(dot));
    const edge = core.cropRect({ minX: 0, minY: 0, maxX: 30, maxY: 20 }, 10, 1200, 160);
    check('cropRect: clamps to the canvas', edge.sx === 0 && edge.sy === 0);
    const far = core.cropRect({ minX: 1190, minY: 150, maxX: 1199, maxY: 159 }, 10, 1200, 160);
    check('cropRect: clamps at the far edge', far.sx + far.sw <= 1200 && far.sy + far.sh <= 160);
    const fa = core.fitAspect(300, 80);
    check('fitAspect: a wide stroke gets headroom so the canvas is exactly 3:1', Math.abs(fa.cw / fa.ch - 3) < 1e-9 && fa.cw === 300 && fa.ch === 100 && fa.oy === 10 && fa.ox === 0, JSON.stringify(fa));
    const fb = core.fitAspect(60, 60);
    check('fitAspect: a tall/square stroke is widened to 3:1 and centered', Math.abs(fb.cw / fb.ch - 3) < 1e-9 && fb.ox === 60 && fb.oy === 0, JSON.stringify(fb));
    const fc = core.fitAspect(1100, 100);
    check('fitAspect: an extreme 11:1 stroke can never make the stamp card wider than a 3:1 mark would (the page-overflow bug)', Math.abs(fc.cw / fc.ch - 3) < 1e-9, JSON.stringify(fc));
    // initials card geometry at the real anchor x=505 on a 612pt page: card = 3 + 4 + max(sigW, label+10+brand) + 4
    const sigWInitials = Math.max(Math.min(14 * 3, 200), 50);
    check('stamp card: an initials card from a 3:1 mark ends inside the 612pt page', 505.4 + (3 + 4 + Math.max(sigWInitials, 22.4 + 10 + 27.7) + 4) < 612);
    eq('fitWidth: caps width, keeps aspect', core.fitWidth(960, 240, 480), { dw: 480, dh: 120 });
    eq('fitWidth: never upscales', core.fitWidth(200, 50, 480), { dw: 200, dh: 50 });
}

// ---- LWS clone shim
{
    const win = {
        structuredClone(v) {
            if (v && v.__bad) throw new Error('DataCloneError');
            return JSON.parse(JSON.stringify(v));
        }
    };
    check('shim: installs once', core.installCloneShim(win) === true && core.installCloneShim(win) === false);
    eq('shim: plain values still use the native clone', win.structuredClone({ a: 1 }), { a: 1 });
    const cloned = win.structuredClone({ __bad: true, data: new Uint8Array([1, 2, 3]), nested: { m: new Map([['k', 1]]) } });
    check('shim: falls back to a deep copy when native throws', cloned.data instanceof Uint8Array && cloned.data[2] === 3 && cloned.nested.m.get('k') === 1);
    // transfer is ignored: the source buffer must survive (LWS drops it otherwise)
    const ab = new Uint8Array([9, 9, 9]);
    const cl = win.structuredClone({ __bad: true, buf: ab }, { transfer: [ab.buffer] });
    check('shim: ignores transfer, source buffer intact', cl.buf[0] === 9 && ab.length === 3);
    const cyc = { name: 'c' };
    cyc.self = cyc;
    const cc = core.deepClone(cyc);
    check('deepClone: handles cycles', cc.self === cc && cc !== cyc);
}

// ---- compositing on a REAL pdf-lib document
const PNG_1x1 = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
async function makeSource(pageCount) {
    const d = await PDFLib.PDFDocument.create();
    const f = await d.embedFont(PDFLib.StandardFonts.Helvetica);
    for (let i = 0; i < pageCount; i++) {
        const p = d.addPage([612, 792]);
        p.drawText('Agreement page ' + (i + 1), { x: 72, y: 700, size: 12, font: f });
    }
    return d.save();
}
const src = await makeSource(2);
const pagesByNum = { 1: pages2[0] };
function spotsFor(overrides) {
    const b = core.buildSpots(plc, allHits);
    b.spots.forEach((s) => Object.assign(s, overrides[s.placement.id] || {}));
    return b.spots;
}
const mark = { a: { imageData: PNG_1x1 }, b: { value: 'Jordan Rivera' }, c: { value: 'November 10, 2026' } };
let out = await core.compositeSignedPdf({
    PDFLib,
    sourceBytes: src,
    spots: spotsFor(mark),
    pagesByNum,
    signerName: 'Jordan Rivera',
    cert: { othersAllSigned: false, documentTitle: 'Spike', requestId: 'r1', signers: [] },
    ip: '203.0.113.9',
    userAgent: 'check/1.0'
});
let outDoc = await PDFLib.PDFDocument.load(out);
eq('composite: not the last signer adds no certificate page', outDoc.getPageCount(), 2);
check('composite: output is a different, larger-or-equal PDF', out.length > 0 && out.length !== src.length);

out = await core.compositeSignedPdf({
    PDFLib,
    sourceBytes: src,
    spots: spotsFor(mark),
    pagesByNum,
    signerName: 'Jordan Rivera',
    cert: {
        othersAllSigned: true,
        documentTitle: 'Master Agreement',
        requestId: 'a0Aiz000001ux4rEAA',
        verifyUrl: 'https://example.my.site.com/apex/portwoodglobal__DocGenVerify?token=' + TOK,
        signers: [{ name: 'Jordan Rivera', role: 'Member', email: 'j@example.com', isMe: true, verified: false }]
    },
    ip: '203.0.113.9',
    userAgent: 'check/1.0'
});
outDoc = await PDFLib.PDFDocument.load(out);
eq('composite: the completing signer gets a Certificate of Completion page', outDoc.getPageCount(), 3);
eq('composite: the certificate is letter portrait', [outDoc.getPage(2).getWidth(), outDoc.getPage(2).getHeight()], [612, 792]);

let threw = null;
try {
    await core.compositeSignedPdf({ PDFLib, sourceBytes: src, spots: spotsFor({ b: { value: '李小龍' }, a: { value: 'JR' }, c: { value: 'x' } }), pagesByNum, signerName: 'J', cert: {}, now: new Date() });
} catch (e) {
    threw = e.message;
}
check('composite: typed text outside WinAnsi throws instead of altering the signature', threw && /draw/i.test(threw), String(threw));

threw = null;
try {
    const s = spotsFor(mark);
    s[0].hit = { ...s[0].hit, page: 7 };
    await core.compositeSignedPdf({ PDFLib, sourceBytes: src, spots: s, pagesByNum, signerName: 'J', cert: {} });
} catch (e) {
    threw = e.message;
}
check('composite: a field that cannot be placed throws (fail closed)', threw && /could not be placed/.test(threw), String(threw));

// a non-Latin SIGNER NAME must not break the caption: only the caption is substituted
out = await core.compositeSignedPdf({ PDFLib, sourceBytes: src, spots: spotsFor(mark), pagesByNum, signerName: '李小龍 Lee', cert: {} });
check('composite: a non-Latin signer name does not break the caption', (await PDFLib.PDFDocument.load(out)).getPageCount() === 2);

// ---- form-field answers + DatePick on a real pdf-lib document
{
    const ffDefs = [
        { key: 'po', label: 'PO number', type: 'text', required: true, listOnCertificate: true },
        { key: 'ack', label: 'I acknowledge', type: 'checkbox', required: true, listOnCertificate: true },
        { key: 'quiet', label: 'Not listed', type: 'text', required: false, listOnCertificate: false }
    ];
    const ffPages = [
        {
            pageNum: 1,
            viewport,
            textContent: {
                items: [
                    item('@@SIG-0@@', 440, 604, 55),
                    item('@@SIG-1@@', 72, 460, 55),
                    item('@@SIG-2@@', 317, 460, 55),
                    item('PO: @@FF-po@@', 72, 300, 100),
                    item('@@FF-ack@@', 72, 270, 55),
                    item('@@FF-quiet@@', 72, 240, 55)
                ]
            }
        }
    ];
    const ffHits = core.locateAnchors(ffPages, core.formFieldNeedles(ffDefs));
    eq('formFields: every @@FF-key@@ anchor is located', ffHits.length, 3);
    const spotHits = core.locateAnchors(ffPages, ['@@SIG-0@@', '@@SIG-1@@', '@@SIG-2@@']);
    const dpPlc = [
        { id: 'a', type: 'Initials', tagText: '@@SIG-0@@', sequence: 1 },
        { id: 'b', type: 'Full', tagText: '@@SIG-1@@', sequence: 2 },
        { id: 'c', type: 'DatePick', tagText: '@@SIG-2@@', sequence: 3 }
    ];
    const built2 = core.buildSpots(dpPlc, spotHits);
    check('datePick: a DatePick placement maps like any other', built2.ok && built2.spots[2].placement.type === 'DatePick');
    built2.spots[0].value = 'JR';
    built2.spots[1].value = 'Jordan Rivera';
    built2.spots[2].value = core.formatPickedDate('2026-01-05');
    const ffSrc = await makeSource(1);
    const common = { PDFLib, sourceBytes: ffSrc, spots: built2.spots, pagesByNum: { 1: ffPages[0] }, signerName: 'Jordan Rivera', formFieldDefs: ffDefs, ffHits, userAgent: 'check/1.0', ip: '203.0.113.9' };
    let o = await core.compositeSignedPdf({ ...common, formValues: { po: 'PO-7781', ack: true, quiet: 'secret' }, cert: { othersAllSigned: false } });
    check('formFields: stamping form answers and a DatePick composes without error', (await PDFLib.PDFDocument.load(o)).getPageCount() === 1);
    o = await core.compositeSignedPdf({
        ...common,
        formValues: { po: 'PO-7781', ack: true, quiet: 'secret' },
        cert: { othersAllSigned: true, documentTitle: 'D', requestId: 'r', signers: [{ name: 'Jordan Rivera', isMe: true }] }
    });
    check('formFields: the completing signer still gets exactly one certificate page', (await PDFLib.PDFDocument.load(o)).getPageCount() === 2);
    const bare = await core.compositeSignedPdf({ ...common, formFieldDefs: [], ffHits: [], formValues: {}, cert: { othersAllSigned: true, documentTitle: 'D', requestId: 'r', signers: [{ name: 'J', isMe: true }] } });
    check('formFields: the Form Field Responses section only adds content when fields are listed', o.length !== bare.length);
    let ffThrew = null;
    try {
        await core.compositeSignedPdf({ ...common, formValues: { po: '李小龍', ack: true }, cert: {} });
    } catch (e) {
        ffThrew = e.message;
    }
    check('formFields: an answer the PDF cannot encode throws instead of being altered', ffThrew && /cannot be placed/.test(ffThrew), String(ffThrew));
    const emptyAnswers = await core.compositeSignedPdf({ ...common, formValues: {}, cert: {} });
    check('formFields: unanswered optional fields are simply not stamped', (await PDFLib.PDFDocument.load(emptyAnswers)).getPageCount() === 1);
}

// size guard constant is what the measured ceiling implies
check('size ceiling is under the 3 MB that passed and over zero', core.MAX_COMPOSITE_BASE64_CHARS < 3 * 1024 * 1024 && core.MAX_COMPOSITE_BASE64_CHARS > 1000000);

console.log('PASS: ' + pass + '  FAIL: ' + fail + (fail === 0 ? '  ALL TESTS PASSED' : ''));
process.exit(fail === 0 ? 0 : 1);
