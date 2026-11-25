/**
 * Pure logic for the Flow-screen signing component. No DOM, no Salesforce imports, so it
 * can be exercised in plain Node (scripts/qa/flow-signer-core-check.mjs) the same way
 * canvasModel.js is.
 *
 * Almost everything here is a port of what the signing Visualforce page does
 * (pages/DocGenSignaturePdf.page): locating the @@SIG-n@@ anchors in the PDF text layer,
 * mapping placements onto them, drawing the stamp cards, and the Certificate of
 * Completion page. It is a COPY, not shared code, on purpose: the VF page is used by every
 * customer and this feature must not touch it. If you change the stamp-card geometry or
 * the certificate layout there, mirror it here, or the two paths will produce differently
 * laid-out signed PDFs.
 *
 * Deliberately NOT ported (the component fails closed instead, see assessSupport):
 * prepared uploaded-PDF requests (sender-placed coordinate fields), signer form fields,
 * email-PIN entry, DatePick, and multi-document packets.
 */

export const SUPPORTED_TYPES = ['Full', 'Initials', 'Date', 'DatePick'];

/**
 * Largest base64 string we will send to saveCompositedSignedPdf. Measured in a Customer
 * Community session: a 3 MB request passed and a 4 MB request failed with
 * aura:systemError. 3,000,000 characters leaves headroom under the 3 MB that passed for
 * the other parameters. That is a signed PDF of roughly 2.2 MB.
 */
export const MAX_COMPOSITE_BASE64_CHARS = 3000000;

const TOKEN_RE = /^[a-fA-F0-9]{64}$/;

/** A signer token from an explicit `token`, else from `?token=` in a signing URL. */
export function parseToken(signerUrl, token) {
    const direct = typeof token === 'string' ? token.trim() : '';
    if (TOKEN_RE.test(direct)) return direct;
    if (typeof signerUrl === 'string') {
        const m = /[?&]token=([a-fA-F0-9]{64})(?![a-fA-F0-9])/.exec(signerUrl);
        if (m) return m[1];
    }
    return null;
}

/**
 * First decision, from DocGenFlowSigningController.getSignerStatus:
 * signed | unavailable | expired | proceed. A signed signer is never "unavailable" or
 * "expired": a browser refresh after signing must show the signed state, not an error.
 */
export function classifyStatus(status) {
    if (!status) return 'unavailable';
    if (status.isSigned) return 'signed';
    if (status.isUnavailable) return 'unavailable';
    if (status.isExpired) return 'expired';
    return 'proceed';
}

/**
 * Fail closed on anything this component cannot do faithfully. Returning {ok:false} is
 * always better than signing a document the signer could not fully complete: the VF
 * page applies the same rule to un-locatable fields (issue #407).
 *
 * Still refused: prepared uploaded-PDF requests (sender-placed coordinate fields). Their only
 * finalizer, savePreparedSignedPdf, is @RemoteAction-only (not callable from a Lightning web
 * component) and a Flow's Create Signature Request action cannot create them.
 *
 * Returns { ok, legacy }. legacy:true is a request with ZERO placement records, which the signing
 * page signs with a single typed name and consent (savePdfSignature), no on-page fields.
 */
export function assessSupport({ status, placements, pdfRevision }) {
    if ((status && status.isPreparedPdf) || (pdfRevision !== null && pdfRevision !== undefined)) {
        return fail(
            'prepared-pdf',
            "This document has fields placed by the sender on an uploaded PDF, which can't be signed inside a Flow. Please use the signing link the sender emailed."
        );
    }
    // Called once before the placements are fetched (placements === undefined) so an unsupported
    // request is rejected without loading the document; called again with them.
    if (placements === undefined) return { ok: true, legacy: false };
    if (!Array.isArray(placements)) {
        return fail('no-placements', 'The signature fields for this document could not be loaded.');
    }
    if (placements.length === 0) return { ok: true, legacy: true };
    for (const p of placements) {
        if (p.pdfRect || p.pdfPage !== undefined) {
            return fail(
                'coordinate-placements',
                "This document has sender-placed signature fields, which can't be signed inside a Flow. Please use the signing link the sender emailed."
            );
        }
        if (!SUPPORTED_TYPES.includes(p.type)) {
            return fail(
                'unsupported-type',
                'This document has a "' + p.type + '" field, which the Flow signing component does not support.'
            );
        }
        if (!p.tagText) {
            return fail(
                'unlocatable',
                'A signature field in this document cannot be located. Please contact the sender.'
            );
        }
    }
    return { ok: true, legacy: false };

    function fail(code, message) {
        return { ok: false, code, message };
    }
}

// ---------------------------------------------------------------- anchor location

/** pdf.js Util.transform: multiply two 2D affine matrices [a,b,c,d,e,f]. */
export function multiply(m1, m2) {
    return [
        m1[0] * m2[0] + m1[2] * m2[1],
        m1[1] * m2[0] + m1[3] * m2[1],
        m1[0] * m2[2] + m1[2] * m2[3],
        m1[1] * m2[2] + m1[3] * m2[3],
        m1[0] * m2[4] + m1[2] * m2[5] + m1[4],
        m1[1] * m2[4] + m1[3] * m2[5] + m1[5]
    ];
}

/** Device-space (top-left origin) box of a text item under a page viewport. */
export function itemDeviceBox(item, viewport) {
    const tx = multiply(viewport.transform, item.transform);
    const fontHeight = Math.hypot(item.transform[2], item.transform[3]) * viewport.scale;
    return { x: tx[4], y: tx[5] - fontHeight, w: item.width * viewport.scale, h: fontHeight };
}

/**
 * Box for just chars [cs, ce) of an item. When a sentinel shares one rendered text run with
 * adjacent label text ("Signature: @@SIG-0@@") the whole-item box would cover the label, so
 * the box is sliced proportionally by character offset (assumes ~even glyph widths).
 */
export function itemSubBox(item, viewport, cs, ce) {
    const full = itemDeviceBox(item, viewport);
    const len = (item.str || '').length;
    if (len <= 0 || (cs <= 0 && ce >= len)) return full;
    return { x: full.x + (cs / len) * full.w, y: full.y, w: ((ce - cs) / len) * full.w, h: full.h };
}

export function unionBox(a, b) {
    const x1 = Math.min(a.x, b.x);
    const y1 = Math.min(a.y, b.y);
    const x2 = Math.max(a.x + a.w, b.x + b.w);
    const y2 = Math.max(a.y + a.h, b.y + b.h);
    return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 };
}

/**
 * Vertical clearance (device px) from an anchor box to the nearest text above and below,
 * limited to text that horizontally overlaps the stamp's footprint. Lets a stamp grow into
 * real whitespace instead of covering body text or the label below it.
 */
export function clearanceAround(box, items, viewport) {
    const winL = box.x - 2;
    const winR = box.x + Math.max(box.w, 230 * viewport.scale);
    const top = box.y;
    const bot = box.y + box.h;
    let above = top;
    let below = viewport.height - bot;
    for (const it of items) {
        if (!it.str || !it.str.trim()) continue;
        const ib = itemDeviceBox(it, viewport);
        if (ib.w <= 0.5) continue;
        if (ib.x > winR || ib.x + ib.w < winL) continue;
        const ibBot = ib.y + ib.h;
        if (ibBot > top + 1 && ib.y < bot - 1) continue; // the anchor's own line
        if (ibBot <= top + 1) {
            above = Math.min(above, top - ibBot);
        } else if (ib.y >= bot - 1) {
            below = Math.min(below, ib.y - bot);
        }
    }
    return { above: Math.max(0, above), below: Math.max(0, below) };
}

/**
 * Every occurrence of each needle across all pages, tolerating a match split across text
 * runs. pages: [{ pageNum, viewport:{transform,scale,height}, textContent:{items} }].
 * Hits come back page-ascending, then in text-run order, so duplicate needles map to
 * records in document order.
 */
export function locateAnchors(pages, needles) {
    const hits = [];
    for (const pg of pages) {
        let combined = '';
        const ranges = [];
        const items = pg.textContent.items;
        for (const it of items) {
            const s = combined.length;
            combined += it.str;
            ranges.push({ item: it, start: s, end: combined.length });
        }
        for (const needle of needles) {
            if (!needle) continue;
            let from = 0;
            let at;
            while ((at = combined.indexOf(needle, from)) >= 0) {
                const matchEnd = at + needle.length;
                let box = null;
                for (const rg of ranges) {
                    if (rg.end <= at || rg.start >= matchEnd) continue;
                    const cs = Math.max(at, rg.start) - rg.start;
                    const ce = Math.min(matchEnd, rg.end) - rg.start;
                    const b = itemSubBox(rg.item, pg.viewport, cs, ce);
                    box = box ? unionBox(box, b) : b;
                }
                if (box) {
                    const clr = clearanceAround(box, items, pg.viewport);
                    hits.push({ needle, box, clearAbove: clr.above, clearBelow: clr.below, page: pg.pageNum });
                }
                from = matchEnd;
            }
        }
    }
    return hits;
}

/**
 * Map placements onto located anchors (port of buildGuidedSpots, non-coordinate path).
 * Placements sharing a tagText map to that needle's Nth hit in document order. Fails closed
 * if any placement is unlocated or any extra anchor occurrence exists (issue #407).
 */
export function buildSpots(placements, hits) {
    const byNeedle = {};
    const needles = [];
    for (const p of placements) {
        if (!p.tagText) continue;
        if (!byNeedle[p.tagText]) {
            byNeedle[p.tagText] = [];
            needles.push(p.tagText);
        }
        byNeedle[p.tagText].push(p);
    }
    const hitsByNeedle = {};
    for (const h of hits) (hitsByNeedle[h.needle] = hitsByNeedle[h.needle] || []).push(h);

    const spots = [];
    for (const needle of needles) {
        const plcs = byNeedle[needle];
        const hitList = hitsByNeedle[needle] || [];
        plcs.forEach((plc, j) => {
            const hit = hitList[j];
            if (!hit) return;
            spots.push({
                placement: plc,
                hit,
                signed: plc.status === 'Signed',
                value: plc.signedValue || null,
                imageData: null
            });
        });
    }
    if (spots.length !== placements.length || hits.length !== placements.length) {
        return {
            ok: false,
            message: 'This document has required signature fields that cannot be located. Please contact the sender.'
        };
    }
    spots.sort((a, b) => (a.placement.sequence || 0) - (b.placement.sequence || 0));
    return { ok: true, spots };
}

/** Device-space hit -> PDF points, bottom-left origin (what pdf-lib draws in). */
export function hitToPdfRect(hit, pagesByNum) {
    const pg = pagesByNum[hit.page];
    if (!pg) return null;
    const s = pg.viewport.scale;
    const pageHpts = pg.viewport.height / s;
    return {
        pageIndex: hit.page - 1,
        x: hit.box.x / s,
        yBottom: pageHpts - (hit.box.y + hit.box.h) / s,
        w: hit.box.w / s,
        h: hit.box.h / s,
        clearAbove: (hit.clearAbove != null ? hit.clearAbove : 9999) / s,
        clearBelow: (hit.clearBelow != null ? hit.clearBelow : 9999) / s
    };
}

// ---------------------------------------------------------------- drawn-mark export sizing

/**
 * Crop rectangle (canvas pixels) around the ink, from a bounding box tracked while drawing.
 * Measured: embedding the whole ~1200x160 pad as a PNG took ~5 s per mark inside Lightning Web
 * Security (pdf-lib's PNG pixel loops run slowly there); a tight crop is a fraction of the
 * pixels. Grows to a minimum size so a single tap still exports a usable mark, and is clamped
 * to the canvas.
 */
export function cropRect(b, pad, canvasW, canvasH, minW = 48, minH = 24) {
    let x1 = Math.floor(b.minX - pad);
    let y1 = Math.floor(b.minY - pad);
    let x2 = Math.ceil(b.maxX + pad);
    let y2 = Math.ceil(b.maxY + pad);
    if (x2 - x1 < minW) {
        const grow = (minW - (x2 - x1)) / 2;
        x1 = Math.floor(x1 - grow);
        x2 = Math.ceil(x2 + grow);
    }
    if (y2 - y1 < minH) {
        const grow = (minH - (y2 - y1)) / 2;
        y1 = Math.floor(y1 - grow);
        y2 = Math.ceil(y2 + grow);
    }
    x1 = Math.max(0, x1);
    y1 = Math.max(0, y1);
    x2 = Math.min(canvasW, x2);
    y2 = Math.min(canvasH, y2);
    return { sx: x1, sy: y1, sw: Math.max(1, x2 - x1), sh: Math.max(1, y2 - y1) };
}

/**
 * The signing page exports its whole fixed 440x150 pad, so every drawn mark it makes is about 3:1, and the
 * stamp card sizes itself from the image's aspect ratio. A tight crop of a wide, flat stroke can be 10:1,
 * which made the card run off the right edge of the page (measured: its "Portwood" brand landed at x=607 on
 * a 612 pt page). So the cropped ink is exported centered on a canvas of exactly this aspect: card
 * dimensions match the original's, and the ink fills the card better.
 */
export const PAD_ASPECT = 3;

/** Canvas size (in source pixels) with the given aspect that contains a sw x sh crop, and the crop's centered offset. */
export function fitAspect(sw, sh, aspect = PAD_ASPECT) {
    const cw = Math.max(sw, sh * aspect);
    const ch = cw / aspect;
    return { cw, ch, ox: (cw - sw) / 2, oy: (ch - sh) / 2 };
}

/** Output size for a crop, capped in width (aspect preserved, never upscaled). */
export function fitWidth(sw, sh, maxW) {
    const s = Math.min(1, maxW / sw);
    return { dw: Math.max(1, Math.round(sw * s)), dh: Math.max(1, Math.round(sh * s)) };
}

// ---------------------------------------------------------------- bytes / text helpers

export function b64ToBytes(b64) {
    const bin = atob(b64);
    const a = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
    return a;
}

export function bytesToB64(bytes) {
    let bin = '';
    const CHUNK = 0x8000; // String.fromCharCode.apply overflows the stack on very large arrays
    for (let i = 0; i < bytes.length; i += CHUNK) {
        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    return btoa(bin);
}

export function dataUrlToBytes(dataUrl) {
    return b64ToBytes(String(dataUrl).split(',')[1] || '');
}

// The stamp text is drawn with a PDF standard font (WinAnsi). Anything outside it cannot be
// encoded and pdf-lib throws, so typed input is checked up front and the signer is told to
// draw instead, rather than writing a silently altered name into a legal document.
const WIN_ANSI_EXTRAS = '€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ';
export function isWinAnsiSafe(text) {
    for (const ch of String(text == null ? '' : text)) {
        const c = ch.codePointAt(0);
        const ok = (c >= 0x20 && c <= 0x7e) || (c >= 0xa0 && c <= 0xff) || WIN_ANSI_EXTRAS.includes(ch);
        if (!ok) return false;
    }
    return true;
}

/** Caption-only: swap unencodable characters for '?' (the signature itself is never altered). */
export function captionSafe(text) {
    let out = '';
    for (const ch of String(text == null ? '' : text)) out += isWinAnsiSafe(ch) ? ch : '?';
    return out;
}

/** Timestamp in the server audit format ('MMMM d, yyyy h:mm a z'). */
export function nowStamp(d = new Date()) {
    try {
        const month = d.toLocaleString('en-US', { month: 'long' });
        const hours = d.getHours();
        const ampm = hours >= 12 ? 'PM' : 'AM';
        const h12 = hours % 12 === 0 ? 12 : hours % 12;
        const mins = ('0' + d.getMinutes()).slice(-2);
        let tz = '';
        try {
            const parts = d.toLocaleTimeString('en-US', { timeZoneName: 'short' }).split(' ');
            tz = parts[parts.length - 1];
        } catch (e) {
            /* tz is best-effort */
        }
        return (
            month +
            ' ' +
            d.getDate() +
            ', ' +
            d.getFullYear() +
            ' ' +
            h12 +
            ':' +
            mins +
            ' ' +
            ampm +
            (tz ? ' ' + tz : '')
        );
    } catch (e) {
        return d.toString();
    }
}

export function shortDate(d = new Date()) {
    try {
        return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
    } catch (e) {
        return '';
    }
}

// ---------------------------------------------------------------- DatePick, form fields, returning signers

/** What the server stores for a drawn mark: the image itself lives only in the browser's PDF. */
export const DRAWN_MARKER = 'Signed (drawn)';

/**
 * DatePick value (a native date input's yyyy-mm-dd) as "Month D, YYYY", matching the automatic Date
 * stamp. Built from LOCAL parts: new Date('yyyy-mm-dd') parses as UTC midnight and shows the
 * previous day in negative time zones.
 */
export function formatPickedDate(iso) {
    if (!iso) return '';
    const p = String(iso).split('-');
    if (p.length !== 3) return iso;
    const d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
    if (isNaN(d.getTime())) return iso;
    return d.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });
}

/**
 * Validate signer form-field answers against the template's config (key,label,type,required,...).
 * Mirrors the signing page: required checks only (checkbox must be ticked; others non-empty after
 * trimming). Server-side validateAndClean still coerces and drops unknown keys. Text that the PDF
 * font cannot encode is refused here so the answer is never silently altered on the document.
 * Returns { valid, errors:{key:message}, values:{key:value} }.
 */
export function validateFormValues(defs, values) {
    const errors = {};
    const clean = {};
    let valid = true;
    for (const d of defs || []) {
        const raw = values ? values[d.key] : undefined;
        let v;
        let missing;
        if (d.type === 'checkbox') {
            v = raw === true || raw === 'true';
            missing = !!d.required && !v;
        } else {
            v = raw === undefined || raw === null ? '' : String(raw).trim();
            missing = !!d.required && !v;
        }
        clean[d.key] = v;
        if (missing) {
            errors[d.key] = 'This field is required.';
            valid = false;
        } else if (typeof v === 'string' && v && !isWinAnsiSafe(v)) {
            errors[d.key] = "These characters can't be placed on the PDF.";
            valid = false;
        }
    }
    return { valid, errors, values: clean };
}

/** The @@FF-<key>@@ anchors the template engine plants for each form field. */
export function formFieldNeedles(defs) {
    return (defs || []).map((d) => '@@FF-' + d.key + '@@');
}

/** Text stamped/listed for a form answer: checkboxes read Yes/No. */
export function formFieldDisplay(def, raw) {
    if (def && def.type === 'checkbox') return raw === true || raw === 'true' ? 'Yes' : 'No';
    return raw === undefined || raw === null ? '' : String(raw);
}

/** "Jordan Rivera" -> "JR" (up to 4 letters). */
export function initialsOf(name) {
    return String(name === undefined || name === null ? '' : name)
        .split(/\s+/)
        .filter(Boolean)
        .map((w) => w[0].toUpperCase())
        .join('')
        .slice(0, 4);
}

/**
 * A signer who reloads mid-signing gets their already-signed fields back from the server. A typed
 * mark and a Date come back with their text, but a DRAWN mark comes back only as the marker
 * 'Signed (drawn)': the image existed only in the old page. signPlacement cannot re-sign a placement,
 * so the drawing is unrecoverable. Rather than stamp the literal marker text on a legal document, those
 * fields fall back to the signer's typed name (the consent they accept says a typed name is their
 * electronic signature). Returns how many fields were restored this way, so the UI can say so.
 */
export function restoreLostMarks(spots, signerName) {
    let n = 0;
    for (const s of spots) {
        if (s.signed && !s.imageData && s.placement.signedValue === DRAWN_MARKER) {
            // An initials field falls back to the signer's initials, not their whole name.
            s.value = (s.placement.type === 'Initials' ? initialsOf(signerName) : signerName) || 'Signed';
            s.restored = true;
            n++;
        }
    }
    return n;
}

// ---------------------------------------------------------------- branding (values come from admin settings but land in styles/markup, so they are checked)

/** A #rgb or #rrggbb color normalised to #rrggbb, else null (never anything that could break out of a style). */
export function safeColor(c) {
    const s = String(c === undefined || c === null ? '' : c).trim();
    if (/^#[0-9a-fA-F]{6}$/.test(s)) return s.toLowerCase();
    if (/^#[0-9a-fA-F]{3}$/.test(s)) return ('#' + s[1] + s[1] + s[2] + s[2] + s[3] + s[3]).toLowerCase();
    return null;
}

export function hexToRgba(hex, alpha) {
    const h = safeColor(hex) || '#0176d3';
    return (
        'rgba(' +
        parseInt(h.slice(1, 3), 16) +
        ',' +
        parseInt(h.slice(3, 5), 16) +
        ',' +
        parseInt(h.slice(5, 7), 16) +
        ',' +
        alpha +
        ')'
    );
}

/** Only https:// or a site-relative path may become an <img src>; never javascript: or data:. */
export function safeUrl(u) {
    const s = String(u === undefined || u === null ? '' : u).trim();
    return /^https:\/\//i.test(s) || /^\/(?!\/)/.test(s) ? s : '';
}

// ---------------------------------------------------------------- certificate page

const CERT_LEFT = 54;
const CERT_LINE_WIDTH = 612 - CERT_LEFT * 2;

/** Wrap text across lines (pdf-lib has no wrapping); breaks mid-token for long URLs. Returns new y. */
export function drawWrappedText(page, text, opts) {
    const font = opts.font;
    const size = opts.size;
    const maxWidth = opts.maxWidth || CERT_LINE_WIDTH;
    const lineHeight = opts.lineHeight || size + 3;
    let y = opts.y;
    const words = String(text).split(' ');
    let line = '';
    const flush = () => {
        if (line === '') return;
        page.drawText(line, { x: opts.x, y, size, font, color: opts.color });
        y -= lineHeight;
        line = '';
    };
    for (const word of words) {
        const candidate = line === '' ? word : line + ' ' + word;
        if (font.widthOfTextAtSize(candidate, size) <= maxWidth) {
            line = candidate;
            continue;
        }
        flush();
        if (font.widthOfTextAtSize(word, size) <= maxWidth) {
            line = word;
            continue;
        }
        let chunk = '';
        for (const ch of word) {
            if (font.widthOfTextAtSize(chunk + ch, size) > maxWidth) {
                page.drawText(chunk, { x: opts.x, y, size, font, color: opts.color });
                y -= lineHeight;
                chunk = '';
            }
            chunk += ch;
        }
        line = chunk;
    }
    flush();
    return y;
}

/** Append the Certificate of Completion page (audit roster + verify pointer). */
export function addCertificatePage(PDFLib, doc, fonts, cert, meStamp, ip, userAgent, ff) {
    const { rgb } = PDFLib;
    const { helv, helvBold } = fonts;
    const gray = rgb(0.44, 0.43, 0.42);
    const brand = rgb(0.005, 0.27, 0.52);
    const page = doc.addPage([612, 792]);
    let y = 740;
    page.drawText('Certificate of Completion', { x: 54, y, size: 18, font: helvBold, color: brand });
    y -= 28;
    page.drawText(captionSafe('Document: ' + (cert.documentTitle || 'Document')), { x: 54, y, size: 10, font: helv });
    y -= 14;
    page.drawText(captionSafe('Request ID: ' + (cert.requestId || '')), { x: 54, y, size: 9, font: helv, color: gray });
    y -= 28;
    page.drawText('Signers', { x: 54, y, size: 12, font: helvBold });
    y -= 18;
    (cert.signers || []).forEach((s) => {
        const signedNow = s.isMe && !s.signedAt;
        const when = signedNow ? meStamp : s.signedAt || 'Pending';
        const lineIp = s.ip || (signedNow ? ip : '') || '—';
        const consent = s.consent || s.isMe ? 'Accepted' : '—';
        const nameLine = (s.name || 'Signer') + (s.role ? '  (' + s.role + ')' : '');
        page.drawText(captionSafe(nameLine), { x: 60, y, size: 10, font: helvBold });
        y -= 13;
        if (s.email) {
            page.drawText(captionSafe(s.email), { x: 60, y, size: 9, font: helv, color: gray });
            y -= 12;
        }
        page.drawText(captionSafe('Signed: ' + when + '      Email verified: ' + (s.verified ? 'Yes' : 'No')), {
            x: 60,
            y,
            size: 9,
            font: helv,
            color: gray
        });
        y -= 12;
        page.drawText(captionSafe('IP address: ' + lineIp + '      Consent: ' + consent), {
            x: 60,
            y,
            size: 9,
            font: helv,
            color: gray
        });
        y -= 12;
        let ua = s.userAgent || (signedNow ? userAgent : '') || '';
        if (ua) {
            // single ellipsis character, as the signing page writes it (WinAnsi can encode it)
            if (ua.length > 95) ua = ua.substring(0, 95) + '…';
            page.drawText(captionSafe('Device: ' + ua), { x: 60, y, size: 7.5, font: helv, color: gray });
        }
        y -= 22;
    });
    // Form Field Responses: the fields flagged "On Certificate", with what this signer entered
    // (mirrors the server certificate's section, so the drawn path matches the typed path).
    const listed = ((ff && ff.defs) || []).filter((d) => d.listOnCertificate);
    if (listed.length) {
        y -= 6;
        page.drawText('Form Field Responses', { x: 54, y, size: 12, font: helvBold });
        y -= 18;
        for (const d of listed) {
            const raw = ff.values ? ff.values[d.key] : undefined;
            const shown =
                d.type === 'checkbox'
                    ? formFieldDisplay(d, raw)
                    : raw === undefined || raw === null || raw === ''
                      ? '—'
                      : String(raw);
            page.drawText(captionSafe((d.label || d.key) + ': ' + shown), {
                x: 60,
                y,
                size: 9,
                font: helv,
                color: gray
            });
            y -= 13;
        }
        y -= 9;
    }
    y -= 6;
    // No raw SHA-256 is printed: the authoritative hash is of the FINAL delivered PDF (computed
    // server-side, stored on the audit record, checked by the verify page). A page inside the
    // file cannot contain its own final hash, so printing one would never match.
    page.drawText('This certificate evidences an electronic signature under the US ESIGN Act and UETA.', {
        x: 54,
        y,
        size: 8,
        font: helv,
        color: gray
    });
    y -= 14;
    page.drawText('The SHA-256 hash of the signed PDF is recorded in a tamper-evident audit record.', {
        x: 54,
        y,
        size: 8,
        font: helv,
        color: gray
    });
    if (cert && cert.verifyUrl) {
        y -= 16;
        page.drawText('Verify this document at:', { x: 54, y, size: 8, font: helvBold, color: gray });
        y -= 12;
        y = drawWrappedText(page, String(cert.verifyUrl), {
            x: 54,
            y,
            size: 7.5,
            font: helv,
            color: brand,
            lineHeight: 10
        });
        y -= 2;
        page.drawText('Drop the PDF you received at that link to confirm its integrity.', {
            x: 54,
            y,
            size: 7.5,
            font: helv,
            color: gray
        });
    }
}

// ---------------------------------------------------------------- compositing

/**
 * Composite every captured mark onto the source PDF with pdf-lib and, when this signer
 * completes the request, append the Certificate of Completion. Returns the PDF bytes.
 *
 * spots: from buildSpots, with `imageData` (a PNG data URL, for a drawn mark) or `value`
 * (typed text; for Date, the server-stamped date) filled in for each.
 */
export async function compositeSignedPdf({
    PDFLib,
    sourceBytes,
    spots,
    pagesByNum,
    signerName,
    cert,
    ip,
    userAgent,
    now,
    formFieldDefs,
    formValues,
    ffHits
}) {
    const { rgb } = PDFLib;
    const when = now || new Date();
    const capStamp = nowStamp(when);
    const capShort = shortDate(when);
    const doc = await PDFLib.PDFDocument.load(sourceBytes);
    const oblique = await doc.embedFont(PDFLib.StandardFonts.HelveticaOblique);
    const helv = await doc.embedFont(PDFLib.StandardFonts.Helvetica);
    const helvBold = await doc.embedFont(PDFLib.StandardFonts.HelveticaBold);
    const pages = doc.getPages();

    // Fallback for a field with no surrounding whitespace (a tag dropped mid-prose): just the
    // ink at roughly line height, no box, so it never covers adjacent text. Returns width.
    function drawInlineMark(page, ink, rect) {
        const h = Math.min(Math.max(rect.h, 11), 16);
        if (ink.png) {
            const asp = ink.png.width / ink.png.height || 3;
            const w = Math.min(h * asp, 90);
            page.drawImage(ink.png, { x: rect.x, y: rect.yBottom, width: w, height: h });
            return w;
        }
        const sz = Math.min(Math.max(rect.h, 10), 15);
        page.drawText(ink.text || '', {
            x: rect.x,
            y: rect.yBottom + 1,
            size: sz,
            font: oblique,
            color: rgb(0.07, 0.11, 0.25)
        });
        return oblique.widthOfTextAtSize(ink.text || '', sz);
    }

    // A stamp card: brand border, the ink (drawn image or typed text in the oblique "signature"
    // font), and a "<labelLine> · Portwood" footer. It grows into whichever side of the field
    // line has more whitespace so it never covers body text above or a label below.
    function drawStampCard(page, ink, rect, sigH, labelLine) {
        const blue = rgb(0.13, 0.36, 0.62);
        const grayTxt = rgb(0.4, 0.4, 0.42);
        const hair = rgb(0.8, 0.84, 0.9);
        const pad = 4;
        let sigW;
        if (ink.png) {
            const aspect = ink.png.width / ink.png.height || 3;
            sigW = Math.max(Math.min(sigH * aspect, 200), 50);
        } else {
            sigW = Math.max(Math.min(oblique.widthOfTextAtSize(ink.text || '', sigH), 200), 50);
        }
        const labelSize = 6.5;
        const brandSize = 6;
        const brandTxt = 'Portwood';
        const labelW = helv.widthOfTextAtSize(labelLine, labelSize);
        const brandW = helvBold.widthOfTextAtSize(brandTxt, brandSize);
        const accent = 3;
        const innerW = Math.max(sigW, labelW + 10 + brandW);
        const cardW = accent + pad + innerW + pad;
        const labelH = 9;
        let cardH = pad + sigH + 4 + labelH + pad;
        const above = rect.clearAbove != null ? rect.clearAbove : 9999;
        const below = rect.clearBelow != null ? rect.clearBelow : 9999;
        if (Math.max(above, below) < 8) return drawInlineMark(page, ink, rect);
        const need = cardH - rect.h;
        // Deterministic: keys off the room BELOW only, so co-located fields signed in separate
        // sessions make the same choice and stay aligned.
        const growDown = below >= 14 || below >= above;
        const room = growDown ? below : above;
        if (need > 0 && room < need) {
            sigH = Math.max(9, sigH - (need - room));
            cardH = pad + sigH + 4 + labelH + pad;
        }
        const botY = growDown ? rect.yBottom + rect.h - cardH : rect.yBottom;
        const x0 = rect.x;
        // Border only, no fill: if the stamp overlaps document text the text stays visible.
        page.drawRectangle({ x: x0, y: botY, width: cardW, height: cardH, borderColor: blue, borderWidth: 0.75 });
        page.drawRectangle({ x: x0, y: botY, width: accent, height: cardH, color: blue });
        const innerX = x0 + accent + pad;
        const sy = botY + cardH - pad - sigH;
        if (ink.png) {
            page.drawImage(ink.png, { x: innerX, y: sy, width: Math.min(sigW, innerW), height: sigH });
        } else {
            page.drawText(ink.text || '', {
                x: innerX,
                y: sy + sigH * 0.18,
                size: sigH,
                font: oblique,
                color: rgb(0.07, 0.11, 0.25)
            });
        }
        page.drawRectangle({ x: innerX, y: sy - 2.5, width: innerW, height: 0.4, color: hair });
        const ly = botY + pad;
        page.drawText(labelLine, { x: innerX, y: ly, size: labelSize, font: helv, color: grayTxt });
        page.drawText(brandTxt, {
            x: x0 + cardW - pad - brandW,
            y: ly - 0.2,
            size: brandSize,
            font: helvBold,
            color: blue
        });
        return cardW;
    }

    for (const spot of spots) {
        const rect = hitToPdfRect(spot.hit, pagesByNum);
        if (!rect || !pages[rect.pageIndex]) {
            throw new Error('A signature field could not be placed on the document.');
        }
        const page = pages[rect.pageIndex];
        const fullLabel = 'Signed by ' + (captionSafe(signerName) || '—') + '   ·   ' + capShort;
        const inlineMode = !!(spot.placement && spot.placement.renderInline);
        const type = spot.placement.type;
        if (spot.imageData) {
            const png = await doc.embedPng(dataUrlToBytes(spot.imageData));
            if (inlineMode) drawInlineMark(page, { png }, rect);
            else if (type === 'Initials') drawStampCard(page, { png }, rect, 14, 'Initialed');
            else drawStampCard(page, { png }, rect, 20, fullLabel);
            continue;
        }
        const text = spot.value || spot.placement.signedValue || '';
        if (!text) continue;
        if (!isWinAnsiSafe(text)) {
            throw new Error(
                'The text for a signature field contains characters that cannot be placed on the PDF. Please draw it instead.'
            );
        }
        if (inlineMode && (type === 'Full' || type === 'Initials')) {
            drawInlineMark(page, { text }, rect);
        } else if (type === 'Full') {
            drawStampCard(page, { text }, rect, 18, fullLabel);
        } else if (type === 'Initials') {
            drawStampCard(page, { text }, rect, 14, 'Initialed');
        } else {
            // Date: plain stamped text on the line.
            const sz = Math.max(rect.h, 9);
            page.drawText(String(text), { x: rect.x, y: rect.yBottom + 1, size: sz, font: oblique });
        }
    }

    // Signer form-field answers ({?key}) are stamped at their @@FF-key@@ anchors, like a Date.
    if (formFieldDefs && formFieldDefs.length && Array.isArray(ffHits)) {
        const byKey = {};
        formFieldDefs.forEach((d) => {
            byKey[d.key] = d;
        });
        for (const h of ffHits) {
            const key = h.needle.substring(5, h.needle.length - 2); // strip "@@FF-" and "@@"
            const def = byKey[key];
            if (!def) continue;
            const text = formFieldDisplay(def, formValues ? formValues[key] : undefined);
            if (!text) continue;
            if (!isWinAnsiSafe(text)) {
                throw new Error('An answer contains characters that cannot be placed on the PDF.');
            }
            const r = hitToPdfRect(h, pagesByNum);
            if (!r || !pages[r.pageIndex]) continue;
            pages[r.pageIndex].drawText(text, {
                x: r.x,
                y: r.yBottom + 1,
                size: Math.max(Math.min(r.h, 12), 8),
                font: helv
            });
        }
    }

    if (cert && cert.othersAllSigned) {
        addCertificatePage(PDFLib, doc, { helv, helvBold }, cert, capStamp, ip, userAgent, {
            defs: formFieldDefs,
            values: formValues
        });
    }
    return doc.save();
}

// ---------------------------------------------------------------- Lightning Web Security shim

/**
 * pdf.js runs its worker on the main thread here, and its in-page port copies every message
 * with structuredClone. Under Lightning Web Security that breaks two ways, both measured:
 *   1. structuredClone(obj, { transfer }) returns the transferred buffer as undefined, so the
 *      PDF bytes vanish and getDocument() hangs;
 *   2. it throws DataCloneError on objects LWS has wrapped.
 * The fix is a clone that ignores `transfer` (the buffer is copied, not moved) and falls back
 * to a plain deep copy. Installed on the component's own sandbox global only.
 */
export function deepClone(v, seen = new Map()) {
    if (v === null || typeof v !== 'object') return v;
    if (seen.has(v)) return seen.get(v);
    if (ArrayBuffer.isView(v)) return v.slice();
    if (v instanceof ArrayBuffer) return v.slice(0);
    if (v instanceof Date) return new Date(v.getTime());
    if (v instanceof Map) {
        const m = new Map();
        seen.set(v, m);
        v.forEach((val, k) => m.set(deepClone(k, seen), deepClone(val, seen)));
        return m;
    }
    if (v instanceof Set) {
        const s = new Set();
        seen.set(v, s);
        v.forEach((val) => s.add(deepClone(val, seen)));
        return s;
    }
    if (Array.isArray(v)) {
        const a = [];
        seen.set(v, a);
        for (let i = 0; i < v.length; i++) a.push(deepClone(v[i], seen));
        return a;
    }
    const o = {};
    seen.set(v, o);
    Object.keys(v).forEach((k) => {
        o[k] = deepClone(v[k], seen);
    });
    return o;
}

/** Returns true if the shim was installed (false if already present). */
export function installCloneShim(win) {
    if (win.__portwoodCloneShim) return false;
    const native = win.structuredClone;
    win.structuredClone = function (v) {
        try {
            return native(v);
        } catch (e) {
            return deepClone(v);
        }
    };
    win.__portwoodCloneShim = true;
    return true;
}
