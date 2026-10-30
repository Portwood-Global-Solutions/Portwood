/** Private, versioned HTML fragments. Expand BEFORE fields/loops, never after merging record values. */
public with sharing class DocGenSnippetService {
    public static final String ASSET_TYPE = 'HTMLSnippet';
    public static final Integer MAX_HTML = 250000;
    private static final Integer MAX_EXPANDED = 1000000;
    private static final Pattern TAG = Pattern.compile('(?i)\\{%snippet:([a-z0-9][a-z0-9-]{0,39})\\}');
    private static Map<String, String> bodies = new Map<String, String>();

    public static String mergeTag(String key) {
        return '{%snippet:' + key + '}';
    }
    public static void clearCache() {
        bodies.clear();
    }
    public static Set<String> keys(String html) {
        Set<String> out = new Set<String>();
        if (String.isBlank(html))
            return out;
        Matcher m = TAG.matcher(html);
        while (m.find())
            out.add(m.group(1).toLowerCase());
        return out;
    }
    public static String expand(String html) {
        if (String.isBlank(html) || !html.toLowerCase().contains('{%snippet:'))
            return html;
        return expandInner(html, new Set<String>(), 0);
    }
    private static String expandInner(String html, Set<String> ancestors, Integer depth) {
        Set<String> wanted = keys(html);
        if (wanted.isEmpty()) {
            if (html.toLowerCase().contains('{%snippet:'))
                throw new DocGenException('Use a shared content tag like {%snippet:standard-terms}.');
            return html;
        }
        if (depth >= 8)
            throw new DocGenException('Shared content is nested too deeply. Use at most eight levels of snippets.');
        load(wanted);
        Matcher m = TAG.matcher(html);
        List<String> parts = new List<String>();
        Integer cursor = 0, size = 0;
        while (m.find()) {
            String key = m.group(1).toLowerCase();
            if (ancestors.contains(key))
                throw new DocGenException('Shared content contains a circular reference: ' + key + '.');
            Set<String> chain = ancestors.clone();
            chain.add(key);
            String expanded = expandInner(bodies.get(key), chain, depth + 1);
            String before = html.substring(cursor, m.start());
            size += before.length() + expanded.length();
            if (size > MAX_EXPANDED)
                throw new DocGenException(
                    'Expanded shared content is too large for one document. Split it into separate documents.'
                );
            parts.add(before);
            parts.add(expanded);
            cursor = m.end();
        }
        size += html.length() - cursor;
        if (size > MAX_EXPANDED)
            throw new DocGenException('Expanded shared content is too large for one document.');
        parts.add(html.substring(cursor));
        String result = String.join(parts, '');
        // A malformed reference alongside valid tags must not be silently consumed as an image tag.
        if (result.toLowerCase().contains('{%snippet:'))
            throw new DocGenException('A shared content tag is malformed. Copy its tag from Assets.');
        return result;
    }
    private static void load(Set<String> wanted) {
        Set<String> missing = wanted.clone();
        missing.removeAll(bodies.keySet());
        if (missing.isEmpty())
            return;
        if (bodies.size() + missing.size() > 100)
            throw new DocGenException('A document can reference at most 100 different snippets.');
        bodies.putAll(DocGenSnippetController.loadActiveBodies(missing));
        for (String key : missing)
            if (!bodies.containsKey(key))
                throw new DocGenException(
                    'Shared content "' +
                        key +
                        '" is missing, inactive, or has no saved HTML. Open Assets → Terms & snippets to fix it.'
                );
    }

    /** Validate rather than silently remove legal wording. Fragments use inline CSS; no executable or global HTML. */
    public static String validate(String html) {
        if (String.isBlank(html))
            throw new DocGenException('Add some content before saving this snippet.');
        html = DocGenService.decodeBraceEntities(html.trim());
        if (html.length() > MAX_HTML)
            throw new DocGenException('This snippet is too large. Split it into smaller reusable sections.');
        Set<String> tags = new Set<String>{
            'p',
            'div',
            'section',
            'article',
            'span',
            'h1',
            'h2',
            'h3',
            'h4',
            'h5',
            'h6',
            'strong',
            'b',
            'em',
            'i',
            'u',
            's',
            'strike',
            'del',
            'sup',
            'sub',
            'small',
            'br',
            'hr',
            'ul',
            'ol',
            'li',
            'blockquote',
            'pre',
            'code',
            'table',
            'thead',
            'tbody',
            'tfoot',
            'tr',
            'th',
            'td',
            'colgroup',
            'col',
            'a',
            'img',
            'font'
        };
        Set<String> attrs = new Set<String>{
            'style',
            'class',
            'id',
            'dir',
            'lang',
            'title',
            'alt',
            'href',
            'target',
            'rel',
            'src',
            'width',
            'height',
            'colspan',
            'rowspan',
            'align',
            'valign',
            'border',
            'cellpadding',
            'cellspacing',
            'start',
            'type',
            'color',
            'face',
            'size',
            'data-pw-font-face',
            'data-pw-page-break'
        };
        Pattern element = Pattern.compile('(?is)^<\\s*(/?)\\s*([a-z][a-z0-9]*)\\b(.*?)\\s*(/?)>$');
        Pattern attribute = Pattern.compile(
            '(?is)\\s+([a-z][a-z0-9_-]*)\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s"\'=<>`]+))'
        );
        Integer cursor = 0;
        while (true) {
            Integer start = html.indexOf('<', cursor);
            if (start < 0)
                break;
            Integer endPos = start + 1;
            String quote = null;
            while (endPos < html.length()) {
                String ch = html.substring(endPos, endPos + 1);
                if (quote != null) {
                    if (ch == quote)
                        quote = null;
                } else if (ch == '"' || ch == '\'')
                    quote = ch;
                else if (ch == '>')
                    break;
                endPos++;
            }
            if (endPos >= html.length())
                throw new DocGenException('A snippet HTML tag is unfinished. Check the HTML source.');
            String token = html.substring(start, endPos + 1);
            Matcher el = element.matcher(token);
            if (!el.matches() || !tags.contains(el.group(2).toLowerCase()))
                throw new DocGenException(
                    'Use an HTML fragment with text, tables and inline styles. Scripts, stylesheets and full HTML documents are not supported in snippets.'
                );
            String attributes = el.group(3);
            if (el.group(1) == '/' && String.isNotBlank(attributes))
                throw new DocGenException('Closing HTML tags cannot contain attributes.');
            Matcher am = attribute.matcher(attributes);
            Integer pos = 0;
            while (am.find()) {
                if (am.start() != pos)
                    throw new DocGenException('Check the attributes in this snippet’s HTML.');
                pos = am.end();
                String name = am.group(1).toLowerCase();
                String value = am.group(2) != null ? am.group(2) : (am.group(3) != null ? am.group(3) : am.group(4));
                if (!attrs.contains(name))
                    throw new DocGenException('The HTML attribute "' + name + '" is not supported in snippets.');
                String decoded = value.unescapeHtml4().toLowerCase().replaceAll('\\s+', '');
                if (
                    name == 'style' &&
                    (decoded.contains('url(') ||
                    decoded.contains('expression') ||
                    decoded.contains('javascript:') ||
                    decoded.contains('@') ||
                    decoded.contains('\\') ||
                    decoded.contains('/*') ||
                    decoded.contains('behavior:') ||
                    decoded.contains('-moz-binding'))
                )
                    throw new DocGenException(
                        'Snippet styles must use inline formatting. Use an image asset tag for images and a registered font tag for fonts.'
                    );
                if (
                    name == 'href' &&
                    !(decoded.startsWith('https://') ||
                    decoded.startsWith('http://') ||
                    decoded.startsWith('mailto:') ||
                    decoded.startsWith('#'))
                )
                    throw new DocGenException('Snippet links must use http, https, mailto, or a page anchor.');
                if (
                    name == 'src' &&
                    !(decoded.startsWith('{%asset:') ||
                    Pattern.matches('/sfc/servlet\\.shepherd/version/download/068[a-zA-Z0-9]{12,15}', value))
                )
                    throw new DocGenException(
                        'Use an image from Assets in snippets, for example <img src="{%asset:logo}" />.'
                    );
            }
            if (String.isNotBlank(attributes.substring(pos)))
                throw new DocGenException('Check the attributes in this snippet’s HTML.');
            cursor = endPos + 1;
        }
        return html;
    }
}
