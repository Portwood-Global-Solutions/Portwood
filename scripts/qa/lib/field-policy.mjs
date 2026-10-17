/**
 * FIELD VISIBILITY POLICY — one list, shared by every suite that has an opinion
 * about where a field should appear.
 *
 * Two suites ask overlapping questions:
 *   metadata-audit  reads the repo   — "is this field on a layout XML?"
 *   record-pages    drives the org   — "does this field render on the page?"
 *
 * They each started with their own waiver list and immediately disagreed: one
 * asserted a signing token must be OFF a layout while the other reported it as
 * missing. Two suites contradicting each other is worse than either being
 * wrong, because it makes the whole report unreliable. So the policy lives here
 * and both import it.
 *
 * Three categories, and the distinction matters:
 *
 *   ELSEWHERE — a real setting, edited through a purpose-built UI. Absent from
 *               the layout is fine; absent from BOTH would be a bug.
 *   ENGINE    — written by the engine, never by a person. Read-only noise on a
 *               layout; safe either way.
 *   FORBIDDEN — a secret. Being on a layout is itself the defect, and suites
 *               assert the OPPOSITE for these.
 */

/** Settings edited through a purpose-built UI rather than the record page. */
export const UI_ELSEWHERE = {
    'DocGen_Template__c.Header_Html__c': 'edited in the Designer header band',
    'DocGen_Template__c.Footer_Html__c': 'edited in the Designer footer band',
    'DocGen_Template__c.Query_Config__c': 'edited by the visual query builder',
    'DocGen_Template__c.Form_Fields_Config__c': 'edited on the Signer Inputs tab',
    'DocGen_Template__c.Specific_Record_Ids__c': 'set by the sharing panel',
    'DocGen_Template__c.Record_Filter__c': 'set by the filter builder',
    'DocGen_Template_Version__c.Header_Html__c': 'edited in the Designer header band',
    'DocGen_Template_Version__c.Footer_Html__c': 'edited in the Designer footer band',
    'DocGen_Template_Version__c.Query_Config__c': 'edited by the visual query builder'
};

/** Written by the engine, never by a person. */
export const ENGINE_WRITTEN = {
    'DocGen_Signature_Request__c.Original_Document_CV_Id__c':
        'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Request__c.Original_Content_Document_Id__c':
        'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Request__c.Preparation_Config_CV_Id__c':
        'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Request__c.PDF_Revision__c': 'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Request__c.PDF_Internal_Preview__c':
        'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Placement__c.PDF_Page__c': 'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Placement__c.PDF_X__c': 'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Placement__c.PDF_Y__c': 'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Placement__c.PDF_Width__c': 'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Placement__c.PDF_Height__c': 'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Placement__c.PDF_Rotation__c':
        'managed by the record-page PDF signature editor and signing engine',
    'DocGen_Signature_Request__c.Frozen_Document__c': 'snapshot blob written by the signing engine',
    'DocGen_Signature_Request__c.Render_Data_Snapshot__c': 'snapshot blob written by the signing engine',
    'DocGen_Signature_Request__c.Signature_Data__c': 'written by the signing engine',
    'DocGen_Signature_Request__c.Snapshot_Taken_At__c': 'stamped by the signing engine',
    'DocGen_Signer__c.Field_Data_Json__c': 'written by the signing engine',
    'DocGen_Signer__c.Signature_Data__c': 'written by the signing engine',
    'DocGen_Template_Version__c.Watermark_Image_CV_Id__c': 'set when a watermark is uploaded',
    'DocGen_Job__c.Data_Cache_CV__c': 'internal cache pointer written by the batch',
    'DocGen_Job__c.Giant_Query_Config__c': 'internal config written by the giant-query path'
};

/**
 * SECRETS. Presence on a layout is the defect — suites assert these are ABSENT.
 *
 * Secure_Token__c is the guest signer's authorisation to write. Putting it on a
 * layout hands anyone with read access the ability to impersonate a signer.
 */
export const LAYOUT_FORBIDDEN = new Set([
    'DocGen_Signature_Request__c.Secure_Token__c',
    'DocGen_Signature_Request__c.Snapshot_Hash__c',
    'DocGen_Signature_Request__c.Frozen_Document_CV_Id__c',
    'DocGen_Signer__c.Secure_Token__c',
    'DocGen_Signer__c.PIN_Hash__c'
]);

/** Objects managed only through a purpose-built UI, or with no layout concept. */
export const NO_LAYOUT_EXPECTED = new Set([
    'DocGen_Signature_PDF__e',
    'DocGen_Guest_Render__e',
    'DocGen_Field_Writeback__e',
    'DocGen_Button__mdt',
    'Product2'
]);

/** A field is waived from "must be visible" if it is elsewhere or engine-written. */
export function visibilityWaiver(objectApi, fieldApi) {
    const key = `${objectApi}.${fieldApi}`;
    return UI_ELSEWHERE[key] || ENGINE_WRITTEN[key] || null;
}

export function isForbidden(objectApi, fieldApi) {
    return LAYOUT_FORBIDDEN.has(`${objectApi}.${fieldApi}`);
}
