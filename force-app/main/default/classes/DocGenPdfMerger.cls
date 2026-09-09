/**
 * Server-side PDF merge for the bulk "Combined PDF" duplex-padding feature (#382).
 *
 * Concatenates several single-document PDFs into one, and — when a duplex mode is
 * given — appends ONE completely blank page after any document with an odd page
 * count so every document starts on the front of a sheet under double-sided
 * printing. The blank page has no content stream, so it draws nothing and carries
 * no page number; real pages keep the numbering baked in when each document was
 * rendered on its own.
 *
 * SCOPE: this targets PDFs produced by Portwood's own renderer (Flying Saucer /
 * iText via Blob.toPdf) — %PDF-1.4, a classic cross-reference table, a flat
 * /Pages tree, explicit /MediaBox per page, direct /Length on streams, no
 * encryption and no cross-reference or object streams. It is NOT a general-
 * purpose PDF library. Arbitrary user-uploaded PDFs go through the client-side
 * docGenPdfMerger.js instead.
 *
 * The byte-level string handling (hex round-trip, latin1 1:1 char/byte mapping)
 * mirrors DocGenAcroFormService, which already does this class of work in Apex.
 */
global with sharing class DocGenPdfMerger {
    global class DocGenPdfMergeException extends Exception {
    }

    // 256-entry lookup: byte value -> lowercase 2-char hex. Built once.
    private static final List<String> HEX2;
    static {
        HEX2 = new List<String>();
        String h = '0123456789abcdef';
        for (Integer i = 0; i < 256; i++) {
            HEX2.add(h.substring(i / 16, i / 16 + 1) + h.substring(Math.mod(i, 16), Math.mod(i, 16) + 1));
        }
    }

    // %PDF-1.4\n%<e2 e3 cf d3>\n  — header + binary-file marker comment
    private static final String HEADER_HEX = '255044462d312e340a25e2e3cfd30a';

    private class ObjRec {
        Integer num;
        String dictPart; // ASCII: everything from after "N 0 obj" up to "stream" (or up to "endobj")
        String streamHex; // hex of "stream ... endstream\n" bytes, or '' for a plain object
        Boolean isPage = false;
    }

    private class Src {
        Map<Integer, ObjRec> objs = new Map<Integer, ObjRec>();
        List<Integer> pageOrder = new List<Integer>();
        String lastMediaBox = '/MediaBox [0 0 612 792]';
        // Object numbers of embedded font PROGRAMS (/FontFile, /FontFile2,
        // /FontFile3 targets). These are the only streams safe to deduplicate
        // across parts: a font subset is byte-identical for every render of the
        // same template and is referenced by exactly one FontDescriptor. Page
        // content streams and image XObjects are NEVER deduped — two records
        // that render identical page text produce byte-identical content
        // streams, and collapsing those corrupts the page tree (#382).
        Set<Integer> fontFileObjs = new Set<Integer>();
    }

    /**
     * @param pdfs  single-document PDFs, in final packet order
     * @param padOddDocuments  when true, every document with an odd page count
     *        (including the last) gets one blank page appended before the merge
     * @return the merged PDF
     */
    global static Blob mergePdfs(List<Blob> pdfs, Boolean padOddDocuments) {
        if (pdfs == null || pdfs.isEmpty()) {
            throw new DocGenPdfMergeException('No PDFs supplied to merge.');
        }
        if (pdfs.size() == 1 && padOddDocuments != true) {
            return pdfs[0];
        }
        return mergeCore(pdfs, null, padOddDocuments == true);
    }

    /**
     * As mergePdfs, but the parts are ContentVersion Ids. Each blob is loaded by
     * Id inside the merge loop and released before the next — a single
     * `SELECT VersionData` for hundreds of parts heap-crashes the query itself.
     * @param partCvIds  ContentVersion Ids of the single-document PDFs, in order
     */
    global static Blob mergePdfCvs(List<Id> partCvIds, Boolean padOddDocuments) {
        if (partCvIds == null || partCvIds.isEmpty()) {
            throw new DocGenPdfMergeException('No PDFs supplied to merge.');
        }
        return mergeCore(null, partCvIds, padOddDocuments == true);
    }

    // Load part blobs in chunks: one SELECT VersionData per part blows the async
    // SOQL cap (200) past ~200 parts, and one SELECT for all of them blows heap.
    private static final Integer PART_CHUNK = 40;

    private static Blob mergeCore(List<Blob> blobs, List<Id> cvIds, Boolean pad) {
        Integer partCount = (blobs != null) ? blobs.size() : cvIds.size();

        // ---- parse + renumber + dedupe, ONE part at a time ----
        //
        // Streamed on purpose (#382): the merge runs in a Queueable (12 MB async
        // heap). Parsing every part up front and holding them all is what
        // heap-crashes an ~90-100 record packet. Instead each part is parsed,
        // folded into the global object list, and released before the next.
        //
        // Font deduplication: every part carries its own embedded font subset
        // (~60 KB of Arial Unicode MS), byte-identical across parts from the same
        // template. Only embedded font PROGRAMS (Src.fontFileObjs) are
        // fingerprinted; the first copy is kept. A dropped object's slot becomes
        // "N 0 obj null endobj" so numbering stays contiguous, and the one
        // FontDescriptor reference to it is repointed at the survivor. Content
        // streams and images are deliberately left alone — see Src.fontFileObjs.
        Integer next = 1;
        List<ObjRec> allObjs = new List<ObjRec>();
        Map<Integer, ObjRec> byNum = new Map<Integer, ObjRec>();
        List<List<Integer>> docPages = new List<List<Integer>>();
        List<String> docMediaBoxes = new List<String>();
        Map<String, Integer> streamFingerprints = new Map<String, Integer>();
        Map<Integer, Integer> dedupeRemap = new Map<Integer, Integer>();

        for (Integer chunkStart = 0; chunkStart < partCount; chunkStart += PART_CHUNK) {
            Integer chunkEnd = Math.min(chunkStart + PART_CHUNK, partCount);
            List<Blob> chunkBlobs = new List<Blob>();
            if (blobs != null) {
                for (Integer k = chunkStart; k < chunkEnd; k++) {
                    chunkBlobs.add(blobs[k]);
                    blobs.set(k, null);
                }
            } else {
                List<Id> ids = new List<Id>();
                for (Integer k = chunkStart; k < chunkEnd; k++) {
                    ids.add(cvIds[k]);
                }
                Map<Id, ContentVersion> loaded = new Map<Id, ContentVersion>(
                    [SELECT VersionData FROM ContentVersion WHERE Id IN :ids WITH USER_MODE]
                );
                for (Id id : ids) {
                    chunkBlobs.add(loaded.get(id).VersionData);
                }
            }

            for (Integer ci = 0; ci < chunkBlobs.size(); ci++) {
                Src s = parse(chunkBlobs[ci]);
                chunkBlobs[ci] = null;

                List<Integer> keys = new List<Integer>(s.objs.keySet());
                keys.sort();
                Map<Integer, Integer> remap = new Map<Integer, Integer>();
                for (Integer k : keys) {
                    remap.put(k, next++);
                }
                for (Integer k : keys) {
                    ObjRec o = s.objs.get(k);
                    Integer newNum = remap.get(k);
                    ObjRec n = new ObjRec();
                    n.num = newNum;
                    n.isPage = o.isPage;

                    if (String.isNotBlank(o.streamHex) && s.fontFileObjs.contains(k)) {
                        String fp = EncodingUtil.convertToHex(
                            Crypto.generateDigest('SHA-256', Blob.valueOf(o.dictPart + '~' + o.streamHex))
                        );
                        Integer canonical = streamFingerprints.get(fp);
                        if (canonical != null) {
                            dedupeRemap.put(newNum, canonical);
                            n.dictPart = ' null ';
                            n.streamHex = '';
                            allObjs.add(n);
                            byNum.put(newNum, n);
                            continue;
                        }
                        streamFingerprints.put(fp, newNum);
                    }

                    String d = renumberRefs(o.dictPart, remap);
                    if (!dedupeRemap.isEmpty() && d.contains(' 0 R')) {
                        d = renumberRefs(d, dedupeRemap); // repoint refs to a dropped duplicate in this part
                    }
                    n.dictPart = d;
                    n.streamHex = o.streamHex;
                    allObjs.add(n);
                    byNum.put(newNum, n);
                }

                List<Integer> pn = new List<Integer>();
                for (Integer p : s.pageOrder) {
                    pn.add(remap.get(p));
                }
                docPages.add(pn);
                docMediaBoxes.add(s.lastMediaBox);
                s = null;
            }
        }

        Integer pagesNum = next++;
        Integer catNum = next++;

        // ---- build the padded /Kids list + blank-page objects ----
        List<Integer> kids = new List<Integer>();
        List<ObjRec> blanks = new List<ObjRec>();
        for (Integer d = 0; d < docPages.size(); d++) {
            List<Integer> pn = docPages.get(d);
            for (Integer p : pn) {
                ObjRec pg = byNum.get(p);
                if (pg != null) {
                    pg.dictPart = setParent(pg.dictPart, pagesNum);
                }
                kids.add(p);
            }
            if (pad && Math.mod(pn.size(), 2) == 1) {
                ObjRec blank = new ObjRec();
                blank.num = next++;
                blank.dictPart =
                    '\n<< /Type /Page /Parent ' +
                    pagesNum +
                    ' 0 R ' +
                    docMediaBoxes.get(d) +
                    ' /Resources << >> >>\n';
                blank.streamHex = '';
                blanks.add(blank);
                kids.add(blank.num);
            }
        }

        byNum = null;
        docPages = null;

        // ---- assemble, entirely in the hex domain ----
        List<String> hx = new List<String>{ HEADER_HEX };
        Integer bytePos = HEADER_HEX.length() / 2;
        Map<Integer, Integer> offsets = new Map<Integer, Integer>();

        allObjs.addAll(blanks);
        for (Integer oi = 0; oi < allObjs.size(); oi++) {
            ObjRec o = allObjs[oi];
            offsets.put(o.num, bytePos);
            String head = o.num + ' 0 obj';
            hx.add(ah(head));
            hx.add(ah(o.dictPart));
            bytePos += head.length() + o.dictPart.length();
            if (String.isNotBlank(o.streamHex)) {
                hx.add(o.streamHex);
                bytePos += o.streamHex.length() / 2;
            }
            hx.add(ah('endobj\n'));
            bytePos += 7;
            allObjs[oi] = null; // release each object once its bytes are emitted
        }

        offsets.put(pagesNum, bytePos);
        String pagesObj =
            pagesNum +
            ' 0 obj\n<< /Type /Pages /Kids [' +
            joinRefs(kids) +
            '] /Count ' +
            kids.size() +
            ' >>\nendobj\n';
        hx.add(ah(pagesObj));
        bytePos += pagesObj.length();

        offsets.put(catNum, bytePos);
        String catObj = catNum + ' 0 obj\n<< /Type /Catalog /Pages ' + pagesNum + ' 0 R >>\nendobj\n';
        hx.add(ah(catObj));
        bytePos += catObj.length();

        // ---- classic cross-reference table + trailer ----
        Integer size = next; // objects 0 .. next-1
        Integer xrefStart = bytePos;
        String xref = 'xref\n0 ' + size + '\n0000000000 65535 f \n';
        for (Integer i = 1; i < size; i++) {
            Integer off = offsets.containsKey(i) ? offsets.get(i) : 0;
            xref += String.valueOf(off).leftPad(10, '0') + ' 00000 n \n';
        }
        xref += 'trailer\n<< /Size ' + size + ' /Root ' + catNum + ' 0 R >>\nstartxref\n' + xrefStart + '\n%%EOF\n';
        hx.add(ah(xref));

        String joined = String.join(hx, '');
        hx = null; // free the piece list before the final byte allocation
        return EncodingUtil.convertFromHex(joined);
    }

    /** Page count of a Portwood-generated PDF, without a full merge. */
    global static Integer pageCount(Blob pdf) {
        return parse(pdf).pageOrder.size();
    }

    // ------------------------------------------------------------------
    // parsing
    // ------------------------------------------------------------------

    /** Number of pages with no content stream — the blank fillers. Test hook. */
    @TestVisible
    private static Integer blankPageCount(Blob pdf) {
        Src s = parse(pdf);
        Integer n = 0;
        for (Integer p : s.pageOrder) {
            ObjRec o = s.objs.get(p);
            if (o != null && !o.dictPart.contains('/Contents')) {
                n++;
            }
        }
        return n;
    }

    private static Src parse(Blob pdfBlob) {
        String hex = EncodingUtil.convertToHex(pdfBlob).toLowerCase();
        String s = latin1FromHex(hex);

        if (!s.startsWith('%PDF-')) {
            throw new DocGenPdfMergeException('Not a PDF file.');
        }
        if (s.contains('/Encrypt')) {
            throw new DocGenPdfMergeException('Encrypted PDFs cannot be merged.');
        }
        if (s.contains('/ObjStm') || s.contains('/Type/XRef') || s.contains('/Type /XRef')) {
            throw new DocGenPdfMergeException(
                'This PDF uses compressed object/cross-reference streams and cannot be merged server-side.'
            );
        }

        Src src = new Src();
        Integer cursor = 0;
        while (true) {
            Integer ob = s.indexOf(' 0 obj', cursor);
            if (ob == -1) {
                break;
            }
            Integer ns = ob;
            while (ns > 0 && isDigit(s.charAt(ns - 1))) {
                ns--;
            }
            if (ns == ob) {
                cursor = ob + 6;
                continue;
            }
            Integer num = Integer.valueOf(s.substring(ns, ob));
            Integer bodyStart = ob + 6;

            Integer si = s.indexOf('stream', bodyStart);
            Integer eob = s.indexOf('endobj', bodyStart);
            if (eob == -1) {
                break;
            }

            ObjRec o = new ObjRec();
            o.num = num;
            if (si != -1 && si < eob) {
                String dict = s.substring(bodyStart, si);
                Integer len = parseLength(dict);
                Integer dStart = si + 6;
                if (dStart < s.length() && s.charAt(dStart) == 13) {
                    dStart++;
                }
                if (dStart < s.length() && s.charAt(dStart) == 10) {
                    dStart++;
                }
                Integer dEnd = (len != null) ? dStart + len : s.indexOf('endstream', dStart);
                Integer eo = s.indexOf('endobj', dEnd);
                if (eo == -1) {
                    break;
                }
                o.dictPart = dict;
                o.streamHex = hex.substring(si * 2, eo * 2);
                src.objs.put(num, o);
                cursor = eo + 6;
            } else {
                o.dictPart = s.substring(bodyStart, eob);
                o.streamHex = '';
                src.objs.put(num, o);
                cursor = eob + 6;
            }
        }

        // Embedded font programs — the only streams safe to dedupe (see Src).
        // FontDescriptor dicts reference them as /FontFile[23]? N 0 R.
        Matcher ffm = Pattern.compile('/FontFile[23]?\\s+(\\d+)\\s+0\\s+R').matcher(s);
        while (ffm.find()) {
            src.fontFileObjs.add(Integer.valueOf(ffm.group(1)));
        }

        // root /Pages -> flat page order
        Integer pagesRoot = null;
        Matcher rm = Pattern.compile('/Root\\s+(\\d+)\\s+0\\s+R').matcher(s);
        if (rm.find() && src.objs.containsKey(Integer.valueOf(rm.group(1)))) {
            Matcher pm = Pattern.compile('/Pages\\s+(\\d+)\\s+0\\s+R')
                .matcher(src.objs.get(Integer.valueOf(rm.group(1))).dictPart);
            if (pm.find()) {
                pagesRoot = Integer.valueOf(pm.group(1));
            }
        }
        if (pagesRoot == null) {
            for (ObjRec o : src.objs.values()) {
                if (o.dictPart.contains('/Type/Pages') || o.dictPart.contains('/Type /Pages')) {
                    pagesRoot = o.num;
                    break;
                }
            }
        }
        if (pagesRoot != null) {
            collectPages(src, pagesRoot, src.pageOrder, new Set<Integer>());
        }
        if (src.pageOrder.isEmpty()) {
            throw new DocGenPdfMergeException('No pages found in PDF.');
        }

        for (Integer i = 0; i < src.pageOrder.size(); i++) {
            ObjRec pg = src.objs.get(src.pageOrder.get(i));
            if (pg == null) {
                continue;
            }
            pg.isPage = true;
            if (i == src.pageOrder.size() - 1) {
                Matcher mb = Pattern.compile('/MediaBox\\s*\\[[^\\]]+\\]').matcher(pg.dictPart);
                if (mb.find()) {
                    src.lastMediaBox = mb.group();
                }
            }
        }
        return src;
    }

    private static void collectPages(Src src, Integer objNum, List<Integer> out, Set<Integer> seen) {
        if (seen.contains(objNum)) {
            return;
        }
        seen.add(objNum);
        ObjRec o = src.objs.get(objNum);
        if (o == null) {
            return;
        }
        Matcher km = Pattern.compile('/Kids\\s*\\[([^\\]]*)\\]').matcher(o.dictPart);
        if (km.find()) {
            Matcher rr = Pattern.compile('(\\d+)\\s+0\\s+R').matcher(km.group(1));
            while (rr.find()) {
                collectPages(src, Integer.valueOf(rr.group(1)), out, seen);
            }
        } else {
            out.add(objNum);
        }
    }

    private static Integer parseLength(String dict) {
        Matcher lm = Pattern.compile('/Length\\s+(\\d+)(?!\\s*\\d+\\s+R)').matcher(dict);
        return lm.find() ? Integer.valueOf(lm.group(1)) : null;
    }

    // ------------------------------------------------------------------
    // reference rewriting
    // ------------------------------------------------------------------

    private static String renumberRefs(String text, Map<Integer, Integer> remap) {
        Matcher m = Pattern.compile('(\\d+)\\s+0\\s+R').matcher(text);
        String out = '';
        Integer last = 0;
        while (m.find()) {
            out += text.substring(last, m.start());
            Integer oldNum = Integer.valueOf(m.group(1));
            out += remap.containsKey(oldNum) ? (remap.get(oldNum) + ' 0 R') : m.group();
            last = m.end();
        }
        out += text.substring(last);
        return out;
    }

    private static String setParent(String dict, Integer pagesNum) {
        Matcher m = Pattern.compile('/Parent\\s+\\d+\\s+0\\s+R').matcher(dict);
        if (m.find()) {
            return dict.substring(0, m.start()) + '/Parent ' + pagesNum + ' 0 R' + dict.substring(m.end());
        }
        Integer lt = dict.indexOf('<<');
        return lt == -1 ? dict : dict.substring(0, lt + 2) + ' /Parent ' + pagesNum + ' 0 R' + dict.substring(lt + 2);
    }

    // ------------------------------------------------------------------
    // byte / hex helpers
    // ------------------------------------------------------------------

    private static String ah(String ascii) {
        return EncodingUtil.convertToHex(Blob.valueOf(ascii)).toLowerCase();
    }

    private static String latin1FromHex(String hex) {
        List<String> chunks = new List<String>();
        List<Integer> chars = new List<Integer>();
        for (Integer i = 0; i < hex.length(); i += 2) {
            chars.add(nib(hex.charAt(i)) * 16 + nib(hex.charAt(i + 1)));
            if (chars.size() == 2000) {
                chunks.add(String.fromCharArray(chars));
                chars.clear();
            }
        }
        if (!chars.isEmpty()) {
            chunks.add(String.fromCharArray(chars));
        }
        return String.join(chunks, '');
    }

    private static Integer nib(Integer code) {
        return code <= 57 ? code - 48 : (code <= 70 ? code - 55 : code - 87);
    }

    private static Boolean isDigit(Integer c) {
        return c >= 48 && c <= 57;
    }

    private static String joinRefs(List<Integer> nums) {
        List<String> parts = new List<String>();
        for (Integer n : nums) {
            parts.add(n + ' 0 R');
        }
        return String.join(parts, ' ');
    }
}
