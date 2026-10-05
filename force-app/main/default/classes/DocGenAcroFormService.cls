public with sharing class DocGenAcroFormService {
    private class PdfObject {
        Integer num;
        String body;
        Integer startOffset;
    }

    private class FillPlan {
        Integer rootNum;
        Integer acroFormNum;
        Integer size;
        Integer prevStartXref;
        Boolean usesXrefStream = false;
        Map<Integer, PdfObject> objects = new Map<Integer, PdfObject>();
        Map<Integer, String> fieldValues = new Map<Integer, String>();
        Map<Integer, String> fieldTypes = new Map<Integer, String>();
        Map<Integer, String> buttonOnValues = new Map<Integer, String>();
    }

    private class XfaDatasetUpdate {
        Integer objectNumber;
        String xml;
    }

    private static final String UNSUPPORTED_XFA_MESSAGE = 'XFA PDF forms are not supported yet. Use a standard AcroForm PDF with uncompressed field dictionaries.';
    private static final String UNSUPPORTED_OBJECT_STREAM_MESSAGE = 'PDF AcroForm fields are stored in compressed object streams, which are not supported yet.';

    public static Blob fillPdfTemplate(Blob pdfBlob, Map<String, Object> data) {
        return fillPdfTemplate(pdfBlob, data, null);
    }

    public static Blob fillPdfTemplate(Blob pdfBlob, Map<String, Object> data, Id templateId) {
        if (pdfBlob == null) {
            throw new DocGenException('PDF template file is missing.');
        }
        String pdfHex = EncodingUtil.convertToHex(pdfBlob);
        if (!isPdfHex(pdfHex)) {
            throw new DocGenException('AcroForm templates must be valid PDF files.');
        }

        if (templateId != null) {
            Blob snapshotFilled = fillFromSavedSnapshot(pdfBlob, pdfTailToLatin1(pdfHex), pdfHex, data, templateId);
            if (snapshotFilled != null) {
                return snapshotFilled;
            }
        }
        if (containsPdfToken(pdfHex, '/Encrypt')) {
            throw new DocGenException('Encrypted PDF AcroForm templates require a saved browser field snapshot.');
        }

        String pdfText = bytesToLatin1Hex(pdfHex);
        FillPlan plan = buildFillPlan(pdfText, data);
        if (plan.fieldValues.isEmpty()) {
            return pdfBlob;
        }
        return appendIncrementalUpdate(pdfBlob, plan);
    }

    private static Blob fillFromSavedSnapshot(
        Blob pdfBlob,
        String pdfTailText,
        String pdfHex,
        Map<String, Object> data,
        Id templateId
    ) {
        String snapshotJson = loadActiveSnapshotJson(templateId);
        if (String.isBlank(snapshotJson)) {
            return null;
        }
        Map<String, Object> snapshot = (Map<String, Object>) JSON.deserializeUntyped(snapshotJson);
        Map<Integer, String> fieldBodies = new Map<Integer, String>();
        Map<Integer, String> fieldValues = new Map<Integer, String>();
        Map<Integer, String> fieldTypes = new Map<Integer, String>();
        Map<Integer, String> buttonOnValues = new Map<Integer, String>();
        Map<Integer, String> widgetBodies = new Map<Integer, String>();
        Map<Integer, String> widgetTypes = new Map<Integer, String>();
        Map<Integer, String> widgetValues = new Map<Integer, String>();
        Map<String, String> xfaValues = new Map<String, String>();
        List<Object> fields = (List<Object>) snapshot.get('fields');
        if (fields == null) {
            return pdfBlob;
        }

        for (Object item : fields) {
            Map<String, Object> field = (Map<String, Object>) item;
            Integer rowObjectNumber = Integer.valueOf(String.valueOf(field.get('objectNumber')));
            Integer objectNumber = field.get('valueObjectNumber') == null
                ? rowObjectNumber
                : Integer.valueOf(String.valueOf(field.get('valueObjectNumber')));
            Integer widgetObjectNumber = field.get('widgetObjectNumber') == null
                ? rowObjectNumber
                : Integer.valueOf(String.valueOf(field.get('widgetObjectNumber')));
            String body = (String) field.get('body');
            String widgetBody = (String) field.get('widgetBody');
            String fieldName = (String) field.get('mappedPath');
            String fieldType = (String) field.get('fieldType');
            if (String.isBlank(fieldName)) {
                continue;
            }
            fieldBodies.put(objectNumber, body);
            if (String.isNotBlank(fieldType)) {
                fieldTypes.put(objectNumber, fieldType);
            }
            if (field.get('buttonOnValue') != null) {
                buttonOnValues.put(objectNumber, String.valueOf(field.get('buttonOnValue')));
            }
            Object value = resolveValue(data, fieldName);
            if (value != null) {
                String formatted = fieldType == 'Btn'
                    ? buttonPdfValue(value, buttonOnValues.get(objectNumber))
                    : formatValue(value);
                fieldValues.put(objectNumber, formatted);
                if (fieldType != 'Btn' && widgetObjectNumber != objectNumber && String.isNotBlank(widgetBody)) {
                    widgetBodies.put(widgetObjectNumber, widgetBody);
                    widgetTypes.put(widgetObjectNumber, fieldType);
                    widgetValues.put(widgetObjectNumber, formatted);
                }
                if (fieldType == 'Btn') {
                    List<Object> widgets = (List<Object>) field.get('widgets');
                    if (widgets == null || widgets.isEmpty()) {
                        if (String.isNotBlank(widgetBody)) {
                            Map<String, Object> fallbackWidget = new Map<String, Object>{
                                'objectNumber' => widgetObjectNumber,
                                'body' => widgetBody,
                                'exportValue' => buttonOnValues.get(objectNumber)
                            };
                            widgets = new List<Object>{ fallbackWidget };
                        }
                    }
                    if (widgets != null) {
                        for (Object widgetItem : widgets) {
                            Map<String, Object> widget = (Map<String, Object>) widgetItem;
                            if (widget.get('objectNumber') == null) {
                                continue;
                            }
                            Integer widgetNum = Integer.valueOf(String.valueOf(widget.get('objectNumber')));
                            String exportValue = widget.get('exportValue') == null
                                ? buttonOnValues.get(objectNumber)
                                : String.valueOf(widget.get('exportValue'));
                            String widgetValue = formatted == 'Off' || formatted != exportValue ? 'Off' : exportValue;
                            widgetBodies.put(
                                widgetNum,
                                widget.get('body') == null ? null : String.valueOf(widget.get('body'))
                            );
                            widgetTypes.put(widgetNum, 'Btn');
                            widgetValues.put(widgetNum, widgetValue);
                        }
                    }
                }
                String xfaName = normalizeXfaFieldName((String) field.get('partialName'));
                if (String.isBlank(xfaName)) {
                    xfaName = normalizeXfaFieldName((String) field.get('name'));
                }
                if (String.isNotBlank(xfaName)) {
                    xfaValues.put(xfaName, formatted);
                }
            }
        }
        if (fieldValues.isEmpty()) {
            return pdfBlob;
        }
        hydrateMissingPdfObjectBodiesFromHex(pdfHex, fieldBodies);
        hydrateMissingPdfObjectBodiesFromHex(pdfHex, widgetBodies);
        assertPdfObjectBodiesAvailable(fieldBodies, fieldValues, 'field');
        assertPdfObjectBodiesAvailable(widgetBodies, widgetValues, 'widget');

        XfaDatasetUpdate xfaUpdate = buildXfaDatasetUpdate(snapshot, xfaValues);
        Integer acroFormNum = Integer.valueOf(String.valueOf(snapshot.get('acroFormObjectNumber')));
        String acroFormBody = (String) snapshot.get('acroFormBody');
        Integer rootNum = Integer.valueOf(String.valueOf(snapshot.get('rootObjectNumber')));
        String rootBody = (String) snapshot.get('rootBody');
        Integer size = Math.max(parseTrailerSize(pdfTailText), Integer.valueOf(String.valueOf(snapshot.get('size'))));
        Integer prevStartXref = parsePreviousStartXref(pdfTailText);
        return appendIncrementalUpdateFromSnapshot(
            pdfBlob,
            fieldBodies,
            fieldValues,
            acroFormNum,
            acroFormBody,
            rootNum,
            rootBody,
            size,
            prevStartXref,
            xfaUpdate,
            fieldTypes,
            widgetBodies,
            widgetTypes,
            widgetValues,
            isXrefStreamPdf(pdfTailText)
        );
    }

    private static String loadActiveSnapshotJson(Id templateId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Template__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> versions = [
            SELECT Id
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (versions.isEmpty()) {
            return null;
        }
        String title = 'docgen_tmpl_pdf_' + String.valueOf(versions[0].Id) + '_acroform';
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> snapshots = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Title = :title
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return snapshots.isEmpty() ? null : snapshots[0].VersionData.toString();
    }

    private static void hydrateMissingPdfObjectBodiesFromHex(String pdfHex, Map<Integer, String> bodiesByObjectNumber) {
        if (String.isBlank(pdfHex) || bodiesByObjectNumber == null || bodiesByObjectNumber.isEmpty()) {
            return;
        }
        Set<Integer> missing = new Set<Integer>();
        for (Integer objectNumber : bodiesByObjectNumber.keySet()) {
            if (objectNumber != null && String.isBlank(bodiesByObjectNumber.get(objectNumber))) {
                missing.add(objectNumber);
            }
        }
        if (missing.isEmpty()) {
            return;
        }
        String objToken = '2030206f626a'; // " 0 obj"
        String endObjToken = '656e646f626a'; // "endobj"
        Integer pos = 0;
        while (!missing.isEmpty()) {
            Integer tokenIndex = pdfHex.indexOf(objToken, pos);
            if (tokenIndex < 0) {
                return;
            }
            Integer digitStart = tokenIndex - 2;
            while (digitStart >= 0 && isDigitHexByte(pdfHex.substring(digitStart, digitStart + 2))) {
                digitStart -= 2;
            }
            digitStart += 2;
            if (digitStart < tokenIndex) {
                Integer objectNumber = asciiDigitHexToInteger(pdfHex.substring(digitStart, tokenIndex));
                Integer bodyStart = tokenIndex + objToken.length();
                Integer endIndex = pdfHex.indexOf(endObjToken, bodyStart);
                if (endIndex < 0) {
                    return;
                }
                if (missing.contains(objectNumber)) {
                    bodiesByObjectNumber.put(
                        objectNumber,
                        pdfDictionaryHexToString(pdfHex.substring(bodyStart, endIndex))
                    );
                    missing.remove(objectNumber);
                }
                pos = endIndex + endObjToken.length();
            } else {
                pos = tokenIndex + objToken.length();
            }
        }
    }

    private static void assertPdfObjectBodiesAvailable(
        Map<Integer, String> bodiesByObjectNumber,
        Map<Integer, String> valuesByObjectNumber,
        String objectKind
    ) {
        if (valuesByObjectNumber == null || valuesByObjectNumber.isEmpty()) {
            return;
        }
        List<String> missing = new List<String>();
        for (Integer objectNumber : valuesByObjectNumber.keySet()) {
            if (
                objectNumber != null &&
                (bodiesByObjectNumber == null || String.isBlank(bodiesByObjectNumber.get(objectNumber)))
            ) {
                missing.add(String.valueOf(objectNumber));
            }
        }
        if (!missing.isEmpty()) {
            missing.sort();
            throw new DocGenException(
                'PDF AcroForm mapping does not match the active PDF body. Missing ' +
                    objectKind +
                    ' object(s): ' +
                    String.join(missing, ', ') +
                    '. Save this PDF as a new template version so Portwood can store a matching server-ready PDF body.'
            );
        }
    }

    private static Boolean isDigitHexByte(String hexByte) {
        return hexByte >= '30' && hexByte <= '39';
    }

    private static Integer asciiDigitHexToInteger(String hexDigits) {
        Integer value = 0;
        for (Integer i = 0; i + 1 < hexDigits.length(); i += 2) {
            value = (value * 10) + Integer.valueOf(hexDigits.substring(i + 1, i + 2));
        }
        return value;
    }

    private static String pdfDictionaryHexToString(String bodyHex) {
        try {
            return EncodingUtil.convertFromHex(bodyHex).toString();
        } catch (Exception e) {
            return bytesToLatin1Hex(bodyHex);
        }
    }

    @TestVisible
    static String inspectFillableFields(Blob pdfBlob) {
        String pdfText = bytesToLatin1(pdfBlob);
        FillPlan plan = buildFillPlan(pdfText, new Map<String, Object>());
        List<String> names = new List<String>();
        for (Integer fieldNum : collectFieldRefs(plan)) {
            PdfObject obj = plan.objects.get(fieldNum);
            String name = extractLiteralName(obj != null ? obj.body : null, '/T');
            if (String.isNotBlank(name)) {
                names.add(name);
            }
        }
        names.sort();
        return String.join(names, ',');
    }

    private static FillPlan buildFillPlan(String pdfText, Map<String, Object> data) {
        FillPlan plan = new FillPlan();
        plan.prevStartXref = parsePreviousStartXref(pdfText);
        plan.usesXrefStream = isXrefStreamPdf(pdfText);
        parseObjects(pdfText, plan);
        plan.rootNum = parseRootNum(pdfText, plan);
        plan.size = Math.max(parseTrailerSize(pdfText), maxObjectNumber(plan.objects) + 1);

        PdfObject catalog = plan.objects.get(plan.rootNum);
        if (catalog == null) {
            throw new DocGenException('PDF catalog object not found.');
        }
        plan.acroFormNum = extractRef(catalog.body, '/AcroForm');
        if (plan.acroFormNum == null) {
            throw new DocGenException('PDF does not contain a reference-based AcroForm.');
        }

        PdfObject acroForm = plan.objects.get(plan.acroFormNum);
        if (acroForm == null || !acroForm.body.contains('/Fields')) {
            throwUnsupportedForm(pdfText);
            throw new DocGenException('PDF AcroForm fields could not be read.');
        }

        for (Integer fieldNum : collectFieldRefs(plan)) {
            PdfObject fieldObj = plan.objects.get(fieldNum);
            if (fieldObj == null || fieldObj.body.contains('stream')) {
                throwUnsupportedForm(pdfText);
                continue;
            }
            String fieldName = extractLiteralName(fieldObj.body, '/T');
            if (String.isBlank(fieldName)) {
                continue;
            }
            Object value = resolveValue(data, fieldName);
            if (value != null) {
                String fieldType = extractName(fieldObj.body, '/FT');
                String buttonOnValue = extractFirstButtonOnValue(fieldObj.body);
                plan.fieldValues.put(
                    fieldNum,
                    fieldType == 'Btn' ? buttonPdfValue(value, buttonOnValue) : formatValue(value)
                );
                plan.fieldTypes.put(fieldNum, fieldType);
                plan.buttonOnValues.put(fieldNum, buttonOnValue);
            }
        }
        return plan;
    }

    private static void throwUnsupportedForm(String pdfText) {
        if (pdfText.contains('/XFA')) {
            throw new DocGenException(UNSUPPORTED_XFA_MESSAGE);
        }
        if (pdfText.contains('/ObjStm') || pdfText.contains('/Type/XRef') || pdfText.contains('/Type /XRef')) {
            throw new DocGenException(UNSUPPORTED_OBJECT_STREAM_MESSAGE);
        }
    }

    private static void parseObjects(String pdfText, FillPlan plan) {
        Pattern objPattern = Pattern.compile('(?s)(\\d+)\\s+0\\s+obj\\b(.*?)endobj');
        Matcher matcher = objPattern.matcher(pdfText);
        while (matcher.find()) {
            Integer num = Integer.valueOf(matcher.group(1));
            PdfObject obj = new PdfObject();
            obj.num = num;
            obj.body = matcher.group(2);
            obj.startOffset = matcher.start();
            plan.objects.put(num, obj);
        }
    }

    private static List<Integer> collectFieldRefs(FillPlan plan) {
        List<Integer> refs = new List<Integer>();
        PdfObject acroForm = plan.objects.get(plan.acroFormNum);
        if (acroForm == null) {
            return refs;
        }
        String fieldArray = extractArray(acroForm.body, '/Fields');
        if (String.isBlank(fieldArray)) {
            return refs;
        }
        Matcher refMatcher = Pattern.compile('(\\d+)\\s+0\\s+R').matcher(fieldArray);
        while (refMatcher.find()) {
            collectFieldRefRecursive(plan, Integer.valueOf(refMatcher.group(1)), refs, new Set<Integer>());
        }
        return refs;
    }

    private static void collectFieldRefRecursive(
        FillPlan plan,
        Integer fieldNum,
        List<Integer> refs,
        Set<Integer> visited
    ) {
        if (fieldNum == null || visited.contains(fieldNum)) {
            return;
        }
        visited.add(fieldNum);
        PdfObject fieldObj = plan.objects.get(fieldNum);
        if (fieldObj == null) {
            refs.add(fieldNum);
            return;
        }
        String kidsArray = extractArray(fieldObj.body, '/Kids');
        if (String.isBlank(kidsArray)) {
            refs.add(fieldNum);
            return;
        }
        Matcher kidMatcher = Pattern.compile('(\\d+)\\s+0\\s+R').matcher(kidsArray);
        Boolean foundKid = false;
        while (kidMatcher.find()) {
            foundKid = true;
            collectFieldRefRecursive(plan, Integer.valueOf(kidMatcher.group(1)), refs, visited);
        }
        if (!foundKid) {
            refs.add(fieldNum);
        }
    }

    private static Blob appendIncrementalUpdate(Blob original, FillPlan plan) {
        String appendText = '\n';
        Integer offset = original.size() + appendText.length();
        Map<Integer, Integer> offsets = new Map<Integer, Integer>();

        List<Integer> updatedNums = new List<Integer>();
        for (Integer fieldNum : plan.fieldValues.keySet()) {
            updatedNums.add(fieldNum);
        }
        updatedNums.add(plan.acroFormNum);
        updatedNums.sort();

        for (Integer objNum : updatedNums) {
            offsets.put(objNum, offset);
            String body = (objNum == plan.acroFormNum)
                ? withNeedAppearances(plan.objects.get(objNum).body)
                : withFieldValue(
                      plan.objects.get(objNum).body,
                      plan.fieldValues.get(objNum),
                      plan.fieldTypes.get(objNum)
                  );
            String serialized = objNum + ' 0 obj\n' + body + '\nendobj\n';
            appendText += serialized;
            offset += Blob.valueOf(serialized).size();
        }

        return plan.usesXrefStream
            ? appendXrefStream(
                  original,
                  appendText,
                  offsets,
                  updatedNums,
                  plan.rootNum,
                  plan.size,
                  plan.prevStartXref,
                  offset
              )
            : appendClassicXref(
                  original,
                  appendText,
                  offsets,
                  updatedNums,
                  plan.rootNum,
                  plan.size,
                  plan.prevStartXref,
                  offset
              );
    }

    private static Blob appendIncrementalUpdateFromSnapshot(
        Blob original,
        Map<Integer, String> fieldBodies,
        Map<Integer, String> fieldValues,
        Integer acroFormNum,
        String acroFormBody,
        Integer rootNum,
        String rootBody,
        Integer size,
        Integer prevStartXref,
        XfaDatasetUpdate xfaUpdate,
        Map<Integer, String> fieldTypes,
        Map<Integer, String> widgetBodies,
        Map<Integer, String> widgetTypes,
        Map<Integer, String> widgetValues,
        Boolean usesXrefStream
    ) {
        String appendText = '\n';
        Integer offset = original.size() + Blob.valueOf(appendText).size();
        Map<Integer, Integer> offsets = new Map<Integer, Integer>();
        Map<Integer, Integer> appearanceRefs = buildTextAppearanceRefs(
            fieldBodies,
            fieldValues,
            fieldTypes,
            widgetBodies,
            widgetTypes,
            widgetValues,
            acroFormBody,
            size
        );
        Map<Integer, String> appearanceBodies = buildTextAppearanceBodies(
            fieldBodies,
            fieldValues,
            fieldTypes,
            widgetBodies,
            widgetTypes,
            widgetValues,
            acroFormBody,
            appearanceRefs
        );
        Map<Integer, Integer> buttonAppearanceRefs = buildButtonAppearanceRefs(
            fieldValues,
            fieldTypes,
            widgetBodies,
            widgetTypes,
            widgetValues,
            size + appearanceRefs.size()
        );
        Map<Integer, String> buttonAppearanceBodies = buildButtonAppearanceBodies(
            fieldBodies,
            fieldValues,
            fieldTypes,
            widgetBodies,
            widgetTypes,
            widgetValues,
            buttonAppearanceRefs
        );

        Set<Integer> updatedNumSet = new Set<Integer>();
        updatedNumSet.addAll(fieldValues.keySet());
        if (widgetBodies != null) {
            updatedNumSet.addAll(widgetBodies.keySet());
        }
        updatedNumSet.addAll(appearanceBodies.keySet());
        updatedNumSet.addAll(buttonAppearanceBodies.keySet());
        updatedNumSet.add(acroFormNum);
        if (xfaUpdate != null && xfaUpdate.objectNumber != null && String.isNotBlank(xfaUpdate.xml)) {
            updatedNumSet.add(xfaUpdate.objectNumber);
        }
        String updatedRootBody = withoutCatalogPerms(rootBody);
        if (String.isNotBlank(updatedRootBody) && updatedRootBody != rootBody) {
            updatedNumSet.add(rootNum);
        }
        List<Integer> updatedNums = new List<Integer>(updatedNumSet);
        updatedNums.sort();

        for (Integer objNum : updatedNums) {
            offsets.put(objNum, offset);
            String serialized;
            if (xfaUpdate != null && objNum == xfaUpdate.objectNumber) {
                serialized = serializeXfaDatasetObject(objNum, xfaUpdate.xml);
            } else if (objNum == rootNum) {
                serialized = objNum + ' 0 obj\n' + updatedRootBody + '\nendobj\n';
            } else if (appearanceBodies.containsKey(objNum)) {
                serialized = objNum + ' 0 obj\n' + appearanceBodies.get(objNum) + '\nendobj\n';
            } else if (buttonAppearanceBodies.containsKey(objNum)) {
                serialized = objNum + ' 0 obj\n' + buttonAppearanceBodies.get(objNum) + '\nendobj\n';
            } else if (widgetBodies != null && widgetBodies.containsKey(objNum)) {
                String widgetBody = widgetBodies.get(objNum);
                if (fieldValues.containsKey(objNum)) {
                    widgetBody = withFieldValue(widgetBody, fieldValues.get(objNum), fieldTypes.get(objNum));
                }
                widgetBody = widgetTypes != null &&
                    widgetTypes.get(objNum) == 'Btn'
                    ? withWidgetAppearanceState(widgetBody, widgetValues.get(objNum))
                    : removePdfKeyValue(widgetBody, '/AP');
                if (appearanceRefs.containsKey(objNum)) {
                    widgetBody = withNormalAppearance(widgetBody, appearanceRefs.get(objNum));
                }
                if (buttonAppearanceRefs.containsKey(objNum)) {
                    widgetBody = withButtonNormalAppearance(
                        widgetBody,
                        widgetValues.get(objNum),
                        buttonAppearanceRefs.get(objNum)
                    );
                }
                serialized = objNum + ' 0 obj\n' + widgetBody + '\nendobj\n';
            } else {
                String body = (objNum == acroFormNum)
                    ? withNeedAppearances(acroFormBody)
                    : withFieldValue(fieldBodies.get(objNum), fieldValues.get(objNum), fieldTypes.get(objNum));
                if (appearanceRefs.containsKey(objNum)) {
                    body = withNormalAppearance(body, appearanceRefs.get(objNum));
                }
                if (buttonAppearanceRefs.containsKey(objNum)) {
                    body = withButtonNormalAppearance(body, fieldValues.get(objNum), buttonAppearanceRefs.get(objNum));
                }
                serialized = objNum + ' 0 obj\n' + body + '\nendobj\n';
            }
            appendText += serialized;
            offset += Blob.valueOf(serialized).size();
        }

        Integer updatedSize = size;
        for (Integer objNum : updatedNums) {
            updatedSize = Math.max(updatedSize, objNum + 1);
        }
        return usesXrefStream
            ? appendXrefStream(original, appendText, offsets, updatedNums, rootNum, updatedSize, prevStartXref, offset)
            : appendClassicXref(
                  original,
                  appendText,
                  offsets,
                  updatedNums,
                  rootNum,
                  updatedSize,
                  prevStartXref,
                  offset
              );
    }

    private static Map<Integer, Integer> buildTextAppearanceRefs(
        Map<Integer, String> fieldBodies,
        Map<Integer, String> fieldValues,
        Map<Integer, String> fieldTypes,
        Map<Integer, String> widgetBodies,
        Map<Integer, String> widgetTypes,
        Map<Integer, String> widgetValues,
        String acroFormBody,
        Integer firstObjectNumber
    ) {
        Map<Integer, Integer> refs = new Map<Integer, Integer>();
        Integer nextObjectNumber = firstObjectNumber;
        for (Integer objNum : fieldValues.keySet()) {
            if (fieldTypes.get(objNum) == 'Btn' || (widgetBodies != null && widgetBodies.containsKey(objNum))) {
                continue;
            }
            if (buildTextAppearanceBody(fieldBodies.get(objNum), fieldValues.get(objNum), acroFormBody) != null) {
                refs.put(objNum, nextObjectNumber);
                nextObjectNumber++;
            }
        }
        if (widgetBodies != null) {
            for (Integer objNum : widgetBodies.keySet()) {
                if (widgetTypes != null && widgetTypes.get(objNum) == 'Btn') {
                    continue;
                }
                if (buildTextAppearanceBody(widgetBodies.get(objNum), widgetValues.get(objNum), acroFormBody) != null) {
                    refs.put(objNum, nextObjectNumber);
                    nextObjectNumber++;
                }
            }
        }
        return refs;
    }

    private static Map<Integer, String> buildTextAppearanceBodies(
        Map<Integer, String> fieldBodies,
        Map<Integer, String> fieldValues,
        Map<Integer, String> fieldTypes,
        Map<Integer, String> widgetBodies,
        Map<Integer, String> widgetTypes,
        Map<Integer, String> widgetValues,
        String acroFormBody,
        Map<Integer, Integer> appearanceRefs
    ) {
        Map<Integer, String> bodies = new Map<Integer, String>();
        for (Integer objNum : appearanceRefs.keySet()) {
            Boolean isWidget = widgetBodies != null && widgetBodies.containsKey(objNum);
            String sourceBody = isWidget ? widgetBodies.get(objNum) : fieldBodies.get(objNum);
            String value = isWidget ? widgetValues.get(objNum) : fieldValues.get(objNum);
            if (!isWidget && fieldTypes.get(objNum) == 'Btn') {
                continue;
            }
            if (isWidget && widgetTypes != null && widgetTypes.get(objNum) == 'Btn') {
                continue;
            }
            String body = buildTextAppearanceBody(sourceBody, value, acroFormBody);
            if (body != null) {
                bodies.put(appearanceRefs.get(objNum), body);
            }
        }
        return bodies;
    }

    private static Map<Integer, Integer> buildButtonAppearanceRefs(
        Map<Integer, String> fieldValues,
        Map<Integer, String> fieldTypes,
        Map<Integer, String> widgetBodies,
        Map<Integer, String> widgetTypes,
        Map<Integer, String> widgetValues,
        Integer firstObjectNumber
    ) {
        Map<Integer, Integer> refs = new Map<Integer, Integer>();
        Integer nextObjectNumber = firstObjectNumber;
        if (widgetBodies != null) {
            for (Integer objNum : widgetBodies.keySet()) {
                if (widgetTypes != null && widgetTypes.get(objNum) == 'Btn') {
                    refs.put(objNum, nextObjectNumber);
                    nextObjectNumber++;
                }
            }
        }
        for (Integer objNum : fieldValues.keySet()) {
            if (
                fieldTypes != null &&
                fieldTypes.get(objNum) == 'Btn' &&
                (widgetBodies == null || !widgetBodies.containsKey(objNum))
            ) {
                refs.put(objNum, nextObjectNumber);
                nextObjectNumber++;
            }
        }
        return refs;
    }

    private static Map<Integer, String> buildButtonAppearanceBodies(
        Map<Integer, String> fieldBodies,
        Map<Integer, String> fieldValues,
        Map<Integer, String> fieldTypes,
        Map<Integer, String> widgetBodies,
        Map<Integer, String> widgetTypes,
        Map<Integer, String> widgetValues,
        Map<Integer, Integer> buttonAppearanceRefs
    ) {
        Map<Integer, String> bodies = new Map<Integer, String>();
        for (Integer objNum : buttonAppearanceRefs.keySet()) {
            Boolean isWidget = widgetBodies != null && widgetBodies.containsKey(objNum);
            String sourceBody = isWidget ? widgetBodies.get(objNum) : fieldBodies.get(objNum);
            String value = isWidget ? widgetValues.get(objNum) : fieldValues.get(objNum);
            String body = buildButtonAppearanceBody(sourceBody, value);
            if (body != null) {
                bodies.put(buttonAppearanceRefs.get(objNum), body);
            }
        }
        return bodies;
    }

    private static String buildButtonAppearanceBody(String fieldBody, String value) {
        if (String.isBlank(fieldBody)) {
            return null;
        }
        List<Decimal> rect = parseRect(fieldBody);
        if (rect.size() != 4) {
            return null;
        }
        Decimal width = rect[2] - rect[0];
        Decimal height = rect[3] - rect[1];
        if (width <= 0 || height <= 0) {
            return null;
        }
        String content = 'q';
        if (!String.isBlank(value) && value != 'Off') {
            Decimal x2 = width - 1;
            Decimal y2 = height - 1;
            if (x2 < 1) {
                x2 = width;
            }
            if (y2 < 1) {
                y2 = height;
            }
            content +=
                ' 1 w 0 g 1 1 m ' +
                decimalToPdf(x2) +
                ' ' +
                decimalToPdf(y2) +
                ' l S 1 ' +
                decimalToPdf(y2) +
                ' m ' +
                decimalToPdf(x2) +
                ' 1 l S';
        }
        content += ' Q';
        Integer length = Blob.valueOf(content).size();
        return '<</Type/XObject/Subtype/Form/FormType 1/BBox[0 0 ' +
            decimalToPdf(width) +
            ' ' +
            decimalToPdf(height) +
            ']/Matrix[1 0 0 1 0 0]/Length ' +
            length +
            '>>stream\n' +
            content +
            '\nendstream';
    }

    private static String buildTextAppearanceBody(String fieldBody, String value, String acroFormBody) {
        if (String.isBlank(fieldBody) || value == null) {
            return null;
        }
        List<Decimal> rect = parseRect(fieldBody);
        if (rect.size() != 4) {
            return null;
        }
        Decimal width = rect[2] - rect[0];
        Decimal height = rect[3] - rect[1];
        if (width <= 0 || height <= 0) {
            return null;
        }
        String da = extractLiteralString(fieldBody, '/DA');
        if (String.isBlank(da)) {
            da = extractLiteralString(acroFormBody, '/DA');
        }
        String fontName = '/Helv';
        String fontSize = '9';
        Matcher fontMatcher = Pattern.compile('(/[A-Za-z0-9_.-]+)\\s+([0-9.]+)\\s+Tf').matcher(da == null ? '' : da);
        if (fontMatcher.find()) {
            fontName = fontMatcher.group(1);
            fontSize = fontMatcher.group(2);
        }
        String fontResources = extractDictionary(acroFormBody, '/Font');
        String resources = String.isBlank(fontResources) ? '' : '/Resources<</Font<<' + fontResources + '>>>>';
        Decimal textY = ((height - Decimal.valueOf(fontSize)) / 2) + Decimal.valueOf(1);
        if (textY < 1) {
            textY = 1;
        }
        String content =
            'q BT ' +
            fontName +
            ' ' +
            fontSize +
            ' Tf 0 g 2 ' +
            decimalToPdf(textY) +
            ' Td ' +
            pdfAppearanceTextStringObject(value) +
            ' Tj ET Q';
        Integer length = Blob.valueOf(content).size();
        return '<</Type/XObject/Subtype/Form/FormType 1/BBox[0 0 ' +
            decimalToPdf(width) +
            ' ' +
            decimalToPdf(height) +
            ']/Matrix[1 0 0 1 0 0]' +
            resources +
            '/Length ' +
            length +
            '>>stream\n' +
            content +
            '\nendstream';
    }

    private static String withNormalAppearance(String body, Integer appearanceObjectNumber) {
        String updated = removePdfKeyValue(body, '/AP');
        Integer idx = updated.lastIndexOf('>>');
        return idx < 0
            ? updated
            : updated.substring(0, idx) + ' /AP <</N ' + appearanceObjectNumber + ' 0 R>> ' + updated.substring(idx);
    }

    private static String withButtonNormalAppearance(String body, String value, Integer appearanceObjectNumber) {
        String nameValue = String.isBlank(value) ? 'Off' : value;
        if (!nameValue.startsWith('/')) {
            nameValue = '/' + escapePdfName(nameValue);
        }
        String updated = removePdfKeyValue(body, '/AP');
        Integer idx = updated.lastIndexOf('>>');
        return idx < 0
            ? updated
            : updated.substring(0, idx) +
              ' /AP <</N <<' +
              nameValue +
              ' ' +
              appearanceObjectNumber +
              ' 0 R>>>> ' +
              updated.substring(idx);
    }

    private static List<Decimal> parseRect(String body) {
        List<Decimal> values = new List<Decimal>();
        String rect = extractArray(body, '/Rect');
        if (String.isBlank(rect)) {
            return values;
        }
        Matcher matcher = Pattern.compile('-?\\d+(?:\\.\\d+)?').matcher(rect);
        while (matcher.find() && values.size() < 4) {
            values.add(Decimal.valueOf(matcher.group(0)));
        }
        return values;
    }

    private static String extractLiteralString(String body, String key) {
        if (String.isBlank(body)) {
            return null;
        }
        Integer keyIdx = body.indexOf(key);
        if (keyIdx == -1) {
            return null;
        }
        Integer openIdx = body.indexOf('(', keyIdx);
        if (openIdx == -1) {
            return null;
        }
        Integer closeIdx = findLiteralClose(body, openIdx);
        return closeIdx == -1 ? null : body.substring(openIdx + 1, closeIdx);
    }

    private static String extractDictionary(String body, String key) {
        if (String.isBlank(body)) {
            return null;
        }
        Integer keyIdx = body.indexOf(key);
        if (keyIdx == -1) {
            return null;
        }
        Integer openIdx = body.indexOf('<<', keyIdx);
        if (openIdx == -1) {
            return null;
        }
        Integer depth = 0;
        for (Integer i = openIdx; i < body.length() - 1; i++) {
            String pair = body.substring(i, i + 2);
            if (pair == '<<') {
                depth++;
                i++;
            } else if (pair == '>>') {
                depth--;
                i++;
                if (depth == 0) {
                    return body.substring(openIdx + 2, i - 1);
                }
            }
        }
        return null;
    }

    private static String decimalToPdf(Decimal value) {
        String out = String.valueOf(value.setScale(3));
        while (out.contains('.') && out.endsWith('0')) {
            out = out.substring(0, out.length() - 1);
        }
        return out.endsWith('.') ? out.substring(0, out.length() - 1) : out;
    }

    private static Blob appendClassicXref(
        Blob original,
        String appendText,
        Map<Integer, Integer> offsets,
        List<Integer> updatedNums,
        Integer rootNum,
        Integer size,
        Integer prevStartXref,
        Integer xrefStart
    ) {
        String xref = 'xref\n';
        Integer i = 0;
        while (i < updatedNums.size()) {
            Integer start = updatedNums[i];
            List<Integer> run = new List<Integer>{ start };
            i++;
            while (i < updatedNums.size() && updatedNums[i] == run[run.size() - 1] + 1) {
                run.add(updatedNums[i]);
                i++;
            }
            xref += start + ' ' + run.size() + '\n';
            for (Integer num : run) {
                xref += String.valueOf(offsets.get(num)).leftPad(10, '0') + ' 00000 n \n';
            }
        }
        xref +=
            'trailer\n<< /Size ' +
            size +
            ' /Root ' +
            rootNum +
            ' 0 R /Prev ' +
            prevStartXref +
            ' >>\nstartxref\n' +
            xrefStart +
            '\n%%EOF\n';
        String mergedHex =
            EncodingUtil.convertToHex(original) +
            EncodingUtil.convertToHex(Blob.valueOf(appendText)) +
            EncodingUtil.convertToHex(Blob.valueOf(xref));
        return EncodingUtil.convertFromHex(mergedHex);
    }

    private static Blob appendXrefStream(
        Blob original,
        String appendText,
        Map<Integer, Integer> offsets,
        List<Integer> updatedNums,
        Integer rootNum,
        Integer size,
        Integer prevStartXref,
        Integer xrefStart
    ) {
        Integer xrefObjNum = size;
        offsets.put(xrefObjNum, xrefStart);
        List<Integer> xrefNums = new List<Integer>();
        xrefNums.addAll(updatedNums);
        xrefNums.add(xrefObjNum);
        xrefNums.sort();

        String streamHex = '';
        for (Integer num : xrefNums) {
            streamHex += '01' + fixedWidthHex(offsets.get(num), 4) + '0000';
        }
        Integer streamLength = streamHex.length() / 2;
        String xrefHeader =
            xrefObjNum +
            ' 0 obj\n<< /Type /XRef /Size ' +
            (size + 1) +
            ' /Root ' +
            rootNum +
            ' 0 R /Prev ' +
            prevStartXref +
            ' /W [1 4 2] /Index [' +
            buildXrefIndex(xrefNums) +
            '] /Length ' +
            streamLength +
            ' >>\nstream\n';
        String xrefFooter = '\nendstream\nendobj\nstartxref\n' + xrefStart + '\n%%EOF\n';
        String mergedHex =
            EncodingUtil.convertToHex(original) +
            EncodingUtil.convertToHex(Blob.valueOf(appendText)) +
            EncodingUtil.convertToHex(Blob.valueOf(xrefHeader)) +
            streamHex +
            EncodingUtil.convertToHex(Blob.valueOf(xrefFooter));
        return EncodingUtil.convertFromHex(mergedHex);
    }

    private static String buildXrefIndex(List<Integer> nums) {
        String index = '';
        Integer i = 0;
        while (i < nums.size()) {
            Integer start = nums[i];
            Integer count = 1;
            i++;
            while (i < nums.size() && nums[i] == start + count) {
                count++;
                i++;
            }
            if (index != '') {
                index += ' ';
            }
            index += start + ' ' + count;
        }
        return index;
    }

    private static String fixedWidthHex(Integer value, Integer byteCount) {
        String out = '';
        Integer remaining = value == null ? 0 : value;
        for (Integer i = 0; i < byteCount; i++) {
            Integer quotient = remaining / 256;
            Integer b = remaining - (quotient * 256);
            out = byteToHex(b) + out;
            remaining = quotient;
        }
        return out;
    }

    private static String byteToHex(Integer value) {
        String hex = '0123456789ABCDEF';
        Integer high = value / 16;
        Integer low = value - (high * 16);
        return hex.substring(high, high + 1) + hex.substring(low, low + 1);
    }

    private static String withoutCatalogPerms(String body) {
        if (String.isBlank(body) || !body.contains('/Perms')) {
            return body;
        }
        return body.replaceAll('/Perms\\s+\\d+\\s+0\\s+R', '');
    }

    private static XfaDatasetUpdate buildXfaDatasetUpdate(
        Map<String, Object> snapshot,
        Map<String, String> valuesByXfaName
    ) {
        if (valuesByXfaName == null || valuesByXfaName.isEmpty()) {
            return null;
        }
        List<Object> packets = (List<Object>) snapshot.get('xfaPackets');
        if (packets == null) {
            return null;
        }
        for (Object item : packets) {
            Map<String, Object> packet = (Map<String, Object>) item;
            if (String.valueOf(packet.get('name')) != 'datasets') {
                continue;
            }
            String xml = (String) packet.get('decodedStream');
            if (String.isBlank(xml)) {
                return null;
            }
            String updatedXml = xml;
            for (String xfaName : valuesByXfaName.keySet()) {
                updatedXml = withXfaFieldValue(updatedXml, xfaName, valuesByXfaName.get(xfaName));
            }
            if (updatedXml == xml) {
                return null;
            }
            XfaDatasetUpdate updatePacket = new XfaDatasetUpdate();
            updatePacket.objectNumber = Integer.valueOf(String.valueOf(packet.get('objectNumber')));
            updatePacket.xml = updatedXml;
            return updatePacket;
        }
        return null;
    }

    private static String serializeXfaDatasetObject(Integer objectNumber, String xml) {
        Integer length = Blob.valueOf(xml).size();
        return objectNumber +
            ' 0 obj\n<</Length ' +
            length +
            '/Type/EmbeddedFile>>stream\n' +
            xml +
            '\nendstream\nendobj\n';
    }

    @TestVisible
    private static String withXfaFieldValue(String xml, String fieldName, String value) {
        if (String.isBlank(xml) || String.isBlank(fieldName)) {
            return xml;
        }
        String tag = Pattern.quote(fieldName);
        String escapedValue = escapeXml(value);
        Pattern selfClosing = Pattern.compile('(?s)<' + tag + '(\\s[^>]*)?\\s*/>');
        Matcher selfClosingMatcher = selfClosing.matcher(xml);
        if (selfClosingMatcher.find()) {
            String attrs = selfClosingMatcher.group(1) == null ? '' : selfClosingMatcher.group(1);
            if (String.isBlank(attrs)) {
                attrs = '';
            }
            return xml.substring(0, selfClosingMatcher.start()) +
                '<' +
                fieldName +
                attrs +
                '>' +
                escapedValue +
                '</' +
                fieldName +
                '>' +
                xml.substring(selfClosingMatcher.end());
        }
        Pattern paired = Pattern.compile('(?s)<' + tag + '(\\s[^>]*)?>(.*?)</' + tag + '>');
        Matcher pairedMatcher = paired.matcher(xml);
        if (pairedMatcher.find()) {
            String attrs = pairedMatcher.group(1) == null ? '' : pairedMatcher.group(1);
            if (String.isBlank(attrs)) {
                attrs = '';
            }
            return xml.substring(0, pairedMatcher.start()) +
                '<' +
                fieldName +
                attrs +
                '>' +
                escapedValue +
                '</' +
                fieldName +
                '>' +
                xml.substring(pairedMatcher.end());
        }
        return xml;
    }

    private static String escapeXml(String value) {
        if (value == null) {
            return '';
        }
        String out = '';
        for (Integer i = 0; i < value.length(); i++) {
            out += escapeXmlChar(value.substring(i, i + 1));
        }
        return out;
    }

    private static String escapeXmlChar(String ch) {
        if (ch == '&') {
            return '&amp;';
        }
        if (ch == '<') {
            return '&lt;';
        }
        if (ch == '>') {
            return '&gt;';
        }
        if (ch == '"') {
            return '&quot;';
        }
        if (ch == '\'') {
            return '&apos;';
        }
        String byteHex = singleByteTextHex(ch);
        Integer code = hexByteToInt(byteHex);
        return code >= 128 ? '&#' + String.valueOf(code) + ';' : ch;
    }

    private static String normalizeXfaFieldName(String name) {
        if (String.isBlank(name)) {
            return null;
        }
        String normalized = name;
        Integer dotIdx = normalized.lastIndexOf('.');
        if (dotIdx >= 0) {
            normalized = normalized.substring(dotIdx + 1);
        }
        return normalized.replaceAll('\\[\\d+\\]', '');
    }

    private static String buildXref(List<Integer> nums, Map<Integer, Integer> offsets) {
        String xref = 'xref\n0 1\n0000000000 65535 f \n';
        Integer i = 0;
        while (i < nums.size()) {
            Integer start = nums[i];
            List<Integer> run = new List<Integer>{ start };
            i++;
            while (i < nums.size() && nums[i] == run[run.size() - 1] + 1) {
                run.add(nums[i]);
                i++;
            }
            xref += start + ' ' + run.size() + '\n';
            for (Integer num : run) {
                xref += String.valueOf(offsets.get(num)).leftPad(10, '0') + ' 00000 n \n';
            }
        }
        return xref;
    }

    private static String withNeedAppearances(String body) {
        if (body.contains('/NeedAppearances')) {
            return body.replaceAll('/NeedAppearances\\s+(true|false)', '/NeedAppearances true');
        }
        Integer idx = body.lastIndexOf('>>');
        if (idx == -1) {
            return body;
        }
        return body.substring(0, idx) + ' /NeedAppearances true ' + body.substring(idx);
    }

    private static String withFieldValue(String body, String value, String fieldType) {
        if (fieldType == 'Btn') {
            return withButtonValue(body, value);
        }
        String literal = pdfTextStringObject(value);
        String updated = removePdfKeyValue(removePdfKeyValue(removePdfKeyValue(body, '/V'), '/DV'), '/AP');
        Integer idx = updated.lastIndexOf('>>');
        if (idx == -1) {
            return updated;
        }
        return updated.substring(0, idx) + ' /V ' + literal + ' ' + updated.substring(idx);
    }

    private static String withButtonValue(String body, String value) {
        String nameValue = String.isBlank(value) ? 'Off' : value;
        if (!nameValue.startsWith('/')) {
            nameValue = '/' + escapePdfName(nameValue);
        }
        String updated = removePdfKeyValue(
            removePdfKeyValue(removePdfKeyValue(removePdfKeyValue(body, '/V'), '/DV'), '/AS'),
            '/AP'
        );
        Integer idx = updated.lastIndexOf('>>');
        if (idx == -1) {
            return updated;
        }
        return updated.substring(0, idx) + ' /V ' + nameValue + ' /AS ' + nameValue + ' ' + updated.substring(idx);
    }

    private static String withWidgetAppearanceState(String body, String value) {
        String nameValue = String.isBlank(value) ? 'Off' : value;
        if (!nameValue.startsWith('/')) {
            nameValue = '/' + escapePdfName(nameValue);
        }
        String updated = removePdfKeyValue(removePdfKeyValue(body, '/AS'), '/AP');
        Integer idx = updated.lastIndexOf('>>');
        if (idx == -1) {
            return updated;
        }
        return updated.substring(0, idx) + ' /AS ' + nameValue + ' ' + updated.substring(idx);
    }

    private static String replaceLiteralValue(String body, String key, String literal) {
        Integer keyIdx = body.indexOf(key);
        if (keyIdx == -1) {
            return body;
        }
        Integer openIdx = body.indexOf('(', keyIdx);
        if (openIdx == -1) {
            return body;
        }
        Integer closeIdx = findLiteralClose(body, openIdx);
        if (closeIdx == -1) {
            return body;
        }
        return body.substring(0, openIdx) + literal + body.substring(closeIdx + 1);
    }

    private static String replaceNameValue(String body, String key, String nameValue) {
        if (String.isBlank(body)) {
            return body;
        }
        Matcher matcher = Pattern.compile(Pattern.quote(key) + '\\s*/[A-Za-z0-9_.-]+').matcher(body);
        if (!matcher.find()) {
            return body;
        }
        return body.substring(0, matcher.start()) + key + ' ' + nameValue + body.substring(matcher.end());
    }

    private static String removePdfKeyValue(String body, String key) {
        if (String.isBlank(body) || String.isBlank(key)) {
            return body;
        }
        String updated = body;
        Integer keyIdx = findPdfKey(updated, key, 0);
        while (keyIdx != -1) {
            Integer valueEnd = findPdfValueEnd(updated, keyIdx + key.length());
            updated = updated.substring(0, keyIdx) + updated.substring(valueEnd);
            keyIdx = findPdfKey(updated, key, keyIdx);
        }
        return updated;
    }

    private static Integer findPdfKey(String body, String key, Integer fromIndex) {
        if (String.isBlank(body)) {
            return -1;
        }
        Integer idx = body.indexOf(key, Math.max(0, fromIndex));
        while (idx != -1) {
            String nextChar = idx + key.length() < body.length()
                ? body.substring(idx + key.length(), idx + key.length() + 1)
                : '';
            if (String.isBlank(nextChar) || Pattern.compile('[\\s(<\\[/]').matcher(nextChar).matches()) {
                return idx;
            }
            idx = body.indexOf(key, idx + key.length());
        }
        return -1;
    }

    private static Integer findPdfValueEnd(String body, Integer valueStart) {
        Integer i = skipPdfWhitespace(body, valueStart);
        if (i >= body.length()) {
            return i;
        }
        String ch = body.substring(i, i + 1);
        if (ch == '(') {
            Integer closeIdx = findLiteralClose(body, i);
            return closeIdx == -1 ? i + 1 : closeIdx + 1;
        }
        if (ch == '<' && (i + 1 >= body.length() || body.substring(i, i + 2) != '<<')) {
            Integer closeIdx = body.indexOf('>', i + 1);
            return closeIdx == -1 ? i + 1 : closeIdx + 1;
        }
        if (ch == '[') {
            Integer closeIdx = body.indexOf(']', i + 1);
            return closeIdx == -1 ? i + 1 : closeIdx + 1;
        }
        if (ch == '/') {
            Matcher nameMatcher = Pattern.compile('^/[^\\s<>\\[\\]()/]+').matcher(body.substring(i));
            return nameMatcher.find() ? i + nameMatcher.end() : i + 1;
        }
        Matcher refMatcher = Pattern.compile('^\\d+\\s+\\d+\\s+R\\b').matcher(body.substring(i));
        if (refMatcher.find()) {
            return i + refMatcher.end();
        }
        Matcher scalarMatcher = Pattern.compile('^[^\\s<>\\[\\]()/]+').matcher(body.substring(i));
        return scalarMatcher.find() ? i + scalarMatcher.end() : i + 1;
    }

    private static Integer skipPdfWhitespace(String body, Integer index) {
        Integer i = Math.max(0, index);
        while (i < body.length() && Pattern.compile('\\s').matcher(body.substring(i, i + 1)).matches()) {
            i++;
        }
        return i;
    }

    private static String extractArray(String body, String key) {
        Integer keyIdx = body.indexOf(key);
        if (keyIdx == -1) {
            return null;
        }
        Integer openIdx = body.indexOf('[', keyIdx);
        if (openIdx == -1) {
            return null;
        }
        Integer depth = 0;
        for (Integer i = openIdx; i < body.length(); i++) {
            String ch = body.substring(i, i + 1);
            if (ch == '[') {
                depth++;
            } else if (ch == ']') {
                depth--;
                if (depth == 0) {
                    return body.substring(openIdx + 1, i);
                }
            }
        }
        return null;
    }

    private static Integer extractRef(String body, String key) {
        if (String.isBlank(body)) {
            return null;
        }
        Pattern refPattern = Pattern.compile(Pattern.quote(key) + '\\s+(\\d+)\\s+0\\s+R');
        Matcher matcher = refPattern.matcher(body);
        return matcher.find() ? Integer.valueOf(matcher.group(1)) : null;
    }

    private static String extractLiteralName(String body, String key) {
        if (String.isBlank(body)) {
            return null;
        }
        Integer keyIdx = body.indexOf(key);
        if (keyIdx == -1) {
            return null;
        }
        Integer openIdx = body.indexOf('(', keyIdx);
        if (openIdx == -1) {
            return null;
        }
        Integer closeIdx = findLiteralClose(body, openIdx);
        if (closeIdx == -1) {
            return null;
        }
        return unescapePdfString(body.substring(openIdx + 1, closeIdx));
    }

    private static String extractName(String body, String key) {
        if (String.isBlank(body)) {
            return null;
        }
        Matcher matcher = Pattern.compile(Pattern.quote(key) + '\\s*/([A-Za-z0-9_.-]+)').matcher(body);
        return matcher.find() ? matcher.group(1) : null;
    }

    private static String extractFirstButtonOnValue(String body) {
        if (String.isBlank(body)) {
            return 'Yes';
        }
        Matcher appearanceMatcher = Pattern.compile('/Off\\s+\\d+\\s+0\\s+R\\s*/([A-Za-z0-9_.-]+)').matcher(body);
        if (appearanceMatcher.find()) {
            return appearanceMatcher.group(1);
        }
        appearanceMatcher = Pattern.compile('/([A-Za-z0-9_.-]+)\\s+\\d+\\s+0\\s+R\\s*/Off').matcher(body);
        if (appearanceMatcher.find()) {
            return appearanceMatcher.group(1);
        }
        Matcher matcher = Pattern.compile('/([A-Za-z0-9_.-]+)\\s+\\d+\\s+0\\s+R').matcher(body);
        while (matcher.find()) {
            String value = matcher.group(1);
            if (value != 'Off' && value != 'AP' && value != 'N' && value != 'D' && value != 'R') {
                return value;
            }
        }
        return 'Yes';
    }

    private static Integer findLiteralClose(String text, Integer openIdx) {
        Integer depth = 1;
        Boolean escaped = false;
        for (Integer i = openIdx + 1; i < text.length(); i++) {
            String ch = text.substring(i, i + 1);
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '(') {
                depth++;
            } else if (ch == ')') {
                depth--;
                if (depth == 0) {
                    return i;
                }
            }
        }
        return -1;
    }

    private static Integer parseRootNum(String pdfText, FillPlan plan) {
        Integer root = null;
        Matcher rootMatcher = Pattern.compile('/Root\\s+(\\d+)\\s+0\\s+R').matcher(pdfText);
        while (rootMatcher.find()) {
            root = Integer.valueOf(rootMatcher.group(1));
        }
        if (root == null) {
            throw new DocGenException('PDF root catalog not found.');
        }
        return root;
    }

    private static Integer parseTrailerSize(String pdfText) {
        Integer size = 0;
        Matcher sizeMatcher = Pattern.compile('/Size\\s+(\\d+)').matcher(pdfText);
        while (sizeMatcher.find()) {
            size = Integer.valueOf(sizeMatcher.group(1));
        }
        return size;
    }

    private static Integer parsePreviousStartXref(String pdfText) {
        Integer idx = pdfText.lastIndexOf('startxref');
        if (idx == -1) {
            throw new DocGenException('PDF startxref marker not found.');
        }
        Matcher matcher = Pattern.compile('startxref\\s+(\\d+)').matcher(pdfText.substring(idx));
        if (!matcher.find()) {
            throw new DocGenException('PDF startxref offset not found.');
        }
        return Integer.valueOf(matcher.group(1));
    }

    private static Boolean isXrefStreamPdf(String pdfText) {
        return String.isNotBlank(pdfText) && (pdfText.contains('/Type/XRef') || pdfText.contains('/Type /XRef'));
    }

    private static Integer maxObjectNumber(Map<Integer, PdfObject> objects) {
        Integer maxNum = 0;
        for (Integer num : objects.keySet()) {
            if (num > maxNum) {
                maxNum = num;
            }
        }
        return maxNum;
    }

    private static Object resolveValue(Object data, String path) {
        if (data == null || String.isBlank(path)) {
            return null;
        }
        Object current = data;
        for (String segment : path.split('\\.')) {
            if (current instanceof Map<String, Object>) {
                current = mapGetIgnoreCase((Map<String, Object>) current, segment);
            } else if (current instanceof SObject) {
                current = ((SObject) current).get(segment);
            } else {
                return null;
            }
            if (current == null) {
                return null;
            }
        }
        return current;
    }

    private static Object mapGetIgnoreCase(Map<String, Object> values, String key) {
        if (values.containsKey(key)) {
            return values.get(key);
        }
        for (String existing : values.keySet()) {
            if (existing.equalsIgnoreCase(key)) {
                return values.get(existing);
            }
        }
        return null;
    }

    private static String formatValue(Object value) {
        if (value == null) {
            return '';
        }
        if (value instanceof Date) {
            return ((Date) value).format();
        }
        if (value instanceof Datetime) {
            return ((Datetime) value).format();
        }
        return String.valueOf(value);
    }

    private static String buttonPdfValue(Object value, String onValue) {
        if (isTruthy(value)) {
            return String.isBlank(onValue) ? 'Yes' : onValue;
        }
        return 'Off';
    }

    private static Boolean isTruthy(Object value) {
        if (value == null) {
            return false;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        if (value instanceof Decimal) {
            return ((Decimal) value) != 0;
        }
        if (value instanceof Integer) {
            return ((Integer) value) != 0;
        }
        String normalized = String.valueOf(value).trim().toLowerCase();
        return normalized == 'true' ||
            normalized == 'yes' ||
            normalized == 'y' ||
            normalized == '1' ||
            normalized == 'on';
    }

    private static String escapePdfString(String value) {
        String out = value == null ? '' : value;
        out = out.replace('\\', '\\\\');
        out = out.replace('(', '\\(');
        out = out.replace(')', '\\)');
        out = out.replace('\r', '\\r');
        out = out.replace('\n', '\\n');
        return out;
    }

    private static String pdfTextStringObject(String value) {
        return isPdfLiteralSafe(value) ? '(' + escapePdfString(value) + ')' : '<' + pdfUtf16BeHex(value) + '>';
    }

    private static String pdfAppearanceTextStringObject(String value) {
        return isPdfLiteralSafe(value) ? '(' + escapePdfString(value) + ')' : '<' + pdfSingleByteTextHex(value) + '>';
    }

    private static Boolean isPdfLiteralSafe(String value) {
        if (value == null) {
            return true;
        }
        String printableAscii = ' !"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~';
        for (Integer i = 0; i < value.length(); i++) {
            String ch = value.substring(i, i + 1);
            if (!printableAscii.contains(ch)) {
                return false;
            }
        }
        return true;
    }

    private static String pdfUtf16BeHex(String value) {
        if (value == null) {
            return '';
        }
        String out = 'FEFF';
        for (Integer i = 0; i < value.length(); i++) {
            String ch = value.substring(i, i + 1);
            out += utf16CodeUnitHex(ch);
        }
        return out;
    }

    private static String pdfSingleByteTextHex(String value) {
        if (value == null) {
            return '';
        }
        String out = '';
        for (Integer i = 0; i < value.length(); i++) {
            String ch = value.substring(i, i + 1);
            out += singleByteTextHex(ch);
        }
        return out;
    }

    private static String utf16CodeUnitHex(String ch) {
        String byteHex = singleByteTextHex(ch);
        if (byteHex.length() == 2) {
            return '00' + byteHex;
        }
        return '003F';
    }

    private static String singleByteTextHex(String ch) {
        if (ch == '\n') {
            return '0A';
        }
        if (ch == '\r') {
            return '0D';
        }
        if (ch == '\t') {
            return '09';
        }
        String ascii = ' !"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~';
        Integer asciiIdx = ascii.indexOf(ch);
        if (asciiIdx >= 0) {
            return byteToHex(asciiIdx + 32);
        }
        String utf8Hex = EncodingUtil.convertToHex(Blob.valueOf(ch)).toUpperCase();
        if (utf8Hex.length() == 4 && (utf8Hex.startsWith('C2') || utf8Hex.startsWith('C3'))) {
            Integer first = hexByteToInt(utf8Hex.substring(0, 2));
            Integer second = hexByteToInt(utf8Hex.substring(2, 4));
            Integer code = first == 194 ? 128 + (second - 128) : 192 + (second - 128);
            return byteToHex(code);
        }
        return '3F';
    }

    private static String escapePdfName(String value) {
        if (String.isBlank(value)) {
            return 'Off';
        }
        String out = '';
        String safe = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-';
        for (Integer i = 0; i < value.length(); i++) {
            String ch = value.substring(i, i + 1);
            out += safe.contains(ch) ? ch : '#' + EncodingUtil.convertToHex(Blob.valueOf(ch)).toUpperCase();
        }
        return out;
    }

    private static String unescapePdfString(String value) {
        if (value == null) {
            return null;
        }
        String out = '';
        Boolean escaped = false;
        for (Integer i = 0; i < value.length(); i++) {
            String ch = value.substring(i, i + 1);
            if (escaped) {
                if (ch == 'n') {
                    out += '\n';
                } else if (ch == 'r') {
                    out += '\r';
                } else {
                    out += ch;
                }
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else {
                out += ch;
            }
        }
        return out;
    }

    private static String bytesToLatin1(Blob input) {
        return bytesToLatin1Hex(EncodingUtil.convertToHex(input));
    }

    private static String bytesToLatin1Hex(String hex) {
        List<String> chunks = new List<String>();
        List<Integer> chars = new List<Integer>();
        for (Integer i = 0; i < hex.length(); i += 2) {
            chars.add(hexByteToInt(hex.substring(i, i + 2)));
            if (chars.size() == 1000) {
                chunks.add(String.fromCharArray(chars));
                chars.clear();
            }
        }
        if (!chars.isEmpty()) {
            chunks.add(String.fromCharArray(chars));
        }
        return String.join(chunks, '');
    }

    private static String pdfTailToLatin1(String hex) {
        if (String.isBlank(hex)) {
            return '';
        }
        Integer maxTailHexChars = 131072;
        Integer start = Math.max(0, hex.length() - maxTailHexChars);
        if (Math.mod(start, 2) == 1) {
            start++;
        }
        return bytesToLatin1Hex(hex.substring(start));
    }

    private static Boolean isPdfHex(String hex) {
        return hex != null && hex.toLowerCase().startsWith('255044462d');
    }

    private static Boolean containsPdfToken(String hex, String token) {
        return hex != null && String.isNotBlank(token) && hex.toLowerCase().contains(stringToHex(token));
    }

    private static String stringToHex(String value) {
        return EncodingUtil.convertToHex(Blob.valueOf(value)).toLowerCase();
    }

    private static Integer hexByteToInt(String pair) {
        return hexNibble(pair.substring(0, 1)) * 16 + hexNibble(pair.substring(1, 2));
    }

    private static Integer hexNibble(String c) {
        Integer code = c.toLowerCase().charAt(0);
        return code <= 57 ? code - 48 : code - 87;
    }
}
