@IsTest
private class DocGenAcroFormServiceTest {
    @IsTest
    static void fillsSimpleTextFieldsWithIncrementalUpdate() {
        Blob pdf = Blob.valueOf(simpleAcroFormPdf());
        Map<String, Object> data = new Map<String, Object>{
            'Name' => 'Ada (Pilot) \\ One',
            'Owner' => new Map<String, Object>{ 'Email' => 'ada@example.com' }
        };

        Blob filled = DocGenAcroFormService.fillPdfTemplate(pdf, data);

        System.assert(filled.size() > pdf.size(), 'Filled PDF should append an incremental update');
        System.assert(
            blobContains(filled, '/NeedAppearances true'),
            'AcroForm should ask readers to regenerate appearances'
        );
        System.assert(
            blobContains(filled, '/V (Ada \\(Pilot\\) \\\\ One)'),
            'Name field value should be escaped and filled'
        );
        System.assert(
            blobContains(filled, '/V (ada@example.com)'),
            'Nested field path should resolve from template data'
        );
        System.assert(blobContains(filled, '/Prev 0'), 'Incremental update should point back to the original xref');
    }

    @IsTest
    static void fillsAccentedTextFieldsWithPdfDocEncoding() {
        Blob pdf = Blob.valueOf(simpleAcroFormPdf());
        String arvore = 'Poda de ' + String.fromCharArray(new List<Integer>{ 193 }) + 'rvore';
        String solicitacao =
            'Solicita' +
            String.fromCharArray(new List<Integer>{ 231 }) +
            String.fromCharArray(new List<Integer>{ 227 }) +
            'o';
        Map<String, Object> data = new Map<String, Object>{
            'Name' => arvore,
            'Owner' => new Map<String, Object>{ 'Email' => solicitacao }
        };

        Blob filled = DocGenAcroFormService.fillPdfTemplate(pdf, data);
        String filledHex = EncodingUtil.convertToHex(filled).toLowerCase();

        System.assert(filled.size() > pdf.size(), 'Accented values should still append an incremental update');
        System.assert(
            filledHex.contains(
                EncodingUtil.convertToHex(
                        Blob.valueOf('/V <FEFF0050006F00640061002000640065002000C100720076006F00720065>')
                    )
                    .toLowerCase()
            ),
            'Accented field value should be written as UTF-16BE PDF text, not UTF-8 text'
        );
        System.assert(
            filledHex.contains(EncodingUtil.convertToHex(Blob.valueOf('00E7')).toLowerCase()) &&
            filledHex.contains(EncodingUtil.convertToHex(Blob.valueOf('00E3')).toLowerCase()),
            'Portuguese cedilla/tilde characters should be preserved in the PDF field value'
        );
    }

    @IsTest
    static void returnsOriginalWhenNoMappedFieldsResolve() {
        Blob pdf = Blob.valueOf(simpleAcroFormPdf());

        Blob out = DocGenAcroFormService.fillPdfTemplate(pdf, new Map<String, Object>{ 'Other' => 'Ignored' });

        System.assertEquals(pdf.size(), out.size(), 'Unmapped AcroForm should remain unchanged');
    }

    @IsTest
    static void inspectsFillableFieldNames() {
        String fields = DocGenAcroFormService.inspectFillableFields(Blob.valueOf(simpleAcroFormPdf()));

        System.assertEquals('Name,Owner.Email', fields);
    }

    @IsTest
    static void fillsRecursiveFieldTree() {
        Blob pdf = Blob.valueOf(recursiveAcroFormPdf());

        Blob filled = DocGenAcroFormService.fillPdfTemplate(pdf, new Map<String, Object>{ 'Name' => 'Recursive Ada' });

        System.assert(filled.size() > pdf.size(), 'Nested field should be filled through /Kids traversal');
        System.assert(blobContains(filled, '/V (Recursive Ada)'), 'Terminal child field should receive the value');
    }

    @IsTest
    static void fillsButtonFieldsWithNameValuesAndAppearanceState() {
        Blob pdf = Blob.valueOf(buttonAcroFormPdf());

        Blob filled = DocGenAcroFormService.fillPdfTemplate(pdf, new Map<String, Object>{ 'Approved__c' => true });

        System.assert(filled.size() > pdf.size(), 'Checked button field should append an incremental update');
        System.assert(blobContains(filled, '/V /Yes'), 'Button value should use a PDF name, not a text literal');
        System.assert(blobContains(filled, '/AS /Yes'), 'Widget appearance state should be checked');
    }

    @IsTest
    static void appendsXrefStreamWhenSourceUsesXrefStream() {
        Blob pdf = Blob.valueOf(xrefStreamMarkedAcroFormPdf());

        Blob filled = DocGenAcroFormService.fillPdfTemplate(pdf, new Map<String, Object>{ 'Name' => 'Stream Ada' });

        System.assert(filled.size() > pdf.size(), 'XRef-stream PDFs should still receive an incremental update');
        System.assert(blobContains(filled, '/Type /XRef'), 'Incremental update should use an xref stream');
        System.assert(blobContains(filled, '/V (Stream Ada)'), 'Field should be filled before xref-stream append');
    }

    @IsTest
    static void updatesXfaDatasetNodes() {
        String selfClosing = '<xfa:datasets><f1_01\n/><f1_02/></xfa:datasets>';
        String updatedSelfClosing = DocGenAcroFormService.withXfaFieldValue(selfClosing, 'f1_01', 'Ada & Co <Pilot>');

        System.assert(
            updatedSelfClosing.contains('<f1_01>Ada &amp; Co &lt;Pilot&gt;</f1_01>'),
            'XFA self-closing data node should be expanded with escaped text'
        );

        String paired = '<xfa:datasets><f1_01>Old</f1_01></xfa:datasets>';
        String updatedPaired = DocGenAcroFormService.withXfaFieldValue(paired, 'f1_01', 'New');

        System.assert(updatedPaired.contains('<f1_01>New</f1_01>'), 'Existing XFA data node value should be replaced');

        String accented = 'Poda de ' + String.fromCharArray(new List<Integer>{ 193 }) + 'rvore';
        String updatedAccented = DocGenAcroFormService.withXfaFieldValue(paired, 'f1_01', accented);

        System.assert(
            updatedAccented.contains('<f1_01>Poda de &#193;rvore</f1_01>'),
            'XFA XML should use numeric character references for accented values'
        );
    }

    @IsTest
    static void fillsFromSavedSnapshotAndUpdatesXfaDatasets() {
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'PDF Snapshot Render Test',
            Type__c = 'PDF',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        insert template;

        DocGen_Template_Version__c version = new DocGen_Template_Version__c(
            Template__c = template.Id,
            Type__c = 'PDF',
            Output_Format__c = 'PDF',
            Is_Active__c = true
        );
        insert version;

        insert new ContentVersion(
            Title = 'docgen_tmpl_pdf_' + String.valueOf(version.Id) + '_acroform',
            PathOnClient = 'snapshot.json',
            VersionData = Blob.valueOf(simpleSnapshotJson()),
            IsMajorVersion = true
        );

        Blob pdf = Blob.valueOf(snapshotBackedXfaPdf());
        String arvore = 'Poda de ' + String.fromCharArray(new List<Integer>{ 193 }) + 'rvore';
        Blob filled = DocGenAcroFormService.fillPdfTemplate(
            pdf,
            new Map<String, Object>{ 'Name' => arvore },
            template.Id
        );
        String filledHex = EncodingUtil.convertToHex(filled).toLowerCase();

        System.assert(filled.size() > pdf.size(), 'Saved snapshot should drive an incremental PDF update');
        System.assert(
            filledHex.contains(
                EncodingUtil.convertToHex(
                        Blob.valueOf('/V <FEFF0050006F00640061002000640065002000C100720076006F00720065>')
                    )
                    .toLowerCase()
            ),
            'Snapshot-mapped field value should be stored as UTF-16BE PDF text'
        );
        System.assert(
            filledHex.contains(
                EncodingUtil.convertToHex(Blob.valueOf(' Td <506F646120646520C172766F7265> Tj ')).toLowerCase()
            ),
            'Visible appearance text should use single-byte PDF font bytes for Latin accents'
        );
        System.assert(
            filledHex.contains(EncodingUtil.convertToHex(Blob.valueOf('<f1_01>')).toLowerCase()),
            'XFA datasets packet should be updated alongside AcroForm value'
        );
        System.assert(
            filledHex.contains(EncodingUtil.convertToHex(Blob.valueOf('Poda de &#193;rvore')).toLowerCase()),
            'XFA datasets packet should avoid raw UTF-8 accented bytes'
        );
    }

    @IsTest
    static void fillsSnapshotWithSeparateWidgetsAndButtonAppearances() {
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'PDF Widget Snapshot Render Test',
            Type__c = 'PDF',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name,Approved__c'
        );
        insert template;

        DocGen_Template_Version__c version = new DocGen_Template_Version__c(
            Template__c = template.Id,
            Type__c = 'PDF',
            Output_Format__c = 'PDF',
            Is_Active__c = true
        );
        insert version;

        insert new ContentVersion(
            Title = 'docgen_tmpl_pdf_' + String.valueOf(version.Id) + '_acroform',
            PathOnClient = 'snapshot.json',
            VersionData = Blob.valueOf(widgetSnapshotJson()),
            IsMajorVersion = true
        );

        Blob pdf = Blob.valueOf(widgetSnapshotPdf());
        Blob filled = DocGenAcroFormService.fillPdfTemplate(
            pdf,
            new Map<String, Object>{ 'Name' => 'Widget Ada', 'Approved__c' => true },
            template.Id
        );

        System.assert(filled.size() > pdf.size(), 'Widget snapshot should append an incremental update');
        System.assert(blobContains(filled, '/V (Widget Ada)'), 'Parent text field should receive the value');
        System.assert(blobContains(filled, '/AS /Yes'), 'Button widget should use the checked appearance state');
        System.assert(blobContains(filled, '/AP <</N <<'), 'Widgets should receive generated normal appearances');
    }

    @IsTest
    static void rejectsPdfWithoutAcroForm() {
        Boolean threw = false;
        try {
            DocGenAcroFormService.fillPdfTemplate(
                Blob.valueOf(
                    '%PDF-1.4\n' +
                        '1 0 obj\n<< /Type /Catalog >>\nendobj\n' +
                        'trailer\n<< /Size 2 /Root 1 0 R >>\n' +
                        'startxref\n0\n%%EOF\n'
                ),
                new Map<String, Object>{ 'Name' => 'Ada' }
            );
        } catch (DocGenException e) {
            threw = e.getMessage().contains('AcroForm');
        }

        System.assert(threw, 'PDF templates without AcroForm data should fail clearly');
    }

    @IsTest
    static void rejectsXfaFormClearly() {
        Boolean threw = false;
        try {
            DocGenAcroFormService.fillPdfTemplate(
                Blob.valueOf(
                    '%PDF-1.7\n' +
                        '1 0 obj\n<< /Type /Catalog /AcroForm 2 0 R >>\nendobj\n' +
                        '2 0 obj\n<< /XFA [ (template) 3 0 R ] >>\nendobj\n' +
                        '3 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n' +
                        'trailer\n<< /Size 4 /Root 1 0 R >>\n' +
                        'startxref\n0\n%%EOF\n'
                ),
                new Map<String, Object>{ 'Name' => 'Ada' }
            );
        } catch (DocGenException e) {
            threw = e.getMessage().contains('XFA PDF forms are not supported yet');
        }

        System.assert(threw, 'XFA PDFs should fail with a specific message');
    }

    @IsTest
    static void rejectsEncryptedPdfBeforeParsing() {
        Boolean threw = false;
        try {
            DocGenAcroFormService.fillPdfTemplate(
                Blob.valueOf(
                    '%PDF-1.7\n' +
                        '1 0 obj\n<< /Type /Catalog >>\nendobj\n' +
                        'trailer\n<< /Size 2 /Root 1 0 R /Encrypt 99 0 R >>\n' +
                        'startxref\n0\n%%EOF\n'
                ),
                new Map<String, Object>{ 'Name' => 'Ada' }
            );
        } catch (DocGenException e) {
            threw = e.getMessage().contains('Encrypted PDF AcroForm templates require a saved browser field snapshot');
        }

        System.assert(threw, 'Encrypted PDFs without a saved snapshot should fail before AcroForm parsing');
    }

    private static String simpleAcroFormPdf() {
        return '%PDF-1.4\n' +
            '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
            '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n' +
            '3 0 obj\n<< /Fields [5 0 R 6 0 R] >>\nendobj\n' +
            '4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R] >>\nendobj\n' +
            '5 0 obj\n<< /FT /Tx /T (Name) /Subtype /Widget /Rect [10 10 200 30] >>\nendobj\n' +
            '6 0 obj\n<< /FT /Tx /T (Owner.Email) /Subtype /Widget /Rect [10 40 200 60] /V (old) >>\nendobj\n' +
            'xref\n0 7\n' +
            '0000000000 65535 f \n' +
            '0000000009 00000 n \n' +
            '0000000076 00000 n \n' +
            '0000000135 00000 n \n' +
            '0000000184 00000 n \n' +
            '0000000281 00000 n \n' +
            '0000000357 00000 n \n' +
            'trailer\n<< /Size 7 /Root 1 0 R >>\n' +
            'startxref\n0\n' +
            '%%EOF\n';
    }

    private static String xrefStreamMarkedAcroFormPdf() {
        return '%PDF-1.5\n' +
            '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
            '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n' +
            '3 0 obj\n<< /Fields [5 0 R] >>\nendobj\n' +
            '4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>\nendobj\n' +
            '5 0 obj\n<< /FT /Tx /T (Name) /Subtype /Widget /Rect [10 10 200 30] >>\nendobj\n' +
            '6 0 obj\n<< /Type /XRef /Length 0 >>\nstream\n\nendstream\nendobj\n' +
            'trailer\n<< /Size 7 /Root 1 0 R >>\n' +
            'startxref\n0\n' +
            '%%EOF\n';
    }

    private static String recursiveAcroFormPdf() {
        return '%PDF-1.4\n' +
            '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
            '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n' +
            '3 0 obj\n<< /Fields [5 0 R] >>\nendobj\n' +
            '4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [6 0 R] >>\nendobj\n' +
            '5 0 obj\n<< /T (Parent) /Kids [6 0 R] >>\nendobj\n' +
            '6 0 obj\n<< /FT /Tx /T (Name) /Subtype /Widget /Rect [10 10 200 30] >>\nendobj\n' +
            'xref\n0 7\n' +
            '0000000000 65535 f \n' +
            '0000000009 00000 n \n' +
            '0000000076 00000 n \n' +
            '0000000135 00000 n \n' +
            '0000000177 00000 n \n' +
            '0000000259 00000 n \n' +
            '0000000309 00000 n \n' +
            'trailer\n<< /Size 7 /Root 1 0 R >>\n' +
            'startxref\n0\n' +
            '%%EOF\n';
    }

    private static String buttonAcroFormPdf() {
        return '%PDF-1.4\n' +
            '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
            '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n' +
            '3 0 obj\n<< /Fields [5 0 R] >>\nendobj\n' +
            '4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>\nendobj\n' +
            '5 0 obj\n<< /FT /Btn /T (Approved__c) /Subtype /Widget /Rect [10 10 30 30] /AP << /N << /Off 7 0 R /Yes 8 0 R >> >> /V /Off /AS /Off >>\nendobj\n' +
            '7 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n' +
            '8 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n' +
            'xref\n0 9\n' +
            '0000000000 65535 f \n' +
            '0000000009 00000 n \n' +
            '0000000076 00000 n \n' +
            '0000000135 00000 n \n' +
            '0000000177 00000 n \n' +
            '0000000274 00000 n \n' +
            '0000000000 00000 f \n' +
            '0000000418 00000 n \n' +
            '0000000470 00000 n \n' +
            'trailer\n<< /Size 9 /Root 1 0 R >>\n' +
            'startxref\n0\n' +
            '%%EOF\n';
    }

    private static String snapshotBackedXfaPdf() {
        return '%PDF-1.7\n' +
            '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
            '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n' +
            '3 0 obj\n<< /Fields [5 0 R] /XFA [ (datasets) 7 0 R ] >>\nendobj\n' +
            '4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>\nendobj\n' +
            '5 0 obj\n<< /FT /Tx /T (f1_01) /Subtype /Widget /Rect [10 10 200 30] >>\nendobj\n' +
            '7 0 obj\n<</Length 39/Type/EmbeddedFile>>stream\n' +
            '<xfa:datasets><f1_01/></xfa:datasets>\n' +
            'endstream\nendobj\n' +
            'xref\n0 8\n' +
            '0000000000 65535 f \n' +
            '0000000009 00000 n \n' +
            '0000000076 00000 n \n' +
            '0000000135 00000 n \n' +
            '0000000207 00000 n \n' +
            '0000000304 00000 n \n' +
            '0000000000 00000 f \n' +
            '0000000383 00000 n \n' +
            'trailer\n<< /Size 8 /Root 1 0 R >>\n' +
            'startxref\n0\n' +
            '%%EOF\n';
    }

    private static String simpleSnapshotJson() {
        return JSON.serialize(
            new Map<String, Object>{
                'version' => 1,
                'rootObjectNumber' => 1,
                'rootBody' => '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                'acroFormObjectNumber' => 3,
                'acroFormBody' => '<< /Fields [5 0 R] /XFA [ (datasets) 7 0 R ] >>',
                'size' => 8,
                'fields' => new List<Object>{
                    new Map<String, Object>{
                        'objectNumber' => 5,
                        'body' => '<< /FT /Tx /T (f1_01) /Subtype /Widget /Rect [10 10 200 30] >>',
                        'name' => 'form1[0].#subform[0].f1_01[0]',
                        'partialName' => 'f1_01[0]',
                        'fieldType' => 'Tx',
                        'mappedPath' => 'Name'
                    }
                },
                'xfaPackets' => new List<Object>{
                    new Map<String, Object>{
                        'name' => 'datasets',
                        'objectNumber' => 7,
                        'decodedStream' => '<xfa:datasets><f1_01/></xfa:datasets>'
                    }
                }
            }
        );
    }

    private static String widgetSnapshotPdf() {
        return '%PDF-1.7\n' +
            '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
            '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n' +
            '3 0 obj\n<< /Fields [5 0 R 8 0 R] /DA (/Helv 10 Tf 0 g) >>\nendobj\n' +
            '4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [6 0 R 8 0 R] >>\nendobj\n' +
            '5 0 obj\n<< /FT /Tx /T (Name) /Kids [6 0 R] >>\nendobj\n' +
            '6 0 obj\n<< /Subtype /Widget /Parent 5 0 R /Rect [10 10 210 35] >>\nendobj\n' +
            '8 0 obj\n<< /FT /Btn /T (Approved__c) /Subtype /Widget /Rect [10 45 30 65] /AP << /N << /Off 9 0 R /Yes 10 0 R >> >> /V /Off /AS /Off >>\nendobj\n' +
            '9 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n' +
            '10 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n' +
            'trailer\n<< /Size 11 /Root 1 0 R >>\n' +
            'startxref\n0\n' +
            '%%EOF\n';
    }

    private static String widgetSnapshotJson() {
        return JSON.serialize(
            new Map<String, Object>{
                'version' => 1,
                'rootObjectNumber' => 1,
                'rootBody' => '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                'acroFormObjectNumber' => 3,
                'acroFormBody' => '<< /Fields [5 0 R 8 0 R] /DA (/Helv 10 Tf 0 g) >>',
                'size' => 11,
                'fields' => new List<Object>{
                    new Map<String, Object>{
                        'objectNumber' => 5,
                        'valueObjectNumber' => 5,
                        'widgetObjectNumber' => 6,
                        'body' => '<< /FT /Tx /T (Name) /Kids [6 0 R] >>',
                        'widgetBody' => '<< /Subtype /Widget /Parent 5 0 R /Rect [10 10 210 35] >>',
                        'name' => 'Name',
                        'partialName' => 'Name',
                        'fieldType' => 'Tx',
                        'mappedPath' => 'Name'
                    },
                    new Map<String, Object>{
                        'objectNumber' => 8,
                        'body' => '<< /FT /Btn /T (Approved__c) /Subtype /Widget /Rect [10 45 30 65] /AP << /N << /Off 9 0 R /Yes 10 0 R >> >> /V /Off /AS /Off >>',
                        'name' => 'Approved__c',
                        'partialName' => 'Approved__c',
                        'fieldType' => 'Btn',
                        'mappedPath' => 'Approved__c',
                        'buttonOnValue' => 'Yes',
                        'widgets' => new List<Object>{
                            new Map<String, Object>{
                                'objectNumber' => 8,
                                'body' => '<< /FT /Btn /T (Approved__c) /Subtype /Widget /Rect [10 45 30 65] /AP << /N << /Off 9 0 R /Yes 10 0 R >> >> /V /Off /AS /Off >>',
                                'exportValue' => 'Yes'
                            }
                        }
                    }
                }
            }
        );
    }

    private static Boolean blobContains(Blob value, String needle) {
        return EncodingUtil.convertToHex(value).contains(EncodingUtil.convertToHex(Blob.valueOf(needle)));
    }
}
