/**
 * handlePdfPreview — browser-sandbox routing.
 *
 *   node scripts/qa/locker-preview-route-check.mjs
 *
 * Locker Service's SecureWindow.open permits only http:, https: and mailto:. A
 * blob: URL is refused with "secure.windowopen() only acceptable types are
 * http:, https: and mailto:" — and it THROWS rather than returning null, so the
 * popup-blocked recovery beneath it was unreachable in exactly the orgs that
 * needed it. Control went straight to the catch and the author got a bare
 * "PDF preview failed" carrying the raw platform message (#321).
 *
 * The fix routes any failure of the inline blob: path into the ContentVersion +
 * native viewer path, which is already the route for payloads too large for Aura
 * and is an ordinary https: navigation. This asserts that routing against three
 * sandboxes — permissive, Locker (window.open throws) and one where
 * createObjectURL itself is refused — so a regression that lets a sandbox
 * failure reach the user as an error fails here rather than in a customer org.
 *
 * Sibling of lws-download-route-check.mjs, which covers the same class of bug on
 * the download path.
 */

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

/**
 * Mirrors the shipped handlePdfPreview, with the browser calls injected.
 * Returns how the preview was delivered: 'tab' | 'armed' | 'contentversion' | 'error'.
 */
function handlePdfPreview({ small }, env) {
    const trace = { toastedError: null, navigated: false, armedUrl: null };
    try {
        // previewDraftPdfData returns base64 only when the PDF fits the Aura payload.
        const res = small ? { base64: 'JVBERi0=' } : {};
        if (res && res.base64) {
            let deliveredInline = false;
            try {
                const url = env.createObjectURL('application/pdf');
                const win = env.windowOpen(url);
                if (!win) {
                    trace.armedUrl = url;
                }
                deliveredInline = true;
            } catch (blobErr) {
                const noop = blobErr && blobErr.message;
                void noop;
            }
            if (deliveredInline) {
                return { how: trace.armedUrl ? 'armed' : 'tab', trace };
            }
        }
        // ContentVersion + native viewer — plain https:, portable everywhere.
        const res2 = env.previewDraftPdf();
        if (!res2 || !res2.contentDocumentId) {
            throw new Error('Preview returned no PDF.');
        }
        trace.navigated = true;
        return { how: 'contentversion', trace };
    } catch (err) {
        trace.toastedError = err.message;
        return { how: 'error', trace };
    }
}

const contentVersion = () => ({ contentDocumentId: '069000000000000AAA' });

// A permissive browser: everything works.
const permissive = {
    createObjectURL: () => 'blob:https://example.lightning.force.com/abc',
    windowOpen: () => ({}),
    previewDraftPdf: contentVersion
};

// Locker Service: SecureWindow.open THROWS on blob:. This is #321.
const locker = {
    createObjectURL: () => 'blob:https://example.lightning.force.com/abc',
    windowOpen: () => {
        throw new Error("secure.windowopen() only acceptable types are http:, https: and mailto:");
    },
    previewDraftPdf: contentVersion
};

// A sandbox that refuses createObjectURL outright, as LWS does for non-allowlisted
// MIME types (see lws-download-route-check.mjs). PDF is on that allowlist today,
// so this is defence in depth rather than a reproduction.
const noObjectUrl = {
    createObjectURL: () => {
        throw new Error("Cannot 'createObjectURL' using an unsecure [object Blob]");
    },
    windowOpen: () => ({}),
    previewDraftPdf: contentVersion
};

// A browser that blocks the popup but allows blob: — must NOT be confused with a
// sandbox refusal: the armed-button recovery is still the right answer there.
const popupBlocked = {
    createObjectURL: () => 'blob:https://example.lightning.force.com/abc',
    windowOpen: () => null,
    previewDraftPdf: contentVersion
};

console.log('\nsmall PDF — the inline blob: path');
let r = handlePdfPreview({ small: true }, permissive);
ok(r.how === 'tab', 'permissive browser opens the blob: URL in a tab');

r = handlePdfPreview({ small: true }, popupBlocked);
ok(r.how === 'armed', 'popup blocked arms the button rather than erroring');
ok(r.trace.armedUrl !== null, 'and keeps the blob URL for the synchronous open');

r = handlePdfPreview({ small: true }, locker);
ok(r.how === 'contentversion', 'Locker refusing blob: falls through to the ContentVersion viewer');
ok(r.trace.toastedError === null, 'and the author is never shown an error');
ok(r.trace.navigated === true, 'and is actually navigated to the preview');

r = handlePdfPreview({ small: true }, noObjectUrl);
ok(r.how === 'contentversion', 'createObjectURL being refused also falls through');
ok(r.trace.toastedError === null, 'and is likewise not surfaced as an error');

console.log('\nlarge PDF — always the ContentVersion path');
r = handlePdfPreview({ small: false }, permissive);
ok(r.how === 'contentversion', 'a payload too large for Aura uses the viewer, as before');

r = handlePdfPreview({ small: false }, locker);
ok(r.how === 'contentversion', 'and is unaffected by the sandbox, since it never touches blob:');

console.log('\na real failure must still reach the author');
r = handlePdfPreview(
    { small: true },
    {
        ...locker,
        previewDraftPdf: () => null // server genuinely returned nothing
    }
);
ok(r.how === 'error', 'if the fallback itself fails, that is a real error');
ok(r.trace.toastedError === 'Preview returned no PDF.', 'and it is reported, not swallowed');

console.log(fail ? `\n${fail} FAILED` : '\npreview routing OK');
process.exit(fail ? 1 : 0);
