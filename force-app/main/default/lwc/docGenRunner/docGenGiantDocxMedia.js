const DOCUMENT_RELS = 'word/_rels/document.xml.rels';
const CONTENT_TYPES = '[Content_Types].xml';
const RELS_NS = 'http://schemas.openxmlformats.org/package/2006/relationships';
const IMAGE_REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image';
const CONTENT_TYPE_BY_EXTENSION = {
    png: 'image/png',
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    gif: 'image/gif',
    bmp: 'image/bmp'
};
const EMU_PER_PIXEL = 9525;
const DEFAULT_CONTENT_WIDTH = 624;
const DEFAULT_CONTENT_HEIGHT = 864;
const MAX_DISTINCT_IMAGE_BYTES = 20 * 1024 * 1024;

export function wordTextPosition(xml, index, initiallyInsideWordText = false) {
    const open = xml.lastIndexOf('<w:t', index);
    const close = xml.lastIndexOf('</w:t>', index);
    if (open < 0) return initiallyInsideWordText && close < 0;
    return /[>\s]/.test(xml.charAt(open + 4)) && xml.indexOf('>', open) < index && open > close;
}

export function giantDocxFieldValue(record, field) {
    let result = record;
    for (const name of field.split('.')) result = result?.[name];
    return result;
}

export function giantDocxImageTags(xml, initiallyInsideWordText = false) {
    const tags = new Map();
    for (const match of xml.matchAll(/\{%([A-Za-z_][\w.]*)(?::([^{}]+))?\}/g)) {
        const [, field, size] = match;
        if (
            wordTextPosition(xml, match.index, initiallyInsideWordText) &&
            !(size && /^(?:Image|asset|QR|BARCODE)$/i.test(field))
        ) {
            tags.set(match.index, { field, size });
        }
    }
    return tags;
}

function fileReference(value) {
    if (value == null || String(value).trim() === '') return null;
    const text = String(value).trim();
    if (/^06[89][A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/.test(text)) return text;
    const path =
        /^\/sfc\/servlet\.shepherd\/(version|document)\/download\/(06[89][A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?)(?:\?[^#\s]*)?$/i.exec(
            text
        );
    if (path && path[2].startsWith(path[1].toLowerCase() === 'version' ? '068' : '069')) return path[2];
    throw new Error(
        'Giant Query Word image fields must contain a Salesforce File ID or a relative Salesforce download link.'
    );
}

function imagePixels(extension, base64) {
    // Many images have large metadata; inspect only a bounded header.
    const bytes = atob(base64.substring(0, 87384));
    const valueAt = (i) => bytes.charCodeAt(i) || 0;
    const big16 = (i) => valueAt(i) * 256 + valueAt(i + 1);
    const little16 = (i) => valueAt(i) + valueAt(i + 1) * 256;
    const big32 = (i) => big16(i) * 65536 + big16(i + 2);
    const little32 = (i) => little16(i) + little16(i + 2) * 65536;
    if (extension === 'png' && bytes.slice(12, 16) === 'IHDR') return [big32(16), big32(20)];
    if (extension === 'gif' && bytes.startsWith('GIF')) return [little16(6), little16(8)];
    if (extension === 'bmp' && bytes.startsWith('BM')) {
        if (little32(14) === 12) return [little16(18), little16(20)];
        const height = little32(22);
        return [little32(18), Math.abs(height > 0x7fffffff ? height - 0x100000000 : height)];
    }
    if ((extension === 'jpeg' || extension === 'jpg') && big16(0) === 0xffd8) {
        for (let i = 2; i + 8 < bytes.length && valueAt(i) === 0xff; ) {
            while (valueAt(i) === 0xff) i++;
            const marker = valueAt(i++);
            if (marker === 0xda || marker === 0xd9) break;
            if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
                return [big16(i + 5), big16(i + 3)];
            }
            const sectionLength = big16(i);
            if (sectionLength < 2) break;
            i += sectionLength;
        }
    }
    return [0, 0];
}

function dimension(token, available) {
    if (!token.trim()) return null;
    const match = /^(m)?(\d+)(px|%)?$/i.exec(token.trim());
    if (!match) throw new Error('Invalid Giant Query Word image dimension.');
    const numeric = Number(match[2]);
    if (numeric < 1 || numeric > 4096) throw new Error('Giant Query Word image dimensions must be between 1 and 4096.');
    return { max: Boolean(match[1]), pixels: match[3] === '%' ? (available * numeric) / 100 : numeric };
}

function drawingDimensions(dimensions, size) {
    let [width, height] = dimensions;
    if (!width || !height) [width, height] = [320, 240];
    let w;
    let h;
    if (size) {
        const tokens = /^(.*?)x(.*?)$/i.exec(size.replace(/px/gi, ''));
        if (tokens) {
            w = dimension(tokens[1], DEFAULT_CONTENT_WIDTH);
            h = dimension(tokens[2], DEFAULT_CONTENT_HEIGHT);
        } else if (/^\s*\d+(?:px)?\s*$/i.test(size)) {
            w = dimension('m' + size.trim(), DEFAULT_CONTENT_WIDTH);
            h = w;
        } else {
            throw new Error('Invalid Giant Query Word image size. Use width x height in pixels.');
        }
        if (!w && !h) throw new Error('Invalid Giant Query Word image size. Use width x height in pixels.');
    }
    const ratio = width / height;
    if (w && !w.max && h && !h.max) {
        width = w.pixels;
        height = h.pixels;
    } else {
        if (w && !w.max) {
            width = w.pixels;
            height = width / ratio;
        } else if (h && !h.max) {
            height = h.pixels;
            width = height * ratio;
        }
        const ceilingW = w?.max ? w.pixels : w ? Infinity : DEFAULT_CONTENT_WIDTH;
        const ceilingH = h?.max ? h.pixels : h ? Infinity : DEFAULT_CONTENT_HEIGHT;
        const scale = Math.min(1, ceilingW / width, ceilingH / height);
        width *= scale;
        height *= scale;
    }
    return [Math.max(1, Math.round(width * EMU_PER_PIXEL)), Math.max(1, Math.round(height * EMU_PER_PIXEL))];
}

function addChildren(xml, rootName, children, implicitRoot) {
    if (!xml && implicitRoot) xml = implicitRoot;
    const root = new RegExp(`<([\\w.-]+:)?${rootName}(?:[\\s/>])`).exec(xml || '');
    if (!root) throw new Error(`The Word template is missing its ${rootName} part.`);
    const qualified = (root[1] || '') + rootName;
    const close = `</${qualified}>`;
    const addition = children(root[1] || '');
    const closeAt = xml.lastIndexOf(close);
    if (closeAt >= 0) return xml.slice(0, closeAt) + addition + xml.slice(closeAt);
    const headerEnd = xml.indexOf('>', root.index);
    if (headerEnd > 0 && xml[headerEnd - 1] === '/') {
        return xml.slice(0, headerEnd - 1) + '>' + addition + close + xml.slice(headerEnd + 1);
    }
    throw new Error(`The Word template's ${rootName} part is incomplete.`);
}

function drawingMarkup(id, relationshipId, width, height) {
    const extent = `cx="${width}" cy="${height}"`;
    return `</w:t><w:drawing><wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" distT="0" distB="0" distL="0" distR="0"><wp:extent ${extent}/><wp:docPr id="${id}" name="Portwood image ${id}"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="${id}" name="Portwood image ${id}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:embed="${relationshipId}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext ${extent}/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing><w:t xml:space="preserve">`;
}

export class GiantDocxMedia {
    constructor(parts, placements, loadImage) {
        this.parts = parts;
        this.loadImage = loadImage;
        this.byReference = new Map();
        this.byVersion = new Map();
        this.mediaBytes = 0;
        this.sequence = 0;
        this.drawingId = 0;
        this.reservedDrawingIds = new Set();
        this.reservedPaths = new Set([
            ...Object.keys(parts.allXmlParts),
            ...Object.keys(parts.imageBase64Map || {}),
            ...Object.keys(parts.imageCvIdMap || {}),
            ...Object.keys(parts.imageUrlMap || {})
        ]);
        const rels = parts.allXmlParts[DOCUMENT_RELS] || '';
        this.reservedRels = new Set([...rels.matchAll(/\bId=["']([^"']+)["']/g)].map((value) => value[1]));
        for (const source of [parts.allXmlParts['word/document.xml'], ...placements.map((slot) => slot.innerXml)]) {
            for (const match of (source || '').matchAll(/<(?:\w+:)?(?:docPr|cNvPr)\b[^>]*\bid=["'](\d+)["']/g)) {
                this.reservedDrawingIds.add(Number(match[1]));
            }
        }
    }

    async preparePage(records, tags, fields) {
        const referenceToField = new Map();
        const allowed = new Set(fields);
        for (const { field } of tags.values()) {
            if (!allowed.has(field)) throw new Error(`Add ${field} to the Giant Query field list to render its image.`);
        }
        for (const record of records) {
            for (const { field } of tags.values()) {
                const reference = fileReference(giantDocxFieldValue(record, field));
                if (reference && !this.byReference.has(reference)) referenceToField.set(reference, field);
            }
        }
        for (const [reference, field] of referenceToField) {
            if (this.byReference.has(reference)) continue;
            // Keep Aura response memory bounded and avoid parallel duplicate fetches.
            // eslint-disable-next-line no-await-in-loop
            const image = await this.loadImage({ fileId: reference });
            const extension = image?.extension?.toLowerCase();
            const canonical = image?.contentVersionId;
            if (
                !canonical ||
                !/^068[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/.test(canonical) ||
                !Object.prototype.hasOwnProperty.call(CONTENT_TYPE_BY_EXTENSION, extension) ||
                !image?.base64
            ) {
                throw new Error(`The Salesforce image file for ${field} could not be read.`);
            }
            let embedded = this.byVersion.get(canonical);
            if (!embedded) {
                this.mediaBytes += Math.ceil((image.base64.length * 3) / 4);
                if (this.mediaBytes > MAX_DISTINCT_IMAGE_BYTES) {
                    throw new Error('Giant Query Word images exceed the 20 MB dynamic image budget.');
                }
                let path;
                let relationshipId;
                do {
                    this.sequence++;
                    path = `word/media/docgen_giant_image_${this.sequence}.${extension}`;
                    relationshipId = 'rIdPortwoodGiantImage' + this.sequence;
                } while (this.reservedPaths.has(path) || this.reservedRels.has(relationshipId));
                embedded = {
                    extension,
                    base64: image.base64,
                    path,
                    relationshipId,
                    pixels: imagePixels(extension, image.base64)
                };
                this.byVersion.set(canonical, embedded);
            }
            this.byReference.set(reference, embedded);
            this.byReference.set(canonical, embedded);
        }
    }

    drawing(value, size) {
        const reference = fileReference(value);
        if (!reference) return '';
        const image = this.byReference.get(reference);
        if (!image) throw new Error('The Salesforce image file is missing from the Word document.');
        const [width, height] = drawingDimensions(image.pixels, size);
        do {
            this.drawingId++;
        } while (this.reservedDrawingIds.has(this.drawingId));
        return drawingMarkup(this.drawingId, image.relationshipId, width, height);
    }

    writeImages(images) {
        if (!this.byVersion.size) return;
        const { allXmlParts } = this.parts;
        const versions = [...this.byVersion.values()];
        allXmlParts[DOCUMENT_RELS] = addChildren(
            allXmlParts[DOCUMENT_RELS],
            'Relationships',
            (prefix) =>
                versions
                    .map(
                        ({ relationshipId, path }) =>
                            `<${prefix}Relationship Id="${relationshipId}" Type="${IMAGE_REL}" Target="${path.slice(5)}"/>`
                    )
                    .join(''),
            `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="${RELS_NS}"></Relationships>`
        );
        const known = new Set(
            [...(allXmlParts[CONTENT_TYPES] || '').matchAll(/\bExtension=["']([^"']+)["']/g)].map((match) =>
                match[1].toLowerCase()
            )
        );
        const newTypes = [...new Set(versions.map((version) => version.extension))].filter(
            (extension) => !known.has(extension)
        );
        if (newTypes.length) {
            allXmlParts[CONTENT_TYPES] = addChildren(allXmlParts[CONTENT_TYPES], 'Types', (prefix) =>
                newTypes
                    .map(
                        (extension) =>
                            `<${prefix}Default Extension="${extension}" ContentType="${CONTENT_TYPE_BY_EXTENSION[extension]}"/>`
                    )
                    .join('')
            );
        }
        for (const { path, base64 } of versions) images[path] = base64;
    }
}
