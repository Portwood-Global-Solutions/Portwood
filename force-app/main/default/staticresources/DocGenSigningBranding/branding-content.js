(function () {
    'use strict';
    var sequence = 0;
    var tags = [
        'a',
        'article',
        'b',
        'blockquote',
        'br',
        'caption',
        'div',
        'em',
        'figcaption',
        'figure',
        'footer',
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'header',
        'hr',
        'i',
        'img',
        'li',
        'ol',
        'p',
        's',
        'section',
        'small',
        'span',
        'strong',
        'table',
        'tbody',
        'td',
        'tfoot',
        'th',
        'thead',
        'tr',
        'u',
        'ul'
    ];
    var properties = new Set(
        (
            'color background background-color background-image background-size background-position background-repeat font-family font-size font-weight font-style line-height letter-spacing ' +
            'text-align text-decoration text-transform white-space word-break overflow-wrap margin margin-top margin-right margin-bottom margin-left ' +
            'padding padding-top padding-right padding-bottom padding-left border border-top border-right border-bottom border-left border-color ' +
            'border-width border-style border-radius box-shadow display flex-direction flex-wrap flex-grow flex-shrink flex-basis align-items ' +
            'align-content align-self justify-content justify-items gap row-gap column-gap grid-template-columns grid-auto-flow order width max-width ' +
            'min-width height max-height min-height box-sizing vertical-align object-fit object-position overflow overflow-x overflow-y ' +
            'table-layout border-collapse border-spacing list-style-type list-style-position'
        ).split(' ')
    );

    function assetUrl(value) {
        if (!value || /[\\<>\s]/.test(value) || String(value).startsWith('//')) return '';
        if (/^data:image\/(png|jpe?g|gif|webp|bmp);base64,[a-z0-9+/=]+$/i.test(value)) return value;
        try {
            var source = new URL(value, window.location.href);
            if (source.protocol !== 'https:' || source.username || source.password) return '';
            if (!/^\/(resource\/|sfc\/|sfsites\/|file-asset\/|servlet\/(rtaImage|servlet\.Image))/i.test(source.pathname) &&
                !/\/(sfsites|file-asset)\//i.test(source.pathname)) return '';
            if (!/^https?:/i.test(value)) return source.pathname + source.search;
            if (source.origin === window.location.origin) return source.href;
            function identity(host) {
                var match = host.match(/^(.*?)\.(?:my\.salesforce-sites\.com|my\.salesforce\.com|my\.site\.com|file\.force\.com|lightning\.force\.com|vf\.force\.com)$/i);
                return match ? match[1].replace(/--(?:c|portwoodglobal)(?=\.|$)/i,'').toLowerCase() : null;
            }
            if (source.hostname.endsWith('.content.force.com') && /^\/servlet\/rtaImage/i.test(source.pathname)) return source.href;
            var org = identity(window.location.hostname);
            return org && org === identity(source.hostname) ? source.href : '';
        } catch (_e) {
            return '';
        }
    }
    function https(value) {
        try {
            var url = new URL(value);
            return url.protocol === 'https:' && !url.username && !url.password ? url.href : '';
        } catch (_e) {
            return '';
        }
    }
    function escape(value) {
        return String(value == null ? '' : value).replace(/[&<>"']/g, function (character) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character];
        });
    }
    function declarations(style) {
        var clean = [];
        var omitted = false;
        for (var i = 0; i < style.length; i++) {
            var property = style[i];
            var value = style.getPropertyValue(property).trim();
            if (
                !(
                    properties.has(property) ||
                    /^border-(?:(?:top|right|bottom|left)-(?:width|style|color)|(?:top|bottom)-(?:left|right)-radius)$/.test(
                        property
                    ) ||
                    /^background-(?:attachment|origin|clip|position-[xy]|repeat-[xy])$/.test(property) ||
                    /^text-decoration-(?:line|style|color|thickness)$/.test(property)
                ) ||
                /(?:url|image-set|cross-fade|paint|element)\s*\(|(?:https?|data|blob):|expression|(?:var|env|attr)\s*\(|[\\@{}<>]|[\u0000-\u001f]|[\d.](?:vh|vw|vmin|vmax)\b/i.test(
                    value
                ) ||
                /(^|[\s,(])-\d/.test(value)
            ) {
                omitted = true;
                continue;
            }
            if (
                /^(?:width|height|min-|max-|margin|padding|gap|row-gap|column-gap|border-width|border-radius|letter-spacing)/.test(
                    property
                ) &&
                (value.match(/\d+(?:\.\d+)?/g) || []).some(function (number) {
                    return Number(number) > 1440;
                })
            ) {
                omitted = true;
                continue;
            }
            if (
                property === 'line-height' &&
                !/^(?:normal|inherit|[0-3](?:\.\d+)?|[1-9]\d?(?:\.\d+)?px|[0-3](?:\.\d+)?(?:rem|em)|1\d\d%)$/.test(
                    value
                )
            ) {
                omitted = true;
                continue;
            }
            if (
                property === 'font-size' &&
                !/^(?:[1-9]\d?(?:\.\d+)?px|[0-5]?(?:\.\d+)?(?:rem|em)|100%|inherit)$/.test(value)
            ) {
                omitted = true;
                continue;
            }
            clean.push(property + ':' + value);
        }
        return { css: clean.join(';'), omitted: omitted };
    }
    function scopedCss(source, prefix) {
        if (!source) return { css: '', omitted: false };
        var omitted = false;
        try {
            // Constructed sheets never fetch @import resources. Only serialized,
            // allowlisted rules are attached to the real document below.
            var sheet = new CSSStyleSheet();
            sheet.replaceSync(source);
            function rules(items) {
                var result = [];
                for (var i = 0; i < items.length; i++) {
                    var rule = items[i];
                    if (rule.type === 1) {
                        var selectors = rule.selectorText.split(',').map(function (selector) {
                            return selector.trim();
                        });
                        var supported = selectors.every(function (selector) {
                            return (
                                selector &&
                                /^[a-zA-Z0-9_.\s>+~*-]+$/.test(selector.replace(/:(?:hover|focus-visible)\b/g, ''))
                            );
                        });
                        if (!supported) {
                            omitted = true;
                            continue;
                        }
                        var declaration = declarations(rule.style);
                        omitted = omitted || declaration.omitted;
                        if (declaration.css)
                            result.push(
                                selectors
                                    .map(function (selector) {
                                        return prefix + ' ' + selector;
                                    })
                                    .join(',') +
                                    '{' +
                                    declaration.css +
                                    '}'
                            );
                    } else if (rule.type === 4 && /^\((?:min|max)-width:\s*\d{2,4}px\)$/.test(rule.conditionText)) {
                        result.push('@media ' + rule.conditionText + '{' + rules(rule.cssRules) + '}');
                    } else {
                        omitted = true;
                    }
                }
                return result.join('\n');
            }
            var css = rules(sheet.cssRules);
            return { css: css, omitted: omitted || /@import/i.test(source) };
        } catch (_e) {
            return { css: '', omitted: true };
        }
    }
    window.PortwoodBrandContent = {
        assetUrl: assetUrl,
        render: function (container, source, css, tokens) {
            while (container.firstChild) container.removeChild(container.firstChild);
            container.hidden = true;
            if (!source || !window.DOMPurify) return { rendered: false, omitted: !!source };
            // Placeholders are escaped before HTML parsing, including in quoted
            // attributes. They cannot inject elements, handlers or new attributes.
            source = source.replace(/\{\{([a-zA-Z]+)\}\}/g, function (_match, key) {
                return escape(tokens[key]);
            });
            // Strip resource destinations inside an inert template before any
            // sanitizer parser or rendered fragment can encounter them.
            var preOmitted = false;
            var inert = document.createElement('template');
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- Inert prepass filters resources before DOMPurify or live insertion.
            inert.innerHTML = source;
            Array.prototype.forEach.call(
                inert.content.querySelectorAll(
                    'script,link,style,iframe,object,embed,svg,math,video,audio,source,base,meta'
                ),
                function (node) {
                    preOmitted = true;
                    node.remove();
                }
            );
            Array.prototype.forEach.call(inert.content.querySelectorAll('*'), function (node) {
                Array.prototype.slice.call(node.attributes).forEach(function (attribute) {
                    var name = attribute.name.toLowerCase();
                    if (
                        name.indexOf('on') === 0 ||
                        ['srcset', 'ping', 'poster', 'background', 'data', 'xlink:href'].indexOf(name) !== -1
                    )
                        node.removeAttribute(attribute.name);
                    else if (name === 'src') {
                        var local = node.tagName === 'IMG' ? assetUrl(attribute.value) : '';
                        if (local) node.setAttribute('src', local);
                        else {
                            preOmitted = true;
                            node.removeAttribute('src');
                        }
                    }
                });
                if (node.hasAttribute('style')) node.setAttribute('style', declarations(node.style).css);
            });
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- Serialize the resource-filtered inert fragment.
            source = inert.innerHTML;
            var fragment = window.DOMPurify.sanitize(source, {
                ALLOWED_TAGS: tags,
                ALLOWED_ATTR: [
                    'class',
                    'style',
                    'href',
                    'src',
                    'alt',
                    'title',
                    'aria-label',
                    'role',
                    'colspan',
                    'rowspan',
                    'scope'
                ],
                ALLOW_DATA_ATTR: false,
                FORBID_TAGS: [
                    'style',
                    'script',
                    'form',
                    'input',
                    'button',
                    'iframe',
                    'object',
                    'embed',
                    'svg',
                    'math',
                    'template'
                ],
                RETURN_DOM_FRAGMENT: true
            });
            // DOMPurify's inert parser reports its temporary BODY wrapper when
            // an explicit tag list is used. It is not omitted author content.
            var omitted =
                preOmitted ||
                window.DOMPurify.removed.some(function (item) {
                    return !item.element || item.element.nodeName !== 'BODY';
                });
            Array.prototype.forEach.call(fragment.querySelectorAll('*'), function (node) {
                if (node.hasAttribute('style')) {
                    var declaration = declarations(node.style);
                    node.removeAttribute('style');
                    node.style.cssText = declaration.css;
                    omitted = omitted || declaration.omitted;
                }
                if (node.tagName === 'IMG') {
                    var src = assetUrl(node.getAttribute('src'));
                    if (!src) {
                        omitted = omitted || !!node.getAttribute('src');
                        node.remove();
                        return;
                    }
                    node.src = src;
                    node.alt = node.getAttribute('alt') || '';
                    node.referrerPolicy = 'no-referrer';
                    node.loading = 'lazy';
                }
                if (node.tagName === 'A') {
                    var href = https(node.getAttribute('href'));
                    if (href) {
                        node.href = href;
                        node.target = '_blank';
                        node.rel = 'noopener noreferrer';
                    } else {
                        omitted = omitted || !!node.getAttribute('href');
                        node.removeAttribute('href');
                    }
                }
                ['rowspan', 'colspan'].forEach(function (attribute) {
                    if (node.hasAttribute(attribute) && !/^(?:[1-9]|[1-4]\d|50)$/.test(node.getAttribute(attribute)))
                        node.removeAttribute(attribute);
                });
            });
            if (!fragment.textContent.trim() && !fragment.querySelector('img'))
                return { rendered: false, omitted: omitted };
            var scope = 'pw-brand-' + ++sequence;
            container.setAttribute('data-brand-scope', scope);
            var prefix = '[data-brand-scope="' + scope + '"] .brand-html-root';
            var custom = scopedCss(css, prefix);
            var style = document.createElement('style');
            // Containment and clipping prevent negative layouts, shadows or huge
            // content from covering the managed document/signing controls.
            var wrapper = '[data-brand-scope="' + scope + '"]';
            style.textContent =
                wrapper +
                '{display:block;max-width:100%;overflow:hidden;contain:layout style paint;isolation:isolate;overflow-wrap:anywhere;}' +
                prefix +
                '{display:flow-root;max-width:100%;font:inherit;line-height:1.5;overflow-wrap:anywhere;}' +
                prefix +
                ' *{box-sizing:border-box;max-width:100%;}' +
                prefix +
                ' img{max-width:100%;height:auto;max-height:600px;object-fit:contain;}' +
                prefix +
                ' a{text-decoration:underline;color:inherit;}' +
                custom.css;
            var content = document.createElement('div');
            content.className = 'brand-html-root';
            content.appendChild(fragment);
            container.appendChild(style);
            container.appendChild(content);
            container.hidden = false;
            return { rendered: true, omitted: omitted || custom.omitted };
        }
    };
})();
