/**
 * PDF object reader used by the native merger. Reads the active cross-reference
 * chain, including PDF 1.5 object streams, rather than scanning binary content
 * for object-looking text. Page/image streams are copied without decoding.
 */
public class DocGenPdfDocument {
    public class PdfException extends Exception {
    }

    public class Value {
        public String kind;
        public String text;
        public Map<String, Value> entries;
        public List<Value> items;
        public String key;

        public Value(String kind, String text) {
            this.kind = kind;
            this.text = text;
        }
    }

    public class PdfObject {
        public Value value;
        public String streamHex;
    }

    private class Location {
        Integer type;
        Integer offset;
        Integer generation;
        Integer index;
    }

    public Map<String, PdfObject> objects = new Map<String, PdfObject>();
    public Value catalog;
    public Value pages;
    public List<Value> pageList = new List<Value>();
    private Map<Integer, Location> locations = new Map<Integer, Location>();
    private Set<Integer> xrefs = new Set<Integer>();
    private Set<Integer> readingXrefs = new Set<Integer>();
    private Set<String> loading = new Set<String>();
    private Set<Integer> expanded = new Set<Integer>();
    private String source;
    private String sourceHex;
    private Value root;
    private Integer decodedBytes = 0;
    private static final Integer MAX_OBJECTS = 10000;
    private static final Integer MAX_DECODED_BYTES = 524288;
    private static final String DIGITS = '0123456789abcdef';

    public DocGenPdfDocument(Blob input) {
        if (input == null || input.size() == 0)
            fail('Empty PDF.');
        sourceHex = EncodingUtil.convertToHex(input).toLowerCase();
        source = fromHex(sourceHex);
        if (!source.startsWith('%PDF-'))
            fail('Not a PDF file.');
        Integer tail = source.lastIndexOf('startxref');
        if (tail < 0)
            fail('PDF startxref is missing.');
        Cursor c = new Cursor(source, tail + 9);
        readXref(c.integerToken(), 0);
        if (root == null)
            fail('PDF root catalog is missing.');
        catalog = resolve(root);
        requireDict(catalog);
        pages = catalog.entries.get('Pages');
        walkPages(pages, new Set<String>(), 0);
        if (pageList.isEmpty())
            fail('No pages found in PDF.');
        // Resolve only objects reachable from pages and form fields. Old revisions,
        // unused objects, source catalogs and xref/object-stream containers stay out.
        collect(pages, new Set<String>(), 0);
        Value form = catalog.entries.get('AcroForm');
        if (form != null)
            collect(form, new Set<String>(), 0);
        source = null;
        sourceHex = null;
    }

    public Value resolve(Value v) {
        Set<String> seen = new Set<String>();
        while (v != null && v.kind == 'ref') {
            if (seen.contains(v.key))
                fail('Cyclic PDF reference.');
            seen.add(v.key);
            v = load(v.key).value;
        }
        return v;
    }

    public PdfObject load(String key) {
        if (objects.containsKey(key))
            return objects.get(key);
        if (loading.contains(key))
            fail('Cyclic PDF stream length.');
        loading.add(key);
        List<String> pair = key.split(' ');
        Integer objNum = Integer.valueOf(pair[0]);
        Integer generation = Integer.valueOf(pair[1]);
        Location loc = locations.get(objNum);
        if (
            loc == null ||
            loc.type == 0 ||
            (loc.type == 1 &&
            loc.generation != generation) ||
            (loc.type == 2 &&
            generation != 0)
        )
            fail('Missing PDF object ' + key + '.');
        if (loc.type == 2) {
            expandObjectStream(loc.offset);
            if (!objects.containsKey(key))
                fail('Missing compressed PDF object ' + key + '.');
        } else {
            Cursor c = new Cursor(source, loc.offset);
            if (c.integerToken() != objNum || c.integerToken() != generation || c.word() != 'obj') {
                fail('Invalid PDF object offset for ' + key + '.');
            }
            objects.put(key, readObject(c));
        }
        loading.remove(key);
        return objects.get(key);
    }

    private PdfObject readObject(Cursor c) {
        PdfObject result = new PdfObject();
        result.value = c.value(0);
        c.skip();
        if (c.at('stream')) {
            requireDict(result.value);
            c.pos += 6;
            if (c.pos < source.length() && source.charAt(c.pos) == 13)
                c.pos++;
            if (c.pos < source.length() && source.charAt(c.pos) == 10)
                c.pos++;
            else if (c.pos == 0 || source.charAt(c.pos - 1) != 13)
                fail('Invalid PDF stream separator.');
            Integer length = intValue(resolve(result.value.entries.get('Length')));
            if (length < 0 || length > source.length() - c.pos)
                fail('Invalid PDF stream length.');
            result.streamHex = sourceHex.substring(c.pos * 2, (c.pos + length) * 2);
            c.pos += length;
            if (c.word() != 'endstream')
                fail('Invalid PDF stream boundary.');
        }
        if (c.word() != 'endobj')
            fail('Invalid PDF object boundary.');
        return result;
    }

    private void readXref(Integer offset, Integer depth) {
        readXref(offset, depth, true);
    }

    private void readXref(Integer offset, Integer depth, Boolean followPrevious) {
        if (depth > 64 || readingXrefs.contains(offset))
            fail('Invalid PDF cross-reference chain.');
        if (xrefs.contains(offset))
            return;
        if (offset < 0 || offset >= source.length())
            fail('Invalid PDF cross-reference offset.');
        readingXrefs.add(offset);
        Set<Integer> previouslyKnown = new Set<Integer>(locations.keySet());
        Cursor c = new Cursor(source, offset);
        Value trailer;
        if (c.at('xref')) {
            c.pos += 4;
            c.skip();
            while (!c.at('trailer')) {
                Integer first = c.integerToken();
                Integer count = c.integerToken();
                if (first < 0 || count < 0 || count > MAX_OBJECTS)
                    fail('PDF has too many objects.');
                for (Integer i = 0; i < count; i++) {
                    Location loc = new Location();
                    loc.offset = c.integerToken();
                    loc.generation = c.integerToken();
                    String state = c.word();
                    if (state != 'n' && state != 'f')
                        fail('Invalid PDF cross-reference entry.');
                    loc.type = state == 'n' ? 1 : 0;
                    if (!locations.containsKey(first + i))
                        locations.put(first + i, loc);
                }
                c.skip();
            }
            c.pos += 7;
            trailer = c.value(0);
        } else {
            c.integerToken();
            c.integerToken();
            if (c.word() != 'obj')
                fail('Invalid PDF cross-reference stream.');
            PdfObject xref = readObject(c);
            trailer = xref.value;
            requireDict(trailer);
            if (name(trailer.entries.get('Type')) != 'XRef')
                fail('Invalid PDF cross-reference stream type.');
            String bytes = decodeStream(xref);
            Value widths = resolve(trailer.entries.get('W'));
            requireArray(widths);
            if (widths.items.size() != 3)
                fail('Invalid PDF cross-reference widths.');
            Integer w0 = intValue(widths.items[0]);
            Integer w1 = intValue(widths.items[1]);
            Integer w2 = intValue(widths.items[2]);
            if (w0 < 0 || w1 < 0 || w2 < 0 || w0 > 4 || w1 > 4 || w2 > 4 || w0 + w1 + w2 == 0) {
                fail('Unsupported PDF cross-reference widths.');
            }
            Value ranges = resolve(trailer.entries.get('Index'));
            if (ranges == null)
                ranges = arrayValue(new List<Value>{ numberValue(0), trailer.entries.get('Size') });
            requireArray(ranges);
            if (Math.mod(ranges.items.size(), 2) != 0)
                fail('Invalid PDF cross-reference index.');
            Integer pos = 0;
            for (Integer r = 0; r < ranges.items.size(); r += 2) {
                Integer first = intValue(ranges.items[r]);
                Integer count = intValue(ranges.items[r + 1]);
                if (first < 0 || count < 0 || count > MAX_OBJECTS)
                    fail('PDF has too many objects.');
                for (Integer i = 0; i < count; i++) {
                    if (pos + w0 + w1 + w2 > bytes.length())
                        fail('Truncated PDF cross-reference stream.');
                    Location loc = new Location();
                    loc.type = w0 == 0 ? 1 : unsigned(bytes, pos, w0);
                    pos += w0;
                    loc.offset = unsigned(bytes, pos, w1);
                    pos += w1;
                    loc.generation = unsigned(bytes, pos, w2);
                    loc.index = loc.generation;
                    pos += w2;
                    // Hybrid xref streams override their same-revision classic table.
                    if (!locations.containsKey(first + i))
                        locations.put(first + i, loc);
                }
            }
        }
        requireDict(trailer);
        if (trailer.entries.containsKey('Encrypt'))
            fail('Encrypted PDFs cannot be merged. Upload an unencrypted copy.');
        if (root == null)
            root = trailer.entries.get('Root');
        if (locations.size() > MAX_OBJECTS)
            fail('PDF has too many objects.');
        Value hybrid = trailer.entries.get('XRefStm');
        if (hybrid != null) {
            // A hybrid table marks compressed objects free. Let its stream replace
            // those entries, while retaining entries from genuinely newer revisions.
            Map<Integer, Location> freeInThisRevision = new Map<Integer, Location>();
            for (Integer n : locations.keySet()) {
                if (!previouslyKnown.contains(n) && locations.get(n).type == 0)
                    freeInThisRevision.put(n, locations.get(n));
            }
            for (Integer n : freeInThisRevision.keySet())
                locations.remove(n);
            readXref(intValue(hybrid), depth + 1, false);
            for (Integer n : freeInThisRevision.keySet())
                if (!locations.containsKey(n))
                    locations.put(n, freeInThisRevision.get(n));
        }
        Value prev = trailer.entries.get('Prev');
        if (prev != null && followPrevious)
            readXref(intValue(prev), depth + 1);
        readingXrefs.remove(offset);
        xrefs.add(offset);
    }

    private void expandObjectStream(Integer objNum) {
        if (expanded.contains(objNum))
            fail('Invalid compressed object index.');
        expanded.add(objNum);
        Location container = locations.get(objNum);
        if (container == null || container.type != 1)
            fail('Missing PDF object stream.');
        PdfObject stream = load(objNum + ' ' + container.generation);
        if (name(stream.value.entries.get('Type')) != 'ObjStm')
            fail('Invalid PDF object stream type.');
        Integer count = intValue(resolve(stream.value.entries.get('N')));
        Integer first = intValue(resolve(stream.value.entries.get('First')));
        if (count < 0 || count > MAX_OBJECTS)
            fail('PDF has too many compressed objects.');
        String decoded = decodeStream(stream);
        if (first < 0 || first > decoded.length())
            fail('Invalid PDF object stream header.');
        Cursor header = new Cursor(decoded, 0);
        List<Integer> numbers = new List<Integer>();
        List<Integer> offsets = new List<Integer>();
        for (Integer i = 0; i < count; i++) {
            numbers.add(header.integerToken());
            offsets.add(header.integerToken());
        }
        if (header.pos > first)
            fail('Invalid PDF object stream header length.');
        for (Integer i = 0; i < count; i++) {
            Integer start = first + offsets[i];
            Integer endPos = i + 1 < count ? first + offsets[i + 1] : decoded.length();
            if (start < first || endPos < start || endPos > decoded.length())
                fail('Invalid PDF compressed object offset.');
            Location active = locations.get(numbers[i]);
            if (active == null || active.type != 2 || active.offset != objNum || active.index != i)
                continue;
            Cursor c = new Cursor(decoded.substring(start, endPos), 0);
            PdfObject obj = new PdfObject();
            obj.value = c.value(0);
            c.skip();
            if (c.pos != c.data.length())
                fail('Invalid compressed PDF object boundary.');
            objects.put(numbers[i] + ' 0', obj);
        }
    }

    private void walkPages(Value ref, Set<String> seen, Integer depth) {
        if (ref == null || ref.kind != 'ref' || seen.contains(ref.key) || depth > 64)
            fail('Invalid PDF page tree.');
        seen.add(ref.key);
        Value v = resolve(ref);
        requireDict(v);
        String type = name(v.entries.get('Type'));
        if (type == 'Page') {
            pageList.add(ref);
        } else if (type == 'Pages') {
            Value kids = resolve(v.entries.get('Kids'));
            requireArray(kids);
            for (Value child : kids.items)
                walkPages(child, seen, depth + 1);
            v.entries.put('Count', numberValue(countLeaves(ref, new Set<String>(), 0)));
        } else
            fail('Invalid PDF page node.');
    }

    private Integer countLeaves(Value ref, Set<String> seen, Integer depth) {
        if (seen.contains(ref.key) || depth > 64)
            fail('Invalid PDF page tree.');
        seen.add(ref.key);
        Value v = resolve(ref);
        if (name(v.entries.get('Type')) == 'Page')
            return 1;
        Integer total = 0;
        Value kids = resolve(v.entries.get('Kids'));
        requireArray(kids);
        for (Value child : kids.items)
            total += countLeaves(child, seen, depth + 1);
        return total;
    }

    private void collect(Value v, Set<String> seen, Integer depth) {
        if (v == null)
            return;
        if (depth > 128)
            fail('PDF object nesting is too deep.');
        if (v.kind == 'ref') {
            if (seen.contains(v.key))
                return;
            seen.add(v.key);
            collect(load(v.key).value, seen, depth + 1);
        } else if (v.kind == 'dict') {
            for (Value child : v.entries.values())
                collect(child, seen, depth + 1);
        } else if (v.kind == 'array') {
            for (Value child : v.items)
                collect(child, seen, depth + 1);
        }
    }

    private String decodeStream(PdfObject obj) {
        if (obj.streamHex == null)
            fail('Missing PDF stream.');
        Value filter = resolve(obj.value.entries.get('Filter'));
        Value params = resolve(obj.value.entries.get('DecodeParms'));
        List<Value> filters = filter == null
            ? new List<Value>()
            : filter.kind == 'array' ? filter.items : new List<Value>{ filter };
        String hex = obj.streamHex;
        for (Integer i = 0; i < filters.size(); i++) {
            String f = name(resolve(filters[i]));
            if (f != 'FlateDecode' && f != 'Fl')
                fail('Unsupported PDF object-stream filter: ' + f + '.');
            hex = inflate(hex);
            Value p = params != null && params.kind == 'array' ? resolve(params.items[i]) : params;
            if (p != null && p.kind != 'null')
                hex = undoPredictor(hex, p);
        }
        decodedBytes += hex.length() / 2;
        if (decodedBytes > MAX_DECODED_BYTES)
            fail('Decoded PDF object streams exceed the native merge limit.');
        return fromHex(hex);
    }

    private static String inflate(String zlibHex) {
        if (zlibHex.length() < 12)
            fail('Truncated PDF deflate stream.');
        Integer cmf = byteAt(zlibHex, 0);
        Integer flg = byteAt(zlibHex, 1);
        if (Math.mod(cmf, 16) != 8 || cmf / 16 > 7 || Math.mod(cmf * 256 + flg, 31) != 0 || (flg & 32) != 0)
            fail('Unsupported PDF deflate header.');
        String raw = zlibHex.substring(4, zlibHex.length() - 8);
        Integer compressed = raw.length() / 2;
        // ZIP method 8 contains the same raw deflate bytes as zlib, with a
        // different wrapper. ZipReader accepts unknown CRC/expanded size (0).
        // Validate zlib's Adler-32 ourselves after extraction. No external code.
        String local = '504b03041400000008000000000000000000' + le(compressed, 4) + '000000000100000078' + raw;
        String central =
            '504b010214001400000008000000000000000000' +
            le(compressed, 4) +
            '0000000001000000000000000000000000000000000078';
        String zipEnd = '504b05060000000001000100' + le(central.length() / 2, 4) + le(local.length() / 2, 4) + '0000';
        Blob output;
        try {
            Compression.ZipReader reader = new Compression.ZipReader(
                EncodingUtil.convertFromHex(local + central + zipEnd)
            );
            output = reader.extract('x');
        } catch (Exception e) {
            fail('Invalid PDF deflate stream.');
        }
        if (output.size() > MAX_DECODED_BYTES)
            fail('Decoded PDF object stream exceeds the native merge limit.');
        String hex = EncodingUtil.convertToHex(output).toLowerCase();
        Integer a = 1;
        Integer b = 0;
        for (Integer i = 0; i < output.size(); i++) {
            a = Math.mod(a + byteAt(hex, i), 65521);
            b = Math.mod(b + a, 65521);
        }
        String checksum =
            le(b, 2).substring(2, 4) +
            le(b, 2).substring(0, 2) +
            le(a, 2).substring(2, 4) +
            le(a, 2).substring(0, 2);
        if (checksum != zlibHex.right(8))
            fail('Invalid PDF deflate checksum.');
        return hex;
    }

    private static String undoPredictor(String hex, Value params) {
        requireDict(params);
        Integer predictor = params.entries.containsKey('Predictor') ? intValue(params.entries.get('Predictor')) : 1;
        if (predictor == 1)
            return hex;
        Integer columns = params.entries.containsKey('Columns') ? intValue(params.entries.get('Columns')) : 1;
        Integer colors = params.entries.containsKey('Colors') ? intValue(params.entries.get('Colors')) : 1;
        Integer bits = params.entries.containsKey('BitsPerComponent')
            ? intValue(params.entries.get('BitsPerComponent'))
            : 8;
        if (predictor < 10 || predictor > 15 || columns < 1 || colors < 1 || bits != 8 || columns * colors > 10000) {
            fail('Unsupported PDF object-stream predictor.');
        }
        Integer width = columns * colors;
        List<Integer> prev = new List<Integer>();
        for (Integer i = 0; i < width; i++)
            prev.add(0);
        List<String> rows = new List<String>();
        Integer pos = 0;
        while (pos < hex.length() / 2) {
            Integer mode = byteAt(hex, pos++);
            if (mode > 4 || pos + width > hex.length() / 2)
                fail('Invalid PDF predictor row.');
            List<Integer> row = new List<Integer>();
            String rowHex = '';
            for (Integer i = 0; i < width; i++) {
                Integer left = i < colors ? 0 : row[i - colors];
                Integer up = prev[i];
                Integer upperLeft = i < colors ? 0 : prev[i - colors];
                Integer add = mode == 0
                    ? 0
                    : mode == 1 ? left : mode == 2 ? up : mode == 3 ? (left + up) / 2 : paeth(left, up, upperLeft);
                Integer val = Math.mod(byteAt(hex, pos++) + add, 256);
                row.add(val);
                rowHex += le(val, 1);
            }
            rows.add(rowHex);
            prev = row;
        }
        return String.join(rows, '');
    }

    private static Integer paeth(Integer a, Integer b, Integer c) {
        Integer p = a + b - c;
        Integer pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }

    public static String write(Value v, Map<String, Integer> remap) {
        if (v.kind == 'ref') {
            if (!remap.containsKey(v.key))
                fail('Unresolved PDF reference ' + v.key + '.');
            return remap.get(v.key) + ' 0 R';
        }
        if (v.kind == 'dict') {
            List<String> out = new List<String>{ '<<' };
            List<String> keys = new List<String>(v.entries.keySet());
            keys.sort();
            for (String key : keys)
                out.add('/' + encodeName(key) + ' ' + write(v.entries.get(key), remap));
            out.add('>>');
            return String.join(out, ' ');
        }
        if (v.kind == 'array') {
            List<String> out = new List<String>();
            for (Value item : v.items)
                out.add(write(item, remap));
            return '[' + String.join(out, ' ') + ']';
        }
        return v.text;
    }

    public static Value dictValue() {
        Value v = new Value('dict', null);
        v.entries = new Map<String, Value>();
        return v;
    }

    public static Value arrayValue(List<Value> items) {
        Value v = new Value('array', null);
        v.items = items;
        return v;
    }

    public static Value numberValue(Integer n) {
        return new Value('numeric', String.valueOf(n));
    }
    public static Value nameValue(String n) {
        return new Value('name', '/' + encodeName(n));
    }
    public static Value reference(String key) {
        Value v = new Value('ref', null);
        v.key = key;
        return v;
    }
    public static String name(Value v) {
        return v != null && v.kind == 'name' ? decodeName(v.text.substring(1)) : null;
    }
    public static Integer intValue(Value v) {
        if (v == null || v.kind != 'numeric' || !Pattern.matches('[+-]?[0-9]+', v.text))
            fail('Invalid PDF integer.');
        return Integer.valueOf(v.text);
    }

    public static Value renameAppearance(Value v, Map<String, String> names) {
        if (v == null || v.kind != 'string')
            fail('Invalid PDF form default appearance.');
        String s;
        if (v.text.startsWith('<')) {
            String hex = v.text.substring(1, v.text.length() - 1).replaceAll('\\s', '').toLowerCase();
            if (Math.mod(hex.length(), 2) == 1)
                hex += '0';
            s = fromHex(hex);
        } else {
            s = '';
            for (Integer i = 1; i < v.text.length() - 1; i++) {
                Integer c = v.text.charAt(i);
                if (c != 92) {
                    s += v.text.substring(i, i + 1);
                    continue;
                }
                i++;
                c = v.text.charAt(i);
                if (c >= 48 && c <= 55) {
                    Integer n = c - 48;
                    Integer digits = 1;
                    while (
                        digits < 3 &&
                        i + 1 <
                        v.text.length() - 1 &&
                        v.text.charAt(i + 1) >= 48 &&
                        v.text.charAt(i + 1) <= 55
                    ) {
                        n = n * 8 + v.text.charAt(++i) - 48;
                        digits++;
                    }
                    s += String.fromCharArray(new List<Integer>{ Math.mod(n, 256) });
                } else if (c == 10 || c == 13) {
                    if (c == 13 && i + 1 < v.text.length() - 1 && v.text.charAt(i + 1) == 10)
                        i++;
                } else {
                    Map<Integer, Integer> escapes = new Map<Integer, Integer>{
                        110 => 10,
                        114 => 13,
                        116 => 9,
                        98 => 8,
                        102 => 12
                    };
                    s += String.fromCharArray(new List<Integer>{ escapes.containsKey(c) ? escapes.get(c) : c });
                }
            }
        }
        String out = '';
        Integer pos = 0;
        while (pos < s.length()) {
            if (s.charAt(pos) == 47) {
                Cursor c = new Cursor(s, pos);
                Value token = c.value(0);
                String old = name(token);
                out += names.containsKey(old) ? '/' + encodeName(names.get(old)) : token.text;
                pos = c.pos;
            } else {
                out += s.substring(pos, pos + 1);
                pos++;
            }
        }
        return new Value('string', '<' + toHex(out) + '>');
    }

    public static String toHex(String s) {
        List<String> parts = new List<String>();
        String chunk = '';
        for (Integer i = 0; i < s.length(); i++) {
            Integer n = s.charAt(i);
            if (n > 255)
                fail('Invalid PDF byte.');
            chunk += DIGITS.substring(n / 16, n / 16 + 1) + DIGITS.substring(Math.mod(n, 16), Math.mod(n, 16) + 1);
            if (chunk.length() >= 2000) {
                parts.add(chunk);
                chunk = '';
            }
        }
        parts.add(chunk);
        return String.join(parts, '');
    }

    public static String fromHex(String hex) {
        List<String> chunks = new List<String>();
        List<Integer> chars = new List<Integer>();
        for (Integer i = 0; i < hex.length() / 2; i++) {
            chars.add(byteAt(hex, i));
            if (chars.size() == 2000) {
                chunks.add(String.fromCharArray(chars));
                chars.clear();
            }
        }
        chunks.add(String.fromCharArray(chars));
        return String.join(chunks, '');
    }

    private static Integer byteAt(String hex, Integer i) {
        return DIGITS.indexOf(hex.substring(i * 2, i * 2 + 1)) * 16 +
            DIGITS.indexOf(hex.substring(i * 2 + 1, i * 2 + 2));
    }
    private static String le(Integer n, Integer size) {
        String out = '';
        for (Integer i = 0; i < size; i++) {
            Integer val = Math.mod(n, 256);
            out +=
                DIGITS.substring(val / 16, val / 16 + 1) + DIGITS.substring(Math.mod(val, 16), Math.mod(val, 16) + 1);
            n = n / 256;
        }
        return out;
    }
    private static Integer unsigned(String bytes, Integer offset, Integer width) {
        Long n = 0;
        for (Integer i = 0; i < width; i++)
            n = n * 256 + bytes.charAt(offset + i);
        if (n > 2147483647L)
            fail('PDF offset is too large.');
        return Integer.valueOf(n);
    }
    private static void requireDict(Value v) {
        if (v == null || v.kind != 'dict')
            fail('Expected PDF dictionary.');
    }
    private static void requireArray(Value v) {
        if (v == null || v.kind != 'array')
            fail('Expected PDF array.');
    }
    private static Boolean white(Integer c) {
        return c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;
    }
    private static Boolean delimiter(Integer c) {
        return white(c) || '()<>[]{}/%'.contains(String.fromCharArray(new List<Integer>{ c }));
    }
    private static String decodeName(String s) {
        String out = '';
        for (Integer i = 0; i < s.length(); i++) {
            if (s.charAt(i) == 35 && i + 2 < s.length()) {
                String hex = s.substring(i + 1, i + 3).toLowerCase();
                if (Pattern.matches('[0-9a-f]{2}', hex)) {
                    out += fromHex(hex);
                    i += 2;
                    continue;
                }
            }
            out += s.substring(i, i + 1);
        }
        return out;
    }
    private static String encodeName(String s) {
        String out = '';
        for (Integer i = 0; i < s.length(); i++) {
            Integer c = s.charAt(i);
            out += c < 33 ||
                c > 126 ||
                delimiter(c) ||
                c == 35
                ? '#' + toHex(s.substring(i, i + 1))
                : s.substring(i, i + 1);
        }
        return out;
    }
    private static void fail(String message) {
        throw new PdfException(message);
    }

    private class Cursor {
        String data;
        Integer pos;
        Cursor(String data, Integer pos) {
            this.data = data;
            this.pos = pos;
        }
        void skip() {
            while (pos < data.length()) {
                Integer c = data.charAt(pos);
                if (white(c))
                    pos++;
                else if (c == 37) {
                    while (pos < data.length() && data.charAt(pos) != 10 && data.charAt(pos) != 13)
                        pos++;
                } else
                    break;
            }
        }
        Boolean at(String token) {
            skip();
            Integer endPos = pos + token.length();
            return endPos <= data.length() &&
                data.substring(pos, endPos) == token &&
                (endPos == data.length() || delimiter(data.charAt(endPos)));
        }
        String word() {
            skip();
            Integer start = pos;
            while (pos < data.length() && !delimiter(data.charAt(pos)))
                pos++;
            if (start == pos)
                fail('Unexpected PDF token.');
            return data.substring(start, pos);
        }
        Integer integerToken() {
            String s = word();
            if (!Pattern.matches('[0-9]+', s))
                fail('Expected PDF integer token.');
            return Integer.valueOf(s);
        }
        Value value(Integer depth) {
            if (depth > 64)
                fail('PDF value nesting is too deep.');
            skip();
            if (pos >= data.length())
                fail('Unexpected end of PDF value.');
            Integer start = pos;
            Integer c = data.charAt(pos++);
            if (c == 60 && pos < data.length() && data.charAt(pos) == 60) {
                pos++;
                Value v = dictValue();
                while (true) {
                    skip();
                    if (pos + 1 < data.length() && data.substring(pos, pos + 2) == '>>') {
                        pos += 2;
                        return v;
                    }
                    Value key = value(depth + 1);
                    if (key.kind != 'name')
                        fail('Invalid PDF dictionary key.');
                    v.entries.put(name(key), value(depth + 1));
                }
            }
            if (c == 91) {
                Value v = arrayValue(new List<Value>());
                while (true) {
                    skip();
                    if (pos >= data.length())
                        fail('Unterminated PDF array.');
                    if (data.charAt(pos) == 93) {
                        pos++;
                        return v;
                    }
                    v.items.add(value(depth + 1));
                }
            }
            if (c == 40) {
                Integer nesting = 1;
                while (pos < data.length() && nesting > 0) {
                    Integer next = data.charAt(pos++);
                    if (next == 92) {
                        if (pos < data.length())
                            pos++;
                    } else if (next == 40)
                        nesting++;
                    else if (next == 41)
                        nesting--;
                }
                if (nesting != 0)
                    fail('Unterminated PDF literal string.');
                return new Value('string', data.substring(start, pos));
            }
            if (c == 60) {
                while (pos < data.length() && data.charAt(pos) != 62) {
                    Integer next = data.charAt(pos++);
                    if (
                        !white(next) &&
                        DIGITS.indexOf(String.fromCharArray(new List<Integer>{ next }).toLowerCase()) < 0
                    )
                        fail('Invalid PDF hex string.');
                }
                if (pos == data.length())
                    fail('Unterminated PDF hex string.');
                pos++;
                return new Value('string', data.substring(start, pos));
            }
            if (c == 47) {
                while (pos < data.length() && !delimiter(data.charAt(pos)))
                    pos++;
                return new Value('name', data.substring(start, pos));
            }
            pos = start;
            String token = word();
            if (Pattern.matches('[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)', token)) {
                Integer afterNumber = pos;
                if (Pattern.matches('[0-9]+', token)) {
                    skip();
                    if (pos < data.length() && data.charAt(pos) >= 48 && data.charAt(pos) <= 57) {
                        String gen = word();
                        if (Pattern.matches('[0-9]+', gen) && at('R')) {
                            pos++;
                            return reference(Integer.valueOf(token) + ' ' + Integer.valueOf(gen));
                        }
                    }
                }
                pos = afterNumber;
                return new Value('numeric', token);
            }
            if (token == 'true' || token == 'false')
                return new Value('bool', token);
            if (token == 'null')
                return new Value('null', token);
            fail('Unsupported PDF value token: ' + token + '.');
            return null;
        }
    }
}
