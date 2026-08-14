/**
 * The Canvas scene graph, and the only place that knows how it becomes HTML.
 *
 * WHY A MODEL AND NOT THE DOM
 * ---------------------------
 * The existing designer treats the rendered DOM as the document: it reads the canvas
 * back with innerHTML and re-parses it. Under Lightning Web Security's per-namespace
 * sandbox that has repeatedly bitten us — `ChildNode.replaceWith` missing on proxied
 * nodes, `cloneNode(true)` silently dropping browser-inserted nodes — because the
 * browser is allowed to restructure contenteditable output and LWS distorts what you
 * read back.
 *
 * Here the model is the truth. Boxes are plain objects with inch coordinates; the DOM
 * is a projection of them that is thrown away and re-rendered. Nothing is ever parsed
 * back out of the live tree, so there is no tree to be distorted. contenteditable
 * survives only INSIDE a single text box, where the browser's restructuring can't
 * escape the box it belongs to.
 *
 * UNITS
 * -----
 * The model stores INCHES because that is what the PDF is measured in and what the
 * author is really choosing. Pixels appear only at render time (inches x 96 x zoom),
 * so changing zoom can never drift the document — a class of bug the old caret/marker
 * code had to divide the zoom back out of by hand at every site.
 */

/** CSS reference pixels per inch. Fixed by the CSS spec, not by the display. */
export const PX_PER_IN = 96;

/**
 * PAPER sizes in inches. The artboard is paper minus margins, computed rather than
 * tabulated — margins are author-controlled now, so a table of content sizes baked
 * against 0.5in would silently be wrong the moment anyone changed them.
 */
const PAPER = {
    Letter: { w: 8.5, h: 11 },
    A4: { w: 8.27, h: 11.69 },
    Legal: { w: 8.5, h: 14 }
};

export const PAGE_SIZES = [
    { label: 'Letter (8.5 x 11 in)', value: 'Letter' },
    { label: 'A4 (210 x 297 mm)', value: 'A4' },
    { label: 'Legal (8.5 x 14 in)', value: 'Legal' },
    { label: 'Custom size', value: 'Custom' }
];

export const DEFAULT_CUSTOM_PAGE = { w: 8.5, h: 11 };

/**
 * ZERO by default, so the canvas and the page share an origin.
 *
 * With a margin, the artboard is the CONTENT area and a box at 0,0 sits at the margin
 * rather than at the corner of the paper — correct, but it means the numbers in the
 * editor are not the numbers on the page. At zero the two are the same thing and what
 * you place is exactly what prints, which is the whole promise of this editor. Authors
 * who want a margin can set one, and every document already saved keeps whatever its
 * own @page rule says.
 */
export const DEFAULT_MARGINS = { top: 0, right: 0, bottom: 0, left: 0 };

function clampMargin(v, fallback) {
    const n = parseFloat(v);
    if (isNaN(n) || n < 0) {
        return fallback;
    }
    // 3in of margin on one side of Letter leaves 2.5in of page. Past that the author
    // is fighting the tool rather than using it.
    return Math.min(3, round3(n));
}

export function normalizeMargins(m) {
    const src = m || {};
    return {
        top: clampMargin(src.top, DEFAULT_MARGINS.top),
        right: clampMargin(src.right, DEFAULT_MARGINS.right),
        bottom: clampMargin(src.bottom, DEFAULT_MARGINS.bottom),
        left: clampMargin(src.left, DEFAULT_MARGINS.left)
    };
}

/**
 * The artboard is the CONTENT area — paper minus margins — because that is the box a
 * pinned coordinate is measured inside. `@page { margin }` shifts the whole content
 * box, so a box at x=0 sits at the left margin, not at the paper edge, and the canvas
 * shows exactly that.
 */
/** Custom page dimensions, clamped to what a PDF page can actually be. */
export function normalizeCustomPage(c) {
    const src = c || {};
    const w = parseFloat(src.w);
    const h = parseFloat(src.h);
    return {
        w: round3(Math.min(200, Math.max(1, isNaN(w) ? DEFAULT_CUSTOM_PAGE.w : w))),
        h: round3(Math.min(200, Math.max(1, isNaN(h) ? DEFAULT_CUSTOM_PAGE.h : h)))
    };
}

/**
 * The artboard is the CONTENT area — paper minus margins — because that is the box a
 * pinned coordinate is measured inside. `@page { margin }` shifts the whole content
 * box, so a box at x=0 sits at the left margin, not at the paper edge, and the canvas
 * shows exactly that. At the default zero margin the two coincide.
 *
 * A custom size emits its dimensions as lengths rather than a named page. Inches, and
 * rounded: metric page sizes turn into long decimals (210mm is 8.26388…in) and those
 * have been implicated in the engine mis-paginating long documents.
 */
export function pageGeometry(pageSize, orientation, margins, customPage) {
    const isCustom = pageSize === 'Custom';
    const paper = isCustom ? normalizeCustomPage(customPage) : PAPER[pageSize] || PAPER.Letter;
    const landscape = String(orientation || 'Portrait').toLowerCase() === 'landscape';
    const pw = landscape ? paper.h : paper.w;
    const ph = landscape ? paper.w : paper.h;
    const m = normalizeMargins(margins);
    return {
        css: isCustom
            ? round3(pw) + 'in ' + round3(ph) + 'in'
            : (PAPER[pageSize] ? pageSize : 'Letter') + (landscape ? ' landscape' : ' portrait'),
        w: round3(Math.max(1, pw - m.left - m.right)),
        h: round3(Math.max(1, ph - m.top - m.bottom)),
        margins: m
    };
}

let seq = 0;
/** Ids are per-session only — they never reach the serialized document. */
function nextId(prefix) {
    seq += 1;
    return prefix + '_' + seq;
}

/**
 * The ONLY font stacks Flying Saucer actually resolves, measured 2026-08-05 against a
 * real render (scripts/css-probe-fonts.apex, docs/css-probe-fonts.png).
 *
 * Most NAMED families — Arial, Georgia, Verdana, Tahoma, Impact, Times New Roman,
 * Courier New, Symbol, ZapfDingbats — silently fall back to a base-14 face. Offering
 * one would render something else and quietly make the canvas stop being WYSIWYG.
 *
 * `Arial Unicode MS` is the exception and is offered: it genuinely embeds, which is
 * how a checkmark reaches the page at all. Re-measured 2026-08-06 — an earlier probe
 * missed it by testing "Arial" and not this name, and concluded wrongly that symbols
 * were impossible.
 */
/** The one family with full Unicode coverage. Wrapped around any glyph the base
 *  fonts cannot draw, so a symbol renders whatever font its box is set to. */
export const UNICODE_FONT = "'Arial Unicode MS'";

/**
 * Whether a font-family can actually print bold in the PDF engine (Blob.toPdf /
 * Flying Saucer). Only `'Arial Unicode MS'` cannot: it embeds a regular (and italic)
 * face but no bold variant (#281), so `font-weight: bold` on it silently renders
 * regular — the canvas showed a weight the PDF could not deliver. The serializers
 * use this to skip emitting bold for it, and the editor disables the Bold control, so
 * authoring and output agree.
 */
export function canRenderBold(font) {
    return typeof font !== 'string' || font.replace(/['"]/g, '').toLowerCase() !== 'arial unicode ms';
}

/**
 * Symbols, and the font each one needs.
 *
 * Measured against rendered PDFs. Blob.toPdf resolves the generic families to the
 * base-14 fonts (Helvetica / Times-Roman / Courier, WinAnsi), where anything outside
 * Latin-1 renders as NOTHING — not a box, not a substitute, absent. That is where
 * checkmarks used to disappear.
 *
 * `Arial Unicode MS` is different: it embeds as a subsetted CID TrueType with
 * Identity-H encoding and draws the lot — ✓ ✔ ☑ ☐ ✗ ● ■ ★ → √ ≤ ≥ ≈ ∞, CJK, Greek,
 * Cyrillic, Hebrew — in regular and italic but NOT bold (#281: it has no bold face,
 * so font-weight bold on it prints regular). Naming it is the whole trick, and it
 * is why `unicode: true` symbols below are inserted wrapped in a span that asks for it
 * rather than relying on whatever the box is set to.
 *
 * The cost is real but bounded: embedding the subset takes a rendered page from ~1.5KB
 * to ~70KB. Only pages that use it pay, and only for the glyphs they use.
 */
export const SAFE_SYMBOLS = [
    { label: '✓', value: '\u2713', name: 'Check', unicode: true },
    { label: '✔', value: '\u2714', name: 'Heavy check', unicode: true },
    { label: '☑', value: '\u2611', name: 'Checked box', unicode: true },
    { label: '☐', value: '\u2610', name: 'Empty box', unicode: true },
    { label: '✗', value: '\u2717', name: 'Cross', unicode: true },
    { label: '●', value: '\u25cf', name: 'Filled circle', unicode: true },
    { label: '■', value: '\u25a0', name: 'Filled square', unicode: true },
    { label: '★', value: '\u2605', name: 'Star', unicode: true },
    { label: '☆', value: '\u2606', name: 'Open star', unicode: true },
    { label: '→', value: '\u2192', name: 'Arrow', unicode: true },
    { label: '≤', value: '\u2264', name: 'Less or equal', unicode: true },
    { label: '≥', value: '\u2265', name: 'Greater or equal', unicode: true },
    { label: '•', value: '\u2022', name: 'Bullet' },
    { label: '–', value: '\u2013', name: 'En dash' },
    { label: '—', value: '\u2014', name: 'Em dash' },
    { label: '×', value: '\u00d7', name: 'Multiply' },
    { label: '÷', value: '\u00f7', name: 'Divide' },
    { label: '±', value: '\u00b1', name: 'Plus-minus' },
    { label: '°', value: '\u00b0', name: 'Degree' },
    { label: '§', value: '\u00a7', name: 'Section' },
    { label: '¶', value: '\u00b6', name: 'Paragraph' },
    { label: '†', value: '\u2020', name: 'Dagger' },
    { label: '™', value: '\u2122', name: 'Trademark' },
    { label: '©', value: '\u00a9', name: 'Copyright' },
    { label: '®', value: '\u00ae', name: 'Registered' },
    { label: '½', value: '\u00bd', name: 'One half' },
    { label: '€', value: '\u20ac', name: 'Euro' },
    { label: '£', value: '\u00a3', name: 'Pound' }
];

/** The markup to insert for a symbol — Unicode ones carry the font that draws them. */
export function symbolMarkup(sym) {
    if (!sym) {
        return '';
    }
    return sym.unicode ? '<span style="font-family: ' + UNICODE_FONT + ';">' + sym.value + '</span>' : sym.value;
}

export const FONT_CHOICES = [
    { label: 'Sans-serif', value: 'sans-serif' },
    { label: 'Serif', value: 'serif' },
    { label: 'Monospace', value: 'monospace' },
    // The Unicode face. Embeds and draws symbols, CJK, Greek, Cyrillic and Hebrew that
    // the base-14 fonts cannot — in regular and italic. It has NO bold face in the PDF
    // engine (Blob.toPdf), so font-weight: bold on it silently prints regular; the
    // Bold control is disabled for it (see canRenderBold).
    { label: 'Arial Unicode (symbols, CJK)', value: "'Arial Unicode MS'" }
];

/**
 * Stacking order. Measured to work in this engine (scripts/css-probe-canvas-features),
 * unlike most CSS 3 — z-index is CSS 2.1 and Flying Saucer honours it on positioned
 * boxes, which is what makes overlap controllable rather than a matter of authoring
 * order.
 */
export const DEFAULT_Z = 0;

export const DEFAULT_STYLE = {
    font: 'sans-serif',
    size: 11,
    bold: false,
    italic: false,
    underline: false,
    color: '#1a1a1a',
    fill: '',
    align: 'left',
    borderWidth: 0,
    borderColor: '#333333',
    padding: 2
};

export function newTextBox(xIn, yIn, wIn, hIn) {
    return {
        id: nextId('box'),
        kind: 'text',
        style: { ...DEFAULT_STYLE },
        // `pinned` boxes are position:absolute and land exactly where dropped.
        // `flow` boxes sit in normal flow so their content can paginate — that is
        // how a {#Loop} of 60 rows spills onto the next page instead of being
        // clipped at the artboard edge.
        mode: 'pinned',
        z: DEFAULT_Z,
        condition: '',
        x: round3(xIn),
        y: round3(yIn),
        w: round3(wIn),
        h: round3(hIn),
        // PLAIN TEXT, not HTML.
        //
        // A canvas text box is edited in a real <textarea>, for two reasons that both
        // matter more than inline formatting would. First, Lightning's global "/"
        // hotkey steals focus to the search box from a contenteditable — the flow
        // designer had to detect the theft after the fact and steal focus BACK, because
        // LWS never delivers the window-capture listener that would let it be
        // prevented. Lightning ignores its shortcuts inside a textarea, so the problem
        // stops existing rather than being recovered from. Second, a textarea's value
        // is a plain string: there is no contenteditable DOM for LWS to distort, which
        // is the entire bug class this editor was built to escape.
        //
        // The trade is no bold-one-word-inside-a-box. That is the Canva model anyway —
        // styling belongs to the object, and every style here is already per-box.
        text: 'Text'
    };
}

/**
 * Header and body rows carry their OWN typography.
 *
 * One setting for the whole table meant a heading could not be bigger than its data,
 * which is the first thing anyone reaches for. Font family stays box-level — mixing
 * families inside one table is almost always a mistake, and there are only three to
 * choose from anyway.
 */
export const DEFAULT_ROW_TEXT = { size: 11, color: '#1a1a1a', bold: false, align: 'left' };
export const DEFAULT_HEADER_TEXT = { size: 10.5, color: '#ffffff', bold: true, align: 'left' };

/**
 * The totals row carries its OWN fill and typography.
 *
 * It used to be hardcoded to bold-on-headerFill, which meant a grand total could not
 * be distinguished from a column heading — the two rows looked identical at opposite
 * ends of the table, and an author wanting a dark total band had to accept a dark
 * header too.
 */
export const DEFAULT_TOTALS_TEXT = { size: 11, color: '#1f3a5f', bold: true, align: 'left' };

/**
 * The NESTED row's typography and band. Separate from rowText because the point of a
 * sub-row is that it reads as subordinate to the row above it — usually smaller, often
 * on a tint, always indented.
 */
export const DEFAULT_SUB_TEXT = { size: 10, color: '#41546b', bold: false, align: 'left' };

/**
 * How a table is ruled. Flying Saucer honours per-side borders (v2.8 added the
 * per-side translation), so "horizontal rules only" is a real option rather than an
 * approximation — and it is the one that looks like a designed document instead of a
 * spreadsheet. Vertical lines between every column are what make a table look busy.
 */
export const GRID_STYLES = [
    { label: 'Rules under rows', value: 'rows' },
    { label: 'Full grid', value: 'grid' },
    { label: 'No lines', value: 'none' }
];

export const DEFAULT_TABLE_STYLE = {
    // A banded header with white type reads as deliberate; grey-on-grey reads as a
    // default nobody chose.
    headerFill: '#1f3a5f',
    headerBold: true,
    gridStyle: 'rows',
    gridColor: '#d5dde6',
    gridWidth: 0.75,
    // Room to breathe. 3pt crams the text against the rules.
    cellPadding: 6,
    headerText: { ...DEFAULT_HEADER_TEXT },
    rowText: { ...DEFAULT_ROW_TEXT },
    totalsFill: '#eef3f9',
    totalsText: { ...DEFAULT_TOTALS_TEXT },
    // The GRANDCHILD loop, rendered once per parent row inside the parent's loop.
    // Blank relationship = off, which is why this can be added to any existing table
    // without changing what it already produces.
    subRelationship: '',
    subColumns: [],
    subFill: '#f7f9fc',
    subIndent: 12,
    subText: { ...DEFAULT_SUB_TEXT }
};

/**
 * A table box. Defaults to FLOW mode, and that default is the whole point: a table
 * bound to a {#Loop} grows to whatever the merge produces, and only a flow box
 * paginates. Pinned would clip it at the artboard edge the moment the data outgrew
 * the page — measured in scripts/canvas-layout-model-probe.apex.
 */
export function newTableBox(xIn, yIn, wIn) {
    return {
        id: nextId('box'),
        kind: 'table',
        mode: 'flow',
        z: DEFAULT_Z,
        condition: '',
        style: { ...DEFAULT_STYLE, padding: 0 },
        table: {
            ...DEFAULT_TABLE_STYLE,
            showHeader: true,
            // Blank relationship = a static table. Set it and every row repeats per
            // child record.
            relationship: '',
            // Extra literal rows, each an array of cell strings. Used on their own for
            // a fixed table, or appended after the loop when one is bound.
            rows: [],
            // A totals row. Emitted as the LAST <tr> of <tbody>, deliberately not in
            // <tfoot>: a table-footer-group repeats on EVERY page, and a grand total
            // that appears on every page of a long invoice is wrong.
            totals: { enabled: false, cells: [] },
            columns: [
                { label: 'Item', tag: '{Name}', width: '' },
                { label: 'Amount', tag: '{Amount}', width: '' }
            ],
            subRelationship: '',
            subColumns: [],
            subFill: '#f7f9fc',
            subIndent: 12,
            subText: { ...DEFAULT_SUB_TEXT }
        },
        x: round3(xIn),
        y: round3(yIn),
        w: round3(wIn),
        h: 1,
        html: ''
    };
}

/**
 * An image box.
 *
 * Two sources, one box. `src` is a relative /sfc/ ContentVersion URL — an asset file or
 * a file uploaded to the template — and renders the same picture for every record.
 * `tag` is a merge tag like {%Logo__c}, which renders whatever the record points at.
 * Setting a tag wins, because a box with both is an author who changed their mind.
 *
 * Pinned by default: an image is a fixed piece of furniture (a logo, a signature
 * block), not something that should push text around as it paginates.
 */
export function newImageBox(xIn, yIn, wIn, hIn) {
    return {
        id: nextId('box'),
        kind: 'image',
        mode: 'pinned',
        z: DEFAULT_Z,
        condition: '',
        style: { ...DEFAULT_STYLE, padding: 0 },
        image: {
            // A Portwood ASSET KEY, not a file URL. `{%asset:<key>}` resolves at
            // generation time to that asset's latest version, so replacing the logo in
            // the Assets tab updates every document that uses it. Baking a
            // ContentVersion Id into the body instead would pin each template to the
            // version that happened to be current the day it was authored, and there
            // would be nothing to indicate the document had gone stale.
            assetKey: '',
            // Preview only — the canvas has to draw something, and this URL never
            // reaches the saved document.
            src: '',
            tag: '',
            fileName: '',
            // Keep the aspect ratio by default — dragging a corner on a logo and
            // getting it squashed is the single most annoying thing an image tool can
            // do. When on, only the width is emitted and height follows.
            keepRatio: true
        },
        x: round3(xIn),
        y: round3(yIn),
        w: round3(wIn),
        h: round3(hIn)
    };
}

/**
 * Shape kinds are limited to what the PDF engine ACTUALLY renders, measured against a
 * real Blob.toPdf (scripts/css-probe-canvas-features.apex).
 *
 * A rectangle is a div with a background and a border; a line is a div with one border
 * side. Both are plain CSS 2.1 and render exactly. Deliberately ABSENT: circles and
 * diamonds. border-radius and transform are CSS 3 — Flying Saucer ignores them
 * silently, so a circle tool would put a rectangle in the PDF while showing a circle on
 * the canvas, which breaks the one promise this editor makes. They need the rasterizer
 * (the route the chart engine already takes) and that is a separate piece of work.
 */
export const SHAPE_CHOICES = [
    { label: 'Rectangle', value: 'rect' },
    { label: 'Horizontal line', value: 'hline' },
    { label: 'Vertical line', value: 'vline' }
];

export const DEFAULT_SHAPE = {
    type: 'rect',
    // Flat hex only. rgba() renders NOTHING in this engine rather than degrading, so
    // there is no opacity control here and 'none' is spelled as an empty string.
    fill: '#e8eef7',
    borderWidth: 1,
    borderColor: '#33475b'
};

export function newShapeBox(xIn, yIn, wIn, hIn) {
    return {
        id: nextId('box'),
        kind: 'shape',
        mode: 'pinned',
        z: DEFAULT_Z,
        condition: '',
        style: { ...DEFAULT_STYLE, padding: 0 },
        shape: { ...DEFAULT_SHAPE },
        x: round3(xIn),
        y: round3(yIn),
        w: round3(wIn),
        h: round3(hIn)
    };
}

/** Inches to CSS px, for the size-keyed image cache-bust. */
function inToCssPx(v) {
    return Math.max(1, Math.round((parseFloat(v) || 0) * PX_PER_IN));
}

/**
 * An image box becomes an <img> at an EXACT size, with the size-keyed cache-bust the
 * engine's own image path uses.
 *
 * Flying Saucer computes a replaced element's layout size once per unique URL and
 * reuses it for every later <img> with that src — so the same logo placed twice at
 * different sizes silently renders at the first one's size. Appending ?dgsz=<key> gives
 * each size its own URL. This is the same rule as DocGenService.buildHtmlImageMarkup;
 * if that rule ever changes, both have to change together.
 */
function imageToHtml(box) {
    const img = box.image || {};
    const wPx = inToCssPx(box.w);
    const hPx = inToCssPx(box.h);
    // The size token MUST contain an 'x'.
    //
    // DocGenService.parseImageTagSpec bails out and applies no size at all when the
    // token has no 'x' — so `{%asset:logo:144}` is silently ignored and the image
    // renders at its intrinsic size, however carefully the box was sized on the canvas.
    // `144x` means "144 wide, height follows"; `144x96` is exact.
    const sizeToken = img.keepRatio ? wPx + 'x' : wPx + 'x' + hPx;
    const assetKey = String(img.assetKey || '').trim();
    if (assetKey) {
        // The engine expands this to a full <img> through the same pipeline every other
        // image tag uses, so sizing tokens and all output formats come for free.
        return '{%asset:' + assetKey + ':' + sizeToken + '}';
    }
    const tag = String(img.tag || '').trim();
    if (tag) {
        // Hand the sizing to the engine's own {%Field:WxH} token rather than wrapping
        // the tag in styled markup — the engine replaces the whole tag, so any CSS put
        // around it here would be describing a box that no longer exists.
        const m = /^\{%([A-Za-z0-9_.]+)(?::[^}]*)?\}$/.exec(tag);
        const field = m ? m[1] : tag.replace(/^\{%?|\}$/g, '');
        return '{%' + field + ':' + (img.keepRatio ? wPx + 'x' : wPx + 'x' + hPx) + '}';
    }
    if (!img.src) {
        return '';
    }
    const sizeKey = img.keepRatio ? 'w' + wPx : 'w' + wPx + 'h' + hPx;
    const url = img.src + (img.src.indexOf('?') === -1 ? '?' : '&') + 'dgsz=' + sizeKey;
    const css = img.keepRatio ? 'width: ' + wPx + 'px; height: auto;' : 'width: ' + wPx + 'px; height: ' + hPx + 'px;';
    return (
        '<img src="' +
        esc(url) +
        '" style="' +
        css +
        ' image-orientation: from-image;" alt="' +
        esc(img.fileName || '') +
        '" />'
    );
}

/**
 * A shape is emitted as a sized div and marked with data-dg-shape so it reads back as a
 * shape rather than as an empty text box. A line is a single border side on a
 * zero-thickness div, which is how you draw a rule in CSS 2.1.
 */
function shapeToHtml(box) {
    const sh = { ...DEFAULT_SHAPE, ...(box.shape || {}) };
    if (sh.type === 'hline' || sh.type === 'vline') {
        const side = sh.type === 'hline' ? 'border-top' : 'border-left';
        const size =
            sh.type === 'hline'
                ? 'width: ' + outerToContentWidth(box) + 'in; height: 0;'
                : 'height: ' + box.h + 'in; width: 0;';
        return (
            '<div data-dg-shape="' +
            sh.type +
            '" style="' +
            size +
            ' ' +
            side +
            ': ' +
            Math.max(0.5, sh.borderWidth) +
            'pt solid ' +
            sh.borderColor +
            '; font-size: 0; line-height: 0;"></div>'
        );
    }
    // The shape's OWN border is outside its width too, so `width: 100%` made a
    // rectangle wider than the box that holds it by twice its line weight — a 6pt
    // outline on a box dragged near the edge ran a sixth of an inch past where the
    // canvas drew it. Subtract it, the same way the wrapper subtracts its own chrome.
    const bw = sh.borderWidth > 0 ? sh.borderWidth : 0;
    const w = round3(Math.max(0.02, outerToContentWidth(box) - (2 * bw) / 72));
    const h = round3(Math.max(0.02, outerToContentHeight(box) - (2 * bw) / 72));
    let css = 'width: ' + w + 'in; height: ' + h + 'in; font-size: 0; line-height: 0;';
    if (sh.fill) css += ' background: ' + sh.fill + ';';
    if (bw > 0) css += ' border: ' + bw + 'pt solid ' + sh.borderColor + ';';
    return '<div data-dg-shape="rect" style="' + css + '"></div>';
}

/** Reads an <img> back into the model, dropping the size-keyed cache-bust. */
function readImageTag(el) {
    const m = /\{%asset:([A-Za-z0-9_-]+)(?::[^}]*)?\}/i.exec(el.textContent || '');
    return m ? { assetKey: m[1], src: '', tag: '', fileName: '', keepRatio: true } : null;
}

function readImage(imgEl) {
    const raw = imgEl.getAttribute('src') || '';
    const src = raw.replace(/[?&]dgsz=[^&]*/, '').replace(/\?$/, '');
    const style = imgEl.getAttribute('style') || '';
    return {
        assetKey: '',
        src: src,
        tag: '',
        fileName: imgEl.getAttribute('alt') || '',
        keepRatio: /height:\s*auto/i.test(style)
    };
}

function readShape(el, boxStyle) {
    const inner = el.querySelector('[data-dg-shape]') || el;
    const type = inner.getAttribute('data-dg-shape') || 'rect';
    const style = inner.getAttribute('style') || boxStyle || '';
    const sh = { ...DEFAULT_SHAPE, type: type };
    const bm = /border(?:-top|-left)?:\s*([0-9.]+)pt\s+solid\s+([^;]+)/.exec(style);
    if (bm) {
        sh.borderWidth = parseFloat(bm[1]);
        sh.borderColor = bm[2].trim();
    }
    const fill = readCss(style, 'background');
    sh.fill = type === 'rect' ? fill || '' : '';
    return sh;
}

/**
 * QR and barcode types the engine can actually draw (BarcodeGenerator.getPattern).
 * Anything else returns a null pattern and the tag prints its raw value instead.
 */
export const CODE_TYPES = [
    { label: 'QR code', value: 'qr' },
    { label: 'Barcode (Code 128)', value: 'code128' },
    { label: 'Barcode (Code 39)', value: 'code39' }
];

export const DEFAULT_CODE = { field: '', type: 'qr', size: 200, height: 80 };

/**
 * Chart styles offered in the designer.
 *
 * Ordered by how often they are the right answer, not alphabetically — bar and
 * column carry most real reports. The cross-tab three are grouped last because
 * they need a second dimension (groupBy) to mean anything.
 */
export const CHART_STYLES = [
    { label: 'Bar (horizontal)', value: 'bar' },
    { label: 'Column (vertical)', value: 'column' },
    { label: 'Donut', value: 'donut' },
    { label: 'Pie', value: 'pie' },
    { label: 'Line', value: 'line' },
    { label: 'Area', value: 'area' },
    { label: 'Stacked bar (cross-tab)', value: 'stacked' },
    { label: 'Clustered column (cross-tab)', value: 'clustered' },
    { label: 'Pivot table (cross-tab)', value: 'pivot' }
];

/**
 * Chart element defaults.
 *
 * `relationship` + `field` are the child list and the field to bucket by — the
 * same two coordinates the {Chart:...} tag has always taken. Everything else is
 * presentation and maps 1:1 onto the tag's modifier string.
 */
export const DEFAULT_CHART = {
    relationship: '',
    field: '',
    style: 'bar',
    title: '',
    colors: '',
    split: '',
    groupBy: '',
    colSort: '',
    // Blank means the engine's default (12px). Set it when the chart lands in a frame
    // small enough that the default labels are hard to read — see chartToHtml.
    fontSize: ''
};

/**
 * Serializes a chart box to a {Chart:...} tag.
 *
 * The canvas emits HTML, and the merge engine already resolves {Chart:...} in
 * HTML — so a chart box needs no new rendering path on the server at all. It
 * writes the same tag a hand-authored template would, and inherits the whole
 * pipeline (client-side Chart.js rasterization, the Apex fallback, PNG-via-CV
 * embedding) for free.
 *
 * Width/height come from the box the author drew, so what they laid out is what
 * the chart is rendered at — no aspect-ratio drift between the artboard and the
 * finished document.
 */
/** Cross-tab styles cannot render from a single dimension. */
export const CROSS_TAB_CHART_STYLES = ['pivot', 'clustered', 'stacked'];

/**
 * What still has to be filled in before this chart can render, or null when it
 * is ready.
 *
 * One validator, used by both the serializer and the designer, so the artboard
 * can never disagree with what gets written to the template. The rules mirror
 * DocGenChartTagExpander exactly — it throws for a cross-tab style missing
 * groupBy, and again for one missing colSort, and those throws surface as red
 * error blocks in the finished document. Catching them here turns a generation
 * failure into a hint next to the box.
 */
export function chartConfigIssue(box) {
    const c = { ...DEFAULT_CHART, ...((box && box.chart) || {}) };
    if (!String(c.relationship || '').trim() || !String(c.field || '').trim()) {
        return 'Pick a related list and a field to group by.';
    }
    const style = String(c.style || 'bar').trim() || 'bar';
    if (CROSS_TAB_CHART_STYLES.indexOf(style) !== -1) {
        if (!String(c.groupBy || '').trim()) {
            return `A ${style} chart also needs a field to split the columns by.`;
        }
        if (!String(c.colSort || '').trim()) {
            return `A ${style} chart needs the column order listed, e.g. New,Existing.`;
        }
    }
    return null;
}

function chartToHtml(box) {
    const c = { ...DEFAULT_CHART, ...(box.chart || {}) };
    // Emit nothing at all rather than a tag the engine is guaranteed to reject.
    // A half-configured chart should read as "not finished yet" on the canvas,
    // not as a red error block in front of the customer.
    if (chartConfigIssue(box)) {
        return '';
    }
    const relationship = String(c.relationship || '').trim();
    const field = String(c.field || '').trim();

    const style = String(c.style || 'bar').trim() || 'bar';
    const opts = [];
    if (String(c.title || '').trim()) {
        opts.push('title=' + String(c.title).trim());
    }
    opts.push('width=' + inToCssPx(box.w));
    opts.push('height=' + inToCssPx(box.h));
    // Label size, when the author has set one. Left out entirely otherwise, so the
    // tag stays as short as it was and the engine's default applies.
    const fs = parseInt(c.fontSize, 10);
    if (fs > 0) {
        opts.push('fontSize=' + fs);
    }
    for (const key of ['groupBy', 'colSort', 'colors', 'split']) {
        const val = String(c[key] || '').trim();
        if (val) {
            opts.push(key + '=' + val);
        }
    }
    return '{Chart:' + relationship + ':' + field + ':' + style + ':' + opts.join('&') + '}';
}

/**
 * The box size a code will occupy, in inches.
 *
 * QR is square and sized in CSS px. A 1D barcode is sized WxH in px, which the renderer
 * converts to points at 3/4 — so the HEIGHT is exact, and that is the number an author
 * lays out against.
 *
 * The 1D WIDTH is a best estimate, and deliberately so: the engine picks the module
 * width from the encoded pattern (which depends on the record's value, unknown here)
 * and will widen a symbol that would otherwise fall below the scanner-readable floor.
 * Sizing the box to the request is the useful answer — it is what the author asked for
 * and what they are building around — but the panel says the final width follows the
 * data rather than pretending to a precision this cannot have.
 */
export function codeBoxSize(code) {
    const c = { ...DEFAULT_CODE, ...(code || {}) };
    const size = Math.max(24, parseFloat(c.size) || DEFAULT_CODE.size);
    if (c.type === 'qr') {
        return { w: round3(size / PX_PER_IN), h: round3(size / PX_PER_IN) };
    }
    const h = Math.max(24, parseFloat(c.height) || DEFAULT_CODE.height);
    return { w: round3(size / PX_PER_IN), h: round3(h / PX_PER_IN) };
}

export function newCodeBox(xIn, yIn) {
    const size = codeBoxSize(DEFAULT_CODE);
    return {
        id: nextId('box'),
        kind: 'code',
        mode: 'pinned',
        z: DEFAULT_Z,
        condition: '',
        style: { ...DEFAULT_STYLE, padding: 0 },
        code: { ...DEFAULT_CODE },
        x: round3(xIn),
        y: round3(yIn),
        w: size.w,
        h: size.h
    };
}

/**
 * A code box serializes to the engine's own barcode tag, `{*Field:type:size}` — the
 * engine replaces the whole tag with the drawn symbol, so there is no markup to wrap it
 * in. The authoring settings ride along as data attributes because the tag alone cannot
 * be read back into a type and a size once a size has been normalised away.
 */
function codeToHtml(box) {
    const c = { ...DEFAULT_CODE, ...(box.code || {}) };
    const field = String(c.field || '')
        .trim()
        .replace(/^\{\*?|\}$/g, '');
    if (!field) {
        return '';
    }
    const size = c.type === 'qr' ? String(c.size) : c.size + 'x' + c.height;
    return '{*' + field + ':' + c.type + ':' + size + '}';
}

function codeAttrs(box) {
    const c = { ...DEFAULT_CODE, ...(box.code || {}) };
    return (
        ' data-dg-code-type="' +
        c.type +
        '" data-dg-code-field="' +
        esc(c.field) +
        '" data-dg-code-size="' +
        c.size +
        '" data-dg-code-height="' +
        c.height +
        '"'
    );
}

function readCode(el) {
    return {
        type: el.getAttribute('data-dg-code-type') || DEFAULT_CODE.type,
        field: el.getAttribute('data-dg-code-field') || '',
        size: parseFloat(el.getAttribute('data-dg-code-size')) || DEFAULT_CODE.size,
        height: parseFloat(el.getAttribute('data-dg-code-height')) || DEFAULT_CODE.height
    };
}

/**
 * Chart config as data attributes.
 *
 * The {Chart:...} tag alone is not a sufficient record of the author's intent —
 * reloading would mean re-parsing a modifier string, and width/height in the tag
 * are derived from the box rather than chosen. Storing the config explicitly
 * makes the round trip exact, exactly as codeAttrs does for barcodes.
 */
function chartAttrs(box) {
    const c = { ...DEFAULT_CHART, ...(box.chart || {}) };
    return (
        ' data-dg-chart-rel="' +
        esc(c.relationship) +
        '" data-dg-chart-field="' +
        esc(c.field) +
        '" data-dg-chart-style="' +
        esc(c.style) +
        '" data-dg-chart-title="' +
        esc(c.title) +
        '" data-dg-chart-colors="' +
        esc(c.colors) +
        '" data-dg-chart-split="' +
        esc(c.split) +
        '" data-dg-chart-groupby="' +
        esc(c.groupBy) +
        '" data-dg-chart-colsort="' +
        esc(c.colSort) +
        '" data-dg-chart-fontsize="' +
        esc(c.fontSize) +
        '"'
    );
}

function readChart(el) {
    return {
        relationship: el.getAttribute('data-dg-chart-rel') || '',
        field: el.getAttribute('data-dg-chart-field') || '',
        style: el.getAttribute('data-dg-chart-style') || DEFAULT_CHART.style,
        title: el.getAttribute('data-dg-chart-title') || '',
        colors: el.getAttribute('data-dg-chart-colors') || '',
        split: el.getAttribute('data-dg-chart-split') || '',
        groupBy: el.getAttribute('data-dg-chart-groupby') || '',
        colSort: el.getAttribute('data-dg-chart-colsort') || '',
        fontSize: el.getAttribute('data-dg-chart-fontsize') || ''
    };
}

/**
 * Signature placement types the signing service recognises
 * (DocGenSignatureSenderController.parseSignaturePlacements). Anything else is
 * normalised to Full there, so offering more here would be offering choices that
 * silently collapse.
 */
export const SIGNATURE_TYPES = [
    { label: 'Signature', value: 'Full' },
    { label: 'Initials', value: 'Initials' },
    { label: 'Date signed', value: 'Date' },
    { label: 'Date picker', value: 'DatePick' }
];

export const DEFAULT_SIGNATURE = { role: 'Signer', order: 1, type: 'Full', inline: false };

/** A sensible footprint per type — initials and dates are small, a signature is not. */
export function signatureBoxSize(sig) {
    const t = (sig || {}).type || 'Full';
    if (t === 'Initials') {
        return { w: 1, h: 0.5 };
    }
    if (t === 'Date' || t === 'DatePick') {
        return { w: 1.6, h: 0.4 };
    }
    return { w: 2.6, h: 0.6 };
}

/**
 * A chart box starts at 4.5 x 2.8in — wide enough for category labels at a
 * readable size, and a shape the bar/column renderers fill without dead space.
 * The author resizes it and the tag's width/height follow, so the artboard
 * rectangle and the rendered chart always share an aspect ratio.
 */
export function newChartBox(xIn, yIn, wIn, hIn) {
    return {
        id: nextId('box'),
        kind: 'chart',
        mode: 'pinned',
        z: DEFAULT_Z,
        condition: '',
        style: { ...DEFAULT_STYLE, padding: 0 },
        chart: { ...DEFAULT_CHART },
        x: round3(xIn),
        y: round3(yIn),
        w: round3(wIn || 4.5),
        h: round3(hIn || 2.8)
    };
}

export function newSignatureBox(xIn, yIn) {
    const size = signatureBoxSize(DEFAULT_SIGNATURE);
    return {
        id: nextId('box'),
        kind: 'signature',
        mode: 'pinned',
        z: DEFAULT_Z,
        condition: '',
        style: { ...DEFAULT_STYLE, padding: 0 },
        signature: { ...DEFAULT_SIGNATURE },
        x: round3(xIn),
        y: round3(yIn),
        w: size.w,
        h: size.h
    };
}

/**
 * A signature box emits the signing service's own placement tag.
 *
 * `{@Signature_<Role>[:<order>][:<Type>[:inline]]}` — role underscored, because the
 * parser turns underscores back into spaces, so a role typed as "Account Manager"
 * has to travel as "Account_Manager" or it terminates the role at the first space.
 *
 * The tag is STRIPPED during ordinary generation and only preserved during a signature
 * send, which is deliberate — a generated PDF must never show a raw signing tag. It
 * also means Preview shows nothing where the box is, so the panel says so.
 */
function signatureToHtml(box) {
    const sig = { ...DEFAULT_SIGNATURE, ...(box.signature || {}) };
    const role = String(sig.role || 'Signer')
        .trim()
        .replace(/\s+/g, '_')
        .replace(/[^A-Za-z0-9_]/g, '');
    if (!role) {
        return '';
    }
    const order = parseInt(sig.order, 10) > 0 ? parseInt(sig.order, 10) : 1;
    let tag = '{@Signature_' + role + ':' + order + ':' + (sig.type || 'Full');
    if (sig.inline) {
        tag += ':inline';
    }
    return tag + '}';
}

function signatureAttrs(box) {
    const sig = { ...DEFAULT_SIGNATURE, ...(box.signature || {}) };
    return (
        ' data-dg-sig-role="' +
        esc(sig.role) +
        '" data-dg-sig-order="' +
        (sig.order || 1) +
        '" data-dg-sig-type="' +
        (sig.type || 'Full') +
        '" data-dg-sig-inline="' +
        (sig.inline ? '1' : '0') +
        '"'
    );
}

function readSignature(el) {
    return {
        role: el.getAttribute('data-dg-sig-role') || DEFAULT_SIGNATURE.role,
        order: parseInt(el.getAttribute('data-dg-sig-order'), 10) || 1,
        type: el.getAttribute('data-dg-sig-type') || DEFAULT_SIGNATURE.type,
        inline: el.getAttribute('data-dg-sig-inline') === '1'
    };
}

/** Field names that plausibly hold a number worth totalling. */
const NUMERIC_HINT =
    /(amount|total|price|cost|qty|quantity|count|sum|rate|discount|tax|subtotal|fee|balance|revenue|margin|hours|units)/i;

/**
 * Suggests a totals cell per column.
 *
 * Two things it deliberately gets right, both learned by looking at its own output:
 *
 *  - It carries the column's FORMAT through. A column showing
 *    {Amount:currency:USD} becomes {SUM:Rel.Amount:currency:USD}, because the engine
 *    supports format suffixes on aggregates and a raw unformatted total sitting under
 *    a column of formatted currency looks broken.
 *  - It does NOT suggest for fields that are not plausibly numeric. The first version
 *    happily proposed {SUM:Opportunities.Name}, which renders as an error or a zero.
 *    A blank cell the author fills in beats a confident wrong one.
 *
 * The numeric test is a name heuristic, not a describe — the canvas has no field
 * metadata. It is a suggestion the author edits, so a miss costs a keystroke; the
 * thing worth avoiding is a plausible-looking total that is nonsense.
 */
export function suggestTotals(table) {
    const rel = (table && table.relationship) || '';
    return (table.columns || []).map((c) => {
        const m = /^\{([A-Za-z0-9_.]+)((?::[^}]*)?)\}$/.exec((c.tag || '').trim());
        if (!rel || !m) {
            return '';
        }
        const field = m[1];
        const format = m[2] || '';
        if (!NUMERIC_HINT.test(field)) {
            return '';
        }
        return '{SUM:' + rel + '.' + field + format + '}';
    });
}

export function newArtboard() {
    return { id: nextId('board'), boxes: [] };
}

/**
 * A copy of an artboard, boxes and all, with fresh ids.
 *
 * Fresh ids matter: ids key the selection, the drag state and the DOM sync, so a
 * duplicated page sharing them would make selecting a box on page 2 highlight and drag
 * its twin on page 1.
 *
 * Deep-copied rather than shallow: boxes carry nested `table`, `image`, `shape` and
 * `code` objects, and sharing those references would make editing a column on the
 * duplicate silently change the original.
 */
export function cloneArtboard(board) {
    return {
        id: nextId('board'),
        boxes: (board.boxes || []).map((b) => ({
            ...JSON.parse(JSON.stringify(b)),
            id: nextId('box')
        }))
    };
}

export function blankDocument() {
    return { artboards: [newArtboard()] };
}

function round3(n) {
    return Math.round(n * 1000) / 1000;
}

export function inToPx(inches, zoom) {
    return inches * PX_PER_IN * (zoom || 1);
}

export function pxToIn(px, zoom) {
    return round3(px / (PX_PER_IN * (zoom || 1)));
}

/**
 * Clamps a box inside its artboard. Width and height are preserved where possible —
 * a box dragged off the right edge slides back in rather than being squashed, which
 * is what every design tool does and what authors expect.
 */
export function clampBox(box, geo) {
    const w = Math.min(box.w, geo.w);
    const h = Math.min(box.h, geo.h);
    return {
        ...box,
        w: round3(w),
        h: round3(h),
        x: round3(Math.max(0, Math.min(box.x, geo.w - w))),
        y: round3(Math.max(0, Math.min(box.y, geo.h - h)))
    };
}

/** Snap distance in inches. ~5px at 100%: close enough to feel magnetic, far enough
 *  that a deliberate 0.1in offset is still reachable. */
export const SNAP_IN = 0.05;

/**
 * Snaps a moving box to its neighbours and to the page, and reports which lines to
 * draw.
 *
 * Guides are computed from the MODEL in inches, not from measured pixels, so they
 * stay true at any zoom — a guide that drifts from the thing it claims to align to is
 * worse than no guide.
 *
 * Returns { x, y, guides: [{ axis: 'v'|'h', at: inches }] }.
 */
export function snapBox(box, others, geo) {
    const guides = [];
    const targetsX = [0, geo.w / 2, geo.w];
    const targetsY = [0, geo.h / 2, geo.h];
    for (const o of others) {
        targetsX.push(o.x, o.x + o.w / 2, o.x + o.w);
        targetsY.push(o.y, o.y + o.h / 2, o.y + o.h);
    }

    // Each edge of the moving box is a candidate; the offset converts an edge match
    // back into a box origin.
    const edgesX = [
        { at: box.x, offset: 0 },
        { at: box.x + box.w / 2, offset: box.w / 2 },
        { at: box.x + box.w, offset: box.w }
    ];
    const edgesY = [
        { at: box.y, offset: 0 },
        { at: box.y + box.h / 2, offset: box.h / 2 },
        { at: box.y + box.h, offset: box.h }
    ];

    let x = box.x;
    let y = box.y;
    let bestX = SNAP_IN;
    let bestY = SNAP_IN;
    for (const e of edgesX) {
        for (const t of targetsX) {
            const d = Math.abs(e.at - t);
            if (d < bestX) {
                bestX = d;
                x = round3(t - e.offset);
                guides.push({ axis: 'v', at: t });
            }
        }
    }
    for (const e of edgesY) {
        for (const t of targetsY) {
            const d = Math.abs(e.at - t);
            if (d < bestY) {
                bestY = d;
                y = round3(t - e.offset);
                guides.push({ axis: 'h', at: t });
            }
        }
    }
    // Only the winning line per axis is worth drawing — every near-miss considered
    // along the way would paint the canvas with lines that mean nothing.
    const finalGuides = [];
    const vHit = guides.filter((g) => g.axis === 'v').pop();
    const hHit = guides.filter((g) => g.axis === 'h').pop();
    if (vHit && bestX < SNAP_IN) finalGuides.push(vHit);
    if (hHit && bestY < SNAP_IN) finalGuides.push(hHit);
    return { x, y, guides: finalGuides };
}

// ---------------------------------------------------------------------------
// Serialization — model -> the CANVAS_CSS contract
// ---------------------------------------------------------------------------

/**
 * Every rule below was measured against a real Blob.toPdf render, not assumed.
 * See scripts/canvas-layout-model-probe.apex and docs/canvas-layout-model-p*.png.
 *
 *   min-height, never height   a pinned height is OVERRUN by growing merge content
 *                              instead of growing with it
 *   page-break-BEFORE          on each artboard after the first. page-break-after on
 *                              the previous one gets swallowed when a flow region
 *                              spills, and the next artboard then paints its pinned
 *                              boxes on top of the overflow
 */
/**
 * Delimits the DOCUMENT's own stylesheet from the canvas contract above it, so a
 * reload can tell the two apart and hand the author's CSS back unchanged.
 */
export const IMPORTED_CSS_MARK = '/* --- imported document css --- */';

/**
 * `minimal` drops the element-level defaults and keeps only the layout contract.
 *
 * Those defaults — a border and padding on every td/th, a margin under every p, the
 * list rules — are right for boxes an author drew here and WRONG for an imported
 * document, which arrives with its own stylesheet and its own opinions. Imposing them
 * drew borders on tables that had none and added space under every paragraph, which
 * pushed the Business Letter starter from one page to two.
 */
export function buildCanvasCss(geo, minimal) {
    const m = normalizeMargins(geo && geo.margins);
    return (
        '@page { size: ' +
        geo.css +
        '; margin: ' +
        m.top +
        'in ' +
        m.right +
        'in ' +
        m.bottom +
        'in ' +
        m.left +
        'in; }\n' +
        'body { font-family: Helvetica, Arial, sans-serif; font-size: 11pt; color: #1a1a1a; margin: 0; }\n' +
        // min-height moved to the artboards that NEED it (see serialize). It exists so a
        // page with pinned boxes occupies its full height; on a flow-only artboard it
        // pinned the block to exactly the content height, and a document that nearly
        // filled the page tipped onto a second one — measured on the Business Letter
        // starter, one page before conversion and two after, purely from this rule.
        '.dg-artboard { position: relative; width: ' +
        geo.w +
        'in; }\n' +
        '.dg-artboard_break { page-break-before: always; }\n' +
        '.dg-pin { position: absolute; }\n' +
        '.dg-flow { position: relative; }\n' +
        'thead { display: table-header-group; }\n' +
        (minimal
            ? ''
            : 'table { border-collapse: collapse; width: 100%; -fs-table-paginate: paginate; }\n' +
              'td, th { border: 0.5pt solid #999; padding: 2pt 4pt; }\n') +
        // Lists, stated explicitly and IDENTICALLY to the canvas rules in
        // docGenCanvas.css. Left to their defaults the two disagreed: the browser
        // suppresses markers under SLDS's reset while the engine applies its own
        // indent and spacing, so a list looked like plain lines while authoring and
        // came out numbered and loosely spaced in the PDF. One contract, both surfaces.
        (minimal ? '' : LIST_AND_PARAGRAPH_CSS)
    );
}

const LIST_AND_PARAGRAPH_CSS =
    'ol { list-style: decimal outside; margin: 0 0 0 1.5em; padding: 0; }\n' +
    'ul { list-style: disc outside; margin: 0 0 0 1.5em; padding: 0; }\n' +
    // Per-level markers, matching what the rich-text editor draws. Without these
    // every level numbered 1. 2. 3. again, so a nested item read as a new list
    // rather than a sub-point. Measured against a real render: 1. / 2. / a. /
    // i. / 3., with the indent accumulating per level.
    'ol ol { list-style: lower-alpha outside; }\n' +
    'ol ol ol { list-style: lower-roman outside; }\n' +
    'ul ul { list-style: circle outside; }\n' +
    'ul ul ul { list-style: square outside; }\n' +
    'li { display: list-item; margin: 0; padding: 0; }\n' +
    // The editor wraps each block in <p>. An engine paragraph margin then opens a
    // gap between list items that the canvas does not show.
    'p { margin: 0 0 0.06in 0; }\n';

/** Box styling as inline CSS. Only properties the engine honours are emitted. */
function styleCss(box) {
    const st = { ...DEFAULT_STYLE, ...(box.style || {}) };
    // A null property means "the document already says this" — emitting it would
    // override the source's own stylesheet with a canvas default.
    let css = '';
    if (st.font) css += 'font-family: ' + st.font + '; ';
    if (st.size) css += 'font-size: ' + st.size + 'pt; ';
    if (st.color) css += 'color: ' + st.color + '; ';
    if (st.align) css += 'text-align: ' + st.align + '; ';
    css += 'padding: ' + (st.padding || 0) + 'pt;';
    // Arial Unicode MS has no bold face in the PDF engine, so a bold it emits would
    // silently print regular — the canvas promises a weight the PDF cannot deliver.
    if (st.bold && canRenderBold(st.font)) css += ' font-weight: bold;';
    if (st.italic) css += ' font-style: italic;';
    if (st.underline) css += ' text-decoration: underline;';
    // A flat hex, never rgba(): rgba resolves to nothing in this engine and the fill
    // disappears completely rather than degrading to a solid colour.
    if (st.fill) css += ' background: ' + st.fill + ';';
    if (st.borderWidth > 0) css += ' border: ' + st.borderWidth + 'pt solid ' + st.borderColor + ';';
    return css;
}

/** Escapes only what would break the markup — merge tags must survive verbatim. */
/**
 * HTML-escape, including the double quote.
 *
 * The quote is not decoration. Most callers here write an ATTRIBUTE value delimited by
 * double quotes — data-dg-name, data-dg-if, data-dg-chart-title, the code and signature
 * fields — all of them free text an author types. Without it a chart titled
 * `Q1 "final" numbers` closes the attribute early and the rest of the tag becomes
 * garbage: the box came back with its name truncated at the quote and the attributes
 * after it lost entirely.
 *
 * Safe for the text-content callers too. `&quot;` renders as `"`, and the merge engine
 * already decodes it — DocGenService.evaluateIfExpression un-escapes
 * &gt;/&lt;/&amp;/&apos;/&quot; because Word escapes the same set in its text runs.
 */
function esc(v) {
    return String(v == null ? '' : v)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

/**
 * A table box becomes a real <table>. When a relationship is set, the {#Rel} wrapper
 * goes INSIDE <tbody> around the <tr> — that is the shape the merge engine's row
 * expansion looks for, and the same pattern the reference templates use. The header
 * lives in <thead> so it repeats on every continuation page.
 */
/**
 * The rules for one cell, per the table's grid style.
 *
 * `rows` draws a line UNDER each row and nothing between columns — the difference
 * between a document and a spreadsheet. `grid` is the old four-sided box. `none`
 * leaves the header band and the whitespace to do the work.
 */
function gridCss(t, where) {
    const w = t.gridWidth == null ? 0.75 : t.gridWidth;
    const color = t.gridColor || '#d5dde6';
    const pad = 'padding: ' + (t.cellPadding == null ? 6 : t.cellPadding) + 'pt;';
    const style = t.gridStyle || 'rows';
    if (style === 'grid') {
        return 'border: ' + w + 'pt solid ' + color + '; ' + pad;
    }
    if (style === 'none') {
        return 'border: 0; ' + pad;
    }
    // Header carries the heavier rule beneath it; body rows a hairline.
    return where === 'head'
        ? 'border: 0; border-bottom: ' + Math.max(w, 1) + 'pt solid ' + color + '; ' + pad
        : 'border: 0; border-bottom: ' + w + 'pt solid ' + color + '; ' + pad;
}

/** How many columns the nested row contributes, or 0 when there is no nested list. */
function subColCount(t) {
    const rel = String(t.subRelationship || '').trim();
    const subs = t.subColumns || [];
    return rel && subs.length ? subs.length : 0;
}

/**
 * The colspan attribute for a cell, or '' when it does not need one.
 *
 * Only the LAST cell of a short row stretches. Distributing the slack across every
 * cell would move the columns the author lined up; extending the final one keeps the
 * left edges where they were put, which is what the eye follows down a table.
 */
function spanAttr(index, rowLength, totalCols) {
    if (index !== rowLength - 1) {
        return '';
    }
    const span = Math.max(1, totalCols - rowLength + 1);
    return span > 1 ? ' colspan="' + span + '"' : '';
}

/** One totals cell, styled from the table's own totals settings. */
function totalsCell(t, tt, frame, value, span) {
    const fill = t.totalsFill ? ' background: ' + t.totalsFill + ';' : '';
    // A total is separated from the rows above it, which is what a reader looks for.
    const rule =
        (t.gridStyle || 'rows') === 'grid'
            ? ''
            : ' border-top: ' + Math.max(t.gridWidth == null ? 0.75 : t.gridWidth, 1) + 'pt solid #1f3a5f;';
    const css =
        frame +
        rule +
        ' font-size: ' +
        tt.size +
        'pt; color: ' +
        tt.color +
        '; text-align: ' +
        tt.align +
        ';' +
        (tt.bold && canRenderBold(tt.font) ? ' font-weight: bold;' : ' font-weight: normal;') +
        fill;
    return '<td' + (span || '') + ' style="' + css + '">' + (value || '') + '</td>';
}

/**
 * One nested row per grandchild record, wrapped in its own loop.
 *
 * The sub row carries its own columns, which are usually fewer than the parent's — a
 * line item is a product, a quantity and a price under an opportunity's four columns.
 * The last cell takes a colspan to fill the remainder so the grid stays square; without
 * it the table develops a ragged right edge wherever the counts differ.
 */
function subLoopRow(t, parentColCount, boxFont) {
    const rel = String(t.subRelationship || '').trim();
    const subs = t.subColumns || [];
    if (!rel || !subs.length) {
        return '';
    }
    const stx = { ...DEFAULT_SUB_TEXT, ...(t.subText || {}) };
    const frame = 'border: ' + t.gridWidth + 'pt solid ' + t.gridColor + '; padding: ' + t.cellPadding + 'pt;';
    const indent = t.subIndent == null ? 12 : t.subIndent;
    const base =
        frame +
        ' font-family: ' +
        (stx.font || boxFont || DEFAULT_STYLE.font) +
        '; font-size: ' +
        stx.size +
        'pt; color: ' +
        stx.color +
        '; text-align: ' +
        stx.align +
        ';' +
        (stx.bold && canRenderBold(stx.font || boxFont) ? ' font-weight: bold;' : ' font-weight: normal;') +
        (t.subFill ? ' background: ' + t.subFill + ';' : '');
    const cells = subs
        .map((c, i) => {
            const pad = i === 0 ? ' padding-left: ' + (t.cellPadding + indent) + 'pt;' : '';
            return (
                '<td' +
                spanAttr(i, subs.length, parentColCount) +
                ' style="' +
                base +
                pad +
                '">' +
                (c.tag || '') +
                '</td>'
            );
        })
        .join('');
    return (
        '{#' +
        rel +
        '}<tr data-dg-row="subloop" data-dg-subrel="' +
        esc(rel) +
        '">' +
        cells +
        '</tr>{/' +
        loopCloseKey(rel) +
        '}'
    );
}

/**
 * The closing tag for a loop opener, mirroring the engine's own rule (#310).
 *
 * Some openers carry ARGUMENTS the closer does not repeat. The engine balances
 * on the bare key — DocGenChartBucketResolver's close tag is the literal
 * `{/ChartBucket}` — but the serializer emitted `'{/' + relationship + '}'`,
 * so a table bound to `ChartBucket:Rel:Field` closed with
 * `{/ChartBucket:Rel:Field}`, which nothing matches. The block was left
 * unresolved and the table printed its raw tags.
 *
 * That made a chart with its numbers in a table beside it — the commonest chart
 * layout there is — authorable in Word and HTML but NOT in Canvas.
 *
 * This mirrors DocGenTemplateLinter.balanceKey, which mirrors
 * DocGenService.findBalancedEnd. Keep the three in step.
 */
function loopCloseKey(rel) {
    const name = String(rel || '').trim();
    const upper = name.toUpperCase();
    if (upper === 'IF' || upper.startsWith('IF ')) {
        return 'IF';
    }
    if (upper === 'GROUPBY' || upper.startsWith('GROUPBY ')) {
        return 'GroupBy';
    }
    if (upper === 'CHARTBUCKET' || upper.startsWith('CHARTBUCKET:')) {
        return 'ChartBucket';
    }
    return name;
}

function tableToHtml(box) {
    const t = box.table || {};
    const cols = t.columns || [];
    const st = { ...DEFAULT_STYLE, ...(box.style || {}) };
    const ht = { ...DEFAULT_HEADER_TEXT, ...(t.headerText || {}) };
    const rt = { ...DEFAULT_ROW_TEXT, ...(t.rowText || {}) };
    // Typography goes onto the CELLS, not left to inherit. Flying Saucer gives tables
    // their own defaults, so a cell inheriting nothing renders at the engine's font no
    // matter what the box says — and the canvas would stop matching the PDF.
    // Each band may name its OWN family, falling back to the box's. A heading in a
    // different face from its data is an ordinary thing to want, and the font was the
    // one typographic property these sections could not set.
    const typo = (x) =>
        ' font-family: ' +
        (x.font || st.font) +
        '; font-size: ' +
        x.size +
        'pt; color: ' +
        x.color +
        '; text-align: ' +
        x.align +
        ';' +
        (x.bold && canRenderBold(x.font || st.font) ? ' font-weight: bold;' : ' font-weight: normal;');
    const frame = gridCss(t, 'body');
    const cellCss = frame + typo(rt);
    const headCss = gridCss(t, 'head') + typo(ht);
    const tt = { ...DEFAULT_TOTALS_TEXT, ...(t.totalsText || {}) };
    // The table is as wide as its WIDEST row, and every shorter row's last cell
    // stretches to reach that width.
    //
    // A nested list often has more columns than its parent — "Opportunity Name" above
    // "Product · Quantity" is the ordinary case. Sizing the table to the parent alone
    // left the extra nested cells to add columns of their own, and the parent's single
    // cell then sat in the first narrow one with the rest of the row empty beside it.
    // Handling only the opposite case (parent wider than nested) was half a rule.
    const totalCols = Math.max(cols.length, subColCount(t));
    let out =
        '<table data-dg-grid="' +
        (t.gridStyle || 'rows') +
        '" style="border-collapse: collapse; width: 100%; -fs-table-paginate: paginate;">';
    if (t.showHeader) {
        out += '<thead style="display: table-header-group;"><tr>';
        cols.forEach((c, i) => {
            const w = c.width ? ' width: ' + c.width + ';' : '';
            out +=
                '<th' +
                spanAttr(i, cols.length, totalCols) +
                ' style="' +
                headCss +
                w +
                ' background: ' +
                t.headerFill +
                ';">' +
                esc(c.label) +
                '</th>';
        });
        out += '</tr></thead>';
    }
    const cell = (v, i) =>
        '<td' + spanAttr(i, cols.length, totalCols) + ' style="' + cellCss + '">' + (v || '') + '</td>';
    // data-dg-row is why rows survive a round-trip. The first version INFERRED roles
    // ("the last row is totals if its first cell is bold"); any cell the browser
    // re-serialized differently broke the guess, so a totals row came back as a
    // literal row AND a fresh totals row was appended on the next save. Rows
    // multiplied every time the template was opened.
    const loopRow = '<tr data-dg-row="loop">' + cols.map((c, i) => cell(c.tag, i)).join('') + '</tr>';
    const subRow = subLoopRow(t, totalCols, st.font);
    out += '<tbody>';
    if (t.relationship) {
        // The sub loop lives INSIDE the parent loop, after the parent's row, so each
        // parent record is followed by its own children. Outside it, the grandchildren
        // would all pile up once at the end under whichever parent happened to be last.
        out += '{#' + t.relationship + '}' + loopRow + subRow + '{/' + loopCloseKey(t.relationship) + '}';
    } else if (!(t.rows || []).length) {
        // No loop and no literal rows — keep one row so the table is not just a header.
        out += loopRow;
    }
    for (const r of t.rows || []) {
        out += '<tr data-dg-row="extra">' + cols.map((c, i) => cell(esc(r[i] || ''), i)).join('') + '</tr>';
    }
    if (t.totals && t.totals.enabled) {
        const tc = t.totals.cells || [];
        out +=
            '<tr data-dg-row="totals">' +
            cols.map((c, i) => totalsCell(t, tt, frame, tc[i], spanAttr(i, cols.length, totalCols))).join('') +
            '</tr>';
    }
    out += '</tbody></table>';
    return out;
}

/**
 * The table as the CANVAS should show it: same cells, same widths, same borders, but
 * the {#Rel} loop markers replaced by two sample rows. Showing the raw marker would
 * put stray text in the artboard; showing one row would hide the fact that it repeats.
 */
export function tablePreviewHtml(box) {
    const t = box.table || {};
    const cols = t.columns || [];
    const st = { ...DEFAULT_STYLE, ...(box.style || {}) };
    const ht = { ...DEFAULT_HEADER_TEXT, ...(t.headerText || {}) };
    const rt = { ...DEFAULT_ROW_TEXT, ...(t.rowText || {}) };
    // Each band may name its OWN family, falling back to the box's. A heading in a
    // different face from its data is an ordinary thing to want, and the font was the
    // one typographic property these sections could not set.
    const typo = (x) =>
        ' font-family: ' +
        (x.font || st.font) +
        '; font-size: ' +
        x.size +
        'pt; color: ' +
        x.color +
        '; text-align: ' +
        x.align +
        ';' +
        (x.bold && canRenderBold(x.font || st.font) ? ' font-weight: bold;' : ' font-weight: normal;');
    const frame = gridCss(t, 'body');
    const cellCss = frame + typo(rt);
    const headCss = gridCss(t, 'head') + typo(ht);
    // Declared before the header uses it. Same widest-row rule as the serializer, or
    // the canvas would draw a table the PDF does not.
    const subRelPv = (t.subRelationship || '').trim();
    const subsPv = t.subColumns || [];
    const pvTotal = Math.max(cols.length, subRelPv && subsPv.length ? subsPv.length : 0);
    let out = '<table style="border-collapse: collapse; width: 100%;">';
    if (t.showHeader) {
        out += '<thead><tr>';
        cols.forEach((c, ci) => {
            const w = c.width ? ' width: ' + c.width + ';' : '';
            out +=
                '<th' +
                spanAttr(ci, cols.length, pvTotal) +
                ' style="' +
                headCss +
                w +
                ' background: ' +
                t.headerFill +
                ';">' +
                esc(c.label) +
                '</th>';
        });
        out += '</tr></thead>';
    }
    out += '<tbody>';
    // The repeating body. Two sample rows when bound to a relationship, so it reads as
    // a list rather than a single row.
    const sampleRows = t.relationship ? 2 : (t.rows || []).length ? 0 : 1;
    const subRel = (t.subRelationship || '').trim();
    const subs = t.subColumns || [];
    const stx = { ...DEFAULT_SUB_TEXT, ...(t.subText || {}) };
    const indent = t.subIndent == null ? 12 : t.subIndent;

    for (let i = 0; i < sampleRows; i++) {
        out +=
            '<tr>' +
            cols
                .map(
                    (c, i) =>
                        '<td' +
                        spanAttr(i, cols.length, pvTotal) +
                        ' style="' +
                        cellCss +
                        '">' +
                        esc(c.tag || '') +
                        '</td>'
                )
                .join('') +
            '</tr>';
        if (subRel && subs.length) {
            // Drawn under EVERY sample parent row, because that is where it prints —
            // showing it once at the bottom would misrepresent the nesting.
            const scss =
                frame +
                ' font-size: ' +
                stx.size +
                'pt; color: ' +
                stx.color +
                '; text-align: ' +
                stx.align +
                ';' +
                (stx.bold ? ' font-weight: bold;' : ' font-weight: normal;') +
                (t.subFill ? ' background: ' + t.subFill + ';' : '');
            out +=
                '<tr>' +
                subs
                    .map((c, j) => {
                        const pad = j === 0 ? ' padding-left: ' + (t.cellPadding + indent) + 'pt;' : '';
                        return (
                            '<td' +
                            spanAttr(j, subs.length, pvTotal) +
                            ' style="' +
                            scss +
                            pad +
                            '">' +
                            esc(c.tag || '') +
                            '</td>'
                        );
                    })
                    .join('') +
                '</tr>';
        }
    }
    if (t.relationship) {
        out +=
            '<tr><td colspan="' +
            Math.max(1, pvTotal) +
            '" style="' +
            cellCss +
            ' font-style: italic; color: #6b7280;">… one row per ' +
            esc(t.relationship) +
            ' record</td></tr>';
    }
    // Extra rows and the totals band, drawn exactly as they serialize. Leaving them out
    // meant an author added a row, saw nothing change on the page, and could only find
    // out whether it worked by generating a PDF.
    for (const r of t.rows || []) {
        out +=
            '<tr>' + cols.map((c, i) => '<td style="' + cellCss + '">' + esc(r[i] || '') + '</td>').join('') + '</tr>';
    }
    if (t.totals && t.totals.enabled) {
        const tt = { ...DEFAULT_TOTALS_TEXT, ...(t.totalsText || {}) };
        const tc = t.totals.cells || [];
        out += '<tr>' + cols.map((c, i) => totalsCell(t, tt, frame, esc(tc[i] || ''))).join('') + '</tr>';
    }
    out += '</tbody></table>';
    return out;
}

/**
 * The markup a box may carry, and the only markup the PDF engine reliably renders.
 *
 * lightning-input-rich-text emits whatever its toolbar produced, which is more than
 * Flying Saucer honours and occasionally things it chokes on. Reducing it here means
 * the canvas and the PDF agree, and that a paste from a web page cannot inject an
 * absolutely-positioned div into an artboard whose whole layout contract is position.
 *
 * TABLE tags are allowed: authoring a table inside the text box is the point of moving
 * editing into the panel, and tables render correctly (measured — nested tables and
 * per-cell borders both work).
 */
/**
 * Tags whose TEXT is not content, so unwrapping them is wrong.
 *
 * The rule below is "unwrap, never delete", which is right for a stray <section> —
 * the words inside it are what the author wrote. It is wrong for these: their text is
 * CSS or script source, and unwrapping prints it on the page. Paste a whole HTML
 * document into a box's HTML editor and "@page { size: Letter portrait; ... }" landed
 * on the artboard as visible body text.
 */
const DROP_SUBTREE_TAGS = new Set(['STYLE', 'SCRIPT', 'HEAD', 'TITLE', 'META', 'LINK', 'BASE', 'NOSCRIPT']);

const SAFE_TAGS = new Set([
    // Anchors survive because the output honours them: Blob.toPdf emits a real /Link
    // annotation for an http(s) href and a /GoTo jump for an in-document #anchor.
    // Their href is filtered by scheme below — it is the one attribute here that can
    // carry executable content.
    'A',
    'B',
    'STRONG',
    'I',
    'EM',
    'U',
    'S',
    'STRIKE',
    'BR',
    'SPAN',
    'P',
    'DIV',
    'UL',
    'OL',
    'LI',
    'TABLE',
    'THEAD',
    'TBODY',
    'TR',
    'TD',
    'TH',
    'H1',
    'H2',
    'H3',
    'H4',
    'H5',
    'H6'
]);

/** Only properties measured to work. rgba and opacity are dropped on purpose: rgba
 *  renders NOTHING in this engine and opacity is ignored, so both are traps. */
const SAFE_STYLE = [
    'color',
    'background-color',
    'font-weight',
    'font-style',
    'text-decoration',
    'font-size',
    'font-family',
    'text-align',
    // Margin is how a document spaces its own paragraphs. Stripping it flattened every
    // imported block against its neighbour and changed where text wrapped.
    'margin',
    'margin-top',
    'margin-right',
    'margin-bottom',
    'margin-left',
    'width',
    'height',
    'border',
    // PER-SIDE borders, spelled out. The matcher requires a colon straight after the
    // property name, so `border` never matched `border-bottom:` — and a rule under a
    // row is exactly how a well-set table is drawn. Every imported table lost its
    // horizontal rules and came back as a borderless block, and a table pasted into a
    // box's HTML view lost them the same way.
    'border-top',
    'border-right',
    'border-bottom',
    'border-left',
    'border-color',
    'border-width',
    'border-style',
    'border-collapse',
    'background',
    'padding',
    'padding-top',
    'padding-right',
    'padding-bottom',
    'padding-left',
    'vertical-align'
];

function dropUnsafeStyle(value) {
    // A colour the engine cannot resolve is worse than no colour: rgba() makes the
    // whole background disappear rather than degrading.
    return /rgba?\(|hsla?\(|var\(|calc\(/i.test(value || '');
}

/**
 * Repairs merge tags that inline formatting has cut in half.
 *
 * Select the middle of {Description}, press italic, and the editor emits
 * `{De<i>scription}</i>` — the tag now spans an element boundary, so the merge engine
 * never sees `{Description}` and the reader gets the braces printed literally. It is
 * silent: nothing errors, the tag simply does not resolve.
 *
 * This is the same failure Word has had for years (issue #130, tags split across runs
 * by character formatting), arriving on the canvas by a different route. The fix is
 * the same shape: a tag is an atom, so any markup INSIDE the braces is dropped and the
 * formatting around it survives. Losing italic on one word beats shipping a document
 * with {De scription} printed in it.
 */
function healSplitTags(html) {
    return String(html == null ? '' : html).replace(/\{[^{}]*\}/g, (tag) =>
        tag.indexOf('<') === -1 ? tag : tag.replace(/<[^>]*>/g, '')
    );
}

/**
 * Escaped braces are LEFT ESCAPED, deliberately.
 *
 * There was a decodeBraces() step here that turned `&#123;` back into `{` on the theory
 * that a rich-text editor might normalise a brace and break a merge tag. It was added
 * speculatively and never proven, and the import fidelity harness caught what it
 * actually did: the shipped starters write `&#123;CloseDate:MMMM d, yyyy&#125;` as
 * DOCUMENTATION — text showing an author what a format suffix looks like — and decoding
 * turned that example into a live merge tag that would print the record's close date.
 *
 * An escaped brace is someone asking for a literal brace. Activating it is silent
 * corruption of the exact kind this editor keeps finding. If an editor is ever proven
 * to mangle a real tag, fix it where that is demonstrated, not by rewriting every
 * brace in the document.
 */
// A brace is a plain character in HTML, so parsing `&#123;` into a DOM and reading it
// back yields `{` — the entity is normalised away by the browser, not by us. Escaped
// braces therefore cannot survive a round trip unless they are hidden from the parser
// first. These sentinels use characters that cannot appear in authored markup.
const LB_SENTINEL = '\u0001DGLB\u0001';
const RB_SENTINEL = '\u0001DGRB\u0001';

function hideEscapedBraces(html) {
    return String(html == null ? '' : html)
        .replace(/&#0*123;|&#x0*7b;|&lbrace;/gi, LB_SENTINEL)
        .replace(/&#0*125;|&#x0*7d;|&rbrace;/gi, RB_SENTINEL);
}

function restoreEscapedBraces(html) {
    return String(html == null ? '' : html)
        .split(LB_SENTINEL)
        .join('&#123;')
        .split(RB_SENTINEL)
        .join('&#125;');
}

/**
 * An href the document may carry, or null.
 *
 * Allows http, https and in-document #anchors — the three the PDF actually turns into
 * annotations. Everything else is refused rather than filtered: `javascript:` and
 * `data:` are the reason this function exists, and a scheme allow-list cannot be
 * outflanked by encoding tricks the way a blocklist can.
 */
function safeHref(raw) {
    const v = String(raw == null ? '' : raw).trim();
    if (!v) {
        return null;
    }
    if (v.startsWith('#')) {
        return v;
    }
    return /^https?:\/\//i.test(v) ? v : null;
}

export function sanitizeInline(html) {
    const tpl = document.createElement('template');
    // Heal first, then parse: stripping tags out of the braces can leave an orphan
    // closing tag, and the parser is what tidies that up.
    // eslint-disable-next-line @lwc/lwc/no-inner-html
    tpl.innerHTML = healSplitTags(hideEscapedBraces(html));
    const walk = (node) => {
        for (const child of [...node.childNodes]) {
            if (child.nodeType === 3) {
                continue;
            }
            if (child.nodeType !== 1) {
                child.remove();
                continue;
            }
            if (DROP_SUBTREE_TAGS.has(child.tagName)) {
                // Deleted outright, contents and all. See DROP_SUBTREE_TAGS.
                child.remove();
                continue;
            }
            if (!SAFE_TAGS.has(child.tagName)) {
                // Unwrap, never delete — the TEXT the author wrote is the point.
                while (child.firstChild) node.insertBefore(child.firstChild, child);
                child.remove();
                continue;
            }
            const keep = [];
            const style = child.getAttribute('style');
            if (style) {
                for (const prop of SAFE_STYLE) {
                    const m = new RegExp('(?:^|;)\\s*' + prop + '\\s*:\\s*([^;]+)').exec(style);
                    if (m && !dropUnsafeStyle(m[1])) {
                        keep.push(prop + ': ' + m[1].trim());
                    }
                }
            }
            const colspan = child.getAttribute('colspan');
            const rowspan = child.getAttribute('rowspan');
            const href = child.tagName === 'A' ? safeHref(child.getAttribute('href')) : null;
            for (const attr of [...child.attributes]) child.removeAttribute(attr.name);
            if (keep.length) child.setAttribute('style', keep.join('; '));
            if (colspan) child.setAttribute('colspan', colspan);
            if (rowspan) child.setAttribute('rowspan', rowspan);
            if (href) child.setAttribute('href', href);
            walk(child);
        }
    };
    walk(tpl.content);
    // READ of this function's own just-sanitized output, off a detached <template>.
    // Nothing is written to a live document here.
    // eslint-disable-next-line @lwc/lwc/no-inner-html
    return restoreEscapedBraces(tpl.innerHTML);
}

/**
 * Inline formatting marks, applied to a SELECTION inside the plain-text box.
 *
 * Marks in the text rather than HTML in a contenteditable, deliberately. A
 * contenteditable box reintroduces Lightning's "/" hotkey stealing focus mid-typing —
 * measured, not theorised — because Lightning binds it on window capture and LWS does
 * not deliver window-capture listeners to component code. A textarea is exempt from
 * those shortcuts, so keeping the box a textarea keeps typing safe; the formatting
 * rides along as marks the serializer expands.
 *
 * Chosen to be things nobody types by accident in a business document, and to avoid
 * the braces and colons that merge tags already use.
 */
export const INLINE_MARKS = [
    { name: 'bold', open: '**', close: '**', tag: 'b' },
    { name: 'italic', open: '//', close: '//', tag: 'i' },
    { name: 'underline', open: '__', close: '__', tag: 'u' },
    { name: 'strike', open: '~~', close: '~~', tag: 's' }
];

function escapeRe(v) {
    return v.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Expands inline marks into tags. Runs on ALREADY-ESCAPED text, so a literal "<" the
 * author typed stays escaped and only the marks become markup.
 */
function expandMarks(escaped) {
    let out = escaped;
    for (const m of INLINE_MARKS) {
        const re = new RegExp(escapeRe(m.open) + '([\\s\\S]+?)' + escapeRe(m.close), 'g');
        out = out.replace(re, '<' + m.tag + '>$1</' + m.tag + '>');
    }
    return out;
}

/** Inverse of expandMarks, for reading a stored document back into the editor. */
export function collapseMarks(html) {
    let out = String(html == null ? '' : html);
    for (const m of INLINE_MARKS) {
        const re = new RegExp('<' + m.tag + '>([\\s\\S]*?)</' + m.tag + '>', 'gi');
        out = out.replace(re, m.open + '$1' + m.close);
    }
    return out;
}

/**
 * Plain text to safe markup: escaped, marks expanded, newlines becoming line breaks.
 *
 * Escaping does NOT break conditionals that use angle brackets. `{#IF Amount > 100}`
 * serializes as `{#IF Amount &gt; 100}` and the engine decodes it —
 * DocGenService.evaluateIfExpression already un-escapes &gt;/&lt;/&amp;/&apos;/&quot;
 * because Word escapes exactly the same characters in its text runs. Do not "fix" this
 * by leaving text unescaped: a stray `<` in someone's address block would then break
 * the document's markup.
 */
function textToHtml(box) {
    // A box edited in the rich-text editor carries `html`, and that is what the author
    // actually sees. Serializing `text` here meant every bold, bullet and colour was
    // dropped on the way to the PDF while the canvas kept showing them — the editor
    // silently stopped being WYSIWYG. `text` remains the fallback for boxes authored
    // before the rich-text editor existed, and for a box whose html was cleared.
    if (box.html != null && String(box.html).trim() !== '') {
        // Guarded so the serializer stays runnable without a DOM — scripts/qa/
        // canvas-serializer-check.mjs is a pure-Node guard on exactly these rules, and
        // a serializer that only runs in a browser cannot be checked before it ships.
        // The html was already sanitized on the way IN (handleRichTextChange) and again
        // on load, so the brace repair is what actually has to happen here.
        return typeof document === 'undefined' ? box.html : sanitizeInline(box.html);
    }
    return expandMarks(esc(box.text == null ? '' : box.text)).replace(/\n/g, '<br />');
}

/**
 * A flow box's vertical margin is the GAP from the previous flow box, not its y.
 *
 * This is the whole mechanism behind "a table that grows pushes what is under it
 * down". Flow boxes sit in normal flow, so margin-top is measured from the bottom of
 * the one before — emitting the box's absolute y there put a box authored at y=5in
 * five inches BELOW the table instead of five inches down the page, and the error
 * compounded with every additional flow box.
 *
 * Computing the gap means the layout matches the canvas exactly at minimum content,
 * and everything after a growing table moves down by however much it grew. Pinned
 * boxes are absolute and take no part in this, which is precisely what pinning is for.
 */
function flowMarginTop(box, cursor) {
    return round3(Math.max(0, box.y - cursor));
}

/**
 * The AUTHORING coordinates, carried as data attributes.
 *
 * The CSS is a rendering instruction, not a record of what the author did — and for a
 * flow box the two genuinely differ: its margin is the GAP from the previous flow box,
 * not its position on the page. Reading that margin back as the box's y collapsed
 * flow boxes toward the top on every reload, and because height was never stored
 * either, the next save recomputed the gaps from wrong heights and the drift
 * compounded.
 *
 * Storing x/y/w/h/mode explicitly makes the round trip exact no matter how the CSS is
 * derived, which also means the layout maths can change later without corrupting
 * documents saved under the old rules. Flying Saucer ignores unknown attributes.
 */
function authoringAttrs(box, withId) {
    if (box.kind === 'code') {
        return baseAuthoringAttrs(box, withId) + codeAttrs(box);
    }
    if (box.kind === 'signature') {
        return baseAuthoringAttrs(box, withId) + signatureAttrs(box);
    }
    if (box.kind === 'chart') {
        return baseAuthoringAttrs(box, withId) + chartAttrs(box);
    }
    return baseAuthoringAttrs(box, withId);
}

function baseAuthoringAttrs(box, withId) {
    return (
        // The box's OWN id, so an anchor saved against it can be resolved on the way
        // back in. deserialize mints fresh ids, so a bare data-dg-anchor holding last
        // session's id is not merely stale — the ids are sequential, so it usually
        // still MATCHES, just a different box. Links silently re-pointed at whatever
        // landed on that number this time. See the remap in deserialize.
        //
        // Only group members get one. An id is per-session and renumbers on every
        // save, so emitting it everywhere would make exported HTML churn on documents
        // that have no links at all — and an unlinked box has nothing to resolve.
        (withId ? ' data-dg-id="' + esc(box.id || '') + '"' : '') +
        ' data-dg-x="' +
        box.x +
        '" data-dg-y="' +
        box.y +
        '"' +
        ' data-dg-w="' +
        box.w +
        '" data-dg-h="' +
        box.h +
        '"' +
        ' data-dg-mode="' +
        (box.mode === 'flow' ? 'flow' : 'pinned') +
        '"' +
        ' data-dg-z="' +
        (box.z || 0) +
        '"' +
        // Position mode and anchor ride as attributes for the same reason the
        // geometry does: the emitted CSS is a rendering instruction, and for a
        // grouped member it no longer describes where the author put it.
        // The author's own name for the block. Emitted only when set, so an unnamed
        // document's markup is byte-for-byte what it was before naming existed.
        (box.name ? ' data-dg-name="' + esc(box.name) + '"' : '') +
        (box.positionMode === 'follows' && box.anchorTo ? ' data-dg-anchor="' + esc(box.anchorTo) + '"' : '') +
        (box.keepTogether ? ' data-dg-keep="1"' : '') +
        (box.condition ? ' data-dg-if="' + esc(box.condition) + '"' : '')
    );
}

/**
 * The width to EMIT so the box's outer edge lands where the author put it.
 *
 * Flying Saucer is CSS 2.1: `width` is the CONTENT box, and border and padding are
 * added outside it. `box-sizing: border-box` does not help — measured against a real
 * render (a 4in box with a 12pt border put its content edge at 300pt with and without
 * the property, versus 288pt for no border at all), so the engine ignores it outright.
 *
 * The consequence was a box dragged to the right edge of the page being clipped: it
 * occupied its authored width PLUS twice its border and padding, and the excess fell
 * off the paper. The canvas showed it correctly because the browser does honour
 * border-box, so the editor and the PDF disagreed by exactly that much on every
 * bordered or padded box.
 *
 * Subtracting here makes the emitted box measure the authored width from outer edge to
 * outer edge, which is what the author dragged and what the canvas draws.
 */
function outerToContentWidth(box) {
    const st = { ...DEFAULT_STYLE, ...(box.style || {}) };
    const chromePt = 2 * ((st.borderWidth > 0 ? st.borderWidth : 0) + (st.padding || 0));
    // 72pt to the inch. Never below a hair's width: a narrow box with a fat border
    // would otherwise ask for a negative width, which the engine treats as auto and
    // lets run the full width of the page — the very failure being fixed.
    return round3(Math.max(0.05, box.w - chromePt / 72));
}

/** Height counterpart to outerToContentWidth, for the children that declare one. */
function outerToContentHeight(box) {
    const st = { ...DEFAULT_STYLE, ...(box.style || {}) };
    const chromePt = 2 * ((st.borderWidth > 0 ? st.borderWidth : 0) + (st.padding || 0));
    return round3(Math.max(0.02, box.h - chromePt / 72));
}

/**
 * Wraps a box in {#IF …}…{/IF} when it carries a condition.
 *
 * The tags sit OUTSIDE the box's div, so a false condition removes the element
 * entirely rather than leaving an empty bordered rectangle behind — which is what
 * putting them inside would do, and is not what "show only when" means.
 *
 * The expression is escaped like any other text. That does not break it: the engine's
 * evaluateIfExpression un-escapes &gt; / &lt; / &amp; before evaluating, because Word
 * escapes exactly the same characters in its text runs. Leaving it raw would put an
 * unescaped `<` into the markup and break the document.
 */
function wrapCondition(box, inner) {
    const cond = String(box.condition || '').trim();
    if (!cond) {
        return inner;
    }
    return '{#IF ' + esc(cond) + '}' + inner + '{/IF}';
}

/**
 * How a box decides where to sit. Mutually exclusive by nature — an element
 * cannot both hold its spot and travel with something else — so this is a mode,
 * not a set of flags.
 *
 * 'repeat' (appears on every page) is deliberately absent: it is a different
 * mechanism, not a third position. CSS cannot repeat an in-flow element, so it
 * has to be lifted out of the artboard into Header_Html__c/Footer_Html__c.
 */
export const POSITION_MODES = [
    { label: 'Stays put', value: 'fixed' },
    { label: 'Moves with another element', value: 'follows' }
];

export const DEFAULT_POSITION_MODE = 'fixed';

/** True when the box travels with an anchor rather than holding its spot. */
function isFollower(box) {
    return box && box.positionMode === 'follows' && !!box.anchorTo;
}

/**
 * Walks a box up to the head of its anchor chain.
 *
 * Returns null when the chain is broken (anchor deleted) or cyclic. Both are
 * reachable from the UI — delete a target, or link A to B and B back to A — so
 * neither can be allowed to reach the serializer. The visited set is what stops
 * a cycle spinning forever.
 */
export function anchorRoot(box, byId) {
    let cur = box;
    const seen = new Set();
    while (isFollower(cur)) {
        if (seen.has(cur.id)) {
            return null; // cycle
        }
        seen.add(cur.id);
        const next = byId.get(cur.anchorTo);
        if (!next) {
            return null; // anchor was deleted
        }
        cur = next;
    }
    return cur;
}

/**
 * Would linking `box` to `candidate` close a loop?
 *
 * A cycle is one click away in the picker — link A to B, then B to A — and it has to
 * be stopped BEFORE it reaches the model, not detected afterwards. anchorRoot survives
 * a cycle by returning null, which drops the whole set to singletons: both boxes
 * quietly stop travelling together and nothing says why. Far better to grey the option
 * out and never let it happen.
 *
 * Walks up from the candidate: if the chain above it passes through `box`, then making
 * `box` follow it closes the loop.
 */
export function wouldCycle(box, candidateId, byId) {
    if (!box || !candidateId || candidateId === box.id) {
        return true;
    }
    let cur = byId.get(candidateId);
    const seen = new Set();
    while (cur) {
        if (cur.id === box.id) {
            return true;
        }
        if (seen.has(cur.id)) {
            return true; // the candidate is already in a loop of its own
        }
        seen.add(cur.id);
        cur = isFollower(cur) ? byId.get(cur.anchorTo) : null;
    }
    return false;
}

/**
 * A short human name for a box, for the anchor picker and the artboard badge.
 *
 * Boxes have no user-given name, so this is derived. A table says which relationship
 * it lists, because "Contacts table" is how an author refers to it; everything else
 * leads with its own first few words, which is what they actually recognise on the
 * page. Falls back to the kind so an empty box is still selectable rather than a blank
 * row in the dropdown.
 */
export function boxLabel(box) {
    if (!box) {
        return '';
    }
    // An author-given name always wins. Everything below it is a guess derived from
    // content, and a guess is only useful until someone has said what the thing is —
    // which is the whole reason naming exists. Truncated on the same rule as derived
    // text so one long name cannot stretch the picker.
    if (box.name && box.name.trim()) {
        const n = box.name.trim();
        return n.length > 32 ? n.slice(0, 32).trim() + '…' : n;
    }
    if (box.kind === 'table') {
        const rel = box.table && box.table.relationship;
        return rel ? rel + ' table' : 'Table';
    }
    if (box.kind === 'chart') {
        const f = box.chart && box.chart.fieldApi;
        return f ? 'Chart of ' + f : 'Chart';
    }
    // Named by kind, NOT by their text field. Every box is built by newTextBox, which
    // seeds `text` with the placeholder "Text", and a non-text box never overwrites it
    // — so a horizontal rule offered itself to the picker as "Text".
    if (box.kind === 'shape') {
        const found = SHAPE_CHOICES.find((s) => s.value === (box.shape && box.shape.type));
        return found ? found.label : 'Shape';
    }
    if (box.kind === 'image') {
        return 'Image';
    }
    if (box.kind === 'code') {
        const found = CODE_TYPES.find((c) => c.value === (box.code && box.code.type));
        return found ? found.label : 'Code';
    }
    if (box.kind === 'signature') {
        return 'Signature block';
    }
    // Marks are stripped, not rendered. `text` carries the canvas's own inline syntax,
    // so a bolded heading read back as "**Contact Roster**" — the picker was showing
    // authoring source where it should show what is on the page.
    let raw = box.text || htmlToText(box.html || '') || '';
    for (const mk of INLINE_MARKS) {
        raw = raw.split(mk.open).join('').split(mk.close).join('');
    }
    const words = raw.replace(/\s+/g, ' ').trim();
    if (words) {
        return words.length > 32 ? words.slice(0, 32).trim() + '…' : words;
    }
    const kind = box.kind || 'text';
    return kind.charAt(0).toUpperCase() + kind.slice(1);
}

/**
 * Groups boxes into anchor sets: each head plus everything that transitively
 * follows it, ordered by authored y so document order matches what the author
 * sees. Boxes with a broken or cyclic anchor come back as singletons rather
 * than vanishing — a bad link should render the element in the wrong place,
 * never drop it from the document.
 */
export function buildAnchorGroups(boxes) {
    const byId = new Map((boxes || []).map((b) => [b.id, b]));
    const groups = new Map();
    const orphans = [];
    for (const b of boxes || []) {
        const root = anchorRoot(b, byId);
        if (!root) {
            orphans.push(b);
            continue;
        }
        if (!groups.has(root.id)) {
            groups.set(root.id, []);
        }
        groups.get(root.id).push(b);
    }
    const out = [];
    for (const members of groups.values()) {
        members.sort((p, q) => p.y - q.y);
        out.push(members);
    }
    for (const o of orphans) {
        out.push([o]);
    }
    // Group order follows the head's y, matching the flow chain's ordering.
    out.sort((a, c) => a[0].y - c[0].y);
    return out;
}

/**
 * Emits an anchor group as ONE flow container whose members are also in flow.
 *
 * Members are in flow, NOT absolutely positioned inside the container. That is
 * the whole mechanism: an absolute follower would hold its offset while the
 * anchor grew and get overrun — the exact bug this feature exists to fix. In
 * flow, each member's margin-top is its authored gap from the previous member's
 * bottom, so growth pushes everything after it.
 *
 * The container itself carries no height: it takes its height from its content,
 * which is what lets the whole set push the artboard when the set grows.
 */
function groupToHtml(members, cursor) {
    const head = members[0];
    let inner = '';
    let bottom = head.y;
    members.forEach((m, i) => {
        const gapTop = i === 0 ? 0 : Math.max(0, round3(m.y - bottom));
        const gapLeft = round3(Math.max(0, m.x - head.x));
        inner +=
            '<div class="dg-anchored"' +
            authoringAttrs(m, true) +
            ' style="margin: ' +
            gapTop +
            'in 0 0 ' +
            gapLeft +
            'in; width: ' +
            outerToContentWidth(m) +
            'in; ' +
            styleCss(m) +
            '">' +
            boxInnerHtml(m) +
            '</div>';
        bottom = m.y + m.h;
    });
    const keep = members.some((m) => m.keepTogether) ? ' page-break-inside: avoid;' : '';
    return wrapCondition(
        head,
        '<div class="dg-group" style="position: relative; margin: ' +
            round3(Math.max(0, head.y - (cursor || 0))) +
            'in 0 0 ' +
            head.x +
            'in;' +
            keep +
            '">' +
            inner +
            '</div>'
    );
}

/** The rendered content of a box, without its positioning wrapper. */
function boxInnerHtml(box) {
    if (box.kind === 'table') {
        return tableToHtml(box);
    } else if (box.kind === 'image') {
        return imageToHtml(box);
    } else if (box.kind === 'shape') {
        return shapeToHtml(box);
    } else if (box.kind === 'code') {
        return codeToHtml(box);
    } else if (box.kind === 'signature') {
        return signatureToHtml(box);
    } else if (box.kind === 'chart') {
        return chartToHtml(box);
    }
    return textToHtml(box);
}

function boxToHtml(box, cursor) {
    let inner;
    if (box.kind === 'table') {
        inner = tableToHtml(box);
    } else if (box.kind === 'image') {
        inner = imageToHtml(box);
    } else if (box.kind === 'shape') {
        inner = shapeToHtml(box);
    } else if (box.kind === 'code') {
        inner = codeToHtml(box);
    } else if (box.kind === 'signature') {
        inner = signatureToHtml(box);
    } else if (box.kind === 'chart') {
        inner = chartToHtml(box);
    } else {
        inner = textToHtml(box);
    }
    if (box.mode === 'flow') {
        return wrapCondition(
            box,
            '<div class="dg-flow"' +
                authoringAttrs(box) +
                ' style="margin: ' +
                flowMarginTop(box, cursor || 0) +
                'in 0 0 ' +
                box.x +
                'in; width: ' +
                outerToContentWidth(box) +
                'in; ' +
                styleCss(box) +
                '">' +
                inner +
                '</div>'
        );
    }
    // Height is deliberately NOT emitted for a pinned box. Declaring it would cap the
    // box and let merged content overflow past its own background and border; leaving
    // it off lets the box grow to whatever the merge produces. The model still tracks
    // h so the editor can show a real rectangle to drag.
    const zCss = box.z ? ' z-index: ' + box.z + ';' : '';
    return wrapCondition(
        box,
        '<div class="dg-pin"' +
            authoringAttrs(box) +
            ' style="' +
            zCss.trim() +
            ' left: ' +
            box.x +
            'in; top: ' +
            box.y +
            'in; width: ' +
            outerToContentWidth(box) +
            'in; ' +
            styleCss(box) +
            '">' +
            inner +
            '</div>'
    );
}

export function serialize(doc, geo) {
    const boards = doc.artboards
        .map((b, i) => {
            const cls = i === 0 ? 'dg-artboard' : 'dg-artboard dg-artboard_break';
            // Pinned boxes first — they are absolute, so their position in the markup
            // does not matter and emitting them up front leaves the flow starting at
            // the top of the artboard. Flow boxes then follow IN Y ORDER, because
            // normal flow is document order and authoring order is not.
            // Ascending z, so document order and paint order agree even where z ties —
            // the later box in the markup wins a tie, which is what "bring to front"
            // means when two boxes share a level.
            // An anchor group always flows — that is what lets growth push it —
            // so its members leave the pinned set regardless of their own mode.
            const anchored = new Set();
            for (const g of buildAnchorGroups(b.boxes || [])) {
                if (g.length > 1) {
                    g.forEach((m) => anchored.add(m.id));
                }
            }
            const pinned = (b.boxes || [])
                .filter((x) => !anchored.has(x.id))
                .filter((x) => x.mode !== 'flow')
                .slice()
                .sort((p, q) => (p.z || 0) - (q.z || 0));
            // Anchor groups and plain flow boxes share ONE chain, ordered by y, so a
            // group is pushed by a flow box above it and vice versa. Emitting them in
            // separate passes would let the two interleave wrongly on the page.
            const groups = buildAnchorGroups(b.boxes || []).filter((g) => g.length > 1);
            const flowSingles = (b.boxes || [])
                .filter((x) => !anchored.has(x.id))
                .filter((x) => x.mode === 'flow')
                .map((x) => [x]);
            const chain = [...groups, ...flowSingles].sort((p, q) => p[0].y - q[0].y);
            let cursor = 0;
            const flowHtml = chain.map((members) => {
                const out = members.length > 1 ? groupToHtml(members, cursor) : boxToHtml(members[0], cursor);
                const last = members[members.length - 1];
                cursor = last.y + last.h;
                return out;
            });
            const inner = [...pinned.map((x) => boxToHtml(x, 0)), ...flowHtml].join('\n  ');
            // A page holding pinned boxes must occupy its full height, or an absolute
            // box near the bottom has nothing to be absolute within. Flow-only pages
            // take their height from their content, exactly as the source document did.
            const needsHeight = pinned.length > 0;
            const heightCss = needsHeight ? ' style="min-height: ' + geo.h + 'in;"' : '';
            return (
                '<div class="' + cls + '" data-dg-artboard="' + (i + 1) + '"' + heightCss + '>\n  ' + inner + '\n</div>'
            );
        })
        .join('\n');
    // The document's own stylesheet, kept AFTER the canvas contract so an imported
    // rule can restyle its own content but cannot redefine .dg-pin/.dg-flow out from
    // under the layout. Dropping it entirely was losing every class-based and
    // element-level rule an imported template had — body typography included, which is
    // why imported text re-wrapped at different words than the original.
    const imported = !!(doc && doc.css);
    const extraCss = imported ? '\n' + IMPORTED_CSS_MARK + '\n' + doc.css + '\n' : '';
    return (
        '<!DOCTYPE html>\n<html>\n<head>\n<meta charset="utf-8" />\n<style>\n' +
        buildCanvasCss(geo, imported) +
        extraCss +
        '</style>\n</head>\n<body>\n' +
        boards +
        '\n</body>\n</html>\n'
    );
}

// ---------------------------------------------------------------------------
// Deserialization — the CANVAS_CSS contract -> model
// ---------------------------------------------------------------------------

function readInches(style, prop) {
    const m = new RegExp(prop + '\\s*:\\s*(-?[0-9.]+)in').exec(style || '');
    return m ? parseFloat(m[1]) : null;
}

/**
 * Reads a stored Canvas body back into the model.
 *
 * Parses from a detached <template> rather than by touching the live canvas — the
 * same discipline the upload path already uses, and the reason LWS node distortion
 * cannot reach this.
 *
 * Returns null when the body is not canvas-shaped, so the caller can tell "empty new
 * template" from "someone pointed this at an HTML template" instead of silently
 * showing a blank artboard over content that is really still there.
 */
/** Inverse of textToHtml — <br> back to newlines, entities back to characters. */
function htmlToText(html) {
    const tmp = document.createElement('div');
    html = collapseMarks(html);
    // eslint-disable-next-line @lwc/lwc/no-inner-html
    tmp.innerHTML = String(html == null ? '' : html).replace(/<br\s*\/?>/gi, '\n');
    return tmp.textContent || '';
}

function readCss(style, prop) {
    const m = new RegExp('(?:^|;)\\s*' + prop + '\\s*:\\s*([^;]+)').exec(style || '');
    return m ? m[1].trim() : null;
}

/** Recovers box styling from the serialized inline CSS, falling back per-property. */
function readStyle(style) {
    const st = { ...DEFAULT_STYLE };
    const font = readCss(style, 'font-family');
    if (font) st.font = font;
    const size = readCss(style, 'font-size');
    if (size) st.size = parseFloat(size) || st.size;
    const color = readCss(style, 'color');
    if (color) st.color = color;
    const align = readCss(style, 'text-align');
    if (align) st.align = align;
    const pad = readCss(style, 'padding');
    if (pad) st.padding = parseFloat(pad) || 0;
    st.bold = /font-weight:\s*bold/.test(style || '');
    st.italic = /font-style:\s*italic/.test(style || '');
    st.underline = /text-decoration:\s*underline/.test(style || '');
    st.fill = readCss(style, 'background') || '';
    const border = readCss(style, 'border');
    if (border) {
        const bm = /([0-9.]+)pt\s+solid\s+(\S+)/.exec(border);
        if (bm) {
            st.borderWidth = parseFloat(bm[1]);
            st.borderColor = bm[2];
        }
    }
    return st;
}

/** Recovers a table box's columns and loop binding from the serialized markup. */
function readTable(wrapper, tableEl) {
    const t = { ...DEFAULT_TABLE_STYLE, showHeader: false, relationship: '', columns: [] };
    const ths = [...tableEl.querySelectorAll('thead th')];
    t.showHeader = ths.length > 0;
    // Cells from the LOOP row only.
    //
    // This was 'tbody tr td', which collects cells from every row — the loop row, the
    // literal rows AND the totals row. The column count was then max(headers, all
    // cells), so a two-column table with one extra row and a totals row came back with
    // six columns, and the count multiplied again on every reload. That is the "random
    // columns" bug: a table that grew wider each time it was opened.
    // Never the SUB row: it carries the grandchild's columns, which are usually fewer
    // than the parent's, so falling back to it would shrink the table's column count.
    const loopRow =
        tableEl.querySelector('tbody tr[data-dg-row="loop"]') ||
        tableEl.querySelector('tbody tr:not([data-dg-row="subloop"])');
    const tds = loopRow ? [...loopRow.querySelectorAll('td')] : [];
    // The loop marker lives as a text node inside <tbody>, around the <tr>.
    // Read the loop marker from the WRAPPER, not from <tbody>.
    //
    // We serialize `<tbody>{#Rel}<tr>…</tr>{/Rel}</tbody>`, which is what the merge
    // engine's row expansion expects. But the HTML parser does not allow text as a
    // direct child of <tbody> — it FOSTER-PARENTS those text nodes out, to just before
    // the <table>. So on the way back in, tbody.innerHTML no longer contains the
    // marker and the binding read as blank: open a table template, save, and the
    // {#Rel} was silently gone. The wrapper still holds it wherever the parser moved it.
    // READ, to find the {#Rel} marker the parser may have moved. No write.
    // eslint-disable-next-line @lwc/lwc/no-inner-html
    // The opener may carry ARGUMENTS — `{#ChartBucket:Rel:Field}` — so this cannot be
    // [A-Za-z0-9_]+ (#310). With the narrow pattern a bucket table read back as an
    // unbound table, which is why the documented string-replace workaround did not
    // survive a round trip through the designer.
    const m = /\{#([^{}]+)\}/.exec((wrapper && wrapper.innerHTML) || '');
    t.relationship = m ? m[1] : '';
    const count = Math.max(ths.length, tds.length);
    for (let i = 0; i < count; i++) {
        const th = ths[i];
        const td = tds[i];
        t.columns.push({
            label: th ? (th.textContent || '').trim() : 'Column ' + (i + 1),
            // READ: a column's tag may carry inline formatting, so textContent would
            // lose it.
            // eslint-disable-next-line @lwc/lwc/no-inner-html
            tag: td ? (td.innerHTML || '').trim() : '',
            width: th ? readCss(th.getAttribute('style'), 'width') || '' : ''
        });
    }
    // Roles are READ from data-dg-row, never inferred. Rows without the marker come
    // from a pre-marker document: treat them as literal rows, which is lossless —
    // worst case the author re-ticks the totals box once.
    t.rows = [];
    t.totals = { enabled: false, cells: [] };
    for (const tr of tableEl.querySelectorAll('tbody tr')) {
        const role = tr.getAttribute('data-dg-row');
        if (role === 'loop') {
            continue;
        }
        const tds2 = [...tr.querySelectorAll('td')];
        const cells = tds2.map((td) => (td.textContent || '').trim());
        if (role === 'subloop') {
            // The relationship rides on the row as an attribute. The {#Rel} tags around
            // it are bare text nodes in the tbody, and recovering a name from those
            // means re-parsing markup the browser has already reshaped.
            t.subRelationship = tr.getAttribute('data-dg-subrel') || '';
            t.subColumns = cells.map((v, i) => ({ label: 'Column ' + (i + 1), tag: v, width: '' }));
            const scs = tds2[0] ? tds2[0].getAttribute('style') || '' : '';
            if (scs) {
                t.subFill = readCss(scs, 'background') || t.subFill;
                t.subText = {
                    ...DEFAULT_SUB_TEXT,
                    size: parseFloat(readCss(scs, 'font-size')) || DEFAULT_SUB_TEXT.size,
                    color: readCss(scs, 'color') || DEFAULT_SUB_TEXT.color,
                    align: readCss(scs, 'text-align') || DEFAULT_SUB_TEXT.align,
                    bold: /font-weight:\s*bold/.test(scs)
                };
            }
            continue;
        }
        if (role === 'totals') {
            t.totals = { enabled: true, cells };
            // Recover the row's own styling, or reopening the template would silently
            // reset a customised totals band to the default on the next save.
            const cs = tds2[0] ? tds2[0].getAttribute('style') || '' : '';
            if (cs) {
                t.totalsFill = readCss(cs, 'background') || t.totalsFill;
                t.totalsText = {
                    ...DEFAULT_TOTALS_TEXT,
                    size: parseFloat(readCss(cs, 'font-size')) || DEFAULT_TOTALS_TEXT.size,
                    color: readCss(cs, 'color') || DEFAULT_TOTALS_TEXT.color,
                    align: readCss(cs, 'text-align') || DEFAULT_TOTALS_TEXT.align,
                    bold: /font-weight:\s*bold/.test(cs)
                };
            }
        } else {
            t.rows.push(cells);
        }
    }

    t.gridStyle = tableEl.getAttribute('data-dg-grid') || 'rows';
    const firstCell = ths[0] || tds[0];
    if (firstCell) {
        const cs = firstCell.getAttribute('style') || '';
        const bm = /([0-9.]+)pt\s+solid\s+(\S+)/.exec(readCss(cs, 'border') || '');
        if (bm) {
            t.gridWidth = parseFloat(bm[1]);
            t.gridColor = bm[2];
        }
        const pad = readCss(cs, 'padding');
        if (pad) t.cellPadding = parseFloat(pad) || t.cellPadding;
    }
    if (ths[0]) {
        t.headerFill = readCss(ths[0].getAttribute('style'), 'background') || t.headerFill;
        t.headerBold = /font-weight:\s*bold/.test(ths[0].getAttribute('style') || '');
    }
    return t;
}

export function deserialize(html) {
    if (!html || html.indexOf('dg-artboard') === -1) {
        return null;
    }
    const tpl = document.createElement('template');
    // Parsing a stored document into a DETACHED <template>, whose content is inert —
    // scripts do not run and resources do not load. This is the parse step that feeds
    // sanitizeInline, not a render into the live page.
    // eslint-disable-next-line @lwc/lwc/no-inner-html
    tpl.innerHTML = html;
    const boards = [...tpl.content.querySelectorAll('.dg-artboard')];
    if (!boards.length) {
        return null;
    }
    const styleEl = tpl.content.querySelector('style');
    const styleText = styleEl ? styleEl.textContent || '' : '';
    const markAt = styleText.indexOf(IMPORTED_CSS_MARK);
    const carriedCss = markAt === -1 ? '' : styleText.slice(markAt + IMPORTED_CSS_MARK.length).trim();

    return {
        css: carriedCss,
        artboards: boards.map((boardEl) => {
            const board = newArtboard();
            // .dg-anchored is included because a linked member lives inside a
            // .dg-group wrapper rather than sitting directly on the artboard.
            // Without it the reader simply does not see followers, and every
            // linked element vanishes on reload. The .dg-group wrapper itself is
            // NOT a box — it carries no authoring attributes and is rebuilt from
            // the members' anchors on the way out.
            const els = [...boardEl.querySelectorAll('.dg-pin, .dg-flow, .dg-anchored')];
            board.boxes = els.map((el) => {
                const style = el.getAttribute('style') || '';
                const isFlow = el.classList.contains('dg-flow');
                const box = newTextBox(0, 0, 2, 0.5);
                box.mode = el.getAttribute('data-dg-mode') || (isFlow ? 'flow' : 'pinned');
                const az = parseInt(el.getAttribute('data-dg-z'), 10);
                box.z = isNaN(az) ? 0 : az;
                box.condition = el.getAttribute('data-dg-if') || '';
                box.name = el.getAttribute('data-dg-name') || '';
                // Prefer the AUTHORING attributes; fall back to reading the CSS only
                // for documents saved before they existed.
                const ax = parseFloat(el.getAttribute('data-dg-x'));
                const ay = parseFloat(el.getAttribute('data-dg-y'));
                const aw = parseFloat(el.getAttribute('data-dg-w'));
                const ah = parseFloat(el.getAttribute('data-dg-h'));
                const hasAuthored = !isNaN(ax) && !isNaN(ay);
                // The AUTHORED width, which is the outer edge. The emitted CSS width is
                // that minus border and padding (see outerToContentWidth), so reading
                // the CSS back as the box width would shrink every bordered box a
                // little more on each save.
                box.w = !isNaN(aw) ? aw : readInches(style, 'width') || 2;
                if (hasAuthored) {
                    box.x = ax;
                    box.y = ay;
                } else if (isFlow) {
                    // Legacy: the margin was written as an absolute y back then.
                    const m = /margin:\s*(-?[0-9.]+)in\s+0\s+0\s+(-?[0-9.]+)in/.exec(style);
                    box.y = m ? parseFloat(m[1]) : 0;
                    box.x = m ? parseFloat(m[2]) : 0;
                } else {
                    box.x = readInches(style, 'left') || 0;
                    box.y = readInches(style, 'top') || 0;
                }
                // Height, in preference order: the authored attribute, then any CSS
                // height, then a sensible default. The unconditional CSS read that used
                // to sit here overwrote the authored value with 0.5in on EVERY load,
                // because height is deliberately not emitted as CSS (see boxToHtml).
                // Flow gaps are computed from box heights, so every box below a
                // resized one crept upward a little more with each save.
                box.h = !isNaN(ah) ? ah : readInches(style, 'height') || 0.5;
                box.style = readStyle(style);
                const tableEl = el.querySelector('table');
                const imgEl = el.querySelector('img');
                const shapeEl = el.querySelector('[data-dg-shape]');
                const assetImg = readImageTag(el);
                if (tableEl) {
                    box.kind = 'table';
                    box.table = readTable(el, tableEl);
                    box.html = '';
                } else if (imgEl) {
                    box.kind = 'image';
                    box.image = readImage(imgEl);
                } else if (assetImg) {
                    box.kind = 'image';
                    box.image = assetImg;
                } else if (el.hasAttribute('data-dg-sig-role')) {
                    box.kind = 'signature';
                    box.signature = readSignature(el);
                } else if (el.hasAttribute('data-dg-code-type')) {
                    box.kind = 'code';
                    box.code = readCode(el);
                } else if (el.hasAttribute('data-dg-chart-rel')) {
                    box.kind = 'chart';
                    box.chart = readChart(el);
                    // The {Chart:...} tag is regenerated from the config on save;
                    // keeping the old tag text would let the two drift apart.
                    box.html = '';
                } else if (shapeEl) {
                    // The marker sits on the INNER div, not on the wrapper — testing
                    // the wrapper meant a shape read back as an empty text box and lost
                    // its fill, border and kind on every reload.
                    box.kind = 'shape';
                    box.shape = readShape(el, style);
                }
                // Position mode is orthogonal to kind — any box can follow another.
                if (el.hasAttribute('data-dg-anchor')) {
                    box.positionMode = 'follows';
                    // The SAVED id, not a live one. Rewritten to the freshly minted id
                    // by remapAnchors below, which also owns what happens when it
                    // cannot be resolved.
                    box.anchorTo = el.getAttribute('data-dg-anchor') || '';
                }
                if (el.hasAttribute('data-dg-keep')) {
                    box.keepTogether = true;
                }
                // Only a plain text box keeps its markup; every other kind rebuilds
                // its content from its own config on the way out.
                if (!box.kind || box.kind === 'text') {
                    // Keep BOTH: the markup is what renders, the flattened text is what
                    // a plain-text edit would start from. Keeping only the text lost
                    // every author's formatting on reload.
                    // READS off the detached parse tree above, and the first is fed
                    // straight into the sanitizer.
                    // eslint-disable-next-line @lwc/lwc/no-inner-html
                    box.html = sanitizeInline(el.innerHTML);
                    // eslint-disable-next-line @lwc/lwc/no-inner-html
                    box.text = htmlToText(el.innerHTML);
                }
                return box;
            });
            remapAnchors(board.boxes, els);
            return board;
        })
    };
}

/**
 * Rewrites every `anchorTo` from the id it was SAVED against to the id its box was
 * just given.
 *
 * `deserialize` builds each box with `newTextBox`, which mints a fresh sequential id.
 * The saved `data-dg-anchor` holds an id from the session that wrote the file. Those
 * two id spaces are unrelated — but because both are `box_<n>` from the same counter,
 * a saved id almost always collides with a real box in the new document. So the link
 * did not dangle and did not error; it quietly re-pointed at a different element.
 * Measured on the Anchor Demo fixture: one open-and-save turned a four-box chain
 * (table → summary → note → signature) into three groups, with the summary anchored to
 * the subtitle and the note to a horizontal rule.
 *
 * Two ways to resolve, in order:
 *
 *  1. `data-dg-id`, written alongside the anchor. Exact, and handles trees — two
 *     followers hanging off one anchor — as well as chains.
 *  2. For documents written before that attribute existed, position within the
 *     `.dg-group`: the serializer emits members in chain order, so a follower's anchor
 *     is the member before it. Correct for a chain, a guess for a tree, and strictly
 *     better than the collision it replaces.
 *
 * Anything still unresolved goes back to `fixed` rather than keeping an id that means
 * nothing. A box that stops moving is visible; a box silently tied to the wrong
 * neighbour is not.
 */
function remapAnchors(boxes, els) {
    const savedToNew = new Map();
    els.forEach((el, i) => {
        const saved = el.getAttribute('data-dg-id');
        if (saved && !savedToNew.has(saved)) {
            savedToNew.set(saved, boxes[i].id);
        }
    });
    boxes.forEach((box, i) => {
        if (box.positionMode !== 'follows' || !box.anchorTo) {
            return;
        }
        const exact = savedToNew.get(box.anchorTo);
        if (exact && exact !== box.id) {
            box.anchorTo = exact;
            return;
        }
        // Legacy: no ids were written, so fall back to the member above this one
        // inside the same group.
        const group = els[i].closest('.dg-group');
        const prev = group && els[i].previousElementSibling;
        if (!savedToNew.size && prev && prev.classList.contains('dg-anchored')) {
            box.anchorTo = boxes[els.indexOf(prev)].id;
            return;
        }
        box.positionMode = 'fixed';
        box.anchorTo = '';
    });
}

// ---------------------------------------------------------------------------
// Import — an existing HTML document, re-described as canvas boxes
// ---------------------------------------------------------------------------

/**
 * Converts an HTML template body into a canvas document.
 *
 * STRUCTURAL, not geometric. Each top-level block becomes a FLOW box carrying its own
 * markup, in document order; only elements whose CSS already says `position: absolute`
 * become pinned boxes. Nothing is measured and nothing is re-laid-out.
 *
 * That choice is the whole reason this is safe. A canvas document IS an HTML document
 * rendered by the same engine, so re-describing the blocks emits near-identical markup
 * and the PDF barely moves. The alternative — rendering the source in the browser,
 * measuring every element with getBoundingClientRect and pinning boxes at those
 * coordinates — would bake the BROWSER's layout into a document that Flying Saucer
 * renders, and the two do not agree. It would look right in the editor and drift in the
 * output, which is the failure this editor exists to prevent.
 *
 * One way. The caller must write the result to a NEW template: flow content that used
 * to be one continuous document becomes discrete boxes, and there is no route back.
 *
 * Returns { doc, page, report } — report lists what could not be carried over, because
 * a conversion that silently drops a running header is worse than one that refuses.
 */
export function htmlToCanvas(html, measure) {
    const report = { dropped: [], notes: [], boxes: 0 };
    if (!html || typeof document === 'undefined') {
        return { doc: blankDocument(), page: null, report };
    }

    // The stylesheet is lifted from the RAW markup, and <head> is removed before the
    // parse. A <template> drops the html/head/body wrappers, and <title> is a RAWTEXT
    // element — so its text arrived as a bare text node among the real blocks and
    // imported as a visible box printing the document's title at the top of the page.
    // Skipping the <title> ELEMENT did not help, because by then there was no element.
    const styleBlocks = (html.match(/<style[^>]*>[\s\S]*?<\/style>/gi) || [])
        .map((b) => b.replace(/<\/?style[^>]*>/gi, ''))
        .join('\n');
    const bodyOnly = html
        .replace(/<head[\s\S]*?<\/head>/gi, '')
        .replace(/<title[\s\S]*?<\/title>/gi, '')
        .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '');

    const tpl = document.createElement('template');
    // Escaped braces are hidden BEFORE this parse, not later: the browser decodes
    // `&#123;` the moment the markup enters a DOM, so by the time a block's outerHTML
    // is read the entity is already gone. The starters use escaped braces as
    // documentation ("format dates with &#123;CloseDate:MMMM d, yyyy&#125;"), and
    // decoding turns that example into a live merge tag printing the record's date.
    // Parsed into a DETACHED <template>: its content is inert, so nothing runs or loads.
    // eslint-disable-next-line @lwc/lwc/no-inner-html
    tpl.innerHTML = hideEscapedBraces(bodyOnly);

    // --- page setup from the source's own @page rule ----------------------
    const page = readPageFromCss(html, report);

    // --- what cannot come across ------------------------------------------
    // Said plainly rather than discovered later in a customer's PDF.
    if (/@page\s*[^{]*\{[^}]*@(top|bottom)-(left|center|right)/i.test(html)) {
        report.dropped.push('Running header/footer (@page margin boxes) — the canvas has no equivalent yet.');
    }
    if (/column-count|column-width|-moz-columns|-webkit-columns/i.test(html)) {
        report.dropped.push('Multi-column layout — boxes are single-column; place two boxes side by side instead.');
    }
    if (/<script/i.test(html)) {
        report.dropped.push('Script tags — never rendered by the PDF engine, removed.');
    }
    if (/position\s*:\s*fixed/i.test(html)) {
        report.dropped.push('position: fixed elements — converted as ordinary pinned boxes on page 1.');
    }

    // The source's own stylesheet, minus the parts the canvas owns. @page is read into
    // page setup separately, and a rule targeting .dg-* would fight the layout contract.
    const sheets = styleBlocks
        .replace(/@page[^{]*\{[^}]*\}/gi, '')
        .replace(/^[^{}]*\.dg-[^{}]*\{[^}]*\}/gim, '')
        .trim();
    if (sheets) {
        report.notes.push("The document's own stylesheet was carried across, so class-based styling still applies.");
    }

    const body = tpl.content.querySelector('body') || tpl.content;
    const board = newArtboard();
    const geo = page ? pageGeometry(page.size, page.orientation, page.margins) : pageGeometry('Letter', 'Portrait');

    // Consecutive flow blocks are grouped into ONE box.
    //
    // A box per block breaks CSS margin collapsing: adjacent block margins normally
    // collapse to the larger of the two, but once each block sits in its own wrapper
    // they stop being adjacent and every margin adds. Measured on the Business Letter
    // starter — same page size, every word present, and it grew from one page to two.
    //
    // Grouping keeps the run of prose exactly as the browser and the engine laid it
    // out, and costs only that a paragraph is not individually draggable. Tables and
    // positioned elements still get their own box, which is what an author actually
    // reaches for.
    let cursorIn = 0;
    let run = [];
    const flushRun = () => {
        if (!run.length) {
            return;
        }
        const html = run.join('');
        run = [];
        if (isEmptyBlockHtml(html)) {
            return;
        }
        const box = newTextBox(0, cursorIn, geo.w, 0.35);
        box.mode = 'flow';
        box.style = importedStyle();
        box.text = '';
        box.html = html;
        box.h = measuredHeight(measure, html, geo.w, 0.35);
        board.boxes.push(box);
        cursorIn = round3(box.y + box.h);
    };

    for (const node of [...body.childNodes]) {
        const groupable = isGroupableFlowNode(node);
        if (groupable !== null) {
            run.push(groupable);
            continue;
        }
        flushRun();
        const box = blockToBox(node, geo, cursorIn, report, measure);
        if (!box) {
            continue;
        }
        board.boxes.push(box);
        // A flowing block continues from where the last one ended — and a PLACED block
        // counts too. Only flow boxes used to advance the cursor, so a document that
        // pinned a title and then let a table flow put the table at y=0, printed on top
        // of the title. Taking the max means flowing content lands below everything
        // placed so far, which is the whole point of flowing it. For a pure-flow
        // document box.y already equals the cursor, so this changes nothing there.
        cursorIn = round3(Math.max(cursorIn, box.y + box.h));
    }
    flushRun();

    if (!board.boxes.length) {
        report.notes.push('No block content found — starting from an empty page.');
    }
    report.boxes = board.boxes.length;
    return { doc: { css: sheets, artboards: [board] }, page, report };
}

/** Reads page size, orientation and margins out of the source's @page rule. */
function readPageFromCss(html, report) {
    const rule = /@page\s*\{([^}]*)\}/.exec(html || '');
    if (!rule) {
        report.notes.push('No @page rule found — using Letter portrait with no margins.');
        return null;
    }
    const out = { size: 'Letter', orientation: 'Portrait', margins: { ...DEFAULT_MARGINS } };
    const custom = /size:\s*([0-9.]+)in\s+([0-9.]+)in/i.exec(rule[1]);
    const named = custom ? null : /size:\s*([A-Za-z0-9]+)\s*(portrait|landscape)?/i.exec(rule[1]);
    if (named) {
        const match = ['Letter', 'A4', 'Legal'].find((n) => n.toLowerCase() === named[1].toLowerCase());
        if (match) out.size = match;
        out.orientation = (named[2] || 'portrait').toLowerCase() === 'landscape' ? 'Landscape' : 'Portrait';
    } else if (custom) {
        out.size = 'Custom';
        out.custom = { w: parseFloat(custom[1]), h: parseFloat(custom[2]) };
    }
    const marg = /margin:\s*([^;]+)/i.exec(rule[1]);
    if (marg) {
        const parts = marg[1]
            .trim()
            .split(/\s+/)
            .map((v) => parseFloat(v))
            .filter((v) => !isNaN(v));
        if (parts.length === 1) {
            out.margins = normalizeMargins({ top: parts[0], right: parts[0], bottom: parts[0], left: parts[0] });
        } else if (parts.length === 2) {
            out.margins = normalizeMargins({ top: parts[0], right: parts[1], bottom: parts[0], left: parts[1] });
        } else if (parts.length === 4) {
            out.margins = normalizeMargins({ top: parts[0], right: parts[1], bottom: parts[2], left: parts[3] });
        }
    }
    return out;
}

/** Block-level tags that become their own box. Everything else is inline content. */
const BLOCK_TAGS = new Set(['P', 'DIV', 'TABLE', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'HR', 'SECTION']);

/**
 * One source block to one box.
 *
 * A <table> keeps its own markup rather than being reshaped into the table model. The
 * table tool describes a specific shape — a header, one looping row, extras, totals —
 * and forcing an arbitrary authored table into it would silently rewrite the document.
 * Carried as markup it renders EXACTLY as before; the report says it is not editable
 * with the table tool, which is an honest trade the author can act on.
 */
/**
 * True when a converted block would print nothing.
 *
 * Worth checking because newTextBox seeds `text: 'Text'` as a placeholder for a box the
 * author is about to type into, and the serializer falls back to `text` when `html` is
 * empty. An empty block in the source therefore imported as a box that prints the word
 * "Text" — content the original document never had, appearing in someone's document.
 */
function isEmptyBlockHtml(html) {
    const structural = /<(img|table|hr|svg)\b/i.test(html || '');
    if (structural) {
        return false;
    }
    return (
        String(html || '')
            .replace(/<[^>]*>/g, '')
            .replace(/&nbsp;|&#160;|\s/g, '') === ''
    );
}

/**
 * An imported box adds NO chrome of its own.
 *
 * readStyle falls back to DEFAULT_STYLE, which carries 2pt of padding — sensible for a
 * box an author drew, wrong for one describing existing markup. The padding narrowed
 * the text area by 4pt and the source's paragraphs re-wrapped at different words. The
 * markup being carried across already has whatever padding and margins its author gave
 * it; this box is a container, not a restyling.
 */
/**
 * The wrapper carries GEOMETRY ONLY.
 *
 * The block's markup is kept inside the box, styling and all, so copying its border and
 * padding onto the wrapper too applied both TWICE — the certificate's frame drew a
 * second time and the doubled padding narrowed the text until it wrapped at different
 * words. The wrapper's job is to place the block, not to restyle it.
 */
function importedStyle() {
    // Geometry only — every visual property is left unset so the document's own CSS
    // decides. DEFAULT_STYLE would otherwise stamp 11pt sans over a body that says
    // 10.5pt Helvetica, and text would wrap at different words than the original.
    return {
        font: null,
        size: null,
        color: null,
        align: null,
        fill: '',
        padding: 0,
        borderWidth: 0,
        borderColor: DEFAULT_STYLE.borderColor,
        bold: false,
        italic: false,
        underline: false
    };
}

/**
 * The markup for a node that can join a run of flow content, or null when it needs a
 * box of its own (a table, or anything already positioned).
 */
function isGroupableFlowNode(node) {
    if (node.nodeType === 3) {
        const text = (node.textContent || '').trim();
        return text ? esc(text) : '';
    }
    if (node.nodeType !== 1) {
        return '';
    }
    const tag = node.tagName.toUpperCase();
    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TITLE' || tag === 'META' || tag === 'LINK') {
        return '';
    }
    if (tag === 'TABLE') {
        return null;
    }
    // A block CONTAINING a table also needs its own box, or the table is buried inside
    // a prose run and never becomes editable.
    if (node.querySelector && node.querySelector('table')) {
        return null;
    }
    const style = node.getAttribute('style') || '';
    if (/position\s*:\s*(absolute|fixed)/i.test(style)) {
        return null;
    }
    // eslint-disable-next-line @lwc/lwc/no-inner-html
    return sanitizeInline(node.outerHTML);
}

/**
 * The real on-screen height of a block, when the caller can measure one.
 *
 * Heights matter ONLY to the editor: a flow box never emits a height (see boxToHtml),
 * so this cannot move the PDF. What it does fix is the canvas — every imported box was
 * 0.35in tall regardless of content, so a page of prose and a twenty-row table were
 * drawn the same size, stacked on top of each other, and the import looked broken even
 * though it rendered correctly.
 *
 * Measuring POSITIONS in the browser would be a different and much worse idea, because
 * the browser and the PDF engine lay out differently. A height used only to draw the
 * editor carries none of that risk.
 */
function measuredHeight(measure, html, widthIn, fallback) {
    if (typeof measure !== 'function') {
        return fallback;
    }
    try {
        const h = measure(html, widthIn);
        return h && h > 0.05 ? round3(h) : fallback;
    } catch (e) {
        return fallback;
    }
}

function blockToBox(node, geo, cursorIn, report, measure) {
    if (node.nodeType === 3) {
        const text = (node.textContent || '').trim();
        if (!text) {
            return null;
        }
        const box = newTextBox(0, cursorIn, geo.w, 0.3);
        box.mode = 'flow';
        box.style = { ...DEFAULT_STYLE, padding: 0, borderWidth: 0 };
        box.html = esc(text);
        box.text = '';
        return box;
    }
    if (node.nodeType !== 1) {
        return null;
    }
    const tag = node.tagName.toUpperCase();
    // Head content, not document content. A parsed <template> drops the html/head/body
    // wrappers, so <title> arrives as a sibling of the real blocks — and it imported as
    // a visible box printing the document's title at the top of the page, text the
    // original never showed.
    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TITLE' || tag === 'META' || tag === 'LINK') {
        return null;
    }

    const style = node.getAttribute('style') || '';
    const absolute = /position\s*:\s*(absolute|fixed)/i.test(style);

    // An element that is already positioned keeps its coordinates — that is exactly
    // what a pinned box is.
    if (absolute) {
        const box = newTextBox(
            readInches(style, 'left') || 0,
            readInches(style, 'top') || 0,
            readInches(style, 'width') || 2.5,
            readInches(style, 'height') || 0.5
        );
        box.mode = 'pinned';
        box.style = importedStyle();
        // eslint-disable-next-line @lwc/lwc/no-inner-html
        box.html = sanitizeInline(node.innerHTML);
        box.text = '';
        box.h = measuredHeight(measure, box.html, box.w, box.h);
        return isEmptyBlockHtml(box.html) ? null : box;
    }

    if (!BLOCK_TAGS.has(tag)) {
        // An inline element at the top level still has to land somewhere.
        const box = newTextBox(0, cursorIn, geo.w, 0.3);
        box.mode = 'flow';
        box.style = { ...DEFAULT_STYLE, padding: 0, borderWidth: 0 };
        // READ off the detached parse tree, fed straight into the sanitizer.
        // eslint-disable-next-line @lwc/lwc/no-inner-html
        box.html = sanitizeInline(node.outerHTML);
        box.text = '';
        box.h = measuredHeight(measure, box.html, box.w, box.h);
        return isEmptyBlockHtml(box.html) ? null : box;
    }

    const box = newTextBox(0, cursorIn, readInches(style, 'width') || geo.w, 0.35);
    box.mode = 'flow';
    box.style = importedStyle();
    box.text = '';
    if (tag === 'TABLE') {
        // Carried as MARKUP, deliberately. Reshaping an authored table into the table
        // model was tried and measured: it dropped merge tags on two of the five
        // starters, because an arbitrary table does not reliably decompose into the
        // header/loop/extras/totals shape the tool describes. Rendering exactly as
        // before and saying the tool cannot edit it is the honest trade — a converter
        // that quietly loses a {SUM:} is worse than one that admits a limit.
        report.notes.push(
            'A table was carried across as markup — it renders as before, but the table tool cannot edit it.'
        );
        // eslint-disable-next-line @lwc/lwc/no-inner-html
        box.html = sanitizeInline(node.outerHTML);
        box.h = measuredHeight(measure, box.html, box.w, 1);
        return box;
    }
    // eslint-disable-next-line @lwc/lwc/no-inner-html
    box.html = sanitizeInline(node.outerHTML);
    return isEmptyBlockHtml(box.html) ? null : box;
}

// ---------------------------------------------------------------------------
// Query generation — the canvas tells the query what it needs
// ---------------------------------------------------------------------------

/** Tags that resolve without being queried, so they must never reach the SELECT. */
const NON_FIELD_TAGS =
    /^(Today|Now|PageNumber|TotalPages|RowNumber|RunningUser(\.[A-Za-z0-9_]+)?|SUM|COUNT|AVG|MIN|MAX|IF|ELSE)/i;

/**
 * Walks text for merge tags, TRACKING loop context.
 *
 * A text box can hold hand-written loops, including one inside another — which is the
 * only way to express a grandchild list (opportunities, then each opportunity's line
 * items) since the table tool binds a single relationship. Reading its fields without
 * following `{#Rel}` … `{/Rel}` put every one of them on the base object, so the
 * derived query came out as a flat SELECT with no subqueries at all: it compiles, it
 * returns a row, and every child tag renders blank. A query that is wrong in a way
 * that still runs is worse than one that errors.
 *
 * `rel` seeds the stack for callers that already know the context (a table's own
 * relationship, whose loop tags are not in the text).
 */
function collectFromText(text, out, rel) {
    const stack = rel ? [rel] : [];
    for (const m of String(text || '').matchAll(/\{([#/^%]?)([A-Za-z0-9_.:=&'"\s-]+?)\}/g)) {
        const prefix = m[1];
        let body = m[2].trim();
        if (prefix === '#') {
            // {#IF …} and {#ChartBucket:…} open blocks, not child collections — pushing
            // them would file the fields inside under a relationship that does not exist.
            const head = body.split(/[\s:]/)[0];
            if (!/^(IF|ChartBucket)$/i.test(head)) {
                stack.push(head);
            }
            continue;
        }
        if (prefix === '/') {
            const head = body.split(/[\s:]/)[0];
            if (!/^(IF|ChartBucket)$/i.test(head)) {
                stack.pop();
            }
            continue;
        }
        if (prefix === '^' || prefix === '%') {
            continue;
        }
        // Strip a format suffix: {Amount:currency:USD} is still the Amount field.
        body = body.split(':')[0].trim();
        if (!body || NON_FIELD_TAGS.test(body)) {
            continue;
        }
        // Aggregates name their own relationship and are resolved from it, not selected.
        if (body.indexOf('(') !== -1 || body.indexOf(' ') !== -1) {
            continue;
        }
        const path = stack.join('.');
        if (path) {
            if (!out.children[path]) out.children[path] = new Set();
            out.children[path].add(body);
        } else {
            out.base.add(body);
        }
    }
}

/**
 * Walks the document and reports every field it actually references, split into
 * base/parent fields and per-relationship child fields.
 *
 * This is what lets the Query Config be DERIVED rather than maintained by hand. The
 * commonest failure with this product is a tag that renders blank because its field
 * was never queried — the template looks broken and the cause is invisible. Reading
 * the requirement off the document removes the whole class.
 */
export function collectUsedFields(doc) {
    const out = { base: new Set(), children: {} };
    for (const board of doc.artboards || []) {
        for (const box of board.boxes || []) {
            if (box.kind === 'table') {
                const t = box.table || {};
                const rel = t.relationship || '';
                for (const c of t.columns || []) {
                    collectFromText(c.tag, out, rel);
                }
                // Grandchild columns belong to rel.subRel, so the derived query nests
                // the subquery rather than asking the account for line items.
                const subRel = (t.subRelationship || '').trim();
                if (subRel && rel) {
                    for (const c of t.subColumns || []) {
                        collectFromText(c.tag, out, rel + '.' + subRel);
                    }
                }
                for (const r of t.rows || []) {
                    for (const cell of r) collectFromText(cell, out, rel);
                }
                for (const cell of (t.totals || {}).cells || []) {
                    // Totals are aggregates over the relationship — the field they name
                    // has to be queried even though the tag itself is not a plain field.
                    const m = /\{(?:SUM|COUNT|AVG|MIN|MAX):([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)/i.exec(cell || '');
                    if (m) {
                        if (!out.children[m[1]]) out.children[m[1]] = new Set();
                        out.children[m[1]].add(m[2]);
                    }
                }
            } else {
                collectFromText(box.html != null && box.html !== '' ? box.html : box.text, out, '');
            }
            // A condition names a field too. Without this, "show only when Amount > 200"
            // silently evaluated against a field the query never selected — the box
            // just never appeared, and nothing said why.
            const cond = String(box.condition || '').trim();
            const m = /^([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/.exec(cond);
            if (m && !NON_FIELD_TAGS.test(m[1])) {
                out.base.add(m[1]);
            }
        }
    }
    return out;
}

/**
 * Builds a V1 flat Query Config from what the canvas uses.
 *
 * V1 (not the V3 node tree) on purpose: it is the format a human can read in the
 * Query Configuration tab and correct, which matters because this is a SUGGESTION the
 * author accepts, never a silent overwrite. A generated query that quietly replaced a
 * hand-tuned WHERE clause would be a worse bug than the one it solves.
 */
export function buildQueryConfig(doc) {
    const used = collectUsedFields(doc);
    const base = [...used.base];
    if (!base.length) {
        base.push('Name');
    }
    // Relationship paths arrive dotted ("Opportunities.OpportunityLineItems"), because
    // a loop can sit inside a loop. Build them into a tree so the deeper level becomes a
    // NESTED subquery — SOQL expresses a grandchild that way, and emitting the two
    // levels side by side would query line items straight off the account, which is not
    // a relationship that exists.
    const tree = {};
    for (const path of Object.keys(used.children)) {
        const segs = path.split('.');
        let node = tree;
        for (const seg of segs) {
            if (!node[seg]) node[seg] = { fields: new Set(), children: {} };
            node = seg === segs[segs.length - 1] ? node[seg] : node[seg].children;
        }
        for (const f of used.children[path]) node.fields.add(f);
    }
    const renderNode = (name, node) => {
        const inner = Object.keys(node.children).map((k) => renderNode(k, node.children[k]));
        const fields = [...node.fields, ...inner];
        if (!fields.length) {
            return '';
        }
        return '(SELECT ' + fields.join(', ') + ' FROM ' + name + ')';
    };
    const parts = [...base];
    for (const rel of Object.keys(tree)) {
        const sub = renderNode(rel, tree[rel]);
        if (sub) parts.push(sub);
    }
    return parts.join(', ');
}
