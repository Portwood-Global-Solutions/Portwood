@IsTest
private class DocGenPdfDocumentTest {
    @IsTest
    static void mergesModernCompressedAndClassicPdfObjects() {
        Test.startTest();
        Blob output = DocGenPdfMerger.mergePdfs(
            new List<Blob>{ DocGenPdfMergeFixtures.modern(), DocGenPdfMergeFixtures.classic() },
            false
        );
        Test.stopTest();
        DocGenPdfDocument doc = new DocGenPdfDocument(output);
        System.assertEquals(3, doc.pageList.size());
        System.assertEquals(0, DocGenPdfMerger.blankPageCount(output));
        System.assertEquals(
            6,
            DocGenPdfMerger.pageCount(DocGenPdfMerger.mergePdfs(new List<Blob>{ output, output }, false))
        );
    }
    @IsTest
    static void preservesNonzeroGenerationsAndIndirectStreamLength() {
        Test.startTest();
        Blob output = DocGenPdfMerger.mergePdfs(
            new List<Blob>{ DocGenPdfMergeFixtures.generation(), DocGenPdfMergeFixtures.modern() },
            false
        );
        Test.stopTest();
        System.assertEquals(2, DocGenPdfMerger.pageCount(output));
        System.assertEquals(0, DocGenPdfMerger.blankPageCount(output));
    }
    @IsTest
    static void preservesInheritedPageResourcesAndRotation() {
        Test.startTest();
        Blob output = DocGenPdfMerger.mergePdfs(
            new List<Blob>{ DocGenPdfMergeFixtures.inherited(), DocGenPdfMergeFixtures.modern() },
            true
        );
        Test.stopTest();
        DocGenPdfDocument doc = new DocGenPdfDocument(output);
        System.assertEquals(4, doc.pageList.size());
        DocGenPdfDocument.Value first = doc.resolve(doc.pageList[0]);
        DocGenPdfDocument.Value parent = doc.resolve(first.entries.get('Parent'));
        System.assertEquals(90, DocGenPdfDocument.intValue(parent.entries.get('Rotate')));
        System.assertNotEquals(null, parent.entries.get('Resources'));
        System.assertNotEquals(null, parent.entries.get('MediaBox'));
    }
    @IsTest
    static void keepsFormsValuesAndSeparatesDuplicateFieldNames() {
        Test.startTest();
        Blob output = DocGenPdfMerger.mergePdfs(
            new List<Blob>{ DocGenPdfMergeFixtures.formAlpha(), DocGenPdfMergeFixtures.formBravo() },
            false
        );
        Test.stopTest();
        DocGenPdfDocument doc = new DocGenPdfDocument(output);
        DocGenPdfDocument.Value form = doc.resolve(doc.catalog.entries.get('AcroForm'));
        System.assertNotEquals(null, form);
        DocGenPdfDocument.Value fields = doc.resolve(form.entries.get('Fields'));
        System.assertEquals(2, fields.items.size());
        for (Integer i = 0; i < 2; i++) {
            DocGenPdfDocument.Value parent = doc.resolve(fields.items[i]);
            System.assertEquals('(Document_' + (i + 1) + ')', parent.entries.get('T').text);
            DocGenPdfDocument.Value child = doc.resolve(doc.resolve(parent.entries.get('Kids')).items[0]);
            System.assertEquals(fields.items[i].key, child.entries.get('Parent').key);
            System.assertEquals(i == 0 ? '(ALPHA)' : '(BRAVO)', child.entries.get('V').text);
            System.assertNotEquals(null, child.entries.get('AP'));
        }
    }
    @IsTest
    static void detectsInvalidCrossReferenceOffsets() {
        Test.startTest();
        try {
            DocGenPdfMerger.mergePdfs(
                new List<Blob>{ Blob.valueOf('%PDF-1.7\nstartxref\n9999\n%%EOF'), DocGenPdfMergeFixtures.modern() },
                false
            );
            System.assert(false, 'Invalid offset must fail');
        } catch (DocGenPdfMerger.DocGenPdfMergeException e) {
            System.assert(e.getMessage().contains('offset'), e.getMessage());
        }
        Test.stopTest();
    }
    @IsTest
    static void usesNewestIncrementalCatalogAndHybridObjectIndex() {
        Test.startTest();
        System.assertEquals(
            2,
            DocGenPdfMerger.pageCount(DocGenPdfMergeFixtures.incremental()),
            'Newest root contains two pages, original root one'
        );
        System.assertEquals(
            1,
            DocGenPdfMerger.pageCount(DocGenPdfMergeFixtures.hybrid()),
            'Hybrid stream overrides same-revision free placeholders'
        );
        Blob output = DocGenPdfMerger.mergePdfs(
            new List<Blob>{ DocGenPdfMergeFixtures.incremental(), DocGenPdfMergeFixtures.hybrid() },
            false
        );
        Test.stopTest();
        System.assertEquals(3, DocGenPdfMerger.pageCount(output));
    }
    @IsTest
    static void doesNotRewriteReferenceTextInsideAnnotationStrings() {
        Blob output = DocGenPdfMerger.mergePdfs(
            new List<Blob>{ DocGenPdfMergeFixtures.modern(), DocGenPdfMergeFixtures.classic() },
            false
        );
        DocGenPdfDocument doc = new DocGenPdfDocument(output);
        DocGenPdfDocument.Value page = doc.resolve(doc.pageList[0]);
        DocGenPdfDocument.Value annotations = doc.resolve(page.entries.get('Annots'));
        DocGenPdfDocument.Value annotation = doc.resolve(annotations.items[0]);
        System.assert(
            annotation.entries.get('Contents').text.contains('9 0 R'),
            'Literal strings must not be renumbered'
        );
    }
    private static Blob minimalPdf(String catalogExtra, List<String> extraObjects) {
        List<String> bodies = new List<String>{
            '<< /Type /Catalog /Pages 2 0 R ' +
            catalogExtra +
            ' >>',
            '<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300] /Resources << >> >>',
            '<< /Type /Page /Parent 2 0 R >>'
        };
        bodies.addAll(extraObjects);
        String data = '%PDF-1.7\n';
        List<Integer> offsets = new List<Integer>();
        for (Integer i = 0; i < bodies.size(); i++) {
            offsets.add(data.length());
            data += (i + 1) + ' 0 obj\n' + bodies[i] + '\nendobj\n';
        }
        Integer xrefOffset = data.length();
        data += 'xref\n0 ' + (bodies.size() + 1) + '\n0000000000 65535 f \n';
        for (Integer offset : offsets)
            data += String.valueOf(offset).leftPad(10, '0') + ' 00000 n \n';
        data += 'trailer\n<< /Size ' + (bodies.size() + 1) + ' /Root 1 0 R >>\nstartxref\n' + xrefOffset + '\n%%EOF\n';
        return Blob.valueOf(data);
    }
    @IsTest
    static void rejectsXfaSignaturesAndFormCalculationsOrScripts() {
        List<Blob> unsupported = new List<Blob>{
            minimalPdf('/AcroForm 4 0 R', new List<String>{ '<< /XFA (dynamic form) /Fields [] >>' }),
            minimalPdf(
                '/AcroForm 4 0 R',
                new List<String>{
                    '<< /Fields [5 0 R] >>',
                    '<< /FT /Sig /T (Signature) /V 6 0 R >>',
                    '<< /Type /Sig /Contents <00> >>'
                }
            ),
            minimalPdf(
                '/AcroForm 4 0 R',
                new List<String>{ '<< /Fields [5 0 R] /CO [5 0 R] >>', '<< /FT /Tx /T (Total) /V (1) >>' }
            ),
            minimalPdf(
                '/AcroForm 4 0 R',
                new List<String>{
                    '<< /Fields [5 0 R] >>',
                    '<< /FT /Tx /T (Total) /AA << /K << /S /JavaScript /JS (event.value=1;) >> >> >>'
                }
            )
        };
        List<String> expected = new List<String>{ 'XFA', 'signed', 'calculations', 'scripts' };
        Test.startTest();
        for (Integer i = 0; i < unsupported.size(); i++) {
            try {
                DocGenPdfMerger.mergePdfs(new List<Blob>{ unsupported[i], DocGenPdfMergeFixtures.modern() }, false);
                System.assert(false, 'Unsupported source must fail');
            } catch (DocGenPdfMerger.DocGenPdfMergeException e) {
                System.assert(e.getMessage().contains(expected[i]), e.getMessage());
            }
        }
        Test.stopTest();
    }
}
