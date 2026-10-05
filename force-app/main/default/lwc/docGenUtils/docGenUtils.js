/**
 * Shared utility functions for Portwood LWC components.
 * Consolidates duplicated logic (download, filter parsing) into one module.
 */

/**
 * Downloads a base64-encoded file via a temporary anchor element.
 *
 * @param {string} base64Data - The base64-encoded file content
 * @param {string} fileName   - The download filename (including extension)
 * @param {string} mimeType   - The MIME type (e.g. 'application/pdf')
 */
/**
 * MIME types Lightning Web Security will accept through URL.createObjectURL.
 *
 * LWS sanitizes createObjectURL against an allowlist — PDF, images and plain
 * text pass, everything else is rejected with
 *
 *   Lightning Web Security: Cannot 'createObjectURL' using an unsecure [object Blob]
 *
 * Office formats (.docx/.pptx/.xlsx), JSON and HTML are all off it. This is the
 * single source of truth; docGenButton reads the same list so the two cannot
 * drift apart.
 */
export function isBlobSafeMime(mimeType) {
    if (!mimeType) {
        return false;
    }
    return mimeType === 'application/pdf' || mimeType.startsWith('image/') || mimeType === 'text/plain';
}

/**
 * Downloads base64 content as a file.
 *
 * Two routes, because one is not enough in an LWS-enabled org:
 *
 *   - allowlisted MIME -> Blob + createObjectURL. Preferred: no size ceiling,
 *     and the browser streams it.
 *   - anything else -> a data: URI, which never calls createObjectURL and so
 *     cannot be refused. This is what makes .docx/.pptx/.xlsx downloads work
 *     with LWS on; previously they threw and the user got nothing.
 *
 * The createObjectURL branch is also wrapped, so if the allowlist changes under
 * us in a future release the download degrades to the data: URI instead of
 * failing outright.
 */
export function downloadBase64(base64Data, fileName, mimeType) {
    const anchor = document.createElement('a');
    anchor.download = fileName;

    let objectUrl = null;
    if (isBlobSafeMime(mimeType)) {
        try {
            const binaryString = atob(base64Data);
            const bytes = new Uint8Array(binaryString.length);
            for (let i = 0; i < binaryString.length; i++) {
                bytes[i] = binaryString.charCodeAt(i);
            }
            objectUrl = URL.createObjectURL(new Blob([bytes], { type: mimeType }));
        } catch (e) {
            objectUrl = null; // fall through to the data: URI
        }
    }

    anchor.href = objectUrl || 'data:' + (mimeType || 'application/octet-stream') + ';base64,' + base64Data;
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
    if (objectUrl) {
        URL.revokeObjectURL(objectUrl);
    }
}

/**
 * Converts a Query_Config__c JSON's report filters or bulkWhereClause
 * into a SOQL WHERE clause string.
 *
 * @param {string} queryConfigJson - Raw Query_Config__c value (JSON string)
 * @returns {string|null} The WHERE clause, or null if none could be derived
 */
/**
 * Splits a string by commas, respecting parenthesis nesting depth.
 * Port of Apex DocGenDataRetriever.splitTopLevel().
 *
 * @param {string} input - e.g. "Id, (SELECT Id FROM Cases)"
 * @returns {string[]} - e.g. ["Id", "(SELECT Id FROM Cases)"]
 */
export function splitTopLevel(input) {
    const parts = [];
    let current = '';
    let parenLevel = 0;

    for (let i = 0; i < input.length; i++) {
        const ch = input[i];

        // Auto-split field from adjacent subquery: "Account.Name (SELECT..."
        if (ch === '(' && parenLevel === 0 && current.trim().length > 0) {
            parts.push(current.trim());
            current = '';
        }

        if (ch === '(') {
            parenLevel++;
        }
        if (ch === ')') {
            parenLevel--;
        }

        if (ch === ',' && parenLevel === 0) {
            if (current.trim().length > 0) {
                parts.push(current.trim());
            }
            current = '';
        } else {
            current += ch;
        }
    }
    if (current.trim().length > 0) {
        parts.push(current.trim());
    }
    return parts;
}

/**
 * Finds a SQL keyword at parenthesis nesting level 0.
 * Returns the index of the keyword, or -1 if not found.
 *
 * @param {string} input - The string to search
 * @param {string} keyword - e.g. "FROM", "WHERE", "ORDER", "LIMIT"
 * @returns {number}
 */
export function findKeywordAtLevel0(input, keyword) {
    const upper = input.toUpperCase();
    const kw = keyword.toUpperCase();
    let parenLvl = 0;

    // Check at start of string
    if (upper.startsWith(kw + ' ') || upper.startsWith(kw + '\t') || upper.startsWith(kw + '\n')) {
        return 0;
    }

    for (let i = 0; i < input.length; i++) {
        const ch = input[i];
        if (ch === '(') {
            parenLvl++;
        }
        if (ch === ')') {
            parenLvl--;
        }
        if (parenLvl === 0) {
            // Check for keyword preceded by whitespace and followed by whitespace
            const before = input[i];
            if (/\s/.test(before) && i + 1 + kw.length <= upper.length) {
                const slice = upper.substring(i + 1, i + 1 + kw.length);
                const afterChar = upper[i + 1 + kw.length];
                if (slice === kw && (afterChar === undefined || /\s/.test(afterChar))) {
                    return i + 1; // position of keyword
                }
            }
        }
    }
    return -1;
}

/**
 * Parses a SOQL-like query string (V1 format) into base fields and subqueries.
 * Handles nested subqueries of any depth. Also accepts full SOQL statements
 * (with SELECT ... FROM ObjectName) — the outer SELECT/FROM are stripped.
 *
 * @param {string} queryStr - e.g. "Name, (SELECT Id, (SELECT Id FROM Cases) FROM Contacts)"
 *                            or "SELECT Name, (SELECT Id FROM Contacts) FROM Account"
 * @returns {{ baseFields: string[], parentFields: string[], subqueries: object[] }}
 */
export function parseSOQLFields(queryStr) {
    if (!queryStr) return { baseFields: [], parentFields: [], subqueries: [], warnings: [] };

    let cleaned = queryStr.trim();
    const warnings = [];

    // Detect and warn about outer WHERE/ORDER BY/LIMIT before stripping
    const outerClauses = detectOuterClauses(cleaned);
    if (outerClauses) {
        warnings.push(outerClauses);
    }

    // Strip outer SELECT ... FROM ObjectName if present
    cleaned = stripOuterSelectFrom(cleaned);

    // Split into top-level tokens (fields + subquery blocks)
    const tokens = splitTopLevel(cleaned);

    const baseFields = [];
    const parentFields = [];
    const subqueries = [];

    for (const token of tokens) {
        const trimmed = token.trim();
        const upper = trimmed.toUpperCase();
        if (trimmed.startsWith('(') && upper.includes('SELECT') && upper.includes('FROM')) {
            // Subquery
            const sq = parseSubquery(trimmed);
            if (sq) {
                subqueries.push(sq);
            }
        } else if (trimmed.length > 0) {
            if (trimmed.includes('.')) {
                parentFields.push(trimmed);
            } else {
                baseFields.push(trimmed);
            }
        }
    }

    return { baseFields, parentFields, subqueries, warnings };
}

/**
 * Detects if a full SOQL statement has WHERE/ORDER BY/LIMIT on the outer query.
 * These clauses are not supported at the top level because Portwood always runs
 * against a specific record.
 *
 * @param {string} input
 * @returns {string|null} Warning message, or null if clean
 */
function detectOuterClauses(input) {
    const upper = input.trim().toUpperCase();
    if (!upper.startsWith('SELECT ')) {
        return null;
    }

    const afterSelect = input.trim().substring(7);
    const fromIdx = findKeywordAtLevel0(afterSelect, 'FROM');
    if (fromIdx === -1) {
        return null;
    }

    const afterFrom = afterSelect.substring(fromIdx + 5).trim();
    // Check if there's more than just the object name after FROM
    const objOnly = afterFrom.match(/^(\w+)\s*$/);
    if (objOnly) {
        return null;
    } // Clean — just "FROM Account"

    const objMatch = afterFrom.match(/^(\w+)\s+/);
    if (!objMatch) {
        return null;
    }

    const remainder = afterFrom.substring(objMatch[0].length).trim().toUpperCase();
    const found = [];
    if (remainder.startsWith('WHERE') || remainder.includes(' WHERE ')) {
        found.push('WHERE');
    }
    if (remainder.includes('ORDER BY') || remainder.startsWith('ORDER')) {
        found.push('ORDER BY');
    }
    if (remainder.includes('LIMIT') || remainder.startsWith('LIMIT')) {
        found.push('LIMIT');
    }

    if (found.length > 0) {
        return (
            'Outer ' +
            found.join(', ') +
            ' clause' +
            (found.length > 1 ? 's are' : ' is') +
            ' ignored — Portwood runs against a specific record. Move filters inside a subquery if needed.'
        );
    }
    return null;
}

/**
 * Parses a single subquery string like "(SELECT Id, Name FROM Contacts WHERE ...)"
 * into a structured object. Recursively handles nested subqueries.
 *
 * @param {string} subqueryStr
 * @returns {{ relationshipName: string, fields: string[], children: object[], whereClause: string, orderBy: string, limitAmount: string }}
 */
function parseSubquery(subqueryStr) {
    // Strip outer parens
    let inner = subqueryStr.trim();
    if (inner.startsWith('(')) {
        inner = inner.substring(1);
    }
    if (inner.endsWith(')')) {
        inner = inner.substring(0, inner.length - 1);
    }
    inner = inner.trim();

    // Find SELECT and FROM at level 0
    const upperInner = inner.toUpperCase();
    const selectIdx = upperInner.indexOf('SELECT ');
    const fromIdx = findKeywordAtLevel0(inner, 'FROM');
    if (selectIdx === -1 || fromIdx === -1) {
        return null;
    }

    const fieldsPart = inner.substring(selectIdx + 7, fromIdx).trim();
    const afterFrom = inner.substring(fromIdx + 5).trim();

    // Extract relationship name and optional clauses
    const relMatch = afterFrom.match(/^(\w+)/);
    if (!relMatch) {
        return null;
    }
    const relationshipName = relMatch[1];
    let clauses = afterFrom.substring(relationshipName.length).trim();

    // Extract LIMIT
    let limitAmount = '';
    const limitMatch = clauses.match(/\s+LIMIT\s+(\d+)$/i);
    if (limitMatch) {
        limitAmount = limitMatch[1];
        clauses = clauses.substring(0, clauses.length - limitMatch[0].length).trim();
    }

    // Extract ORDER BY
    let orderBy = '';
    const orderMatch = clauses.match(/\s+ORDER\s+BY\s+(.+)$/i);
    if (orderMatch) {
        orderBy = orderMatch[1];
        clauses = clauses.substring(0, clauses.length - orderMatch[0].length).trim();
    }

    // Extract WHERE
    let whereClause = '';
    const whereMatch = clauses.match(/\s*WHERE\s+(.+)$/i);
    if (whereMatch) {
        whereClause = whereMatch[1];
    }

    // Parse fields, respecting nested subqueries
    const fieldTokens = splitTopLevel(fieldsPart);
    const fields = [];
    const children = [];

    for (const token of fieldTokens) {
        const trimmed = token.trim();
        const upper = trimmed.toUpperCase();
        if (trimmed.startsWith('(') && upper.includes('SELECT') && upper.includes('FROM')) {
            const child = parseSubquery(trimmed);
            if (child) {
                children.push(child);
            }
        } else if (trimmed.length > 0) {
            fields.push(trimmed);
        }
    }

    return { relationshipName, fields, children, whereClause, orderBy, limitAmount };
}

/**
 * Strips the outer SELECT ... FROM ObjectName from a full SOQL statement,
 * returning just the field list (including subqueries).
 *
 * @param {string} input - e.g. "SELECT Name, Industry FROM Account"
 * @returns {string} - e.g. "Name, Industry"
 */
export function stripOuterSelectFrom(input) {
    const trimmed = input.trim();
    const upper = trimmed.toUpperCase();

    // Must start with SELECT
    if (!upper.startsWith('SELECT ')) {
        return trimmed;
    }

    // Find FROM at level 0 (not inside a subquery)
    const afterSelect = trimmed.substring(7); // skip "SELECT "
    const fromIdx = findKeywordAtLevel0(afterSelect, 'FROM');
    if (fromIdx === -1) {
        return trimmed;
    }

    // Check that what follows FROM is a bare object name (not a subquery relationship)
    const afterFrom = afterSelect.substring(fromIdx + 5).trim();
    const objMatch = afterFrom.match(/^(\w+)\s*$/);
    if (!objMatch) {
        // Has WHERE/ORDER/LIMIT after the object — still strip for field extraction
        const objOnlyMatch = afterFrom.match(/^(\w+)/);
        if (objOnlyMatch) {
            return afterSelect.substring(0, fromIdx).trim();
        }
        return trimmed;
    }

    return afterSelect.substring(0, fromIdx).trim();
}

export function extractWhereClause(queryConfigJson) {
    if (!queryConfigJson) return null;

    try {
        const config = JSON.parse(queryConfigJson);

        if (config.bulkWhereClause) {
            return config.bulkWhereClause;
        }

        if (config.reportFilters && config.reportFilters.length > 0) {
            const DATE_LITERALS = [
                'TODAY',
                'YESTERDAY',
                'TOMORROW',
                'LAST_WEEK',
                'THIS_WEEK',
                'NEXT_WEEK',
                'LAST_MONTH',
                'THIS_MONTH',
                'NEXT_MONTH',
                'LAST_QUARTER',
                'THIS_QUARTER',
                'NEXT_QUARTER',
                'LAST_YEAR',
                'THIS_YEAR',
                'NEXT_YEAR',
                'LAST_90_DAYS',
                'NEXT_90_DAYS'
            ];

            const parts = config.reportFilters.map((f) => {
                if (f.operator === 'LIKE') {
                    return f.field + " LIKE '%" + f.value + "%'";
                }
                if (f.operator === 'IN' || f.operator === 'NOT IN') {
                    const vals = f.value
                        .split(',')
                        .map((v) => "'" + v.trim() + "'")
                        .join(', ');
                    return f.field + ' ' + f.operator + ' (' + vals + ')';
                }

                let v = f.value.trim();
                const upper = v.toUpperCase();

                // Date-only value on a datetime field: append time component
                const isDateOnly = /^\d{4}-\d{2}-\d{2}$/.test(v);
                const isDateTimeField =
                    f.field &&
                    (f.field.toLowerCase().includes('date') || f.field.toLowerCase().includes('time')) &&
                    !f.field.toLowerCase().endsWith('__c');
                if (isDateOnly && isDateTimeField) {
                    v = v + 'T00:00:00Z';
                }

                if (
                    DATE_LITERALS.includes(upper) ||
                    upper.startsWith('LAST_N_') ||
                    upper.startsWith('NEXT_N_') ||
                    /^\d+\.?\d*$/.test(v) ||
                    /^\d{4}-\d{2}-\d{2}/.test(v) ||
                    upper === 'TRUE' ||
                    upper === 'FALSE' ||
                    upper === 'NULL'
                ) {
                    return f.field + ' ' + f.operator + ' ' + v;
                }

                return f.field + ' ' + f.operator + " '" + f.value + "'";
            });

            return parts.join(' AND ');
        }
    } catch {
        // Not JSON or malformed — that's fine
    }

    return null;
}

/**
 * Rasterizes an SVG string to a base64-encoded PNG via a hidden <canvas>.
 *
 * Used by the chart pipeline (#117): Apex emits SVG via DocGenSvgChartSerializer,
 * the runner LWC calls this to convert it to PNG, then uploads the PNG as a
 * ContentVersion linked to the source record. The existing image substitution
 * path embeds the PNG in every output format (DOCX / PPTX / XLSX / HTML / PDF)
 * since all five render raster images natively.
 *
 * Server-side flows (Flow / batch / async) have no browser and skip this path
 * — they render a text placeholder where the chart would go.
 *
 * The `scale` factor (default 4) controls oversampling. SVG is a vector format;
 * rasterizing at 1x looks blurry on Retina displays and pixelates when zoomed
 * or printed. Drawing at 4x nominal dimensions keeps text + edges crisp on
 * high-DPI screens, in DOCX/PPTX zoom up to ~200%, and in PDF print at any
 * reasonable size. File size grows ~16x at 4x scale (chart PNG ~25 KB → ~320 KB)
 * — still small for typical business docs. Authors can override per-chart via
 * the `scale=N` modifier on the chart tag (`{Chart:Rel:Field:bar:scale=2}`).
 *
 * @param {string} svgString - The full <svg>...</svg> markup as a string
 * @param {number} width     - Nominal display width in pixels
 * @param {number} height    - Nominal display height in pixels
 * @param {number} [scale=4] - Oversampling factor (1 = 1x, 4 = default sharp, 5 = extreme zoom)
 * @returns {Promise<string>} Base64-encoded PNG bytes (no `data:` prefix)
 */
export function rasterizeSvgToPng(svgString, width, height, scale = 4) {
    return new Promise((resolve, reject) => {
        const blob = new Blob([svgString], { type: 'image/svg+xml' });
        const url = URL.createObjectURL(blob);
        const img = new Image();
        img.onload = () => {
            try {
                const canvas = document.createElement('canvas');
                canvas.width = width * scale;
                canvas.height = height * scale;
                const ctx = canvas.getContext('2d');
                ctx.imageSmoothingEnabled = true;
                ctx.imageSmoothingQuality = 'high';
                // White background — PNG defaults to transparent which renders
                // as black in some PDF/DOCX viewers when the chart has no
                // background <rect>. The SVG already paints its own background,
                // but this is a safety belt.
                ctx.fillStyle = '#ffffff';
                ctx.fillRect(0, 0, canvas.width, canvas.height);
                ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                URL.revokeObjectURL(url);
                // toDataURL returns "data:image/png;base64,...."; strip the prefix.
                resolve(canvas.toDataURL('image/png').split(',')[1]);
            } catch (err) {
                URL.revokeObjectURL(url);
                reject(err);
            }
        };
        img.onerror = (err) => {
            URL.revokeObjectURL(url);
            reject(err instanceof Error ? err : new Error('SVG load failed'));
        };
        img.src = url;
    });
}

// ---------------------------------------------------------------------------
// Preview hardening
// ---------------------------------------------------------------------------

// Elements that can run code, load another document, or collect input. A preview never
// needs any of them, so they are removed outright rather than neutralised.
const PREVIEW_DROP_TAGS =
    'script,iframe,frame,frameset,object,embed,applet,base,meta,link,form,input,button,textarea,select,' +
    'option,noscript,template,svg,math,portal,dialog';

// Attributes whose value is a URL. Anything that is not http(s), mailto, tel, a fragment or a
// relative path is dropped; data: is kept only for raster images.
const PREVIEW_URL_ATTRS = [
    'href',
    'src',
    'xlink:href',
    'poster',
    'data',
    'cite',
    'action',
    'formaction',
    'background',
    'ping',
    'longdesc'
];
const PREVIEW_IMAGE_URL_ATTRS = ['src', 'poster', 'background'];
const PREVIEW_BAD_CSS = /expression\s*\(|javascript:|vbscript:|behavior\s*:|-moz-binding|@import/i;

function isSafePreviewUrl(value, attrName) {
    // Browsers ignore whitespace and control characters inside a scheme ("java\tscript:"), so
    // compare against the value with all of them removed.
    // eslint-disable-next-line no-control-regex
    const v = String(value || '')
        .replace(/[\u0000- \u007f-\u009f]+/g, '')
        .toLowerCase();
    if (!v) {
        return true;
    }
    if (v.startsWith('data:')) {
        return PREVIEW_IMAGE_URL_ATTRS.includes(attrName) && /^data:image\/(?:png|jpe?g|gif|webp|bmp)[;,]/.test(v);
    }
    const scheme = v.match(/^([a-z][a-z0-9+.-]*):/);
    if (scheme) {
        return ['http', 'https', 'mailto', 'tel'].includes(scheme[1]);
    }
    return true;
}

function cleanPreviewCss(css) {
    return String(css || '')
        .replace(/@import\b[^;]*;?/gi, '')
        .replace(/expression\s*\(/gi, '(')
        .replace(/(?:javascript|vbscript):/gi, '')
        .replace(/behavior\s*:[^;}]*/gi, '')
        .replace(/-moz-binding\s*:[^;}]*/gi, '');
}

/**
 * Harden merged-document HTML before it is written into a lwc:dom="manual" host.
 *
 * The preview HTML contains record data, and the merge does not HTML-escape it, so a field
 * holding markup would otherwise become live markup in the page. This removes scripts, frames,
 * forms, SVG and friends, every on* handler (quoted or not), srcdoc, unsafe URLs and dangerous
 * CSS. It parses into an inert <template>, so nothing runs while it works. Fails closed: with
 * no DOM available it returns an empty string.
 *
 * It does not scope CSS: pair it with scopeHtmlForInlinePreview (c/docGenAuthoringKit).
 */
export function sanitizePreviewHtml(html) {
    if (!html) {
        return '';
    }
    if (typeof document === 'undefined') {
        return '';
    }
    const tpl = document.createElement('template');
    // eslint-disable-next-line @lwc/lwc/no-inner-html -- inert <template> parse, the first step of sanitising; nothing here executes
    tpl.innerHTML = String(html);
    const root = tpl.content;

    for (const el of Array.from(root.querySelectorAll(PREVIEW_DROP_TAGS))) {
        el.remove();
    }
    for (const el of Array.from(root.querySelectorAll('*'))) {
        for (const attr of Array.from(el.attributes)) {
            const name = attr.name.toLowerCase();
            if (name.startsWith('on') || name === 'srcdoc' || name === 'srcset' || name === 'ping') {
                el.removeAttribute(attr.name);
            } else if (PREVIEW_URL_ATTRS.includes(name) && !isSafePreviewUrl(attr.value, name)) {
                el.removeAttribute(attr.name);
            } else if (name === 'style' && PREVIEW_BAD_CSS.test(attr.value)) {
                el.removeAttribute(attr.name);
            }
        }
    }
    for (const style of Array.from(root.querySelectorAll('style'))) {
        style.textContent = cleanPreviewCss(style.textContent);
    }

    const box = document.createElement('div');
    box.appendChild(root);
    // eslint-disable-next-line @lwc/lwc/no-inner-html -- serialising the already-sanitised fragment
    return box.innerHTML;
}
