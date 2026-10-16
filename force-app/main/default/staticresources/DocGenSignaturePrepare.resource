/* Authenticated, record-bound Visualforce editor. Vendored libraries only. */
(function () {
    'use strict';
    var env = window.PortwoodPreparation;
    var $ = function (id) { return document.getElementById(id); };
    var escapeHtml = function (value) {
        return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    };
    var types = { Full: 'Signature', Initials: 'Initials', Date: 'Date signed', DatePick: 'Date picker' };
    var colors = ['#075cad', '#7840a2', '#227548', '#a75813', '#a1315a'];
    var state = {
        step: 0, source: env.source === 'files' ? 'files' : 'upload', draftId: null, revision: 0,
        documentId: null, title: '', recipients: [{ key: 'recipient-1', name: '', email: '' }],
        fields: [], pages: [], page: 1, owner: 'recipient-1', tool: null, selected: null,
        expirationDays: 30, requireVerification: null, prefill: true, subject: '', message: '',
        delivery: 'preview', dirty: false
    };
    var context = { files: [], drafts: [] }, pdf, pdfjs, viewport, pageModel, renderTask, renderSequence = 0;
    var busy = false, documentBytes, contactTimer, lastWidth = 0, pendingSource = null;

    function rpc(action, args) {
        return new Promise(function (resolve, reject) {
            var params = [env.actions[action]].concat(args);
            params.push(function (result, event) {
                if (!event.status) reject(new Error(event.message || 'The request could not be completed.'));
                else resolve(result);
            }, { escape: false, buffer: false, timeout: 120000 });
            Visualforce.remoting.Manager.invokeAction.apply(Visualforce.remoting.Manager, params);
        });
    }
    function notify(action) {
        if (/^https:\/\/[a-z0-9.-]+\.(lightning\.force\.com|salesforce\.com)$/.test(env.parentOrigin)) {
            window.parent.postMessage({ channel: 'portwood-signatures', nonce: env.nonce, action: action }, env.parentOrigin);
        }
    }
    function error(err) { $('error').textContent = err.message || String(err); $('error').hidden = false; }
    function clearError() { $('error').hidden = true; $('error').textContent = ''; }
    function setBusy(value, message) {
        busy = value; $('busy').hidden = !value; $('busy').textContent = message || 'Working…'; updateFooter();
        if (!value && pendingSource) { var source = pendingSource; pendingSource = null; switchSource(source); }
    }
    function changed() { state.dirty = true; updateFooter(); }
    function config() {
        return { version: 1, documentId: state.documentId, title: state.title, recipients: state.recipients,
            fields: state.fields, pages: state.pages, expirationDays: Number(state.expirationDays),
            requireVerification: state.requireVerification, prefill: state.prefill, subject: state.subject,
            message: state.message, delivery: state.delivery };
    }
    function namespaceValue(row, name) { return row[name] == null ? row['portwoodglobal__' + name] : row[name]; }
    function missingSignatures() {
        return state.recipients.filter(function (person) {
            return !state.fields.some(function (field) { return field.recipientKey === person.key && field.type === 'Full'; });
        });
    }
    function canAdvance() {
        if (!state.documentId) return false;
        if (state.step === 1 || state.step === 3) {
            if (!state.recipients.length || state.recipients.some(function (p) { return !p.name.trim() || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(p.email.trim()); })) return false;
        }
        return (state.step !== 2 && state.step !== 3) || !missingSignatures().length;
    }
    function updateFooter() {
        $('save').disabled = busy || !state.draftId;
        $('back').disabled = busy || state.step === 0;
        $('back').hidden = state.step === 0;
        $('next').disabled = busy || !canAdvance();
        $('next').textContent = state.step === 3 ? (state.delivery === 'email' ? 'Send request' : state.delivery === 'preview' ? 'Create preview links' : 'Create signing links') : state.step === 2 ? 'Review request' : 'Continue';
        $('status').textContent = state.step === 2 && missingSignatures().length ?
            'Place a signature for ' + missingSignatures().map(function (p) { return p.name || 'Recipient'; }).join(', ') :
            state.draftId ? (state.dirty ? 'Unsaved changes' : 'Draft saved') : 'Choose a PDF to start.';
    }
    function renderControls() {
        document.querySelectorAll('[data-step]').forEach(function (button) { button.setAttribute('aria-current', Number(button.dataset.step) === state.step ? 'step' : 'false'); });
        $('document-heading').textContent = state.title || 'New signature request';
        var html;
        if (state.step === 0) html = documentControls();
        else if (state.step === 1) html = recipientControls();
        else if (state.step === 2) html = fieldControls();
        else html = reviewControls();
        $('controls').innerHTML = html;
        wireControls(); updateFooter(); renderFields();
    }
    function documentControls() {
        var html;
        if (state.source === 'upload') {
            html = '<h3>Upload your PDF</h3><p class="small">Choose the document you want signed. Its layout will stay as uploaded.</p>' +
                '<div class="drop" id="drop"><strong>Drop your PDF here</strong><p class="small">PDF · Up to 2 MB · Up to 50 pages</p><button id="choose-file" class="primary">Choose PDF</button><input class="file-input" id="upload" type="file" accept=".pdf,application/pdf" aria-label="Upload a PDF" /></div>';
        } else {
            html = '<h3>Files on this record</h3><p class="small">Choose a PDF to prepare for signature.</p>';
            if (!context.files.length) html += '<p class="small">No PDFs are attached to this record. Use Change source above to upload a PDF.</p>';
            context.files.forEach(function (file) { html += '<button class="file-item" data-file="' + escapeHtml(file.Id) + '">' + escapeHtml(file.Title) + '<div class="small">' + Math.ceil(file.ContentSize / 1024) + ' KB</div></button>'; });
        }
        if (state.documentId) html += '<div class="selected-file"><strong>' + escapeHtml(state.title) + '</strong><span class="small">' + state.pages.length + ' pages · Original preserved</span></div>';
        return html;
    }
    function switchSource(source) {
        state.source = source; state.step = 0; state.selected = null; state.tool = null;
        clearError(); renderControls();
    }
    function recipientControls() {
        var html = '<h3>Who needs to sign?</h3><p class="small">Recipients sign one at a time, in this order.</p>';
        state.recipients.forEach(function (person, index) {
            html += '<div class="recipient"><div class="recipient-head"><span class="avatar">' + (index + 1) + '</span><strong>Recipient ' + (index + 1) + '</strong><button data-remove-person="' + escapeHtml(person.key) + '" aria-label="Remove recipient ' + (index + 1) + '" ' + (state.recipients.length === 1 ? 'disabled' : '') + '>×</button></div>' +
                '<label for="contact-' + index + '">Find a Salesforce Contact</label><input id="contact-' + index + '" data-contact="' + escapeHtml(person.key) + '" placeholder="Search contacts" autocomplete="off" /><div id="contact-results-' + index + '" class="contact-options" hidden></div>' +
                '<label for="name-' + index + '">Name</label><input id="name-' + index + '" data-person="' + escapeHtml(person.key) + '" data-property="name" value="' + escapeHtml(person.name) + '" maxlength="100" autocomplete="off" />' +
                '<label for="email-' + index + '">Email</label><input id="email-' + index + '" data-person="' + escapeHtml(person.key) + '" data-property="email" type="email" value="' + escapeHtml(person.email) + '" maxlength="100" autocomplete="off" /></div>';
        });
        return html + '<button id="add-person" style="margin-top:15px" ' + (state.recipients.length >= 10 ? 'disabled' : '') + '>+ Add recipient</button>';
    }
    function fieldControls() {
        var html = '<h3>Place signing fields</h3><label for="field-owner">Assign fields to</label><select id="field-owner">';
        state.recipients.forEach(function (person, index) { html += '<option value="' + escapeHtml(person.key) + '" ' + (state.owner === person.key ? 'selected' : '') + '>' + escapeHtml(person.name || 'Recipient ' + (index + 1)) + '</option>'; });
        html += '</select><div class="field-tools">';
        Object.keys(types).forEach(function (type) { html += '<button data-tool="' + type + '" class="' + (state.tool === type ? 'active' : '') + '">' + types[type] + '</button>'; });
        html += '</div><p class="small">' + (state.tool ? 'Click on the document to place ' + types[state.tool].toLowerCase() + '.' : 'Choose a field, then click on the PDF. Drag placed fields to move them.') + '</p>';
        var field = selectedField();
        if (field) {
            var person = state.recipients.find(function (p) { return p.key === field.recipientKey; });
            html += '<div class="field-info"><h3>' + types[field.type] + '</h3><p class="small">' + escapeHtml(person.name || 'Recipient') + ' · Page ' + field.page + '</p><label for="field-width">Width</label><input id="field-width" type="range" min="40" max="280" value="' + screenRect(field).width + '" /><label for="field-height">Height</label><input id="field-height" type="range" min="20" max="100" value="' + screenRect(field).height + '" /><p class="small">Arrow keys move the selected field. Delete removes it.</p><button id="delete-field" class="quiet">Remove field</button></div>';
        }
        html += '<div class="field-info"><strong>' + state.fields.length + ' fields placed</strong>';
        state.recipients.forEach(function (person, index) {
            var count = state.fields.filter(function (f) { return f.recipientKey === person.key; }).length;
            html += '<p class="small">' + escapeHtml(person.name || 'Recipient ' + (index + 1)) + ': ' + count + ' fields</p>';
        });
        return html + '</div>';
    }
    function reviewControls() {
        var html = '<h3>Review and send</h3><label for="title">Document title</label><input id="title" data-setting="title" maxlength="200" value="' + escapeHtml(state.title) + '" />' +
            '<p class="small">' + state.pages.length + ' pages · ' + state.fields.length + ' fields · Sign in order</p>';
        state.recipients.forEach(function (person, index) { html += '<div class="recipient-head" style="margin:12px 0"><span class="avatar">' + (index + 1) + '</span><div><strong>' + escapeHtml(person.name) + '</strong><div class="small">' + escapeHtml(person.email) + '</div></div></div>'; });
        html += '<label for="expirationDays">Links expire in days</label><input id="expirationDays" data-setting="expirationDays" type="number" min="1" max="365" value="' + state.expirationDays + '" />' +
            '<label for="verification">Email verification</label><select id="verification"><option value="inherit" ' + (state.requireVerification == null ? 'selected' : '') + '>Use org default (' + (context.verificationDefault ? 'required' : 'off') + ')</option><option value="yes" ' + (state.requireVerification === true ? 'selected' : '') + '>Require an email code</option><option value="no" ' + (state.requireVerification === false ? 'selected' : '') + '>No email code</option></select>' +
            '<label for="delivery">Delivery</label><select id="delivery"><option value="preview" ' + (state.delivery === 'preview' ? 'selected' : '') + '>Preview signing in Salesforce</option>';
        if (context.publicSite) html += '<option value="links" ' + (state.delivery === 'links' ? 'selected' : '') + '>Create public signing links</option>';
        if (context.canEmail) html += '<option value="email" ' + (state.delivery === 'email' ? 'selected' : '') + '>Email invitations</option>';
        html += '</select>';
        if (!context.publicSite) html += '<div class="notice">A public signing site is not configured. Preview links work for signed-in Salesforce users. Configure the signing site in Signature Settings before sending to external recipients.</div>';
        if (state.delivery === 'email') html += '<label for="subject">Email subject</label><input id="subject" data-setting="subject" maxlength="255" value="' + escapeHtml(state.subject) + '" /><label for="message">Message</label><textarea id="message" data-setting="message" maxlength="2000" rows="3">' + escapeHtml(state.message) + '</textarea>';
        return html;
    }
    function selectedField() { return state.fields.find(function (f) { return f.id === state.selected; }); }
    function bytesToBase64(bytes) {
        var text = ''; for (var i = 0; i < bytes.length; i += 8192) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
        return btoa(text);
    }
    function base64ToBytes(base64) { var text = atob(base64), bytes = new Uint8Array(text.length); for (var i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i); return bytes; }
    async function validatePdf(bytes) {
        if (bytes.length > 2097152) throw new Error('Choose a PDF no larger than 2 MB.');
        var doc;
        try { doc = await PDFLib.PDFDocument.load(bytes); }
        catch (_err) { throw new Error('This PDF is encrypted or cannot be opened. Export an unlocked PDF and try again.'); }
        if (doc.getPageCount() > 50) throw new Error('Choose a PDF with no more than 50 pages.');
        var signed = doc.context.enumerateIndirectObjects().some(function (entry) { return entry[1] instanceof PDFLib.PDFDict && entry[1].has(PDFLib.PDFName.of('ByteRange')); });
        if (signed) throw new Error('This PDF already has a digital signature. Choose an unsigned copy.');
        return doc.getPages().map(function (page) { var box = page.getCropBox(); return { x: box.x, y: box.y, width: box.width, height: box.height, rotation: ((page.getRotation().angle % 360) + 360) % 360 }; });
    }
    async function applyDocument(result) {
        documentBytes = base64ToBytes(result.base64);
        var geometry = await validatePdf(documentBytes);
        if (pdf) await pdf.destroy();
        pdf = await pdfjs.getDocument({ data: documentBytes.slice(), isEvalSupported: false }).promise;
        state.draftId = result.draftId; state.revision = Number(result.revision); state.documentId = result.documentId;
        if (result.config) {
            var restored = JSON.parse(result.config);
            ['title', 'recipients', 'fields', 'expirationDays', 'requireVerification', 'prefill', 'subject', 'message', 'delivery'].forEach(function (key) { if (restored[key] !== undefined) state[key] = restored[key]; });
        } else { state.title = result.title; state.fields = []; }
        state.pages = geometry; state.page = 1; state.selected = null; state.tool = null; state.dirty = false;
        state.owner = state.recipients[0].key;
        $('file-label').textContent = state.title + '.pdf'; $('page-controls').hidden = false;
        renderControls(); await renderPdf();
    }
    async function chooseUpload(file) {
        if (!file || busy) return;
        clearError(); setBusy(true, 'Opening your PDF…');
        try {
            if (!/\.pdf$/i.test(file.name) || file.size > 2097152) throw new Error('Choose a PDF file no larger than 2 MB.');
            var bytes = new Uint8Array(await file.arrayBuffer()); await validatePdf(bytes);
            if (state.draftId && state.dirty) await persistDraft();
            var result = await rpc('upload', [env.recordId, file.name, bytesToBase64(bytes)]);
            await applyDocument(result); state.dirty = true; notify('saved');
        } catch (err) { error(err); }
        finally { setBusy(false); }
    }
    async function openDraft(draftId) {
        clearError(); setBusy(true, 'Opening your draft…');
        try { await applyDocument(await rpc('load', [env.recordId, draftId])); state.step = 1; renderControls(); }
        catch (err) { error(err); } finally { setBusy(false); }
    }
    async function renderPdf() {
        if (!pdf) return;
        var run = ++renderSequence;
        if (renderTask) { try { renderTask.cancel(); } catch (_err) { /* already finished */ } }
        pageModel = await pdf.getPage(state.page);
        if (run !== renderSequence) return;
        var base = pageModel.getViewport({ scale: 1 });
        var width = Math.max(160, $('viewport').clientWidth - (window.innerWidth < 700 ? 24 : 44));
        viewport = pageModel.getViewport({ scale: Math.min(1.65, width / base.width) });
        $('viewport').innerHTML = '<div class="paper" id="paper"><canvas id="pdf-canvas" aria-label="PDF page ' + state.page + '"></canvas><div class="overlay" id="overlay"></div></div>';
        $('paper').style.width = viewport.width + 'px'; $('paper').style.height = viewport.height + 'px';
        var canvas = $('pdf-canvas'), ratio = Math.min(window.devicePixelRatio || 1, 2);
        canvas.width = Math.floor(viewport.width * ratio); canvas.height = Math.floor(viewport.height * ratio);
        canvas.style.width = viewport.width + 'px'; canvas.style.height = viewport.height + 'px';
        renderTask = pageModel.render({ canvasContext: canvas.getContext('2d'), viewport: viewport, transform: [ratio, 0, 0, ratio, 0, 0] });
        try { await renderTask.promise; } catch (err) { if (err.name !== 'RenderingCancelledException') throw err; }
        if (run !== renderSequence) return;
        $('page-label').textContent = 'Page ' + state.page + ' of ' + pdf.numPages;
        $('previous-page').disabled = state.page === 1; $('next-page').disabled = state.page === pdf.numPages;
        $('overlay').addEventListener('click', placeField); renderFields();
    }
    function screenRect(field) {
        if (!viewport) return { x: 0, y: 0, width: 100, height: 35 };
        var box = viewport.convertToViewportRectangle([field.x, field.y, field.x + field.width, field.y + field.height]);
        return { x: Math.min(box[0], box[2]), y: Math.min(box[1], box[3]), width: Math.abs(box[2] - box[0]), height: Math.abs(box[3] - box[1]) };
    }
    function assignScreenRect(field, rect) {
        rect.width = Math.max(12, Math.min(rect.width, viewport.width)); rect.height = Math.max(12, Math.min(rect.height, viewport.height));
        rect.x = Math.max(0, Math.min(rect.x, viewport.width - rect.width)); rect.y = Math.max(0, Math.min(rect.y, viewport.height - rect.height));
        var a = viewport.convertToPdfPoint(rect.x, rect.y), b = viewport.convertToPdfPoint(rect.x + rect.width, rect.y + rect.height);
        field.x = Math.min(a[0], b[0]); field.y = Math.min(a[1], b[1]); field.width = Math.abs(a[0] - b[0]); field.height = Math.abs(a[1] - b[1]);
    }
    function placeField(event) {
        if (state.step !== 2 || !state.tool || event.target.closest('[data-field]')) return;
        if (state.fields.length >= 100) return error(new Error('Use no more than 100 fields.'));
        var box = $('overlay').getBoundingClientRect();
        var field = { id: 'field-' + Date.now() + '-' + Math.random().toString(36).slice(2, 7), recipientKey: state.owner, type: state.tool, page: state.page };
        assignScreenRect(field, { x: event.clientX - box.left, y: event.clientY - box.top, width: Math.min(180, viewport.width * 0.45), height: 44 });
        state.fields.push(field); state.selected = field.id; state.tool = null; changed(); renderControls();
    }
    function paintField(button, field) {
        var rect = screenRect(field);
        button.style.left = rect.x + 'px'; button.style.top = rect.y + 'px'; button.style.width = rect.width + 'px'; button.style.height = rect.height + 'px';
    }
    function renderFields() {
        if (!$('overlay') || !viewport) return;
        $('overlay').innerHTML = '';
        if (state.step < 2) return;
        state.fields.filter(function (field) { return field.page === state.page; }).forEach(function (field) {
            var personIndex = state.recipients.findIndex(function (person) { return person.key === field.recipientKey; });
            var person = state.recipients[personIndex], button = document.createElement('button');
            button.type = 'button'; button.dataset.field = field.id;
            button.className = 'field' + (state.selected === field.id ? ' selected' : '');
            button.setAttribute('aria-label', (person.name || 'Recipient ' + (personIndex + 1)) + ' ' + types[field.type]);
            button.style.borderColor = colors[personIndex % colors.length]; button.style.color = colors[personIndex % colors.length];
            button.innerHTML = escapeHtml(types[field.type]) + '<span class="owner">' + escapeHtml(person.name || 'Recipient ' + (personIndex + 1)) + '</span>';
            paintField(button, field); $('overlay').appendChild(button);
            button.addEventListener('click', function (event) { event.stopPropagation(); if (state.step === 2) { state.selected = field.id; renderControls(); } });
            if (state.step !== 2) { button.disabled = true; return; }
            button.addEventListener('pointerdown', function (event) {
                event.stopPropagation(); if (event.button !== 0) return;
                state.selected = field.id;
                $('controls').innerHTML = fieldControls(); wireControls();
                $('overlay').querySelectorAll('.field').forEach(function (item) { item.classList.toggle('selected', item.dataset.field === field.id); });
                var start = screenRect(field), sx = event.clientX, sy = event.clientY;
                button.setPointerCapture(event.pointerId);
                function move(ev) { assignScreenRect(field, { x: start.x + ev.clientX - sx, y: start.y + ev.clientY - sy, width: start.width, height: start.height }); paintField(button, field); }
                function stop() { button.removeEventListener('pointermove', move); button.removeEventListener('pointerup', stop); button.removeEventListener('pointercancel', stop); changed(); }
                button.addEventListener('pointermove', move); button.addEventListener('pointerup', stop); button.addEventListener('pointercancel', stop);
            });
            button.addEventListener('keydown', function (event) {
                var shifts = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
                if (event.key === 'Delete' || event.key === 'Backspace') { event.preventDefault(); removeField(field.id); return; }
                if (!shifts[event.key]) return;
                event.preventDefault(); var rect = screenRect(field), amount = event.shiftKey ? 10 : 2;
                rect.x += shifts[event.key][0] * amount; rect.y += shifts[event.key][1] * amount;
                assignScreenRect(field, rect); paintField(button, field); changed();
            });
        });
    }
    function removeField(id) { state.fields = state.fields.filter(function (f) { return f.id !== id; }); state.selected = null; changed(); renderControls(); }
    function wireControls() {
        if ($('choose-file')) $('choose-file').onclick = function () { $('upload').click(); };
        if ($('upload')) $('upload').onchange = function (event) { chooseUpload(event.target.files[0]); };
        if ($('drop')) { $('drop').ondragover = function (e) { e.preventDefault(); $('drop').classList.add('dragging'); }; $('drop').ondragleave = function () { $('drop').classList.remove('dragging'); }; $('drop').ondrop = function (e) { e.preventDefault(); chooseUpload(e.dataTransfer.files[0]); }; }
        document.querySelectorAll('[data-file]').forEach(function (button) { button.onclick = async function () {
            clearError(); setBusy(true, 'Preparing the selected PDF…');
            try {
                if (state.draftId && state.dirty) await persistDraft();
                await applyDocument(await rpc('select', [env.recordId, button.dataset.file])); changed(); notify('saved');
            }
            catch (err) { error(err); } finally { setBusy(false); }
        }; });
        document.querySelectorAll('[data-person]').forEach(function (input) { input.oninput = function () { var person = state.recipients.find(function (p) { return p.key === input.dataset.person; }); person[input.dataset.property] = input.value; person.contactId = null; changed(); }; });
        document.querySelectorAll('[data-contact]').forEach(function (input) { input.oninput = function () {
            clearTimeout(contactTimer); var query = input.value, personKey = input.dataset.contact, resultBox = input.nextElementSibling;
            if (query.length < 2) { resultBox.hidden = true; return; }
            contactTimer = setTimeout(async function () {
                try {
                    var contacts = await rpc('contacts', [env.recordId, query]);
                    if (input.value !== query || !input.isConnected) return;
                    resultBox.innerHTML = ''; resultBox.hidden = contacts.length === 0;
                    contacts.forEach(function (contact) { var b = document.createElement('button'); b.textContent = contact.Name + (contact.Email ? ' · ' + contact.Email : ''); b.onclick = function () { var person = state.recipients.find(function (p) { return p.key === personKey; }); person.name = contact.Name; person.email = contact.Email || ''; person.contactId = contact.Id; changed(); renderControls(); }; resultBox.appendChild(b); });
                } catch (err) { error(err); }
            }, 250);
        }; });
        if ($('add-person')) $('add-person').onclick = function () { state.recipients.push({ key: 'recipient-' + Date.now(), name: '', email: '' }); changed(); renderControls(); };
        document.querySelectorAll('[data-remove-person]').forEach(function (button) { button.onclick = function () { var key = button.dataset.removePerson; state.recipients = state.recipients.filter(function (p) { return p.key !== key; }); state.fields = state.fields.filter(function (f) { return f.recipientKey !== key; }); state.owner = state.recipients[0].key; changed(); renderControls(); }; });
        if ($('field-owner')) $('field-owner').onchange = function (event) { state.owner = event.target.value; state.selected = null; renderControls(); };
        document.querySelectorAll('[data-tool]').forEach(function (button) { button.onclick = function () { state.tool = button.dataset.tool; state.selected = null; renderControls(); }; });
        if ($('delete-field')) $('delete-field').onclick = function () { removeField(state.selected); };
        ['width', 'height'].forEach(function (axis) { var input = $('field-' + axis); if (input) input.oninput = function () { var field = selectedField(), rect = screenRect(field); rect[axis] = Number(input.value); assignScreenRect(field, rect); renderFields(); changed(); }; });
        document.querySelectorAll('[data-setting]').forEach(function (input) { input.oninput = function () { state[input.dataset.setting] = input.value; changed(); }; });
        if ($('verification')) $('verification').onchange = function (event) { state.requireVerification = event.target.value === 'inherit' ? null : event.target.value === 'yes'; changed(); };
        if ($('delivery')) $('delivery').onchange = function (event) { state.delivery = event.target.value; changed(); renderControls(); };
    }
    async function persistDraft() {
        state.revision = await rpc('save', [env.recordId, state.draftId, state.revision, JSON.stringify(config())]);
        state.dirty = false; notify('saved');
    }
    async function save() {
        if (!state.draftId || busy) return;
        clearError(); setBusy(true, 'Saving your draft…');
        try { await persistDraft(); }
        catch (err) { error(err); } finally { setBusy(false); }
    }
    async function send() {
        if (!canAdvance() || busy) return;
        clearError(); setBusy(true, 'Creating your signature request…');
        try {
            var result = await rpc('send', [env.recordId, state.draftId, state.revision, JSON.stringify(config())]);
            showResult(result); notify('sent');
        } catch (err) { error(err); } finally { setBusy(false); }
    }
    function showResult(result) {
        var html = '<section class="success"><h2>' + (result.delivery === 'preview' ? 'Your signing preview is ready' : 'Signature request created') + '</h2><p>' + escapeHtml(result.title) + '</p>';
        if (result.delivery === 'preview') html += '<div class="notice">These links require Salesforce login. Sign as the first recipient, then open the next recipient’s link. External signing requires a public signing site.</div>';
        if (result.emailStatus) html += '<p class="small">' + escapeHtml(result.emailStatus) + '</p>';
        (result.signers || []).forEach(function (signer, index) { html += '<div class="signer-result"><span class="avatar">' + (index + 1) + '</span><div class="grow"><strong>' + escapeHtml(signer.signerName) + '</strong><div class="small">' + escapeHtml(signer.signerEmail) + '</div></div><a href="' + escapeHtml(signer.signerUrl) + '" target="_blank" rel="noopener noreferrer">' + (result.delivery === 'preview' ? 'Open signing preview' : 'Open signing link') + '</a></div>'; });
        html += '<p class="small">The completed PDF will appear in this record’s Files.</p><button id="another" class="primary">Prepare another document</button></section>';
        $('app').innerHTML = html; $('another').onclick = function () {
            if (env.parentOrigin) notify('new-request');
            else { var url = new URL(window.location.href); url.searchParams.delete('draftId'); window.location.assign(url.toString()); }
        };
        // Footer controls no longer exist after success.
        busy = false; $('busy').hidden = true;
    }
    document.querySelectorAll('[data-step]').forEach(function (button) { button.onclick = function () {
        if (busy) return;
        var next = Number(button.dataset.step);
        if (next > 0 && !state.documentId) return error(new Error('Choose a PDF first.'));
        if (next > 1 && (state.recipients.some(function (p) { return !p.name.trim() || !p.email.trim(); }))) return error(new Error('Add names and emails before placing fields.'));
        clearError(); state.step = next; state.tool = null; renderControls();
    }; });
    $('save').onclick = save;
    $('back').onclick = function () { if (!busy) { state.step = Math.max(0, state.step - 1); clearError(); renderControls(); } };
    $('next').onclick = function () { if (state.step === 3) send(); else if (canAdvance()) { state.step++; clearError(); renderControls(); } };
    function changePage(delta) {
        if (!pdf || busy || state.page + delta < 1 || state.page + delta > pdf.numPages) return;
        state.page += delta; state.selected = null; state.tool = null;
        renderControls(); renderPdf().catch(error);
    }
    $('previous-page').onclick = function () { changePage(-1); };
    $('next-page').onclick = function () { changePage(1); };
    new ResizeObserver(function () { var width = $('viewport') && $('viewport').clientWidth; if (width && Math.abs(width - lastWidth) > 2) { lastWidth = width; if (pdf) renderPdf().catch(error); } }).observe($('viewport'));
    // Success replaces the shell, so the final busy cleanup must tolerate missing controls.
    var originalUpdateFooter = updateFooter;
    updateFooter = function () { if ($('next')) originalUpdateFooter(); };
    window.addEventListener('message', function (event) {
        var message = event.data;
        if (event.source !== window.parent || event.origin !== env.parentOrigin || !message ||
            message.channel !== 'portwood-signatures' || message.nonce !== env.nonce ||
            message.action !== 'source' || (message.value !== 'upload' && message.value !== 'files') || !$('controls')) return;
        if (busy) pendingSource = message.value;
        else switchSource(message.value);
    });
    (async function () {
        setBusy(true, 'Loading document preparation…');
        try {
            var loaded = await Promise.all([rpc('context', [env.recordId]), import(env.moduleUrl)]);
            context = loaded[0]; pdfjs = loaded[1]; pdfjs.GlobalWorkerOptions.workerSrc = env.workerUrl;
            state.delivery = context.publicSite ? 'links' : 'preview';
            renderControls();
            if (env.draftId) await openDraft(env.draftId);
        } catch (err) { error(err); }
        finally { setBusy(false); notify('ready'); }
    })();
})();
