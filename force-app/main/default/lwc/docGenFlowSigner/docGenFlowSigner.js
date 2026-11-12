import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent, FlowNavigationNextEvent, FlowNavigationFinishEvent } from 'lightning/flowSupport';
import { loadScript } from 'lightning/platformResourceLoader';
import isGuest from '@salesforce/user/isGuest';
import PDFLIB from '@salesforce/resourceUrl/pdflib';
import PDFJS_CLASSIC from '@salesforce/resourceUrl/pdfjs4classic';
import getSignerStatus from '@salesforce/apex/DocGenFlowSigningController.getSignerStatus';
import validateToken from '@salesforce/apex/DocGenSignatureController.validateToken';
import sendPin from '@salesforce/apex/DocGenSignatureController.sendPin';
import verifyPin from '@salesforce/apex/DocGenSignatureController.verifyPin';
import getSourcePdfBase64 from '@salesforce/apex/DocGenSignatureController.getSourcePdfBase64';
import getSignerPlacements from '@salesforce/apex/DocGenSignatureController.getSignerPlacements';
import signPlacement from '@salesforce/apex/DocGenSignatureController.signPlacement';
import getSignatureCertificate from '@salesforce/apex/DocGenSignatureController.getSignatureCertificate';
import saveCompositedSignedPdf from '@salesforce/apex/DocGenSignatureController.saveCompositedSignedPdf';
import savePdfSignature from '@salesforce/apex/DocGenSignatureController.savePdfSignature';
import declineSignature from '@salesforce/apex/DocGenSignatureController.declineSignature';
import {
    parseToken,
    classifyStatus,
    assessSupport,
    locateAnchors,
    buildSpots,
    compositeSignedPdf,
    installCloneShim,
    b64ToBytes,
    bytesToB64,
    isWinAnsiSafe,
    formatPickedDate,
    validateFormValues,
    formFieldNeedles,
    restoreLostMarks,
    initialsOf,
    safeColor,
    hexToRgba,
    safeUrl,
    MAX_COMPOSITE_BASE64_CHARS
} from './signerCore';
import { createDrawPad } from './drawPad';

// Same wording as the signing page, so the legal text is identical.
const CONSENT_TEXT =
    'I agree to sign this document electronically. I understand that my typed name constitutes my legal ' +
    'electronic signature, and I consent to conducting this transaction electronically.';
const MAX_PAGE_SCALE = 1.8;
const DEFAULT_BRAND = '#0176d3';
const CHIP_LABEL = { Full: 'SIGN HERE', Initials: 'INITIAL HERE', Date: 'DATE', DatePick: 'DATE' };

/**
 * Sign a document inside a Screen Flow, in the same tab.
 *
 * Behaves like the signing page (pages/DocGenSignaturePdf.page) and differs only in being embedded:
 * it calls the same signing server code (DocGenSignatureController @AuraEnabled methods) in the same
 * order, so the audit trail is identical: same audit row, SHA-256 of the composited bytes,
 * immutability triggers, Certificate of Completion, completion emails. Covered, as on the page:
 * guided on-document fields (Full, Initials, Date, DatePick), draw or type, type-only mode, signer
 * form fields, the email-PIN step, decline, branding, multi-signer progress, returning signers, and
 * documents with no fields (typed-name signing). The one thing it refuses is a prepared uploaded
 * PDF (see signerCore.assessSupport).
 *
 * The Flow only advances after the server confirms the outcome (signed or declined), and validate()
 * blocks Next until then; never on a timer or a status poll.
 */
export default class DocGenFlowSigner extends LightningElement {
    /** The signing URL from Create Signature Request's Signer URLs (the token is read from it). */
    @api signerUrl;
    /** Or the whole Signer URLs collection; the first entry is used. */
    @api signerUrls;
    /** Or the signer token itself. */
    @api token;
    /**
     * By default the Flow moves on as soon as the outcome is confirmed. Set this true to make the
     * signer select Next themselves instead. (Inverted from "autoAdvance" because an LWC Boolean
     * @api property may not default to true.)
     */
    @api waitForNext = false;

    @api signed = false;
    @api declined = false;
    @api requestComplete = false;
    @api signerStatus;
    @api errorMessage;

    @api
    get availableActions() {
        return this._actions;
    }
    set availableActions(v) {
        this._actions = Array.isArray(v) ? v : [];
        this._tryAdvance();
    }

    /** Flow calls this before Next/Finish. Nothing proceeds until the server has recorded the outcome. */
    @api
    validate() {
        if (this.signed || this.declined) return { isValid: true };
        return {
            isValid: false,
            errorMessage:
                this.state === 'error' || this.state === 'guest'
                    ? this.errorText || 'Signing is not available.'
                    : 'Please complete signing before continuing.'
        };
    }

    // ---- view state
    state = 'loading'; // loading | verify | guest | error | signed | declined | ready | submitting | done
    loadingText = 'Loading your document...';
    errorTitle = 'Signature Error';
    errorText = '';
    canRetry = false;
    bannerText = '';
    noticeText = '';
    documentTitle = '';
    signerName = '';
    roleName = '';
    signerProgress = '';
    brandName = '';
    brandLogoUrl = '';
    brandColor = DEFAULT_BRAND;
    signedCount = 0;
    totalCount = 0;
    allSigned = false;
    legacy = false;
    legacyName = '';
    activeSpot = null;
    typedValue = '';
    dateValue = '';
    captureError = '';
    captureBusy = false;
    padInked = false;
    consentChecked = false;
    waitingOn = 0;
    // signer form fields
    formFields = [];
    formStep = false;
    // email PIN
    pinEmail = '';
    pinPlaceholder = 'Enter your email address';
    pinCode = '';
    pinSent = false;
    pinMsg = '';
    pinMsgError = false;
    pinBusy = false;
    resendLabel = 'Resend code';
    resendDisabled = false;
    // decline
    showDeclinePanel = false;
    declineReason = '';
    declineBusy = false;

    _actions = [];
    _alive = false;
    _token;
    _status;
    _signerData;
    _sourceBytes;
    _spots = [];
    _pagesByNum = {};
    _pageList = [];
    _formDefs = [];
    _formValues = {};
    _formFieldJson = '{}';
    _ffHits = [];
    _io;
    _pad;
    _padCanvas;
    _padNeedsResize = false;
    _pendingAdvance = false;
    _resendTimer;

    // ---------------------------------------------------------------- lifecycle

    connectedCallback() {
        this._alive = true;
        this._init();
    }

    disconnectedCallback() {
        this._alive = false;
        if (this._io) this._io.disconnect();
        if (this._resendTimer) clearInterval(this._resendTimer);
    }

    renderedCallback() {
        if (this.showPad) this._ensurePad();
    }

    // ---------------------------------------------------------------- template getters

    get isLoading() {
        return this.state === 'loading';
    }
    get isVerifyState() {
        return this.state === 'verify';
    }
    get isGuestState() {
        return this.state === 'guest';
    }
    get isErrorState() {
        return this.state === 'error';
    }
    get isSignedState() {
        return this.state === 'signed';
    }
    get isDeclinedState() {
        return this.state === 'declined';
    }
    get isSubmitting() {
        return this.state === 'submitting';
    }
    get isDone() {
        return this.state === 'done';
    }
    get isReady() {
        return this.state === 'ready';
    }
    get showViewer() {
        return this.state === 'loading' || this.state === 'ready' || this.state === 'submitting';
    }
    // The pages container is always in the DOM (hidden, not removed) so the manually-built
    // viewer is never torn down by a state change.
    get viewerClass() {
        return this.showViewer ? 'viewer' : 'viewer hidden';
    }
    get rootStyle() {
        return '--pw-brand:' + this.brandColor + ';';
    }
    get hasBrand() {
        return !!(this.brandName || this.brandLogoUrl);
    }
    get hasRole() {
        return !!this.roleName;
    }
    get hasProgressLabel() {
        return !!this.signerProgress;
    }
    get showHeader() {
        return this.isReady || this.isSubmitting;
    }
    get showDeclineButton() {
        return (
            this.isReady &&
            !this.showDeclinePanel &&
            !!(this._signerData && this._signerData.showDecline) &&
            !this.activeSpot
        );
    }
    get showFieldCounter() {
        return !this.legacy && this.totalCount > 0;
    }
    // Signing steps are hidden while the form-field step or the decline confirmation is up.
    get signingOpen() {
        return this.isReady && !this.formStep && !this.showDeclinePanel;
    }
    get showStart() {
        return this.signingOpen && !this.legacy && !this.activeSpot && !this.allSigned && this.totalCount > 0;
    }
    get startLabel() {
        return this.signedCount === 0
            ? 'Start Signing'
            : 'Next Field (' + (this.signedCount + 1) + ' of ' + this.totalCount + ')';
    }
    get progressText() {
        return this.signedCount + ' of ' + this.totalCount + ' fields completed';
    }
    get showCapture() {
        return this.signingOpen && !!this.activeSpot;
    }
    get showConsent() {
        return this.signingOpen && !this.legacy && this.allSigned && !this.activeSpot;
    }
    get showLegacy() {
        return this.signingOpen && this.legacy;
    }
    get isDatePick() {
        return !!this.activeSpot && this.activeSpot.placement.type === 'DatePick';
    }
    get typeOnly() {
        return !!(this._signerData && this._signerData.typeOnly);
    }
    // A signature or initials field offers the draw pad AND the typed field together (as the signing
    // page does); a drawn mark wins when present. Type-only requests never offer the pad.
    get showPad() {
        return !!this.activeSpot && !this.isDatePick && !this.typeOnly;
    }
    get showTyped() {
        return !!this.activeSpot && !this.isDatePick;
    }
    get captureTitle() {
        if (!this.activeSpot) return '';
        if (this.isDatePick) return 'Select a Date';
        return this.activeSpot.placement.type === 'Initials' ? 'Add Initials' : 'Sign Here';
    }
    get captureSubtitle() {
        if (!this.activeSpot) return '';
        if (this.isDatePick) return 'Choose the date for this field.';
        return this.activeSpot.placement.type === 'Initials'
            ? 'Type your initials for this field.'
            : 'Type your full name to sign this field.';
    }
    get typedLabel() {
        return this.activeSpot && this.activeSpot.placement.type === 'Initials'
            ? 'Your initials'
            : 'Type your full name to sign';
    }
    get saveDisabled() {
        if (this.captureBusy) return true;
        if (this.isDatePick) return !this.dateValue;
        return !(this.padInked || (this.typedValue || '').trim());
    }
    get consentSubtitle() {
        return (
            "You've completed all " +
            this.totalCount +
            ' field' +
            (this.totalCount > 1 ? 's' : '') +
            '. Confirm your consent to finalize.'
        );
    }
    get consentText() {
        return CONSENT_TEXT;
    }
    get submitDisabled() {
        return !this.consentChecked;
    }
    get legacyDisabled() {
        return !this.consentChecked || !(this.legacyName || '').trim();
    }
    get pinMsgClass() {
        return this.pinMsgError ? 'field-error' : 'pin-ok';
    }
    get verifyDisabled() {
        return this.pinBusy || !(this.pinCode || '').trim();
    }
    get doneTitle() {
        return this.requestComplete || this.waitingOn === 0 ? 'Signature Complete' : 'Signature Recorded';
    }
    get doneDetail() {
        if (this.waitingOn > 0) {
            return (
                'Your signature has been recorded. Waiting for ' +
                this.waitingOn +
                ' more signer' +
                (this.waitingOn > 1 ? 's' : '') +
                ' to complete.'
            );
        }
        return 'Your document has been signed and processed securely.';
    }
    get signedDetail() {
        return this.requestComplete
            ? 'All signatures on this document are complete.'
            : 'Your signature is already recorded. Other signers may still be completing the document.';
    }
    get showContinueHint() {
        return (this.isDone || this.isSignedState || this.isDeclinedState) && !this._canNavigate();
    }

    // ---------------------------------------------------------------- startup

    async _init() {
        this.state = 'loading';
        this.loadingText = 'Loading your document...';
        this.errorText = '';
        this.canRetry = false;
        if (isGuest) {
            this._fail(
                'guest',
                'Signing here is only available to signed-in users. Please sign in to continue.',
                false
            );
            return;
        }
        const first = Array.isArray(this.signerUrls) && this.signerUrls.length ? this.signerUrls[0] : undefined;
        const token = parseToken(this.signerUrl || first, this.token);
        if (!token) {
            this._fail(
                'error',
                'No valid signing link was provided to this screen. Pass the Signer URL from Create Signature Request.',
                false,
                "This screen isn't set up to sign"
            );
            return;
        }
        this._token = token;
        try {
            const status = await getSignerStatus({ token });
            if (!this._alive) return;
            this._status = status;
            const kind = classifyStatus(status);
            if (kind === 'signed') {
                this._markSigned(status.requestComplete, true, 0);
                return;
            }
            if (kind === 'unavailable') {
                this._fail('error', await this._serverMessage('This signature request is no longer available.'), false);
                return;
            }
            if (kind === 'expired') {
                this._fail(
                    'error',
                    await this._serverMessage('This signature link has expired. Please request a new one.'),
                    false
                );
                return;
            }
            const early = assessSupport({ status });
            if (!early.ok) {
                this._fail('error', early.message, false, "This document can't be signed here");
                return;
            }
            const signerData = await validateToken({ token });
            if (!this._alive) return;
            this._applyBrand(signerData);
            if (!signerData || !signerData.isValid) {
                this._fail(
                    'error',
                    (signerData && signerData.errorMessage) || 'This signing link is not valid.',
                    false
                );
                return;
            }
            this._signerData = signerData;
            this.signerName = signerData.signerName || '';
            this.roleName = signerData.roleName || '';
            this.documentTitle = signerData.documentTitle || 'Document';
            this._formDefs = Array.isArray(signerData.formFields) ? signerData.formFields : [];
            if (signerData.isSignerToken && (signerData.totalSigners || 0) > 1) {
                this.signerProgress =
                    'Signer ' + ((signerData.signedCount || 0) + 1) + ' of ' + signerData.totalSigners;
            }
            if (signerData.requiresPin) {
                this._enterVerify(signerData);
                return;
            }
            await this._loadDocument();
        } catch (e) {
            if (!this._alive) return;
            this._fail('error', this._errText(e), true);
        }
    }

    /**
     * The signing page shows the server's own wording for a link that cannot be used (expired,
     * cancelled, ...), so a Flow signer sees the same message. Falls back to ours if the server has none.
     */
    async _serverMessage(fallback) {
        try {
            const v = await validateToken({ token: this._token });
            return (v && v.errorMessage) || fallback;
        } catch (e) {
            return fallback;
        }
    }

    /** Brand color, name and logo from the signing brand, validated before they reach a style or an <img>. */
    _applyBrand(data) {
        if (!data) return;
        this.brandColor = safeColor(data.brandColor) || DEFAULT_BRAND;
        this.brandName = data.brandName || '';
        this.brandLogoUrl = safeUrl(data.brandLogoUrl);
    }

    async _loadDocument() {
        this.state = 'loading';
        this.loadingText = 'Loading your document...';
        try {
            const token = this._token;
            const [src, placements] = await Promise.all([
                getSourcePdfBase64({ token }),
                getSignerPlacements({ token }),
                this._loadLibs()
            ]).then((r) => [r[0], r[1]]);
            if (!this._alive) return;
            if (!src || !src.base64) {
                this._fail('error', 'The document could not be loaded. Please try again, or contact the sender.', true);
                return;
            }
            const pdfRevision =
                src.pdfRevision !== undefined && src.pdfRevision !== null ? Number(src.pdfRevision) : null;
            const full = assessSupport({ status: this._status, placements, pdfRevision });
            if (!full.ok) {
                this._fail('error', full.message, false, "This document can't be signed here");
                return;
            }
            if (src.base64.length > MAX_COMPOSITE_BASE64_CHARS * 0.85) {
                this._fail(
                    'error',
                    "This document is too large to sign inside a Flow. Please open the sender's signing link instead.",
                    false,
                    "This document can't be signed here"
                );
                return;
            }
            await this._buildViewer(src.base64, placements, full.legacy);
        } catch (e) {
            if (!this._alive) return;
            this._fail('error', this._errText(e), true);
        }
    }

    async _loadLibs() {
        if (!window.PDFLib || !window.__portwoodPdfjs || !window.pdfjsWorker) {
            await Promise.all([
                loadScript(this, PDFLIB + '/pdf-lib.min.js'),
                loadScript(this, PDFJS_CLASSIC + '/pdf.classic.js'),
                loadScript(this, PDFJS_CLASSIC + '/pdf.worker.classic.js')
            ]);
        }
        if (!window.PDFLib || !window.__portwoodPdfjs || !window.pdfjsWorker) {
            throw new Error('The signing libraries could not be loaded.');
        }
        installCloneShim(window);
    }

    // ---------------------------------------------------------------- email verification (PIN)

    _enterVerify(signerData) {
        this.state = 'verify';
        this.pinMsg = '';
        this.pinSent = false;
        this.pinCode = '';
        this.pinEmail = '';
        if (signerData.signerEmail && signerData.signerEmail.indexOf('@') > 0) {
            const parts = signerData.signerEmail.split('@');
            this.pinPlaceholder = 'Enter: ' + parts[0].substring(0, 2) + '***@' + parts[1];
        }
        // Pre-fill: skip the "type your email" step and send to the address on record. The code
        // still goes only to the real inbox.
        if (signerData.prefillEmail && signerData.signerEmail) {
            this.pinEmail = signerData.signerEmail;
            this.handleSendPin();
        }
    }

    handlePinEmail(e) {
        this.pinEmail = e.detail.value;
    }
    handlePinCode(e) {
        this.pinCode = e.detail.value;
    }
    handlePinKey(e) {
        if (e.key === 'Enter') this.handleVerifyPin();
    }

    async handleSendPin() {
        const email = (this.pinEmail || '').trim();
        if (!email) {
            this._pinMessage('Please enter your email address.', true);
            return;
        }
        this.pinBusy = true;
        try {
            const res = await sendPin({ token: this._token, email });
            if (res && res.success) {
                this.pinSent = true;
                this._pinMessage(res.message || 'A verification code was sent.', false);
                this._startResendTimer();
            } else {
                this._pinMessage((res && res.message) || 'Failed to send verification code.', true);
            }
        } catch (e) {
            this._pinMessage(this._errText(e), true);
        } finally {
            this.pinBusy = false;
        }
    }

    async handleResendPin() {
        if (this.resendDisabled) return;
        try {
            const res = await sendPin({ token: this._token, email: (this.pinEmail || '').trim() });
            if (res && res.success) {
                this._pinMessage('New verification code sent.', false);
                this._startResendTimer();
            } else {
                this._pinMessage((res && res.message) || 'Failed to resend code.', true);
            }
        } catch (e) {
            this._pinMessage(this._errText(e), true);
        }
    }

    async handleVerifyPin() {
        const pin = (this.pinCode || '').trim();
        if (pin.length !== 6) {
            this._pinMessage('Please enter the 6-digit code from your email.', true);
            return;
        }
        this.pinBusy = true;
        try {
            const res = await verifyPin({ token: this._token, pin });
            if (res && res.success) {
                if (this._resendTimer) clearInterval(this._resendTimer);
                await this._loadDocument();
            } else {
                this._pinMessage((res && res.message) || 'Verification failed.', true);
            }
        } catch (e) {
            this._pinMessage(this._errText(e), true);
        } finally {
            this.pinBusy = false;
        }
    }

    _pinMessage(text, isError) {
        this.pinMsg = text;
        this.pinMsgError = isError;
    }

    _startResendTimer() {
        if (this._resendTimer) clearInterval(this._resendTimer);
        let seconds = 60;
        this.resendDisabled = true;
        this.resendLabel = 'Resend code (' + seconds + 's)';
        this._resendTimer = setInterval(() => {
            seconds--;
            if (seconds <= 0) {
                clearInterval(this._resendTimer);
                this.resendDisabled = false;
                this.resendLabel = 'Resend code';
            } else {
                this.resendLabel = 'Resend code (' + seconds + 's)';
            }
        }, 1000);
    }

    // ---------------------------------------------------------------- viewer

    async _buildViewer(base64, placements, legacy) {
        const lib = window.__portwoodPdfjs;
        lib.GlobalWorkerOptions.workerSrc = PDFJS_CLASSIC + '/pdf.worker.classic.js';
        const bytes = b64ToBytes(base64);
        this._sourceBytes = bytes; // pdf-lib composites onto these
        this.loadingText = 'Preparing the document...';
        // isEvalSupported:false keeps the CVE-2024-4367 font path off (same as the signing page).
        const pdf = await lib.getDocument({ data: bytes.slice(), isEvalSupported: false, useWorkerFetch: false })
            .promise;
        const container = this.template.querySelector('.pdf-pages');
        while (container.firstChild) container.removeChild(container.firstChild);
        this._pagesByNum = {};
        this._pageList = [];

        if ('IntersectionObserver' in window) {
            this._io = new IntersectionObserver(
                (entries) =>
                    entries.forEach((en) => en.isIntersecting && this._renderPage(Number(en.target.dataset.page))),
                // root is the document's scroll area, so rootMargin pre-renders pages just off-screen
                { root: this.template.querySelector('.viewer'), rootMargin: '600px 0px' }
            );
        }
        const avail = Math.max(320, (container.clientWidth || 640) - 28);
        for (let p = 1; p <= pdf.numPages; p++) {
            const page = await pdf.getPage(p);
            const base = page.getViewport({ scale: 1 });
            const viewport = page.getViewport({ scale: Math.min(MAX_PAGE_SCALE, avail / base.width) });
            const wrap = document.createElement('div');
            wrap.dataset.page = String(p);
            wrap.style.cssText =
                'position:relative;margin:0 auto 12px auto;background:#fff;box-shadow:0 1px 4px rgba(0,0,0,.35);' +
                'width:' +
                viewport.width +
                'px;height:' +
                viewport.height +
                'px;max-width:100%;';
            container.appendChild(wrap);
            const textContent = await page.getTextContent();
            const entry = { pageNum: p, page, viewport, textContent, wrap, rendered: false, rendering: false };
            this._pagesByNum[p] = entry;
            this._pageList.push(entry);
            if (this._io) this._io.observe(wrap);
            if (p === 1) await this._renderPage(1);
            // Let the browser paint between pages; the worker shares the main thread.
            await new Promise((r) => setTimeout(r, 0));
            if (!this._alive) return;
        }
        if (!this._io) {
            for (const e of this._pageList) await this._renderPage(e.pageNum);
        }

        // Signer form-field anchors (@@FF-key@@), located now so the answers can be stamped at finish.
        this._ffHits = this._formDefs.length ? locateAnchors(this._pageList, formFieldNeedles(this._formDefs)) : [];
        this.formFields = this._formDefs.map((d) => this._fieldModel(d));
        this.formStep = this._formDefs.length > 0;

        this.legacy = !!legacy;
        this._spots = [];
        if (!legacy) {
            const needles = [...new Set(placements.map((pl) => pl.tagText))];
            const hits = locateAnchors(this._pageList, needles);
            const built = buildSpots(placements, hits);
            if (!built.ok) {
                this._fail('error', built.message, false);
                return;
            }
            this._spots = built.spots;
            // Fields signed in an earlier session: a drawn mark's image is gone, so it falls back to
            // the signer's typed name (see restoreLostMarks); tell the signer rather than surprise them.
            const lost = restoreLostMarks(this._spots, this.signerName);
            this.noticeText = lost
                ? 'You started signing earlier. ' +
                  lost +
                  (lost > 1 ? ' fields you drew' : ' field you drew') +
                  ' in that session will be stamped with your typed name (' +
                  this.signerName +
                  ') instead.'
                : '';
            this._spots.forEach((s) => this._addChip(s));
        } else {
            this.legacyName = this.signerName;
        }
        this._recount();
        this.state = 'ready';
        this._refreshChips();
    }

    _fieldModel(d) {
        const type = d.type || 'text';
        return {
            key: d.key,
            labelText: (d.label || d.key) + (d.required ? ' *' : ''),
            type,
            isCheckbox: type === 'checkbox',
            isPicklist: type === 'picklist',
            isInput: type !== 'checkbox' && type !== 'picklist',
            htmlType: type === 'number' ? 'number' : type === 'date' ? 'date' : 'text',
            options: (d.choices || []).map((c) => ({ label: c, value: c })),
            value: '',
            checked: false,
            error: ''
        };
    }

    async _renderPage(pageNum) {
        const e = this._pagesByNum[pageNum];
        if (!e || e.rendered || e.rendering) return;
        e.rendering = true;
        try {
            const ratio = Math.min(window.devicePixelRatio || 1, 2.5);
            const rv = e.page.getViewport({ scale: e.viewport.scale * ratio });
            const canvas = document.createElement('canvas');
            canvas.width = Math.ceil(rv.width);
            canvas.height = Math.ceil(rv.height);
            canvas.style.cssText =
                'display:block;width:' + e.viewport.width + 'px;height:' + e.viewport.height + 'px;max-width:100%;';
            await e.page.render({ canvasContext: canvas.getContext('2d'), viewport: rv }).promise;
            e.wrap.insertBefore(canvas, e.wrap.firstChild);
            e.rendered = true;
        } catch (err) {
            e.rendering = false;
            this.bannerText =
                'Part of the document could not be displayed. You can still sign; please scroll to check each page.';
        }
    }

    // ---------------------------------------------------------------- signer form fields

    handleFormChange(e) {
        const key = e.target.dataset.key;
        const checkbox = e.target.type === 'checkbox';
        this.formFields = this.formFields.map((f) => {
            if (f.key !== key) return f;
            return checkbox
                ? { ...f, checked: e.target.checked, error: '' }
                : { ...f, value: e.detail.value, error: '' };
        });
    }

    handleFormContinue() {
        const raw = {};
        this.formFields.forEach((f) => {
            raw[f.key] = f.isCheckbox ? f.checked : f.value;
        });
        const res = validateFormValues(this._formDefs, raw);
        this.formFields = this.formFields.map((f) => ({ ...f, error: res.errors[f.key] || '' }));
        if (!res.valid) return;
        this._formValues = res.values;
        this._formFieldJson = JSON.stringify(res.values);
        this.formStep = false;
        // Fields are collected up front, before any signing; carry straight on into signing.
        if (!this.legacy && this._firstPending()) this.handleStart();
    }

    // ---------------------------------------------------------------- spots (the on-document fields)

    _addChip(spot) {
        const wrap = this._pagesByNum[spot.hit.page].wrap;
        const chip = document.createElement('div');
        chip.setAttribute('role', 'button');
        chip.setAttribute('tabindex', '0');
        const b = spot.hit.box;
        chip.style.cssText =
            'position:absolute;box-sizing:border-box;cursor:pointer;display:flex;align-items:center;justify-content:center;' +
            'left:' +
            b.x +
            'px;top:' +
            b.y +
            'px;width:' +
            Math.max(b.w, 56) +
            'px;height:' +
            Math.max(b.h, 22) +
            'px;' +
            'border:2px dashed ' +
            this.brandColor +
            ';background:' +
            hexToRgba(this.brandColor, 0.14) +
            ';color:#16324f;font:700 10px/1 Arial,sans-serif;' +
            'letter-spacing:.04em;border-radius:3px;overflow:hidden;';
        chip.textContent = CHIP_LABEL[spot.placement.type] || 'SIGN HERE';
        chip.addEventListener('click', () => this._onChip(spot));
        chip.addEventListener('keydown', (ev) => {
            if (ev.key === 'Enter' || ev.key === ' ') {
                ev.preventDefault();
                this._onChip(spot);
            }
        });
        wrap.appendChild(chip);
        spot.chip = chip;
        if (spot.signed) this._styleSigned(spot);
    }

    _styleSigned(spot) {
        const chip = spot.chip;
        // Let a longer value grow the chip (a date is wider than "SIGN HERE"), but never shrink
        // below the anchor it covers, so no tail of the @@SIG-n@@ text shows from underneath.
        const covered = chip.offsetWidth;
        chip.style.width = 'auto';
        chip.style.minWidth = covered + 'px';
        chip.style.height = 'auto';
        chip.style.minHeight = chip.style.minHeight || '22px';
        chip.style.padding = '0 4px';
        chip.style.overflow = 'visible';
        chip.style.border = '2px solid #2e844a';
        chip.style.background = 'rgba(255,255,255,.96)';
        chip.style.color = '#16324f';
        chip.style.boxShadow = 'none';
        chip.style.cursor = 'default';
        while (chip.firstChild) chip.removeChild(chip.firstChild);
        const tick = document.createElement('span');
        tick.textContent = '✓ ';
        tick.style.cssText = 'color:#2e844a;font-weight:700;margin-right:4px;';
        chip.appendChild(tick);
        if (spot.imageData) {
            const img = document.createElement('img');
            img.src = spot.imageData;
            img.style.cssText = 'max-height:100%;max-width:100%;display:block;';
            chip.appendChild(img);
        } else {
            const t = document.createElement('span');
            t.textContent = spot.value || spot.placement.signedValue || '';
            t.style.cssText = 'font:italic 13px Arial,sans-serif;white-space:nowrap;';
            chip.appendChild(t);
        }
    }

    _refreshChips() {
        const next = this._firstPending();
        this._spots.forEach((s) => {
            if (s.signed) return;
            const current = s === next;
            s.chip.style.boxShadow = current ? '0 0 0 3px ' + hexToRgba(this.brandColor, 0.45) : 'none';
            s.chip.style.background = hexToRgba(this.brandColor, current ? 0.26 : 0.14);
        });
    }

    _firstPending() {
        return this._spots.find((s) => !s.signed) || null;
    }

    _recount() {
        this.totalCount = this._spots.length;
        this.signedCount = this._spots.filter((s) => s.signed).length;
        this.allSigned = this.totalCount > 0 && this.signedCount === this.totalCount;
    }

    /**
     * Bring a field into view by scrolling the document's OWN scroll area, never the page.
     * scrollIntoView scrolls every ancestor, so the capture panel (which sits above the document)
     * would scroll out of sight while the signer is using it.
     */
    _scrollTo(spot) {
        const viewer = this.template.querySelector('.viewer');
        if (!spot || !spot.chip || !viewer) return;
        const c = viewer.getBoundingClientRect();
        const r = spot.chip.getBoundingClientRect();
        const top = viewer.scrollTop + (r.top - c.top) - viewer.clientHeight / 2 + r.height / 2;
        viewer.scrollTo({ top: Math.max(0, top), behavior: 'smooth' });
    }

    /** Merge the server's placement list back into our spots (it holds the stamped Date text). */
    _syncPlacements(list) {
        if (!Array.isArray(list)) return;
        list.forEach((pl) => {
            const spot = this._spots.find((s) => s.placement.id === pl.id);
            if (!spot) return;
            spot.placement.status = pl.status;
            spot.placement.signedValue = pl.signedValue;
            if (pl.status === 'Signed') spot.signed = true;
        });
    }

    // ---------------------------------------------------------------- capture

    handleStart() {
        const next = this._firstPending();
        if (!next) return;
        this._scrollTo(next);
        this._openCapture(next, true);
    }

    // A direct click on a field is the deliberate pace: a Date field fills in and the signer decides
    // what to open next.
    _onChip(spot) {
        if (spot.signed || !this.signingOpen) return;
        this._openCapture(spot, false);
    }

    _openCapture(spot, openNext) {
        this.bannerText = '';
        if (spot.placement.type === 'Date') {
            this._autoDate(spot, openNext);
            return;
        }
        this.activeSpot = spot;
        this.captureError = '';
        this.padInked = false;
        this.dateValue = '';
        const name = this.signerName || '';
        this.typedValue = spot.placement.type === 'Initials' ? initialsOf(name) : name;
        this._padNeedsResize = true;
        this._scrollTo(spot);
    }

    async _autoDate(spot, openNext) {
        try {
            const placements = await signPlacement({ token: this._token, placementId: spot.placement.id, value: '' });
            this._syncPlacements(placements);
            spot.signed = true;
            spot.imageData = null;
            spot.value = null;
            this._styleSigned(spot);
            this._recount();
            this._afterSpot(openNext);
        } catch (e) {
            this.bannerText =
                'The date could not be saved: ' + this._errText(e) + ' Click the date field to try again.';
        }
    }

    _ensurePad() {
        const cv = this.template.querySelector('canvas.pad');
        if (!cv) return;
        if (this._padCanvas !== cv) {
            this._padCanvas = cv;
            this._pad = createDrawPad(cv, () => {
                this.padInked = this._pad.hasInk();
            });
            this._padNeedsResize = true;
        }
        if (this._padNeedsResize) {
            this._pad.resize();
            this._padNeedsResize = false;
        }
    }

    handleTyped(e) {
        this.typedValue = e.target.value;
    }
    handleDate(e) {
        this.dateValue = e.detail.value;
    }
    handleClearPad() {
        if (this._pad) this._pad.clear();
        this.padInked = false;
    }
    handleCancelCapture() {
        this.activeSpot = null;
        this.captureError = '';
    }

    // "Save" saves and scrolls to the next field without opening it; "Save & Next" opens it.
    handleSave() {
        return this._saveCapture(false);
    }
    handleSaveNext() {
        return this._saveCapture(true);
    }

    async _saveCapture(openNext) {
        const spot = this.activeSpot;
        if (!spot || this.captureBusy) return;
        let serverValue;
        let imageData = null;
        let value = null;
        if (this.isDatePick) {
            const picked = formatPickedDate(this.dateValue);
            if (!picked) {
                this.captureError = 'Please choose a date.';
                return;
            }
            serverValue = picked;
            value = picked;
        } else if (this.showPad && this._pad && this._pad.hasInk()) {
            // A drawn mark wins over typed text, as on the signing page. Drawn marks store a
            // marker server-side; the image lives in the composited PDF.
            serverValue = 'Signed (drawn)';
            imageData = this._pad.toPng();
        } else {
            const typed = (this.typedValue || '').trim();
            if (!typed) {
                this.captureError =
                    'Please draw or type your ' + (spot.placement.type === 'Initials' ? 'initials.' : 'name.');
                return;
            }
            if (!isWinAnsiSafe(typed)) {
                this.captureError = this.typeOnly
                    ? "These characters can't be placed on the PDF. Please use only Latin letters."
                    : 'These characters cannot be placed on the PDF. Please draw your signature instead.';
                return;
            }
            serverValue = typed;
            value = typed;
        }
        this.captureBusy = true;
        this.captureError = '';
        try {
            const placements = await signPlacement({
                token: this._token,
                placementId: spot.placement.id,
                value: serverValue
            });
            this._syncPlacements(placements);
            spot.signed = true;
            spot.imageData = imageData;
            spot.value = value;
            this._styleSigned(spot);
            this.activeSpot = null;
            this._recount();
            this._afterSpot(openNext);
        } catch (e) {
            this.captureError = 'Save failed: ' + this._errText(e);
        } finally {
            this.captureBusy = false;
        }
    }

    // Walk to the next pending field at the pace the signer chose: openNext opens it (a Date fills
    // in and the walk continues); otherwise it is only scrolled to and highlighted, and the signer
    // opens it when ready ("Next Field").
    _afterSpot(openNext) {
        this._refreshChips();
        const next = this._firstPending();
        if (!next) {
            this.consentChecked = false;
            return;
        }
        this._scrollTo(next);
        if (openNext) this._openCapture(next, true);
    }

    // ---------------------------------------------------------------- consent + submit

    handleConsent(e) {
        this.consentChecked = e.target.checked;
    }

    handleLegacyName(e) {
        this.legacyName = e.target.value;
    }

    async handleFinish() {
        if (!this.allSigned || !this.consentChecked || this.state !== 'ready') return;
        this.state = 'submitting';
        this.bannerText = '';
        try {
            // Fail closed: without the certificate roster we cannot know whether this signer
            // completes the request, and a completing signer's PDF must carry the certificate page.
            const cert = await getSignatureCertificate({ token: this._token });
            if (!cert) throw new Error('The certificate details could not be loaded.');
            const out = await compositeSignedPdf({
                PDFLib: window.PDFLib,
                sourceBytes: this._sourceBytes,
                spots: this._spots,
                pagesByNum: this._pagesByNum,
                signerName: this._signerData.signerName || this.signerName,
                cert,
                ip: this._status && this._status.clientIp,
                userAgent: navigator.userAgent,
                formFieldDefs: this._formDefs,
                formValues: this._formValues,
                ffHits: this._ffHits
            });
            const b64 = bytesToB64(out);
            if (b64.length > MAX_COMPOSITE_BASE64_CHARS) {
                throw new Error(
                    "The signed document is too large to submit from a Flow. Please open the sender's signing link instead."
                );
            }
            const res = await saveCompositedSignedPdf({
                token: this._token,
                base64Pdf: b64,
                consentGiven: true,
                ipAddress: (this._status && this._status.clientIp) || null,
                userAgent: navigator.userAgent || 'Unknown',
                formFieldJson: this._formFieldJson
            });
            if (!res || res.success === false) {
                throw new Error((res && res.message) || 'The signature could not be saved.');
            }
            this._markSigned(res.isComplete, false, res.remaining || 0);
        } catch (e) {
            this.state = 'ready';
            this.bannerText = 'Unable to complete signing: ' + this._errText(e);
        }
    }

    /** A document with no on-page fields: a typed name plus consent, signed server-side (as the signing page does). */
    async handleLegacyFinish() {
        if (!this.legacy || !this.consentChecked || !(this.legacyName || '').trim() || this.state !== 'ready') return;
        this.state = 'submitting';
        this.bannerText = '';
        try {
            const res = await savePdfSignature({
                token: this._token,
                typedName: this.legacyName.trim(),
                consentGiven: true,
                ipAddress: (this._status && this._status.clientIp) || null,
                userAgent: navigator.userAgent || 'Unknown',
                formFieldJson: this._formFieldJson
            });
            if (!res || res.success === false) {
                throw new Error((res && res.message) || 'Unable to complete signing.');
            }
            this._markSigned(res.isComplete, false, res.remaining || 0);
        } catch (e) {
            this.state = 'ready';
            this.bannerText = 'Unable to complete signing: ' + this._errText(e);
        }
    }

    // ---------------------------------------------------------------- decline

    handleDeclineOpen() {
        this.activeSpot = null;
        this.bannerText = '';
        this.declineReason = '';
        this.showDeclinePanel = true;
    }
    handleDeclineCancel() {
        this.showDeclinePanel = false;
    }
    handleDeclineReason(e) {
        this.declineReason = e.target.value;
    }

    async handleDeclineConfirm() {
        if (this.declineBusy) return;
        this.declineBusy = true;
        try {
            const res = await declineSignature({
                token: this._token,
                reason: (this.declineReason || '').trim(),
                ipAddress: (this._status && this._status.clientIp) || null,
                userAgent: navigator.userAgent || 'Unknown'
            });
            if (res && res.success) {
                this.showDeclinePanel = false;
                this._markDeclined();
            } else {
                this.bannerText = (res && res.message) || 'Failed to decline. Please try again.';
            }
        } catch (e) {
            this.bannerText = this._errText(e);
        } finally {
            this.declineBusy = false;
        }
    }

    // ---------------------------------------------------------------- outcome + Flow

    _markSigned(requestComplete, alreadySigned, remaining) {
        this.signed = true;
        this.declined = false;
        this.requestComplete = !!requestComplete;
        this.signerStatus = 'Signed';
        this.errorMessage = '';
        this.waitingOn = remaining || 0;
        this.state = alreadySigned ? 'signed' : 'done';
        this._emitOutcome();
    }

    _markDeclined() {
        this.signed = false;
        this.declined = true;
        this.requestComplete = false;
        this.signerStatus = 'Declined';
        this.errorMessage = '';
        this.state = 'declined';
        this._emitOutcome();
    }

    _emitOutcome() {
        this._emit('signed', this.signed);
        this._emit('declined', this.declined);
        this._emit('requestComplete', this.requestComplete);
        this._emit('signerStatus', this.signerStatus);
        this._emit('errorMessage', '');
        this._pendingAdvance = !this.waitForNext;
        this._tryAdvance();
    }

    _fail(kind, message, canRetry, title) {
        this.state = kind === 'guest' ? 'guest' : 'error';
        this.errorText = message;
        this.errorTitle = title || 'Signature Error';
        this.canRetry = !!canRetry;
        this.errorMessage = message;
        this.signed = false;
        this.declined = false;
        this._emit('errorMessage', message);
        this._emit('signed', false);
        this._emit('declined', false);
    }

    _emit(name, value) {
        this.dispatchEvent(new FlowAttributeChangeEvent(name, value));
    }

    _canNavigate() {
        return this._actions.includes('NEXT') || this._actions.includes('FINISH');
    }

    /** Advance only once an outcome is confirmed; waits if the Flow has not offered NEXT/FINISH yet. */
    _tryAdvance() {
        if (!this._pendingAdvance || !(this.signed || this.declined)) return;
        if (this._actions.includes('NEXT')) {
            this._pendingAdvance = false;
            this.dispatchEvent(new FlowNavigationNextEvent());
        } else if (this._actions.includes('FINISH')) {
            this._pendingAdvance = false;
            this.dispatchEvent(new FlowNavigationFinishEvent());
        }
    }

    handleRetry() {
        this._init();
    }

    _errText(e) {
        if (!e) return 'Unknown error.';
        if (e.body && e.body.message) return e.body.message;
        if (e.body && Array.isArray(e.body) && e.body[0] && e.body[0].message) return e.body[0].message;
        return e.message || String(e);
    }
}
