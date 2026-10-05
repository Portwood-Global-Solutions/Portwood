/**
 * DocGenPdfMerger — merges Portwood-generated PDFs and pads odd-length documents
 * with a blank page for duplex printing (#382).
 *
 * Fixtures are real Blob.toPdf() output (Flying Saucer / iText) captured from a
 * scratch org — 1-, 2- and 3-page documents — embedded as base64 so the tests
 * do not depend on Blob.toPdf() working in an @IsTest context.
 */
@IsTest
private class DocGenPdfMergerTest {
    // 1-page PDF
    private static final String FX1_B64 = 'JVBERi0xLjQKJeLjz9MKMyAwIG9iaiA8PC9GaWx0ZXIvRmxhdGVEZWNvZGUvTGVuZ3RoIDEyNz4+c3RyZWFtCnicVY69CsJQFIP3PEVGXa7n/h5dBR0EwcIBB3ErKsUKdfH1vW1xkCwfCSQZsDUIdRNoLXaGBgPESdTMDwIPNezghUdcrsIWsVBzYY+sMz0nisVJqhz/cM4fOONVe0a97+Pgau8ZEu0GP7meKVCDurym9Vic/NK635sGX7T6IQMKZW5kc3RyZWFtCmVuZG9iagoxIDAgb2JqPDwvQ29udGVudHMgMyAwIFIvVHlwZS9QYWdlL1Jlc291cmNlczw8L1Byb2NTZXQgWy9QREYgL1RleHQgL0ltYWdlQiAvSW1hZ2VDIC9JbWFnZUldL0ZvbnQ8PC9GMSAyIDAgUj4+Pj4vUGFyZW50IDQgMCBSL01lZGlhQm94WzAgMCA2MTIgNzkyXT4+CmVuZG9iagoyIDAgb2JqPDwvU3VidHlwZS9UeXBlMS9UeXBlL0ZvbnQvQmFzZUZvbnQvVGltZXMtQm9sZC9FbmNvZGluZy9XaW5BbnNpRW5jb2Rpbmc+PgplbmRvYmoKNCAwIG9iajw8L0tpZHNbMSAwIFJdL1R5cGUvUGFnZXMvQ291bnQgMT4+CmVuZG9iago1IDAgb2JqPDwvVHlwZS9DYXRhbG9nL1BhZ2VzIDQgMCBSPj4KZW5kb2JqCjYgMCBvYmo8PC9Nb2REYXRlKEQ6MjAyNjA5MDgxMDM1NDZaKS9DcmVhdGlvbkRhdGUoRDoyMDI2MDkwODEwMzU0NlopL1Byb2R1Y2VyKGlUZXh0IDIuMC44IFwoYnkgbG93YWdpZS5jb21cKSk+PgplbmRvYmoKeHJlZgowIDcKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMjA5IDAwMDAwIG4gCjAwMDAwMDAzNjUgMDAwMDAgbiAKMDAwMDAwMDAxNSAwMDAwMCBuIAowMDAwMDAwNDUzIDAwMDAwIG4gCjAwMDAwMDA1MDMgMDAwMDAgbiAKMDAwMDAwMDU0NyAwMDAwMCBuIAp0cmFpbGVyCjw8L0luZm8gNiAwIFIvSUQgWzxhMmI2OWVlNGM5NTQzYmRmNTc2N2VkZjU3MTU5ZDkzNz48NzQxYmRhZGU1ZTZhOGI2MjE4NmFjMGFlZDJkZDgyMTQ+XS9Sb290IDUgMCBSL1NpemUgNz4+CnN0YXJ0eHJlZgo2NjYKJSVFT0YK';

    // 2-page PDF
    private static final String FX2_B64 = 'JVBERi0xLjQKJeLjz9MKMyAwIG9iaiA8PC9GaWx0ZXIvRmxhdGVEZWNvZGUvTGVuZ3RoIDEyOD4+c3RyZWFtCnicVY69CsJQFIP3PEVGXa7n/h4dFXQQHAoHHMStqBQr1MXX97bFQbJ8JJBkwM4g1E2gtdgbGgwQJ1EzPwg81rCDF55wuQpbxELNhT2yzvScKBYnqXL8wzl/4IxX7Rn1vo+Dq4NnSLQb/OR6pkAN6vKa1mOx9Uvrfm8afAG0GSD0CmVuZHN0cmVhbQplbmRvYmoKMSAwIG9iajw8L0NvbnRlbnRzIDMgMCBSL1R5cGUvUGFnZS9SZXNvdXJjZXM8PC9Qcm9jU2V0IFsvUERGIC9UZXh0IC9JbWFnZUIgL0ltYWdlQyAvSW1hZ2VJXS9Gb250PDwvRjEgMiAwIFI+Pj4+L1BhcmVudCA0IDAgUi9NZWRpYUJveFswIDAgNjEyIDc5Ml0+PgplbmRvYmoKNSAwIG9iaiA8PC9GaWx0ZXIvRmxhdGVEZWNvZGUvTGVuZ3RoIDEyNz4+c3RyZWFtCnicVY69CsJQFIP3PEVGXa7n/h46KuggOBQOOIhbUSlWqIuv722Lg2T5SCDJiJ1BqE2gddgbWowQJ1EzPwg81rCHF55wuQo7xELNhQOyLvScKRYnqXL8wyV/4IxX7Zn0vk+Dm4NnSLQb/Ox6pkD16lJDG7DahrX1vzctvrQNIPQKZW5kc3RyZWFtCmVuZG9iago2IDAgb2JqPDwvQ29udGVudHMgNSAwIFIvVHlwZS9QYWdlL1Jlc291cmNlczw8L1Byb2NTZXQgWy9QREYgL1RleHQgL0ltYWdlQiAvSW1hZ2VDIC9JbWFnZUldL0ZvbnQ8PC9GMSAyIDAgUj4+Pj4vUGFyZW50IDQgMCBSL01lZGlhQm94WzAgMCA2MTIgNzkyXT4+CmVuZG9iagoyIDAgb2JqPDwvU3VidHlwZS9UeXBlMS9UeXBlL0ZvbnQvQmFzZUZvbnQvVGltZXMtQm9sZC9FbmNvZGluZy9XaW5BbnNpRW5jb2Rpbmc+PgplbmRvYmoKNCAwIG9iajw8L0tpZHNbMSAwIFIgNiAwIFJdL1R5cGUvUGFnZXMvQ291bnQgMj4+CmVuZG9iago3IDAgb2JqPDwvVHlwZS9DYXRhbG9nL1BhZ2VzIDQgMCBSPj4KZW5kb2JqCjggMCBvYmo8PC9Nb2REYXRlKEQ6MjAyNjA5MDgxMDM1NDZaKS9DcmVhdGlvbkRhdGUoRDoyMDI2MDkwODEwMzU0NlopL1Byb2R1Y2VyKGlUZXh0IDIuMC44IFwoYnkgbG93YWdpZS5jb21cKSk+PgplbmRvYmoKeHJlZgowIDkKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMjEwIDAwMDAwIG4gCjAwMDAwMDA3MTYgMDAwMDAgbiAKMDAwMDAwMDAxNSAwMDAwMCBuIAowMDAwMDAwODA0IDAwMDAwIG4gCjAwMDAwMDAzNjYgMDAwMDAgbiAKMDAwMDAwMDU2MCAwMDAwMCBuIAowMDAwMDAwODYwIDAwMDAwIG4gCjAwMDAwMDA5MDQgMDAwMDAgbiAKdHJhaWxlcgo8PC9JbmZvIDggMCBSL0lEIFs8ZWFlMTE4ZjJjNDljMmNmMmI3YWFhYWZkYmYyNWQxMWM+PDJmYzhlZjI4NmQwNTA5NjdiZjA4NDYwNWJhN2Q4N2EwPl0vUm9vdCA3IDAgUi9TaXplIDk+PgpzdGFydHhyZWYKMTAyMwolJUVPRgo=';

    // 3-page PDF
    private static final String FX3_B64 = 'JVBERi0xLjQKJeLjz9MKMyAwIG9iaiA8PC9GaWx0ZXIvRmxhdGVEZWNvZGUvTGVuZ3RoIDEyNz4+c3RyZWFtCnicVY69CsJQFIP3PEVGXa7n/h5dCzoIDoUDDuJWVIoV6uLre9viIFk+EkgyojEIdRdoHfaGFiPESdTMDwKPNezhhSdcrsIOsVBz4YCsCz1nisVJqhz/cMkfOONVeya979Pg5uAZEu0GP7ueKVCDurylDVg1fm39702LL7QoIPUKZW5kc3RyZWFtCmVuZG9iagoxIDAgb2JqPDwvQ29udGVudHMgMyAwIFIvVHlwZS9QYWdlL1Jlc291cmNlczw8L1Byb2NTZXQgWy9QREYgL1RleHQgL0ltYWdlQiAvSW1hZ2VDIC9JbWFnZUldL0ZvbnQ8PC9GMSAyIDAgUj4+Pj4vUGFyZW50IDQgMCBSL01lZGlhQm94WzAgMCA2MTIgNzkyXT4+CmVuZG9iago1IDAgb2JqIDw8L0ZpbHRlci9GbGF0ZURlY29kZS9MZW5ndGggMTI3Pj5zdHJlYW0KeJxVjr0KwlAUg/c8RUZdruf+HroWdBAcCgccxK2oFCvUxdf3tsVBsnwkkGRCaxBqE2g99oYOE8RJ1MwPAo81HOCFJ1yuwh6xUHPhiKwrPReKxUmqHP9wzR8441V7Zr3v8+Du4BkS7Qa/uJ4pUL261NBGbNqwteH3psMXtBwg9QplbmRzdHJlYW0KZW5kb2JqCjYgMCBvYmo8PC9Db250ZW50cyA1IDAgUi9UeXBlL1BhZ2UvUmVzb3VyY2VzPDwvUHJvY1NldCBbL1BERiAvVGV4dCAvSW1hZ2VCIC9JbWFnZUMgL0ltYWdlSV0vRm9udDw8L0YxIDIgMCBSPj4+Pi9QYXJlbnQgNCAwIFIvTWVkaWFCb3hbMCAwIDYxMiA3OTJdPj4KZW5kb2JqCjcgMCBvYmogPDwvRmlsdGVyL0ZsYXRlRGVjb2RlL0xlbmd0aCAxMjc+PnN0cmVhbQp4nFWOvQrCUBSD9zxFRl2u5/4euhZ0EBwKBxzEragUK9TF1/e2xUGyfCSQZEJrEGoTaD32hg4TxEnUzA8CjzUc4IUnXK7CHrFQc+GIrCs9F4rFSaoc/3DNHzjjVXtmve/z4O7gGRLtBr+4nilQvbrU0EZs2ri14femwxe0KiD2CmVuZHN0cmVhbQplbmRvYmoKOCAwIG9iajw8L0NvbnRlbnRzIDcgMCBSL1R5cGUvUGFnZS9SZXNvdXJjZXM8PC9Qcm9jU2V0IFsvUERGIC9UZXh0IC9JbWFnZUIgL0ltYWdlQyAvSW1hZ2VJXS9Gb250PDwvRjEgMiAwIFI+Pj4+L1BhcmVudCA0IDAgUi9NZWRpYUJveFswIDAgNjEyIDc5Ml0+PgplbmRvYmoKMiAwIG9iajw8L1N1YnR5cGUvVHlwZTEvVHlwZS9Gb250L0Jhc2VGb250L1RpbWVzLUJvbGQvRW5jb2RpbmcvV2luQW5zaUVuY29kaW5nPj4KZW5kb2JqCjQgMCBvYmo8PC9LaWRzWzEgMCBSIDYgMCBSIDggMCBSXS9UeXBlL1BhZ2VzL0NvdW50IDM+PgplbmRvYmoKOSAwIG9iajw8L1R5cGUvQ2F0YWxvZy9QYWdlcyA0IDAgUj4+CmVuZG9iagoxMCAwIG9iajw8L01vZERhdGUoRDoyMDI2MDkwODEwMzU0NlopL0NyZWF0aW9uRGF0ZShEOjIwMjYwOTA4MTAzNTQ2WikvUHJvZHVjZXIoaVRleHQgMi4wLjggXChieSBsb3dhZ2llLmNvbVwpKT4+CmVuZG9iagp4cmVmCjAgMTEKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMjA5IDAwMDAwIG4gCjAwMDAwMDEwNjUgMDAwMDAgbiAKMDAwMDAwMDAxNSAwMDAwMCBuIAowMDAwMDAxMTUzIDAwMDAwIG4gCjAwMDAwMDAzNjUgMDAwMDAgbiAKMDAwMDAwMDU1OSAwMDAwMCBuIAowMDAwMDAwNzE1IDAwMDAwIG4gCjAwMDAwMDA5MDkgMDAwMDAgbiAKMDAwMDAwMTIxNSAwMDAwMCBuIAowMDAwMDAxMjU5IDAwMDAwIG4gCnRyYWlsZXIKPDwvSW5mbyAxMCAwIFIvSUQgWzw2ZDIzMTQ1MmMyYWRjNWJlMTJjMWJlOTVmM2JkZWZlMD48YWQwNDBmOWQ4YTQ2MjczOGVlZmY3MTZkNjRjZGJhNGY+XS9Sb290IDkgMCBSL1NpemUgMTE+PgpzdGFydHhyZWYKMTM3OQolJUVPRgo=';

    private static Blob fx(String b64) {
        return EncodingUtil.base64Decode(b64);
    }

    @IsTest
    static void pageCountReadsEachDocument() {
        Test.startTest();
        System.assertEquals(1, DocGenPdfMerger.pageCount(fx(FX1_B64)), '1-page fixture');
        System.assertEquals(2, DocGenPdfMerger.pageCount(fx(FX2_B64)), '2-page fixture');
        System.assertEquals(3, DocGenPdfMerger.pageCount(fx(FX3_B64)), '3-page fixture');
        Test.stopTest();
    }

    @IsTest
    static void padFalseConcatenatesWithNoPadding() {
        Test.startTest();
        Blob merged = DocGenPdfMerger.mergePdfs(new List<Blob>{ fx(FX2_B64), fx(FX3_B64), fx(FX2_B64) }, false);
        Test.stopTest();
        System.assertEquals(7, DocGenPdfMerger.pageCount(merged), '2 + 3 + 2, no blanks');
        System.assertEquals(0, DocGenPdfMerger.blankPageCount(merged), 'padding off adds no blank pages');
    }

    @IsTest
    static void padTrueAddsOneBlankToEveryOddDocument() {
        Test.startTest();
        // [3, 2, 3] — both 3-page documents are odd (including the last one)
        Blob merged = DocGenPdfMerger.mergePdfs(new List<Blob>{ fx(FX3_B64), fx(FX2_B64), fx(FX3_B64) }, true);
        Test.stopTest();
        System.assertEquals(10, DocGenPdfMerger.pageCount(merged), '(3+1) + 2 + (3+1)');
        System.assertEquals(2, DocGenPdfMerger.blankPageCount(merged), 'one blank per odd document, last included');
    }

    @IsTest
    static void evenDocumentsAreNeverPadded() {
        Test.startTest();
        Blob merged = DocGenPdfMerger.mergePdfs(new List<Blob>{ fx(FX2_B64), fx(FX2_B64) }, true);
        Test.stopTest();
        System.assertEquals(4, DocGenPdfMerger.pageCount(merged), '2 + 2');
        System.assertEquals(0, DocGenPdfMerger.blankPageCount(merged), 'padding only acts on odd documents');
    }

    @IsTest
    static void everyOddDocumentGetsExactlyOneBlank() {
        Test.startTest();
        Blob merged = DocGenPdfMerger.mergePdfs(new List<Blob>{ fx(FX1_B64), fx(FX1_B64), fx(FX1_B64) }, true);
        Test.stopTest();
        System.assertEquals(6, DocGenPdfMerger.pageCount(merged), '3 x (1 + 1 blank)');
        System.assertEquals(3, DocGenPdfMerger.blankPageCount(merged), 'one blank per odd document');
    }

    @IsTest
    static void mergedOutputReParsesCleanly() {
        Test.startTest();
        Blob merged = DocGenPdfMerger.mergePdfs(new List<Blob>{ fx(FX3_B64), fx(FX2_B64) }, true);
        // feed the merged PDF back through the merger as a source — proves the
        // object graph, /Kids, xref and trailer we wrote are all well-formed
        Blob remerged = DocGenPdfMerger.mergePdfs(new List<Blob>{ merged, merged }, false);
        Test.stopTest();
        System.assertEquals(6, DocGenPdfMerger.pageCount(merged), '(3+1) + 2');
        System.assertEquals(12, DocGenPdfMerger.pageCount(remerged), 'merged PDF is itself parseable');
    }

    @IsTest
    static void singleDocumentUnpaddedIsReturnedUntouched() {
        Blob src = fx(FX2_B64);
        Test.startTest();
        Blob out = DocGenPdfMerger.mergePdfs(new List<Blob>{ src }, false);
        Test.stopTest();
        System.assertEquals(src.size(), out.size(), 'single PDF + no padding is a pass-through');
    }

    @IsTest
    static void singleOddDocumentIsPaddedWhenRequested() {
        Test.startTest();
        Blob out = DocGenPdfMerger.mergePdfs(new List<Blob>{ fx(FX1_B64) }, true);
        Test.stopTest();
        System.assertEquals(2, DocGenPdfMerger.pageCount(out), '1-page document padded to 2');
        System.assertEquals(1, DocGenPdfMerger.blankPageCount(out), 'one blank added');
    }

    @IsTest
    static void nullOrEmptyInputThrows() {
        Test.startTest();
        try {
            DocGenPdfMerger.mergePdfs(null, false);
            System.assert(false, 'null input should throw');
        } catch (DocGenPdfMerger.DocGenPdfMergeException e) {
            System.assert(e.getMessage().containsIgnoreCase('no pdf'), e.getMessage());
        }
        try {
            DocGenPdfMerger.mergePdfs(new List<Blob>(), false);
            System.assert(false, 'empty input should throw');
        } catch (DocGenPdfMerger.DocGenPdfMergeException e) {
            System.assert(e.getMessage().containsIgnoreCase('no pdf'), e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void nonPdfAndEncryptedInputAreRejected() {
        Test.startTest();
        try {
            DocGenPdfMerger.mergePdfs(new List<Blob>{ Blob.valueOf('not a pdf at all'), fx(FX2_B64) }, false);
            System.assert(false, 'non-PDF should throw');
        } catch (DocGenPdfMerger.DocGenPdfMergeException e) {
            System.assert(e.getMessage().containsIgnoreCase('not a pdf'), e.getMessage());
        }
        try {
            DocGenPdfMerger.mergePdfs(
                new List<Blob>{ Blob.valueOf('%PDF-1.4\n<< /Encrypt 9 0 R >>'), fx(FX2_B64) },
                false
            );
            System.assert(false, 'encrypted PDF should throw');
        } catch (DocGenPdfMerger.DocGenPdfMergeException e) {
            System.assert(e.getMessage().containsIgnoreCase('encrypt'), e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void identicalContentDocumentsKeepEveryPage() {
        // #382 regression: a template that renders byte-identical page content
        // for every record (a static contract, T&Cs, a cover letter with no
        // effective merge fields) produces parts whose content streams match
        // across documents. Dedup must NOT collapse those — only embedded font
        // programs are safe to share. Earlier the stream dedup dropped the
        // repeated pages, leaving a short, corrupt packet.
        Blob one = fx(FX3_B64); // 3-page document
        Test.startTest();
        Blob merged = DocGenPdfMerger.mergePdfs(new List<Blob>{ one, one, one }, false);
        Test.stopTest();

        System.assertEquals(
            9,
            DocGenPdfMerger.pageCount(merged),
            'all 3x3 pages must survive an identical-content merge'
        );
        System.assertEquals(0, DocGenPdfMerger.blankPageCount(merged), 'no page should lose its content stream');
        // Every page keeps its own content: the merged size tracks 3x the source,
        // not the ~1x an over-eager content-stream dedup would collapse it to.
        System.assert(
            merged.size() > one.size() * 2,
            'identical documents must not be deduped down to one copy (got ' +
                merged.size() +
                ' from 3x ' +
                one.size() +
                ')'
        );
    }

    // A page of mixed CJK / Cyrillic / accented-Latin / symbols. Non-Latin content
    // makes Flying Saucer embed an Arial Unicode MS CID (Type0) font subset — the
    // exact case the font-program dedup targets.
    private static Blob nonLatinDoc(String text) {
        return Blob.toPdf(
            '<html><head><style>body{font-family:"Arial Unicode MS",sans-serif;font-size:14pt}' +
                '.pb{page-break-before:always}</style></head><body>' +
                '<p>' +
                text +
                '</p><div class="pb"></div><p>page two ' +
                text +
                '</p></body></html>'
        );
    }

    @IsTest
    static void identicalNonLatinDocumentsDedupeFontWithoutCorruption() {
        // #382 — a static contract in Japanese generated for many records: the
        // embedded CID font subsets are byte-identical, so the dedup collapses
        // them. It must keep every page and every glyph — only the font *program*
        // is shared, never the CID→GID map, widths or ToUnicode CMap (those ride
        // with the per-document font dict).
        Blob jp = nonLatinDoc('販売店契約書 税込 ¥1,000,000 — 支払は30日以内');
        Blob single = DocGenPdfMerger.mergePdfs(new List<Blob>{ jp }, false);

        Test.startTest();
        Blob merged = DocGenPdfMerger.mergePdfs(new List<Blob>{ jp, jp, jp, jp, jp }, true);
        Test.stopTest();

        // 5 two-page docs, each even → no padding.
        System.assertEquals(10, DocGenPdfMerger.pageCount(merged), '5 x 2 pages, no blanks (even docs)');
        System.assertEquals(0, DocGenPdfMerger.blankPageCount(merged), 'even non-Latin docs are never padded');
        // Re-parse proves the object graph, xref and repointed font refs are sound.
        System.assertEquals(
            20,
            DocGenPdfMerger.pageCount(DocGenPdfMerger.mergePdfs(new List<Blob>{ merged, merged }, false)),
            'the merged non-Latin packet must itself re-parse cleanly'
        );
        // The font dedup fired: 5 identical subsets collapse toward one embedded
        // program, so the packet is far smaller than five standalone copies.
        System.assert(
            merged.size() < single.size() * 3,
            'identical CID font subsets should be deduplicated (got ' + merged.size() + ' vs 5x ' + single.size() + ')'
        );
    }

    @IsTest
    static void differentNonLatinCharsetsAreNotDeduped() {
        // Different scripts → different font subsets → different fingerprints. The
        // dedup must leave both programs in place; collapsing them would render the
        // wrong glyphs.
        Blob jp = nonLatinDoc('日本語 テキスト こんにちは');
        Blob cy = nonLatinDoc('Привет мир Δοκιμή № 7 Übermäßig');

        Test.startTest();
        Blob merged = DocGenPdfMerger.mergePdfs(new List<Blob>{ jp, cy }, false);
        Test.stopTest();

        System.assertEquals(4, DocGenPdfMerger.pageCount(merged), 'both 2-page docs survive');
        System.assertEquals(
            0,
            DocGenPdfMerger.blankPageCount(merged),
            'no page loses its content stream when subsets differ'
        );
    }
}
