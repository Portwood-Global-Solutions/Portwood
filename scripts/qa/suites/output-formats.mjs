/**
 * output-formats — does generation actually produce a valid document, for every
 * template type and every output format?
 *
 * WHY THIS SUITE EXISTS
 * ---------------------
 * The existing e2e scripts prove `generateDocument` did not throw. That is a
 * much weaker claim than "the customer got a working file". A merge that
 * silently drops the template chrome (v2.5.0), packs cells into the left half of
 * the page (v2.8.0), or writes xlsx bytes under a .docx extension all "pass" a
 * non-null check. So every assertion here is about the ARTEFACT:
 *
 *   1. the bytes are non-empty and above a floor that a real document clears
 *   2. the MAGIC BYTES match the claimed format — %PDF for PDF, PK for OOXML
 *   3. for ZIP containers, the expected internal parts are present
 *   4. the merged DATA is in the output, read back out of the artefact:
 *        · PDF  → DocGenService.lastRenderedHtml (the exact HTML fed to Blob.toPdf)
 *        · OOXML→ the produced ZIP is re-opened and the part is read
 *   5. nothing UNRESOLVED leaked — a literal `{Tag}` in the output is a silent
 *      corruption, not a cosmetic issue
 *   6. the file name follows Document_Title_Format__c
 *
 * HOW IT TALKS TO THE ORG
 * -----------------------
 * Anonymous Apex has no return channel, so each phase prints `KEY=value` and the
 * assertions live here in JS — the check name and the evidence string stay next
 * to each other, and a failure says what the org actually returned.
 *
 * Every phase ends with `PHASE_DONE=<id>`. That sentinel is the whole defence
 * against the failure mode CLAUDE.md calls out for e2e-03b: a governor limit
 * throws a LimitException, the script prints NOTHING, and a naive parser reads
 * the silence as success. No sentinel ⇒ the transaction died ⇒ reported as a
 * failure with whatever the log said, never as a pass.
 *
 * WHY SO MANY SEPARATE runAnonymous CALLS
 * --------------------------------------
 * One full generateDocument costs ~10 SOQL. The 100-SOQL synchronous ceiling
 * therefore allows ~8 generations per transaction, and this suite does far more
 * than that. Each phase is its own transaction with its own limits.
 *
 * CLEANUP
 * -------
 * Everything is prefixed with a per-run token and deleted in the final phase,
 * including the ContentDocuments behind the template bodies (deleting the
 * template only removes the link, not the file). Repeat runs must stay green and
 * must not fill the org.
 */
import { runAnonymous, debugMap } from '../lib/sf.mjs';
import { check, skip, suiteResult, suiteSkipped, SEVERITY } from '../lib/report.mjs';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const B = SEVERITY.BLOCKER;
const MA = SEVERITY.MAJOR;
const MI = SEVERITY.MINOR;

/** Magic bytes, as uppercase hex, for the formats this package emits. */
const MAGIC_PDF = '25504446'; // '%PDF'
const MAGIC_ZIP = '504B0304'; // 'PK\x03\x04' — DOCX, PPTX, XLSX are all ZIPs

/**
 * Size floors. Deliberately generous — the point is to catch an EMPTY or
 * header-only artefact, not to police compression ratios. A real one-page PDF
 * from Flying Saucer is ~2-8 KB; a four-entry DOCX ZIP is ~1 KB.
 */
const MIN_PDF = 800;
const MIN_ZIP = 400;

/* ------------------------------------------------------------------ *
 * Apex plumbing
 * ------------------------------------------------------------------ */

/**
 * Pull the reason a transaction died. A phase with no PHASE_DONE sentinel has
 * one of these in the log; surfacing it is the difference between "something
 * went wrong" and a fixable report line.
 */
function extractError(log) {
    const s = String(log || '');
    const patterns = [
        /System\.LimitException[^\n]*/,
        /System\.[A-Za-z]+Exception[^\n]*/,
        /FATAL_ERROR[^\n]*/,
        /Compile error[^\n]*/i,
        /error:[^\n]*/i
    ];
    for (const p of patterns) {
        const m = p.exec(s);
        if (m) return m[0].trim().slice(0, 260);
    }
    return 'no PHASE_DONE sentinel and no error text — the transaction ended silently';
}

/**
 * Run one phase. Never throws: a CLI failure, a compile error and a governor
 * limit all come back as `{ ok:false, error }` so the caller turns them into
 * checks rather than killing the suite.
 *
 * A compile error goes to the CLI's STDERR with an empty stdout, so the failure
 * text alone is "Command failed" — useless. When a phase does not finish, the
 * generated Apex is written to a temp file and the path goes into the check
 * detail, because a report line you cannot act on is barely better than none.
 */
async function phase(org, id, src) {
    let log = '';
    let cliErr = '';
    try {
        log = await runAnonymous(org, src, { timeout: 900000 });
    } catch (e) {
        cliErr = String(e.stderr || e.message || '').slice(0, 400);
    }
    const map = debugMap(log);
    if (map.PHASE_DONE === id) return { ok: true, map, log, error: '' };

    let dumped = '';
    try {
        dumped = join(mkdtempSync(join(tmpdir(), 'dgqa-fail-')), `${id}.apex`);
        writeFileSync(dumped, src, 'utf8');
    } catch (e) {
        /* the dump is a convenience; never let it become the failure */
    }
    const why = log ? extractError(log) : cliErr || 'the CLI produced no output at all';
    return { ok: false, map, log, error: `${why}${dumped ? ` [apex: ${dumped}]` : ''}` };
}

const yes = (v) => String(v) === 'true';

/**
 * Evidence that reads correctly in BOTH states.
 *
 * The report prints the detail next to a ✅ as well as a ❌, so a string written
 * only as an accusation ("a literal {Tag} survived") is actively misleading when
 * the check passed. Pass the two readings explicitly.
 */
const evidence = (ok, whenOk, whenBad) => (ok ? whenOk : whenBad);

const num = (v) => {
    const n = Number(v);
    return Number.isFinite(n) ? n : -1;
};

/** Hex → UTF-8, so a unicode round-trip is proven end to end rather than assumed. */
function hexToUtf8(hex) {
    try {
        const clean = String(hex || '').replace(/[^0-9a-fA-F]/g, '');
        if (!clean.length || clean.length % 2) return '';
        return Buffer.from(clean, 'hex').toString('utf8');
    } catch (e) {
        return '';
    }
}

/**
 * The standard artefact assertions, applied identically to every format so a
 * DOCX is held to the same bar as a PDF.
 *
 * @param prefix  key prefix the Apex phase printed (`H_` → H_SIZE, H_HEX, …)
 * @param magic   expected leading bytes
 * @param minSize floor for a document that actually contains something
 */
function artefactChecks(label, map, prefix, magic, minSize, severity = B) {
    const out = [];
    const size = num(map[`${prefix}SIZE`]);
    const hex = String(map[`${prefix}HEX`] || '').toUpperCase();

    // A null/blank base64 is the failure customers report as "nothing happened".
    out.push(
        check(
            `${label}: generation returned bytes`,
            size > 0,
            size > 0 ? `${size} bytes` : `no blob returned (base64 was ${map[`${prefix}B64`] || 'null/blank'})`,
            severity
        )
    );
    // Magic bytes are the only cheap proof the container is what it claims. A
    // truncated or half-written blob still decodes from base64 and still has a
    // non-zero size — it just is not a document.
    out.push(
        check(
            `${label}: magic bytes are ${magic === MAGIC_PDF ? '%PDF' : 'PK (ZIP)'}`,
            hex.startsWith(magic),
            hex ? `leading bytes ${hex}, expected ${magic}` : 'no bytes to inspect',
            severity
        )
    );
    // Above a floor, because an empty PDF shell and an empty ZIP both pass the
    // magic-byte test.
    out.push(check(`${label}: size above ${minSize} bytes`, size >= minSize, `${size} bytes`, severity));
    return out;
}

/* ------------------------------------------------------------------ *
 * Apex fragments shared by several phases
 * ------------------------------------------------------------------ */

/**
 * A minimal but genuinely valid DOCX. Four entries is what Word needs to open
 * the file, and it is what TestDataFactory.createValidDocxFile builds — kept
 * inline here so this suite never depends on a @TestVisible/test-only class
 * (which anonymous Apex cannot reach anyway).
 */
const APEX_DOCX_BUILDER = `
String buildDocx(String bodyXml) {
    Compression.ZipWriter zw = new Compression.ZipWriter();
    zw.addEntry('[Content_Types].xml', Blob.valueOf(
        '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
        '<Default Extension="xml" ContentType="application/xml"/>' +
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
        '</Types>'));
    zw.addEntry('_rels/.rels', Blob.valueOf(
        '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
        '</Relationships>'));
    zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(
        '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'));
    zw.addEntry('word/document.xml', Blob.valueOf(bodyXml));
    return EncodingUtil.base64Encode(zw.getArchive());
}
`;

/**
 * Binary-safe byte search.
 *
 * Blob.toString() throws `BLOB is not a valid UTF-8 string` on a real
 * Flying-Saucer PDF (compressed streams are not text), so looking for content
 * that way turns a HEALTHY generation into a caught exception and reads as a
 * clean product failure. Hex is the only way in, and hex doubles the heap — so
 * anything over the ceiling reports "not checked" instead of guessing.
 */
const APEX_BYTES = `
Boolean bytesCheckable(Blob b) { return b != null && b.size() <= 1000000; }
Boolean bytesContain(Blob b, String needle) {
    if (!bytesCheckable(b)) { return false; }
    String hx = EncodingUtil.convertToHex(b).toUpperCase();
    return hx.contains(EncodingUtil.convertToHex(Blob.valueOf(needle)).toUpperCase());
}
`;

/** Attach a body to a template and mark it the active version. */
const APEX_ATTACH = `
void attach(Id tmplId, String name, String path, Blob body) {
    ContentVersion cv = new ContentVersion(
        Title = name, PathOnClient = path, VersionData = body, FirstPublishLocationId = tmplId);
    insert cv;
    cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];
    insert new DocGen_Template_Version__c(
        Template__c = tmplId, Content_Version_Id__c = cv.Id, Is_Active__c = true);
}
`;

/* ------------------------------------------------------------------ *
 * The suite
 * ------------------------------------------------------------------ */

export async function run({ org }) {
    // One token per run: makes every record findable for cleanup and keeps two
    // concurrent runs from colliding.
    const PFX = `QAOF${Date.now().toString().slice(-9)}`;
    const checks = [];
    let setupOk = false;

    try {
        /* ============================================================ *
         * PHASE 0 — fixtures
         * No generation here, so the whole thing fits well inside limits
         * and a failure is unambiguously a SETUP failure, not a product one.
         * ============================================================ */
        const p0 = await phase(
            org,
            'P0',
            `
${APEX_DOCX_BUILDER}
${APEX_ATTACH}

String PFX = '${PFX}';

// Unicode lives in a field, not in the Account Name, so every later phase can
// find its fixtures with a plain ASCII LIKE and the unicode assertion stays a
// real round-trip rather than a query artefact.
String UNI = 'Kabushiki \\u65E5\\u672C\\u8A9E \\u00DCn\\u00EFc\\u00F8d\\u00E9 \\u03A9 \\u20AC';

Account main = new Account(
    Name = PFX + ' Corp',
    Description = UNI,
    AccountNumber = '068000000000000AAA',   // a well-formed CV Id that does NOT exist
    Industry = 'Technology'
);
Account empty = new Account(Name = PFX + ' Empty', Industry = 'Energy');
Account doomed = new Account(Name = PFX + ' Doomed');
insert new List<Account>{ main, empty, doomed };

insert new List<Contact>{
    new Contact(LastName = 'Alpha', AccountId = main.Id),
    new Contact(LastName = 'Bravo', AccountId = main.Id),
    new Contact(LastName = 'Charlie', AccountId = main.Id)
};

String QC = 'Name, Industry, Description, AccountNumber, (SELECT LastName FROM Contacts)';

// ---- HTML -> PDF -------------------------------------------------------
DocGen_Template__c htmlT = new DocGen_Template__c(
    Name = PFX + ' HTMLPDF', Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = QC,
    Document_Title_Format__c = PFX + '-{Name}-{Industry}'
);
insert htmlT;
attach(htmlT.Id, PFX + ' HTMLPDF', 'b.html', Blob.valueOf(
    '<html><body><h1>MARKER_TITLE {Name}</h1>' +
    '<p>UNI:{Description}</p><p>IND:{Industry}</p>' +
    '<table>{#Contacts}<tr><td>ROW-{LastName}</td></tr>{/Contacts}</table>' +
    '</body></html>'));

// ---- Word -> DOCX (Native) --------------------------------------------
String wordBody =
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
    '<w:p><w:r><w:t>MARKER_TITLE {Name}</w:t></w:r></w:p>' +
    '<w:p><w:r><w:t>IND:{Industry}</w:t></w:r></w:p>' +
    // The section tags live INSIDE the row that repeats — that is the Word
    // convention the row-expansion logic keys off.
    '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{#Contacts}ROW-{LastName}{/Contacts}</w:t></w:r></w:p></w:tc></w:tr></w:tbl>' +
    '</w:body></w:document>';
DocGen_Template__c docxT = new DocGen_Template__c(
    Name = PFX + ' WORDDOCX', Base_Object_API__c = 'Account', Type__c = 'Word',
    Output_Format__c = 'Native', Query_Config__c = QC,
    Document_Title_Format__c = PFX + '-{Name}'
);
insert docxT;
attach(docxT.Id, PFX + ' WORDDOCX', 'b.docx', EncodingUtil.base64Decode(buildDocx(wordBody)));

// ---- Word -> PDF (the DOCX->HTML->PDF converter path) ------------------
DocGen_Template__c wpdfT = new DocGen_Template__c(
    Name = PFX + ' WORDPDF', Base_Object_API__c = 'Account', Type__c = 'Word',
    Output_Format__c = 'PDF', Query_Config__c = QC,
    Document_Title_Format__c = PFX + '-{Name}'
);
insert wpdfT;
attach(wpdfT.Id, PFX + ' WORDPDF', 'b.docx', EncodingUtil.base64Decode(buildDocx(wordBody)));

System.debug('MAIN_ID=' + main.Id);
System.debug('EMPTY_ID=' + empty.Id);
System.debug('DOOMED_ID=' + doomed.Id);
System.debug('UNI_HEX=' + EncodingUtil.convertToHex(Blob.valueOf(UNI)));
System.debug('PHASE_DONE=P0');
`
        );

        if (!p0.ok) {
            // Without fixtures nothing else can be evaluated. Report the setup
            // failure once and skip the suite rather than emit 40 phantom fails.
            return suiteSkipped('output-formats', 'Output formats', `fixture setup failed: ${p0.error}`);
        }
        setupOk = true;

        const MAIN = p0.map.MAIN_ID;
        const EMPTY = p0.map.EMPTY_ID;
        const DOOMED = p0.map.DOOMED_ID;
        const UNI = hexToUtf8(p0.map.UNI_HEX);

        /* ============================================================ *
         * PHASE 1 — HTML template -> PDF
         * The recommended authoring format (CLAUDE.md), so every content
         * assertion this suite can make is made here.
         * ============================================================ */
        const p1 = await phase(
            org,
            'P1',
            `
String PFX = '${PFX}';
String pat = PFX + ' HTMLPDF';
DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c WHERE Name = :pat LIMIT 1];

// Null it first: lastRenderedHtml is a sticky static. Reading a value left over
// from an earlier call in the same transaction would be a false pass.
DocGenService.lastRenderedHtml = null;

Map<String, Object> r = DocGenController.processAndReturnDocument(t.Id, '${MAIN}', null, null);
String b64 = (String) r.get('base64');
System.debug('H_TITLE=' + r.get('title'));
System.debug('H_FMT=' + r.get('outputFormat'));
System.debug('H_TYPE=' + r.get('templateType'));
Integer sz = 0;
String hx = '';
if (String.isNotBlank(b64)) {
    Blob bl = EncodingUtil.base64Decode(b64);
    sz = bl.size();
    hx = EncodingUtil.convertToHex(bl).toUpperCase();
    if (hx.length() > 16) { hx = hx.substring(0, 16); }
}
System.debug('H_SIZE=' + sz);
System.debug('H_HEX=' + hx);

String html = DocGenService.lastRenderedHtml;
System.debug('H_HTML_LEN=' + (html == null ? 0 : html.length()));
if (html != null) {
    // The merged parent field must be in the HTML that Blob.toPdf was handed.
    System.debug('H_HAS_NAME=' + html.contains(PFX + ' Corp'));
    System.debug('H_HAS_IND=' + html.contains('IND:Technology'));
    // Every child row, not just the first — a loop that renders one row is the
    // classic off-by-one in loop-body extraction.
    System.debug('H_ROWS=' + (html.contains('ROW-Alpha') && html.contains('ROW-Bravo') && html.contains('ROW-Charlie')));
    // Unicode is printed as hex so the assertion survives the debug-log transport.
    System.debug('H_UNI_HEX=' + EncodingUtil.convertToHex(Blob.valueOf(
        html.contains('UNI:') ? html.substring(html.indexOf('UNI:'), Math.min(html.indexOf('UNI:') + 80, html.length())) : '')));
    // A literal merge tag surviving into the output is silent data corruption.
    System.debug('H_LEAK=' + (html.contains('{Name}') || html.contains('{Industry}') ||
                              html.contains('{#Contacts}') || html.contains('{/Contacts}') ||
                              html.contains('{Description}')));
}
System.debug('PHASE_DONE=P1');
`
        );

        if (!p1.ok) {
            checks.push(check('HTML template renders to PDF', false, `phase died: ${p1.error}`, B));
        } else {
            checks.push(...artefactChecks('HTML→PDF', p1.map, 'H_', MAGIC_PDF, MIN_PDF));
            // The rendered HTML is the only window into PDF content Apex has.
            const hlen = num(p1.map.H_HTML_LEN);
            checks.push(
                check(
                    'HTML→PDF: DocGenService.lastRenderedHtml captured for inspection',
                    hlen > 0,
                    hlen > 0 ? `${hlen} chars` : 'lastRenderedHtml was null — content cannot be verified',
                    MA
                )
            );
            checks.push(
                check(
                    'HTML→PDF: merged parent field appears in the rendered document',
                    yes(p1.map.H_HAS_NAME) && yes(p1.map.H_HAS_IND),
                    evidence(
                        yes(p1.map.H_HAS_NAME) && yes(p1.map.H_HAS_IND),
                        'both {Name} and {Industry} resolved in the rendered HTML',
                        `{Name}=${p1.map.H_HAS_NAME} {Industry}=${p1.map.H_HAS_IND} — a PDF that renders but drops merge data is worse than one that fails`
                    ),
                    B
                )
            );
            checks.push(
                check(
                    'HTML→PDF: every child-loop row rendered',
                    yes(p1.map.H_ROWS),
                    evidence(
                        yes(p1.map.H_ROWS),
                        'ROW-Alpha, ROW-Bravo and ROW-Charlie all present',
                        'expected ROW-Alpha, ROW-Bravo and ROW-Charlie in lastRenderedHtml — a loop that renders fewer rows than the collection holds is silent data loss'
                    ),
                    B
                )
            );
            const uniSlice = hexToUtf8(p1.map.H_UNI_HEX);
            checks.push(
                check(
                    'HTML→PDF: non-Latin / unicode merge values survive the round trip',
                    UNI.length > 0 && uniSlice.includes(UNI.split(' ')[1] || 'x'),
                    `expected ${JSON.stringify(UNI)} to appear; rendered slice was ${JSON.stringify(uniSlice.slice(0, 60))}`,
                    B
                )
            );
            checks.push(
                check(
                    'HTML→PDF: no unresolved merge tags leak into the output',
                    !yes(p1.map.H_LEAK),
                    evidence(
                        !yes(p1.map.H_LEAK),
                        'no {Tag} or {#Loop} survived into the rendered HTML',
                        'a literal {Tag} or {#Loop} was found in the rendered HTML'
                    ),
                    B
                )
            );
            // Document_Title_Format__c drives the downloaded file name.
            const wantTitle = `${PFX}-${PFX} Corp-Technology`;
            checks.push(
                check(
                    'Document_Title_Format__c produces the document title',
                    p1.map.H_TITLE === wantTitle,
                    `expected "${wantTitle}", got "${p1.map.H_TITLE}"`,
                    MA
                )
            );
            checks.push(
                check(
                    'HTML→PDF: result is labelled PDF',
                    p1.map.H_FMT === 'PDF' && p1.map.H_TYPE === 'HTML',
                    `outputFormat=${p1.map.H_FMT} templateType=${p1.map.H_TYPE}`,
                    MA
                )
            );
        }

        /* ============================================================ *
         * PHASE 2 — Word template -> DOCX (Native)
         * Re-opens the produced ZIP and reads word/document.xml back, so the
         * content assertion is made against the artefact, not against an
         * intermediate the code happened to expose.
         * ============================================================ */
        const p2 = await phase(
            org,
            'P2',
            `
String PFX = '${PFX}';
String pat = PFX + ' WORDDOCX';
DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c WHERE Name = :pat LIMIT 1];

Map<String, Object> r = DocGenController.processAndReturnDocument(t.Id, '${MAIN}', null, null);
String b64 = (String) r.get('base64');
System.debug('D_TITLE=' + r.get('title'));
System.debug('D_FMT=' + r.get('outputFormat'));
Integer sz = 0;
String hx = '';
if (String.isNotBlank(b64)) {
    Blob bl = EncodingUtil.base64Decode(b64);
    sz = bl.size();
    hx = EncodingUtil.convertToHex(bl).toUpperCase();
    if (hx.length() > 16) { hx = hx.substring(0, 16); }

    // Open the produced file as a ZIP. If this throws, the customer's Word
    // would have thrown too.
    try {
        Compression.ZipReader zr = new Compression.ZipReader(bl);
        Set<String> names = new Set<String>();
        for (Compression.ZipEntry ze : zr.getEntries()) { names.add(ze.getName()); }
        System.debug('D_PARTS=' + String.join(new List<String>(names), '|'));
        System.debug('D_HAS_DOC=' + names.contains('word/document.xml'));
        System.debug('D_HAS_CT=' + names.contains('[Content_Types].xml'));
        System.debug('D_HAS_RELS=' + names.contains('_rels/.rels'));
        if (names.contains('word/document.xml')) {
            String dx = zr.extract('word/document.xml').toString();
            System.debug('D_HAS_NAME=' + dx.contains(PFX + ' Corp'));
            System.debug('D_HAS_IND=' + dx.contains('IND:Technology'));
            System.debug('D_ROWS=' + (dx.contains('ROW-Alpha') && dx.contains('ROW-Bravo') && dx.contains('ROW-Charlie')));
            System.debug('D_LEAK=' + (dx.contains('{Name}') || dx.contains('{Industry}') || dx.contains('{#Contacts}')));
        }
    } catch (Exception ze) {
        System.debug('D_ZIP_ERR=' + ze.getMessage());
    }
}
System.debug('D_SIZE=' + sz);
System.debug('D_HEX=' + hx);
System.debug('PHASE_DONE=P2');
`
        );

        if (!p2.ok) {
            checks.push(check('Word template renders to DOCX', false, `phase died: ${p2.error}`, B));
        } else {
            checks.push(...artefactChecks('Word→DOCX', p2.map, 'D_', MAGIC_ZIP, MIN_ZIP));
            checks.push(
                check(
                    'Word→DOCX: output opens as a ZIP archive',
                    !p2.map.D_ZIP_ERR && !!p2.map.D_PARTS,
                    p2.map.D_ZIP_ERR
                        ? `ZipReader threw: ${p2.map.D_ZIP_ERR} — Word would refuse this file`
                        : `entries: ${p2.map.D_PARTS}`,
                    B
                )
            );
            // The three parts Word needs to open the document at all.
            checks.push(
                check(
                    'Word→DOCX: contains word/document.xml, [Content_Types].xml and _rels/.rels',
                    yes(p2.map.D_HAS_DOC) && yes(p2.map.D_HAS_CT) && yes(p2.map.D_HAS_RELS),
                    `document.xml=${p2.map.D_HAS_DOC} content-types=${p2.map.D_HAS_CT} rels=${p2.map.D_HAS_RELS}; parts: ${p2.map.D_PARTS}`,
                    B
                )
            );
            checks.push(
                check(
                    'Word→DOCX: merged data is inside the produced document.xml',
                    yes(p2.map.D_HAS_NAME) && yes(p2.map.D_HAS_IND),
                    `{Name}=${p2.map.D_HAS_NAME} {Industry}=${p2.map.D_HAS_IND}`,
                    B
                )
            );
            checks.push(
                check(
                    'Word→DOCX: every child-loop row rendered',
                    yes(p2.map.D_ROWS),
                    evidence(
                        yes(p2.map.D_ROWS),
                        'all three rows present in the produced word/document.xml',
                        'expected ROW-Alpha, ROW-Bravo and ROW-Charlie inside word/document.xml'
                    ),
                    B
                )
            );
            checks.push(
                check(
                    'Word→DOCX: no unresolved merge tags leak into the output',
                    !yes(p2.map.D_LEAK),
                    evidence(
                        !yes(p2.map.D_LEAK),
                        'no {Tag} survived into word/document.xml',
                        'a literal {Tag} survived into word/document.xml'
                    ),
                    B
                )
            );
            checks.push(
                check(
                    'Word→DOCX: Document_Title_Format__c applied',
                    p2.map.D_TITLE === `${PFX}-${PFX} Corp`,
                    `expected "${PFX}-${PFX} Corp", got "${p2.map.D_TITLE}"`,
                    MA
                )
            );
        }

        /* ============================================================ *
         * PHASE 3 — Word template -> PDF (the DOCX->HTML->PDF converter)
         * A completely different code path from phase 2 despite the same
         * template body: DocGenHtmlRenderer.convertToHtml then Blob.toPdf.
         * ============================================================ */
        const p3 = await phase(
            org,
            'P3',
            `
String PFX = '${PFX}';
String pat = PFX + ' WORDPDF';
DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c WHERE Name = :pat LIMIT 1];
DocGenService.lastRenderedHtml = null;

Map<String, Object> r = DocGenController.processAndReturnDocument(t.Id, '${MAIN}', null, null);
String b64 = (String) r.get('base64');
Integer sz = 0;
String hx = '';
if (String.isNotBlank(b64)) {
    Blob bl = EncodingUtil.base64Decode(b64);
    sz = bl.size();
    hx = EncodingUtil.convertToHex(bl).toUpperCase();
    if (hx.length() > 16) { hx = hx.substring(0, 16); }
}
System.debug('W_SIZE=' + sz);
System.debug('W_HEX=' + hx);
System.debug('W_FMT=' + r.get('outputFormat'));

String html = DocGenService.lastRenderedHtml;
System.debug('W_HTML_LEN=' + (html == null ? 0 : html.length()));
if (html != null) {
    System.debug('W_HAS_NAME=' + html.contains(PFX + ' Corp'));
    System.debug('W_ROWS=' + (html.contains('ROW-Alpha') && html.contains('ROW-Bravo') && html.contains('ROW-Charlie')));
    // Word XML must be gone: a <w:t> reaching Flying Saucer means the converter
    // passed raw OOXML through and the PDF will be visually wrong.
    System.debug('W_RAW_OOXML=' + (html.contains('<w:t') || html.contains('<w:p>')));
    System.debug('W_LEAK=' + (html.contains('{Name}') || html.contains('{#Contacts}')));
}
System.debug('PHASE_DONE=P3');
`
        );

        if (!p3.ok) {
            checks.push(check('Word template renders to PDF (converter path)', false, `phase died: ${p3.error}`, B));
        } else {
            checks.push(...artefactChecks('Word→PDF', p3.map, 'W_', MAGIC_PDF, MIN_PDF));
            checks.push(
                check(
                    'Word→PDF: merged data survives the DOCX→HTML conversion',
                    yes(p3.map.W_HAS_NAME) && yes(p3.map.W_ROWS),
                    `name=${p3.map.W_HAS_NAME} rows=${p3.map.W_ROWS}`,
                    B
                )
            );
            checks.push(
                check(
                    'Word→PDF: no raw OOXML reaches the PDF renderer',
                    !yes(p3.map.W_RAW_OOXML),
                    evidence(
                        !yes(p3.map.W_RAW_OOXML),
                        'the converter emitted clean HTML — no <w:t>/<w:p> left',
                        'a <w:t>/<w:p> tag was still present in the HTML handed to Blob.toPdf'
                    ),
                    B
                )
            );
            checks.push(
                check(
                    'Word→PDF: no unresolved merge tags leak into the output',
                    !yes(p3.map.W_LEAK),
                    evidence(
                        !yes(p3.map.W_LEAK),
                        'no {Tag} survived the converter path',
                        'a literal {Tag} survived the converter path'
                    ),
                    B
                )
            );
        }

        /* ============================================================ *
         * PHASE 4 — PowerPoint -> PPTX and Excel -> XLSX
         * Both are ZIP-repack paths with their own rels/media roots. Grouped
         * because neither renders HTML, so the pair costs ~20 SOQL.
         * ============================================================ */
        const p4 = await phase(
            org,
            'P4',
            `
${APEX_ATTACH}
String PFX = '${PFX}';
String QC = 'Name, Industry, Description';

// ---------- PowerPoint ----------
Compression.ZipWriter pz = new Compression.ZipWriter();
pz.addEntry('[Content_Types].xml', Blob.valueOf(
    '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>' +
    '</Types>'));
pz.addEntry('_rels/.rels', Blob.valueOf(
    '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'));
pz.addEntry('ppt/_rels/presentation.xml.rels', Blob.valueOf(
    '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'));
pz.addEntry('ppt/slides/slide1.xml', Blob.valueOf(
    '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
    '<p:cSld><p:spTree><p:sp><p:txBody>' +
    '<a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:r><a:t>MARKER_TITLE {Name}</a:t></a:r></a:p>' +
    '<a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:r><a:t>IND:{Industry}</a:t></a:r></a:p>' +
    '</p:txBody></p:sp></p:spTree></p:cSld></p:sld>'));

DocGen_Template__c pt = new DocGen_Template__c(
    Name = PFX + ' PPTX', Base_Object_API__c = 'Account', Type__c = 'PowerPoint',
    Output_Format__c = 'Native', Query_Config__c = QC, Document_Title_Format__c = PFX + '-{Name}');
insert pt;
attach(pt.Id, PFX + ' PPTX', 'b.pptx', pz.getArchive());

try {
    Map<String, Object> pr = DocGenController.processAndReturnDocument(pt.Id, '${MAIN}', null, null);
    String pb = (String) pr.get('base64');
    if (String.isNotBlank(pb)) {
        Blob pbl = EncodingUtil.base64Decode(pb);
        System.debug('P_SIZE=' + pbl.size());
        String phx = EncodingUtil.convertToHex(pbl).toUpperCase();
        System.debug('P_HEX=' + (phx.length() > 16 ? phx.substring(0, 16) : phx));
        Compression.ZipReader pzr = new Compression.ZipReader(pbl);
        Set<String> pn = new Set<String>();
        for (Compression.ZipEntry ze : pzr.getEntries()) { pn.add(ze.getName()); }
        System.debug('P_PARTS=' + String.join(new List<String>(pn), '|'));
        System.debug('P_HAS_SLIDE=' + pn.contains('ppt/slides/slide1.xml'));
        if (pn.contains('ppt/slides/slide1.xml')) {
            String sx = pzr.extract('ppt/slides/slide1.xml').toString();
            System.debug('P_MERGED=' + (sx.contains(PFX + ' Corp') && sx.contains('IND:Technology')));
            System.debug('P_LEAK=' + (sx.contains('{Name}') || sx.contains('{Industry}')));
        }
    } else {
        System.debug('P_SIZE=0');
    }
} catch (Exception e) {
    System.debug('P_ERR=' + e.getMessage());
}

// ---------- Excel ----------
Compression.ZipWriter xz = new Compression.ZipWriter();
xz.addEntry('[Content_Types].xml', Blob.valueOf(
    '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/></Types>'));
xz.addEntry('_rels/.rels', Blob.valueOf(
    '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'));
xz.addEntry('xl/_rels/workbook.xml.rels', Blob.valueOf(
    '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'));
xz.addEntry('xl/worksheets/sheet1.xml', Blob.valueOf(
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' +
    '<row r="1"><c r="A1" t="inlineStr"><is><t>MARKER_TITLE {Name}</t></is></c></row>' +
    '<row r="2"><c r="A2" t="inlineStr"><is><t>IND:{Industry}</t></is></c></row>' +
    '</sheetData></worksheet>'));

DocGen_Template__c xt = new DocGen_Template__c(
    Name = PFX + ' XLSX', Base_Object_API__c = 'Account', Type__c = 'Excel',
    Output_Format__c = 'Native', Query_Config__c = QC, Document_Title_Format__c = PFX + '-{Name}');
insert xt;
attach(xt.Id, PFX + ' XLSX', 'b.xlsx', xz.getArchive());

try {
    Map<String, Object> xr = DocGenController.processAndReturnDocument(xt.Id, '${MAIN}', null, null);
    String xb = (String) xr.get('base64');
    if (String.isNotBlank(xb)) {
        Blob xbl = EncodingUtil.base64Decode(xb);
        System.debug('X_SIZE=' + xbl.size());
        String xhx = EncodingUtil.convertToHex(xbl).toUpperCase();
        System.debug('X_HEX=' + (xhx.length() > 16 ? xhx.substring(0, 16) : xhx));
        Compression.ZipReader xzr = new Compression.ZipReader(xbl);
        Set<String> xn = new Set<String>();
        for (Compression.ZipEntry ze : xzr.getEntries()) { xn.add(ze.getName()); }
        System.debug('X_PARTS=' + String.join(new List<String>(xn), '|'));
        System.debug('X_HAS_SHEET=' + xn.contains('xl/worksheets/sheet1.xml'));
        if (xn.contains('xl/worksheets/sheet1.xml')) {
            String sx = xzr.extract('xl/worksheets/sheet1.xml').toString();
            System.debug('X_MERGED=' + (sx.contains(PFX + ' Corp') && sx.contains('IND:Technology')));
            System.debug('X_LEAK=' + (sx.contains('{Name}') || sx.contains('{Industry}')));
        }
    } else {
        System.debug('X_SIZE=0');
    }
} catch (Exception e) {
    System.debug('X_ERR=' + e.getMessage());
}
System.debug('PHASE_DONE=P4');
`
        );

        if (!p4.ok) {
            checks.push(check('PowerPoint and Excel generation', false, `phase died: ${p4.error}`, B));
        } else {
            if (p4.map.P_ERR) {
                checks.push(check('PowerPoint→PPTX generation', false, `threw: ${p4.map.P_ERR}`, B));
            } else {
                checks.push(...artefactChecks('PowerPoint→PPTX', p4.map, 'P_', MAGIC_ZIP, MIN_ZIP));
                checks.push(
                    check(
                        'PowerPoint→PPTX: ppt/slides/slide1.xml survives the repack',
                        yes(p4.map.P_HAS_SLIDE),
                        `parts: ${p4.map.P_PARTS}`,
                        B
                    )
                );
                checks.push(
                    check(
                        'PowerPoint→PPTX: merged data is inside the produced slide',
                        yes(p4.map.P_MERGED) && !yes(p4.map.P_LEAK),
                        `merged=${p4.map.P_MERGED} leakedTags=${p4.map.P_LEAK}`,
                        B
                    )
                );
            }

            if (p4.map.X_ERR) {
                checks.push(check('Excel→XLSX generation', false, `threw: ${p4.map.X_ERR}`, B));
            } else {
                checks.push(...artefactChecks('Excel→XLSX', p4.map, 'X_', MAGIC_ZIP, MIN_ZIP));
                checks.push(
                    check(
                        'Excel→XLSX: xl/worksheets/sheet1.xml survives the repack',
                        yes(p4.map.X_HAS_SHEET),
                        `parts: ${p4.map.X_PARTS}`,
                        B
                    )
                );
                checks.push(
                    check(
                        'Excel→XLSX: merged data is inside the produced sheet',
                        yes(p4.map.X_MERGED) && !yes(p4.map.X_LEAK),
                        `merged=${p4.map.X_MERGED} leakedTags=${p4.map.X_LEAK}`,
                        B
                    )
                );
            }
        }

        /* ============================================================ *
         * PHASE 5 — PDF AcroForm fill (Type__c = 'PDF')
         * A real AcroForm PDF, built as PDF syntax rather than unzipped, so
         * the parser in DocGenAcroFormService is genuinely exercised.
         * ============================================================ */
        const p5 = await phase(
            org,
            'P5',
            `
${APEX_ATTACH}
${APEX_BYTES}
String PFX = '${PFX}';

// A minimal reference-based AcroForm with one text field named "Name".
String pdf = '%PDF-1.4\\n' +
    '1 0 obj\\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\\nendobj\\n' +
    '2 0 obj\\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\\nendobj\\n' +
    '3 0 obj\\n<< /Fields [5 0 R] >>\\nendobj\\n' +
    '4 0 obj\\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>\\nendobj\\n' +
    '5 0 obj\\n<< /FT /Tx /T (Name) /Subtype /Widget /Rect [10 10 200 30] >>\\nendobj\\n' +
    'xref\\n0 6\\n' +
    '0000000000 65535 f \\n0000000009 00000 n \\n0000000076 00000 n \\n' +
    '0000000135 00000 n \\n0000000177 00000 n \\n0000000274 00000 n \\n' +
    'trailer\\n<< /Size 6 /Root 1 0 R >>\\nstartxref\\n0\\n%%EOF\\n';
Blob src = Blob.valueOf(pdf);
System.debug('A_SRC_SIZE=' + src.size());
String accented = 'Poda de ' + String.fromCharArray(new List<Integer>{ 193 }) + 'rvore';
String expectedAccent = EncodingUtil.convertToHex(
    Blob.valueOf('/V <FEFF0050006F00640061002000640065002000C100720076006F00720065>')
).toUpperCase();

DocGen_Template__c at = new DocGen_Template__c(
    Name = PFX + ' ACROFORM', Base_Object_API__c = 'Account', Type__c = 'PDF',
    Output_Format__c = 'PDF', Query_Config__c = 'Name, Industry',
    Document_Title_Format__c = PFX + '-{Name}');
insert at;
attach(at.Id, PFX + ' ACROFORM', 'b.pdf', src);

try {
    Map<String, Object> ar = DocGenController.processAndReturnDocument(at.Id, '${MAIN}', null, null);
    String ab = (String) ar.get('base64');
    if (String.isNotBlank(ab)) {
        Blob abl = EncodingUtil.base64Decode(ab);
        System.debug('A_SIZE=' + abl.size());
        String ahx = EncodingUtil.convertToHex(abl).toUpperCase();
        System.debug('A_HEX=' + (ahx.length() > 16 ? ahx.substring(0, 16) : ahx));
        // The AcroForm filler writes an incremental update, so the merged value
        // is readable as literal bytes in the tail of the file.
        System.debug('A_MERGED=' + bytesContain(abl, PFX + ' Corp'));
        System.debug('A_GROWN=' + (abl.size() > src.size()));
        Blob accentedBlob = DocGenAcroFormService.fillPdfTemplate(
            src,
            new Map<String, Object>{ 'Name' => accented }
        );
        String accentedHex = EncodingUtil.convertToHex(accentedBlob).toUpperCase();
        System.debug('A_ACCENT=' + accentedHex.contains(expectedAccent));
    } else {
        System.debug('A_SIZE=0');
    }
    System.debug('A_TITLE=' + ar.get('title'));
} catch (Exception e) {
    System.debug('A_ERR=' + e.getMessage());
}
System.debug('PHASE_DONE=P5');
`
        );

        if (!p5.ok) {
            checks.push(check('PDF AcroForm fill', false, `phase died: ${p5.error}`, B));
        } else if (p5.map.A_ERR) {
            // Distinguish "not supported" from "broken". Either way it is a
            // failure for a customer who configured a PDF template.
            checks.push(
                check(
                    'PDF AcroForm template fills and returns a PDF',
                    false,
                    `DocGenAcroFormService threw: ${p5.map.A_ERR}`,
                    B
                )
            );
        } else {
            checks.push(...artefactChecks('PDF AcroForm', p5.map, 'A_', MAGIC_PDF, 300));
            checks.push(
                check(
                    'PDF AcroForm: merged value is written into the PDF',
                    yes(p5.map.A_MERGED),
                    `expected "${PFX} Corp" in the filled PDF bytes; A_MERGED=${p5.map.A_MERGED}`,
                    B
                )
            );
            checks.push(
                check(
                    'PDF AcroForm: incremental update appended (output larger than template)',
                    yes(p5.map.A_GROWN),
                    `template ${p5.map.A_SRC_SIZE} bytes → output ${p5.map.A_SIZE} bytes; equal size means no field was filled`,
                    MA
                )
            );
            checks.push(
                check(
                    'PDF AcroForm: accented value is preserved',
                    yes(p5.map.A_ACCENT),
                    `expected UTF-16BE encoding for "Poda de Árvore"; A_ACCENT=${p5.map.A_ACCENT}`,
                    B
                )
            );
        }

        /* ============================================================ *
         * PHASE 6 — edge cases: no active version, empty child collection
         * ============================================================ */
        const p6 = await phase(
            org,
            'P6',
            `
${APEX_ATTACH}
String PFX = '${PFX}';

// NOTE ON ENTRY POINT
// Every negative path in this phase goes through DocGenService.generatePdfBlob,
// NOT DocGenController.processAndReturnDocument. The controller wraps failures in
// AuraHandledException, and anonymous Apex CANNOT catch one — it is an
// uncatchable LimitException subclass. Using the controller here would kill the
// whole transaction on the very first expected failure and print nothing, so an
// intentional negative test would masquerade as a dead script. generatePdfBlob
// raises the underlying DocGenException, which is catchable and carries the real
// message. (Same lesson as CLAUDE.md's note on e2e negative-path assertions.)

// ---- A template with NO body at all: no active version, no attached file ----
// Must fail with something an admin can act on, and must NOT return bytes.
DocGen_Template__c bare = new DocGen_Template__c(
    Name = PFX + ' NOVERSION', Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = 'Name');
insert bare;
try {
    Map<String, Object> br = DocGenService.generatePdfBlob(bare.Id, '${MAIN}');
    Blob bb = br == null ? null : (Blob) br.get('blob');
    System.debug('NV_RETURNED=' + (bb != null && bb.size() > 0));
    System.debug('NV_THREW=false');
} catch (Exception e) {
    System.debug('NV_THREW=true');
    System.debug('NV_MSG=' + e.getMessage());
    System.debug('NV_RETURNED=false');
}

// ---- Active version explicitly deactivated, file still attached ----------
// The CDL fallback in DocGenTemplateManager is intentional; what matters is
// that it never produces a HALF-merged or corrupt file.
DocGen_Template__c inact = new DocGen_Template__c(
    Name = PFX + ' INACTIVE', Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = 'Name');
insert inact;
attach(inact.Id, PFX + ' INACTIVE', 'b.html', Blob.valueOf('<html><body><p>INACT {Name}</p></body></html>'));
for (DocGen_Template_Version__c v : [SELECT Id FROM DocGen_Template_Version__c WHERE Template__c = :inact.Id]) {
    update new DocGen_Template_Version__c(Id = v.Id, Is_Active__c = false);
}
try {
    Map<String, Object> ir = DocGenService.generatePdfBlob(inact.Id, '${MAIN}');
    Blob ibl = ir == null ? null : (Blob) ir.get('blob');
    if (ibl != null) {
        String ihx = EncodingUtil.convertToHex(ibl).toUpperCase();
        System.debug('IA_HEX=' + (ihx.length() > 16 ? ihx.substring(0, 16) : ihx));
        System.debug('IA_SIZE=' + ibl.size());
    } else {
        System.debug('IA_SIZE=0');
    }
    System.debug('IA_THREW=false');
} catch (Exception e) {
    System.debug('IA_THREW=true');
    System.debug('IA_MSG=' + e.getMessage());
    System.debug('IA_SIZE=0');
}

// ---- Child collection with ZERO rows -------------------------------------
DocGen_Template__c zt = new DocGen_Template__c(
    Name = PFX + ' ZEROCHILD', Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = 'Name, (SELECT LastName FROM Contacts)');
insert zt;
attach(zt.Id, PFX + ' ZEROCHILD', 'b.html', Blob.valueOf(
    '<html><body><h1>ZERO {Name}</h1>' +
    '<table>{#Contacts}<tr><td>ROW-{LastName}</td></tr>{/Contacts}</table>' +
    '<p>AFTER_LOOP</p></body></html>'));
DocGenService.lastRenderedHtml = null;
try {
    Map<String, Object> zr = DocGenService.generatePdfBlob(zt.Id, '${EMPTY}');
    Blob zbl = zr == null ? null : (Blob) zr.get('blob');
    if (zbl != null) {
        System.debug('Z_SIZE=' + zbl.size());
        String zhx = EncodingUtil.convertToHex(zbl).toUpperCase();
        System.debug('Z_HEX=' + (zhx.length() > 16 ? zhx.substring(0, 16) : zhx));
    } else {
        System.debug('Z_SIZE=0');
    }
    String zh = DocGenService.lastRenderedHtml;
    if (zh != null) {
        // Loop markers gone, content on BOTH sides of the loop still present.
        System.debug('Z_LEAK=' + (zh.contains('{#Contacts}') || zh.contains('{/Contacts}') || zh.contains('{LastName}')));
        System.debug('Z_KEEPS_CHROME=' + (zh.contains('ZERO ') && zh.contains('AFTER_LOOP')));
        System.debug('Z_NO_GHOST_ROW=' + (!zh.contains('ROW-')));
    }
} catch (Exception e) {
    System.debug('Z_ERR=' + e.getMessage());
    System.debug('Z_SIZE=0');
}
System.debug('PHASE_DONE=P6');
`
        );

        if (!p6.ok) {
            checks.push(check('Template/collection edge cases', false, `phase died: ${p6.error}`, B));
        } else {
            checks.push(
                check(
                    'Template with no active version and no file fails instead of returning bytes',
                    !yes(p6.map.NV_RETURNED),
                    yes(p6.map.NV_RETURNED)
                        ? 'a template with no body returned a document — the customer gets an empty file with no warning'
                        : `raised: ${(p6.map.NV_MSG || '(no message)').slice(0, 160)}`,
                    B
                )
            );
            checks.push(
                check(
                    'No-version failure message points at the template configuration',
                    yes(p6.map.NV_THREW) && /template|file|version|configuration/i.test(p6.map.NV_MSG || ''),
                    `message was: ${p6.map.NV_MSG || '(none)'} — an admin has to be able to tell what to fix`,
                    MI
                )
            );
            // The documented CDL fallback: allowed to succeed, not allowed to corrupt.
            const iaSize = num(p6.map.IA_SIZE);
            checks.push(
                check(
                    'Deactivated version with an attached file yields a valid PDF or a clean error, never a corrupt one',
                    (iaSize === 0 && yes(p6.map.IA_THREW)) ||
                        (iaSize >= MIN_PDF && String(p6.map.IA_HEX || '').startsWith(MAGIC_PDF)),
                    `size=${iaSize} hex=${p6.map.IA_HEX} threw=${p6.map.IA_THREW}`,
                    MA
                )
            );
            checks.push(...artefactChecks('Zero-row child loop', p6.map, 'Z_', MAGIC_PDF, MIN_PDF));
            checks.push(
                check(
                    'Zero-row child collection: loop tags do not leak into the output',
                    !yes(p6.map.Z_LEAK),
                    evidence(
                        !yes(p6.map.Z_LEAK),
                        'the loop collapsed cleanly with nothing to iterate',
                        'a {#Contacts}/{/Contacts}/{LastName} tag survived when the collection was empty'
                    ),
                    B
                )
            );
            checks.push(
                check(
                    'Zero-row child collection: content around the loop is preserved',
                    yes(p6.map.Z_KEEPS_CHROME),
                    evidence(
                        yes(p6.map.Z_KEEPS_CHROME),
                        'the heading before the loop and the paragraph after it both survived',
                        'an empty collection swallowed the content surrounding the loop'
                    ),
                    B
                )
            );
            checks.push(
                check(
                    'Zero-row child collection: no phantom row rendered',
                    yes(p6.map.Z_NO_GHOST_ROW),
                    evidence(
                        yes(p6.map.Z_NO_GHOST_ROW),
                        'zero rows in, zero rows out',
                        'the loop body rendered once with blank values — the classic empty-collection bug'
                    ),
                    MA
                )
            );
        }

        /* ============================================================ *
         * PHASE 7 — layout edges: source @page precedence, running-header
         * image overflow, image field pointing at a missing ContentVersion
         * ============================================================ */
        const p7 = await phase(
            org,
            'P7',
            `
${APEX_ATTACH}
String PFX = '${PFX}';

// ---- Source HTML declares its own @page: source must win over the engine ----
// Page_Size__c is deliberately set to a DIFFERENT size so the two disagree and
// the winner is unambiguous.
DocGen_Template__c pgT = new DocGen_Template__c(
    Name = PFX + ' SRCPAGE', Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = 'Name',
    Page_Size__c = 'Letter', Page_Orientation__c = 'Portrait');
insert pgT;
attach(pgT.Id, PFX + ' SRCPAGE', 'b.html', Blob.valueOf(
    '<html><head><style>@page { size: 5in 8in; margin: 0.4in; }</style></head>' +
    '<body><p>SRCPAGE {Name}</p></body></html>'));
DocGenService.lastRenderedHtml = null;
try {
    DocGenService.generatePdfBlob(pgT.Id, '${MAIN}');
    String h = DocGenService.lastRenderedHtml;
    if (h != null) {
        System.debug('SP_HAS_SRC=' + h.contains('5in 8in'));
        // The engine's own size declaration must be suppressed, or the two
        // @page rules fight and Flying Saucer silently picks one.
        System.debug('SP_ENGINE_SIZE=' + (h.contains('size: letter') || h.contains('size: 8.5in 11in')));
    }
} catch (Exception e) {
    System.debug('SP_ERR=' + e.getMessage());
}

// ---- Running header containing a TALL image --------------------------------
// The @page margin box is exactly as tall as the margin, so a 1.5in logo inside
// a 1in margin paints straight over the body text. The engine has to grow the
// top margin; if it does not, the first section of every document is covered.
DocGen_Template__c hdrT = new DocGen_Template__c(
    Name = PFX + ' HDRIMG', Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = 'Name',
    Page_Size__c = 'Letter', Page_Margins__c = 'Normal',
    Header_Html__c = '<img src="/img/logo.png" style="height:1.5in" alt="logo"/>');
insert hdrT;
attach(hdrT.Id, PFX + ' HDRIMG', 'b.html', Blob.valueOf(
    '<html><body><p>BODYTEXT {Name}</p></body></html>'));
DocGenService.lastRenderedHtml = null;
try {
    Map<String, Object> hres = DocGenService.generatePdfBlob(hdrT.Id, '${MAIN}');
    Blob hb = (Blob) hres.get('blob');
    System.debug('HI_SIZE=' + (hb == null ? 0 : hb.size()));
    if (hb != null) {
        String hhx = EncodingUtil.convertToHex(hb).toUpperCase();
        System.debug('HI_HEX=' + (hhx.length() > 16 ? hhx.substring(0, 16) : hhx));
    }
    String h = DocGenService.lastRenderedHtml;
    if (h != null) {
        System.debug('HI_RUNNING=' + h.contains('position: running(dgheader)'));
        System.debug('HI_TOPBOX=' + h.contains('@top-center'));
        // 1.5in image + 0.15in gutter = 1.65in, which must beat the 1in margin.
        System.debug('HI_GROWN=' + h.contains('margin-top: 1.65in'));
        System.debug('HI_MARGIN_SNIPPET=' + (h.contains('@page') ?
            h.substring(h.indexOf('@page'), Math.min(h.indexOf('@page') + 150, h.length())).replace('\\n', ' ') : ''));
    }
} catch (Exception e) {
    System.debug('HI_ERR=' + e.getMessage());
}

// ---- Image field pointing at a ContentVersion that does not exist ----------
// AccountNumber holds a well-formed 068 Id for a record that was never created.
DocGen_Template__c imgT = new DocGen_Template__c(
    Name = PFX + ' MISSINGIMG', Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = 'Name, AccountNumber');
insert imgT;
attach(imgT.Id, PFX + ' MISSINGIMG', 'b.html', Blob.valueOf(
    '<html><body><p>BEFORE_IMG</p><p>{%AccountNumber}</p><p>AFTER_IMG {Name}</p></body></html>'));
DocGenService.lastRenderedHtml = null;
try {
    Map<String, Object> ires = DocGenService.generatePdfBlob(imgT.Id, '${MAIN}');
    Blob ib = (Blob) ires.get('blob');
    System.debug('MI_SIZE=' + (ib == null ? 0 : ib.size()));
    if (ib != null) {
        String ihx = EncodingUtil.convertToHex(ib).toUpperCase();
        System.debug('MI_HEX=' + (ihx.length() > 16 ? ihx.substring(0, 16) : ihx));
    }
    String h = DocGenService.lastRenderedHtml;
    if (h != null) {
        // The rest of the document must still be there...
        System.debug('MI_KEEPS_BODY=' + (h.contains('BEFORE_IMG') && h.contains('AFTER_IMG')));
        // ...and the unresolvable Id must not be dumped on the page as text.
        System.debug('MI_LEAKS_ID=' + h.contains('068000000000000AAA'));
        // A src pointing at a CV that does not exist renders as a broken-image box.
        System.debug('MI_DANGLING_SRC=' + h.contains('/sfc/servlet.shepherd/version/download/068000000000000AAA'));
    }
    System.debug('MI_THREW=false');
} catch (Exception e) {
    System.debug('MI_THREW=true');
    System.debug('MI_ERR=' + e.getMessage());
    System.debug('MI_SIZE=0');
}
System.debug('PHASE_DONE=P7');
`
        );

        if (!p7.ok) {
            checks.push(check('Page-setup and image edge cases', false, `phase died: ${p7.error}`, B));
        } else {
            checks.push(
                check(
                    "Source HTML's own @page rule wins over the engine's page fields",
                    yes(p7.map.SP_HAS_SRC) && !yes(p7.map.SP_ENGINE_SIZE),
                    p7.map.SP_ERR
                        ? `threw: ${p7.map.SP_ERR}`
                        : `sourceSizePresent=${p7.map.SP_HAS_SRC} engineSizeAlsoEmitted=${p7.map.SP_ENGINE_SIZE} — two competing @page size declarations make Flying Saucer pick one silently`,
                    MA
                )
            );
            checks.push(...artefactChecks('Header image', p7.map, 'HI_', MAGIC_PDF, MIN_PDF));
            checks.push(
                check(
                    'Running header is wired into the @page margin box',
                    yes(p7.map.HI_RUNNING) && yes(p7.map.HI_TOPBOX),
                    `running(dgheader)=${p7.map.HI_RUNNING} @top-center=${p7.map.HI_TOPBOX}`,
                    MA
                )
            );
            checks.push(
                check(
                    'Tall header image grows the top margin instead of overflowing onto the body',
                    yes(p7.map.HI_GROWN),
                    evidence(
                        yes(p7.map.HI_GROWN),
                        'margin-top raised to 1.65in for the 1.5in header image',
                        `a 1.5in header image needs margin-top: 1.65in or it paints over the body; emitted @page was: ${(p7.map.HI_MARGIN_SNIPPET || '(none)').slice(0, 200)}`
                    ),
                    B
                )
            );
            checks.push(...artefactChecks('Missing image CV', p7.map, 'MI_', MAGIC_PDF, MIN_PDF));
            checks.push(
                check(
                    'Image field pointing at a missing ContentVersion does not abort generation',
                    !yes(p7.map.MI_THREW),
                    p7.map.MI_ERR
                        ? `threw: ${p7.map.MI_ERR} — one deleted file must not take the whole document down`
                        : 'generation completed',
                    B
                )
            );
            checks.push(
                check(
                    'Missing image degrades without dropping the rest of the document',
                    yes(p7.map.MI_KEEPS_BODY),
                    evidence(
                        yes(p7.map.MI_KEEPS_BODY),
                        'content before and after the image tag both survived',
                        'the unresolvable image took surrounding content down with it'
                    ),
                    B
                )
            );
            checks.push(
                check(
                    'Missing image does not leak the raw ContentVersion Id onto the page',
                    !yes(p7.map.MI_LEAKS_ID) && !yes(p7.map.MI_DANGLING_SRC),
                    evidence(
                        !yes(p7.map.MI_LEAKS_ID) && !yes(p7.map.MI_DANGLING_SRC),
                        'no internal Id and no dangling <img src> in the output',
                        `rawIdAsText=${p7.map.MI_LEAKS_ID} danglingSrc=${p7.map.MI_DANGLING_SRC} — either one shows the customer an internal Id or a broken-image box`
                    ),
                    MA
                )
            );
        }

        /* ============================================================ *
         * PHASE 8 — heap pressure: a very large merged body
         * The contract is binary: a valid document, or a clean error. A
         * truncated blob that still starts with %PDF is the outcome to catch.
         * ============================================================ */
        const p8 = await phase(
            org,
            'P8',
            `
${APEX_ATTACH}
${APEX_BYTES}
String PFX = '${PFX}';

// ~1.2 MB of real markup before merging. Big enough to press on heap in a
// synchronous transaction without being so big the insert itself fails.
String chunk = '<p>Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p>';
String big = '';
for (Integer i = 0; i < 9000; i++) { big += chunk; }
System.debug('HP_BODY_LEN=' + big.length());

DocGen_Template__c bt = new DocGen_Template__c(
    Name = PFX + ' HEAP', Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF', Query_Config__c = 'Name');
insert bt;
attach(bt.Id, PFX + ' HEAP', 'b.html', Blob.valueOf(
    '<html><body><h1>HEAPTOP {Name}</h1>' + big + '<p>HEAPEND {Name}</p></body></html>'));
// Release the 1.2 MB source string before generating. It is no longer needed,
// and holding it would leave too little heap for the hex scan of the output.
big = null;

try {
    Map<String, Object> res = DocGenService.generatePdfBlob(bt.Id, '${MAIN}');
    Blob b = (Blob) res.get('blob');
    System.debug('HP_SIZE=' + (b == null ? 0 : b.size()));
    if (b != null) {
        String hx = EncodingUtil.convertToHex(b).toUpperCase();
        System.debug('HP_HEX=' + (hx.length() > 16 ? hx.substring(0, 16) : hx));
        // %%EOF is the PDF end-of-file marker. Its absence means the writer was
        // cut off mid-stream — the exact corruption a size check alone misses.
        System.debug('HP_EOF_CHECKED=' + bytesCheckable(b));
        System.debug('HP_EOF=' + bytesContain(b, '%%EOF'));
    }
    System.debug('HP_THREW=false');
} catch (Exception e) {
    System.debug('HP_THREW=true');
    System.debug('HP_ERR=' + e.getTypeName() + ': ' + e.getMessage());
    System.debug('HP_SIZE=0');
}
System.debug('PHASE_DONE=P8');
`
        );

        if (!p8.ok) {
            // A phase that itself died on heap is still evidence — report it as
            // the product behaviour it is, not as a harness problem.
            checks.push(
                check(
                    'Very large document body: generation completes or fails cleanly',
                    false,
                    `the transaction died rather than returning an error: ${p8.error}`,
                    B
                )
            );
        } else {
            const hpSize = num(p8.map.HP_SIZE);
            const threw = yes(p8.map.HP_THREW);
            checks.push(
                check(
                    'Very large document body: valid PDF or a clean, catchable error',
                    (threw && hpSize === 0) || (hpSize >= MIN_PDF && String(p8.map.HP_HEX || '').startsWith(MAGIC_PDF)),
                    threw
                        ? `raised ${p8.map.HP_ERR} at body length ${p8.map.HP_BODY_LEN} — acceptable, provided the UI surfaces it`
                        : `size=${hpSize} hex=${p8.map.HP_HEX} at body length ${p8.map.HP_BODY_LEN}`,
                    B
                )
            );
            if (!threw) {
                checks.push(
                    yes(p8.map.HP_EOF_CHECKED)
                        ? check(
                              'Very large document body: PDF is complete, not truncated',
                              yes(p8.map.HP_EOF),
                              evidence(
                                  yes(p8.map.HP_EOF),
                                  `%%EOF trailer present in ${hpSize} bytes`,
                                  'the %%EOF trailer is missing — the blob starts like a PDF but was cut short'
                              ),
                              B
                          )
                        : skip(
                              'Very large document body: PDF is complete, not truncated',
                              `output was ${hpSize} bytes; scanning it for the %%EOF trailer needs a hex copy that would itself blow the 6 MB Apex heap`,
                              B
                          )
                );
                checks.push(
                    check(
                        'Very large document body: output size reflects the content',
                        hpSize > 20000,
                        evidence(
                            hpSize > 20000,
                            `${p8.map.HP_BODY_LEN}-char body → ${hpSize} bytes of PDF`,
                            `a ${p8.map.HP_BODY_LEN}-char body produced only ${hpSize} bytes — content was probably dropped`
                        ),
                        MA
                    )
                );
            } else {
                checks.push(
                    skip(
                        'Very large document body: PDF completeness',
                        `generation raised ${p8.map.HP_ERR} before producing bytes, so there is nothing to inspect`,
                        MA
                    )
                );
            }
        }

        /* ============================================================ *
         * PHASE 9 — a record the caller cannot reach
         * ============================================================ */
        const p9 = await phase(
            org,
            'P9',
            `
String PFX = '${PFX}';
String pat = PFX + ' HTMLPDF';
DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c WHERE Name = :pat LIMIT 1];

// Delete the record, then generate against its Id: a well-formed Id for a row
// the running user genuinely cannot read. Closest reachable analogue of an
// FLS/sharing-invisible record without a second authenticated user.
delete [SELECT Id FROM Account WHERE Id = '${DOOMED}'];

// generatePdfBlob, not the controller — see the note in phase P6: an
// AuraHandledException from the controller cannot be caught here and would end
// the transaction instead of being asserted on.
try {
    Map<String, Object> r = DocGenService.generatePdfBlob(t.Id, '${DOOMED}');
    Blob b = r == null ? null : (Blob) r.get('blob');
    System.debug('UR_RETURNED=' + (b != null && b.size() > 0));
    if (b != null) { System.debug('UR_SIZE=' + b.size()); }
    System.debug('UR_THREW=false');
} catch (Exception e) {
    System.debug('UR_THREW=true');
    System.debug('UR_MSG=' + e.getMessage());
    System.debug('UR_RETURNED=false');
}
System.debug('PHASE_DONE=P9');
`
        );

        if (!p9.ok) {
            checks.push(check('Unreadable record handled cleanly', false, `phase died: ${p9.error}`, B));
        } else {
            checks.push(
                check(
                    'Generating against a record the user cannot read returns no document',
                    !yes(p9.map.UR_RETURNED),
                    yes(p9.map.UR_RETURNED)
                        ? `a document was produced for an unreadable record (${p9.map.UR_SIZE} bytes) — that is a data-exposure shaped failure`
                        : `raised: ${(p9.map.UR_MSG || '(no message)').slice(0, 160)}`,
                    B
                )
            );
        }
        // Honest about what the deleted-record proxy does not cover.
        checks.push(
            skip(
                'Record hidden by sharing/FLS from a low-privilege user',
                'requires generating as a second, restricted user; System.runAs is test-context only and anonymous Apex cannot impersonate. Covered here only by the deleted-record analogue.',
                MA
            )
        );

        /* ============================================================ *
         * PHASE 10 — the giant-query path (>2000 child rows)
         * CLAUDE.md: this is COMPLETELY different code. processXml is not
         * called; DocGenGiantQueryBatch harvests pages and
         * DocGenGiantQueryAssembler builds the PDF. Nothing above this line
         * exercises a single line of it.
         *
         * The threshold is a hard-coded local (DocGenController.cls:929) with no
         * @TestVisible hook and no Custom Setting, so the only honest way in is
         * to actually insert >2000 children.
         * ============================================================ */
        const p10 = await phase(
            org,
            'P10',
            `
${APEX_ATTACH}
String PFX = '${PFX}';

Account g = new Account(Name = PFX + ' Giant', Industry = 'Utilities');
insert g;

// 2100 > the hard-coded 2000 threshold. Inserted in blocks to stay clear of
// per-statement CPU spikes; 2100 rows is well inside the 10,000 DML row limit.
for (Integer blk = 0; blk < 3; blk++) {
    List<Contact> batch = new List<Contact>();
    for (Integer i = 0; i < 700; i++) {
        batch.add(new Contact(LastName = 'G' + blk + '-' + i, AccountId = g.Id));
    }
    insert batch;
}
System.debug('G_CHILD_COUNT=' + [SELECT COUNT() FROM Contact WHERE AccountId = :g.Id]);

DocGen_Template__c gt = new DocGen_Template__c(
    Name = PFX + ' GIANT', Base_Object_API__c = 'Account', Type__c = 'HTML',
    Output_Format__c = 'PDF',
    Query_Config__c = 'Name, Industry, (SELECT LastName FROM Contacts)',
    Document_Title_Format__c = PFX + '-giant-{Name}');
insert gt;
attach(gt.Id, PFX + ' GIANT', 'b.html', Blob.valueOf(
    '<html><body><h1>GIANTTITLE {Name}</h1><p>IND:{Industry}</p>' +
    '<table><thead><tr><th>HDRCELL</th></tr></thead>' +
    '<tbody>{#Contacts}<tr><td>GROW-{LastName}</td></tr>{/Contacts}</tbody></table>' +
    '<p>GIANTFOOT</p></body></html>'));

Map<String, Object> r = DocGenController.generateDocumentGiantQuery(gt.Id, g.Id);
System.debug('G_ACCT=' + g.Id);
System.debug('G_TMPL=' + gt.Id);
System.debug('G_IS_GIANT=' + r.get('isGiantQuery'));
System.debug('G_REL=' + r.get('giantRelationship'));
System.debug('G_JOB=' + r.get('jobId'));
System.debug('PHASE_DONE=P10');
`
        );

        let giantJobId = null;
        if (!p10.ok) {
            checks.push(
                check('Giant-query path (>2000 child rows) is reachable', false, `phase died: ${p10.error}`, B)
            );
        } else {
            const childCount = num(p10.map.G_CHILD_COUNT);
            checks.push(
                check(
                    'Giant-query fixture actually crosses the 2000-row threshold',
                    childCount > 2000,
                    evidence(
                        childCount > 2000,
                        `${childCount} child rows — over the hard-coded 2000 threshold`,
                        `only ${childCount} child rows: below 2000 this silently tests the ordinary path instead`
                    ),
                    MA
                )
            );
            checks.push(
                check(
                    'Over-threshold child collection routes to the giant-query path',
                    yes(p10.map.G_IS_GIANT) && p10.map.G_REL === 'Contacts',
                    `isGiantQuery=${p10.map.G_IS_GIANT} relationship=${p10.map.G_REL}`,
                    B
                )
            );
            giantJobId = p10.map.G_JOB && /^a[\w]{14,17}$/.test(p10.map.G_JOB) ? p10.map.G_JOB : null;
            if (!giantJobId) {
                checks.push(
                    check(
                        'Giant-query job record created',
                        false,
                        `no usable jobId returned (got "${p10.map.G_JOB}")`,
                        B
                    )
                );
            }
        }

        /* --- poll the async chain: batch -> finish -> assembler queueable ---
         * Polled through anonymous Apex rather than `sf data query`, because a
         * NAMESPACED org (this package builds under `portwoodglobal`) rejects the
         * bare `DocGen_Job__c` name over the API while Apex inside the namespace
         * resolves it. Polling in Apex keeps the suite working against both a
         * namespaced scratch org and a plain one.
         */
        let poll = { ok: false, map: {}, error: 'not polled' };
        if (giantJobId) {
            const deadline = Date.now() + 480000; // 2100 rows at batchSize 50 is ~42 executes
            while (Date.now() < deadline) {
                poll = await phase(
                    org,
                    'PJ',
                    `
Id jid = '${giantJobId}';
DocGen_Job__c j = [SELECT Id, Status__c, Label__c, Total_Records__c, Merged_PDF_CV__c FROM DocGen_Job__c WHERE Id = :jid LIMIT 1];
System.debug('J_STATUS=' + j.Status__c);
System.debug('J_LABEL=' + j.Label__c);
System.debug('J_TOTAL=' + j.Total_Records__c);
System.debug('J_CV=' + j.Merged_PDF_CV__c);
System.debug('PHASE_DONE=PJ');
`
                );
                if (!poll.ok) break;
                if (poll.map.J_STATUS === 'Completed' || poll.map.J_STATUS === 'Failed') break;
                await new Promise((r) => setTimeout(r, 10000));
            }
            const status = poll.ok ? poll.map.J_STATUS : null;

            checks.push(
                check(
                    'Giant-query job reaches Completed',
                    status === 'Completed',
                    poll.ok
                        ? `status=${status} label=${poll.map.J_LABEL} totalRecords=${poll.map.J_TOTAL}`
                        : `job record could not be read: ${poll.error}`,
                    B
                )
            );
            checks.push(
                check(
                    'Giant-query job harvested every child row',
                    num(poll.map.J_TOTAL) > 2000,
                    evidence(
                        num(poll.map.J_TOTAL) > 2000,
                        `Total_Records__c=${poll.map.J_TOTAL} of 2100 inserted`,
                        `Total_Records__c=${poll.map.J_TOTAL} — fewer than the 2100 inserted means rows were dropped from the document`
                    ),
                    B
                )
            );

            const pdfCvId = poll.map.J_CV && poll.map.J_CV !== 'null' ? poll.map.J_CV : null;
            if (status === 'Completed' && pdfCvId) {
                // Inspect the assembled PDF with the same artefact bar as every
                // other format — the giant path builds its own HTML and never
                // touches processXml, so nothing above proves it emits a real PDF.
                const p10b = await phase(
                    org,
                    'P10B',
                    `
${APEX_BYTES}
Id cvId = '${pdfCvId}';
List<ContentVersion> cvs = [SELECT Id, Title, VersionData FROM ContentVersion WHERE Id = :cvId LIMIT 1];
if (cvs.isEmpty()) {
    System.debug('GP_SIZE=0');
} else {
    Blob b = cvs[0].VersionData;
    System.debug('GP_SIZE=' + b.size());
    System.debug('GP_TITLE=' + cvs[0].Title);
    String hx = EncodingUtil.convertToHex(b).toUpperCase();
    System.debug('GP_HEX=' + (hx.length() > 16 ? hx.substring(0, 16) : hx));
    hx = null;
    System.debug('GP_EOF_CHECKED=' + bytesCheckable(b));
    System.debug('GP_EOF=' + bytesContain(b, '%%EOF'));
}
System.debug('PHASE_DONE=P10B');
`
                );
                if (!p10b.ok) {
                    checks.push(check('Giant-query output PDF is readable', false, `phase died: ${p10b.error}`, B));
                } else {
                    // 2100 rows cannot fit in a small file; the floor is set high
                    // deliberately so a chrome-only or bare-table regression fails.
                    checks.push(...artefactChecks('Giant-query PDF', p10b.map, 'GP_', MAGIC_PDF, 30000));
                    checks.push(
                        yes(p10b.map.GP_EOF_CHECKED)
                            ? check(
                                  'Giant-query PDF is complete, not truncated',
                                  yes(p10b.map.GP_EOF),
                                  evidence(
                                      yes(p10b.map.GP_EOF),
                                      `%%EOF trailer present in ${p10b.map.GP_SIZE} bytes`,
                                      'the %%EOF trailer is missing from the assembled PDF'
                                  ),
                                  B
                              )
                            : skip(
                                  'Giant-query PDF is complete, not truncated',
                                  `assembled PDF was ${p10b.map.GP_SIZE} bytes; a hex copy large enough to scan for %%EOF would exceed the Apex heap`,
                                  B
                              )
                    );
                    checks.push(
                        check(
                            'Giant-query output is named from Document_Title_Format__c',
                            String(p10b.map.GP_TITLE || '').includes(`${PFX}-giant-`),
                            `ContentVersion.Title was "${p10b.map.GP_TITLE}", expected it to start with "${PFX}-giant-"`,
                            MA
                        )
                    );
                }
            } else {
                checks.push(
                    skip(
                        'Giant-query assembled PDF inspection',
                        `job status=${status || 'unknown'}, Merged_PDF_CV__c=${pdfCvId || 'null'} — no artefact to inspect`,
                        B
                    )
                );
            }

            // The v2.5.0 regression (chrome dropped from giant output) is a
            // CONTENT failure and cannot be proven from Apex.
            checks.push(
                skip(
                    'Giant-query PDF retains template chrome (title, column headers, footer)',
                    'the giant path builds its HTML inside the assembler and does not set DocGenService.lastRenderedHtml, and Apex cannot extract text from a rendered PDF. This is the exact shape of the v2.5.0 regression, so it is a real gap — it needs a PDF text-extraction step outside Apex.',
                    B
                )
            );
        }
    } catch (e) {
        // A suite must never throw. Whatever went wrong becomes a visible check.
        checks.push(
            check(
                'output-formats suite ran to completion',
                false,
                `unexpected harness error: ${String(e.message).slice(0, 240)}`,
                B
            )
        );
    } finally {
        /* ============================================================ *
         * PHASE 11 — cleanup, always
         * ContentDocuments must be gathered BEFORE the templates go, because
         * deleting a template only removes the link, not the file. Skipping
         * this fills the org and makes the next run's LIKE queries ambiguous.
         * ============================================================ */
        if (setupOk) {
            const p11 = await phase(
                org,
                'P11',
                `
String PFX = '${PFX}';
String lk = PFX + '%'; // NOT 'like' — that is a reserved word in Apex
Integer docs = 0, tmpls = 0, accts = 0, jobs = 0;

try {
    List<Id> tmplIds = new List<Id>();
    for (DocGen_Template__c t : [SELECT Id FROM DocGen_Template__c WHERE Name LIKE :lk]) { tmplIds.add(t.Id); }
    tmpls = tmplIds.size();

    // Jobs first — they reference the templates.
    if (!tmplIds.isEmpty()) {
        List<DocGen_Job__c> js = [SELECT Id FROM DocGen_Job__c WHERE Template__c IN :tmplIds];
        jobs = js.size();
        if (!js.isEmpty()) { delete js; }
    }

    // Every file linked to a template (bodies, pre-decomposed parts, snapshots)
    // plus every generated output named from Document_Title_Format__c.
    Set<Id> cdIds = new Set<Id>();
    if (!tmplIds.isEmpty()) {
        for (ContentDocumentLink l : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId IN :tmplIds]) {
            cdIds.add(l.ContentDocumentId);
        }
    }
    for (ContentVersion cv : [SELECT ContentDocumentId FROM ContentVersion WHERE Title LIKE :lk]) {
        cdIds.add(cv.ContentDocumentId);
    }
    if (!cdIds.isEmpty()) {
        List<ContentDocument> cds = [SELECT Id FROM ContentDocument WHERE Id IN :cdIds];
        docs = cds.size();
        delete cds;
    }

    if (!tmplIds.isEmpty()) { delete [SELECT Id FROM DocGen_Template__c WHERE Id IN :tmplIds]; }

    // Contacts cascade with the Accounts.
    List<Account> doomedAccts = [SELECT Id FROM Account WHERE Name LIKE :lk];
    accts = doomedAccts.size();
    if (!doomedAccts.isEmpty()) { delete doomedAccts; }

    System.debug('CL_ERR=');
} catch (Exception e) {
    System.debug('CL_ERR=' + e.getMessage());
}
System.debug('CL_DOCS=' + docs);
System.debug('CL_TMPLS=' + tmpls);
System.debug('CL_ACCTS=' + accts);
System.debug('CL_JOBS=' + jobs);
System.debug('PHASE_DONE=P11');
`
            );
            // Cleanup failing is not a product bug, but leaving debris makes the
            // NEXT run untrustworthy, so it is reported rather than swallowed.
            checks.push(
                check(
                    'Suite fixtures cleaned up',
                    p11.ok && !p11.map.CL_ERR,
                    p11.ok
                        ? `removed ${p11.map.CL_TMPLS} templates, ${p11.map.CL_ACCTS} accounts, ${p11.map.CL_DOCS} files, ${p11.map.CL_JOBS} jobs${p11.map.CL_ERR ? ` (error: ${p11.map.CL_ERR})` : ''}`
                        : `cleanup phase died: ${p11.error}. Records prefixed ${PFX} are still in the org.`,
                    MI
                )
            );
        }
    }

    return suiteResult('output-formats', 'Output formats', checks);
}
