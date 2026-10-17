/** Pinned font bindings travel inside versioned HTML, alongside the body they style. */
public with sharing class DocGenFontService {
    private static final String MARKER = '-pw-font-face';
    private static Map<String, String> checkedCss = new Map<String, String>();
    private static Map<String, DocGen_Font_Face__c> checkedFaces = new Map<String, DocGen_Font_Face__c>();
    private static Map<String, DocGen_Font_Face__c> tagFaces = new Map<String, DocGen_Font_Face__c>();
    private static Map<String, Map<String, Object>> checkedMetadata = new Map<String, Map<String, Object>>();
    /** Revision metadata is immutable. Reuse one parse for bindings, glyph checks and native CSS. */
    private static Map<String, Object> metadata(DocGen_Font_Face__c face) {
        if (!checkedMetadata.containsKey(face.Revision_Key__c))
            checkedMetadata.put(
                face.Revision_Key__c,
                (Map<String, Object>) JSON.deserializeUntyped(face.Metadata_JSON__c)
            );
        return checkedMetadata.get(face.Revision_Key__c);
    }
    /** Tags identify a face revision, not a mutable latest-family alias. */
    public static String mergeTag(String assetKey, String revisionKey) {
        return '{%font:' + assetKey + ':' + revisionKey.substring(0, 16) + '}';
    }
    private static Boolean hasFontTag(String html) {
        return String.isNotBlank(html) && Pattern.compile('(?i)\\{%font:').matcher(html).find();
    }
    private static String bindingForTag(String assetKey, String revision) {
        String selector = assetKey + ':' + revision;
        if (!tagFaces.containsKey(selector)) {
            DocGenFlsGuard.assertAccessible(DocGen_Font_Face__c.sObjectType, new Set<String>{ 'Revision_Key__c' });
            DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, new Set<String>{ 'Asset_Key__c' });
            String prefix = revision + '%';
            // Bound, validated asset key and revision prefix; ambiguous revisions fail rather than choosing latest.
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Font_Face__c> rows = [
                SELECT Revision_Key__c
                FROM DocGen_Font_Face__c
                WHERE Asset__r.Asset_Key__c = :assetKey AND Revision_Key__c LIKE :prefix
                WITH SYSTEM_MODE
                LIMIT 2
            ];
            if (rows.size() != 1)
                throw new DocGenException(
                    'Font tag does not identify one available revision. Copy its tag from Assets > Fonts.'
                );
            DocGen_Font_Face__c resolved = DocGenFontController.load(rows[0].Revision_Key__c);
            if (resolved.Status__c != 'Verified' && resolved.Status__c != 'Retired')
                throw new DocGenException('This font revision has not passed native PDF review.');
            tagFaces.put(selector, resolved);
        }
        DocGen_Font_Face__c f = tagFaces.get(selector);
        if (f.Status__c != 'Verified' && f.Status__c != 'Retired')
            throw new DocGenException('This font revision has not passed native PDF review.');
        Map<String, Object> m = metadata(f);
        return MARKER +
            ':' +
            f.Revision_Key__c +
            ';font-family:"' +
            m.get('family') +
            '";font-weight:' +
            m.get('weight') +
            ';font-style:' +
            m.get('style') +
            ';';
    }
    /** A font tag is a CSS declaration in a quoted inline style, never an image URL or raw stylesheet. */
    public static String expandTags(String html) {
        if (String.isBlank(html) || !html.toLowerCase().contains('%font:'))
            return html;
        String source = DocGenService.decodeBraceEntities(html);
        if (!hasFontTag(source))
            return html;
        Matcher elements = Pattern.compile('(?is)<!--.*?-->|<[^>]+>').matcher(source);
        String output = '';
        Integer cursor = 0;
        while (elements.find()) {
            String tag = elements.group(0);
            if (!tag.startsWith('<!--') && hasFontTag(tag)) {
                Matcher styles = Pattern.compile('(?is)\\sstyle\\s*=\\s*(["\'])(.*?)\\1').matcher(tag);
                if (!styles.find())
                    throw new DocGenException('Place the font tag inside an element’s quoted style attribute.');
                String style = styles.group(2).unescapeHtml4();
                Matcher font = Pattern.compile('(?i)\\{%font:([a-z0-9-]{1,40}):([a-f0-9]{16,64})\\}').matcher(style);
                if (!font.find())
                    throw new DocGenException('Invalid font tag. Copy a verified face’s tag from Assets > Fonts.');
                String before = style.substring(0, font.start());
                if (String.isNotBlank(before) && !before.trim().endsWith(';'))
                    throw new DocGenException(
                        'Use the font tag as a whole style declaration, for example style="{%font:asset:revision};font-size:12pt".'
                    );
                String outsideTag = before + style.substring(font.end());
                if (Pattern.compile('(?i)(?:^|;)\\s*font(?:-family|-weight|-style)?\\s*:').matcher(outsideTag).find())
                    throw new DocGenException(
                        'The font tag sets family, weight and style. Remove font overrides and choose the face you want from Assets > Fonts.'
                    );
                String expanded =
                    before +
                    bindingForTag(font.group(1).toLowerCase(), font.group(2).toLowerCase()) +
                    style.substring(font.end());
                if (hasFontTag(expanded))
                    throw new DocGenException('Use one verified font tag per element.');
                tag =
                    tag.substring(0, styles.start()) +
                    ' style="' +
                    expanded.escapeHtml4() +
                    '"' +
                    tag.substring(styles.end());
                if (hasFontTag(tag))
                    throw new DocGenException('Font tags belong only inside style attributes.');
            }
            output += source.substring(cursor, elements.start()) + tag;
            cursor = elements.end();
        }
        output += source.substring(cursor);
        if (hasFontTag(output.replaceAll('(?is)<!--.*?-->', '')))
            throw new DocGenException('Place font tags in inline style attributes, not text, URLs or stylesheets.');
        return output;
    }
    /** The HTML extractor removes body attributes; retain a body-level font on a content wrapper. */
    public static String retainBodyFont(String bodyTag, String content) {
        String style = attribute(bodyTag, 'style');
        return style.contains(MARKER) ? '<div style="' + style.escapeHtml4() + '">' + content + '</div>' : content;
    }
    public static String faceCss(DocGen_Font_Face__c face) {
        if (face.Source_Checksum__c == null)
            throw new DocGenException('Generate and review this font’s Salesforce File PDF specimen in Assets first.');
        DocGenFontController.sourceFile(face);
        Map<String, Object> m = metadata(face);
        // Let the PDF renderer resolve the File in the caller’s Salesforce context.
        // An absolute org-domain URL works in API Apex but silently loses every
        // custom font when generation is invoked from Lightning.
        String url = DocGenFontController.fileUrl(face.Source_CV_Id__c);
        return '@font-face{font-family:"' +
            m.get('family') +
            '";src:url("' +
            url +
            '");font-weight:' +
            m.get('weight') +
            ';font-style:' +
            m.get('style') +
            ';-fs-pdf-font-embed:embed;-fs-pdf-font-encoding:Identity-H;}';
    }
    public static Boolean hasGlyph(Map<String, Object> m, Integer cp) {
        List<Object> ranges = (List<Object>) m.get('coverage');
        for (Object item : ranges) {
            List<Object> r = (List<Object>) item;
            Integer lo = Integer.valueOf(r[0]), hi = Integer.valueOf(r[1]);
            if (cp < lo)
                return false;
            if (cp <= hi)
                return true;
        }
        return false;
    }
    public static String specimenText(Map<String, Object> m) {
        for (
            String candidate : new List<String>{
                'Portwood · Şahin Şirket · ş 0123456789',
                'Portwood · 東京 漢字 · 0123456789',
                'Portwood - Document font - 0123456789'
            }
        ) {
            Boolean complete = true;
            for (Integer i = 0; i < candidate.length(); i++)
                if (!hasGlyph(m, candidate.charAt(i))) {
                    complete = false;
                    break;
                }
            if (complete)
                return candidate;
        }
        String seed = 'Portwood 0123456789';
        List<Integer> chars = new List<Integer>();
        for (Integer i = 0; i < seed.length(); i++)
            if (hasGlyph(m, seed.charAt(i)))
                chars.add(seed.charAt(i));
        if (chars.isEmpty()) {
            for (Object item : (List<Object>) m.get('coverage')) {
                List<Object> r = (List<Object>) item;
                Integer cp = Integer.valueOf(r[0]);
                if (cp < 32 || cp >= 55296 && cp <= 57343)
                    continue;
                if (cp <= 65535)
                    chars.add(cp);
                else {
                    Integer v = cp - 65536;
                    chars.add(55296 + v / 1024);
                    chars.add(56320 + Math.mod(v, 1024));
                }
                if (chars.size() >= 20)
                    break;
            }
        }
        return String.fromCharArray(chars);
    }
    public static void checkText(Map<String, Object> m, String text) {
        List<Object> ranges = (List<Object>) m.get('coverage');
        Set<Integer> seen = new Set<Integer>();
        for (Integer i = 0; i < text.length(); i++) {
            Integer cp = text.charAt(i);
            if (cp >= 55296 && cp <= 56319 && i + 1 < text.length()) {
                Integer low = text.charAt(++i);
                if (low < 56320 || low > 57343)
                    throw new DocGenException('Invalid Unicode text.');
                cp = 65536 + (cp - 55296) * 1024 + low - 56320;
            }
            if (cp == 9 || cp == 10 || cp == 13 || seen.contains(cp))
                continue;
            seen.add(cp);
            Boolean covered = false;
            for (Object item : ranges) {
                List<Object> r = (List<Object>) item;
                Integer lo = Integer.valueOf(r[0]), hi = Integer.valueOf(r[1]);
                if (cp < lo)
                    break;
                if (cp <= hi) {
                    covered = true;
                    break;
                }
            }
            if (!covered || cp > 65535) {
                String hex = EncodingUtil.convertToHex(Blob.valueOf(' '));
                Integer value = cp;
                String digits = '0123456789ABCDEF';
                hex = '';
                while (value > 0) {
                    hex = digits.substring(Math.mod(value, 16), Math.mod(value, 16) + 1) + hex;
                    value = value / 16;
                }
                while (hex.length() < 4)
                    hex = '0' + hex;
                // The native renderer drops UTF-16 surrogate pairs even when the
                // embedded font's format-12 cmap contains the character.
                if (covered)
                    throw new DocGenException(
                        'Custom-font PDFs do not support supplementary Unicode character U+' +
                            hex +
                            '. Use a supported character or an image.'
                    );
                throw new DocGenException(
                    'Font ' +
                        m.get('family') +
                        ' does not contain U+' +
                        hex +
                        '. Choose a font that contains this character.'
                );
            }
        }
    }
    private static String attribute(String tag, String name) {
        Matcher m = Pattern.compile('(?is)\\s' + name + '\\s*=\\s*(["\'])(.*?)\\1').matcher(tag);
        return m.find() ? m.group(2).unescapeHtml4() : '';
    }
    private static String property(String style, String name) {
        Matcher m = Pattern.compile('(?i)(?:^|;)\\s*' + name + '\\s*:\\s*([^;]+)').matcher(style);
        return m.find() ? m.group(1).trim() : '';
    }
    private static String withoutPriority(String value) {
        // Priority is CSS syntax, not part of the selected family/weight/style.
        return value.replaceFirst('(?i)\\s*!\\s*important\\s*$', '').trim();
    }
    private static String fontProperty(String style, String name) {
        return withoutPriority(property(style, name));
    }
    public static String prepare(String html) {
        html = expandTags(html);
        if (String.isBlank(html) || !html.contains(MARKER))
            return html;
        if (Pattern.compile('(?i)@font-face').matcher(html).find())
            throw new DocGenException(
                'Font-bound templates use registry font faces. Remove authored @font-face rules and choose fonts from Assets > Fonts.'
            );
        Matcher refs = Pattern.compile(MARKER + '\\s*:\\s*([a-f0-9]{64})').matcher(html);
        Map<String, Map<String, Object>> metas = new Map<String, Map<String, Object>>();
        String css = '';
        Map<String, String> triples = new Map<String, String>();
        while (refs.find()) {
            String key = refs.group(1);
            if (metas.containsKey(key))
                continue;
            if (!checkedFaces.containsKey(key))
                checkedFaces.put(key, DocGenFontController.load(key));
            DocGen_Font_Face__c f = checkedFaces.get(key);
            if (metas.size() >= 16)
                throw new DocGenException('A document can use up to 16 distinct font faces.');
            // Retired revisions remain usable by frozen templates. They disappear from new selections.
            if (f.Status__c != 'Verified' && f.Status__c != 'Retired')
                throw new DocGenException('This font revision has not passed native PDF review.');
            Map<String, Object> m = metadata(f);
            String triple = m.get('family') + ':' + m.get('weight') + ':' + m.get('style');
            if (triples.containsKey(triple) && triples.get(triple) != (String) m.get('sha256'))
                throw new DocGenException('Conflicting font bytes share the same PDF family and style.');
            triples.put(triple, (String) m.get('sha256'));
            metas.put(key, m);
            if (!checkedCss.containsKey(key))
                checkedCss.put(key, faceCss(f));
            css += checkedCss.get(key);
        }
        if (metas.isEmpty())
            throw new DocGenException('Invalid pinned font revision marker.');
        Set<String> families = new Set<String>();
        for (Map<String, Object> m : metas.values())
            families.add(((String) m.get('family')).toLowerCase());
        Matcher styleBlocks = Pattern.compile('(?is)<style\\b[^>]*>(.*?)</style>').matcher(html);
        while (styleBlocks.find()) {
            Matcher declarations = Pattern.compile('(?i)font-family\\s*:\\s*([^;}]+)').matcher(styleBlocks.group(1));
            while (declarations.find())
                for (
                    String family : withoutPriority(declarations.group(1))
                        .replace('"', '')
                        .replace('\'', '')
                        .toLowerCase()
                        .split(',')
                )
                    if (families.contains(family.trim()))
                        throw new DocGenException(
                            'Custom font stylesheets need inline font bindings. Use an Assets font tag in each container’s style attribute.'
                        );
        }

        List<String> stack = new List<String>{ '' };
        List<String> tags = new List<String>();
        String current = '';
        Map<Integer, String> replacements = new Map<Integer, String>();
        Integer last = 0;
        Matcher tokens = Pattern.compile('(?is)<!--.*?-->|<[^>]+>').matcher(html);
        while (tokens.find()) {
            if (current != '')
                checkText(metas.get(current), html.substring(last, tokens.start()).unescapeHtml4());
            String tag = tokens.group(0);
            last = tokens.end();
            if (tag.startsWith('<!--') || tag.startsWith('<!') || tag.startsWith('<?'))
                continue;
            Matcher nameMatch = Pattern.compile('(?i)^<\\s*(/?)\\s*([a-z0-9]+)').matcher(tag);
            if (!nameMatch.find())
                throw new DocGenException('Invalid font-bound HTML markup.');
            String name = nameMatch.group(2).toLowerCase();
            if (nameMatch.group(1) == '/') {
                if (tags.isEmpty() || tags[tags.size() - 1] != name)
                    throw new DocGenException('Font-bound templates require balanced HTML tags (' + name + ').');
                tags.remove(tags.size() - 1);
                stack.remove(stack.size() - 1);
                current = stack[stack.size() - 1];
                continue;
            }
            String style = attribute(tag, 'style'), key = property(style, MARKER);
            if (key != '') {
                if (!metas.containsKey(key))
                    throw new DocGenException('Unknown pinned font revision.');
                current = key;
            }
            if (current == '') {
                String named = fontProperty(style, 'font-family');
                if (name == 'font')
                    named = attribute(tag, 'face');
                for (String family : named.replace('"', '').replace('\'', '').toLowerCase().split(','))
                    if (families.contains(family.trim()))
                        throw new DocGenException('Add an explicit verified font binding to this text container.');
            }
            if (current != '') {
                Map<String, Object> m = metas.get(current);
                String family = fontProperty(style, 'font-family'),
                    weight = fontProperty(style, 'font-weight'),
                    slant = fontProperty(style, 'font-style');
                family = family.replace('"', '').replace('\'', '');
                if (
                    (family != '' &&
                    family != (String) m.get('family')) ||
                    (weight != '' &&
                    weight != String.valueOf(m.get('weight')) &&
                    !(weight == 'normal' &&
                    String.valueOf(m.get('weight')) == '400') &&
                    !(weight == 'bold' &&
                    String.valueOf(m.get('weight')) == '700')) ||
                    (slant != '' &&
                    slant != (String) m.get('style')) ||
                    (key == '' && new Set<String>{ 'b', 'strong', 'i', 'em' }.contains(name)) ||
                    name == 'font'
                )
                    throw new DocGenException('Select an explicit verified face for each font, bold or italic change.');
                if (key != '' && (family == '' || weight == '' || slant == ''))
                    throw new DocGenException('A font binding must specify its exact family, weight and style.');
                // Pin inherited descendants too. Inline priority protects the verified
                // face from stylesheet/shorthand overrides while leaving authored
                // !important colour, sizing and layout declarations intact.
                String baseTag = tag.replaceFirst('(?is)\\sstyle\\s*=\\s*(["\']).*?\\1', '');
                Integer endAt = baseTag.endsWith('/>') ? baseTag.length() - 2 : baseTag.length() - 1;
                String exact =
                    style +
                    ';font-family:"' +
                    m.get('family') +
                    '" !important;font-weight:' +
                    m.get('weight') +
                    ' !important;font-style:' +
                    m.get('style') +
                    ' !important;';
                replacements.put(
                    tokens.start(),
                    baseTag.substring(0, endAt) + ' style="' + exact.escapeHtml4() + '"' + baseTag.substring(endAt)
                );
            }
            if (
                !tag.endsWith('/>') &&
                !new Set<String>{
                        'br',
                        'hr',
                        'img',
                        'meta',
                        'link',
                        'input',
                        'wbr',
                        'area',
                        'base',
                        'col',
                        'embed',
                        'param',
                        'source',
                        'track'
                    }
                    .contains(name)
            ) {
                tags.add(name);
                stack.add(current);
            } else
                current = stack[stack.size() - 1];
        }
        if (current != '')
            checkText(metas.get(current), html.substring(last).unescapeHtml4());
        if (!tags.isEmpty())
            throw new DocGenException('Font-bound templates require balanced HTML.');
        String rendered = '';
        Integer cursor = 0;
        Matcher rewrite = Pattern.compile('(?is)<!--.*?-->|<[^>]+>').matcher(html);
        while (rewrite.find()) {
            rendered +=
                html.substring(cursor, rewrite.start()) +
                (replacements.containsKey(rewrite.start()) ? replacements.get(rewrite.start()) : rewrite.group(0));
            cursor = rewrite.end();
        }
        rendered += html.substring(cursor);
        return rendered.replaceFirst('(?i)</head>', '<style>' + css + '</style></head>');
    }
    public class ProtectedRuns {
        public String masked;
        public Map<String, String> runs = new Map<String, String>();
    }
    /** Keep legacy glyph repair outside explicitly font-bound subtrees only. */
    public static ProtectedRuns protect(String html) {
        ProtectedRuns out = new ProtectedRuns();
        out.masked = '';
        Integer last = 0, start = -1, depth = 0;
        Matcher tokens = Pattern.compile('(?is)<[^>]+>').matcher(html);
        while (tokens.find()) {
            String tag = tokens.group(0);
            Boolean close = tag.startsWith('</');
            Boolean empty =
                tag.endsWith('/>') || Pattern.compile('(?i)^<(br|hr|img|meta|link|input|wbr)\\b').matcher(tag).find();
            if (start < 0 && tag.contains(MARKER)) {
                start = tokens.start();
                depth = 0;
                out.masked += html.substring(last, start);
            }
            if (start >= 0) {
                if (close)
                    depth--;
                else if (!empty)
                    depth++;
                if (depth == 0) {
                    String placeholder = 'PWPROTECTEDFONT' + out.runs.size() + 'END';
                    out.runs.put(placeholder, html.substring(start, tokens.end()));
                    out.masked += placeholder;
                    last = tokens.end();
                    start = -1;
                }
            }
        }
        if (start >= 0)
            throw new DocGenException('Unbalanced font-bound HTML.');
        out.masked += html.substring(last);
        return out;
    }
}
