const EDGES = ['Top', 'Right', 'Bottom', 'Left'];
const DEFAULTS = {
    size: 'Letter',
    orient: 'portrait',
    margin: '0.75',
    customW: '8.5',
    customH: '11',
    customMargin: '0.75'
};

// Locate a complete simple @page block, including nested running-region rules.
function pageRule(code) {
    const re = /@page\s*\{/gi;
    let match, result;
    while ((match = re.exec(code))) {
        const prefix = code.slice(0, match.index);
        if (prefix.lastIndexOf('/*') > prefix.lastIndexOf('*/')) continue;
        let depth = 1,
            quote = '',
            comment = false,
            i = re.lastIndex;
        for (; i < code.length && depth; i++) {
            const c = code[i],
                next = code[i + 1];
            if (comment) {
                if (c === '*' && next === '/') {
                    comment = false;
                    i++;
                }
                continue;
            }
            if (quote) {
                if (c === '\\') i++;
                else if (c === quote) quote = '';
                continue;
            }
            if (c === '/' && next === '*') {
                comment = true;
                i++;
            } else if (c === '"' || c === "'") quote = c;
            else if (c === '{') depth++;
            else if (c === '}') depth--;
        }
        if (!depth) result = { start: match.index, open: re.lastIndex, end: i - 1 };
        re.lastIndex = i;
    }
    return result;
}

function declarations(body) {
    const found = [];
    let start = 0,
        depth = 0,
        quote = '',
        comment = false;
    const collect = (end) => {
        const raw = body.slice(start, end);
        const match = /^\s*([\w-]+)\s*:\s*([\s\S]*?);?\s*$/.exec(raw);
        if (match)
            found.push({ start, end, name: match[1].toLowerCase(), value: match[2].replace(/;\s*$/, '').trim() });
    };
    for (let i = 0; i < body.length; i++) {
        const c = body[i],
            next = body[i + 1];
        if (comment) {
            if (c === '*' && next === '/') {
                comment = false;
                i++;
                if (!depth) start = i + 1;
            }
            continue;
        }
        if (quote) {
            if (c === '\\') i++;
            else if (c === quote) quote = '';
            continue;
        }
        if (c === '/' && next === '*') {
            comment = true;
            i++;
        } else if (c === '"' || c === "'") quote = c;
        else if (c === '{') depth++;
        else if (c === '}') {
            depth--;
            if (!depth) start = i + 1;
        } else if (c === ';' && !depth) {
            collect(i + 1);
            start = i + 1;
        }
    }
    if (!depth) collect(body.length);
    return found;
}

function inches(value) {
    const match = /^([\d.]+)(in|cm|mm|pt|px)?$/i.exec(value);
    if (!match) return null;
    const number = Number(match[1]);
    if (!Number.isFinite(number) || (!match[2] && number !== 0)) return null;
    return number * ({ in: 1, cm: 1 / 2.54, mm: 1 / 25.4, pt: 1 / 72, px: 1 / 96 }[match[2]?.toLowerCase()] || 1);
}

export function pageMargins(setup) {
    const uniform = Number(setup.margin === 'custom' ? setup.customMargin : setup.margin);
    return EDGES.map((edge) => {
        const value = setup['margin' + edge];
        const result = value == null || value === '' ? uniform : Number(value);
        return Number.isFinite(result) && result >= 0 ? result : 0.75;
    });
}

export function pageGeometry(setup) {
    const sizes = { Letter: [8.5, 11], Legal: [8.5, 14], A4: [210 / 25.4, 297 / 25.4] };
    const dimensions = sizes[setup.size] || [Number(setup.customW), Number(setup.customH)];
    const [width, height] = setup.orient === 'landscape' ? [...dimensions].reverse() : dimensions;
    return { width, height, margins: pageMargins(setup) };
}

export function parsePageLayout(code = '') {
    const setup = { ...DEFAULTS };
    const rule = pageRule(code);
    if (!rule) return setup;
    const declared = declarations(code.slice(rule.open, rule.end));
    const values = Object.fromEntries(declared.map((d) => [d.name, d.value]));
    const size = /^(letter|legal|a4)(?:\s+(portrait|landscape))?$/i.exec(values.size || '');
    if (size) {
        setup.size = { letter: 'Letter', legal: 'Legal', a4: 'A4' }[size[1].toLowerCase()];
        setup.orient = (size[2] || 'portrait').toLowerCase();
    } else {
        const dimensions = (values.size || '').split(/\s+/).map(inches);
        if (dimensions.length === 2 && dimensions.every((v) => v > 0)) {
            setup.size = 'Custom';
            setup.orient = dimensions[0] > dimensions[1] ? 'landscape' : 'portrait';
            setup.customW = String(Math.min(...dimensions));
            setup.customH = String(Math.max(...dimensions));
        }
    }
    let margins = [0.75, 0.75, 0.75, 0.75];
    for (const item of declared) {
        if (item.name === 'margin') {
            const shorthand = item.value.split(/\s+/).map(inches);
            if (shorthand.length <= 4 && shorthand.every((v) => v !== null)) {
                const [a, b = a, c = a, d = b] = shorthand;
                margins = [a, b, c, d];
            }
        } else {
            const index = EDGES.findIndex((edge) => item.name === 'margin-' + edge.toLowerCase());
            const value = inches(item.value);
            if (index >= 0 && value !== null) margins[index] = value;
        }
    }
    EDGES.forEach((edge, i) => {
        setup['margin' + edge] = String(margins[i]);
    });
    const all = pageMargins(setup);
    setup.margin = all.every((v) => v === all[0]) && [0.5, 0.75, 1].includes(all[0]) ? String(all[0]) : 'custom';
    setup.customMargin = String(all[0]);
    return setup;
}

export function applyPageLayout(code, setup) {
    const { width, height, margins } = pageGeometry(setup);
    if (!(width > margins[1] + margins[3] && height > margins[0] + margins[2]))
        throw new Error('Margins leave no space for document content.');
    const edits = {
        size: setup.size === 'Custom' ? `${width}in ${height}in` : `${setup.size} ${setup.orient}`,
        margin: margins.map((v) => `${v}in`).join(' ')
    };
    const rule = pageRule(code || '');
    if (!rule) {
        const css = `@page { size: ${edits.size}; margin: ${edits.margin}; }`;
        if (/<style\b[^>]*>/i.test(code)) return code.replace(/<style\b[^>]*>/i, (m) => m + '\n' + css);
        return '<style>' + css + '</style>\n' + code;
    }
    let body = code.slice(rule.open, rule.end);
    const existing = declarations(body);
    for (const item of [...existing].reverse()) {
        if (item.name in edits || /^margin-(top|right|bottom|left)$/.test(item.name)) {
            body = body.slice(0, item.start) + body.slice(item.end);
        }
    }
    body = `\n size: ${edits.size}; margin: ${edits.margin};\n` + body;
    return code.slice(0, rule.open) + body + code.slice(rule.end);
}
