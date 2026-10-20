(function () {
    'use strict';
    function color(value, fallback) {
        return /^#[0-9a-f]{6}$/i.test(value || '') ? value : fallback;
    }
    function foreground(hex) {
        var channels = hex
            .slice(1)
            .match(/../g)
            .map(function (channel) {
                var value = parseInt(channel, 16) / 255;
                return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
            });
        var luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
        return luminance > 0.179 ? '#000000' : '#FFFFFF';
    }
    function https(value) {
        try {
            var url = new URL(value);
            return url.protocol === 'https:' && !url.username && !url.password ? url.href : '';
        } catch (_e) {
            return '';
        }
    }
    function text(id, value) {
        document.getElementById(id).textContent = value || '';
    }
    function bounded(value, minimum, maximum, fallback) {
        value = Number(value);
        return Number.isInteger(value) && value >= minimum && value <= maximum ? value : fallback;
    }
    function image(id, url, alt) {
        var element = document.getElementById(id);
        url = window.PortwoodBrandContent ? window.PortwoodBrandContent.assetUrl(url) : '';
        element.hidden = !url;
        element.style.removeProperty('display');
        element.alt = alt || '';
        element.onerror = function () {
            element.hidden = true;
        };
        if (url) {
            element.referrerPolicy = 'no-referrer';
            element.src = url;
        } else element.removeAttribute('src');
    }
    function renderSections(brand) {
        var page = brand.page || {};
        var tokens = Object.assign({}, brand, {
            logoUrl: page.logoUrl || brand.logoUrl,
            bannerUrl: page.bannerUrl,
            backgroundUrl: page.backgroundUrl
        });
        var rendered = {};
        ['header', 'welcome', 'footer', 'completion'].forEach(function (section) {
            var container = document.getElementById('signing-custom-' + section);
            rendered[section] =
                container && window.PortwoodBrandContent
                    ? window.PortwoodBrandContent.render(
                          container,
                          page.mode === 'Advanced' ? page[section + 'Html'] : '',
                          page.customCss || '',
                          tokens
                      ).rendered
                    : false;
        });
        if (rendered.header) document.getElementById('signing-brand-header').hidden = true;
        if (rendered.welcome) {
            document.getElementById('signing-brand-title').hidden = true;
            document.getElementById('signing-brand-welcome').hidden = true;
        } else {
            document.getElementById('signing-brand-title').hidden = false;
            document.getElementById('signing-brand-welcome').hidden = false;
        }
        if (rendered.footer) document.getElementById('signing-brand-footer').hidden = true;
        document.getElementById('signing-completion-message').hidden = rendered.completion;
    }
    window.PortwoodSigningBranding = {
        apply: function (brand) {
            if (!brand) return;
            var action = color(brand.color, '#0176D3');
            var header = color(brand.headerColor, '#FFFFFF');
            var background = color(brand.backgroundColor, '#F3F2F2');
            var page = brand.page || {};
            var body = document.body;
            body.style.setProperty('--signing-action', action);
            body.style.setProperty('--signing-action-text', foreground(action));
            body.style.setProperty('--signing-header', header);
            body.style.setProperty('--signing-header-text', foreground(header));
            body.style.setProperty('--signing-background', background);
            body.style.setProperty('--signing-background-text', foreground(background));
            body.style.setProperty('--signing-logo-height', bounded(page.logoHeight, 24, 160, 56) + 'px');
            body.style.setProperty('--signing-width', bounded(page.contentWidth, 640, 1440, 1040) + 'px');
            body.style.setProperty(
                '--signing-header-align',
                { Center: 'center', Right: 'flex-end' }[page.logoAlignment] || 'flex-start'
            );
            body.style.setProperty(
                '--signing-space',
                { Compact: '0.75rem', Spacious: '1.5rem' }[page.spacing] || '1rem'
            );
            body.style.setProperty('--signing-gap', { Compact: '1rem', Spacious: '1.5rem' }[page.spacing] || '1.25rem');
            body.style.setProperty(
                '--signing-font',
                (/^[a-zA-Z0-9 ,"'_-]{1,180}$/.test(page.fontFamily || '') ? page.fontFamily : '') ||
                    { Serif: 'Georgia, "Times New Roman", serif', Humanist: '"Trebuchet MS", Verdana, sans-serif' }[
                        page.font
                    ] ||
                    '"Salesforce Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
            );
            var backgroundUrl = window.PortwoodBrandContent
                ? window.PortwoodBrandContent.assetUrl(page.backgroundUrl)
                : '';
            var rgb = background
                .slice(1)
                .match(/../g)
                .map(function (channel) {
                    return parseInt(channel, 16);
                })
                .join(',');
            body.style.backgroundImage = backgroundUrl
                ? 'linear-gradient(rgba(' +
                  rgb +
                  ',0.92),rgba(' +
                  rgb +
                  ',0.92)),url("' +
                  backgroundUrl.replace(/["\\\r\n]/g, encodeURIComponent) +
                  '")'
                : 'none';
            body.classList.add('signing-branded');
            body.classList.toggle('signing-custom-layout', !!brand.page && page.layoutConfigured !== false);
            text('signing-brand-company', brand.companyName);
            text('signing-brand-title', brand.title);
            text('signing-brand-welcome', brand.welcomeText);
            text('signing-brand-footer-text', brand.footerText);
            if (brand.completionMessage) text('signing-completion-message', brand.completionMessage);
            document.title = brand.companyName ? brand.companyName + ' | Document signing' : 'Document signing';
            image('signing-brand-logo', page.logoUrl || brand.logoUrl, '');
            image('signing-brand-banner', page.bannerUrl, page.bannerAlt);
            var support = document.getElementById('signing-brand-support');
            var supportUrl = https(brand.supportUrl);
            support.hidden = !supportUrl;
            if (supportUrl) support.href = supportUrl;
            else support.removeAttribute('href');
            ['signing-brand-header', 'signing-brand-intro', 'signing-brand-footer', 'signing-brand-support'].forEach(
                function (id) {
                    document.getElementById(id).style.removeProperty('display');
                }
            );
            document.getElementById('signing-brand-header').hidden = false;
            document.getElementById('signing-brand-intro').hidden = false;
            document.getElementById('signing-brand-footer').hidden = !brand.footerText && !supportUrl;
            renderSections(brand);
        },
        initialize: function (brand) {
            if (!brand) return;
            // The server has already emitted the identity, images and CSS variables.
            // Only attach image failure handling and sanitize optional author HTML.
            ['signing-brand-logo', 'signing-brand-banner'].forEach(function (id) {
                var element = document.getElementById(id);
                element.onerror = function () {
                    element.hidden = true;
                };
                if (element.getAttribute('src') && element.complete && !element.naturalWidth) element.hidden = true;
            });
            renderSections(brand);
        }
    };
})();
