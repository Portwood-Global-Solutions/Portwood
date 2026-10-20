/** Resource URLs stay in this Salesforce org. Ordinary hyperlinks are navigation. */
public without sharing class DocGenAssetPolicy {
    private static Set<String> hosts;

    public static String assetUrl(String value) {
        if (String.isBlank(value))
            return null;
        String candidate = value.trim().unescapeHtml4();
        if (Pattern.matches('(?s).*[\\s\\\\<>"].*', candidate) || candidate.contains('@') || candidate.startsWith('//'))
            return null;
        String decodedQuery = candidate;
        try {
            for (Integer i = 0; i < 3; i++) {
                String next = EncodingUtil.urlDecode(decodedQuery, 'UTF-8');
                if (next == decodedQuery)
                    break;
                decodedQuery = next;
            }
        } catch (Exception ex) {
            return null;
        }
        if (
            Pattern.compile('(?i)[?&](returl|starturl|redirect_uri|redirect|destination|target|url)=')
                .matcher(decodedQuery)
                .find()
        )
            return null;
        if (candidate.startsWith('/'))
            return localPath(candidate) ? URL.getOrgDomainUrl().toExternalForm() + candidate : null;
        try {
            Url parsed = new Url(candidate);
            return parsed.getProtocol() == 'https' &&
                parsed.getPort() == -1 &&
                (allowedHosts().contains(parsed.getHost().toLowerCase()) ||
                (parsed.getHost().toLowerCase().endsWith('.content.force.com') &&
                parsed.getPath().toLowerCase().startsWith('/servlet/rtaimage'))) &&
                localPath(parsed.getPath())
                ? candidate
                : null;
        } catch (Exception ex) {
            return null;
        }
    }

    public static Boolean localPath(String path) {
        if (String.isBlank(path))
            return false;
        Integer query = path.indexOf('?');
        if (query >= 0)
            path = path.substring(0, query);
        try {
            for (Integer i = 0; i < 3; i++) {
                String next = EncodingUtil.urlDecode(path, 'UTF-8');
                if (next == path)
                    break;
                path = next;
            }
        } catch (Exception ex) {
            return false;
        }
        if (path.startsWith('//') || path.contains('\\') || path.contains('..') || Pattern.matches('(?s).*\\s.*', path))
            return false;
        String lower = path.toLowerCase();
        return lower.startsWith('/resource/') ||
            lower.startsWith('/sfc/') ||
            lower.startsWith('/sfsites/') ||
            lower.startsWith('/file-asset/') ||
            lower.startsWith('/servlet/rtaimage') ||
            lower.startsWith('/servlet/servlet.image') ||
            lower.contains('/sfsites/') ||
            lower.contains('/file-asset/');
    }

    private static Set<String> allowedHosts() {
        if (hosts != null)
            return hosts;
        hosts = new Set<String>{ URL.getOrgDomainUrl().getHost().toLowerCase() };
        addHost(DomainCreator.getContentHostname());
        addHost(DomainCreator.getLightningHostname());
        addHost(DomainCreator.getVisualforceHostname(null));
        addHost(DomainCreator.getVisualforceHostname('c'));
        try {
            addHost(DomainCreator.getSalesforceSitesHostname());
        } catch (Exception ex) {
            // Sites need not be enabled in a subscriber org.
        }
        try {
            addHost(DomainCreator.getExperienceCloudSitesHostname());
        } catch (Exception ex) {
            // Experience Cloud need not be enabled.
        }
        try {
            String base = Site.getBaseUrl();
            if (String.isNotBlank(base))
                addHost(new Url(base).getHost());
        } catch (Exception ex) {
            // No active Site request.
        }
        return hosts;
    }

    private static void addHost(String host) {
        if (String.isNotBlank(host))
            hosts.add(host.toLowerCase());
    }

    /** Check both authored and merged HTML before publishing, previewing or rendering. */
    public static String assertHtmlResources(String html) {
        if (String.isBlank(html))
            return html;
        String checked = resourceScanHtml(html);
        if (Pattern.compile('(?is)<!ENTITY|<!DOCTYPE[^>]*(SYSTEM|PUBLIC)').matcher(checked).find())
            fail();
        Pattern attributes = Pattern.compile(
            '(?is)[\\s/]+([a-z_:][a-z0-9_:.\\-]*)(?:\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+)))?'
        );
        Pattern tagName = Pattern.compile('(?i)^<([a-z][a-z0-9:-]*)');
        Set<String> forbidden = new Set<String>{
            'script',
            'iframe',
            'object',
            'embed',
            'base',
            'video',
            'audio',
            'foreignobject',
            'animate',
            'animatetransform',
            'animatemotion',
            'animatecolor',
            'set',
            'discard',
            'math',
            'form',
            'link'
        };
        Set<String> resources = new Set<String>{
            'src',
            'srcset',
            'poster',
            'background',
            'data',
            'xlink:href',
            'href',
            'ping',
            'lowsrc',
            'dynsrc'
        };
        Set<String> cssAttributes = new Set<String>{
            'style',
            'fill',
            'stroke',
            'filter',
            'clip-path',
            'mask',
            'marker-start',
            'marker-mid',
            'marker-end',
            'cursor'
        };
        Matcher tags = Pattern.compile('(?is)<!--.*?-->|<[a-z][a-z0-9:-]*(?:[^\'">]|"[^"]*"|\'[^\']*\')*>')
            .matcher(checked);
        while (tags.find()) {
            String tag = tags.group();
            if (tag.startsWith('<!--'))
                continue;
            Matcher name = tagName.matcher(tag);
            name.find();
            String element = name.group(1).toLowerCase();
            if (forbidden.contains(element))
                fail();
            Matcher attrs = attributes.matcher(tag.substring(name.end()));
            while (attrs.find()) {
                String key = attrs.group(1).toLowerCase();
                String value = attrs.group(2) != null
                    ? attrs.group(2)
                    : (attrs.group(3) != null ? attrs.group(3) : attrs.group(4));
                if (key.startsWith('on') || (element == 'meta' && key == 'http-equiv'))
                    fail();
                if (
                    resources.contains(key) &&
                    !(key == 'href' &&
                    element == 'a') &&
                    (key == 'srcset' || !inlineResource(value))
                )
                    fail();
                if (cssAttributes.contains(key))
                    assertCss(value);
            }
        }
        Matcher blocks = Pattern.compile('(?is)<style\\b[^>]*>(.*?)</style>').matcher(checked);
        while (blocks.find())
            assertCss(blocks.group(1));
        return html;
    }

    /** Inline binary data cannot make a network request. Keep it out of the
     * HTML regex scan, which otherwise hits Apex's regex limit on large images. */
    private static String resourceScanHtml(String html) {
        if (!html.contains('data:'))
            return html;
        List<String> pieces = new List<String>();
        Integer copied = 0;
        Integer search = 0;
        while (search < html.length()) {
            Integer start = html.indexOf('data:', search);
            if (start < 0)
                break;
            String prefix = html.substring(start, Math.min(start + 100, html.length()));
            Matcher header = Pattern.compile('(?i)^data:(image/(png|jpe?g|gif|webp|bmp)|font/(ttf|otf|woff2?));base64,')
                .matcher(prefix);
            if (!header.find()) {
                search = start + 5;
                continue;
            }
            Integer payload = start + header.end();
            Integer endValue = html.length();
            String before = start == 0 ? '' : html.substring(start - 1, start);
            if (before == '"' || before == '\'') {
                Integer quote = html.indexOf(before, payload);
                if (quote >= 0)
                    endValue = quote;
            } else {
                for (String delimiter : new List<String>{ ' ', '\t', '\r', '\n', '>', ')', '"', '\'' }) {
                    Integer found = html.indexOf(delimiter, payload);
                    if (found >= 0 && found < endValue)
                        endValue = found;
                }
            }
            pieces.add(html.substring(copied, payload));
            pieces.add('AQ==');
            copied = endValue;
            search = endValue;
        }
        if (pieces.isEmpty())
            return html;
        pieces.add(html.substring(copied));
        return String.join(pieces, '');
    }

    public static void assertCss(String css) {
        if (String.isBlank(css))
            return;
        // Normalize comments before checking resource tokens; CSS escapes can
        // disguise them and are unnecessary for registered font declarations.
        css = css.unescapeHtml4().replaceAll('(?s)/\\*.*?\\*/', '');
        if (
            css.contains('\\') ||
            Pattern.compile('(?i)@import|(?:image|image-set|cross-fade|expression)\\s*\\(').matcher(css).find()
        )
            fail();
        Matcher urls = Pattern.compile('(?is)url\\s*\\(\\s*(?:"([^"]*)"|\'([^\']*)\'|([^)]*))\\s*\\)').matcher(css);
        while (urls.find()) {
            String value = urls.group(1) != null
                ? urls.group(1)
                : (urls.group(2) != null ? urls.group(2) : urls.group(3));
            if (!inlineResource(value.trim()))
                fail();
        }
    }

    private static Boolean inlineResource(String value) {
        if (String.isBlank(value))
            return true;
        value = value.trim();
        if (value.startsWith('#') || value.startsWith('cid:') || Pattern.matches('\\{[^<>]+\\}', value))
            return true;
        if (
            Pattern.matches(
                '(?is)data:(image/(png|jpe?g|gif|webp|bmp)|font/(ttf|otf|woff2?));base64,[a-z0-9+/=\\s]+',
                value
            )
        )
            return true;
        // Generated chart SVGs contain only local vector shapes and text.
        if (value.toLowerCase().startsWith('data:image/svg+xml;base64,')) {
            try {
                String svg = EncodingUtil.base64Decode(value.substring(value.indexOf(',') + 1)).toString();
                String local = svg.replaceAll('(?is)(?:xlink:)?href\\s*=\\s*["\']#[a-z0-9_:-]+["\']', '')
                    .replaceAll('(?is)url\\s*\\(\\s*["\']?#[a-z0-9_:-]+["\']?\\s*\\)', '');
                return !local.contains('\\') &&
                    !Pattern.compile(
                            '(?is)href\\s*=|url\\s*\\(|@import|image-set|cross-fade|<script|<foreignObject|<!DOCTYPE|<!ENTITY|[\\s/]on[a-z]+\\s*='
                        )
                        .matcher(local)
                        .find();
            } catch (Exception ex) {
                return false;
            }
        }
        return assetUrl(value) != null;
    }

    private static void fail() {
        throw new DocGenException(
            'Use Salesforce-hosted assets from Assets. External images, fonts, stylesheets and embedded content are not supported.'
        );
    }

    public static void assertOfficeResources(Compression.ZipReader reader) {
        for (Compression.ZipEntry entry : reader.getEntries()) {
            if (!entry.getName().endsWith('.rels'))
                continue;
            assertOfficeRelationshipXml(reader.extract(entry.getName()).toString());
        }
    }

    public static void assertOfficeRelationshipXml(String source) {
        Dom.Document xml = new Dom.Document();
        String lower = source.toLowerCase();
        if (lower.contains('<!entity') || lower.contains('<!doctype'))
            fail();
        xml.load(source);
        for (Dom.XmlNode relationship : xml.getRootElement().getChildElements()) {
            String type = relationship.getAttribute('Type', null);
            String target = relationship.getAttribute('Target', null);
            if (type != null && type.endsWith('/hyperlink'))
                continue;
            if (
                (relationship.getAttribute('TargetMode', null) == 'External' ||
                (target != null && Pattern.matches('(?i)(https?:)?//.*', target))) && assetUrl(target) == null
            )
                fail();
        }
    }
}
