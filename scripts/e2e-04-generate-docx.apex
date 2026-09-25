// DocGen E2E Test 04 — DOCX Generation + Output Verification
// Run: sf apex run --target-org <org> -f scripts/e2e-04-generate-docx.apex
// Depends on: e2e-02 (Account 'E2E Test Corp', Template 'E2E Test Template')
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;

Id acctId;
Id tmplId;

// ===== Look up test data =====
try {
    List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
    if (accts.isEmpty()) {
        fail++;
        System.debug('LOOKUP ACCOUNT: FAIL — Run e2e-02 first.');
    } else {
        acctId = accts[0].Id;
        pass++;
        System.debug('LOOKUP ACCOUNT: PASS');
    }

    List<DocGen_Template__c> tmpls = [SELECT Id FROM DocGen_Template__c WHERE Name = 'E2E Test Template' LIMIT 1];
    if (tmpls.isEmpty()) {
        fail++;
        System.debug('LOOKUP TEMPLATE: FAIL — Run e2e-02 first.');
    } else {
        tmplId = tmpls[0].Id;
        pass++;
        System.debug('LOOKUP TEMPLATE: PASS');
    }
} catch (Exception e) {
    fail++;
    System.debug('LOOKUP: FAIL — ' + e.getMessage());
}

if (acctId == null || tmplId == null) {
    System.debug('========================================');
    System.debug('E2E-04 GENERATE DOCX — PASS: ' + pass + '  FAIL: ' + fail + '  ABORTED (missing test data)');
    System.debug('========================================');
    return;
}

// ===== Switch template to Native (DOCX) output =====
try {
    DocGen_Template__c t = [SELECT Id, Output_Format__c FROM DocGen_Template__c WHERE Id = :tmplId];
    t.Output_Format__c = 'Native';
    update t;
    DocGen_Template__c verify = [SELECT Output_Format__c FROM DocGen_Template__c WHERE Id = :tmplId];
    if (verify.Output_Format__c == 'Native') {
        pass++;
        System.debug('TEMPLATE SET TO NATIVE: PASS');
    } else {
        fail++;
        System.debug('TEMPLATE SET TO NATIVE: FAIL — got: ' + verify.Output_Format__c);
    }
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE SET TO NATIVE: FAIL — ' + e.getMessage());
}

// ===== Generate DOCX via processAndReturnDocument =====
String base64Docx;
try {
    Map<String, Object> genResult = DocGenController.processAndReturnDocument(tmplId, acctId, null, null);

    if (genResult == null) {
        fail++;
        System.debug('DOCX GEN RESULT: FAIL — null result');
    } else {
        base64Docx = (String) genResult.get('base64');
        String docTitle = (String) genResult.get('title');

        if (String.isNotBlank(base64Docx)) {
            pass++;
            System.debug('DOCX GEN NON-EMPTY: PASS — title: ' + docTitle + ', base64 length: ' + base64Docx.length());
        } else {
            fail++;
            System.debug('DOCX GEN NON-EMPTY: FAIL — empty base64');
        }

        if (docTitle == 'E2E Test Corp') {
            pass++;
            System.debug('DOCX TITLE PRESERVED: PASS');
        } else {
            fail++;
            System.debug('DOCX TITLE PRESERVED: FAIL — got: ' + docTitle);
        }

        // Verify ZIP header — first bytes should be PK (0x504B)
        if (String.isNotBlank(base64Docx)) {
            Blob docxBlob = EncodingUtil.base64Decode(base64Docx);
            String hexStart = EncodingUtil.convertToHex(docxBlob).substring(0, 4).toUpperCase();
            if (hexStart == '504B') {
                pass++;
                System.debug('DOCX ZIP HEADER (PK): PASS');
            } else {
                fail++;
                System.debug('DOCX ZIP HEADER (PK): FAIL — got hex: ' + hexStart);
            }

            // Verify non-trivial size
            if (docxBlob.size() > 200) {
                pass++;
                System.debug('DOCX SIZE > 200 bytes: PASS — ' + docxBlob.size() + ' bytes');
            } else {
                fail++;
                System.debug('DOCX SIZE > 200 bytes: FAIL — only ' + docxBlob.size() + ' bytes');
            }

            // Verify it can be read as a ZIP
            try {
                Compression.ZipReader zr = new Compression.ZipReader(docxBlob);
                List<Compression.ZipEntry> entries = zr.getEntries();
                Boolean hasDocXml = false;
                for (Compression.ZipEntry ze : entries) {
                    if (ze.getName() == 'word/document.xml') {
                        hasDocXml = true;
                    }
                }
                if (hasDocXml) {
                    pass++;
                    System.debug('DOCX CONTAINS word/document.xml: PASS — ' + entries.size() + ' entries');
                } else {
                    fail++;
                    System.debug('DOCX CONTAINS word/document.xml: FAIL — entries: ' + entries.size());
                }
            } catch (Exception ze) {
                fail++;
                System.debug('DOCX ZIP READ: FAIL — ' + ze.getMessage());
            }
        }

        // Save the DOCX to the Account for manual inspection
        if (String.isNotBlank(base64Docx)) {
            try {
                ContentVersion docxCv = new ContentVersion(
                    Title = 'E2E Output - DOCX',
                    PathOnClient = 'e2e_output.docx',
                    VersionData = EncodingUtil.base64Decode(base64Docx),
                    FirstPublishLocationId = acctId
                );
                insert docxCv;
                pass++;
                System.debug('DOCX SAVED TO ACCOUNT: PASS');
                System.debug('>>> DOWNLOAD: Navigate to Account "E2E Test Corp" > Files tab to inspect the DOCX');
            } catch (Exception e) {
                fail++;
                System.debug('DOCX SAVED TO ACCOUNT: FAIL — ' + e.getMessage());
            }
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('DOCX GENERATION: FAIL — ' + e.getMessage() + ' at line ' + e.getLineNumber());
}

// ===== Test generateDocumentParts (client-side assembly path) =====
try {
    Map<String, Object> parts = DocGenController.generateDocumentParts(tmplId, acctId, null, null);
    if (parts != null) {
        Boolean hasXmlParts = parts.containsKey('allXmlParts');
        if (hasXmlParts) {
            pass++;
            System.debug('GENERATE DOCUMENT PARTS: PASS — has allXmlParts');
        } else {
            fail++;
            System.debug('GENERATE DOCUMENT PARTS: FAIL — missing allXmlParts');
        }
        // Verify the new image-routing maps are present (added with rich-text-image support)
        if (
            parts.containsKey('imageBase64Map') &&
            parts.containsKey('imageCvIdMap') &&
            parts.containsKey('imageUrlMap')
        ) {
            pass++;
            System.debug('GENERATE PARTS IMAGE MAPS: PASS — base64Map, cvIdMap, urlMap all present');
        } else {
            fail++;
            System.debug('GENERATE PARTS IMAGE MAPS: FAIL — missing one of the three image maps');
        }
    } else {
        fail++;
        System.debug('GENERATE DOCUMENT PARTS: FAIL — null result');
    }
} catch (Exception e) {
    fail++;
    System.debug('GENERATE DOCUMENT PARTS: FAIL — ' + e.getMessage());
}

// ===== Test renderImageAsPdfBase64 (rich text PDF-extract path) =====
// Validates the Apex-side primitive that powers Lightning rich text inline image
// rendering in DOCX (server renders single-image PDF, client extracts the image).
try {
    // Use a known-good Salesforce-relative URL (won't actually reach a real image
    // in test data, but exercises the validation + Blob.toPdf code path).
    String result = DocGenController.renderImageAsPdfBase64('/sfc/servlet.shepherd/version/download/' + acctId);
    if (Test.isRunningTest()) {
        // In test mode the method returns a stub blob, no real PDF
        if (String.isNotBlank(result)) {
            pass++;
            System.debug('RENDER IMAGE AS PDF (test stub): PASS');
        } else {
            fail++;
            System.debug('RENDER IMAGE AS PDF (test stub): FAIL — returned null');
        }
    } else {
        // Production-mode: result is a base64 PDF (or null if image fetch failed,
        // which is fine — we're testing the entry point not the round trip)
        pass++;
        System.debug(
            'RENDER IMAGE AS PDF (smoke): PASS — entry point invoked, length: ' +
            (result == null ? 'null' : String.valueOf(result.length()))
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('RENDER IMAGE AS PDF: FAIL — ' + e.getMessage());
}

// Validate URL safety check — only Salesforce-hosted URLs allowed
try {
    String result = DocGenController.renderImageAsPdfBase64('https://malicious.example.com/image.png');
    if (result == null) {
        pass++;
        System.debug('RENDER IMAGE AS PDF (rejects external URL): PASS');
    } else {
        fail++;
        System.debug('RENDER IMAGE AS PDF (rejects external URL): FAIL — should have returned null');
    }
} catch (Exception e) {
    fail++;
    System.debug('RENDER IMAGE AS PDF (rejects external URL): FAIL — ' + e.getMessage());
}

// ===== Reset template back to PDF for subsequent scripts =====
try {
    DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c WHERE Id = :tmplId];
    t.Output_Format__c = 'PDF';
    update t;
    pass++;
    System.debug('TEMPLATE RESET TO PDF: PASS');
} catch (Exception e) {
    fail++;
    System.debug('TEMPLATE RESET TO PDF: FAIL — ' + e.getMessage());
}

// ===== Issue #90: Flow action must honor Save to Record toggle =====
// Runs against the PDF-mode template (after reset) so we exercise the same path
// real customers use. saveToRecord=false must NOT attach the file to the source
// record even though recordId is supplied as the merge-data source.
try {
    DocGenFlowAction.Request reqOff = new DocGenFlowAction.Request();
    reqOff.templateId = tmplId;
    reqOff.recordId = acctId;
    reqOff.saveToRecord = false;
    List<DocGenFlowAction.Response> resOff = DocGenFlowAction.generateDocument(
        new List<DocGenFlowAction.Request>{ reqOff }
    );
    if (resOff[0].success == true && resOff[0].contentDocumentId != null) {
        Integer linkCount = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acctId AND ContentDocumentId = :resOff[0].contentDocumentId
        ];
        if (linkCount == 0) {
            pass++;
            System.debug('FLOW ACTION saveToRecord=false: PASS — no CDL to source record');
        } else {
            fail++;
            System.debug('FLOW ACTION saveToRecord=false: FAIL — file attached anyway (' + linkCount + ' CDL)');
        }
    } else {
        fail++;
        System.debug('FLOW ACTION saveToRecord=false: FAIL — generation failed: ' + resOff[0].errorMessage);
    }
} catch (Exception e) {
    fail++;
    System.debug('FLOW ACTION saveToRecord=false: FAIL — ' + e.getMessage());
}

try {
    DocGenFlowAction.Request reqOn = new DocGenFlowAction.Request();
    reqOn.templateId = tmplId;
    reqOn.recordId = acctId;
    reqOn.saveToRecord = true;
    List<DocGenFlowAction.Response> resOn = DocGenFlowAction.generateDocument(
        new List<DocGenFlowAction.Request>{ reqOn }
    );
    if (resOn[0].success == true && resOn[0].contentDocumentId != null) {
        Integer linkCount = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acctId AND ContentDocumentId = :resOn[0].contentDocumentId
        ];
        if (linkCount > 0) {
            pass++;
            System.debug('FLOW ACTION saveToRecord=true: PASS — CDL exists');
        } else {
            fail++;
            System.debug('FLOW ACTION saveToRecord=true: FAIL — no CDL created');
        }
    } else {
        fail++;
        System.debug('FLOW ACTION saveToRecord=true: FAIL — generation failed: ' + resOn[0].errorMessage);
    }
} catch (Exception e) {
    fail++;
    System.debug('FLOW ACTION saveToRecord=true: FAIL — ' + e.getMessage());
}

System.debug('========================================');
System.debug(
    'E2E-04 GENERATE DOCX — PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
