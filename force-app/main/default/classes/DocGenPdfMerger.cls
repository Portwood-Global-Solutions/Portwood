/**
 * Native PDF page merger. Supports classic and streamed cross-reference tables,
 * compressed objects, inherited page resources and nonzero object generations.
 * Binary page/image streams remain byte-for-byte intact. No external processing.
 */
global with sharing class DocGenPdfMerger {
    global class DocGenPdfMergeException extends Exception {
    }

    private class OutputObject {
        Integer objNum;
        DocGenPdfDocument.Value value;
        String streamHex;
        OutputObject(Integer objNum, DocGenPdfDocument.Value value, String streamHex) {
            this.objNum = objNum;
            this.value = value;
            this.streamHex = streamHex;
        }
    }

    private class Packet {
        Integer next = 3;
        Integer count = 0;
        List<OutputObject> objects = new List<OutputObject>();
        List<DocGenPdfDocument.Value> kids = new List<DocGenPdfDocument.Value>();
        List<DocGenPdfDocument.Value> fields = new List<DocGenPdfDocument.Value>();
        DocGenPdfDocument.Value resources = DocGenPdfDocument.dictValue();
        Map<String, Integer> fonts = new Map<String, Integer>();
        Boolean needAppearances = false;
        Map<String, Integer> outputRefs = new Map<String, Integer>{ '@1' => 1, '@2' => 2 };
    }

    global static Blob mergePdfs(List<Blob> pdfs, Boolean padOddDocuments) {
        if (pdfs == null || pdfs.isEmpty())
            throw new DocGenPdfMergeException('No PDFs supplied to merge.');
        if (pdfs.size() == 1 && padOddDocuments != true)
            return pdfs[0];
        Packet packet = new Packet();
        for (Integer i = 0; i < pdfs.size(); i++) {
            addPart(packet, pdfs[i], padOddDocuments == true, i + 1);
        }
        return finish(packet);
    }

    /** Exact versions, in caller order. Duplicate IDs intentionally repeat pages. */
    global static Blob mergePdfCvs(List<Id> partCvIds, Boolean padOddDocuments) {
        if (partCvIds == null || partCvIds.isEmpty())
            throw new DocGenPdfMergeException('No PDFs supplied to merge.');
        Packet packet = new Packet();
        // Bound query count for bulk packets, while releasing each chunk before
        // loading the next. Flow performs metadata/aggregate-size checks first.
        for (Integer start = 0; start < partCvIds.size(); start += 40) {
            List<Id> chunk = new List<Id>();
            for (Integer i = start; i < Math.min(start + 40, partCvIds.size()); i++)
                chunk.add(partCvIds[i]);
            Map<Id, ContentVersion> loaded = new Map<Id, ContentVersion>(
                [SELECT Id, VersionData FROM ContentVersion WHERE Id IN :chunk WITH USER_MODE]
            );
            for (Integer i = 0; i < chunk.size(); i++) {
                ContentVersion cv = loaded.get(chunk[i]);
                if (cv == null)
                    throw new DocGenPdfMergeException('A source ContentVersion is missing or inaccessible.');
                addPart(packet, cv.VersionData, padOddDocuments == true, start + i + 1);
            }
        }
        return finish(packet);
    }

    private static void addPart(Packet packet, Blob input, Boolean pad, Integer partNumber) {
        try {
            addPartCore(packet, input, pad, partNumber);
        } catch (DocGenPdfDocument.PdfException e) {
            throw new DocGenPdfMergeException(e.getMessage());
        }
    }

    private static void addPartCore(Packet packet, Blob input, Boolean pad, Integer partNumber) {
        DocGenPdfDocument doc = new DocGenPdfDocument(input);
        DocGenPdfDocument.Value form = doc.resolve(doc.catalog.entries.get('AcroForm'));
        if (form != null && form.kind != 'dict')
            throw new DocGenPdfMergeException('Invalid PDF form dictionary.');
        if (form != null && form.entries.containsKey('XFA')) {
            throw new DocGenPdfMergeException('XFA forms cannot be merged. Export a standard PDF copy first.');
        }
        if (doc.catalog.entries.containsKey('Perms')) {
            throw new DocGenPdfMergeException('Certified PDFs cannot be merged while preserving their certification.');
        }
        Set<String> fontPrograms = new Set<String>();
        for (DocGenPdfDocument.PdfObject obj : doc.objects.values()) {
            if (obj.value.kind != 'dict')
                continue;
            if (DocGenPdfDocument.name(obj.value.entries.get('FT')) == 'Sig' && obj.value.entries.containsKey('V')) {
                throw new DocGenPdfMergeException(
                    'Digitally signed PDFs cannot be merged while preserving their signatures.'
                );
            }
            for (String key : new List<String>{ 'FontFile', 'FontFile2', 'FontFile3' }) {
                DocGenPdfDocument.Value ref = obj.value.entries.get(key);
                if (ref != null && ref.kind == 'ref')
                    fontPrograms.add(ref.key);
            }
        }

        Map<String, Integer> remap = new Map<String, Integer>();
        Set<String> dropped = new Set<String>();
        List<String> keys = new List<String>(doc.objects.keySet());
        keys.sort();
        Map<String, Integer> identity = new Map<String, Integer>();
        for (String key : keys)
            identity.put(key, Integer.valueOf(key.split(' ')[0]));
        for (String key : keys) {
            DocGenPdfDocument.PdfObject obj = doc.objects.get(key);
            String type = obj.value.kind == 'dict' ? DocGenPdfDocument.name(obj.value.entries.get('Type')) : null;
            if (type == 'Catalog' || type == 'ObjStm' || type == 'XRef')
                continue;
            if (fontPrograms.contains(key) && obj.streamHex != null) {
                String fingerprint = EncodingUtil.convertToHex(
                    Crypto.generateDigest(
                        'SHA-256',
                        Blob.valueOf(DocGenPdfDocument.write(obj.value, identity) + '~' + obj.streamHex)
                    )
                );
                if (packet.fonts.containsKey(fingerprint)) {
                    remap.put(key, packet.fonts.get(fingerprint));
                    dropped.add(key);
                    continue;
                }
                packet.fonts.put(fingerprint, packet.next);
            }
            remap.put(key, packet.next);
            packet.outputRefs.put('@' + packet.next, packet.next++);
        }

        // Keep each original page tree below the packet root. This preserves all
        // inherited Resources, MediaBox, CropBox and Rotate values.
        Map<String, DocGenPdfDocument.Value> lastAttributes = new Map<String, DocGenPdfDocument.Value>();
        if (pad && Math.mod(doc.pageList.size(), 2) == 1) {
            for (String attribute : new List<String>{ 'MediaBox', 'CropBox', 'Rotate' }) {
                DocGenPdfDocument.Value inheritedValue = inherited(
                    doc,
                    doc.pageList[doc.pageList.size() - 1],
                    attribute
                );
                if (inheritedValue != null)
                    lastAttributes.put(attribute, inheritedValue);
            }
        }
        DocGenPdfDocument.Value pageRoot = doc.resolve(doc.pages);
        pageRoot.entries.put('Parent', outputRef(1));
        packet.kids.add(outputRef(remap.get(doc.pages.key)));
        packet.count += doc.pageList.size();
        if (form != null)
            mergeForm(packet, doc, form, partNumber);

        for (String key : keys) {
            if (!remap.containsKey(key) || dropped.contains(key))
                continue;
            DocGenPdfDocument.PdfObject obj = doc.objects.get(key);
            remapValues(obj.value, remap, 0);
            if (obj.streamHex != null)
                obj.value.entries.put('Length', DocGenPdfDocument.numberValue(obj.streamHex.length() / 2));
            packet.objects.add(new OutputObject(remap.get(key), obj.value, obj.streamHex));
        }
        if (pad && Math.mod(doc.pageList.size(), 2) == 1) {
            // Resolve and copy the inherited box before discarding the source.
            DocGenPdfDocument.Value blank = DocGenPdfDocument.dictValue();
            blank.entries.put('Type', DocGenPdfDocument.nameValue('Page'));
            blank.entries.put('Parent', outputRef(1));
            blank.entries.put('MediaBox', defaultBox());
            blank.entries.putAll(lastAttributes);
            blank.entries.put('Resources', DocGenPdfDocument.dictValue());
            Integer objNum = packet.next++;
            packet.outputRefs.put('@' + objNum, objNum);
            packet.objects.add(new OutputObject(objNum, blank, null));
            packet.kids.add(outputRef(objNum));
            packet.count++;
        }
    }

    private static DocGenPdfDocument.Value inherited(DocGenPdfDocument doc, DocGenPdfDocument.Value page, String key) {
        Set<String> seen = new Set<String>();
        while (page != null && page.kind == 'ref' && !seen.contains(page.key)) {
            seen.add(page.key);
            DocGenPdfDocument.Value value = doc.resolve(page);
            if (value.entries.containsKey(key))
                return doc.resolve(value.entries.get(key));
            page = value.entries.get('Parent');
        }
        return null;
    }

    private static void mergeForm(
        Packet packet,
        DocGenPdfDocument doc,
        DocGenPdfDocument.Value form,
        Integer partNumber
    ) {
        DocGenPdfDocument.Value sourceFields = doc.resolve(form.entries.get('Fields'));
        DocGenPdfDocument.Value needsAppearance = doc.resolve(form.entries.get('NeedAppearances'));
        if (needsAppearance != null && needsAppearance.text == 'true')
            packet.needAppearances = true;
        if (sourceFields == null)
            return;
        if (sourceFields.kind != 'array')
            throw new DocGenPdfMergeException('Invalid PDF form fields.');
        DocGenPdfDocument.Value order = doc.resolve(form.entries.get('CO'));
        if (order != null && order.kind == 'array' && !order.items.isEmpty()) {
            throw new DocGenPdfMergeException('PDF forms with calculations must be flattened before merging.');
        }
        Map<String, String> resourceNames = new Map<String, String>();
        DocGenPdfDocument.Value dr = doc.resolve(form.entries.get('DR'));
        if (dr != null) {
            if (dr.kind != 'dict')
                throw new DocGenPdfMergeException('Invalid PDF form resources.');
            for (String category : dr.entries.keySet()) {
                DocGenPdfDocument.Value resources = doc.resolve(dr.entries.get(category));
                if (resources.kind != 'dict')
                    throw new DocGenPdfMergeException('Unsupported PDF form resource category.');
                if (!packet.resources.entries.containsKey(category))
                    packet.resources.entries.put(category, DocGenPdfDocument.dictValue());
                for (String name : resources.entries.keySet()) {
                    String renamed = 'D' + partNumber + '_' + name;
                    resourceNames.put(name, renamed);
                    packet.resources.entries.get(category).entries.put(renamed, resources.entries.get(name));
                }
            }
        }
        // Namespacing prevents unrelated forms' identically named fields being
        // treated as one field. Preserve values, widget appearances and parents.
        Integer groupNumber = packet.next++;
        packet.outputRefs.put('@' + groupNumber, groupNumber);
        DocGenPdfDocument.Value fieldGroup = DocGenPdfDocument.dictValue();
        fieldGroup.entries.put('T', new DocGenPdfDocument.Value('string', '(Document_' + partNumber + ')'));
        fieldGroup.entries.put('Kids', sourceFields);
        for (String key : new List<String>{ 'DA', 'Q' }) {
            if (form.entries.containsKey(key))
                fieldGroup.entries.put(key, doc.resolve(form.entries.get(key)));
        }
        for (DocGenPdfDocument.Value field : sourceFields.items) {
            DocGenPdfDocument.Value resolved = doc.resolve(field);
            if (resolved == null || resolved.kind != 'dict')
                throw new DocGenPdfMergeException('Invalid PDF form field.');
            resolved.entries.put('Parent', outputRef(groupNumber));
        }
        for (DocGenPdfDocument.PdfObject obj : doc.objects.values()) {
            if (obj.value.kind != 'dict')
                continue;
            if (obj.value.entries.containsKey('DA')) {
                obj.value.entries.put(
                    'DA',
                    DocGenPdfDocument.renameAppearance(doc.resolve(obj.value.entries.get('DA')), resourceNames)
                );
            }
            // Field scripts refer to source field names. Do not silently change
            // their meaning by grouping names under a document prefix.
            if (obj.value.entries.containsKey('AA')) {
                throw new DocGenPdfMergeException('PDF forms with field scripts must be flattened before merging.');
            }
        }
        if (fieldGroup.entries.containsKey('DA'))
            fieldGroup.entries.put(
                'DA',
                DocGenPdfDocument.renameAppearance(fieldGroup.entries.get('DA'), resourceNames)
            );
        packet.fields.add(outputRef(groupNumber));
        // References in this fieldGroup share source Value instances and are remapped
        // when the source objects are imported immediately after this method.
        packet.objects.add(new OutputObject(groupNumber, fieldGroup, null));
    }

    private static void remapValues(DocGenPdfDocument.Value v, Map<String, Integer> remap, Integer depth) {
        if (depth > 128)
            throw new DocGenPdfMergeException('PDF object nesting is too deep.');
        if (v.kind == 'ref') {
            if (v.key.startsWith('@'))
                return;
            if (!remap.containsKey(v.key))
                throw new DocGenPdfMergeException('Unsupported PDF reference ' + v.key + '.');
            v.key = '@' + remap.get(v.key);
        } else if (v.kind == 'dict') {
            for (DocGenPdfDocument.Value child : v.entries.values())
                remapValues(child, remap, depth + 1);
        } else if (v.kind == 'array') {
            for (DocGenPdfDocument.Value child : v.items)
                remapValues(child, remap, depth + 1);
        }
    }

    private static Blob finish(Packet packet) {
        DocGenPdfDocument.Value pages = DocGenPdfDocument.dictValue();
        pages.entries.put('Type', DocGenPdfDocument.nameValue('Pages'));
        pages.entries.put('Kids', DocGenPdfDocument.arrayValue(packet.kids));
        pages.entries.put('Count', DocGenPdfDocument.numberValue(packet.count));
        DocGenPdfDocument.Value catalog = DocGenPdfDocument.dictValue();
        catalog.entries.put('Type', DocGenPdfDocument.nameValue('Catalog'));
        catalog.entries.put('Pages', outputRef(1));
        if (!packet.fields.isEmpty()) {
            DocGenPdfDocument.Value form = DocGenPdfDocument.dictValue();
            form.entries.put('Fields', DocGenPdfDocument.arrayValue(packet.fields));
            form.entries.put('DR', packet.resources);
            form.entries.put(
                'NeedAppearances',
                new DocGenPdfDocument.Value('bool', packet.needAppearances ? 'true' : 'false')
            );
            catalog.entries.put('AcroForm', form);
        }
        packet.objects.add(new OutputObject(1, pages, null));
        packet.objects.add(new OutputObject(2, catalog, null));
        List<String> hex = new List<String>{ '255044462d312e370a25e2e3cfd30a' };
        Integer offset = hex[0].length() / 2;
        Map<Integer, Integer> offsets = new Map<Integer, Integer>();
        for (Integer i = 0; i < packet.objects.size(); i++) {
            OutputObject obj = packet.objects[i];
            offsets.put(obj.objNum, offset);
            String body = obj.objNum + ' 0 obj\n' + DocGenPdfDocument.write(obj.value, packet.outputRefs);
            if (obj.streamHex != null)
                body += '\nstream\n';
            String prefix = DocGenPdfDocument.toHex(body);
            String suffix = obj.streamHex != null ? '\nendstream\nendobj\n' : '\nendobj\n';
            hex.add(prefix);
            offset += prefix.length() / 2;
            if (obj.streamHex != null) {
                hex.add(obj.streamHex);
                offset += obj.streamHex.length() / 2;
            }
            hex.add(DocGenPdfDocument.toHex(suffix));
            offset += suffix.length();
            packet.objects[i] = null;
        }
        String xref = 'xref\n0 ' + packet.next + '\n0000000000 65535 f \n';
        for (Integer i = 1; i < packet.next; i++) {
            xref += offsets.containsKey(i)
                ? String.valueOf(offsets.get(i)).leftPad(10, '0') + ' 00000 n \n'
                : '0000000000 00000 f \n';
        }
        xref += 'trailer\n<< /Size ' + packet.next + ' /Root 2 0 R >>\nstartxref\n' + offset + '\n%%EOF\n';
        hex.add(DocGenPdfDocument.toHex(xref));
        String joined = String.join(hex, '');
        hex = null;
        return EncodingUtil.convertFromHex(joined);
    }

    private static DocGenPdfDocument.Value outputRef(Integer n) {
        return DocGenPdfDocument.reference('@' + n);
    }
    private static DocGenPdfDocument.Value defaultBox() {
        return DocGenPdfDocument.arrayValue(
            new List<DocGenPdfDocument.Value>{
                DocGenPdfDocument.numberValue(0),
                DocGenPdfDocument.numberValue(0),
                DocGenPdfDocument.numberValue(612),
                DocGenPdfDocument.numberValue(792)
            }
        );
    }

    global static Integer pageCount(Blob pdf) {
        return new DocGenPdfDocument(pdf).pageList.size();
    }

    @TestVisible
    private static Integer blankPageCount(Blob pdf) {
        DocGenPdfDocument doc = new DocGenPdfDocument(pdf);
        Integer count = 0;
        for (DocGenPdfDocument.Value page : doc.pageList) {
            if (!doc.resolve(page).entries.containsKey('Contents'))
                count++;
        }
        return count;
    }
}
