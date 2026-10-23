/** Bounded, authoritative static TrueType inspection. No browser metadata is trusted. */
public class DocGenFontInspector {
    public static final Integer MAX_FONT_BYTES = 9 * 1024 * 1024;
    private static final String BASE64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    private String data;
    private String sha256;
    private Integer size;
    private Map<String, List<Integer>> tables = new Map<String, List<Integer>>();
    private Integer glyphs;
    public DocGenFontInspector(Blob source) {
        if (source == null || source.size() > MAX_FONT_BYTES || source.size() < 12)
            fail('Choose a valid static TTF up to 9 MB.');
        // Random byte access over base64 avoids a two-character hex copy of every font byte.
        // Large imports run asynchronously; the raw Blob and base64 fit the Winter '27 heap.
        sha256 = DocGenFontController.digest(source);
        data = EncodingUtil.base64Encode(source);
        size = source.size();
    }
    private static void fail(String message) {
        throw new DocGenException(message);
    }
    private void bounds(Integer p, Integer n, Integer start, Integer finish) {
        if (p == null || n < 0 || p < start || p > finish || n > finish - p)
            fail('Malformed TrueType table bounds.');
    }
    private Integer u(Integer p, Integer n) {
        bounds(p, n, 0, size);
        Integer out = 0;
        for (Integer i = p; i < p + n; i++) {
            Integer at = (i / 3) * 4 + Math.mod(i, 3);
            Integer pair =
                BASE64.indexOf(data.substring(at, at + 1)) * 64 + BASE64.indexOf(data.substring(at + 1, at + 2));
            Integer shift = Math.mod(i, 3) == 0 ? 4 : Math.mod(i, 3) == 1 ? 2 : 0;
            if (out > 8388607)
                fail('Font offset exceeds the supported range.');
            out = out * 256 + ((pair >> shift) & 255);
        }
        return out;
    }
    private Integer read(String name, Integer offset, Integer count) {
        List<Integer> t = tables.get(name);
        bounds(t[0] + offset, count, t[0], t[0] + t[1]);
        return u(t[0] + offset, count);
    }
    private String text(Integer p, Integer n) {
        List<Integer> chars = new List<Integer>();
        for (Integer i = 0; i < n; i += 2)
            chars.add(u(p + i, 2));
        return String.fromCharArray(chars).trim();
    }
    public Map<String, Object> inspect(String filename) {
        if (
            String.isBlank(filename) ||
            filename.length() > 255 ||
            !filename.toLowerCase().endsWith('.ttf') ||
            filename.contains('/') ||
            filename.contains('\\') ||
            Pattern.compile('[\\p{Cntrl}]').matcher(filename).find()
        )
            fail('Use a .ttf filename without path separators or control characters.');
        if (u(0, 4) != 65536)
            fail('Only static TrueType TTF is supported. OTF, WOFF, collections and variable fonts are not supported.');
        Integer count = u(4, 2);
        if (count < 1 || count > 200)
            fail('Invalid TrueType table count.');
        bounds(12, count * 16, 0, size);
        for (Integer i = 0; i < count; i++) {
            Integer p = 12 + i * 16;
            List<Integer> chars = new List<Integer>();
            for (Integer j = 0; j < 4; j++)
                chars.add(u(p + j, 1));
            String tag = String.fromCharArray(chars);
            Integer off = u(p + 8, 4), len = u(p + 12, 4);
            bounds(off, len, 12 + count * 16, size);
            if (tables.containsKey(tag))
                fail('Duplicate TrueType table.');
            tables.put(tag, new List<Integer>{ off, len });
        }
        for (String name : new List<String>{ 'head', 'maxp', 'name', 'cmap', 'OS/2', 'glyf', 'loca', 'hhea', 'hmtx' })
            if (!tables.containsKey(name))
                fail('Missing TrueType table ' + name + '.');
        if (tables.containsKey('fvar') || tables.containsKey('CFF ') || tables.containsKey('CFF2'))
            fail('Use a static TrueType outline font.');
        if (read('head', 12, 4) != 1594834165)
            fail('Invalid TrueType header.');
        glyphs = read('maxp', 4, 2);
        if (glyphs < 1 || glyphs > 20000)
            fail('This font exceeds the 20,000 glyph inspection budget.');
        Integer metricCount = read('hhea', 34, 2);
        if (metricCount < 1 || metricCount > glyphs)
            fail('Invalid horizontal metric count.');
        if (tables.get('hmtx')[1] < metricCount * 4 + (glyphs - metricCount) * 2)
            fail('Incomplete horizontal font metrics.');
        Integer locFormat = read('head', 50, 2);
        if (locFormat > 1)
            fail('Invalid loca format.');
        Integer prev = 0;
        for (Integer i = 0; i <= glyphs; i++) {
            Integer pos = read('loca', i * (locFormat == 0 ? 2 : 4), locFormat == 0 ? 2 : 4) * (locFormat == 0 ? 2 : 1);
            if (pos < prev || pos > tables.get('glyf')[1])
                fail('Invalid glyph outline offsets.');
            prev = pos;
        }
        Integer flags = read('OS/2', 8, 2);
        if ((flags & 770) != 0)
            fail('Font embedding restrictions prohibit this PDF path (restricted, no subsetting or bitmap only).');
        Integer n = read('name', 2, 2), storage = read('name', 4, 2);
        if (n > 4096)
            fail('Too many font name records.');
        Map<Integer, String> names = new Map<Integer, String>();
        Map<Integer, Integer> scores = new Map<Integer, Integer>();
        for (Integer i = 0; i < n; i++) {
            Integer p = 6 + i * 12,
                platform = read('name', p, 2),
                encoding = read('name', p + 2, 2),
                language = read('name', p + 4, 2),
                id = read('name', p + 6, 2),
                len = read('name', p + 8, 2),
                off = read('name', p + 10, 2);
            if (
                !new Set<Integer>{ 1, 2, 6, 16, 17 }.contains(id) ||
                !(platform == 0 || platform == 3 && (encoding == 1 || encoding == 10))
            )
                continue;
            if (Math.mod(len, 2) != 0 || len > 512)
                fail('Invalid font name encoding.');
            bounds(
                tables.get('name')[0] + storage + off,
                len,
                tables.get('name')[0],
                tables.get('name')[0] + tables.get('name')[1]
            );
            String value = text(tables.get('name')[0] + storage + off, len);
            Integer score = platform == 3 && language == 1033 ? 3 : platform == 0 ? 2 : 1;
            if (!scores.containsKey(id) || score > scores.get(id)) {
                names.put(id, value);
                scores.put(id, score);
            }
        }
        String family = names.get(1), sub = names.get(2);
        if (
            String.isBlank(family) ||
            String.isBlank(sub) ||
            family.length() > 100 ||
            !Pattern.matches('[\\p{L}\\p{N} ._-]+', family)
        )
            fail('The legacy PDF family name is missing or contains unsupported characters.');
        if (
            new Set<String>{
                    'arial',
                    'arial unicode ms',
                    'helvetica',
                    'times',
                    'times new roman',
                    'times-roman',
                    'courier',
                    'courier new',
                    'sans-serif',
                    'serif',
                    'monospace'
                }
                .contains(family.toLowerCase())
        )
            fail('This PDF family name is reserved for built-in fonts. Use a font with a distinct family name.');
        Set<Integer> coverage = coverage();
        List<Integer> sorted = new List<Integer>(coverage);
        sorted.sort();
        List<List<Integer>> ranges = new List<List<Integer>>();
        for (Integer cp : sorted) {
            if (ranges.isEmpty() || cp > ranges[ranges.size() - 1][1] + 1)
                ranges.add(new List<Integer>{ cp, cp });
            else
                ranges[ranges.size() - 1][1] = cp;
        }
        Integer osWeight = tables.get('OS/2')[1] >= 6 ? read('OS/2', 4, 2) : null;
        Integer fsSelection = tables.get('OS/2')[1] >= 64 ? read('OS/2', 62, 2) : 0;
        String lowerSub = sub.toLowerCase();
        return new Map<String, Object>{
            'family' => family,
            'subfamily' => sub,
            'preferredFamily' => names.get(16),
            'postscriptName' => names.get(6),
            // Google Fonts encode Light/Medium/Semibold/Black in OS/2.usWeightClass;
            // looking only for the word "Bold" made every other face look like 400.
            'weight' => cssWeight(osWeight, lowerSub),
            'style' => (fsSelection & 1) != 0 ||
                lowerSub.contains('italic') ||
                lowerSub.contains('oblique')
                ? 'italic'
                : 'normal',
            'embeddingFlags' => flags,
            'hasCedilla' => coverage.contains(350) && coverage.contains(351),
            'colorFont' => tables.containsKey('COLR') ||
            tables.containsKey('CBDT') ||
            tables.containsKey('sbix') ||
            tables.containsKey('SVG '),
            'coverage' => ranges,
            'filename' => filename,
            'sha256' => sha256,
            'sizeBytes' => size,
            'glyphCount' => glyphs
        };
    }

    /** Maps the OpenType weight class to the CSS weights used by @font-face. */
    private static Integer cssWeight(Integer weightClass, String subfamily) {
        if (weightClass != null && weightClass >= 1 && weightClass <= 1000) {
            Integer rounded = ((weightClass + 50) / 100) * 100;
            return Math.max(100, Math.min(900, rounded));
        }
        if (subfamily.contains('thin'))
            return 100;
        if (subfamily.contains('extra light') || subfamily.contains('extralight') || subfamily.contains('ultralight'))
            return 200;
        if (subfamily.contains('light'))
            return 300;
        if (subfamily.contains('medium'))
            return 500;
        if (subfamily.contains('semi bold') || subfamily.contains('semibold') || subfamily.contains('demibold'))
            return 600;
        if (subfamily.contains('extra bold') || subfamily.contains('extrabold') || subfamily.contains('ultrabold'))
            return 800;
        if (subfamily.contains('black') || subfamily.contains('heavy'))
            return 900;
        if (subfamily.contains('bold'))
            return 700;
        return 400;
    }
    private Set<Integer> coverage() {
        Integer base = tables.get('cmap')[0], cmapEnd = base + tables.get('cmap')[1], count = read('cmap', 2, 2);
        if (count > 64)
            fail('Too many cmap encodings.');
        Integer chosen = null, format = 0;
        for (Integer i = 0; i < count; i++) {
            Integer p = 4 + i * 8,
                platform = read('cmap', p, 2),
                enc = read('cmap', p + 2, 2),
                q = base + read('cmap', p + 4, 4);
            bounds(q, 2, base, cmapEnd);
            if (!(platform == 0 || platform == 3 && (enc == 1 || enc == 10)))
                continue;
            Integer f = u(q, 2);
            if ((f == 4 || f == 12) && f > format) {
                chosen = q;
                format = f;
            }
        }
        if (chosen == null)
            fail('A Unicode cmap format 4 or 12 is required.');
        Set<Integer> out = new Set<Integer>();
        Integer examined = 0;
        if (format == 12) {
            bounds(chosen, 16, base, cmapEnd);
            Integer finish = chosen + u(chosen + 4, 4);
            bounds(chosen, finish - chosen, base, cmapEnd);
            Integer n = u(chosen + 12, 4);
            if (n > 10000)
                fail('Too many cmap groups.');
            bounds(chosen + 16, n * 12, chosen, finish);
            Integer previous = -1;
            for (Integer i = 0; i < n; i++) {
                Integer p = chosen + 16 + i * 12, first = u(p, 4), last = u(p + 4, 4), gid = u(p + 8, 4);
                if (first > last || first <= previous || last > 1114111 || gid + last - first >= glyphs)
                    fail('Invalid cmap glyph range.');
                examined += last - first + 1;
                if (examined > 20000)
                    fail('This font exceeds the 20,000 character inspection budget.');
                for (Integer cp = first; cp <= last; cp++)
                    if (gid + cp - first != 0)
                        out.add(cp);
                previous = last;
            }
        } else {
            bounds(chosen, 16, base, cmapEnd);
            Integer finish = chosen + u(chosen + 2, 2);
            bounds(chosen, finish - chosen, base, cmapEnd);
            Integer seg2 = u(chosen + 6, 2);
            if (Math.mod(seg2, 2) != 0 || seg2 < 2 || seg2 > 16384)
                fail('Invalid cmap segments.');
            Integer n = seg2 / 2;
            Integer ends = chosen + 14, starts = ends + seg2 + 2, deltas = starts + seg2, offsets = deltas + seg2;
            bounds(ends, n * 8 + 2, chosen, finish);
            Integer previous = -1;
            for (Integer i = 0; i < n; i++) {
                Integer first = u(starts + i * 2, 2),
                    last = u(ends + i * 2, 2),
                    delta = u(deltas + i * 2, 2),
                    ro = u(offsets + i * 2, 2);
                if (first > last || first <= previous)
                    fail('Invalid cmap ordering.');
                previous = last;
                if (first == 65535)
                    continue;
                examined += last - first + 1;
                if (examined > 20000)
                    fail('This font exceeds the 20,000 character inspection budget.');
                for (Integer cp = first; cp <= last; cp++) {
                    Integer gid;
                    if (ro == 0)
                        gid = Math.mod(cp + delta, 65536);
                    else {
                        Integer at = offsets + i * 2 + ro + 2 * (cp - first);
                        bounds(at, 2, chosen, finish);
                        gid = u(at, 2);
                        if (gid != 0)
                            gid = Math.mod(gid + delta, 65536);
                    }
                    if (gid >= glyphs)
                        fail('Invalid cmap glyph index.');
                    if (gid != 0)
                        out.add(cp);
                }
            }
        }
        if (out.isEmpty())
            fail('The font has no usable Unicode glyphs.');
        return out;
    }
}
