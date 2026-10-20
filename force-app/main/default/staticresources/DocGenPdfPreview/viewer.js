/* First-party host for the pinned PDF.js adapter in this Salesforce static resource. */
(() => {
    const session = location.hash.slice(1);
    let current = 0, task;
    const send = (type, request, fields = {}) => parent.postMessage(
        { type, session, request, ...fields, height: document.documentElement.scrollHeight }, location.origin
    );
    const pages = document.getElementById('pages');
    async function render(base64, request) {
        current = request;
        try {
            if (task) await task.destroy();
            if (current !== request) return;
            pages.replaceChildren();
            const binary = atob(base64), bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            // The locally loaded worker handler uses PDF.js's standard loopback
            // port. Image inflation runs here without Lightning membrane traps.
            task = pdfjsLib.getDocument({ data: bytes, isEvalSupported: false });
            const pdf = await task.promise;
            if (current !== request) return;
            for (let number = 1; number <= pdf.numPages; number++) {
                if (current !== request) return;
                send('docgen-pdf-progress', request, { pageCount: pdf.numPages, status: 'Rendering page ' + number + ' of ' + pdf.numPages + '…' });
                const page = await pdf.getPage(number), original = page.getViewport({ scale: 1 });
                const viewport = page.getViewport({ scale: Math.min(1.5, Math.max(240, pages.clientWidth - 48) / original.width) });
                const sheet = document.createElement('section');
                sheet.className = 'pdf-page';
                sheet.setAttribute('aria-label', 'PDF page ' + number);
                const canvas = document.createElement('canvas');
                canvas.width = Math.ceil(viewport.width);
                canvas.height = Math.ceil(viewport.height);
                canvas.setAttribute('aria-hidden', 'true');
                const accessible = document.createElement('p');
                accessible.className = 'pdf-text';
                accessible.textContent = (await page.getTextContent()).items.map(item => item.str || '').join(' ');
                const label = document.createElement('div');
                label.className = 'pdf-page-label';
                label.textContent = 'Page ' + number + ' of ' + pdf.numPages;
                sheet.append(canvas, accessible, label);
                pages.append(sheet);
                await page.render({ canvasContext: canvas.getContext('2d'), viewport }).promise;
            }
            if (current === request) send('docgen-pdf-complete', request, { pageCount: pdf.numPages });
        } catch (error) {
            if (current === request) send('docgen-pdf-error', request, { message: error?.message || 'The PDF could not be displayed.' });
        }
    }
    window.addEventListener('message', event => {
        const data = event.data;
        if (event.source !== parent || event.origin !== location.origin || data?.session !== session) return;
        if (data.type === 'docgen-pdf-render' && Number.isSafeInteger(data.request) && typeof data.base64 === 'string') render(data.base64, data.request);
    });
    send('docgen-pdf-ready');
})();
