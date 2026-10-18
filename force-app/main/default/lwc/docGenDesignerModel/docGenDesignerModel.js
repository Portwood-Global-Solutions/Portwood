/** DOM operations shared by the Designer and its document-level regression checks. */
const BLOCKS = 'p,h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,pre,table,hr,div';
const TEXT_BLOCKS = 'p,h1,h2,h3,h4,h5,h6,li,blockquote,pre';
const IGNORE = new Set(['STYLE', 'SCRIPT', 'LINK', 'META']);

export function containsNode(root, node) {
    try {
        if (root?.contains(node)) return true;
    } catch {
        /* LWS can expose different proxy identities. */
    }
    for (let current = node; current; current = current.parentNode) if (current === root) return true;
    return false;
}

export function selectedBlock(node, surface) {
    let element = node?.nodeType === 3 ? node.parentElement : node;
    if (!element || !containsNode(surface, element) || element === surface) return null;
    element = element.closest?.('[data-dg-snippet]') || element;
    const table = element.closest?.('table');
    if (table && containsNode(surface, table)) return table;
    if (element.tagName === 'IMG') {
        const parent = element.parentElement;
        return parent?.matches(TEXT_BLOCKS) && parent.children.length === 1 && !parent.textContent.trim()
            ? parent
            : element;
    }
    const block = element.closest?.(BLOCKS);
    return block && block !== surface ? block : null;
}

/** Rendered snippet HTML is a view of a reference, never authored document content.
 * Collapse it BEFORE parsing HTML so block fragments inside inline tags cannot
 * restructure paragraphs during save, undo, or duplication. Read strings rather
 * than cloning browser-created contenteditable nodes (which LWS can omit). */
export function designerMarkup(root, outer = false) {
    let markup = outer ? root.outerHTML : root.innerHTML;
    const pills = [...(root.matches?.('[data-dg-tag]') ? [root] : []), ...root.querySelectorAll('[data-dg-tag]')];
    for (const pill of pills) {
        const tag = pill.getAttribute('data-dg-snippet') ? pill.getAttribute('data-dg-tag') : pill.textContent;
        if (!/^\{%snippet:/i.test(tag || '') || pill.closest('[data-dg-tag]') !== pill) continue;
        const reference = root.ownerDocument.createElement('span');
        reference.setAttribute('data-dg-tag', 'true');
        reference.setAttribute('contenteditable', 'false');
        reference.textContent = tag;
        for (const property of ['font-family', 'font-size', 'font-weight', 'font-style', 'text-decoration', 'color']) {
            const value = pill.style.getPropertyValue(property);
            if (value) reference.style.setProperty(property, value);
        }
        if (pill.hasAttribute('data-dg-highlight')) {
            reference.setAttribute('data-dg-highlight', 'true');
            reference.style.backgroundColor = pill.style.backgroundColor;
        }
        const face = pill.getAttribute('data-pw-font-face');
        if (face) reference.setAttribute('data-pw-font-face', face);
        markup = markup.replace(pill.outerHTML, () => reference.outerHTML);
    }
    return markup;
}

function marker(node) {
    if (node.nodeType === 1 && (node.querySelector('table,img') || IGNORE.has(node.tagName))) return null;
    const match = /^\{([#^/])([^{}]+)\}$/.exec((node.textContent || '').trim());
    return match ? { close: match[1] === '/', name: match[2].split(/[|:]/)[0].trim() } : null;
}

/** Paired repeat/condition boundaries belong to the same movable unit. */
export function blockUnits(parent) {
    const nodes = Array.from(parent.childNodes).filter((node) =>
        node.nodeType === 1 ? !IGNORE.has(node.tagName) : node.nodeType === 3 && node.textContent.trim()
    );
    const units = [];
    for (let index = 0; index < nodes.length; index++) {
        const start = index;
        const first = marker(nodes[index]);
        if (first && !first.close) {
            const stack = [first.name];
            let end = index + 1;
            for (; end < nodes.length && stack.length; end++) {
                const next = marker(nodes[end]);
                if (!next) continue;
                if (!next.close) stack.push(next.name);
                else if (next.name === stack[stack.length - 1]) stack.pop();
            }
            if (!stack.length) index = end - 1;
        }
        units.push(nodes.slice(start, index + 1));
    }
    return units;
}

export function blockLocation(block) {
    const units = block?.parentNode ? blockUnits(block.parentNode) : [];
    const index = units.findIndex((unit) => unit.includes(block));
    return { units, index, canUp: index > 0, canDown: index >= 0 && index < units.length - 1 };
}

export function moveBlock(block, direction) {
    const { units, index } = blockLocation(block);
    const adjacent = direction === 'up' ? index - 1 : index + 1;
    if (index < 0 || !units[adjacent]) return false;
    const parent = block.parentNode;
    const reference = direction === 'up' ? units[adjacent][0] : units[adjacent].at(-1).nextSibling;
    for (const node of units[index]) parent.insertBefore(node, reference);
    return true;
}

export function duplicateBlock(block) {
    const { units, index } = blockLocation(block);
    if (index < 0) return null;
    const doc = block.ownerDocument;
    const template = doc.createElement('template');
    // String round-trip retains native contenteditable nodes under LWS.
    const markup = units[index]
        .map((node) => {
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- Read-only serialization of existing authored elements.
            const elementHtml = node.nodeType === 1 ? designerMarkup(node, true) : null;
            return elementHtml || node.textContent.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        })
        .join('');
    // eslint-disable-next-line @lwc/lwc/no-inner-html -- Intentional inert-template round trip of the authored DOM; LWS guards the HTML sink.
    template.innerHTML = markup;
    for (const element of template.content.querySelectorAll('[id]')) element.removeAttribute('id');
    const first = template.content.firstElementChild;
    block.parentNode.insertBefore(template.content, units[index].at(-1).nextSibling);
    return first;
}

export function removeBlock(block) {
    const { units, index } = blockLocation(block);
    if (index < 0) return null;
    const next = units[index + 1]?.[0] || units[index - 1]?.[0];
    const parent = block.parentNode;
    for (const node of units[index]) node.remove();
    if (!blockUnits(parent).length) {
        const paragraph = parent.ownerDocument.createElement('p');
        paragraph.append(parent.ownerDocument.createElement('br'));
        parent.append(paragraph);
        return paragraph;
    }
    return next;
}

function meaningful(node) {
    return !!node.textContent.trim() || !!node.querySelector('img,table,[data-dg-tag],hr');
}

/** Insert blocks at a legal boundary, splitting text instead of nesting tables in paragraphs. */
export function insertFragment(surface, range, fragment) {
    const doc = surface.ownerDocument;
    const first = fragment.firstElementChild;
    const last = fragment.lastChild;
    const blockContent = Array.from(fragment.children).some((el) => el.matches(BLOCKS));
    if (!range || !containsNode(surface, range.startContainer) || !containsNode(surface, range.endContainer)) {
        surface.append(fragment);
        return { first, last, appended: true };
    }
    const target = range.cloneRange();
    target.deleteContents();
    if (blockContent) {
        const anchor =
            target.startContainer.nodeType === 3 ? target.startContainer.parentElement : target.startContainer;
        const paragraph = anchor.closest?.(TEXT_BLOCKS);
        if (paragraph && paragraph !== surface && containsNode(surface, paragraph)) {
            const tail = target.cloneRange();
            tail.setEnd(paragraph, paragraph.childNodes.length);
            const after = paragraph.cloneNode(false);
            after.removeAttribute('id');
            after.append(tail.extractContents());
            const reference = paragraph.nextSibling;
            const parent = paragraph.parentNode;
            parent.insertBefore(fragment, reference);
            if (meaningful(after)) parent.insertBefore(after, reference);
            if (!meaningful(paragraph)) paragraph.remove();
            return { first, last, appended: false };
        }
    }
    target.insertNode(fragment);
    return { first, last, appended: false };
}

/** Author-owned relative page wrapper gives absolute elements a stable print coordinate system. */
export function positionBlock(block, surface, geometry, mode, box) {
    if (!block || !containsNode(surface, block)) return null;
    let page = block.closest('[data-pw-layout-page]');
    if (
        !page &&
        block.parentElement !== surface &&
        block.ownerDocument.defaultView?.getComputedStyle(block.parentElement).position === 'relative'
    )
        page = block.parentElement;
    if (mode === 'flow') {
        const original = block.getAttribute('data-pw-flow-style');
        if (original !== null) {
            block.setAttribute('style', original);
            block.removeAttribute('data-pw-flow-style');
        } else
            for (const property of ['position', 'left', 'top', 'right', 'bottom', 'z-index'])
                block.style.removeProperty(property);
        return block;
    }
    if (block.closest('td,th') || (block.parentElement !== surface && !page)) {
        throw new Error('Select a block directly on the page before using fixed placement.');
    }
    if (![box.x, box.y, box.width].every(Number.isFinite) || box.x < 0 || box.y < 0 || box.width <= 0) {
        throw new Error('Use a positive width and positions of zero or greater.');
    }
    const maxWidth = geometry.width - geometry.margins[1] - geometry.margins[3];
    if (box.x + box.width > maxWidth + 0.01) throw new Error('The block extends beyond the printable width.');
    if (box.y >= geometry.height - geometry.margins[0] - geometry.margins[2])
        throw new Error('The top position must be inside the printable page area.');
    if (!page) {
        page = surface.ownerDocument.createElement('div');
        page.setAttribute('data-pw-layout-page', 'true');
        page.style.cssText = `position:relative;width:100%;min-height:${geometry.height - geometry.margins[0] - geometry.margins[2]}in;`;
        const content = Array.from(surface.childNodes).filter((node) => !IGNORE.has(node.tagName));
        surface.append(page);
        for (const node of content) page.append(node);
    }
    if (!block.hasAttribute('data-pw-flow-style'))
        block.setAttribute('data-pw-flow-style', block.getAttribute('style') || '');
    block.style.position = 'absolute';
    block.style.left = box.x + 'in';
    block.style.top = box.y + 'in';
    block.style.width = box.width + 'in';
    block.style.margin = '0';
    return block;
}

export function bookmarkRange(surface, range) {
    if (!range || !containsNode(surface, range.startContainer) || !containsNode(surface, range.endContainer))
        return null;
    const path = (node) => {
        const indices = [];
        while (node !== surface) {
            indices.unshift(Array.from(node.parentNode.childNodes).indexOf(node));
            node = node.parentNode;
        }
        return indices;
    };
    const textOffset = (node, offset) => {
        const prefix = surface.ownerDocument.createRange();
        prefix.selectNodeContents(surface);
        prefix.setEnd(node, offset);
        return prefix.toString().length;
    };
    return {
        start: path(range.startContainer),
        end: path(range.endContainer),
        startOffset: range.startOffset,
        endOffset: range.endOffset,
        startText: textOffset(range.startContainer, range.startOffset),
        endText: textOffset(range.endContainer, range.endOffset)
    };
}

export function restoreRange(surface, bookmark) {
    if (!bookmark) return null;
    const resolve = (path) => path.reduce((node, index) => node?.childNodes[index], surface);
    const length = (node) => (node.nodeType === 3 ? node.nodeValue.length : node.childNodes.length);
    // HTML serialization merges adjacent text nodes, so a path can resolve to a
    // different node after Undo. Validate it against the logical text position.
    const point = (path, offset, textOffset) => {
        const node = resolve(path);
        if (node) {
            const at = Math.min(offset, length(node));
            if (!Number.isFinite(textOffset)) return { node, offset: at };
            const prefix = surface.ownerDocument.createRange();
            prefix.selectNodeContents(surface);
            prefix.setEnd(node, at);
            if (prefix.toString().length === textOffset) return { node, offset: at };
        }
        if (!Number.isFinite(textOffset)) return null;
        const walker = surface.ownerDocument.createTreeWalker(surface, 4);
        let remaining = textOffset;
        while (walker.nextNode()) {
            const text = walker.currentNode;
            if (remaining <= text.nodeValue.length) return { node: text, offset: remaining };
            remaining -= text.nodeValue.length;
        }
        return null;
    };
    const start = point(bookmark.start, bookmark.startOffset, bookmark.startText);
    const end = point(bookmark.end, bookmark.endOffset, bookmark.endText);
    if (!start || !end) return null;
    const range = surface.ownerDocument.createRange();
    range.setStart(start.node, start.offset);
    range.setEnd(end.node, end.offset);
    return range;
}

const FONT_PROPERTIES = ['font-family', 'font-weight', 'font-style'];
const familyName = (value) => (value || '').split(',')[0].replace(/["']/g, '').trim().toLowerCase();
function boundFace(element, faces) {
    const raw = element.getAttribute('style') || '';
    const key = element.getAttribute('data-pw-font-face') || /-pw-font-face\s*:\s*([a-f0-9]{64})/i.exec(raw)?.[1];
    return faces.find((face) => face.key === key || (face.mergeTag && raw.includes(face.mergeTag)));
}
export function annotateFontBindings(root, faces) {
    for (const element of root.querySelectorAll('[style]')) {
        const face = boundFace(element, faces);
        if (!face) {
            const key = /-pw-font-face\s*:\s*([a-f0-9]{64})/i.exec(element.getAttribute('style') || '')?.[1];
            if (key) element.setAttribute('data-pw-font-face', key);
            continue;
        }
        element.setAttribute('data-pw-font-face', face.key);
        const clean = (element.getAttribute('style') || '')
            .replace(/\{%font:[^}]+\}/gi, '')
            .replace(/(?:^|;)\s*-pw-font-face\s*:[^;]*/gi, '');
        element.setAttribute('style', clean);
        element.style.fontFamily = '"' + face.family + '"';
        element.style.fontWeight = String(face.weight);
        element.style.fontStyle = face.style;
    }
}
export function serializeFontBindings(root, faces) {
    for (const element of root.querySelectorAll('[data-pw-font-face]')) {
        const face = faces.find((item) => item.key === element.getAttribute('data-pw-font-face'));
        if (face) {
            element.style.fontFamily = '"' + face.family + '"';
            element.style.fontWeight = String(face.weight);
            element.style.fontStyle = face.style;
        }
        const key = element.getAttribute('data-pw-font-face');
        element.setAttribute('style', element.style.cssText + ';-pw-font-face:' + key + ';');
        element.removeAttribute('data-pw-font-face');
    }
}
function setFont(element, face) {
    element.style.fontFamily = '"' + face.family + '"';
    element.style.fontWeight = String(face.weight);
    element.style.fontStyle = face.style;
    element.setAttribute('data-pw-font-face', face.key);
}
/** Move inherited bindings onto text runs, allowing a selection to switch back to a base font. */
export function flattenFontBindings(root, faces) {
    const walk = (element, inherited) => {
        if (IGNORE.has(element.tagName)) return;
        let face = boundFace(element, faces) || inherited;
        const declared = familyName(element.style?.fontFamily);
        if (face && declared && declared !== familyName(face.family)) {
            face =
                faces.find(
                    (item) =>
                        familyName(item.family) === declared &&
                        Number(item.weight) === (parseInt(element.style.fontWeight, 10) || 400) &&
                        item.style === (element.style.fontStyle || 'normal')
                ) || null;
        }
        const ownFamily = faces.some((item) => familyName(item.family) === declared);
        const raw = (element.getAttribute('style') || '')
            .replace(/\{%font:[^}]+\}/gi, '')
            .replace(/(?:^|;)\s*-pw-font-face\s*:[^;]*/gi, '');
        if (element.hasAttribute('style')) element.setAttribute('style', raw);
        element.removeAttribute('data-pw-font-face');
        if (ownFamily) for (const property of FONT_PROPERTIES) element.style.removeProperty(property);
        if (element.hasAttribute('data-dg-tag')) {
            if (face) setFont(element, face);
            return;
        }
        for (const node of Array.from(element.childNodes)) {
            if (node.nodeType === 1) walk(node, face);
            else if (node.nodeType === 3 && face && node.nodeValue.trim()) {
                const span = root.ownerDocument.createElement('span');
                setFont(span, face);
                node.parentNode.insertBefore(span, node);
                span.append(node);
            }
        }
    };
    for (const element of Array.from(root.children)) walk(element, null);
}

const CARET_SPACE = '\u200b';
/** An editable, unstyled caret beside an atomic merge field, with no pill decoration. */
export function pillCaretRange(surface, pill, side = 'after') {
    const doc = surface.ownerDocument;
    const neighbour = side === 'before' ? pill.previousSibling : pill.nextSibling;
    let slot = neighbour?.nodeType === 1 && neighbour.hasAttribute('data-dg-caret') ? neighbour : null;
    if (!slot) {
        slot = doc.createElement('span');
        slot.setAttribute('data-dg-caret', 'true');
        slot.appendChild(doc.createTextNode(CARET_SPACE));
        pill.parentNode.insertBefore(slot, side === 'before' ? pill : pill.nextSibling);
    }
    const range = doc.createRange();
    range.setStart(slot.firstChild, slot.firstChild.nodeType === 3 ? 1 : 0);
    range.collapse(true);
    return range;
}

function removeCaretSpace(slot) {
    const walker = slot.ownerDocument.createTreeWalker(slot, 4);
    const text = walker.nextNode();
    if (text?.nodeValue.startsWith(CARET_SPACE)) {
        text.deleteData(0, 1);
        return text;
    }
    return null;
}
/** Retire a caret slot after typing, retaining actual typed text and its exact selection. */
export function releasePillCarets(surface, range) {
    if (!range) return range;
    const start = range.startContainer,
        end = range.endContainer;
    let startOffset = range.startOffset,
        endOffset = range.endOffset;
    for (const slot of surface.querySelectorAll('[data-dg-caret]')) {
        if (slot.textContent === CARET_SPACE) continue;
        const removed = removeCaretSpace(slot);
        if (removed === start) startOffset = Math.max(0, startOffset - 1);
        if (removed === end) endOffset = Math.max(0, endOffset - 1);
        while (slot.firstChild) slot.parentNode.insertBefore(slot.firstChild, slot);
        slot.remove();
    }
    if (!containsNode(surface, start) || !containsNode(surface, end)) return range;
    const restored = surface.ownerDocument.createRange();
    restored.setStart(start, startOffset);
    restored.setEnd(end, endOffset);
    return restored;
}

/** Remove editor-only caret characters and wrappers from serialized document content. */
export function stripPillCarets(root) {
    for (const slot of root.querySelectorAll('[data-dg-caret]')) {
        removeCaretSpace(slot);
        while (slot.firstChild) slot.parentNode.insertBefore(slot.firstChild, slot);
        slot.remove();
    }
}

/** Inline formatting without invalid cross-paragraph wrappers; merge fields remain atomic. */
export function styleRange(surface, range, properties, face) {
    if (!range || !containsNode(surface, range.startContainer) || !containsNode(surface, range.endContainer))
        return null;
    const doc = surface.ownerDocument;
    const set = (element) => {
        for (const [key, value] of Object.entries(properties)) element.style.setProperty(key, value);
        if (element.hasAttribute('data-dg-tag') && properties['background-color'])
            element.setAttribute('data-dg-highlight', properties['background-color']);
        if (face) setFont(element, face);
    };
    if (range.collapsed) {
        const node = range.startContainer.nodeType === 3 ? range.startContainer.parentElement : range.startContainer;
        const block = node.closest?.(TEXT_BLOCKS + ',td,th');
        if (block && block !== surface) {
            set(block);
            return range;
        }
        return null;
    }
    const same = (a, b) => a === b || !!a?.isSameNode?.(b);
    const textLength = (node) =>
        node.nodeType === 3
            ? node.nodeValue.length
            : Array.from(node.childNodes).reduce((total, child) => total + textLength(child), 0);
    const boundaryOffset = (container, offset) => {
        let total = 0,
            found = false;
        const visit = (node) => {
            if (found) return;
            if (same(node, container)) {
                total +=
                    node.nodeType === 3
                        ? offset
                        : Array.from(node.childNodes)
                              .slice(0, offset)
                              .reduce((sum, child) => sum + textLength(child), 0);
                found = true;
                return;
            }
            if (node.nodeType === 3) total += node.nodeValue.length;
            else for (const child of Array.from(node.childNodes)) visit(child);
        };
        visit(surface);
        return found ? total : null;
    };
    const from = boundaryOffset(range.startContainer, range.startOffset),
        to = boundaryOffset(range.endContainer, range.endOffset);
    if (from === null || to === null) return null;
    const runs = [],
        atoms = new Set();
    let cursor = 0;
    const collect = (node) => {
        if (node.nodeType !== 3) {
            for (const child of Array.from(node.childNodes)) collect(child);
            return;
        }
        const start = Math.max(0, from - cursor),
            end = Math.min(node.nodeValue.length, to - cursor);
        cursor += node.nodeValue.length;
        if (end <= start || node.parentElement.closest('style,script')) return;
        const atom = node.parentElement.closest('[data-dg-tag]');
        if (atom) atoms.add(atom);
        else runs.push({ node, start, end });
    };
    collect(surface);
    const selected = [];
    for (const { node, start, end } of runs) {
        if (end < node.nodeValue.length) node.splitText(end);
        const text = start ? node.splitText(start) : node;
        const span = doc.createElement('span');
        set(span);
        text.parentNode.insertBefore(span, text);
        span.append(text);
        selected.push(text);
    }
    for (const atom of atoms) {
        set(atom);
        selected.push(atom);
    }
    if (!selected.length) return null;
    selected.sort((a, b) => (a === b ? 0 : a.compareDocumentPosition(b) & 4 ? -1 : 1));
    const first = selected[0],
        last = selected.at(-1);
    const result = doc.createRange();
    first.nodeType === 3 ? result.setStart(first, 0) : result.setStartBefore(first);
    last.nodeType === 3 ? result.setEnd(last, last.nodeValue.length) : result.setEndAfter(last);
    return result;
}

/** Keep concrete text endpoints across binding normalization; moving a node relocates a live Range. */
export function applyFontRange(surface, range, properties, face, faces) {
    const result = styleRange(surface, range, properties, face);
    if (!result) return null;
    const start = result.startContainer,
        end = result.endContainer,
        startOffset = result.startOffset,
        endOffset = result.endOffset;
    flattenFontBindings(surface, faces);
    const restored = surface.ownerDocument.createRange();
    const length = (node) => (node.nodeType === 3 ? node.nodeValue.length : node.childNodes.length);
    restored.setStart(start, Math.min(startOffset, length(start)));
    restored.setEnd(end, Math.min(endOffset, length(end)));
    return restored;
}

/** A logical grid, including row/column spans, rather than a row.children index. */
export function tableGrid(table) {
    const rows = Array.from(table.rows),
        grid = [],
        positions = new Map();
    for (let r = 0; r < rows.length; r++) {
        grid[r] ||= [];
        let column = 0;
        for (const cell of Array.from(rows[r].cells)) {
            while (grid[r][column]) column++;
            const rowSpan = Math.max(1, cell.rowSpan || 1),
                colSpan = Math.max(1, cell.colSpan || 1);
            positions.set(cell, { row: r, column, rowSpan, colSpan });
            for (let y = r; y < Math.min(rows.length, r + rowSpan); y++) {
                grid[y] ||= [];
                for (let x = column; x < column + colSpan; x++) grid[y][x] = cell;
            }
            column += colSpan;
        }
    }
    return { rows, grid, positions, width: Math.max(0, ...grid.map((row) => row.length)) };
}

/** Expand a selection to include every intersecting merged cell in full. */
export function tableRectangle(table, first, last) {
    const layout = tableGrid(table),
        a = layout.positions.get(first),
        b = layout.positions.get(last);
    if (!a || !b) return null;
    let top = Math.min(a.row, b.row),
        left = Math.min(a.column, b.column),
        bottom = Math.max(a.row + a.rowSpan, b.row + b.rowSpan),
        right = Math.max(a.column + a.colSpan, b.column + b.colSpan),
        changed;
    do {
        changed = false;
        for (let r = top; r < bottom; r++)
            for (let c = left; c < right; c++) {
                const p = layout.positions.get(layout.grid[r]?.[c]);
                if (!p) continue;
                const bounds = [
                    Math.min(top, p.row),
                    Math.min(left, p.column),
                    Math.max(bottom, p.row + p.rowSpan),
                    Math.max(right, p.column + p.colSpan)
                ];
                if (bounds[0] !== top || bounds[1] !== left || bounds[2] !== bottom || bounds[3] !== right)
                    changed = true;
                [top, left, bottom, right] = bounds;
            }
    } while (changed);
    const cells = [];
    for (let r = top; r < bottom; r++)
        for (let c = left; c < right; c++) {
            const cell = layout.grid[r]?.[c];
            if (cell && !cells.includes(cell)) cells.push(cell);
        }
    return { ...layout, top, left, bottom, right, cells };
}

export function mergeTableCells(table, first, last) {
    const rectangle = tableRectangle(table, first, last);
    if (!rectangle || rectangle.cells.length < 2) return null;
    // HTML row spans cannot cross a header/body/footer section boundary.
    if (new Set(rectangle.cells.map((cell) => cell.parentElement.parentElement)).size > 1) return null;
    const keep = rectangle.grid[rectangle.top][rectangle.left];
    for (const cell of rectangle.cells) {
        if (cell === keep) continue;
        if (cell.textContent.trim() || cell.querySelector('img,br')) {
            keep.append(table.ownerDocument.createTextNode(' '));
            while (cell.firstChild) keep.append(cell.firstChild);
        }
        cell.remove();
    }
    keep.colSpan = rectangle.right - rectangle.left;
    keep.rowSpan = rectangle.bottom - rectangle.top;
    return keep;
}

export function splitTableCell(table, cell) {
    const { rows, positions } = tableGrid(table),
        at = positions.get(cell);
    if (!at || (at.colSpan === 1 && at.rowSpan === 1)) return null;
    cell.removeAttribute('rowspan');
    cell.removeAttribute('colspan');
    for (let r = at.row; r < Math.min(rows.length, at.row + at.rowSpan); r++) {
        const ref = Array.from(rows[r].cells).find(
            (candidate) => positions.get(candidate)?.column >= at.column + at.colSpan
        );
        for (let c = at.column; c < at.column + at.colSpan; c++) {
            if (r === at.row && c === at.column) continue;
            rows[r].insertBefore(newTableCell(table.ownerDocument, cell, cell.tagName === 'TH'), ref || null);
        }
    }
    return cell;
}
function newTableCell(doc, reference, header) {
    const cell = doc.createElement(header ? 'th' : 'td');
    if (reference?.getAttribute('style')) cell.setAttribute('style', reference.getAttribute('style'));
    if (reference?.getAttribute('data-pw-font-face'))
        cell.setAttribute('data-pw-font-face', reference.getAttribute('data-pw-font-face'));
    cell.style.removeProperty('width');
    cell.style.removeProperty('height');
    cell.style.removeProperty('box-shadow');
    cell.style.removeProperty('outline');
    if (!header && reference?.tagName === 'TH') {
        cell.style.background = 'transparent';
        cell.style.color = 'inherit';
        cell.style.fontWeight = 'normal';
    }
    cell.textContent = '\u00a0';
    return cell;
}
function preserveBoundaryTags(cell, row) {
    const own = Array.from((cell.textContent || '').matchAll(/\{([#^/])([^{}]+)\}/g));
    const balance = new Map();
    for (const [, kind, name] of own) {
        const key = name.split(/[|:]/)[0];
        balance.set(key, (balance.get(key) || 0) + (kind === '/' ? -1 : 1));
    }
    const remaining = Array.from(row.cells).filter((item) => item !== cell);
    if (!remaining.length) return;
    const open = [],
        close = [];
    for (const [tag, kind, name] of own) {
        const count = balance.get(name.split(/[|:]/)[0]);
        if (kind !== '/' && count > 0) open.push(tag);
        if (kind === '/' && count < 0) close.push(tag);
    }
    if (open.length)
        remaining[0].insertBefore(cell.ownerDocument.createTextNode(open.join('')), remaining[0].firstChild);
    if (close.length) remaining.at(-1).append(cell.ownerDocument.createTextNode(close.join('')));
}
export function editTableGrid(table, cell, action) {
    if (!['rowBefore', 'rowAfter', 'rowDel', 'colBefore', 'colAfter', 'colDel'].includes(action)) return null;
    const { rows, grid, positions, width } = tableGrid(table),
        at = positions.get(cell),
        doc = table.ownerDocument;
    if (!at) return null;
    let target = cell;
    if (action === 'rowBefore' || action === 'rowAfter') {
        const index = at.row + (action === 'rowAfter' ? 1 : 0),
            row = doc.createElement('tr');
        row.style.pageBreakInside = 'avoid';
        let section = rows[at.row].parentElement;
        if (section.tagName === 'THEAD' && action === 'rowAfter' && !rows[index]?.closest('thead'))
            section = table.tBodies[0] || table.createTBody();
        const reference = rows[index]?.parentElement === section ? rows[index] : null;
        section.insertBefore(row, reference);
        const extended = new Set();
        for (let column = 0; column < width; column++) {
            const above = index > 0 ? grid[index - 1]?.[column] : null,
                position = positions.get(above);
            if (position && position.row < index && position.row + position.rowSpan > index) {
                if (!extended.has(above)) {
                    above.rowSpan++;
                    extended.add(above);
                }
                continue;
            }
            const referenceCell = grid[Math.min(index, rows.length - 1)]?.[column] || cell;
            const added = newTableCell(doc, referenceCell, section.tagName === 'THEAD');
            row.append(added);
            target = target === cell ? added : target;
        }
    } else if (action === 'rowDel') {
        const adjusted = new Set();
        for (const candidate of grid[at.row] || []) {
            if (adjusted.has(candidate)) continue;
            adjusted.add(candidate);
            const position = positions.get(candidate);
            if (position.row < at.row) candidate.rowSpan = Math.max(1, candidate.rowSpan - 1);
            else if (position.rowSpan > 1 && rows[at.row + 1]) {
                candidate.rowSpan--;
                const next = rows[at.row + 1];
                const reference = Array.from(next.cells).find((item) => positions.get(item)?.column > position.column);
                next.insertBefore(candidate, reference || null);
            }
        }
        rows[at.row].remove();
        target = rows[at.row + 1]?.cells[0] || rows[at.row - 1]?.cells[0];
    } else if (action === 'colBefore' || action === 'colAfter') {
        const index = at.column + (action === 'colAfter' ? at.colSpan : 0),
            extended = new Set();
        for (let r = 0; r < rows.length; r++) {
            const inside = grid[r]?.[index],
                position = positions.get(inside);
            if (position && position.column < index && position.column + position.colSpan > index) {
                if (!extended.has(inside)) {
                    inside.colSpan++;
                    extended.add(inside);
                }
                continue;
            }
            const reference = Array.from(rows[r].cells).find((item) => positions.get(item)?.column >= index);
            const added = newTableCell(
                doc,
                grid[r]?.[Math.min(index, width - 1)] || cell,
                rows[r].parentElement.tagName === 'THEAD'
            );
            rows[r].insertBefore(added, reference || null);
            if (r === at.row) target = added;
        }
        const group = Array.from(table.children).find((item) => item.tagName === 'COLGROUP');
        if (group) group.insertBefore(doc.createElement('col'), group.children[index] || null);
    } else {
        const removed = new Set();
        for (let r = 0; r < rows.length; r++) {
            const candidate = grid[r]?.[at.column];
            if (!candidate || removed.has(candidate)) continue;
            removed.add(candidate);
            if (candidate.colSpan > 1) candidate.colSpan--;
            else {
                preserveBoundaryTags(candidate, rows[r]);
                candidate.remove();
            }
        }
        const group = Array.from(table.children).find((item) => item.tagName === 'COLGROUP');
        group?.children[at.column]?.remove();
        target = rows[at.row].cells[Math.min(at.column, rows[at.row].cells.length - 1)];
    }
    if (!table.querySelector('td,th')) {
        table.remove();
        return { cell: null, removed: true };
    }
    return { cell: target?.isConnected ? target : table.rows[0]?.cells[0], removed: false };
}
