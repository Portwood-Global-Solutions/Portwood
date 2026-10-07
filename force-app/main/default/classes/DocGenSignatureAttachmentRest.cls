/**
 * Guest endpoint that streams one attached document (#412) to the signing page as raw PDF bytes.
 *
 *   GET {Site}/services/apexrest/[ns/]signature-attachment?index=N
 *   X-Portwood-Token: <the signer's 64-hex secure token>
 *
 * Apex REST rather than Visualforce remoting because remoting caps a response at ~15 MB of
 * base64 (≈5.5 MB of PDF) — engineering drawings run to 16 MB and more. The page calls this on
 * its own Site, so it is same-origin: no CORS and no credentials beyond the token.
 *
 * The token travels in a header, never the URL, so it stays out of access logs and history. All
 * gating (token, expiry, terminal state, PIN, index range, pinned version unchanged) lives in
 * DocGenSignatureAttachments.serve; this class only translates to and from HTTP.
 *
 * The GET writes evidence (the SHA-256 on first serve, the signer's Fetched At): it is not
 * CSRF-reachable, because the token has to arrive in a custom header, which a cross-site request
 * cannot set without a CORS preflight the Site never grants.
 */
@RestResource(urlMapping='/signature-attachment/*')
global without sharing class DocGenSignatureAttachmentRest { // NOPMD AvoidGlobalModifier — Apex REST resources must be global
    @TestVisible
    private static final String TOKEN_HEADER = 'X-Portwood-Token';

    @HttpGet
    global static void fetchAttachment() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Cache-Control', 'no-store');
        res.addHeader('Vary', TOKEN_HEADER); // one URL serves every signer; never share a cached copy
        res.addHeader('X-Content-Type-Options', 'nosniff');

        Integer index;
        try {
            String raw = req.params.get('index');
            index = String.isBlank(raw) ? null : Integer.valueOf(raw);
        } catch (Exception e) {
            index = null;
        }

        DocGenSignatureAttachments.GuestResult result;
        try {
            result = DocGenSignatureAttachments.serve(header(req, TOKEN_HEADER), index);
        } catch (Exception e) {
            DocGenErrorLogger.log('DocGenSignatureAttachmentRest', e);
            result = new DocGenSignatureAttachments.GuestResult();
            result.status = 500;
            result.error = 'The attached document could not be loaded. Please try again.';
        }

        if (result.status != 200) {
            res.statusCode = result.status;
            res.addHeader('Content-Type', 'application/json');
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'error' => result.error }));
            return;
        }
        res.statusCode = 200;
        res.addHeader('Content-Type', 'application/pdf');
        res.addHeader('Content-Disposition', 'inline; filename="' + safeFileName(result.title) + '.pdf"');
        res.addHeader('X-Portwood-Sha256', result.sha256);
        res.responseBody = result.bytes;
    }

    @TestVisible
    private static String safeFileName(String title) {
        String name = String.isBlank(title) ? 'document' : title.replaceAll('[^A-Za-z0-9 ._()-]', '_');
        return name.left(120);
    }

    /** Header lookup, case-insensitive — HTTP/2 clients send header names lower-cased. */
    @TestVisible
    private static String header(RestRequest req, String name) {
        if (req == null || req.headers == null) {
            return null;
        }
        if (req.headers.containsKey(name)) {
            return req.headers.get(name);
        }
        for (String key : req.headers.keySet()) {
            if (key != null && key.equalsIgnoreCase(name)) {
                return req.headers.get(key);
            }
        }
        return null;
    }
}
