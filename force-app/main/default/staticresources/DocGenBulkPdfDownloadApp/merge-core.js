(() => {
const pageTreeFanout = 64;
const catalogId = 1;
const rootPagesId = 2;
const maxOffset = 9_999_999_999;
const encoder = new TextEncoder();
const pdfHeader = Uint8Array.of(37, 80, 68, 70, 45, 49, 46, 55, 10, 37, 226, 227, 207, 211, 10);
const streamStart = encoder.encode('\nstream\n');
const streamEnd = encoder.encode('\nendstream');
const objectEnd = encoder.encode('\nendobj\n');

/** Copies pages and their reachable objects from independent documents to an incremental binary sink.
 * The caller positions the sink at checkpoint.offset and truncates any uncommitted bytes on resume.
 * A checkpoint is valid after append resolves, or before the first append, and before finish.
 */
function createIncrementalPdfMerger({ pdfLib, sink, checkpoint = null, padOddDocuments = false }) {
  const { PDFContext, PDFDocument, PDFName, PDFNull, PDFNumber, PDFObjectCopier, PDFPageLeaf, PDFRef,
    PDFStream, ParseSpeeds } = pdfLib;
  if (checkpoint && (checkpoint.version !== 1 || !Array.isArray(checkpoint.pageIds) ||
      !Array.isArray(checkpoint.leafIds) || !Array.isArray(checkpoint.objectOffsets))) {
    throw new Error('Invalid PDF merge checkpoint.');
  }
  const pageIds = checkpoint?.pageIds.slice() ?? [];
  const leafIds = checkpoint?.leafIds.slice() ?? [];
  const objectOffsets = checkpoint?.objectOffsets.slice() ?? [null, null, null];
  let offset = checkpoint?.offset ?? 0;
  let phase = 'ready';
  const buffer = new Uint8Array(64 * 1024);
  let buffered = 0;

  if (checkpoint && (!Number.isSafeInteger(offset) || offset < 0 || offset > maxOffset ||
      leafIds.length !== Math.ceil(pageIds.length / pageTreeFanout) || objectOffsets.length < 3 ||
      objectOffsets[catalogId] !== null || objectOffsets[rootPagesId] !== null)) {
    throw new Error('Invalid PDF merge checkpoint.');
  }

  async function deliver(bytes) {
    const count = await sink.write(bytes);
    if (typeof count === 'number' && count !== bytes.length) throw new Error('Incomplete PDF write.');
  }

  async function flush() {
    if (buffered > 0) {
      await deliver(buffer.subarray(0, buffered));
      buffered = 0;
    }
  }

  async function write(bytes) {
    if (offset + bytes.length > maxOffset) throw new Error('PDF exceeds the classic cross-reference size limit.');
    if (bytes.length >= buffer.length) {
      await flush();
      await deliver(bytes);
    } else {
      if (buffered + bytes.length > buffer.length) await flush();
      buffer.set(bytes, buffered);
      buffered += bytes.length;
    }
    offset += bytes.length;
  }

  function writeText(text) {
    return write(encoder.encode(text));
  }

  function writeObjectBytes(object) {
    const bytes = new Uint8Array(object.sizeInBytes());
    return write(bytes.subarray(0, object.copyBytesInto(bytes, 0)));
  }

  async function writeIndirect(id, object) {
    objectOffsets[id] = offset;
    await writeText(`${id} 0 obj\n`);
    if (object instanceof PDFStream) {
      const contents = object.getContents();
      object.dict.set(PDFName.Length, PDFNumber.of(contents.length));
      await writeObjectBytes(object.dict);
      await write(streamStart);
      await write(contents);
      await write(streamEnd);
    } else if (typeof object === 'string') {
      await writeText(object);
    } else {
      await writeObjectBytes(object);
    }
    await write(objectEnd);
  }

  function begin() {
    if (phase !== 'ready') throw new Error(`PDF merger cannot write while ${phase}.`);
    phase = 'writing';
  }

  async function append(bytes) {
    begin();
    try {
      const source = await PDFDocument.load(bytes, { parseSpeed: ParseSpeeds.Fastest, updateMetadata: false,
        throwOnInvalidObject: true });
      const sourcePages = source.getPages();
      if (sourcePages.length === 0) throw new Error('Source PDF has no pages.');
      if (padOddDocuments && sourcePages.length % 2 === 1) {
        const last = sourcePages.at(-1);
        const box = last.getMediaBox();
        const crop = last.getCropBox();
        const blank = source.addPage([box.width, box.height]);
        blank.setMediaBox(box.x, box.y, box.width, box.height);
        blank.setCropBox(crop.x, crop.y, crop.width, crop.height);
        blank.setRotation(last.getRotation());
      }
      const firstId = objectOffsets.length;
      const destination = PDFContext.create();
      destination.largestObjectNumber = firstId - 1;
      const copier = PDFObjectCopier.for(source.context, destination);
      const reservedLeaves = new Set();

      for (const sourcePage of source.getPages()) {
        const pageRef = copier.copy(sourcePage.ref);
        const page = destination.lookup(pageRef, PDFPageLeaf);
        if (pageIds.length % pageTreeFanout === 0) {
          const leaf = destination.nextRef().objectNumber;
          leafIds.push(leaf);
          reservedLeaves.add(leaf);
        }
        page.setParent(PDFRef.of(leafIds.at(-1)));
        pageIds.push(pageRef.objectNumber);
      }

      if (offset === 0) await write(pdfHeader);
      for (let id = firstId; id <= destination.largestObjectNumber; id += 1) {
        objectOffsets.push(null);
        if (!reservedLeaves.has(id)) {
          await writeIndirect(id, destination.lookup(PDFRef.of(id)) ?? PDFNull);
        }
      }
      await flush();
      phase = 'ready';
      return source.getPageCount();
    } catch (error) {
      phase = 'failed';
      throw error;
    }
  }

  function snapshot() {
    if (phase !== 'ready') throw new Error(`PDF merger cannot checkpoint while ${phase}.`);
    return { version: 1, offset, objectOffsets: objectOffsets.slice(), pageIds: pageIds.slice(), leafIds: leafIds.slice() };
  }

  async function writePageTree() {
    const allNodes = leafIds.map((id, index) => {
      const start = index * pageTreeFanout;
      const kids = pageIds.slice(start, start + pageTreeFanout);
      return { id, kids, count: kids.length, parent: rootPagesId };
    });
    let level = allNodes.slice();
    while (level.length > pageTreeFanout) {
      const parents = [];
      for (let index = 0; index < level.length; index += pageTreeFanout) {
        const group = level.slice(index, index + pageTreeFanout);
        const id = objectOffsets.push(null) - 1;
        let count = 0;
        for (const child of group) {
          child.parent = id;
          count += child.count;
        }
        parents.push({ id, kids: group.map(child => child.id), count, parent: rootPagesId });
      }
      allNodes.push(...parents);
      level = parents;
    }

    const refs = (ids) => ids.map(id => `${id} 0 R`).join(' ');
    for (const node of allNodes) {
      await writeIndirect(node.id,
        `<< /Type /Pages /Parent ${node.parent} 0 R /Kids [${refs(node.kids)}] /Count ${node.count} >>`);
    }
    await writeIndirect(rootPagesId,
      `<< /Type /Pages /Kids [${refs(level.map(node => node.id))}] /Count ${pageIds.length} >>`);
  }

  async function finish() {
    if (pageIds.length === 0) throw new Error('Merge requires at least one source PDF.');
    begin();
    try {
      await writePageTree();
      await writeIndirect(catalogId, `<< /Type /Catalog /Pages ${rootPagesId} 0 R >>`);
      const indexOffset = offset;
      await writeText(`xref\n0 ${objectOffsets.length}\n0000000000 65535 f \n`);
      for (let start = 1; start < objectOffsets.length; start += 2048) {
        const entries = objectOffsets.slice(start, start + 2048).map(value => {
          if (value === null) throw new Error('PDF object is missing its byte offset.');
          return `${String(value).padStart(10, '0')} 00000 n \n`;
        });
        await writeText(entries.join(''));
      }
      await writeText(`trailer\n<< /Size ${objectOffsets.length} /Root ${catalogId} 0 R >>\nstartxref\n${indexOffset}\n%%EOF\n`);
      await flush();
      phase = 'finished';
      return { bytes: offset, pages: pageIds.length };
    } catch (error) {
      phase = 'failed';
      throw error;
    }
  }

  return { append, snapshot, finish };
}

self.createPortwoodIncrementalPdfMerger = createIncrementalPdfMerger;
})();
