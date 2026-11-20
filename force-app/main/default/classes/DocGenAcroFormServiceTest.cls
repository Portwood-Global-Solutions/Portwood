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

    // ---- #534 Flatten PDF on generation ----

    @IsTest
    static void flattenDrawsWidgetAppearancesIntoPageAndDropsForm() {
        Blob flat = DocGenAcroFormService.flattenFilledPdf(Blob.valueOf(flattenablePdf()));

        System.assert(
            blobContains(flat, '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>'),
            'Catalog should no longer reference the AcroForm'
        );
        System.assert(blobContains(flat, '/Annots [10 0 R]'), 'Widgets leave /Annots; the link annotation stays');
        System.assert(
            blobContains(flat, '/Contents [13 0 R 7 0 R 14 0 R]'),
            'Original content is wrapped between a q stream and the field drawing stream'
        );
        System.assert(
            blobContains(flat, 'q 1 0 0 1 10 10 cm /PwFlat5 Do Q'),
            'Text widget appearance should be painted on its /Rect'
        );
        System.assert(
            blobContains(flat, 'q 1 0 0 1 10 40 cm /PwFlat6 Do Q'),
            'Checkbox appearance should be painted on its /Rect'
        );
        System.assert(blobContains(flat, '/PwFlat5 8 0 R'), 'Text appearance stream registered as page XObject');
        System.assert(blobContains(flat, '/PwFlat6 12 0 R'), 'Checkbox should flatten its /AS (Yes) state stream');
        System.assert(blobContains(flat, '/F1 9 0 R'), 'Inherited page fonts are preserved');
        System.assert(
            blobContains(flat, '/Helv << /Type /Font /Subtype /Type1 /BaseFont /Helvetica'),
            'Appearances without their own resources get the form default font on the page'
        );
        System.assert(blobContains(flat, '/Prev 0'), 'Flatten is appended as an incremental update');
    }

    @IsTest
    static void flattenGeneratesAppearanceForValueOnlyFields() {
        Blob filled = DocGenAcroFormService.fillPdfTemplate(
            Blob.valueOf(simpleAcroFormPdf()),
            new Map<String, Object>{ 'Name' => 'Ada' }
        );

        Blob flat = DocGenAcroFormService.flattenFilledPdf(filled);

        System.assert(blobContains(flat, '(Ada) Tj'), 'A value without an appearance must still be drawn');
        System.assert(blobContains(flat, 'cm /PwFlat5 Do Q'), 'Generated appearance should be painted on the page');
        System.assert(
            blobContains(flat, '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>'),
            'Flattened output should have no AcroForm'
        );
    }

    @IsTest
    static void flattenUsesReadableSizeForAutoFontFields() {
        String pdf = simpleAcroFormPdf()
            .replace(
                '3 0 obj\n<< /Fields [5 0 R 6 0 R] >>',
                '3 0 obj\n<< /Fields [5 0 R 6 0 R] /DA (/Helv 0 Tf 0 g) >>'
            );
        Blob filled = DocGenAcroFormService.fillPdfTemplate(
            Blob.valueOf(pdf),
            new Map<String, Object>{ 'Name' => 'Ada' }
        );

        Blob flat = DocGenAcroFormService.flattenFilledPdf(filled);

        System.assert(blobContains(flat, 'BT /Helv 12 Tf'), 'Auto (0) font size should become a visible size');
    }

    @IsTest
    static void fillFlattensOnlyWhenTemplateOptsIn() {
        DocGen_Template__c flatTemplate = new DocGen_Template__c(
            Name = 'Flatten On',
            Type__c = 'PDF',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name',
            Flatten_PDF__c = true
        );
        DocGen_Template__c fillableTemplate = new DocGen_Template__c(
            Name = 'Flatten Off',
            Type__c = 'PDF',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        insert new List<DocGen_Template__c>{ flatTemplate, fillableTemplate };
        Blob pdf = Blob.valueOf(simpleAcroFormPdf());
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'Ada' };

        Blob flat = DocGenAcroFormService.fillPdfTemplate(pdf, data, flatTemplate.Id);
        Blob fillable = DocGenAcroFormService.fillPdfTemplate(pdf, data, fillableTemplate.Id);

        System.assert(blobContains(flat, '/PwFlat5'), 'Flatten_PDF__c = true should flatten the generated PDF');
        System.assert(!blobContains(fillable, '/PwFlat'), 'Templates without the option stay fillable');
        System.assert(blobContains(fillable, '/NeedAppearances true'), 'Unflattened output keeps the live form');
    }

    @IsTest
    static void templateEditorSavesFlattenOption() {
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Flatten Edit',
            Type__c = 'PDF',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        insert template;
        Map<String, Object> fields = new Map<String, Object>{
            'Id' => template.Id,
            'Name' => 'Flatten Edit',
            'Type__c' => 'PDF',
            'Base_Object_API__c' => 'Account',
            'Query_Config__c' => 'Name',
            'Flatten_PDF__c' => true
        };

        DocGenController.saveTemplate(fields, false, null);
        System.assertEquals(
            true,
            [SELECT Flatten_PDF__c FROM DocGen_Template__c WHERE Id = :template.Id].Flatten_PDF__c,
            'Edit Template save should persist Flatten PDF on generation'
        );

        fields.put('Flatten_PDF__c', false);
        DocGenController.saveTemplate(fields, false, null);
        System.assertEquals(
            false,
            [SELECT Flatten_PDF__c FROM DocGen_Template__c WHERE Id = :template.Id].Flatten_PDF__c,
            'Turning the toggle off should persist too'
        );
    }

    @IsTest
    static void flattenLeavesPdfWithoutFormUnchanged() {
        Blob pdf = Blob.valueOf(
            '%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n' +
            'trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n0\n%%EOF\n'
        );

        System.assertEquals(pdf.size(), DocGenAcroFormService.flattenFilledPdf(pdf).size(), 'Nothing to flatten');
    }

    @IsTest
    static void flattenFailsClearlyWhenPagesAreUnreadable() {
        Boolean threw = false;
        try {
            DocGenAcroFormService.flattenFilledPdf(
                Blob.valueOf(
                    '%PDF-1.5\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
                        '3 0 obj\n<< /Fields [] >>\nendobj\n' +
                        'trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n0\n%%EOF\n'
                )
            );
        } catch (DocGenException e) {
            threw = e.getMessage().contains('Flatten PDF on generation');
        }

        System.assert(threw, 'Pages hidden in object streams must fail loudly, never ship an editable PDF');
    }

    @IsTest
    static void removingDictionaryValuedKeysLeavesNoFragments() {
        Blob filled = DocGenAcroFormService.fillPdfTemplate(
            Blob.valueOf(buttonAcroFormPdf()),
            new Map<String, Object>{ 'Approved__c' => true }
        );

        // The old helper cut only "/AP <" and left "/Rect [10 10 30 30] < /N << /Off 7 0 R …" behind.
        System.assert(!blobContains(filled, '30] < /N'), 'Removing /AP must remove its whole dictionary value');
        System.assert(blobContains(filled, '/AS /Yes'), 'Button state is still written');
    }

    private static String flattenablePdf() {
        return '%PDF-1.4\n' +
            '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
            '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 /Resources << /Font << /F1 9 0 R >> >> >>\nendobj\n' +
            '3 0 obj\n<< /Fields [5 0 R 6 0 R] /NeedAppearances true >>\nendobj\n' +
            '4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R /Annots [5 0 R 10 0 R 6 0 R] >>\nendobj\n' +
            '5 0 obj\n<< /FT /Tx /T (Name) /Subtype /Widget /Rect [10 10 200 30] /V (Ada) /AP << /N 8 0 R >> >>\nendobj\n' +
            '6 0 obj\n<< /FT /Btn /T (Approved) /Subtype /Widget /Rect [10 40 30 60] /V /Yes /AS /Yes /AP << /N << /Off 11 0 R /Yes 12 0 R >> >> >>\nendobj\n' +
            '7 0 obj\n<< /Length 5 >>\nstream\nBT ET\nendstream\nendobj\n' +
            '8 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 190 20] /Length 21 >>\nstream\nBT /Helv 9 Tf (Ada) Tj\nendstream\nendobj\n' +
            '9 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>\nendobj\n' +
            '10 0 obj\n<< /Type /Annot /Subtype /Link /Rect [0 0 5 5] >>\nendobj\n' +
            '11 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length 0 >>\nstream\n\nendstream\nendobj\n' +
            '12 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length 0 >>\nstream\n\nendstream\nendobj\n' +
            'trailer\n<< /Size 13 /Root 1 0 R >>\n' +
            'startxref\n0\n' +
            '%%EOF\n';
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
