import { LightningElement, track, wire } from 'lwc';
import { createRecord, updateRecord } from 'lightning/uiRecordApi';
// #236 — Type__c is a RESTRICTED picklist and the wizard defaults to 'HTML', a value
// added in v1.61.0. Orgs installed before that and later upgraded may not have it, in
// which case every create fails. Read the org's real values instead of hardcoding them.
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { downloadBase64 as downloadBase64Util, parseSOQLFields, stripOuterSelectFrom } from 'c/docGenUtils';
// HTML-first authoring: starter designs, AI prompt builder, query-shape extractor
import {
    STARTERS,
    extractQueryShape,
    buildStarterHtml,
    buildAiPrompt,
    prettyPrintHtml,
    scopeHtmlForInlinePreview,
    buildTagPalette,
    buildBlockPalette,
    splitRegions,
    joinRegions,
    stripRegionMarkers,
    buildBlankCanvasBody
} from 'c/docGenAuthoringKit';

// Each predesigned starter carries its natural object — the wizard's starter
// path never asks for one (Advanced options exposes the picker for overrides).
const STARTER_OBJECTS = {
    report: 'Account',
    invoice: 'Opportunity',
    letter: 'Contact',
    agreement: 'Account'
};

// Flexipage-style section presets — equal-width columns, Flying Saucer safe
// (display:table/table-cell, never flex/grid).
const SECTION_COLUMN_PRESETS = [2, 3, 4, 6, 12];
function columnsSectionSnippet(n) {
    let cells = '';
    for (let i = 0; i < n; i++) {
        cells +=
            '<div style="display: table-cell; vertical-align: top; padding: 0 5pt"><p>Column ' + (i + 1) + '</p></div>';
    }
    return '\n<div style="display: table; width: 100%; table-layout: fixed; margin: 8pt 0">' + cells + '</div>\n';
}

// Apex
import getTemplateList from '@salesforce/apex/DocGenController.getTemplateList';
import getTemplateById from '@salesforce/apex/DocGenController.getTemplateById';
import deleteTemplate from '@salesforce/apex/DocGenController.deleteTemplate';
import saveTemplate from '@salesforce/apex/DocGenController.saveTemplate';
import generateDocumentData from '@salesforce/apex/DocGenController.generateDocumentData';
import getTemplateVersions from '@salesforce/apex/DocGenController.getTemplateVersions';
import getVersionBodyFileInfo from '@salesforce/apex/DocGenController.getVersionBodyFileInfo';
import deleteTemplateVersion from '@salesforce/apex/DocGenController.deleteTemplateVersion';
import generateDocumentParts from '@salesforce/apex/DocGenController.generateDocumentParts';
import getContentVersionBase64 from '@salesforce/apex/DocGenController.getContentVersionBase64';
import getLatestContentVersionId from '@salesforce/apex/DocGenController.getLatestContentVersionId';
import generatePdf from '@salesforce/apex/DocGenController.generatePdf';
import previewDraftPdf from '@salesforce/apex/DocGenController.previewDraftPdf';
import previewDraftPdfData from '@salesforce/apex/DocGenController.previewDraftPdfData';
import generatePdfAsync from '@salesforce/apex/DocGenController.generatePdfAsync';
import getPdfSampleGenerationStatus from '@salesforce/apex/DocGenController.getPdfSampleGenerationStatus';
import prepareChartImages from '@salesforce/apex/DocGenChartImageController.prepareChartImages';
import { loadScript } from 'lightning/platformResourceLoader';
import CHARTJS_RESOURCE from '@salesforce/resourceUrl/DocGenChartJs';
import { prepareChartsClientSide } from 'c/docGenChartJs';
import uploadChartImage from '@salesforce/apex/DocGenChartImageController.uploadChartImage';
import deleteChartImages from '@salesforce/apex/DocGenChartImageController.deleteChartImages';
import activateVersion from '@salesforce/apex/DocGenController.activateVersion';
import createSampleTemplates from '@salesforce/apex/DocGenController.createSampleTemplates';
import exportTemplate from '@salesforce/apex/DocGenController.exportTemplate';
import importTemplate from '@salesforce/apex/DocGenController.importTemplate';
import cloneTemplate from '@salesforce/apex/DocGenController.cloneTemplate';
import getObjectFields from '@salesforce/apex/DocGenController.getObjectFields';
import getParentRelationships from '@salesforce/apex/DocGenController.getParentRelationships';
// #161 — updateable-only field list for writeback-target dropdowns (Signer Inputs tab).
// New Apex method (backend agent); if not yet deployed, QA deploys — import/usage is wired here.
import getUpdateableObjectFields from '@salesforce/apex/DocGenController.getUpdateableObjectFields';
import getObjectOptions from '@salesforce/apex/DocGenController.getObjectOptions';
import getChildRelationships from '@salesforce/apex/DocGenController.getChildRelationships';
import previewRecordData from '@salesforce/apex/DocGenController.previewRecordData';
import saveWatermarkImage from '@salesforce/apex/DocGenController.saveWatermarkImage';
import clearWatermarkImage from '@salesforce/apex/DocGenController.clearWatermarkImage';
import searchDataProviders from '@salesforce/apex/DocGenController.searchDataProviders';
import getHtmlTemplateBody from '@salesforce/apex/DocGenController.getHtmlTemplateBody';
import getConvertedHtmlSnapshot from '@salesforce/apex/DocGenController.getConvertedHtmlSnapshot';
import listHtmlTemplateImages from '@salesforce/apex/DocGenController.listHtmlTemplateImages';
import getAssets from '@salesforce/apex/DocGenController.getAssets';
import createAsset from '@salesforce/apex/DocGenController.createAsset';
import addAssetVersion from '@salesforce/apex/DocGenController.addAssetVersion';
import validateDataProvider from '@salesforce/apex/DocGenController.validateDataProvider';

// Schema
import DOCGEN_TEMPLATE_OBJECT from '@salesforce/schema/DocGen_Template__c';
import NAME_FIELD from '@salesforce/schema/DocGen_Template__c.Name';
import CATEGORY_FIELD from '@salesforce/schema/DocGen_Template__c.Category__c';
import TYPE_FIELD from '@salesforce/schema/DocGen_Template__c.Type__c';
import BASE_OBJECT_FIELD from '@salesforce/schema/DocGen_Template__c.Base_Object_API__c';
import QUERY_CONFIG_FIELD from '@salesforce/schema/DocGen_Template__c.Query_Config__c';
import DESC_FIELD from '@salesforce/schema/DocGen_Template__c.Description__c';
import OUTPUT_FORMAT_FIELD from '@salesforce/schema/DocGen_Template__c.Output_Format__c';
import TEST_RECORD_FIELD from '@salesforce/schema/DocGen_Template__c.Test_Record_Id__c';
import DOC_TITLE_FIELD from '@salesforce/schema/DocGen_Template__c.Document_Title_Format__c';
import IS_ACTIVE_FIELD from '@salesforce/schema/DocGen_Template__c.Is_Active__c';
import IS_DEFAULT_FIELD from '@salesforce/schema/DocGen_Template__c.Is_Default__c';
// 1.47 — runner visibility & sort
import SORT_ORDER_FIELD from '@salesforce/schema/DocGen_Template__c.Sort_Order__c';
import LOCK_OUTPUT_FORMAT_FIELD from '@salesforce/schema/DocGen_Template__c.Lock_Output_Format__c';
import SPECIFIC_RECORD_IDS_FIELD from '@salesforce/schema/DocGen_Template__c.Specific_Record_Ids__c';
import REQUIRED_PERM_SETS_FIELD from '@salesforce/schema/DocGen_Template__c.Required_Permission_Sets__c';
import RECORD_FILTER_FIELD from '@salesforce/schema/DocGen_Template__c.Record_Filter__c';
// 1.61 — HTML template type: header/footer fields
import HEADER_HTML_FIELD from '@salesforce/schema/DocGen_Template__c.Header_Html__c';
import FOOTER_HTML_FIELD from '@salesforce/schema/DocGen_Template__c.Footer_Html__c';
// 1.68 — page orientation (Portrait | Landscape) + size + margins for PDF rendering
import PAGE_ORIENTATION_FIELD from '@salesforce/schema/DocGen_Template__c.Page_Orientation__c';
import PAGE_SIZE_FIELD from '@salesforce/schema/DocGen_Template__c.Page_Size__c';
import PAGE_MARGINS_FIELD from '@salesforce/schema/DocGen_Template__c.Page_Margins__c';
import CUSTOM_MARGINS_FIELD from '@salesforce/schema/DocGen_Template__c.Custom_Margins__c';
// #verification — template-level signer-verification defaults
import SIGNER_VERIFICATION_FIELD from '@salesforce/schema/DocGen_Template__c.Signer_Verification__c';
import PREFILL_SIGNER_EMAIL_FIELD from '@salesforce/schema/DocGen_Template__c.Prefill_Signer_Email__c';
// #367
import SHOW_SIGNER_DECLINE_FIELD from '@salesforce/schema/DocGen_Template__c.Show_Signer_Decline__c';
import getSettingsFresh from '@salesforce/apex/DocGenSetupController.getSettingsFresh';
import testRecordFilter from '@salesforce/apex/DocGenController.testRecordFilter';
// 1.61 — HTML zip sidesteps File Upload Security via client-side unzip + per-part upload
import saveHtmlTemplateImage from '@salesforce/apex/DocGenController.saveHtmlTemplateImage';
import saveHtmlTemplateBody from '@salesforce/apex/DocGenController.saveHtmlTemplateBody';
import saveAndPublishHtmlBody from '@salesforce/apex/DocGenController.saveAndPublishHtmlBody';
// Agentforce authoring: same prompt as Copy AI Prompt, but it never leaves the org.
import isAiAvailable from '@salesforce/apex/DocGenAiTemplateController.isAiAvailable';
import generateTemplateBody from '@salesforce/apex/DocGenAiTemplateController.generateTemplateBody';
import generateBodyPreview from '@salesforce/apex/DocGenAiTemplateController.generateBodyPreview';
import savePdfAcroFormPreparedBodyChunk from '@salesforce/apex/DocGenController.savePdfAcroFormPreparedBodyChunk';
import finalizePdfAcroFormPreparedBody from '@salesforce/apex/DocGenController.finalizePdfAcroFormPreparedBody';
import getPdfAcroFormPreparedBodyStatus from '@salesforce/apex/DocGenController.getPdfAcroFormPreparedBodyStatus';
import savePdfAcroFormSnapshot from '@salesforce/apex/DocGenController.savePdfAcroFormSnapshot';
import getActivePdfAcroFormSnapshot from '@salesforce/apex/DocGenController.getActivePdfAcroFormSnapshot';
// 1.74 — guard rail for the async-decompose Queueable's 12 MB heap budget
import getContentVersionSize from '@salesforce/apex/DocGenController.getContentVersionSize';
import deleteContentVersionDocument from '@salesforce/apex/DocGenController.deleteContentVersionDocument';
import renderImageAsPdfBase64 from '@salesforce/apex/DocGenController.renderImageAsPdfBase64';
import { readZip, bytesToBase64 } from './docGenZipReader';
import { buildDocx } from './docGenZipWriter';
import { extractFirstImageFromPdfBase64 } from './docGenPdfImageExtractor';
import { decomposePdfAcroFormBase64 } from './docGenPdfAcroFormDecomposer';
// Version fields (DocGen_Template_Version__c)
import VER_IS_ACTIVE_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Is_Active__c';
import VER_CV_ID_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Content_Version_Id__c';
import VER_WATERMARK_CV_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Watermark_Image_CV_Id__c';
// 1.68 — orientation + size + margins snapshot on the version
import VER_PAGE_ORIENTATION_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Page_Orientation__c';
import VER_PAGE_SIZE_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Page_Size__c';
import VER_PAGE_MARGINS_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Page_Margins__c';
import VER_CUSTOM_MARGINS_FIELD from '@salesforce/schema/DocGen_Template_Version__c.Custom_Margins__c';

// Field API name map — resolves namespace automatically
// #236 — every Type__c picklist value this build knows about, mapped to the release
// that introduced it. Type__c is RESTRICTED, so writing a value the org does not have
// fails the whole insert. Used as a fallback list and to name what a partially-upgraded
// org is missing.
const TYPE_VALUE_HISTORY = {
    Word: '1.0',
    PowerPoint: '1.0',
    Excel: '1.5x',
    HTML: '1.61.0',
    PDF: '3.03.0'
};

/**
 * #236 — pull the ACTIONABLE message out of an LDS / UI API error.
 *
 * `error.body.message` on a DML failure is always the generic
 * "An error occurred while trying to update the record. Please try again." — which is
 * why every customer report of the template-create failure was verbatim identical and
 * none of them identified a cause. The real detail lives in `body.output.fieldErrors`
 * and `body.output.errors`, which nothing was reading.
 */
function ldsErrorDetail(error) {
    if (!error) {
        return 'Unknown error.';
    }
    const body = error.body || error;
    const parts = [];
    const output = body.output || {};
    // Field-level: { Field__c: [{ message, statusCode, fieldLabel }] }
    if (output.fieldErrors) {
        for (const key of Object.keys(output.fieldErrors)) {
            for (const fe of output.fieldErrors[key] || []) {
                const label = fe.fieldLabel || key;
                parts.push(`${label}: ${fe.message}${fe.statusCode ? ` [${fe.statusCode}]` : ''}`);
            }
        }
    }
    // Record-level: [{ message, statusCode }]
    for (const re of output.errors || []) {
        parts.push(`${re.message}${re.statusCode ? ` [${re.statusCode}]` : ''}`);
    }
    // Page-level (older shape) and DML arrays from Apex.
    for (const pe of body.pageErrors || []) {
        parts.push(pe.message);
    }
    if (Array.isArray(body)) {
        for (const b of body) {
            if (b && b.message) parts.push(b.message);
        }
    }
    if (!parts.length && body.message) {
        parts.push(body.message);
    }
    if (!parts.length && error.message) {
        parts.push(error.message);
    }
    return parts.length ? parts.join(' | ') : 'Unknown error.';
}

const F = {
    Name: 'Name',
    Category: CATEGORY_FIELD.fieldApiName,
    Type: TYPE_FIELD.fieldApiName,
    OutputFormat: OUTPUT_FORMAT_FIELD.fieldApiName,
    BaseObject: BASE_OBJECT_FIELD.fieldApiName,
    QueryConfig: QUERY_CONFIG_FIELD.fieldApiName,
    // #161 follow-up — dedicated storage for Signer Inputs form-field config.
    // The field has no @salesforce/schema import yet (backend ships it in
    // parallel), so resolve its namespace from an already-resolved field's
    // prefix (e.g. `portwoodglobal__` in subscriber orgs, '' in staging).
    FormFieldsConfig:
        QUERY_CONFIG_FIELD.fieldApiName.slice(0, QUERY_CONFIG_FIELD.fieldApiName.length - 'Query_Config__c'.length) +
        'Form_Fields_Config__c',
    Desc: DESC_FIELD.fieldApiName,
    TestRecordId: TEST_RECORD_FIELD.fieldApiName,
    DocTitleFormat: DOC_TITLE_FIELD.fieldApiName,
    IsActive: IS_ACTIVE_FIELD.fieldApiName,
    IsDefault: IS_DEFAULT_FIELD.fieldApiName,
    // 1.47 — runner visibility & sort
    SortOrder: SORT_ORDER_FIELD.fieldApiName,
    LockOutputFormat: LOCK_OUTPUT_FORMAT_FIELD.fieldApiName,
    SpecificRecordIds: SPECIFIC_RECORD_IDS_FIELD.fieldApiName,
    RequiredPermSets: REQUIRED_PERM_SETS_FIELD.fieldApiName,
    RecordFilter: RECORD_FILTER_FIELD.fieldApiName,
    // 1.61 — HTML header/footer
    HeaderHtml: HEADER_HTML_FIELD.fieldApiName,
    FooterHtml: FOOTER_HTML_FIELD.fieldApiName,
    // 1.68 — page orientation + size + margins
    PageOrientation: PAGE_ORIENTATION_FIELD.fieldApiName,
    PageSize: PAGE_SIZE_FIELD.fieldApiName,
    PageMargins: PAGE_MARGINS_FIELD.fieldApiName,
    CustomMargins: CUSTOM_MARGINS_FIELD.fieldApiName,
    // #verification — template-level defaults
    SignerVerification: SIGNER_VERIFICATION_FIELD.fieldApiName,
    PrefillSignerEmail: PREFILL_SIGNER_EMAIL_FIELD.fieldApiName,
    ShowSignerDecline: SHOW_SIGNER_DECLINE_FIELD.fieldApiName,
    // PHD-9 — stable developer key for Flow lookups; namespace resolved from an
    // already-imported field (same pattern as FormFieldsConfig).
    ApiName:
        QUERY_CONFIG_FIELD.fieldApiName.slice(0, QUERY_CONFIG_FIELD.fieldApiName.length - 'Query_Config__c'.length) +
        'API_Name__c',
    // #208 — per-template default {Message} for signature emails; namespace
    // resolved from an already-imported field (same pattern as FormFieldsConfig).
    DefaultEmailMessage:
        QUERY_CONFIG_FIELD.fieldApiName.slice(0, QUERY_CONFIG_FIELD.fieldApiName.length - 'Query_Config__c'.length) +
        'Default_Email_Message__c',
    // Version fields
    VerIsActive: VER_IS_ACTIVE_FIELD.fieldApiName,
    VerCvId: VER_CV_ID_FIELD.fieldApiName,
    VerWatermarkCv: VER_WATERMARK_CV_FIELD.fieldApiName,
    VerPageOrientation: VER_PAGE_ORIENTATION_FIELD.fieldApiName,
    VerPageSize: VER_PAGE_SIZE_FIELD.fieldApiName,
    VerPageMargins: VER_PAGE_MARGINS_FIELD.fieldApiName,
    VerCustomMargins: VER_CUSTOM_MARGINS_FIELD.fieldApiName
};

const COLUMNS = [
    { label: 'Category', fieldName: F.Category, sortable: true, initialWidth: 130 },
    { label: 'Name', fieldName: 'Name', sortable: true, wrapText: true, initialWidth: 220 },
    { label: 'Type', fieldName: F.Type, sortable: true, initialWidth: 90 },
    { label: 'Format', fieldName: F.OutputFormat, sortable: true, initialWidth: 95 },
    { label: 'Base Object', fieldName: 'displayBaseObject', sortable: true, initialWidth: 150 },
    {
        label: 'Status',
        fieldName: 'activeLabel',
        sortable: true,
        initialWidth: 90,
        cellAttributes: { class: { fieldName: 'activeClass' } }
    },
    {
        label: 'Default',
        fieldName: 'defaultLabel',
        initialWidth: 75,
        cellAttributes: { class: { fieldName: 'defaultClass' } }
    },
    {
        label: 'Created',
        fieldName: 'CreatedDate',
        type: 'date',
        sortable: true,
        initialWidth: 110,
        typeAttributes: { year: 'numeric', month: 'short', day: 'numeric' }
    },
    {
        label: 'Last Modified',
        fieldName: 'LastModifiedDate',
        type: 'date',
        sortable: true,
        initialWidth: 125,
        typeAttributes: { year: 'numeric', month: 'short', day: 'numeric' }
    },
    { label: 'Description', fieldName: F.Desc, wrapText: true },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [
                { label: 'View', name: 'view' },
                { label: 'Edit', name: 'edit' },
                { label: 'Design', name: 'design' },
                { label: 'Clone', name: 'clone' },
                { label: 'Export', name: 'export' },
                { label: 'Delete', name: 'delete' }
            ]
        }
    }
];

const VERSION_COLUMNS = [
    { label: 'Version', fieldName: 'VersionNumber' },
    {
        label: 'Active',
        fieldName: 'isActiveLabel',
        cellAttributes: {
            class: { fieldName: 'activeClass' }
        }
    },
    {
        label: 'Created Date',
        fieldName: 'CreatedDate',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: 'numeric',
            day: 'numeric',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    { label: 'Created By', fieldName: 'CreatedByName' },
    // Body file the version points at — surfaces which underlying ContentVersion
    // generation actually reads (diagnostic for stale/mismatched template bodies).
    // The same CV Id across rows = a metadata-only save reused the prior body.
    { label: 'File CV Id', fieldName: 'bodyCvId' },
    { label: 'File Name', fieldName: 'bodyCvFileName' },
    // Action buttons: uniform fixed width + centered so they line up at the right.
    {
        type: 'button',
        initialWidth: 130,
        cellAttributes: { alignment: 'center' },
        typeAttributes: {
            label: 'Preview',
            name: 'preview',
            variant: 'neutral',
            iconName: 'utility:preview'
        }
    },
    {
        type: 'button',
        initialWidth: 130,
        cellAttributes: { alignment: 'center' },
        typeAttributes: {
            label: 'Activate',
            name: 'restore',
            title: 'Restore and Activate this version',
            variant: 'brand',
            disabled: { fieldName: 'disableAction' }
        }
    },
    {
        // Issue #83 — Delete a non-active version + its body and pre-decomp CVs.
        // Disabled on the active version via the namespace-safe disableAction
        // flag set in loadVersions().
        type: 'button',
        initialWidth: 130,
        cellAttributes: { alignment: 'center' },
        typeAttributes: {
            label: 'Delete',
            name: 'deleteVersion',
            title: 'Delete this version and its files',
            variant: 'destructive-text',
            iconName: 'utility:delete',
            disabled: { fieldName: 'disableAction' }
        }
    }
];

export default class DocGenAdmin extends NavigationMixin(LightningElement) {
    @track templates = [];
    columns = COLUMNS;
    versionColumns = VERSION_COLUMNS;
    wiredTemplatesResult;

    @track versions = [];

    // Form/Wizard State
    @track activeMainTab = 'new_template';
    @track currentWizardStep = '1';

    // Create State
    newTemplateName = '';
    // PHD-9 — auto-derived from the name until the author edits it by hand
    @track newTemplateApiName = '';
    _newApiNameEdited = false;
    newTemplateCategory = '';
    // HTML-first: the wizard's default authoring path (starter) creates HTML templates.
    @track newTemplateType = 'Canvas';
    @track newTemplateOutputFormat = 'PDF';
    @track newTemplatePageOrientation = 'Portrait';
    @track newTemplatePageSize = 'Letter';
    @track newTemplatePageMargins = 'Default';
    @track newTemplateCustomMargins = '';
    newTemplateObject = 'Account';
    newTemplateDesc = '';
    newTemplateQuery = '';
    // HTML-first authoring path. 'starter' (recommended) and 'ai' both create
    // HTML templates; 'file' exposes the classic Type picker for uploads.
    // A blank canvas is the default. Nothing to choose before you can start.
    @track newAuthoringMode = 'canvas';
    @track newStarterKey = 'report';
    // One-click create: auto-built query + optional company logo asset
    @track isAutoCreating = false;
    @track newTemplateLogoName = '';
    _logoFile = null;
    // Starter/AI paths hide the power-user fields behind this toggle.
    @track showAdvancedOptions = false;
    // AI wizard step: assets the prompt can reference + the paste-back box.
    @track wizardAssets = [];
    _aiPastedHtml = null;
    // Logo control: 'none' | asset id | 'upload'.
    @track newTemplateLogoChoice = 'none';
    @track newTemplateSampleRecordId = '';
    @track sampleRecordData = null;
    isCreating = true;
    createdTemplateId;

    // Edit State
    @track isEditModalOpen = false;
    @track activeEditTab = 'details';
    editTemplateId;
    editTemplateName;
    editTemplateCategory;
    @track editTemplateType;
    // @track so children re-render when it arrives. The canvas mounts before the
    // template record finishes loading, and without this the Data picker was handed
    // undefined for the base object and rendered nothing at all.
    @track editTemplateObject;
    @track editTemplateOutputFormat;
    @track editTemplatePageOrientation = 'Portrait';
    @track editTemplatePageSize = 'Letter';
    @track editTemplatePageMargins = 'Default';
    @track editTemplateCustomMargins = '';
    @track editTemplateWatermarkCvId;
    @track isUploadingWatermark = false;
    editTemplateDesc;
    @track editTemplateQuery;
    // #161 follow-up — raw JSON string for the dedicated Form_Fields_Config__c
    // field (shape `{formFields:[...]}`). Signer Inputs no longer live on
    // Query_Config__c, so this is independent of editTemplateQuery.
    @track editFormFieldsConfig = '';
    editTemplateTestRecordId;
    editTemplateTitleFormat;
    editTemplateIsActive = true;
    editTemplateIsDefault = false;
    // 1.47 — runner visibility & sort
    editTemplateSortOrder;
    editTemplateLockOutputFormat = false;
    // #verification — template-level defaults (tri-state: Inherit / Required|Off / Yes|No)
    @track editTemplateSignerVerification = 'Inherit';
    // PHD-9 — stable developer key for Flow lookups
    @track editTemplateApiName = '';
    // #208 — per-template default {Message} for signature emails
    @track editTemplateDefaultEmailMessage = '';
    @track editTemplatePrefillSignerEmail = 'Inherit';
    // #367 — off by default; only takes effect when the org-wide switch is also on.
    @track editTemplateShowDecline = false;
    // #367 — org-wide switch, fetched once on mount so the template toggle above
    // can hide itself when the org hasn't turned Decline on at all.
    @track orgShowDecline = false;
    editTemplateSpecificRecordIds;
    editTemplateRequiredPermissionSets;
    editTemplateRecordFilter;
    @track editTemplateRecordFilterResult = '';
    @track editTemplateRecordFilterResultMessage = '';
    @track editTemplateRecordFilterTesting = false;
    // 1.61 — HTML type header/footer
    @track editTemplateHeaderHtml;
    @track editTemplateFooterHtml;
    // Show-source toggles so authors can hand-edit raw HTML (image widths,
    // inline styles, merge-tag attributes the WYSIWYG can't expose).
    @track showHeaderHtmlSource = false;
    @track showFooterHtmlSource = false;
    // v1.90 — set true when an uploaded HTML body contains its own @page CSS rule.
    // Drives the "your HTML defines its own page setup" banner and hides the
    // template-level page-layout fields, which the engine ignores in this case.
    @track editHtmlBodyOwnsPageRule = false;
    // HTML body editor (paste-back surface for LLM-generated templates)
    @track showHtmlBodyEditor = false;
    @track isLoadingHtmlBody = false;
    @track isApplyingHtmlBody = false;
    // What "Save as New Version" will save: 'file' | 'editor' | 'starter' | null
    // (null = nothing staged this session; the stored body remains active).
    @track stagedBodySource = null;
    // True when the textarea has been typed in since the last stage/reload.
    @track htmlEditorDirty = false;
    // DOCX→HTML transparency viewer (Word templates, PDF output)
    @track showDocxHtmlViewer = false;
    @track isLoadingDocxHtml = false;
    @track isSwitchingToHtml = false;
    @track docxSnapshotInfo = null;
    // Code ⇄ Preview toggles (textarea stays mounted-but-hidden so its value survives)
    @track showDocxHtmlPreview = false;
    // Tags palette (click-to-insert merge tags from the template's own schema)
    @track showTagPanel = false;
    // Blocks palette (drag-in layout pieces: columns, tables, bands, breaks…)
    @track showBlockPanel = false;
    // Images panel (upload/insert <img> tags without knowing shepherd URLs)
    @track showImagePanel = false;
    @track isLoadingTemplateImages = false;
    @track isUploadingInsertImage = false;
    @track templateImages = [];
    // Visual mode — the scoped preview rendered contenteditable, so authors
    // edit text in place with the real layout visible. Only the body content
    // round-trips; head/styles/@page never do.
    @track showHtmlBodyVisual = false;
    _visualOriginalCode = null;
    _visualEnteredDom = null;
    // What the caret is on ("Editing: Table cell") — answers "what am I
    // about to color?"
    @track selectionContextLabel = '';
    // Pill inspector: click a pill → formatting menu (currency, date, QR…)
    @track pillMenu = null;
    // Notion-style slash-command menu: type "/" in the canvas → searchable insert palette.
    @track slashMenu = null;
    // Right-click context menu in the canvas.
    @track ctxMenu = null;
    _slashCtx = null;
    _slashSel = 0;
    // Floating searchable panels replace the fixed right rail: 'insert' | 'tags' | 'images' | 'watermark'.
    @track activePanel = null;
    @track panelSearch = '';
    // Query panel describe cache.
    @track designerQueryMeta = null;
    _queryMetaFor = null;
    // AI-wizard field checklist describe cache + search.
    @track wizardQueryMeta = null;
    _wizardQueryMetaFor = null;
    @track aiFieldSearch = '';
    // AI step: which shared assets ride into the prompt (null = all).
    @track aiSelectedAssetIds = null;
    // Step 3: the author's own description, injected into the prompt.
    @track aiDocDescription = '';
    // Agentforce authoring (in-org generation). Degrades to Copy AI Prompt when
    // the org has no Einstein entitlement — the button simply does not appear.
    @track isAgentforceAvailable = false;
    @track isAgentforcePanelOpen = false;
    @track isAgentforceGenerating = false;
    @track agentforceSummary = '';
    @track agentforceFindings = [];
    // 'edit' revises the body on the canvas; 'create' writes a new one from
    // scratch. Defaults to edit whenever there is something to edit.
    @track agentforceMode = 'create';
    @track agentforceConfirmDiscard = false;
    // Wizard AI step: generate in-org instead of copy-pasting to an assistant.
    @track isWizardAgentforceGenerating = false;
    @track wizardAgentforceSummary = '';
    @track wizardAgentforceFindings = [];
    // Upload-time fidelity report (#272): DocGenTemplateLinter warnings riding
    // the saveHtmlTemplateBody / saveAndPublishHtmlBody response. Advisory
    // only — the body is already stored when these show, nothing was blocked.
    @track lintFindings = [];
    // Live PDF preview: draft HTML → real Blob.toPdf render → blob: iframe.
    @track pdfPreviewUrl = null;
    @track isPdfPreviewLoading = false;
    _activePill = null;
    // Canvas page setup, mirrored into the template's @page rule. Custom
    // sizes cover everything from 3x4in nametags to poster PDFs.
    @track pageSetup = {
        size: 'Letter',
        orient: 'portrait',
        margin: '0.75',
        customW: '8.5',
        customH: '11',
        customMargin: '0.75'
    };
    // Last HTML body text this session touched (upload, starter, or Apply) so
    // reopening the editor doesn't need a server round-trip.
    _lastUploadedHtmlText = null;

    @track currentFileId;
    @track uploadedFileName = '';
    @track uploadedContentVersionId;
    @track showEditFileUpload = true;
    @track uploadedPdfAcroFormSnapshot = null;
    @track pdfAcroFormSnapshotVersionId = null;
    @track isPdfAcroFormSnapshotLoaded = false;
    @track isSavingPdfAcroFormMapping = false;
    @track isPreparingPdfAcroFormBody = false;
    @track pdfAcroFormPreparationText = '';
    @track pdfAcroFormSearchTerm = '';
    @track pdfAcroFormFilter = 'all';
    uploadedPdfAcroFormSnapshotJson = null;
    uploadedPdfAcroFormNormalizedBase64 = null;

    // Preview/Restore State
    @track isPreviewModalOpen = false;
    @track previewVersion = {};
    isLoadingVersions = false;

    // Visual builder toggle (wizard + edit modal)
    @track useVisualBuilder = false;
    @track editUseVisualBuilder = false;

    // Apex Data Provider mode (V4 — class-backed templates).
    // Wizard + edit modal both feed the same picker state via the _editContext flag.
    @track useApexProvider = false;
    @track editUseApexProvider = false;

    // Step 1 data-source choice. 'record' = pick a base SObject (default, classic
    // path); 'apex' = bind to a DocGenDataProvider class right from the start so
    // the wizard skips the base-object/sample-record requirements.
    @track dataSourceMode = 'record';
    @track providerSearchTerm = '';
    @track providerOptions = [];
    @track showProviderPicker = false;
    @track selectedProviderClassName = '';
    @track providerFields = [];
    @track isValidatingProvider = false;
    // Optional base SObject API name for v4 Apex Provider templates. When set,
    // overrides the 'ApexProvider' sentinel in Base_Object_API__c so the template
    // is filterable by record context (cross-object aggregation use case).
    @track apexProviderBaseObject = '';

    // Edit modal manual query toggle (for backward compat with existing V3 configs)
    @track isManualQuery = false;
    // Context flag: true when editing in modal, false when in wizard
    _editContext = false;

    get _activeQuery() {
        return this._editContext ? this.editTemplateQuery : this.newTemplateQuery;
    }
    set _activeQuery(v) {
        if (this._editContext) {
            this.editTemplateQuery = v;
        } else {
            this.newTemplateQuery = v;
        }
    }
    get _activeObject() {
        return this._editContext ? this.editTemplateObject : this.newTemplateObject;
    }
    get _activeSampleId() {
        return this._editContext ? this.editTemplateTestRecordId : this.newTemplateSampleRecordId;
    }
    // Builder 2.0 state
    @track objectOptions = [];
    @track filteredObjectOptions = [];
    @track showObjectSuggestions = false;
    @track queryTreeNodes = [];
    @track queryWarnings = null;
    @track builderTab = 'fields';
    @track builderSearchTerm = '';
    @track _allFields = [];
    @track _allChildren = [];
    @track _allParents = [];
    // #161 — Signer Inputs (form fields). Updateable-only field list for writeback
    // targets; rows of { key, label, fieldApiName, type, required, writeback,
    // mergeTag, choices, listOnCertificate }.
    @track _allUpdateableFields = [];
    @track signerFields = [];

    get builderFieldsTabClass() {
        return this.builderTab === 'fields' ? 'builder-tab-active' : '';
    }
    get builderRelatedTabClass() {
        return this.builderTab === 'related' ? 'builder-tab-active' : '';
    }
    get builderParentsTabClass() {
        return this.builderTab === 'parents' ? 'builder-tab-active' : '';
    }
    get builderPanelItems() {
        const s = (this.builderSearchTerm || '').toLowerCase();
        if (this.builderTab === 'fields') {
            return (this._allFields || [])
                .filter((f) => !s || f.label.toLowerCase().includes(s) || f.value.toLowerCase().includes(s))
                .slice(0, 150)
                .map((f) => ({ value: f.value, label: f.label, extra: f.type || '' }));
        } else if (this.builderTab === 'related') {
            return (this._allChildren || [])
                .filter((c) => !s || c.label.toLowerCase().includes(s) || c.value.toLowerCase().includes(s))
                .slice(0, 80)
                .map((c) => ({ value: c.value, label: c.label, extra: c.childObjectApiName || '' }));
        } else if (this.builderTab === 'parents') {
            return (this._allParents || [])
                .filter((p) => !s || p.label.toLowerCase().includes(s) || p.value.toLowerCase().includes(s))
                .slice(0, 80)
                .map((p) => ({ value: p.value, label: p.label, extra: p.targetObject || '' }));
        }
        return [];
    }

    get hasUploadedPdfAcroFormFields() {
        return (
            this.uploadedPdfAcroFormSnapshot &&
            this.uploadedPdfAcroFormSnapshot.fields &&
            this.uploadedPdfAcroFormSnapshot.fields.length > 0
        );
    }

    get pdfAcroFormMappedCount() {
        if (!this.hasUploadedPdfAcroFormFields) {
            return 0;
        }
        return this.uploadedPdfAcroFormSnapshot.fields.filter((field) => !!(field.mappedPath || '').trim()).length;
    }

    get hasSavedPdfAcroFormSnapshotTarget() {
        return String(this.pdfAcroFormSnapshotVersionId || '').startsWith('a07');
    }

    get isPdfAcroFormSaveMappingDisabled() {
        return (
            this.isSavingPdfAcroFormMapping ||
            this.isPreparingPdfAcroFormBody ||
            !this.editTemplateId ||
            !this.hasSavedPdfAcroFormSnapshotTarget ||
            !this.uploadedPdfAcroFormSnapshotJson
        );
    }

    get pdfAcroFormMappingStatusText() {
        if (!this.hasUploadedPdfAcroFormFields) {
            return '';
        }
        if (this.isPdfAcroFormSnapshotLoaded && this.hasSavedPdfAcroFormSnapshotTarget) {
            return 'Saved on the active template version.';
        }
        if (this.hasSavedPdfAcroFormSnapshotTarget) {
            return 'Mapping changes are ready to save to the active template version.';
        }
        return 'Draft mapping. Save as New Version will store it.';
    }

    get pdfAcroFormFieldCount() {
        if (!this.hasUploadedPdfAcroFormFields) {
            return 0;
        }
        return this.uploadedPdfAcroFormSnapshot.fields.length;
    }

    get pdfAcroFormVisibleFieldCount() {
        return this.pdfAcroFormFieldRows.length;
    }

    get pdfAcroFormFilterOptions() {
        return [
            { label: 'All fields', value: 'all' },
            { label: 'Mapped', value: 'mapped' },
            { label: 'Unmapped', value: 'unmapped' },
            { label: 'Text fields', value: 'text' },
            { label: 'Buttons', value: 'button' }
        ];
    }

    get pdfAcroFormDataPathOptions() {
        const paths = this._pdfAcroFormDataPathsFromQuery(this.editTemplateQuery);
        return [
            { label: 'Not mapped', value: '' },
            ...paths.map((path) => ({
                label: path.label,
                value: path.value
            }))
        ];
    }

    get hasPdfAcroFormDataPathOptions() {
        return this.pdfAcroFormDataPathOptions.length > 1;
    }

    get pdfAcroFormFieldRows() {
        if (!this.hasUploadedPdfAcroFormFields) {
            return [];
        }
        const search = (this.pdfAcroFormSearchTerm || '').trim().toLowerCase();
        const filter = this.pdfAcroFormFilter || 'all';
        return this.uploadedPdfAcroFormSnapshot.fields
            .map((field, index) => {
                const displayName = field.name || field.partialName || 'Field ' + (index + 1);
                const rect = field.rect || [];
                const positionText = this._pdfAcroFormPositionText(rect, field.mediaBox);
                const estimatedPageNumber =
                    field.estimatedPageNumber || this._pdfAcroFormEstimatedPageNumber(displayName);
                return {
                    key: (field.objectNumber || 'field') + '-' + index,
                    index,
                    rect,
                    displayName,
                    friendlyLabel: field.friendlyLabel || '',
                    partialName: field.partialName,
                    fieldType: field.fieldType || 'Field',
                    pageLabel: field.pageNumber
                        ? 'Page ' + field.pageNumber
                        : estimatedPageNumber
                          ? 'Page ~' + estimatedPageNumber
                          : '',
                    locationLabel: field.locationLabel || '',
                    positionText,
                    isButton: field.fieldType === 'Btn',
                    mappedPath: field.mappedPath || '',
                    buttonOnValue: field.buttonOnValue || 'Yes',
                    buttonOnValuesText:
                        field.buttonOnValues && field.buttonOnValues.length ? field.buttonOnValues.join(', ') : '',
                    rowClass: field.mappedPath ? 'pdf-acroform-row pdf-acroform-row_mapped' : 'pdf-acroform-row'
                };
            })
            .filter((row) => {
                if (filter === 'mapped' && !row.mappedPath) {
                    return false;
                }
                if (filter === 'unmapped' && row.mappedPath) {
                    return false;
                }
                if (filter === 'text' && row.fieldType !== 'Tx') {
                    return false;
                }
                if (filter === 'button' && !row.isButton) {
                    return false;
                }
                if (!search) {
                    return true;
                }
                return [
                    row.friendlyLabel,
                    row.displayName,
                    row.partialName,
                    row.fieldType,
                    row.pageLabel,
                    row.locationLabel,
                    row.positionText,
                    row.mappedPath,
                    row.buttonOnValue,
                    row.buttonOnValuesText
                ]
                    .filter(Boolean)
                    .some((value) => String(value).toLowerCase().includes(search));
            })
            .sort((a, b) => this._comparePdfAcroFormRows(a, b));
    }

    _pdfAcroFormEstimatedPageNumber(fieldName) {
        const match = /#subform\[(\d+)\]/.exec(fieldName || '');
        return match ? Number(match[1]) + 1 : null;
    }

    _comparePdfAcroFormRows(a, b) {
        const pageA = this._pdfAcroFormSortPage(a);
        const pageB = this._pdfAcroFormSortPage(b);
        if (pageA !== pageB) {
            return pageA - pageB;
        }

        const boxA = this._pdfAcroFormSortBox(a);
        const boxB = this._pdfAcroFormSortBox(b);
        const rowTolerance = 8;
        if (Math.abs(boxA.top - boxB.top) > rowTolerance) {
            return boxB.top - boxA.top;
        }
        if (Math.abs(boxA.left - boxB.left) > 0.01) {
            return boxA.left - boxB.left;
        }
        if (Math.abs(boxA.bottom - boxB.bottom) > 0.01) {
            return boxB.bottom - boxA.bottom;
        }
        return a.displayName.localeCompare(b.displayName);
    }

    _pdfAcroFormSortPage(row) {
        const match = /^Page\s+~?(\d+)/.exec(row.pageLabel || '');
        return match ? Number(match[1]) : Number.MAX_SAFE_INTEGER;
    }

    _pdfAcroFormSortBox(row) {
        const rect = row.rect || [];
        const left = Math.min(Number(rect[0]), Number(rect[2]));
        const right = Math.max(Number(rect[0]), Number(rect[2]));
        const bottom = Math.min(Number(rect[1]), Number(rect[3]));
        const top = Math.max(Number(rect[1]), Number(rect[3]));
        if (![left, right, bottom, top].every(Number.isFinite)) {
            return {
                left: Number.MAX_SAFE_INTEGER,
                right: Number.MAX_SAFE_INTEGER,
                bottom: Number.MIN_SAFE_INTEGER,
                top: Number.MIN_SAFE_INTEGER
            };
        }
        return { left, right, bottom, top };
    }

    _pdfAcroFormDataPathsFromQuery(queryConfig) {
        if (!queryConfig) {
            return [];
        }
        const byValue = new Map();
        const addPath = (value, labelPrefix) => {
            if (!value || typeof value !== 'string') {
                return;
            }
            const trimmed = value.trim();
            if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith('/')) {
                return;
            }
            if (!byValue.has(trimmed)) {
                byValue.set(trimmed, {
                    value: trimmed,
                    label: labelPrefix ? labelPrefix + ': ' + trimmed : trimmed
                });
            }
        };

        try {
            const qc = queryConfig.trim();
            if (qc.startsWith('{')) {
                const config = JSON.parse(qc);
                if (config.v === 4 && config.provider) {
                    const declaredLoops = new Set();
                    for (const fieldName of this.providerFields || []) {
                        if (typeof fieldName === 'string' && fieldName.startsWith('#')) {
                            declaredLoops.add(fieldName.substring(1));
                        }
                    }
                    for (const fieldName of this.providerFields || []) {
                        if (typeof fieldName !== 'string' || fieldName.startsWith('#') || fieldName.startsWith('/')) {
                            continue;
                        }
                        const prefix = fieldName.includes('.') ? fieldName.split('.')[0] : '';
                        if (!prefix || !declaredLoops.has(prefix)) {
                            addPath(fieldName, prefix ? 'Parent' : 'Field');
                        }
                    }
                    return Array.from(byValue.values());
                }
                if (config.v >= 3 && config.nodes) {
                    const root = (config.nodes || []).find((node) => !node.parentNode) || {};
                    for (const fieldName of root.fields || []) {
                        addPath(fieldName, 'Field');
                    }
                    for (const fieldName of root.parentFields || []) {
                        addPath(fieldName, 'Parent');
                    }
                    return Array.from(byValue.values());
                }
            }

            const parsed = parseSOQLFields(queryConfig);
            for (const fieldName of parsed.baseFields || []) {
                addPath(fieldName, 'Field');
            }
            for (const fieldName of parsed.parentFields || []) {
                addPath(fieldName, 'Parent');
            }
        } catch {
            return [];
        }
        return Array.from(byValue.values());
    }

    _pdfAcroFormPositionText(rect, mediaBox) {
        if (!rect || rect.length < 4) {
            return '';
        }
        const pointsPerInch = 72;
        const pageTop = mediaBox && Number.isFinite(Number(mediaBox.top)) ? Number(mediaBox.top) : 792;
        const pageLeft = mediaBox && Number.isFinite(Number(mediaBox.left)) ? Number(mediaBox.left) : 0;
        const left = Math.min(Number(rect[0]), Number(rect[2]));
        const right = Math.max(Number(rect[0]), Number(rect[2]));
        const bottom = Math.min(Number(rect[1]), Number(rect[3]));
        const top = Math.max(Number(rect[1]), Number(rect[3]));
        if (![left, right, bottom, top].every(Number.isFinite)) {
            return '';
        }
        const fromLeft = (left - pageLeft) / pointsPerInch;
        const fromTop = (pageTop - top) / pointsPerInch;
        const width = (right - left) / pointsPerInch;
        const height = (top - bottom) / pointsPerInch;
        return (
            fromLeft.toFixed(1) +
            ' in from left, ' +
            fromTop.toFixed(1) +
            ' in from top, ' +
            width.toFixed(1) +
            ' x ' +
            height.toFixed(1) +
            ' in'
        );
    }

    handleBuilderTabClick(event) {
        this.builderTab = event.currentTarget.dataset.tab;
        this.builderSearchTerm = '';
    }

    handleBuilderSearch(event) {
        this.builderSearchTerm = event.target.value;
    }

    handleBuilderItemClick(event) {
        const val = event.currentTarget.dataset.value;
        const q = (this.newTemplateQuery || '').trim();
        const sep = q && !q.endsWith(',') ? ', ' : '';

        let insert = '';
        if (this.builderTab === 'fields') {
            insert = sep + val;
        } else if (this.builderTab === 'related') {
            insert = (q ? ',\n' : '') + '(SELECT Id FROM ' + val + ')';
        } else if (this.builderTab === 'parents') {
            insert = sep + val + '.Name';
        }

        this.newTemplateQuery = q + insert;
        this._updateQueryTree();
    }

    @track suggestions = [];
    @track showSuggestions = false;

    handleDirectQueryEdit(event) {
        this.newTemplateQuery = event.target.value;
        this._updateQueryTree();
        this._updateSuggestions(event.target);
        // Debounced sample data refresh
        clearTimeout(this._sampleDebounce);
        this._sampleDebounce = setTimeout(() => {
            this._loadSampleData();
        }, 800);
    }

    _findUnmatchedParen(str) {
        let depth = 0;
        for (let i = str.length - 1; i >= 0; i--) {
            if (str[i] === ')') depth++;
            if (str[i] === '(') {
                if (depth === 0) return i;
                depth--;
            }
        }
        return -1;
    }

    _getToken(before) {
        // Token = text after the last comma, open-paren, or newline
        let sepIdx = -1;
        for (let i = before.length - 1; i >= 0; i--) {
            const ch = before[i];
            if (ch === ',' || ch === '(' || ch === '\n') {
                sepIdx = i;
                break;
            }
        }
        return {
            token: before.substring(sepIdx + 1).trim(),
            sepChar: sepIdx >= 0 ? before[sepIdx] : '',
            start: sepIdx + 1
        };
    }

    _updateSuggestions(textarea) {
        const text = textarea.value;
        const cursor = textarea.selectionStart || text.length;
        const before = text.substring(0, cursor);
        this._suggestCursor = cursor;

        const { token, sepChar, start } = this._getToken(before);
        this._tokenReplaceStart = start;

        // Skip SOQL keywords
        const upper = token.toUpperCase();
        if (
            [
                'SELECT',
                'FROM',
                'WHERE',
                'AND',
                'OR',
                'ORDER',
                'BY',
                'LIMIT',
                'ASC',
                'DESC',
                'LIKE',
                'IN',
                'NOT',
                'NULL',
                '=',
                '!=',
                '>',
                '<',
                '>=',
                '<='
            ].includes(upper)
        ) {
            this.showSuggestions = false;
            return;
        }

        // 1) Just typed "(" — show child relationships
        if (sepChar === '(' && token === '') {
            this._suggestMode = 'related-scaffold';
            this.suggestions = (this._allChildren || [])
                .slice(0, 15)
                .map((c) => ({ value: c.value, label: c.label, extra: c.childObjectApiName || '' }));
            this.showSuggestions = this.suggestions.length > 0;
            return;
        }

        // 2) Are we inside an unmatched paren? (subquery context)
        const parenIdx = this._findUnmatchedParen(before);
        if (parenIdx !== -1) {
            const insideParen = before.substring(parenIdx + 1).trim();
            const upperInside = insideParen.toUpperCase();

            // 2a) After FROM with no space after relationship name yet — suggest child relationships
            const fromAtEnd = upperInside.match(/FROM\s*(\S*)$/);
            if (fromAtEnd) {
                this._suggestMode = 'related';
                const s = (fromAtEnd[1] || '').toLowerCase();
                this.suggestions = (this._allChildren || [])
                    .filter((c) => !s || c.value.toLowerCase().includes(s) || c.label.toLowerCase().includes(s))
                    .slice(0, 15)
                    .map((c) => ({ value: c.value, label: c.label, extra: c.childObjectApiName || '' }));
                this.showSuggestions = this.suggestions.length > 0;
                return;
            }

            // 2b) We know the FROM object — suggest that child object's fields
            const fromMatch = insideParen.match(/FROM\s+(\w+)/i);
            if (fromMatch && token.length >= 1) {
                const relName = fromMatch[1];
                const childRel = (this._allChildren || []).find((c) => c.value.toLowerCase() === relName.toLowerCase());
                if (childRel) {
                    this._suggestMode = 'child-field';
                    const cacheKey = '_cache_' + childRel.childObjectApiName;
                    const s = token.toLowerCase();
                    if (this[cacheKey]) {
                        this._showSimpleSuggestions(this[cacheKey], s);
                    } else {
                        getObjectFields({ objectName: childRel.childObjectApiName })
                            .then((data) => {
                                this[cacheKey] = data || [];
                                this._showSimpleSuggestions(data || [], s);
                            })
                            .catch(() => {
                                this.showSuggestions = false;
                            });
                    }
                    return;
                }
            }

            // 2c) Inside paren but no FROM yet and token has text — could be typing SELECT fields or relationship name
            if (token.length >= 1 && !upperInside.includes('FROM')) {
                this._suggestMode = 'related';
                const s = token.toLowerCase();
                this.suggestions = (this._allChildren || [])
                    .filter((c) => c.value.toLowerCase().includes(s) || c.label.toLowerCase().includes(s))
                    .slice(0, 15)
                    .map((c) => ({ value: c.value, label: c.label, extra: c.childObjectApiName || '' }));
                this.showSuggestions = this.suggestions.length > 0;
                return;
            }
        }

        // 3) After a dot — parent field lookup
        if (token.includes('.')) {
            const dot = token.lastIndexOf('.');
            const parentName = token.substring(0, dot);
            const fieldSearch = token.substring(dot + 1).toLowerCase();
            const parentRel = (this._allParents || []).find((p) => p.value.toLowerCase() === parentName.toLowerCase());
            if (parentRel) {
                this._suggestMode = 'parent-field';
                this._suggestParent = parentName;
                const cacheKey = '_cache_' + parentRel.targetObject;
                if (this[cacheKey]) {
                    this._showParentFieldSuggestions(this[cacheKey], fieldSearch, parentName);
                } else {
                    getObjectFields({ objectName: parentRel.targetObject })
                        .then((data) => {
                            this[cacheKey] = data || [];
                            this._showParentFieldSuggestions(data || [], fieldSearch, parentName);
                        })
                        .catch(() => {
                            this.showSuggestions = false;
                        });
                }
                return;
            }
        }

        // 4) Default — base object fields + parent relationship names
        if (token.length >= 1) {
            this._suggestMode = 'field';
            const s = token.toLowerCase();
            const fieldResults = (this._allFields || [])
                .filter((f) => f.value.toLowerCase().includes(s) || f.label.toLowerCase().includes(s))
                .slice(0, 8)
                .map((f) => ({ value: f.value, label: f.label, extra: f.type || '' }));
            const parentResults = (this._allParents || [])
                .filter((p) => p.value.toLowerCase().includes(s) || p.label.toLowerCase().includes(s))
                .slice(0, 4)
                .map((p) => ({ value: p.value + '.', label: p.label, extra: '→ ' + (p.targetObject || '') }));
            this.suggestions = [...fieldResults, ...parentResults];
            this.showSuggestions = this.suggestions.length > 0;
        } else {
            this.showSuggestions = false;
        }
    }

    _showSimpleSuggestions(fields, search) {
        this.suggestions = (fields || [])
            .filter((f) => !search || f.value.toLowerCase().includes(search) || f.label.toLowerCase().includes(search))
            .slice(0, 10)
            .map((f) => ({ value: f.value, label: f.label, extra: f.type || '' }));
        this.showSuggestions = this.suggestions.length > 0;
    }

    _showParentFieldSuggestions(fields, search, parentName) {
        this.suggestions = (fields || [])
            .filter((f) => !search || f.value.toLowerCase().includes(search) || f.label.toLowerCase().includes(search))
            .slice(0, 10)
            .map((f) => ({ value: parentName + '.' + f.value, label: f.label, extra: f.type || '' }));
        this.showSuggestions = this.suggestions.length > 0;
    }

    handleSuggestionClick(event) {
        const val = event.currentTarget.dataset.value;
        const text = this._activeQuery || '';
        const cursor = this._suggestCursor || text.length;

        // Find the token boundaries fresh — don't rely on cached values
        const before = text.substring(0, cursor);
        let sepIdx = -1;
        for (let i = before.length - 1; i >= 0; i--) {
            const ch = before[i];
            if (ch === ',' || ch === '(' || ch === '\n') {
                sepIdx = i;
                break;
            }
        }
        // prefix = everything up to and including the separator
        // after = everything after cursor
        const prefix = text.substring(0, sepIdx + 1);
        const after = text.substring(cursor);
        // Add a space after separator if needed
        const needSpace = prefix.length > 0 && !prefix.endsWith(' ') && !prefix.endsWith('(') && !prefix.endsWith('\n');

        let result;
        if (this._suggestMode === 'related-scaffold') {
            // Typed "(" — scaffold full subquery, prefix already ends with "("
            result = prefix + 'SELECT Id FROM ' + val + ')' + after;
        } else if (this._suggestMode === 'related') {
            // Replacing relationship name (after FROM)
            result = prefix + (needSpace ? ' ' : '') + val + after;
        } else if (val.endsWith('.')) {
            // Parent relationship — "Owner." — no comma, they pick a field next
            result = prefix + (needSpace ? ' ' : '') + val + after;
        } else {
            // Regular field — replace token, add trailing comma
            result = prefix + (needSpace ? ' ' : '') + val + ', ' + after;
        }

        this._activeQuery = result;
        // Native textarea doesn't re-render from tracked property after user input — set DOM directly
        const taSelector = this._editContext ? '.edit-query-textarea' : '.wizard-query-textarea';
        const ta = this.template.querySelector(taSelector);
        if (ta) {
            ta.value = result;
        }
        this.showSuggestions = false;
        this._updateQueryTree();

        // If parent with dot, re-trigger to show that parent's fields
        if (val.endsWith('.')) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                const ta = this.template.querySelector(taSelector);
                if (ta) {
                    const newPos = prefix.length + (needSpace ? 1 : 0) + val.length;
                    ta.setSelectionRange(newPos, newPos);
                    ta.focus();
                    this._updateSuggestions(ta);
                }
            }, 50);
        }
    }

    handleSuggestionMouseDown(event) {
        // Prevent textarea blur from firing before onclick
        event.preventDefault();
    }

    handleQueryKeyDown(event) {
        if (event.key === 'Escape' && this.showSuggestions) {
            this.showSuggestions = false;
            event.stopPropagation();
        }
    }

    // Filter State
    searchKey = '';

    @track isInstallingSamples = false;
    _samplesChecked = false;

    // LIST light, LOAD heavy on demand. getTemplateList returns only what the
    // grid, the search and the pickers read — no long-text bodies, no attached
    // document subquery. openEditModal fetches the full record for the one
    // template being opened. See DocGenController.getTemplateList.
    @wire(getTemplateList)
    wiredTemplates(result) {
        this.wiredTemplatesResult = result;
        if (result.data) {
            this.templates = result.data.map((t) => {
                // F.IsActive may be undefined on rows created before the field
                // shipped — treat null/undefined as Active to match the server
                // OR-NULL filter in getTemplatesForObjectInternal.
                const isActive = t[F.IsActive] !== false;
                const rawBase = t[F.BaseObject];
                const displayBaseObject =
                    rawBase === 'FlowJsonData'
                        ? 'JSON Data (from Flow)'
                        : rawBase === 'ApexProvider'
                          ? 'Apex Data Provider'
                          : rawBase;
                return {
                    ...t,
                    displayBaseObject,
                    defaultLabel: t[F.IsDefault] ? '★' : '',
                    defaultClass: t[F.IsDefault] ? 'slds-text-color_success slds-text-title_bold' : '',
                    activeLabel: isActive ? 'Active' : 'Inactive',
                    activeClass: isActive
                        ? 'slds-text-color_success slds-text-title_bold'
                        : 'slds-text-color_weak slds-text-title_bold'
                };
            });
            this._samplesChecked = true;
        } else if (result.error) {
            this.showToast('Error', 'Error loading templates', 'error');
        }
    }

    templateSortedBy;
    templateSortedDirection = 'asc';

    get filteredTemplates() {
        let rows = this.templates;
        if (this.searchKey) {
            const lowerKey = this.searchKey.toLowerCase();
            rows = rows.filter(
                (t) =>
                    (t.Name && t.Name.toLowerCase().includes(lowerKey)) ||
                    (t[F.Category] && t[F.Category].toLowerCase().includes(lowerKey)) ||
                    (t[F.BaseObject] && t[F.BaseObject].toLowerCase().includes(lowerKey)) ||
                    (t.displayBaseObject && t.displayBaseObject.toLowerCase().includes(lowerKey)) ||
                    (t[F.Type] && t[F.Type].toLowerCase().includes(lowerKey)) ||
                    (t[F.OutputFormat] && t[F.OutputFormat].toLowerCase().includes(lowerKey)) ||
                    (t[F.Desc] && t[F.Desc].toLowerCase().includes(lowerKey)) ||
                    (t[F.ApiName] && t[F.ApiName].toLowerCase().includes(lowerKey)) ||
                    (t.Id && t.Id.toLowerCase().includes(lowerKey))
            );
        }
        if (this.templateSortedBy) {
            const key = this.templateSortedBy;
            const dir = this.templateSortedDirection === 'asc' ? 1 : -1;
            rows = [...rows].sort(
                (a, b) => String(a[key] ?? '').localeCompare(String(b[key] ?? ''), undefined, { numeric: true }) * dir
            );
        }
        return rows;
    }

    get templateCountLabel() {
        const total = (this.templates || []).length;
        const shown = (this.filteredTemplates || []).length;
        return shown === total ? total + ' templates' : shown + ' of ' + total + ' templates';
    }

    handleTemplateSort(event) {
        this.templateSortedBy = event.detail.fieldName;
        this.templateSortedDirection = event.detail.sortDirection;
    }

    get hasNoTemplates() {
        return this._samplesChecked && (this.templates || []).length === 0;
    }

    handleGoToCreate() {
        this.activeMainTab = 'new_template';
    }

    handleRefresh() {
        return refreshApex(this.wiredTemplatesResult);
    }

    handleSearch(event) {
        this.searchKey = event.detail.value;
    }

    async installSampleTemplates() {
        this.isInstallingSamples = true;
        try {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            const count = await createSampleTemplates();
            this.showToast(
                'Welcome to Portwood!',
                count + ' sample templates installed. Open any template to see how merge tags work.',
                'success'
            );
            await refreshApex(this.wiredTemplatesResult);
            this.activeMainTab = 'list';
        } catch (error) {
            const msg = error.body ? error.body.message : error.message;
            this.showToast('Error', 'Failed to create sample templates: ' + msg, 'error');
        } finally {
            this.isInstallingSamples = false;
        }
    }

    // --- A11y live region ─────────────────────────────────────
    // Page-level ARIA live announcement channel. Children dispatch a bubbling
    // CustomEvent('announce', {detail:{message}, composed:true}); we mirror
    // the message into a `slds-assistive-text` element with aria-live="polite".
    @track liveAnnouncement = '';

    handleA11yAnnounce(event) {
        const msg = event && event.detail && event.detail.message;
        if (!msg) return;
        // Re-trigger if same string is announced again. Empty briefly so the
        // SR re-reads identical messages.
        if (this.liveAnnouncement === msg) {
            this.liveAnnouncement = '';
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this.liveAnnouncement = msg;
            }, 50);
        } else {
            this.liveAnnouncement = msg;
        }
    }

    // Modal Esc-to-close handlers. Focus restoration is handled by the
    // standard browser flow when the dialog DOM unmounts; full focus trap
    // (Tab/Shift+Tab cycling) is deferred to v1.85.
    handleEditModalKeydown(event) {
        if (event.key === 'Escape') {
            event.preventDefault();
            this.handleCloseEditModal();
        }
    }
    handlePreviewModalKeydown(event) {
        if (event.key === 'Escape') {
            event.preventDefault();
            this.closePreviewModal();
        }
    }

    // --- Wizard Logic ---

    connectedCallback() {
        // Both the wizard's AI step and the designer toolbar key off this, so
        // resolve it once on mount rather than per-surface. Never awaited and
        // never throws — an org without Einstein simply keeps the copy-paste
        // path as the only visible option.
        this._refreshAgentforceAvailability();
        // #367 — the per-template Decline toggle is moot (and hidden) while the
        // org-wide switch is off. Never awaited and never throws — worst case the
        // template toggle stays hidden until the next load, it never blocks the editor.
        this._refreshOrgShowDecline();
    }

    // #367
    async _refreshOrgShowDecline() {
        try {
            const data = await getSettingsFresh();
            this.orgShowDecline = data.Signature_Show_Decline__c === true;
        } catch (_err) {
            // Leave the per-template toggle hidden if the org setting can't be read.
        }
    }

    disconnectedCallback() {
        this._cancelOverlayClear();
        if (this._selListenerAdded) {
            document.removeEventListener('selectionchange', this._onSelectionChange);
            this._selListenerAdded = false;
        }
        if (this._docMouseListenerAdded) {
            document.removeEventListener('mousedown', this._onDocMouseDown, true);
            this._docMouseListenerAdded = false;
        }
        if (this._surfaceRo) {
            try {
                this._surfaceRo.disconnect();
            } catch (e) {
                /* already gone */
            }
            this._surfaceRo = null;
            this._surfaceRoSeen = null;
        }
        // #244 — Ctrl/Cmd + wheel zoom is bound to the canvas node, not the document.
        if (this._wheelBoundPv) {
            this._wheelBoundPv.removeEventListener('wheel', this.handleCanvasWheel);
            this._wheelBoundPv.removeEventListener('mousemove', this.handleCanvasMouseMove);
            this._wheelBoundPv = null;
        }

        this._disableFloatPanelChrome();
    }

    /**
     * Yank focus and caret back from Lightning's global-search box after its
     * "/" hotkey fired while the user was typing in the visual canvas, then
     * insert the "/" they typed. See the key-trap comment in renderedCallback.
     */
    /**
     * True when Lightning's global search input currently holds focus.
     *
     * Matched several ways on purpose: the class name has changed across releases, and
     * a detector that silently stops matching turns this whole recovery back off
     * without anything failing loudly — which is how it came to be broken in the first
     * place.
     */
    _isGlobalSearchFocused() {
        try {
            const ae = document.activeElement;
            if (!ae) {
                return false;
            }
            const cls = String(ae.className || '');
            if (cls.indexOf('saInput') !== -1 || cls.indexOf('slds-lookup__search-input') !== -1) {
                return true;
            }
            if (
                ae.closest &&
                ae.closest('.forceSearchAssistantInput, .slds-global-header__item_search, one-global-search')
            ) {
                return true;
            }
            return (ae.getAttribute && ae.getAttribute('placeholder') === 'Search...') || false;
        } catch (e) {
            return false;
        }
    }

    _recoverStolenSlash() {
        // The search dialog keeps re-grabbing focus asynchronously while it
        // opens, so a single focus() call loses the race — retry until the
        // canvas HOLDS focus, inserting the "/" exactly once.
        let inserted = false;
        const attempt = (triesLeft) => {
            try {
                const host = this.template.querySelector('.dg-visual-host');
                const pv = host && host.querySelector('.dg-pv');
                if (!pv) {
                    return;
                }
                pv.focus();
                const s = window.getSelection();
                if (this._lastCanvasRange) {
                    s.removeAllRanges();
                    s.addRange(this._lastCanvasRange);
                }
                if (this._canvasFocused && !inserted) {
                    inserted = true;
                    document.execCommand('insertText', false, '/');
                    this.htmlEditorDirty = true;
                    this._maybePillifyTyped();
                    this._maybeOpenSlashMenu();
                }
                if (triesLeft > 0) {
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => {
                        if (!this._canvasFocused) {
                            attempt(triesLeft - 1);
                        }
                    }, 220);
                }
            } catch (e) {
                /* best effort */
            }
        };
        attempt(5);
    }

    /**
     * Fit tables wider than the sheet (Word-conversion twips math, extra
     * loop-tag cells) back onto the page: width 100% + table-layout fixed
     * scales the authored column widths proportionally. The inline styles
     * persist into the saved body, so the PDF is fixed too — flagged dirty
     * and announced so the author knows their document was touched.
     */
    _fitOversizeTables(pv) {
        try {
            const cs = getComputedStyle(pv);
            const contentW =
                pv.getBoundingClientRect().width -
                (parseFloat(cs.paddingLeft) || 0) -
                (parseFloat(cs.paddingRight) || 0);
            let fixed = 0;
            for (const t of pv.querySelectorAll('table')) {
                if (t.getBoundingClientRect().width > contentW + 1) {
                    t.style.width = '100%';
                    t.style.tableLayout = 'fixed';
                    t.style.maxWidth = '100%';
                    fixed++;
                }
            }
            if (fixed) {
                this.htmlEditorDirty = true;
                this.showToast(
                    'Table fit to page',
                    fixed +
                        (fixed === 1 ? ' table was' : ' tables were') +
                        ' wider than the page and got scaled to fit — column proportions kept. Save as New Version keeps the fix.',
                    'info'
                );
            }
        } catch (e) {
            /* best effort */
        }
    }

    /**
     * Word-style "click and type": place the caret exactly where the user
     * double-clicked. Inside existing content the browser range is used
     * directly; in empty space below the last block, a fresh paragraph is
     * created there so typing can start immediately.
     */
    _placeCaretAtPoint(e, pv) {
        try {
            const sel = window.getSelection();
            let range = null;
            if (document.caretRangeFromPoint) {
                range = document.caretRangeFromPoint(e.clientX, e.clientY);
            } else if (document.caretPositionFromPoint) {
                const pos = document.caretPositionFromPoint(e.clientX, e.clientY);
                if (pos) {
                    range = document.createRange();
                    range.setStart(pos.offsetNode, pos.offset);
                }
            }
            const blocks = Array.from(pv.children).filter((c) => !c.matches('style'));
            const last = blocks[blocks.length - 1];
            const belowContent = last && e.clientY > last.getBoundingClientRect().bottom + 4;
            // Empty container under the pointer (section column, table cell,
            // panel div): start a paragraph inside IT, not wherever the range
            // snapped to.
            const under = document.elementFromPoint(e.clientX, e.clientY);
            const container =
                under && pv.contains(under) && under !== pv && /^(DIV|TD|TH)$/.test(under.tagName) ? under : null;
            const rangeMissesContainer = container && (!range || !container.contains(range.startContainer));
            if (rangeMissesContainer) {
                const p = document.createElement('p');
                p.appendChild(document.createElement('br'));
                container.appendChild(p);
                range = document.createRange();
                range.setStart(p, 0);
                this.htmlEditorDirty = true;
            } else if (belowContent || !range || !pv.contains(range.startContainer)) {
                const p = document.createElement('p');
                p.appendChild(document.createElement('br'));
                pv.appendChild(p);
                range = document.createRange();
                range.setStart(p, 0);
                this.htmlEditorDirty = true;
            }
            range.collapse(true);
            sel.removeAllRanges();
            sel.addRange(range);
            pv.focus();
        } catch (err) {
            /* caret placement is best-effort */
        }
    }

    renderedCallback() {
        // Floating chrome is position: fixed in viewport coordinates, so it can only
        // be placed once the element exists and has been laid out.
        if (this.selectionBubble) {
            const bubble = this.template.querySelector('.dg-sel-bubble');
            if (bubble) {
                this._positionSelectionBubble(bubble);
            }
        }
        if (this.pillMenu && this._floatAnchor && this._floatAnchor.isConnected) {
            const pm = this.template.querySelector('.dg-pill-menu');
            if (pm) {
                this._positionFloating(this._floatAnchor, pm, { gap: 6, prefer: 'bottom', align: 'start' });
            }
        }
        // Toolbar popovers are position: fixed, so they need placing the moment they
        // open — not only when something scrolls. Without this the grid picker fell
        // back to its static position, which is why moving it out of the toolbar (to
        // escape that stacking context) needed this to land with it.
        if (this._floatAnchor && this._floatAnchor.isConnected) {
            const fm = this.template.querySelector('.dg-fmt-menu');
            if (fm) {
                this._positionFloating(this._floatAnchor, fm, { gap: 6, prefer: 'bottom', align: 'start' });
            }
        }
        // Sync native textarea DOM value with tracked property after re-render
        if (this.currentWizardStep === '2' && this.newTemplateQuery) {
            const ta = this.template.querySelector('.wizard-query-textarea');
            if (ta && ta.value !== this.newTemplateQuery) {
                ta.value = this.newTemplateQuery;
            }
        }
        if (this._editContext && this.isEditModalOpen && this.editTemplateQuery) {
            const ta = this.template.querySelector('.edit-query-textarea');
            if (ta && ta.value !== this.editTemplateQuery) {
                ta.value = this.editTemplateQuery;
            }
        }
        // Page-setup controls: LWC doesn't bind value on native <select>, so
        // mirror state into the DOM the same way the query textareas do —
        // but never clobber a control the user is currently typing in.
        for (const sel of this.template.querySelectorAll('.dg-page-select, .dg-page-input')) {
            const want = this.pageSetup[sel.dataset.field];
            if (want != null && sel.value !== want && !sel.matches(':focus')) {
                sel.value = want;
            }
        }
        // Header/Footer panel textareas: sync tracked values into the DOM
        // (LWC textareas have no value binding); skip while focused.
        if (this.activePanel === 'hf') {
            const hta = this.template.querySelector('.dg-hf-header');
            if (hta && hta !== document.activeElement && hta.value !== (this.editTemplateHeaderHtml || '')) {
                hta.value = this.editTemplateHeaderHtml || '';
            }
            const fta = this.template.querySelector('.dg-hf-footer');
            if (fta && fta !== document.activeElement && fta.value !== (this.editTemplateFooterHtml || '')) {
                fta.value = this.editTemplateFooterHtml || '';
            }
        }
        // Right-click menu just opened — cursor into its search box.
        if (this._focusCtxSearch && this.ctxMenu) {
            const ci = this.template.querySelector('.dg-ctx-search');
            if (ci) {
                ci.focus();
                this._focusCtxSearch = false;
            }
        }
        // Searchable panel just opened — put the cursor in its search box.
        if (this._focusPanelSearch) {
            const inp = this.template.querySelector('.dg-panel-search');
            if (inp) {
                inp.focus();
                this._focusPanelSearch = false;
            }
        }
        // The slash menu's search box is deliberately NOT auto-focused. Taking
        // focus the instant the menu appears would break the flow it was built
        // for — type a backtick and keep typing in the page — by yanking the
        // caret out of the document mid-sentence. The box is there for when the
        // mouse has already been used, which is precisely the case that had no
        // way to filter at all.
        // Inline HTML preview: the lwc:dom="manual" host only exists after the
        // re-render that the Preview toggle triggers, so the content write has
        // to happen here rather than in the click handler.
        if (this._pendingPreviewWrite) {
            const host = this.template.querySelector(this._pendingPreviewWrite.selector);
            if (host) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html
                host.innerHTML = this._pendingPreviewWrite.html;
                // Visual mode: the rendered page becomes the editor.
                if (this._pendingPreviewWrite.editable) {
                    const pv = host.querySelector('.dg-pv');
                    if (pv) {
                        pv.setAttribute('contenteditable', 'true');
                        pv.setAttribute('spellcheck', 'false');
                        // The editing outline moved to .dg-sheet-paper, which encloses
                        // the header band, the page AND the footer band. Here it boxed
                        // the body alone, so the running header sat visibly outside
                        // "the document" and each seam carried two competing dashed
                        // lines. Component CSS can't reach manual DOM, so the rest is
                        // still styled inline.
                        pv.style.caretColor = '#7c3aed';
                        pv.style.cursor = 'text';
                        // Merge tags render as friendly atomic pills.
                        this._pillifyTags(pv);
                        // The page's scoped <style> lives INSIDE the editable —
                        // native editing can caret next to it and delete it,
                        // which drops the white page styling ("canvas
                        // disappears"). Track it so keydown can steer the
                        // caret off it and input can put it back.
                        this._pvStyleEl = pv.querySelector('style');
                        // Drag targets: tag chips and image thumbnails drop
                        // exactly where the user points — with a live insertion
                        // marker so the drop point is never a guess.
                        // Every interaction that must behave the same on the page
                        // and in the running header/footer is wired in ONE place.
                        // Keeping two copies is what left the bands without a
                        // right-click menu, without pill double-click editing,
                        // without table handles and without toolbar state — each
                        // found and fixed separately, which is the tax this removes.
                        this._wireSurfaceInteractions(pv);
                        // Live dirty signal while typing in the page — and
                        // type-to-pill: a completed {tag} snaps into a pill.
                        pv.addEventListener('input', () => {
                            this._healCanvasStyle(pv);
                            this.htmlEditorDirty = true;
                            this._maybePillifyTyped();
                            // Notion-style: "/" at the caret opens the insert menu.
                            this._maybeOpenSlashMenu();
                        });
                        // Click a pill → its formatting menu; click elsewhere closes it.
                        // Double-click a pill → edit its tag text in place.
                        // Keep keystrokes OURS: Lightning binds "/" (and more) to
                        // global shortcuts via a capture-phase listener high in the
                        // tree, so stopping propagation at the page is too late.
                        // Trap at the window in capture phase — fires before
                        // Lightning's hotkey handler — and stop only events that
                        // originate inside the editable page. preventDefault is
                        // NOT called, so typing itself is untouched.
                        // Synthetic shadow retargets e.target for listeners
                        // outside the component, so the trap can't identify the
                        // canvas from the event — track focus from INSIDE it.
                        pv.addEventListener('focusin', () => {
                            this._canvasFocused = true;
                            // #247 — three editable surfaces now; the toolbar has to
                            // know which one it is acting on.
                            this._setActiveSurface('body');
                        });
                        pv.addEventListener('keydown', (e) => {
                            // Ctrl/Cmd+Z first: it must beat the floor guard and the
                            // slash menu, and it must preventDefault before the
                            // browser's own undo can run against the wrong history.
                            if (this._undoKeydown(e)) {
                                return;
                            }
                            // A top-left-corner click parks the caret at the
                            // canvas ROOT, before the scoped <style> — there,
                            // Space types nowhere visible and Backspace eats
                            // the style element (the white page vanishes).
                            // Steer the caret into real content BEFORE the
                            // browser's default edit runs.
                            this._normalizeRootCaret(pv);
                            this._guardCanvasFloor(e, pv);
                            // Open slash menu drives arrows/Enter/Escape.
                            if (this._slashMenuKeydown(e)) {
                                return;
                            }
                            // Tab walks the table cells (and grows the table at the
                            // end) before Enter gets a look in.
                            if (this._handleTabKey(e)) {
                                return;
                            }
                            // Enter = line break, Shift+Enter = new paragraph. After
                            // the slash menu, which owns Enter while it is open.
                            if (this._handleEnterKey(e)) {
                                e.stopPropagation();
                                return;
                            }
                            // Track typing recency for the "/" recovery below.
                            // Only content keys — Tab/arrows must not count, or
                            // tabbing away right after typing would false-match.
                            if (e.key && (e.key.length === 1 || e.key === 'Backspace' || e.key === 'Enter')) {
                                this._lastCanvasKeyTs = Date.now();
                            }
                            // Tracked so the focusout recovery can tell "Lightning stole
                            // this" from "the user tabbed out on purpose".
                            this._lastCanvasKey = e.key;
                            e.stopPropagation();
                        });
                        // Lightning's "/" global-search hotkey preempts us
                        // completely: its window-capture handler runs first,
                        // preventDefaults, stops propagation (the canvas never
                        // sees the keydown), and focuses the search box. LWS
                        // never delivers window-capture listeners to component
                        // code, so the ONLY reliable signal is the SYMPTOM: a
                        // focusout to the search input (saInput) while the user
                        // was mid-typing with no mouse involved. On that
                        // signature, steal focus back, restore the caret, and
                        // type the "/" the user actually pressed.
                        pv.addEventListener('focusout', () => {
                            this._canvasFocused = false;
                            this._canvasBlurTs = Date.now();
                            // Do NOT gate on "typed recently".
                            //
                            // The original condition required a keystroke within 1500ms,
                            // but the stolen key never reaches this component — Lightning
                            // consumes it at window capture — so it does not update
                            // _lastCanvasKeyTs. Press "/" as the FIRST key after clicking
                            // into the canvas and the timestamp is still unset, the guard
                            // reads false, and the recovery never runs. That is the common
                            // path, not an edge case.
                            //
                            // Losing focus straight from the canvas to global search with
                            // no mouse involved is already the signature; the mouse check
                            // is what separates theft from someone deliberately clicking
                            // into search, and Tab is excluded because that is a legitimate
                            // way to leave the canvas by keyboard.
                            const mousedRecently = this._lastDocMouseTs && Date.now() - this._lastDocMouseTs < 150;
                            const leftByTab = this._lastCanvasKey === 'Tab';
                            if (mousedRecently || leftByTab) {
                                return;
                            }
                            // Ask document.activeElement, NOT event.relatedTarget.
                            //
                            // relatedTarget is null on focusout whenever focus lands in a
                            // different tree — which is precisely this case, since global
                            // search lives outside our shadow root. So the old
                            // `rt.className.indexOf('saInput')` test was false EVERY time
                            // and the recovery below never once ran. The search input is in
                            // the document's light DOM, so activeElement resolves to it
                            // properly; it just has to be read after the focus settles.
                            // eslint-disable-next-line @lwc/lwc/no-async-operation
                            setTimeout(() => {
                                if (this._isGlobalSearchFocused()) {
                                    this._recoverStolenSlash();
                                }
                            }, 60);
                        });
                        // Distinguishes hotkey focus-theft from a deliberate
                        // click into global search (document listeners DO fire
                        // for component code — see _onSelectionChange).
                        if (!this._docMouseListenerAdded) {
                            this._onDocMouseDown = () => {
                                this._lastDocMouseTs = Date.now();
                            };
                            document.addEventListener('mousedown', this._onDocMouseDown, true);
                            this._docMouseListenerAdded = true;
                        }
                        // PREVENT the theft where we can, rather than only recovering.
                        //
                        // Document-capture listeners DO reach component code (the mousedown
                        // above proves it); it is window-capture that LWS withholds. So this
                        // wins outright whenever Lightning's hotkey is bound at document
                        // level or registered after ours, and costs nothing when it is not —
                        // the focusout recovery still catches that case. Scoped hard: only a
                        // bare "/" with no modifiers, and only while the canvas actually has
                        // focus, so it can never swallow a slash the user typed elsewhere.
                        if (!this._docKeyListenerAdded) {
                            this._onDocKeyDown = (e) => {
                                if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey) {
                                    return;
                                }
                                if (!this._canvasFocused) {
                                    return;
                                }
                                e.preventDefault();
                                e.stopImmediatePropagation();
                                try {
                                    document.execCommand('insertText', false, '/');
                                    this.htmlEditorDirty = true;
                                    this._maybePillifyTyped();
                                    this._maybeOpenSlashMenu();
                                } catch (err) {
                                    /* if the insert fails the recovery path still applies */
                                }
                            };
                            document.addEventListener('keydown', this._onDocKeyDown, true);
                            this._docKeyListenerAdded = true;
                        }
                        // Land ready-to-type: focus the page with the caret at
                        // the first text block so the cursor is never a hunt.
                        try {
                            pv.focus();
                            const first = pv.querySelector('p, h1, h2, h3, li, td');
                            if (first) {
                                const r = document.createRange();
                                r.selectNodeContents(first);
                                r.collapse(true);
                                const s = window.getSelection();
                                s.removeAllRanges();
                                s.addRange(r);
                            }
                        } catch (e) {
                            /* focus best-effort */
                        }
                        // Sheet dimensions follow the page setup.
                        this._applyCanvasDimensions();
                        // WYSIWYG watermark: show the template's background
                        // image on the sheet, faded, behind the content.
                        if (this.watermarkPreviewUrl) {
                            // Light veil only — uploaded watermarks already carry
                            // their baked opacity, so the canvas should match the PDF.
                            pv.style.backgroundImage =
                                'linear-gradient(rgba(255,255,255,0.25), rgba(255,255,255,0.25)), url(' +
                                this.watermarkPreviewUrl +
                                ')';
                            pv.style.backgroundSize = 'cover';
                            pv.style.backgroundPosition = 'center';
                            pv.style.backgroundRepeat = 'no-repeat';
                        } else {
                            pv.style.backgroundImage = '';
                        }
                        // Word-converted tables with absolute widths can't be
                        // tamed by max-width alone (auto layout won't shrink
                        // below min-content) — refit them onto the sheet.
                        this._fitOversizeTables(pv);
                        // Clean page breaks: rows never split mid-cell in PDF.
                        for (const tr of pv.querySelectorAll('tr')) {
                            if (!tr.style.pageBreakInside) {
                                tr.style.pageBreakInside = 'avoid';
                            }
                        }
                        // Context label ("Editing: Table cell") follows the caret.
                        if (!this._selListenerAdded) {
                            document.addEventListener('selectionchange', this._onSelectionChange);
                            this._selListenerAdded = true;
                        }
                        // #244 — the canvas is rewritten on every re-render, so the
                        // zoom transform has to be re-applied to the new node.
                        this._applyZoom();
                        // The canvas element itself is replaced on every re-render, so
                        // track WHICH node the wheel handler is bound to rather than a
                        // boolean — a plain flag would leave it attached to a detached
                        // node and Ctrl+scroll would stop working after the first
                        // re-render.
                        if (this._wheelBoundPv !== pv) {
                            if (this._wheelBoundPv) {
                                this._wheelBoundPv.removeEventListener('wheel', this.handleCanvasWheel);
                            }
                            pv.addEventListener('wheel', this.handleCanvasWheel, { passive: false });
                            this._wheelBoundPv = pv;
                        }
                        // #241 — the table-handle mousemove moved into
                        // _wireSurfaceInteractions so the bands get it too; binding it
                        // here as well would run the overlay twice per pointer move.
                        // Snapshot AFTER pillify so "unchanged" compares
                        // like-for-like on exit.
                        // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                        this._visualEnteredDom = pv.innerHTML;
                        // #247 — running header/footer are editable bands on the page.
                        this._mountChromeBands();
                    }
                }
                this._pendingPreviewWrite = null;
            }
        }
    }

    get isStep1() {
        return this.currentWizardStep === '1';
    }
    get isStep2() {
        return this.currentWizardStep === '2';
    }
    get isStep3() {
        return this.currentWizardStep === '3';
    }
    /** Dedicated AI step: prompt + assets + paste-back, no query builder. */
    get isStepAi() {
        return this.currentWizardStep === 'ai';
    }
    get isStepAiOrLater() {
        return this.currentWizardStep !== '1';
    }
    get hideWizardFooterNext() {
        if (this.currentWizardStep === '3' || this.currentWizardStep === 'ai') {
            return true;
        }
        // One place to move forward: on Step 1 the starter/AI paths advance
        // ONLY via their in-card button; the footer Next belongs to the file
        // path. Query refinement lives in the template's Query Configuration
        // tab after creation, not in a parallel wizard branch.
        return this.currentWizardStep === '1' && !this.isAuthoringFile;
    }

    // --- Step-1 declutter: starter/AI paths hide power-user fields ---
    get showStep1AdvancedFields() {
        return this.isAuthoringFile || this.showAdvancedOptions;
    }
    /** Starters bring their own object+query — hide the picker on that path. */
    get showBaseObjectField() {
        return this.isRecordDataSource && (!this.isAuthoringStarter || this.showAdvancedOptions);
    }
    get showAdvancedToggle() {
        return !this.isAuthoringFile;
    }
    get advancedToggleLabel() {
        return this.showAdvancedOptions
            ? 'Hide advanced options'
            : 'Advanced options (API name, category, data source)';
    }
    handleToggleAdvanced() {
        this.showAdvancedOptions = !this.showAdvancedOptions;
    }
    get isBackDisabled() {
        return this.currentWizardStep === '1';
    }
    /** Progress ring value — the AI screen maps to the "Pick Your Data" slot. */
    get wizardProgressStep() {
        return this.currentWizardStep === 'ai' ? '2' : this.currentWizardStep;
    }

    async handleNextStep() {
        if (this.currentWizardStep === '1') {
            if (!this.newTemplateName || !this.newTemplateType) {
                this.showToast('Error', 'Please fill in the template name and type.', 'error');
                return;
            }
            // AI path: skip the query builder entirely. Auto-build a sensible
            // query for the prompt, load shared assets it can reference, and
            // land on the prompt + paste screen.
            if (this.isAuthoringAi && this.dataSourceMode === 'record') {
                if (!this.newTemplateObject) {
                    this.showToast('Pick an object', 'Choose the Base Object this document is about.', 'error');
                    return;
                }
                this.isAutoCreating = true;
                try {
                    if (!(this.newTemplateQuery || '').trim()) {
                        this.newTemplateQuery = await this._buildDefaultQueryConfig(this.newTemplateObject);
                    }
                    await this._loadWizardAssets();
                } finally {
                    this.isAutoCreating = false;
                }
                this._loadWizardQueryMeta();
                this.currentWizardStep = 'ai';
                return;
            }
            if (this.isAuthoringAi && this.dataSourceMode === 'flow') {
                await this._loadWizardAssets();
                this.currentWizardStep = 'ai';
                return;
            }
            // JSON Data (from Flow) data source: no SOQL, no provider class.
            // Skip Step 2 entirely — there's nothing to configure between name
            // and template upload. The FlowJsonData sentinel and v4 marker were
            // stamped at handleDataSourceModeChange time; just advance to upload.
            if (this.dataSourceMode === 'flow') {
                this.useApexProvider = false;
                this.useVisualBuilder = false;
                this.currentWizardStep = '3';
                return;
            }
            // Apex Data Provider data source bypasses the base-object requirement —
            // the provider class supplies its own data shape. We require a class to
            // be selected and validated before advancing, and stamp the v4 config
            // so Step 2 lands directly on the connected-provider view.
            if (this.dataSourceMode === 'apex') {
                if (!this.selectedProviderClassName || !this.hasProviderFields) {
                    this.showToast('Error', 'Please select an Apex Data Provider class first.', 'error');
                    return;
                }
                // Base_Object_API__c is non-nullable downstream. If the user supplied
                // an SObject API name (cross-object aggregation: provider returns data
                // about a specific record type), use it; otherwise fall back to the
                // 'ApexProvider' sentinel that docGenColumnBuilder also emits.
                const apexBase = (this.apexProviderBaseObject || '').trim();
                this.newTemplateObject = apexBase || 'ApexProvider';
                this.useApexProvider = true;
                this.useVisualBuilder = false;
                this.newTemplateQuery = JSON.stringify({ v: 4, provider: this.selectedProviderClassName });
                this.currentWizardStep = '2';
                return;
            }
            if (!this.newTemplateObject) {
                this.showToast('Error', 'Please select a base object.', 'error');
                return;
            }
            // Salesforce Record path — load metadata for step 2 before transitioning.
            this.useApexProvider = false;
            this._loadObjectMetadata(this.newTemplateObject);
            this.currentWizardStep = '2';
        } else if (this.currentWizardStep === '2') {
            // Clean up trailing commas/whitespace
            let q = (this.newTemplateQuery || '').replace(/[\s,]+$/, '').replace(/^[\s,]+/, '');
            this.newTemplateQuery = q;
            const ta = this.template.querySelector('.wizard-query-textarea');
            if (ta) {
                ta.value = q;
            }

            if (!q) {
                this.showToast('Error', 'Please add at least one field to the query.', 'error');
                return;
            }
            this.currentWizardStep = '3';
        }
    }

    handlePrevStep() {
        if (this.currentWizardStep === 'ai') {
            this.currentWizardStep = '1';
        } else if (this.currentWizardStep === '3') {
            // JSON-flow templates skip Step 2 going forward; mirror that going back
            // so the user lands on Step 1 (where they can re-pick the data source).
            this.currentWizardStep = this.dataSourceMode === 'flow' ? '1' : '2';
        } else if (this.currentWizardStep === '2') {
            this.currentWizardStep = '1';
        }
    }

    /** Shared image assets: the ONE image pipeline — wizard logo picker,
     *  designer asset panel, slash menu, and the AI prompt all read this. */
    async _loadWizardAssets() {
        try {
            const assets = (await getAssets()) || [];
            this.wizardAssets = assets.map((a) => ({
                id: a.id,
                name: a.name,
                assetKey: a.assetKey,
                mergeTag: a.mergeTag || '{%asset:' + a.assetKey + '}',
                previewUrl: a.latestVersionCvId ? '/sfc/servlet.shepherd/version/download/' + a.latestVersionCvId : null
            }));
            this._assetUrlByKey = {};
            for (const a of this.wizardAssets) {
                if (a.previewUrl) {
                    this._assetUrlByKey[(a.assetKey || '').toLowerCase()] = a.previewUrl;
                }
            }
            this._imagifyAssetPills();
        } catch (e) {
            this.wizardAssets = [];
        }
    }

    get hasWizardAssets() {
        return (this.wizardAssets || []).length > 0;
    }

    /** Paste step is "3" after the assets step, "2" when there are no assets yet. */
    get aiPasteStepNum() {
        return this.hasWizardAssets ? '3' : '2';
    }

    get aiAssetRows() {
        const sel = this.aiSelectedAssetIds;
        return (this.wizardAssets || []).map((a) => ({
            ...a,
            selected: sel === null ? true : sel.includes(a.id)
        }));
    }

    handleAiAssetToggle(event) {
        const id = event.currentTarget.dataset.id;
        const current =
            this.aiSelectedAssetIds === null
                ? (this.wizardAssets || []).map((a) => a.id)
                : [...this.aiSelectedAssetIds];
        const idx = current.indexOf(id);
        if (idx > -1) {
            current.splice(idx, 1);
        } else {
            current.push(id);
        }
        this.aiSelectedAssetIds = current;
    }

    handleAssetTagCopy(event) {
        const tag = event.currentTarget.dataset.tag;
        if (tag) {
            this._copyToClipboard(tag, tag + ' copied — the AI prompt already lists it too.');
        }
    }

    handleAiPasteChange(event) {
        this._aiPastedHtml = event.target.value;
    }

    /** AI step finale: create the template with the pasted HTML staged as its body. */
    async handleAiCreateFromPaste() {
        const ta = this.template.querySelector('.dg-ai-paste');
        if (ta) {
            this._aiPastedHtml = ta.value;
        }
        this.isAutoCreating = true;
        try {
            await this.createTemplate();
        } finally {
            this.isAutoCreating = false;
        }
    }

    handleWizardTabActive() {
        this.activeMainTab = 'new_template';
        this.resetForm();
        // Existing shared assets feed the logo picker and the AI prompt.
        this._loadWizardAssets();
    }

    handleTabActive(event) {
        this.activeMainTab = event.target.value;
    }

    // --- Create Handlers ---
    handleNameChange(event) {
        this.newTemplateName = event.detail.value;
        if (!this._newApiNameEdited) {
            this.newTemplateApiName = this._deriveApiName(this.newTemplateName);
        }
    }
    handleNewApiNameChange(event) {
        this.newTemplateApiName = (event.detail.value || '').trim();
        // Clearing the field hands control back to auto-derive.
        this._newApiNameEdited = this.newTemplateApiName !== '';
    }
    /** Name → stable key: letters/digits/underscores, no leading digit, max 80. */
    _deriveApiName(name) {
        return (name || '')
            .replace(/[^a-zA-Z0-9]+/g, '_')
            .replace(/^[_0-9]+/, '')
            .replace(/_+$/, '')
            .slice(0, 80);
    }
    handleCategoryChange(event) {
        this.newTemplateCategory = event.detail.value;
    }
    handleTypeChange(event) {
        this.newTemplateType = event.detail.value;
        // Excel only supports Native output — auto-switch from PDF
        if (event.detail.value === 'Excel' && this.newTemplateOutputFormat === 'PDF') {
            this.newTemplateOutputFormat = 'Native';
        }
        if (event.detail.value === 'HTML' || event.detail.value === 'PDF') {
            this.newTemplateOutputFormat = 'PDF';
        }
    }

    // --- HTML-first authoring path ---
    get isAuthoringStarter() {
        return this.newAuthoringMode === 'starter';
    }
    get isAuthoringAi() {
        return this.newAuthoringMode === 'ai';
    }
    get isAuthoringFile() {
        return this.newAuthoringMode === 'file';
    }
    get isAuthoringScratch() {
        return this.newAuthoringMode === 'scratch';
    }
    get isAuthoringCanvas() {
        return this.newAuthoringMode === 'canvas';
    }

    /**
     * Two ways in: bring a document, or draw one.
     *
     * Starters are gone. Every one was a layout somebody still had to understand and
     * then edit, and a wizard that asks which of five designs you want before you have
     * seen the editor is asking a question too early. A blank canvas is a shorter path
     * to the same place, and the editor is now good enough to make it the honest one.
     *
     * 'starter', 'scratch' (the legacy blank designer) and 'ai' (Agentforce) are
     * deliberately absent rather than deleted, so a template already created any of
     * those ways still opens normally. They are simply not somewhere the wizard sends
     * anyone.
     */
    get authoringCards() {
        const defs = [
            {
                mode: 'file',
                title: 'Bring an Existing Template',
                badge: null,
                icon: 'utility:upload',
                desc: 'Upload a Word, PowerPoint, Excel, fillable PDF, or HTML file you already maintain. Each keeps its own format — Word generates .docx, Excel .xlsx, PowerPoint .pptx. An HTML file can also be imported onto a canvas from the editor.'
            },
            {
                mode: 'canvas',
                title: 'Start from a Blank Canvas',
                // Beta, and said out loud. Subscribers should know which parts of the
                // product are still moving before they build on them.
                badge: 'Beta',
                icon: 'utility:layout',
                desc: 'An empty artboard. Drop text, tables, images, shapes, codes and signature blocks exactly where you want them and they land there in the PDF, to the inch. Lists still flow onto as many pages as the data needs.'
            }
        ];
        return defs.map((d) => ({
            ...d,
            selected: this.newAuthoringMode === d.mode,
            cardClass:
                this.newAuthoringMode === d.mode ? 'dg-authoring-card dg-authoring-card_selected' : 'dg-authoring-card'
        }));
    }

    get starterCards() {
        return STARTERS.map((s) => ({
            ...s,
            targetObject: STARTER_OBJECTS[s.key] || 'Account',
            selected: this.newStarterKey === s.key,
            cardClass: this.newStarterKey === s.key ? 'dg-starter-card dg-starter-card_selected' : 'dg-starter-card'
        }));
    }

    get selectedStarterLabel() {
        const s = STARTERS.find((x) => x.key === this.newStarterKey);
        return s ? s.label : '';
    }

    handleAuthoringModeSelect(event) {
        const mode = event.currentTarget.dataset.mode;
        if (!mode || mode === this.newAuthoringMode) {
            return;
        }
        this.newAuthoringMode = mode;
        if (mode === 'canvas') {
            // Canvas is its own template TYPE, not an HTML template authored
            // differently — the editor, the stored body shape and the round-trip all
            // differ. It still RENDERS through the HTML path (DocGenService.isHtmlBacked).
            this.newTemplateType = 'Canvas';
            this.newTemplateOutputFormat = 'PDF';
        } else if (mode === 'starter') {
            // Starters are converted to canvas documents on the way in, so the author
            // lands in the editor they will keep using rather than in an HTML body they
            // would have to migrate later.
            this.newTemplateType = 'Canvas';
            this.newTemplateOutputFormat = 'PDF';
        } else if (mode === 'ai' || mode === 'scratch') {
            this.newTemplateType = 'HTML';
            this.newTemplateOutputFormat = 'PDF';
        } else {
            this.newTemplateType = 'Word';
            this.newTemplateOutputFormat = 'PDF';
        }
    }

    handleAuthoringModeKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleAuthoringModeSelect(event);
        }
    }

    handleStarterSelect(event) {
        this.newStarterKey = event.currentTarget.dataset.key;
        // Predesigned templates carry their natural object — no object picker
        // on this path (Advanced options exposes it for power users).
        if (!this.showAdvancedOptions) {
            const obj = STARTER_OBJECTS[this.newStarterKey] || 'Account';
            if (obj !== this.newTemplateObject) {
                this.newTemplateObject = obj;
                this.newTemplateQuery = '';
                this.newTemplateSampleRecordId = null;
            }
        }
        // Starters that declare a page setup (the landscape certificate) flip
        // the wizard's page pickers so the record, the pickers, and the body's
        // @page all agree from the first click.
        const s = STARTERS.find((x) => x.key === this.newStarterKey);
        if (s && s.page) {
            this.newTemplatePageOrientation = s.page.orientation || 'Portrait';
            this.newTemplatePageSize = s.page.size || 'Letter';
            this.newTemplatePageMargins = s.page.margins || 'Default';
        }
    }

    /** Logo control: pick from the shared asset library — the one image
     *  pipeline. New images are added under the Assets tab. */
    get logoChoiceOptions() {
        const opts = [{ label: 'No logo', value: 'none' }];
        for (const a of this.wizardAssets || []) {
            opts.push({ label: a.name + ' — ' + a.mergeTag, value: a.id });
        }
        return opts;
    }

    get hasNoAssetsYet() {
        return !(this.wizardAssets || []).length;
    }

    /** Thumbnail of the chosen logo asset, shown under the picker. */
    get selectedLogoPreviewUrl() {
        const a = (this.wizardAssets || []).find((x) => x.id === this.newTemplateLogoChoice);
        return a ? a.previewUrl : null;
    }

    handleLogoChoiceChange(event) {
        this.newTemplateLogoChoice = event.detail.value;
    }

    /** Merge tag the starter's logo slots should carry, per the user's choice. */
    get _chosenLogoTag() {
        const choice = this.newTemplateLogoChoice;
        if (choice && choice !== 'none' && choice !== 'upload') {
            const a = (this.wizardAssets || []).find((x) => x.id === choice);
            if (a) {
                return a.mergeTag;
            }
        }
        return '{%asset:logo}';
    }

    handleLogoSelected(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) {
            return;
        }
        if (!/\.(png|jpe?g)$/i.test(file.name)) {
            this.showToast('Unsupported logo', 'Use a .png or .jpg image.', 'error');
            event.target.value = '';
            return;
        }
        this._logoFile = file;
        this.newTemplateLogoName = file.name;
    }

    /**
     * The fluid path: name it, pick a design, click once. A sensible Query
     * Config is auto-built from the object's describe (top fields + up to
     * two child relationships), the template is created, the starter body
     * attached, and the designer opens on the finished document.
     */
    async handleCreateAndDesign() {
        if (!this.newTemplateName) {
            this.showToast('Name it first', 'Give the template a name, then create.', 'error');
            return;
        }
        if (this.dataSourceMode === 'record' && !this.newTemplateObject) {
            this.showToast('Pick an object', 'Choose the Base Object this document is about.', 'error');
            return;
        }
        this.isAutoCreating = true;
        try {
            // Predesigned path with the object picker hidden: the starter's
            // natural object drives the auto-built query.
            if (this.isAuthoringStarter && !this.showAdvancedOptions) {
                this.newTemplateObject = STARTER_OBJECTS[this.newStarterKey] || 'Account';
            }
            if (this.dataSourceMode === 'record' && !(this.newTemplateQuery || '').trim()) {
                // Scratch builds get the RICH query — the author picks fields
                // from the palette, so all usable fields must be available.
                // Canvas gets the RICH query for the same reason Scratch does: the
                // author picks fields from a palette rather than writing a query, so a
                // six-field default leaves them with almost nothing to drop onto the
                // artboard.
                this.newTemplateQuery = await this._buildDefaultQueryConfig(
                    this.newTemplateObject,
                    this.isAuthoringScratch || this.isAuthoringCanvas
                );
            }
            await this.createTemplate();
        } finally {
            this.isAutoCreating = false;
        }
    }

    /** Sensible default query from the object's describe — refinable later.
     *  rich=true (Start From Scratch): pull EVERY usable field (capped at 40)
     *  and more relationships, so the tag palette isn't a six-field diet. */
    async _buildDefaultQueryConfig(objectApiName, rich) {
        try {
            const [fields, rels] = await Promise.all([
                getObjectFields({ objectName: objectApiName }),
                getChildRelationships({ objectName: objectApiName })
            ]);
            const names = (fields || []).map((f) => f.value);
            const typeOf = {};
            (fields || []).forEach((f) => {
                typeOf[f.value] = f.type;
            });
            const fieldCap = rich ? 40 : 6;
            const PREF = [
                'Name',
                'Industry',
                'Phone',
                'Email',
                'Website',
                'Amount',
                'StageName',
                'CloseDate',
                'Status',
                'Title',
                'Type',
                'Description'
            ];
            const GOOD =
                /^(STRING|CURRENCY|DOUBLE|INTEGER|PERCENT|DATE|DATETIME|EMAIL|PHONE|URL|PICKLIST|TEXTAREA|BOOLEAN)$/;
            const SKIP =
                /^(Id|OwnerId|CreatedById|LastModifiedById|SystemModstamp|IsDeleted|CurrencyIsoCode|Jigsaw.*|CleanStatus|PhotoUrl)$/;
            const chosen = [];
            for (const p of PREF) {
                if (chosen.length < fieldCap && names.includes(p)) {
                    chosen.push(p);
                }
            }
            for (const f of names) {
                if (chosen.length >= fieldCap) {
                    break;
                }
                if (!chosen.includes(f) && !SKIP.test(f) && !f.endsWith('Id') && GOOD.test(typeOf[f] || '')) {
                    chosen.push(f);
                }
            }
            if (!chosen.length) {
                chosen.push('Name');
            }
            const parts = [chosen.join(', ')];
            const RELPREF = ['Contacts', 'Opportunities', 'OpportunityLineItems', 'OrderItems', 'Cases', 'Assets'];
            const NOISE =
                /Histories|Feeds|Shares|Teams|ContentDocumentLinks|ProcessInstances|ActivityHistories|Emails|Events|Tasks|Notes|Attachments|DuplicateRecord|RecordAction|TopicAssign|Vote/i;
            const picked = [];
            const relCap = rich ? 4 : 2;
            const childCap = rich ? 8 : 4;
            for (const rp of RELPREF) {
                const r = (rels || []).find((x) => x.value === rp);
                if (r && picked.length < relCap) {
                    picked.push(r);
                }
            }
            if (rich) {
                for (const r of rels || []) {
                    if (picked.length >= relCap) {
                        break;
                    }
                    if (!picked.includes(r) && !NOISE.test(r.value)) {
                        picked.push(r);
                    }
                }
            }
            if (!picked.length && rels && rels.length) {
                const r = rels.find((x) => !NOISE.test(x.value));
                if (r) {
                    picked.push(r);
                }
            }
            for (const r of picked) {
                try {
                    const cf = await getObjectFields({ objectName: r.childObjectApiName });
                    const cnames = (cf || []).map((f) => f.value);
                    const ctypeOf = {};
                    (cf || []).forEach((f) => {
                        ctypeOf[f.value] = f.type;
                    });
                    const cchosen = [];
                    for (const p of [
                        'Name',
                        'FirstName',
                        'LastName',
                        'Email',
                        'Title',
                        'StageName',
                        'Amount',
                        'CloseDate',
                        'Quantity',
                        'UnitPrice',
                        'TotalPrice',
                        'Subject',
                        'Status'
                    ]) {
                        if (cchosen.length < childCap && cnames.includes(p)) {
                            cchosen.push(p);
                        }
                    }
                    if (rich) {
                        for (const f of cnames) {
                            if (cchosen.length >= childCap) {
                                break;
                            }
                            if (
                                !cchosen.includes(f) &&
                                !SKIP.test(f) &&
                                !f.endsWith('Id') &&
                                GOOD.test(ctypeOf[f] || '')
                            ) {
                                cchosen.push(f);
                            }
                        }
                    }
                    if (cchosen.length) {
                        parts.push('(SELECT ' + cchosen.join(', ') + ' FROM ' + r.value + ')');
                    }
                } catch (e) {
                    /* skip relationship */
                }
            }
            return parts.join(', ');
        } catch (e) {
            return 'Name';
        }
    }

    /** Wizard logo → the shared {%asset:logo} asset every template can use. */
    async _ensureLogoAsset(templateId) {
        if (!this._logoFile) {
            return;
        }
        try {
            const buffer = await this._logoFile.arrayBuffer();
            const cvRes = await saveHtmlTemplateImage({
                templateId,
                fileName: this._logoFile.name,
                base64Content: bytesToBase64(new Uint8Array(buffer))
            });
            const assets = (await getAssets()) || [];
            let logo = assets.find((a) => a.assetKey === 'logo');
            if (!logo) {
                logo = await createAsset({ name: 'Company Logo', assetKey: 'logo' });
            }
            await addAssetVersion({ assetId: logo.id, contentVersionId: cvRes.contentVersionId });
            this.showToast(
                'Logo saved',
                'Stored as the shared asset {%asset:logo} — your starter header uses it, and every future template can too.',
                'success'
            );
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Logo not saved', msg + ' — you can add it later under Assets.', 'warning');
        } finally {
            this._logoFile = null;
            this.newTemplateLogoName = '';
        }
    }

    /** Word→HTML conversion expectation-setting, shown under the Type picker. */
    get showWordConversionNote() {
        return this.isAuthoringFile && this.newTemplateType === 'Word';
    }

    /** v1.90 HTML @page note only applies when the user brings their own HTML file. */
    get showHtmlPageRuleNote() {
        return this.isCreatingHtmlPdf && this.isAuthoringFile;
    }

    get aiAuthoringPrompt() {
        const shape = extractQueryShape(this.newTemplateQuery, this.newTemplateObject);
        const sel = this.aiSelectedAssetIds;
        const assets = sel === null ? this.wizardAssets : (this.wizardAssets || []).filter((a) => sel.includes(a.id));
        return buildAiPrompt(shape, {
            dataSourceMode: this.dataSourceMode,
            providerFields: (this.providerFields || []).map((f) => f.name || f),
            assets,
            docDescription: this.aiDocDescription,
            // #248 — field types let the model pick its own format suffixes
            // ({Amount:currency}, {CloseDate:MMMM d, yyyy}) instead of emitting bare
            // tags the author then has to fix by hand.
            fieldTypes: this._buildFieldTypeMap(this.wizardQueryMeta)
        });
    }

    get editAiPrompt() {
        const shape = extractQueryShape(this.editTemplateQuery, this.editTemplateObject);
        return buildAiPrompt(shape, {
            dataSourceMode: this.editTemplateObject === 'FlowJsonData' ? 'flow' : 'record',
            providerFields: (this.providerFields || []).map((f) => f.name || f),
            fieldTypes: this._buildFieldTypeMap(this.designerQueryMeta)
        });
    }

    /**
     * #248 — flatten the already-loaded describe metadata into
     * { 'Amount': 'CURRENCY', 'Account.Name': 'STRING', 'Lines.Quantity': 'DOUBLE' }.
     *
     * The wizard's query-builder step has fetched all of this already
     * (getObjectFields returns label/value/type), so this costs no extra round trips.
     * Returns {} when metadata has not loaded — buildAiPrompt degrades to the untyped
     * listing rather than blocking.
     */
    _buildFieldTypeMap(meta) {
        const out = {};
        if (!meta) {
            return out;
        }
        const add = (prefix, list) => {
            for (const f of list || []) {
                if (f && f.value && f.type) {
                    out[prefix + f.value] = f.type;
                }
            }
        };
        add('', meta.fields);
        for (const rel of Object.keys(meta.childFieldsByRel || {})) {
            add(rel + '.', meta.childFieldsByRel[rel]);
        }
        for (const rel of Object.keys(meta.parentFieldsByRel || {})) {
            add(rel + '.', meta.parentFieldsByRel[rel]);
        }
        return out;
    }

    // --- AI-step field checklist (build your query before the prompt) ---
    async _loadWizardQueryMeta() {
        if (this._wizardQueryMetaFor === this.newTemplateObject + '|' + this.newTemplateQuery) {
            return;
        }
        try {
            const [fields, rels, parentRels] = await Promise.all([
                getObjectFields({ objectName: this.newTemplateObject }),
                getChildRelationships({ objectName: this.newTemplateObject }),
                getParentRelationships({ objectName: this.newTemplateObject })
            ]);
            const childFieldsByRel = {};
            const shape = extractQueryShape(this.newTemplateQuery, this.newTemplateObject);
            const { parentFieldsByRel, parentRelsByPath } = await this._prefetchParentMeta(shape, parentRels);
            await Promise.all(
                (shape.children || []).map(async (c) => {
                    const rel = (rels || []).find((r) => r.value === c.relationshipName);
                    if (rel) {
                        try {
                            childFieldsByRel[c.relationshipName] = await getObjectFields({
                                objectName: rel.childObjectApiName
                            });
                        } catch (e) {
                            /* skip */
                        }
                    }
                })
            );
            this._wizardQueryMetaFor = this.newTemplateObject + '|' + this.newTemplateQuery;
            this.wizardQueryMeta = {
                fields: fields || [],
                rels: rels || [],
                parentRels: parentRels || [],
                childFieldsByRel,
                parentFieldsByRel,
                parentRelsByPath
            };
        } catch (e) {
            this.wizardQueryMeta = null;
        }
    }

    get aiQuerySections() {
        return this._buildQuerySections(
            this.newTemplateQuery,
            this.newTemplateObject,
            this.wizardQueryMeta,
            this.aiFieldSearch
        );
    }

    get aiQueryFieldCount() {
        const shape = extractQueryShape(this.newTemplateQuery, this.newTemplateObject);
        let n = (shape.baseFields || []).length + (shape.parentFields || []).length;
        for (const c of shape.children || []) {
            n += (c.fields || []).length;
        }
        return n;
    }

    handleAiDescChange(event) {
        this.aiDocDescription = event.target.value || '';
    }

    handleAiFieldSearch(event) {
        this.aiFieldSearch = event.target.value || '';
    }

    async handleAiQueryFieldToggle(event) {
        const res = await this._applyQueryToggle(
            this.newTemplateQuery,
            this.newTemplateObject,
            this.wizardQueryMeta,
            event.currentTarget.dataset,
            event.currentTarget.checked
        );
        if (res.childFields) {
            this.wizardQueryMeta = {
                ...this.wizardQueryMeta,
                childFieldsByRel: { ...this.wizardQueryMeta.childFieldsByRel, [res.rel]: res.childFields }
            };
        }
        if (res.parentFields) {
            this.wizardQueryMeta = {
                ...this.wizardQueryMeta,
                parentFieldsByRel: { ...(this.wizardQueryMeta.parentFieldsByRel || {}), [res.rel]: res.parentFields },
                parentRelsByPath: {
                    ...(this.wizardQueryMeta.parentRelsByPath || {}),
                    [res.rel]: res.parentRelsForPath || []
                }
            };
        }
        this.newTemplateQuery = res.query;
    }

    handleCopyAiPrompt() {
        this._copyToClipboard(this.aiAuthoringPrompt, 'AI prompt copied — paste it into your AI assistant.');
    }

    handleCopyEditAiPrompt() {
        this._copyToClipboard(this.editAiPrompt, 'AI prompt copied — paste it into your AI assistant.');
    }

    // -----------------------------------------------------------------------
    // Generate with Agentforce
    //
    // Closes the loop that Copy AI Prompt opens: the SAME prompt goes to
    // Salesforce AI in this org, the result is stripped of everything the PDF
    // engine ignores, and the cleaned body lands in the canvas. The button is
    // hidden — not disabled — when the org has no entitlement, so the existing
    // copy-paste path stays the visible answer rather than a dead end.
    // -----------------------------------------------------------------------

    get showAgentforceButton() {
        return this.isAgentforceAvailable && !!this.editTemplateId;
    }

    get agentforceBtnLabel() {
        return this.isAgentforceGenerating ? 'Generating…' : 'Generate with Agentforce';
    }

    get hasAgentforceReport() {
        return this.agentforceFindings && this.agentforceFindings.length > 0;
    }

    /**
     * Whatever is on the canvas right now, unsaved edits included.
     *
     * Delegates to _currentDraftHtml() — the same reader the PDF preview and
     * the save path use — rather than hand-rolling one. An earlier version of
     * this getter called _extractVisualBody() with no argument (it requires the
     * .dg-pv element), threw, was swallowed by a catch, and silently returned
     * ''. That sent Agentforce an "edit this" instruction with no template
     * attached, and the model replied "I do not know. Please specify the exact
     * change you want made to the template." Reuse the real reader.
     */
    get _currentDesignerBody() {
        try {
            const draft = this._currentDraftHtml();
            if (draft && draft.trim()) {
                return draft;
            }
        } catch (e) {
            // Fall through to the staged text below.
        }
        return this._lastUploadedHtmlText || '';
    }

    get canEditWithAgentforce() {
        const body = this._currentDesignerBody;
        return !!(body && body.trim().length > 40);
    }

    get isAgentforceEditMode() {
        return this.agentforceMode === 'edit';
    }

    get agentforceDescriptionLabel() {
        return this.isAgentforceEditMode ? 'What should I change?' : 'What should this document be?';
    }

    get agentforceDescriptionPlaceholder() {
        return this.isAgentforceEditMode
            ? 'e.g. Make the header band dark green, add a totals row under the line items, and move the date to the top right.'
            : 'e.g. A one-page invoice: header band with the account name, a details panel, a line-item table with a grand total row, and a payment-terms footer.';
    }

    get agentforceGenerateLabel() {
        return this.isAgentforceEditMode ? 'Apply Edit' : 'Generate';
    }

    get agentforceModeOptions() {
        return [
            { label: 'Edit what is on the canvas', value: 'edit' },
            { label: 'Start over from scratch', value: 'create' }
        ];
    }

    handleAgentforceModeChange(event) {
        this.agentforceMode = event.detail.value;
        this.agentforceConfirmDiscard = false;
    }

    async _refreshAgentforceAvailability() {
        try {
            this.isAgentforceAvailable = await isAiAvailable();
        } catch (e) {
            this.isAgentforceAvailable = false;
        }
    }

    handleOpenAgentforcePanel() {
        this.agentforceFindings = [];
        this.agentforceSummary = '';
        this.agentforceConfirmDiscard = false;
        // Editing is the safe default whenever there is something to edit —
        // "create" throws away whatever is on the canvas.
        this.agentforceMode = this.canEditWithAgentforce ? 'edit' : 'create';
        this.isAgentforcePanelOpen = true;
    }

    handleCloseAgentforcePanel() {
        this.isAgentforcePanelOpen = false;
    }

    // -----------------------------------------------------------------------
    // Wizard AI step — generate here instead of copy-pasting out.
    //
    // The template record does not exist yet at this point, so this cannot
    // write a ContentVersion. It generates, validates, and drops the HTML into
    // exactly the field the paste box fills, so the wizard's existing create
    // path stages it the same way it stages HTML from ChatGPT. One create path.
    // -----------------------------------------------------------------------

    get showWizardAgentforce() {
        return this.isAgentforceAvailable;
    }

    get wizardAgentforceBtnLabel() {
        return this.isWizardAgentforceGenerating ? 'Generating…' : 'Generate it here with Agentforce';
    }

    get hasWizardAgentforceReport() {
        return this.wizardAgentforceFindings && this.wizardAgentforceFindings.length > 0;
    }

    async handleWizardAgentforceGenerate() {
        if (!this.aiDocDescription || !this.aiDocDescription.trim()) {
            this.showToast(
                'Describe the document first',
                'Tell Agentforce what you want in the description box above, then generate.',
                'warning'
            );
            return;
        }
        this.isWizardAgentforceGenerating = true;
        this.wizardAgentforceFindings = [];
        this.wizardAgentforceSummary = '';
        try {
            // aiAuthoringPrompt is the SAME prompt the Copy Prompt button hands
            // out — fields, assets, description, tag syntax, engine constraints.
            const res = await generateBodyPreview({ prompt: this.aiAuthoringPrompt });
            const html = res.html || '';

            this._aiPastedHtml = html;
            const ta = this.template.querySelector('.dg-ai-paste');
            if (ta) {
                ta.value = html;
            }

            this.wizardAgentforceSummary = res.summary || '';
            this.wizardAgentforceFindings = (res.findings || []).map((f, i) => ({
                key: `wz-af-${i}`,
                rule: f.rule,
                detail: f.detail,
                occurrences: f.occurrences,
                badge: f.action === 'repaired' ? 'Repaired' : f.action === 'removed' ? 'Removed' : 'Check this',
                badgeClass:
                    f.action === 'warning' ? 'slds-theme_warning' : f.action === 'repaired' ? 'slds-theme_success' : ''
            }));

            this.showToast(
                'Template generated',
                `${res.summary || 'Ready.'} Continue to Review & Create — it becomes your v1, and the designer opens on it.`,
                res.warningCount > 0 ? 'warning' : 'success'
            );
        } catch (e) {
            const msg = e?.body?.message || e?.message || 'Generation failed.';
            this.showToast('Agentforce could not generate this', msg, 'error');
        } finally {
            this.isWizardAgentforceGenerating = false;
        }
    }

    /**
     * Creating from scratch replaces the canvas outright, so it needs an
     * explicit confirmation when there is work there to lose. Editing does not:
     * the current body — unsaved edits and all — is what gets sent, so nothing
     * is discarded.
     */
    get agentforceNeedsDiscardConfirm() {
        return !this.isAgentforceEditMode && this.canEditWithAgentforce && !this.agentforceConfirmDiscard;
    }

    handleAgentforceConfirmDiscardChange(event) {
        this.agentforceConfirmDiscard = !!event.target.checked;
    }

    async handleGenerateWithAgentforce() {
        if (!this.editTemplateId) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Save the template first',
                    message: 'There is nothing to write the generated body onto yet.',
                    variant: 'warning'
                })
            );
            return;
        }
        if (this.agentforceNeedsDiscardConfirm) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'This will replace what is on the canvas',
                    message:
                        'Starting over discards the current template, including unsaved edits. Tick the box to confirm, or switch to "Edit what is on the canvas".',
                    variant: 'warning'
                })
            );
            return;
        }
        this.isAgentforceGenerating = true;
        this.agentforceFindings = [];
        this.agentforceSummary = '';
        try {
            // buildAiPrompt owns BOTH the create and the edit framing, so the
            // in-org path, the copy-paste path and the edit path cannot drift.
            //
            // Read the box directly rather than trusting aiDocDescription.
            // lightning-textarea fires `change` on BLUR, so clicking straight
            // from the textarea to Apply Edit could submit a stale (or empty)
            // instruction — the model then receives the template with the
            // placeholder "<<DESCRIBE THE CHANGE YOU WANT>>" and hands it
            // straight back, which reads as "it says it updated but nothing
            // changed". Measured 2026-07-26.
            const descBox = this.template.querySelector('.dg-af-desc');
            if (descBox && typeof descBox.value === 'string') {
                this.aiDocDescription = descBox.value;
            }
            const description = (this.aiDocDescription || '').trim();
            if (!description) {
                throw new Error(
                    this.isAgentforceEditMode
                        ? 'Describe the change you want before applying an edit.'
                        : 'Describe the document you want before generating.'
                );
            }
            const editing = this.isAgentforceEditMode;
            const currentBody = editing ? this._currentDesignerBody : '';
            if (editing && !currentBody.trim()) {
                // Never send "edit this" with nothing attached — the model
                // answers "I do not know" and the reply overwrites the body.
                throw new Error(
                    'Could not read the template off the canvas, so there is nothing to edit. Switch to Source view and try again, or use "Start over from scratch".'
                );
            }
            const shape = extractQueryShape(this.editTemplateQuery, this.editTemplateObject);
            const prompt = buildAiPrompt(shape, {
                dataSourceMode: this.editTemplateObject === 'FlowJsonData' ? 'flow' : 'record',
                providerFields: (this.providerFields || []).map((f) => f.name || f),
                fieldTypes: this._buildFieldTypeMap(this.designerQueryMeta),
                docDescription: description,
                mode: editing ? 'edit' : 'create',
                currentBody
            });

            const res = await generateTemplateBody({
                templateId: this.editTemplateId,
                prompt,
                previousBody: editing ? currentBody : null
            });

            this.agentforceSummary = res.summary || '';
            this.agentforceFindings = (res.findings || []).map((f, i) => ({
                key: `af-${i}`,
                rule: f.rule,
                detail: f.detail,
                occurrences: f.occurrences,
                badge: f.action === 'repaired' ? 'Repaired' : f.action === 'removed' ? 'Removed' : 'Check this',
                badgeClass:
                    f.action === 'warning' ? 'slds-theme_warning' : f.action === 'repaired' ? 'slds-theme_success' : ''
            }));

            const html = res.html || '';
            const wasVisual = this.showHtmlBodyVisual;
            if (wasVisual) {
                this._exitVisualMode();
            }
            this._syncHtmlBodyEditorDom(html);
            this._lastUploadedHtmlText = html;
            this.htmlEditorDirty = true;
            if (wasVisual) {
                // Re-enter on a LATER tick. _enterVisualMode only queues the
                // canvas write; renderedCallback flushes it. Toggling the mode
                // off and on inside one tick coalesces into no re-render at
                // all, so the flush never happens and the canvas stays painted
                // with the previous document — the source textarea updates, the
                // canvas does not, and the edit looks like it did nothing.
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => this._enterVisualMode(html), 0);
            } else {
                this._enterVisualMode(html);
            }

            // Close on a clean result. Leaving the modal up over the canvas is
            // what made a working edit look like a no-op: the one thing the
            // author needs to see is the document behind it.
            this.aiDocDescription = '';
            if (descBox) {
                descBox.value = '';
            }
            if (!res.warningCount) {
                this.isAgentforcePanelOpen = false;
            }

            this.dispatchEvent(
                new ShowToastEvent({
                    title: res.wasEdit ? 'Edit applied' : 'Template generated',
                    message: res.summary || 'Loaded into the canvas.',
                    variant: res.warningCount > 0 ? 'warning' : 'success'
                })
            );
        } catch (e) {
            const msg = e?.body?.message || e?.message || 'Generation failed.';
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Agentforce could not generate this', message: msg, variant: 'error' })
            );
        } finally {
            this.isAgentforceGenerating = false;
        }
    }

    _copyToClipboard(text, successMsg) {
        const fallback = () => {
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            let ok = false;
            try {
                ok = document.execCommand('copy');
            } catch (e) {
                ok = false;
            }
            document.body.removeChild(ta);
            if (ok) {
                this.showToast('Copied', successMsg, 'success');
            } else {
                this.showToast('Copy failed', 'Select the prompt text and copy it manually.', 'warning');
            }
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(
                () => this.showToast('Copied', successMsg, 'success'),
                () => fallback()
            );
        } else {
            fallback();
        }
    }
    handleOutputFormatChange(event) {
        this.newTemplateOutputFormat = event.detail.value;
    }
    handleNewPageOrientationChange(event) {
        this.newTemplatePageOrientation = event.detail.value;
    }
    handleNewPageSizeChange(event) {
        this.newTemplatePageSize = event.detail.value;
    }
    handleNewPageMarginsChange(event) {
        this.newTemplatePageMargins = event.detail.value;
    }
    handleNewCustomMarginsChange(event) {
        this.newTemplateCustomMargins = event.detail.value;
    }
    handleDescChange(event) {
        this.newTemplateDesc = event.detail.value;
    }

    handleConfigChange(event) {
        // The column builder emits 'ApexProvider' as a sentinel object name when in
        // Apex Provider mode. Don't let it clobber a real SObject API name that the
        // user already set in Step 1's "Base Object (optional)" input — needed for
        // cross-object aggregation use cases (issue #62).
        const incoming = event.detail.objectName;
        const haveRealBase = this.newTemplateObject && this.newTemplateObject !== 'ApexProvider';
        if (!(incoming === 'ApexProvider' && haveRealBase)) {
            this.newTemplateObject = incoming;
        }
        this.newTemplateQuery = event.detail.queryConfig;
        this._updateQueryTree();
    }

    toggleVisualBuilder() {
        this.useVisualBuilder = !this.useVisualBuilder;
    }

    toggleEditVisualBuilder() {
        this.editUseVisualBuilder = !this.editUseVisualBuilder;
    }

    handleEditConfigChange(event) {
        // Mirror handleConfigChange's sentinel guard — see comment there.
        const incoming = event.detail.objectName;
        const haveRealBase = this.editTemplateObject && this.editTemplateObject !== 'ApexProvider';
        if (!(incoming === 'ApexProvider' && haveRealBase)) {
            this.editTemplateObject = incoming;
        }
        this.editTemplateQuery = event.detail.queryConfig;
    }

    get visualBuilderToggleIcon() {
        return this.useVisualBuilder ? 'utility:edit' : 'utility:builder';
    }

    get editVisualBuilderToggleIcon() {
        return this.editUseVisualBuilder ? 'utility:edit' : 'utility:builder';
    }

    // ===== APEX DATA PROVIDER (V4) — wizard + edit modal =====

    toggleApexProvider() {
        this.useApexProvider = !this.useApexProvider;
        if (this.useApexProvider) {
            // Mutually exclusive with the visual builder.
            this.useVisualBuilder = false;
            this._loadProviderStateFromQuery(this.newTemplateQuery);
        } else {
            // Switching off clears the v4 binding so the user starts fresh on
            // the manual/visual paths instead of editing a stale provider config.
            this._clearApexProviderState();
            this.newTemplateQuery = '';
        }
    }

    toggleEditApexProvider() {
        this.editUseApexProvider = !this.editUseApexProvider;
        if (this.editUseApexProvider) {
            this.editUseVisualBuilder = false;
            this._loadProviderStateFromQuery(this.editTemplateQuery);
        } else {
            this._clearApexProviderState();
            this.editTemplateQuery = '';
        }
    }

    _loadProviderStateFromQuery(query) {
        // Auto-detect when an existing template already has a v4 config so the
        // picker shows the bound class on first render.
        try {
            const cfg = query ? JSON.parse(query) : null;
            if (cfg && cfg.v === 4 && cfg.provider) {
                this.selectedProviderClassName = cfg.provider;
                this.providerSearchTerm = cfg.provider;
                this._validateAndLoadProviderFields(cfg.provider);
                return;
            }
        } catch (e) {
            /* not JSON — manual or v1 */
        }
        this._clearApexProviderState();
    }

    _clearApexProviderState() {
        this.selectedProviderClassName = '';
        this.providerSearchTerm = '';
        this.providerOptions = [];
        this.providerFields = [];
        this.showProviderPicker = false;
        this.isValidatingProvider = false;
        this.apexProviderBaseObject = '';
    }

    handleApexProviderBaseObjectChange(event) {
        this.apexProviderBaseObject = (event.detail ? event.detail.value : event.target.value) || '';
    }

    handleApexProviderSearch(event) {
        const term = event.target.value || '';
        this.providerSearchTerm = term;
        if (term.length < 2) {
            this.showProviderPicker = false;
            this.providerOptions = [];
            return;
        }
        this.showProviderPicker = true;
        searchDataProviders({ searchTerm: term })
            .then((data) => {
                this.providerOptions = data || [];
            })
            .catch(() => {
                this.providerOptions = [];
            });
    }

    handleApexProviderSelect(event) {
        const className = event.currentTarget.dataset.value;
        if (!className) {
            return;
        }
        this.providerSearchTerm = className;
        this.showProviderPicker = false;
        this._validateAndLoadProviderFields(className);
    }

    _validateAndLoadProviderFields(className) {
        this.isValidatingProvider = true;
        validateDataProvider({ className })
            .then((result) => {
                this.isValidatingProvider = false;
                if (result && result.valid) {
                    this.selectedProviderClassName = className;
                    this.providerFields = result.fields || [];
                    const v4Config = JSON.stringify({ v: 4, provider: className });
                    // Drive whichever query field is in scope (wizard vs edit modal).
                    if (this._editContext) {
                        this.editTemplateQuery = v4Config;
                    } else {
                        this.newTemplateQuery = v4Config;
                    }
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Provider Connected',
                            message: className + ' — ' + this.providerFields.length + ' fields available',
                            variant: 'success'
                        })
                    );
                } else {
                    this.providerFields = [];
                    this.selectedProviderClassName = '';
                    const msg = result && result.error ? result.error : 'Class is not a valid DocGenDataProvider.';
                    this.dispatchEvent(
                        new ShowToastEvent({ title: 'Invalid Provider', message: msg, variant: 'error' })
                    );
                }
            })
            .catch((err) => {
                this.isValidatingProvider = false;
                const msg =
                    err && err.body && err.body.message
                        ? err.body.message
                        : (err && err.message) || 'Validation failed';
                this.dispatchEvent(new ShowToastEvent({ title: 'Error', message: msg, variant: 'error' }));
            });
    }

    handleClearApexProvider() {
        this._clearApexProviderState();
        if (this._editContext) {
            this.editTemplateQuery = '';
        } else {
            this.newTemplateQuery = '';
        }
    }

    get apexProviderToggleLabel() {
        return this.useApexProvider ? 'Switch to manual / visual' : 'Use Apex data provider';
    }

    get editApexProviderToggleLabel() {
        return this.editUseApexProvider ? 'Switch to manual / visual' : 'Use Apex data provider';
    }

    get hasProviderFields() {
        return this.providerFields && this.providerFields.length > 0;
    }

    get providerTagPills() {
        return (this.providerFields || []).map((f) => ({ tag: '{' + f + '}', raw: f }));
    }

    get isProviderConnected() {
        return Boolean(this.selectedProviderClassName) && this.hasProviderFields;
    }

    // ===== Step 1 data-source choice =====

    handleDataSourceModeChange(event) {
        const mode = event.target.value;
        this.dataSourceMode = mode;
        if (mode === 'apex') {
            // Reset record-related state so the wizard's mental model is clean.
            this.newTemplateObject = '';
            this.newTemplateSampleRecordId = '';
            this.sampleRecordData = null;
            // Pre-flip Apex Provider mode so Step 2 lands on the right pane.
            this.useApexProvider = true;
            this.useVisualBuilder = false;
        } else if (mode === 'flow') {
            // JSON-from-Flow: no SOQL, no provider class. Stamp the FlowJsonData
            // sentinel into Base_Object_API__c so the record-page launcher's
            // WHERE Base_Object_API__c = :objectApiName filter naturally excludes
            // these — they're only invokable via DocGenFlowAction.jsonData.
            this.useApexProvider = false;
            this._clearApexProviderState();
            this.newTemplateObject = 'FlowJsonData';
            this.newTemplateSampleRecordId = '';
            this.sampleRecordData = null;
            this.newTemplateQuery = JSON.stringify({ v: 4, source: 'flowJsonData' });
        } else {
            this.useApexProvider = false;
            this._clearApexProviderState();
            // Restore default object so the next "advance to Step 2" doesn't error
            // out before the user re-picks one. Don't carry the FlowJsonData
            // sentinel forward if the user switches back to Record mode.
            if (!this.newTemplateObject || this.newTemplateObject === 'FlowJsonData') {
                this.newTemplateObject = 'Account';
            }
        }
    }

    get dataSourceModeOptions() {
        return [
            { label: 'Salesforce Record (SOQL)', value: 'record' },
            { label: 'Apex Class (Data Provider)', value: 'apex' },
            { label: 'JSON Data (from Flow)', value: 'flow' }
        ];
    }

    get isRecordDataSource() {
        return this.dataSourceMode === 'record';
    }
    get isApexDataSource() {
        return this.dataSourceMode === 'apex';
    }
    get isFlowDataSource() {
        return this.dataSourceMode === 'flow';
    }

    // Edit-modal companion: the modal doesn't have a separate dataSourceMode
    // toggle (since data-source choice is set at creation time), so detect
    // the FlowJsonData sentinel directly off editTemplateObject.
    get isEditFlowDataSource() {
        return this.editTemplateObject === 'FlowJsonData';
    }
    get editBaseObjectDisplay() {
        if (this.editTemplateObject === 'FlowJsonData') return 'JSON Data (from Flow)';
        if (this.editTemplateObject === 'ApexProvider') return 'Apex Data Provider';
        return this.editTemplateObject;
    }

    get readableQueryConfig() {
        return this._formatQueryConfig(this.newTemplateQuery);
    }

    get readableEditQueryConfig() {
        return this._formatQueryConfig(this.editTemplateQuery);
    }

    get isV3Query() {
        const q = this.newTemplateQuery;
        return q && q.trim().startsWith('{') && q.includes('"v":3');
    }

    get isEditV3Query() {
        const q = this.editTemplateQuery;
        return q && q.trim().startsWith('{') && q.includes('"v":3');
    }

    _formatQueryConfig(configStr) {
        if (!configStr) {
            return '';
        }
        try {
            const cfg = JSON.parse(configStr);
            if (cfg.v !== 3 || !cfg.nodes) {
                return configStr;
            }

            const root = cfg.nodes.find((n) => !n.parentNode);
            if (!root) {
                return configStr;
            }

            // Recursively build subqueries — supports any depth
            const buildSubqueries = (parentId) => {
                const children = cfg.nodes.filter((n) => n.parentNode === parentId);
                const subs = [];
                for (const child of children) {
                    const subFields = [...(child.fields || []), ...(child.parentFields || [])];
                    // Recurse: grandchildren become nested subqueries
                    const nestedSubs = buildSubqueries(child.id);
                    subFields.push(...nestedSubs);
                    if (subFields.length === 0) {
                        subFields.push('Id');
                    }
                    let sq = '(SELECT ' + subFields.join(', ') + ' FROM ' + child.relationshipName;
                    if (child.where) {
                        sq += ' WHERE ' + child.where;
                    }
                    if (child.orderBy) {
                        sq += ' ORDER BY ' + child.orderBy;
                    }
                    if (child.limit) {
                        sq += ' LIMIT ' + child.limit;
                    }
                    sq += ')';
                    subs.push(sq);
                }
                return subs;
            };

            const parts = [...(root.fields || []), ...(root.parentFields || []), ...buildSubqueries(root.id)];

            return parts.join(', ');
        } catch {
            return configStr;
        }
    }

    handleNewQueryStringChange(event) {
        this.newTemplateQuery = event.detail ? event.detail.value : event.target.value;
    }

    handleSampleRecordChange(event) {
        this.newTemplateSampleRecordId = event.detail.recordId || '';
        this._loadSampleData();
    }

    _loadSampleData() {
        const recordId = this._activeSampleId;
        const objectName = this._activeObject;
        const query = this._activeQuery;
        if (!recordId || !objectName || !query) {
            this.sampleRecordData = null;
            return;
        }
        previewRecordData({
            recordId: recordId,
            baseObject: objectName,
            queryConfig: query
        })
            .then((data) => {
                this.sampleRecordData = data;
                this._updateQueryTree();
            })
            .catch(() => {
                this.sampleRecordData = null;
            });
    }

    handleObjectSearchInput(event) {
        const term = (event.detail ? event.detail.value : event.target.value) || '';
        this.newTemplateObject = term;
        if (term.length >= 2) {
            if (this.objectOptions.length === 0) {
                getObjectOptions().then((data) => {
                    this.objectOptions = data;
                    this._filterObjects(term);
                });
            } else {
                this._filterObjects(term);
            }
        } else {
            this.showObjectSuggestions = false;
        }
    }

    _filterObjects(term) {
        const t = term.toLowerCase();
        const matches = this.objectOptions.filter(
            (o) => o.label.toLowerCase().includes(t) || o.value.toLowerCase().includes(t)
        );

        // Rank: exact API/label match → standard prefix match → label prefix → API prefix → contains.
        // Surfaces standard Opportunity above payment-processor lookalikes when the user types
        // "opportunity" in an org with 30+ namespaced Opportunity_* custom objects (Sprint NY 2026 feedback).
        const isStandard = (apiName) => !apiName.includes('__');
        const score = (o) => {
            const lbl = o.label.toLowerCase();
            const api = o.value.toLowerCase();
            if (api === t || lbl === t) return 0;
            if (api.startsWith(t) && isStandard(o.value)) return 1;
            if (lbl.startsWith(t) && isStandard(o.value)) return 2;
            if (api.startsWith(t)) return 3;
            if (lbl.startsWith(t)) return 4;
            if (isStandard(o.value)) return 5;
            return 6;
        };
        matches.sort((a, b) => {
            const sa = score(a);
            const sb = score(b);
            if (sa !== sb) return sa - sb;
            return a.label.localeCompare(b.label);
        });

        this.filteredObjectOptions = matches.slice(0, 50).map((o) => ({
            ...o,
            isStandard: !o.value.includes('__')
        }));
        this.showObjectSuggestions = this.filteredObjectOptions.length > 0;
    }

    handleObjectSuggestionClick(event) {
        const apiName = event.currentTarget.dataset.value;
        this.newTemplateObject = apiName;
        this.showObjectSuggestions = false;
        this._loadObjectMetadata(apiName);
    }

    _loadObjectMetadata(objectName) {
        // Load fields, children, and parents in parallel for slash commands
        getObjectFields({ objectName })
            .then((data) => {
                this._allFields = data || [];
            })
            .catch(() => {
                this._allFields = [];
            });
        // #161 — updateable-only list for Signer Inputs writeback targets.
        getUpdateableObjectFields({ objectName })
            .then((data) => {
                this._allUpdateableFields = data || [];
            })
            .catch(() => {
                this._allUpdateableFields = [];
            });
        getChildRelationships({ objectName })
            .then((data) => {
                this._allChildren = data || [];
            })
            .catch(() => {
                this._allChildren = [];
            });
        getParentRelationships({ objectName })
            .then((data) => {
                this._allParents = data || [];
            })
            .catch(() => {
                this._allParents = [];
            });
    }

    // --- Live Query Tree ---
    _updateQueryTree() {
        const q = (this._activeQuery || '').trim();
        if (!q || !this._activeObject) {
            this.queryTreeNodes = [];
            return;
        }
        try {
            const nodes = [];
            const data = this.sampleRecordData || {};
            // V3 JSON: convert to a parsed-like shape so the rest of the
            // tree-builder works unchanged. Filtered-subset slots surface
            // their alias on the loop label so they're distinguishable.
            let parsed;
            if (q.startsWith('{') && q.includes('"v":3')) {
                const cfg = JSON.parse(q);
                const root = (cfg.nodes || []).find((n) => !n.parentNode) || {};
                const buildSubs = (parentId) => {
                    const kids = (cfg.nodes || []).filter((n) => n.parentNode === parentId);
                    return kids.map((k) => ({
                        relationshipName: k.alias || k.relationshipName,
                        fields: [...(k.fields || []), ...(k.parentFields || [])],
                        whereClause: k.where || '',
                        children: buildSubs(k.id)
                    }));
                };
                parsed = {
                    baseFields: root.fields || [],
                    parentFields: root.parentFields || [],
                    subqueries: buildSubs(root.id),
                    warnings: []
                };
            } else {
                parsed = parseSOQLFields(q);
            }
            this.queryWarnings = parsed.warnings.length > 0 ? parsed.warnings : null;
            const directFields = parsed.baseFields;
            const parentFields = parsed.parentFields;

            // Build field display with sample values
            const fieldPills = directFields.map((f) => {
                const val = data[f];
                return { key: f, name: f, sample: val != null ? String(val) : '' };
            });
            const parentPills = parentFields.map((f) => {
                // Resolve dot notation: "Owner.Name" → data.Owner.Name
                const parts = f.split('.');
                let val = data;
                for (const p of parts) {
                    val = val && typeof val === 'object' ? val[p] : undefined;
                }
                return { key: f, name: f, sample: val != null ? String(val) : '' };
            });

            // Flatten child subqueries recursively into a single list with depth
            // so the template can render any nesting level with one for:each
            const flatChildren = [];
            const flattenChildren = (subqueries, depth) => {
                for (let i = 0; i < subqueries.length; i++) {
                    const sq = subqueries[i];
                    const directF = sq.fields.filter((f) => !f.includes('.'));
                    const parentF = sq.fields.filter((f) => f.includes('.'));
                    flatChildren.push({
                        id: 'child_' + flatChildren.length,
                        label: sq.relationshipName,
                        fields: directF,
                        parentFields: parentF,
                        hasParentFields: parentF.length > 0,
                        fieldCount: sq.fields.length,
                        where: sq.whereClause || '',
                        depth,
                        indentStyle:
                            'margin-left: ' +
                            depth * 20 +
                            'px; margin-bottom: 6px; padding: 8px 10px; background: #fff; border: 1px solid #e5e5e5; border-radius: 6px;'
                    });
                    if (sq.children && sq.children.length > 0) {
                        flattenChildren(sq.children, depth + 1);
                    }
                }
            };
            flattenChildren(parsed.subqueries, 0);

            nodes.push({
                id: 'root',
                label: this._activeObject,
                icon: 'standard:account',
                isRoot: true,
                fields: directFields,
                parentFields: parentFields,
                fieldPills: fieldPills,
                parentPills: parentPills,
                flatChildren: flatChildren,
                hasFields: fieldPills.length > 0,
                hasParentFields: parentPills.length > 0,
                hasFlatChildren: flatChildren.length > 0
            });
            this.queryTreeNodes = nodes;
        } catch (err) {
            // eslint-disable-line no-unused-vars
            this.queryTreeNodes = [];
        }
    }

    // --- Edit Handlers ---
    handleEditNameChange(event) {
        this.editTemplateName = event.detail.value;
    }
    handleEditCategoryChange(event) {
        this.editTemplateCategory = event.detail.value;
    }
    handleEditTypeChange(event) {
        this.editTemplateType = event.detail.value;
        if (event.detail.value === 'Excel' && this.editTemplateOutputFormat === 'PDF') {
            this.editTemplateOutputFormat = 'Native';
        }
        if (event.detail.value === 'HTML' || event.detail.value === 'PDF') {
            this.editTemplateOutputFormat = 'PDF';
        }
    }
    handleEditHeaderHtmlChange(event) {
        this.editTemplateHeaderHtml = event.detail.value;
    }
    handleEditFooterHtmlChange(event) {
        this.editTemplateFooterHtml = event.detail.value;
    }
    toggleHeaderHtmlSource() {
        this.showHeaderHtmlSource = !this.showHeaderHtmlSource;
    }
    toggleFooterHtmlSource() {
        this.showFooterHtmlSource = !this.showFooterHtmlSource;
    }
    get headerSourceToggleLabel() {
        return this.showHeaderHtmlSource ? 'Show Editor' : 'Show HTML';
    }
    get footerSourceToggleLabel() {
        return this.showFooterHtmlSource ? 'Show Editor' : 'Show HTML';
    }
    handleEditOutputFormatChange(event) {
        this.editTemplateOutputFormat = event.detail.value;
    }
    handleEditPageOrientationChange(event) {
        this.editTemplatePageOrientation = event.detail.value;
    }
    handleEditPageSizeChange(event) {
        this.editTemplatePageSize = event.detail.value;
    }
    handleEditPageMarginsChange(event) {
        this.editTemplatePageMargins = event.detail.value;
    }
    handleEditCustomMarginsChange(event) {
        this.editTemplateCustomMargins = event.detail.value;
    }
    handleEditDescChange(event) {
        this.editTemplateDesc = event.detail.value;
    }
    handleEditActiveChange(event) {
        this.editTemplateIsActive = event.target.checked;
    }
    handleEditDefaultChange(event) {
        this.editTemplateIsDefault = event.target.checked;
    }
    // 1.47 — runner visibility & sort handlers
    handleEditSortOrderChange(event) {
        this.editTemplateSortOrder = event.detail.value;
    }
    handleEditLockOutputChange(event) {
        this.editTemplateLockOutputFormat = event.target.checked;
    }
    handleEditSpecificRecordIdsChange(event) {
        this.editTemplateSpecificRecordIds = event.detail.value;
    }
    handleEditRequiredPermSetsChange(event) {
        this.editTemplateRequiredPermissionSets = event.detail.value;
    }
    handleEditRecordFilterChange(event) {
        this.editTemplateRecordFilter = event.detail.value;
        this.editTemplateRecordFilterResult = '';
        this.editTemplateRecordFilterResultMessage = '';
    }

    async handleTestRecordFilter() {
        if (!this.editTemplateRecordFilter || !this.editTemplateTestRecordId || !this.editTemplateObject) {
            this.editTemplateRecordFilterResult = 'error';
            this.editTemplateRecordFilterResultMessage =
                'Need Base Object, Sample Test Record Id (set on the template), and a Record Filter clause to test.';
            return;
        }
        this.editTemplateRecordFilterTesting = true;
        this.editTemplateRecordFilterResult = '';
        this.editTemplateRecordFilterResultMessage = '';
        try {
            const res = await testRecordFilter({
                baseObjectApiName: this.editTemplateObject,
                sampleRecordId: this.editTemplateTestRecordId,
                whereClause: this.editTemplateRecordFilter
            });
            if (res.error) {
                this.editTemplateRecordFilterResult = 'error';
                this.editTemplateRecordFilterResultMessage = res.error;
            } else if (res.matched) {
                this.editTemplateRecordFilterResult = 'matched';
                this.editTemplateRecordFilterResultMessage =
                    '✓ Match — this template would appear for the test record.';
            } else {
                this.editTemplateRecordFilterResult = 'nomatch';
                this.editTemplateRecordFilterResultMessage =
                    '✗ No match — the test record does not satisfy this filter.';
            }
        } catch (e) {
            this.editTemplateRecordFilterResult = 'error';
            this.editTemplateRecordFilterResultMessage = e.body && e.body.message ? e.body.message : e.message;
        } finally {
            this.editTemplateRecordFilterTesting = false;
        }
    }

    get recordFilterResultClass() {
        if (this.editTemplateRecordFilterResult === 'matched') return 'slds-text-color_success slds-var-m-top_x-small';
        if (this.editTemplateRecordFilterResult === 'nomatch') return 'slds-text-color_weak slds-var-m-top_x-small';
        if (this.editTemplateRecordFilterResult === 'error') return 'slds-text-color_error slds-var-m-top_x-small';
        return 'slds-hide';
    }

    handleQueryTabActive() {
        // lightning-tab lazy-renders content — sync textarea when query tab first activates
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const ta = this.template.querySelector('.edit-query-textarea');
            if (ta && this.editTemplateQuery && ta.value !== this.editTemplateQuery) {
                ta.value = this.editTemplateQuery;
            }
            this._updateQueryTree();
        }, 50);
    }

    handleManualQueryToggle(event) {
        this.isManualQuery = event.target.checked;
        // Keep editTemplateQuery as-is when toggling. Earlier behavior converted
        // V3→V1 here, which silently dropped filtered-subset alias slots that V1
        // SOQL can't express. Manual textarea uses the readable getter for
        // display when the user wants a V1 view.
    }

    handleQueryStringChange(event) {
        this.editTemplateQuery = event.target.value;
    }

    handleEditDirectQueryEdit(event) {
        this.editTemplateQuery = event.target.value;
        this._updateQueryTree();
        this._updateSuggestions(event.target);
        clearTimeout(this._sampleDebounce);
        this._sampleDebounce = setTimeout(() => {
            this._loadSampleData();
        }, 800);
    }

    handleEditConfigChange(event) {
        // Mirror handleConfigChange's sentinel guard — see comment there.
        const incoming = event.detail.objectName;
        const haveRealBase = this.editTemplateObject && this.editTemplateObject !== 'ApexProvider';
        if (!(incoming === 'ApexProvider' && haveRealBase)) {
            this.editTemplateObject = incoming;
        }
        this.editTemplateQuery = event.detail.queryConfig;
    }

    /**
     * Strips outer SELECT and FROM clauses from a query config string.
     * Delegates to the shared stripOuterSelectFrom utility in docGenUtils.
     */
    _sanitizeQueryConfig(queryConfig) {
        if (!queryConfig) return queryConfig;
        const cleaned = queryConfig.trim();
        if (cleaned.startsWith('{')) return cleaned;
        return stripOuterSelectFrom(cleaned);
    }

    // ============================================================
    // #161 — Signer Inputs (form fields with optional record writeback)
    // ------------------------------------------------------------
    // Rows live as parsed.formFields on the editTemplateQuery JSON:
    //   { key, label, fieldApiName, type, required, writeback, mergeTag,
    //     choices, listOnCertificate }
    // `key` is a stable [A-Za-z0-9_]+ id generated once and NEVER reused after
    // delete; `mergeTag` is `{?<key>}` and never changes when the label is edited.
    // ============================================================

    get signerFieldTypeOptions() {
        return [
            { label: 'Text', value: 'text' },
            { label: 'Number', value: 'number' },
            { label: 'Date', value: 'date' },
            { label: 'Checkbox', value: 'checkbox' },
            { label: 'Picklist', value: 'picklist' }
        ];
    }

    // Capture-or-writeback field pickers, keyed off the edit template object.
    get signerFieldMappedOptions() {
        return [
            { label: '— Not mapped (capture only) —', value: '' },
            ...(this._allFields || []).map((f) => ({ label: f.label, value: f.value }))
        ];
    }
    get signerFieldWritebackOptions() {
        return [
            { label: '— Select a field to write back —', value: '' },
            ...(this._allUpdateableFields || []).map((f) => ({ label: f.label, value: f.value }))
        ];
    }

    // View-model rows for the table template. Picks the right field-picker
    // option set per row (writeback rows must only offer updateable fields).
    get signerFieldRows() {
        return (this.signerFields || []).map((row, index) => ({
            key: row.key,
            index,
            label: row.label || '',
            fieldApiName: row.fieldApiName || '',
            type: row.type || 'text',
            required: !!row.required,
            writeback: !!row.writeback,
            listOnCertificate: !!row.listOnCertificate,
            mergeTag: row.mergeTag || this._buildSignerMergeTag(row.key),
            choicesText: Array.isArray(row.choices) ? row.choices.join(', ') : row.choices || '',
            isPicklist: (row.type || 'text') === 'picklist',
            fieldOptions: row.writeback ? this.signerFieldWritebackOptions : this.signerFieldMappedOptions,
            isFirst: index === 0,
            isLast: index === (this.signerFields || []).length - 1
        }));
    }

    get hasSignerFields() {
        return (this.signerFields || []).length > 0;
    }

    _buildSignerMergeTag(key) {
        return '{?' + key + '}';
    }

    // Stable, collision-free [A-Za-z0-9_]+ key. Slugifies the label as a seed but
    // ALWAYS appends a short unique suffix so renaming the label can never produce
    // a key already in use (and so the merge tag stays unique).
    _generateSignerFieldKey(seedLabel) {
        const existing = new Set((this.signerFields || []).map((f) => f.key));
        const base =
            String(seedLabel || 'field')
                .replace(/[^A-Za-z0-9_]+/g, '_')
                .replace(/^_+|_+$/g, '')
                .slice(0, 30) || 'field';
        let candidate;
        let i = 0;
        do {
            const suffix = Math.random().toString(36).slice(2, 6);
            candidate = (base + '_' + suffix).replace(/__+/g, '_');
            i++;
        } while (existing.has(candidate) && i < 50);
        return candidate;
    }

    // Parse the dedicated Form_Fields_Config__c JSON (shape `{formFields:[...]}`)
    // into signerFields. Independent of Query_Config__c, so it works for EVERY
    // template type (V1 flat-string, V3/V4 JSON, Apex provider) — no gate.
    _hydrateSignerFields() {
        let rows = [];
        const cfg = (this.editFormFieldsConfig || '').trim();
        if (cfg.startsWith('{')) {
            try {
                const parsed = JSON.parse(cfg);
                if (Array.isArray(parsed.formFields)) {
                    rows = parsed.formFields.map((f) => ({
                        key: f.key,
                        label: f.label || '',
                        fieldApiName: f.fieldApiName || '',
                        type: f.type || 'text',
                        required: !!f.required,
                        writeback: !!f.writeback,
                        mergeTag: f.mergeTag || this._buildSignerMergeTag(f.key),
                        choices: Array.isArray(f.choices) ? f.choices : [],
                        listOnCertificate: !!f.listOnCertificate
                    }));
                }
            } catch (e) {
                /* malformed / empty config — no form fields */
            }
        }
        this.signerFields = rows;
    }

    // Serialize the current signerFields into the dedicated Form_Fields_Config__c
    // JSON string. NEVER touches editTemplateQuery — form fields no longer live on
    // Query_Config__c, so this works regardless of the template's query shape.
    _persistSignerFields() {
        const serialized = (this.signerFields || []).map((f) => ({
            key: f.key,
            label: f.label || '',
            fieldApiName: f.fieldApiName || '',
            type: f.type || 'text',
            required: !!f.required,
            writeback: !!f.writeback,
            mergeTag: f.mergeTag || this._buildSignerMergeTag(f.key),
            choices: Array.isArray(f.choices) ? f.choices : [],
            listOnCertificate: !!f.listOnCertificate
        }));
        this.editFormFieldsConfig = JSON.stringify({ formFields: serialized });
    }

    handleAddSignerField() {
        const label = 'New Field';
        const key = this._generateSignerFieldKey(label);
        this.signerFields = [
            ...(this.signerFields || []),
            {
                key,
                label,
                fieldApiName: '',
                type: 'text',
                required: false,
                writeback: false,
                mergeTag: this._buildSignerMergeTag(key),
                choices: [],
                listOnCertificate: false
            }
        ];
        this._persistSignerFields();
    }

    handleRemoveSignerField(event) {
        const index = Number(event.currentTarget.dataset.index);
        if (Number.isNaN(index)) return;
        this.signerFields = (this.signerFields || []).filter((_, i) => i !== index);
        this._persistSignerFields();
    }

    handleMoveSignerFieldUp(event) {
        const index = Number(event.currentTarget.dataset.index);
        if (Number.isNaN(index) || index <= 0) return;
        const rows = [...this.signerFields];
        [rows[index - 1], rows[index]] = [rows[index], rows[index - 1]];
        this.signerFields = rows;
        this._persistSignerFields();
    }

    handleMoveSignerFieldDown(event) {
        const index = Number(event.currentTarget.dataset.index);
        if (Number.isNaN(index) || index >= this.signerFields.length - 1) return;
        const rows = [...this.signerFields];
        [rows[index + 1], rows[index]] = [rows[index], rows[index + 1]];
        this.signerFields = rows;
        this._persistSignerFields();
    }

    // Generic per-row update — never touches key/mergeTag (label edits are safe).
    _updateSignerFieldRow(index, patch) {
        if (Number.isNaN(index)) return;
        this.signerFields = (this.signerFields || []).map((row, i) => (i === index ? { ...row, ...patch } : row));
        this._persistSignerFields();
    }

    handleSignerFieldLabelChange(event) {
        // Label edits must NOT change key/mergeTag.
        this._updateSignerFieldRow(Number(event.currentTarget.dataset.index), {
            label: event.detail ? event.detail.value : event.target.value
        });
    }

    handleSignerFieldMappedChange(event) {
        this._updateSignerFieldRow(Number(event.currentTarget.dataset.index), {
            fieldApiName: (event.detail ? event.detail.value : event.target.value) || ''
        });
    }

    handleSignerFieldTypeChange(event) {
        this._updateSignerFieldRow(Number(event.currentTarget.dataset.index), {
            type: event.detail ? event.detail.value : event.target.value
        });
    }

    handleSignerFieldRequiredChange(event) {
        this._updateSignerFieldRow(Number(event.currentTarget.dataset.index), {
            required: event.detail ? event.detail.checked : event.target.checked
        });
    }

    handleSignerFieldWritebackChange(event) {
        const index = Number(event.currentTarget.dataset.index);
        const writeback = event.detail ? event.detail.checked : event.target.checked;
        // Toggling writeback swaps the field-picker option set; clear the mapped
        // field so a stale (possibly non-updateable) selection can't leak through.
        this._updateSignerFieldRow(index, { writeback, fieldApiName: '' });
    }

    handleSignerFieldChoicesChange(event) {
        const raw = event.detail ? event.detail.value : event.target.value;
        const choices = String(raw || '')
            .split(',')
            .map((s) => s.trim())
            .filter((s) => s.length > 0);
        this._updateSignerFieldRow(Number(event.currentTarget.dataset.index), { choices });
    }

    handleSignerFieldCertificateChange(event) {
        this._updateSignerFieldRow(Number(event.currentTarget.dataset.index), {
            listOnCertificate: event.detail ? event.detail.checked : event.target.checked
        });
    }

    handleEditTestRecordChange(event) {
        this.editTemplateTestRecordId = event.detail.recordId;
        this._loadSampleData();
    }

    // Generate a flat tag list from the query config for the tags view
    get editTemplateTags() {
        const qc = this.editTemplateQuery;
        if (!qc) return null;

        try {
            // Try JSON v3 / v4
            if (qc.trim().startsWith('{')) {
                const config = JSON.parse(qc);

                // V4 (Apex Data Provider) — fields come from the bound class's
                // getFieldNames(), which we cached in providerFields when the
                // modal opened. The list uses '#Foo'/'/Foo' to mark loop
                // boundaries and 'Foo.Field' for parent / loop-row fields.
                if (config.v === 4 && config.provider) {
                    return this._buildV4TagSections(config.provider, this.providerFields || []);
                }

                if (config.v >= 3 && config.nodes) {
                    const sections = [];
                    for (const node of config.nodes) {
                        const tags = [];
                        if (node.fields) {
                            for (const f of node.fields) {
                                tags.push({ code: '{' + f + '}' });
                            }
                        }
                        if (node.parentFields) {
                            for (const pf of node.parentFields) {
                                tags.push({ code: '{' + pf + '}' });
                            }
                        }
                        const isLoop = !!node.parentNode;
                        // Loop tag uses alias when present (filtered subset
                        // distinguishes itself by alias, not relationshipName).
                        const loopName = node.alias || node.relationshipName;
                        sections.push({
                            name: node.object + (isLoop ? ' (loop' + (node.alias ? ' — ' + node.alias : '') + ')' : ''),
                            isLoop,
                            loopStart: isLoop ? '{#' + loopName + '}' : '',
                            loopEnd: isLoop ? '{/' + loopName + '}' : '',
                            tags
                        });
                    }
                    return sections.length > 0 ? sections : null;
                }
            }

            // V1 / full SOQL: parse using shared nesting-aware parser
            const parsed = parseSOQLFields(qc);
            const sections = [];

            const buildTagSections = (subqueries) => {
                for (const sq of subqueries) {
                    sections.push({
                        name: sq.relationshipName,
                        isLoop: true,
                        loopStart: '{#' + sq.relationshipName + '}',
                        loopEnd: '{/' + sq.relationshipName + '}',
                        tags: sq.fields.filter((f) => f).map((f) => ({ code: '{' + f + '}' }))
                    });
                    if (sq.children && sq.children.length > 0) {
                        buildTagSections(sq.children);
                    }
                }
            };

            const baseFields = [...parsed.baseFields, ...parsed.parentFields];
            buildTagSections(parsed.subqueries);

            if (baseFields.length > 0) {
                sections.unshift({
                    name: this.editTemplateObject || 'Base Fields',
                    isLoop: false,
                    tags: baseFields.map((f) => ({ code: '{' + f + '}' }))
                });
            }

            return sections.length > 0 ? sections : null;
        } catch {
            return null;
        }
    }

    /**
     * Builds Copy-Paste Tags sections for a v4 Apex Data Provider template.
     * Walks the provider's getFieldNames() output and groups by:
     *   - Bare names (e.g. "Name", "Industry") → "Provider fields"
     *   - Dotted names (e.g. "Owner.Name") → grouped by parent → "Owner"
     *   - "#Foo" / "/Foo" markers + "Foo.Field" → loop section "Foo"
     * Falls back gracefully if providerFields hasn't loaded yet.
     */
    _buildV4TagSections(providerName, fields) {
        if (!fields || fields.length === 0) {
            // Provider not yet validated — show a placeholder so the tab isn't
            // empty. The fields populate after _validateAndLoadProviderFields runs.
            return [
                {
                    name: providerName + ' (loading…)',
                    isLoop: false,
                    tags: []
                }
            ];
        }

        const baseTags = []; // Bare field tags
        const parentSections = {}; // 'Owner' → { tags: [...] }
        const loopSections = {}; // 'Contacts' → { tags: [...] }
        const loopOrder = []; // preserve order of first appearance

        // First pass: detect explicit loop boundaries '#Foo' so we know which
        // dotted prefixes are loop-rows vs parent-lookups.
        const declaredLoops = new Set();
        for (const f of fields) {
            if (typeof f !== 'string') {
                continue;
            }
            if (f.startsWith('#')) {
                declaredLoops.add(f.substring(1));
            }
        }

        for (const f of fields) {
            if (typeof f !== 'string' || !f) {
                continue;
            }
            // Loop boundary markers — used only to declare loop sections;
            // emitted as loopStart/loopEnd, not as click-to-copy tags.
            if (f.startsWith('#') || f.startsWith('/')) {
                continue;
            }

            const dotIdx = f.indexOf('.');
            if (dotIdx > 0) {
                const prefix = f.substring(0, dotIdx);
                if (declaredLoops.has(prefix)) {
                    if (!loopSections[prefix]) {
                        loopSections[prefix] = { tags: [] };
                        loopOrder.push(prefix);
                    }
                    // Inside a loop, render as the bare field name (loop scope rewrites it)
                    loopSections[prefix].tags.push({ code: '{' + f.substring(dotIdx + 1) + '}' });
                } else {
                    if (!parentSections[prefix]) {
                        parentSections[prefix] = { tags: [] };
                    }
                    parentSections[prefix].tags.push({ code: '{' + f + '}' });
                }
            } else {
                baseTags.push({ code: '{' + f + '}' });
            }
        }

        const sections = [];
        if (baseTags.length > 0) {
            sections.push({
                name: providerName + ' — fields',
                isLoop: false,
                tags: baseTags
            });
        }
        for (const parent of Object.keys(parentSections)) {
            sections.push({
                name: parent + ' (parent lookup)',
                isLoop: false,
                tags: parentSections[parent].tags
            });
        }
        for (const loop of loopOrder) {
            sections.push({
                name: loop + ' (loop)',
                isLoop: true,
                loopStart: '{#' + loop + '}',
                loopEnd: '{/' + loop + '}',
                tags: loopSections[loop].tags
            });
        }
        return sections.length > 0 ? sections : null;
    }

    async handleCopyEditTag(event) {
        const tag = event.currentTarget.dataset.tag;
        if (!tag) {
            return;
        }
        try {
            await this._copyToClipboard(tag);
            this.dispatchEvent(new ShowToastEvent({ title: 'Copied', message: tag, variant: 'success' }));
        } catch {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Copy Failed', message: 'Unable to copy to clipboard.', variant: 'error' })
            );
        }
    }

    // Split a string on commas, but only at parentheses depth 0
    _splitTopLevel(str) {
        const tokens = [];
        let depth = 0;
        let current = '';
        for (let i = 0; i < str.length; i++) {
            const ch = str[i];
            if (ch === '(') {
                depth++;
                current += ch;
            } else if (ch === ')') {
                depth--;
                current += ch;
            } else if (ch === ',' && depth === 0) {
                tokens.push(current.trim());
                current = '';
            } else {
                current += ch;
            }
        }
        if (current.trim()) {
            tokens.push(current.trim());
        }
        return tokens;
    }

    _copyToClipboard(text) {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        }
        const textArea = document.createElement('textarea');
        textArea.value = text;
        textArea.style.position = 'fixed';
        textArea.style.left = '-9999px';
        document.body.appendChild(textArea);
        textArea.focus();
        textArea.select();
        try {
            document.execCommand('copy');
        } finally {
            document.body.removeChild(textArea);
        }
        return Promise.resolve();
    }

    handleTitleFormatChange(event) {
        this.editTemplateTitleFormat = event.detail.value;
    }

    // #verification — template-level signer-verification defaults
    get signerVerificationOptions() {
        return [
            { label: 'Inherit (use org default)', value: 'Inherit' },
            { label: 'Required (email PIN)', value: 'Required' },
            { label: 'Off (no verification)', value: 'Off' }
        ];
    }
    get prefillSignerEmailOptions() {
        return [
            { label: 'Inherit (use org default)', value: 'Inherit' },
            { label: 'Yes (auto-send to known email)', value: 'Yes' },
            { label: 'No (signer types email)', value: 'No' }
        ];
    }
    handleSignerVerificationChange(event) {
        this.editTemplateSignerVerification = event.detail.value;
    }

    handleApiNameChange(event) {
        this.editTemplateApiName = (event.detail.value || '').trim();
    }

    handleDefaultEmailMessageChange(event) {
        this.editTemplateDefaultEmailMessage = event.detail.value || '';
    }
    handlePrefillSignerEmailChange(event) {
        this.editTemplatePrefillSignerEmail = event.detail.value;
    }

    // #367
    handleShowDeclineChange(event) {
        this.editTemplateShowDecline = event.target.checked;
    }

    get isBuilderDisabled() {
        return this.isManualQuery;
    }

    // --- Options ---
    // --- #236: Type__c picklist read from the org, not hardcoded ---------------
    @wire(getObjectInfo, { objectApiName: DOCGEN_TEMPLATE_OBJECT })
    templateObjectInfo;

    @wire(getPicklistValues, {
        recordTypeId: '$templateObjectInfo.data.defaultRecordTypeId',
        fieldApiName: TYPE_FIELD
    })
    wiredTypePicklist(result) {
        this._typePicklist = result;
        if (result && result.data && Array.isArray(result.data.values)) {
            this._orgTypeValues = result.data.values.map((v) => v.value);
            // The wizard's default is HTML. If this org never received it, fall back
            // to something it does have rather than failing on every create.
            if (this._orgTypeValues.length && !this._orgTypeValues.includes(this.newTemplateType)) {
                this.newTemplateType = this._orgTypeValues.includes('HTML') ? 'HTML' : this._orgTypeValues[0];
            }
        }
    }
    _typePicklist;
    @track _orgTypeValues = null;

    get typeOptions() {
        const fallback = Object.keys(TYPE_VALUE_HISTORY);
        // Until the wire resolves (and if it errors) keep the historical hardcoded
        // list so the wizard is never empty.
        const values = this._orgTypeValues && this._orgTypeValues.length ? this._orgTypeValues : fallback;
        // Canvas is omitted: this picker only appears on the upload path, and there is
        // no file that makes a Canvas template. It is reached by choosing "Start from a
        // Blank Canvas" instead.
        return values.filter((v) => v !== 'Canvas').map((v) => ({ label: v, value: v }));
    }

    /**
     * #236 — true when this org's Type__c picklist is missing values this build
     * expects. That means the package schema did not fully upgrade, and it is the
     * leading explanation for "cannot create new templates after upgrading".
     */
    get missingTypeValues() {
        if (!this._orgTypeValues || !this._orgTypeValues.length) {
            return [];
        }
        return Object.keys(TYPE_VALUE_HISTORY).filter((v) => !this._orgTypeValues.includes(v));
    }

    get hasMissingTypeValues() {
        return this.missingTypeValues.length > 0;
    }

    get missingTypeValuesMessage() {
        const missing = this.missingTypeValues.map((v) => `${v} (added in v${TYPE_VALUE_HISTORY[v]})`).join(', ');
        return (
            `This org's Template Type picklist is missing: ${missing}. ` +
            'That means the package upgrade did not fully apply its schema. ' +
            'Re-run the package upgrade, or add the missing values to the ' +
            'Portwood Template > Type field in Setup. Until then those template types cannot be created.'
        );
    }

    get outputFormatOptions() {
        const type = this.isCreating ? this.newTemplateType : this.editTemplateType;
        if (type === 'Excel') {
            return [{ label: 'Native (.xlsx / .xlsm)', value: 'Native' }];
        }
        // Canvas belongs here: it renders through the HTML path, which sets PDF
        // unconditionally. Offering "Native (.docx)" was offering a format the engine
        // will never produce for it.
        if (type === 'HTML' || type === 'PDF' || type === 'Canvas') {
            return [{ label: 'PDF', value: 'PDF' }];
        }
        return [
            { label: type === 'PowerPoint' ? 'Native (.pptx)' : 'Native (.docx)', value: 'Native' },
            { label: 'PDF', value: 'PDF' }
        ];
    }

    get acceptedFormats() {
        const type = this.isCreating ? this.newTemplateType : this.editTemplateType;
        if (type === 'PowerPoint') return ['.pptx'];
        if (type === 'Excel') return ['.xlsx', '.xlsm'];
        if (type === 'HTML') return ['.html', '.htm', '.zip'];
        if (type === 'PDF') return ['.pdf'];
        // A Canvas body is authored, never uploaded. Falling through to .docx invited
        // someone to drop a Word file onto a template that cannot hold one.
        if (type === 'Canvas') return [];
        return ['.docx'];
    }

    get pageOrientationOptions() {
        return [
            { label: 'Portrait', value: 'Portrait' },
            { label: 'Landscape', value: 'Landscape' }
        ];
    }

    get pageSizeOptions() {
        return [
            { label: 'Letter (8.5 x 11 in)', value: 'Letter' },
            { label: 'Legal (8.5 x 14 in)', value: 'Legal' },
            { label: 'A4 (210 x 297 mm)', value: 'A4' }
        ];
    }

    get pageMarginsOptions() {
        return [
            { label: 'Default for size', value: 'Default' },
            { label: 'From source DOCX margins', value: 'FromSource' },
            { label: 'Narrow (0.5 in)', value: 'Narrow' },
            { label: 'Normal (1.0 in)', value: 'Normal' },
            { label: 'Wide (1.5 in)', value: 'Wide' },
            { label: 'Custom (specify below)', value: 'Custom' }
        ];
    }

    /** Orientation/size/margins only apply to PDF output. Hide for Native/Excel. */
    get showPageOrientation() {
        const fmt = this.isCreating ? this.newTemplateOutputFormat : this.editTemplateOutputFormat;
        return fmt === 'PDF';
    }

    // v1.90 — for the create wizard, hide page-layout fields when Type=HTML.
    // HTML templates almost always declare their own @page CSS, so these fields
    // are a UX trap (engine ignores them, but the wizard pre-fills them with
    // Portrait/Letter/Default and makes users feel they're a required choice).
    // After the template is created and the body is uploaded, the edit modal
    // re-evaluates and shows them only if the uploaded HTML lacks @page.
    /**
     * Page layout belongs to the DOCUMENT for HTML and Canvas, not to the record.
     *
     * Both render through an @page CSS rule the body carries, and the engine defers to
     * a source @page — so these fields are read by nothing on those types. Collecting
     * them anyway asks for a decision that is then silently discarded, which is how
     * someone picks A4 in the wizard and spends the afternoon wondering why the PDF is
     * Letter. Canvas additionally owns page setup in its own editor.
     */
    get showNewPageLayoutFields() {
        return this.showPageOrientation && this.newTemplateType !== 'HTML' && this.newTemplateType !== 'Canvas';
    }

    /** Explains where page setup went for a Canvas template, rather than leaving a gap. */
    get showCanvasPageNote() {
        return this.newTemplateType === 'Canvas';
    }

    get isCreatingHtmlPdf() {
        return this.newTemplateType === 'HTML' && this.newTemplateOutputFormat === 'PDF';
    }

    /** Show Custom Margins text field only when "Custom" preset is selected. */
    get showNewCustomMargins() {
        return this.showNewPageLayoutFields && this.newTemplatePageMargins === 'Custom';
    }

    get showEditCustomMargins() {
        // Tied to the page-layout block rather than to output format alone: with a
        // Canvas template (or an HTML body that owns its @page) the rest of the block
        // is hidden, and this input was left behind on its own, editing a value
        // nothing reads.
        return this.showEditPageLayoutFields && this.editTemplatePageMargins === 'Custom';
    }

    /**
     * A Canvas template has no file to replace — its body is authored on the canvas and
     * versioned by saving there. The upload widget was showing on every type, so a
     * Canvas template offered "Upload New Version" against a .docx filter.
     */
    get showEditFileUploadForType() {
        return this.showEditFileUpload && !this.isCanvasTemplate;
    }

    get isEditTypeHtml() {
        return this.editTemplateType === 'HTML';
    }

    get isEditTypePdf() {
        return this.editTemplateType === 'PDF';
    }

    // v1.90 — page-layout fields are dead inputs when the HTML body owns @page.
    // The engine ignores them and they only confuse authors, so hide them and
    // show an explanatory banner in their place.
    /**
     * A Canvas body ALWAYS carries its own @page rule — the canvas serializes one on
     * every save — so these fields are read by nothing. The editHtmlBodyOwnsPageRule
     * flag does not cover it: that is only raised when a body is uploaded or pasted in
     * this session, not when an existing template is opened, so a Canvas template
     * showed live-looking Page Size / Orientation / Margins controls that changed
     * nothing about the document.
     */
    get showEditPageLayoutFields() {
        return this.showPageOrientation && !this.editHtmlBodyOwnsPageRule && !this.isCanvasTemplate;
    }

    get showEditHtmlOwnsPageBanner() {
        return this.isEditTypeHtml && this.editHtmlBodyOwnsPageRule;
    }

    /** Says where page setup actually lives for a Canvas template. */
    get showEditCanvasPageBanner() {
        return this.isCanvasTemplate;
    }

    // --- Create Logic ---
    async createTemplate() {
        // #236 — fail with a cause the admin can act on, rather than letting UI API
        // flatten a restricted-picklist rejection into "An error occurred...".
        const preflight = this._preflightCreate();
        if (preflight) {
            this.showToast('Cannot create template', preflight, 'error', 'sticky');
            return;
        }
        const fields = {};
        fields[NAME_FIELD.fieldApiName] = this.newTemplateName;
        fields[CATEGORY_FIELD.fieldApiName] = this.newTemplateCategory;
        fields[TYPE_FIELD.fieldApiName] = this.newTemplateType;
        fields[OUTPUT_FORMAT_FIELD.fieldApiName] = this.newTemplateOutputFormat;
        // Page setup only meaningful for PDF output. v1.90 — skip for HTML
        // templates: their @page CSS owns page layout, and engine suppresses
        // template-level overrides when source @page is present. Saving the
        // create-wizard defaults would just leave conflicting values that
        // confuse later editors.
        if (
            this.newTemplateOutputFormat === 'PDF' &&
            (this.newTemplateType !== 'HTML' || this.newAuthoringMode === 'starter')
        ) {
            fields[PAGE_ORIENTATION_FIELD.fieldApiName] = this.newTemplatePageOrientation;
            fields[PAGE_SIZE_FIELD.fieldApiName] = this.newTemplatePageSize;
            fields[PAGE_MARGINS_FIELD.fieldApiName] = this.newTemplatePageMargins;
            if (this.newTemplatePageMargins === 'Custom') {
                fields[CUSTOM_MARGINS_FIELD.fieldApiName] = this.newTemplateCustomMargins;
            }
        }
        fields[BASE_OBJECT_FIELD.fieldApiName] = this.newTemplateObject;
        fields[QUERY_CONFIG_FIELD.fieldApiName] = this._sanitizeQueryConfig(this.newTemplateQuery);
        fields[DESC_FIELD.fieldApiName] = this.newTemplateDesc;
        if (this.newTemplateApiName) {
            const clash = (this.templates || []).find(
                (t) => (t[F.ApiName] || '').toLowerCase() === this.newTemplateApiName.toLowerCase()
            );
            if (clash) {
                this.showToast(
                    'API Name already in use',
                    `"${this.newTemplateApiName}" is already used by template "${clash.Name}". API Names must be unique.`,
                    'error'
                );
                return;
            }
            fields[F.ApiName] = this.newTemplateApiName;
        }
        if (this.newTemplateSampleRecordId) {
            fields[TEST_RECORD_FIELD.fieldApiName] = this.newTemplateSampleRecordId;
        }

        // Snapshot authoring-path inputs before resetForm() clears them — the
        // starter body is built and attached after the modal opens.
        const authoringMode = this.newAuthoringMode;
        // Snapshot the TYPE too. resetForm() runs before the starter body is attached
        // and puts newTemplateType back to 'Word', so reading it later reported the
        // wizard's default rather than the template just created — every starter wrote
        // the HTML body and none wrote the canvas one.
        const wantsCanvas = this.newTemplateType === 'Canvas';
        const starterKey = this.newStarterKey;
        const starterShape =
            authoringMode === 'starter' ? extractQueryShape(this.newTemplateQuery, this.newTemplateObject) : null;
        const aiPastedHtml = (this._aiPastedHtml || '').trim();
        this._aiPastedHtml = null;
        const chosenLogoTag = this._chosenLogoTag;

        try {
            const record = await createRecord({ apiName: DOCGEN_TEMPLATE_OBJECT.objectApiName, fields });
            this.createdTemplateId = record.id;
            this.isCreating = false;
            // Only the file path needs an upload prompt — every other mode
            // lands directly in the designer.
            if (authoringMode === 'file') {
                this.showToast('Success', 'Template Record created. Please upload your document.', 'success');
            }

            const newRow = {
                Id: record.id,
                Name: this.newTemplateName,
                [F.Category]: this.newTemplateCategory,
                [F.Type]: this.newTemplateType,
                [F.OutputFormat]: this.newTemplateOutputFormat,
                [F.PageOrientation]: this.newTemplatePageOrientation,
                [F.PageSize]: this.newTemplatePageSize,
                [F.PageMargins]: this.newTemplatePageMargins,
                [F.CustomMargins]: this.newTemplateCustomMargins,
                [F.BaseObject]: this.newTemplateObject,
                [F.Desc]: this.newTemplateDesc,
                // Must carry the API name into the edit modal — resetForm() clears the
                // wizard value, and an edit modal opened without it would post
                // API_Name__c: '' on the next save, wiping what createRecord just wrote.
                [F.ApiName]: this.newTemplateApiName || null,
                [F.QueryConfig]: this.newTemplateQuery,
                [F.TestRecordId]: this.newTemplateSampleRecordId || null,
                [F.DocTitleFormat]: null,
                ContentDocumentLinks: []
            };

            this.resetForm();
            await refreshApex(this.wiredTemplatesResult);

            this.activeMainTab = 'list';
            this.activeEditTab = 'document';
            await this.openEditModal(newRow, 'document');
            if (authoringMode === 'starter') {
                await this._ensureLogoAsset(record.id);
                await this._applyStarterBody(record.id, starterKey, starterShape, chosenLogoTag, wantsCanvas);
                // Land straight in the full-screen designer with the starter open.
                this.isEditModalOpen = false;
                await this._openDesignerSurface();
            } else if (authoringMode === 'ai') {
                await this._ensureLogoAsset(record.id);
                // AI path: the wizard's paste-back becomes the staged body; if
                // nothing was pasted, the designer opens ready for it.
                if (aiPastedHtml) {
                    await this._applyPastedBody(record.id, aiPastedHtml, newRow.Name);
                }
                this.isEditModalOpen = false;
                await this._openDesignerSurface();
            } else if (authoringMode === 'canvas') {
                // Seed one empty artboard so the canvas opens on a real page rather
                // than an empty void with nothing to drop onto.
                await this._applyPastedBody(record.id, buildBlankCanvasBody(), newRow.Name);
                this.isEditModalOpen = false;
                await this._openDesignerSurface();
            } else if (authoringMode === 'scratch') {
                // Blank page — the designer seeds a clean sheet to type into.
                this.isEditModalOpen = false;
                await this._openDesignerSurface();
            }
        } catch (error) {
            // #236 — surface the REAL cause. The generic UI API string told us nothing
            // across dozens of upgrade-failure reports; fieldErrors names the field.
            const detail = ldsErrorDetail(error);
            let hint = '';
            if (/RESTRICTED_PICKLIST|INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST/i.test(detail)) {
                hint =
                    ' — This org is missing a picklist value the package expects, which means the ' +
                    'upgrade did not fully apply its schema. Re-run the package upgrade.';
            } else if (
                /INSUFFICIENT_ACCESS|FIELD_INTEGRITY|not writeable|INVALID_FIELD_FOR_INSERT_UPDATE/i.test(detail)
            ) {
                hint = ' — Check that the Portwood Admin permission set is assigned to your user.';
            } else if (/DUPLICATE_VALUE/i.test(detail)) {
                hint = ' — The API Name is already used by another template. Change it and retry.';
            }
            this.showToast('Could not create template', detail + hint, 'error', 'sticky');
            // eslint-disable-next-line no-console
            console.error('Portwood createTemplate failed', error);
        }
    }

    /**
     * #236 — pre-flight the values we are about to write against what the org actually
     * has. A restricted-picklist rejection is otherwise indistinguishable from any other
     * DML failure once UI API has flattened it.
     *
     * Returns an error string, or null when the create looks safe to attempt.
     */
    _preflightCreate() {
        if (this._orgTypeValues && this._orgTypeValues.length && !this._orgTypeValues.includes(this.newTemplateType)) {
            return (
                `This org's Template Type picklist does not contain "${this.newTemplateType}"` +
                (TYPE_VALUE_HISTORY[this.newTemplateType]
                    ? ` (added in v${TYPE_VALUE_HISTORY[this.newTemplateType]})`
                    : '') +
                '. The package upgrade did not fully apply its schema. Re-run the upgrade, or pick one of: ' +
                this._orgTypeValues.join(', ')
            );
        }
        return null;
    }

    /**
     * Starter path: build the chosen design with the author's real merge
     * fields and attach it as the template body, so the very first "Save as
     * New Version" click produces a working v1 that renders on Generate.
     */
    async _applyStarterBody(templateId, starterKey, shape, logoTag, wantsCanvas) {
        try {
            // A Canvas template gets a CANVAS-native starter — boxes already placed,
            // each one draggable and editable with the tool that owns it. Running the
            // HTML starter through the importer instead would be lossless on content
            // but would land as a couple of large blocks: a page of prose is one text
            // box, and an authored table stays markup because reshaping an arbitrary
            // table into the table model was measured to drop merge tags. Right for
            // someone else's document; wrong for a starting point.
            let html = buildStarterHtml(starterKey, shape);
            // Starter bodies carry SIZED {%asset:logo:Nx} slots (144x header
            // logos, 120x on the agreement); an existing asset picked in the
            // wizard swaps its own merge tag in, inheriting the slot's size
            // when the chosen tag doesn't carry one.
            if (logoTag && logoTag !== '{%asset:logo}') {
                html = html.replace(/\{%asset:logo(:[^}]*)?\}/g, (m, size) => {
                    const chosenHasSize = /:\d/.test(logoTag);
                    return chosenHasSize || !size ? logoTag : logoTag.slice(0, -1) + size + '}';
                });
            }
            const fileName = (this.selectedStarterLabelFor(starterKey) || 'Starter').replace(/[^\w]+/g, '_') + '.html';
            // PUBLISHED as the active version, not left as a loose body CV.
            //
            // The canvas reads the active version's body — deliberately, so the editor
            // and the renderer look at the same bytes. A starter written only as a loose
            // CV is therefore invisible to it, and the author lands on a blank artboard
            // over a template that does have content. Publishing makes the thing just
            // written the thing that opens, and the thing that generates.
            const bodyResult = wantsCanvas
                ? await saveAndPublishHtmlBody({ templateId, fileName, htmlContent: html, newVersion: true })
                : await saveHtmlTemplateBody({ templateId, fileName, htmlContent: html });
            this.currentFileId = bodyResult.contentDocumentId;
            this.uploadedContentVersionId = bodyResult.contentVersionId;
            this.uploadedFileName = fileName;
            this._lastUploadedHtmlText = html;
            this.stagedBodySource = 'starter';
            this.htmlEditorDirty = false;
            // Starters declare @page — same handling as an uploaded body that owns it.
            this.editHtmlBodyOwnsPageRule = true;
            this.editTemplatePageOrientation = null;
            this.editTemplatePageSize = null;
            this.editTemplatePageMargins = null;
            this.editTemplateCustomMargins = '';
            // Land the author inside the HTML with the draft loaded.
            this.showHtmlBodyEditor = true;
            this._syncHtmlBodyEditorDom(html);
            this.showToast(
                'Starter design attached',
                'Review the HTML, then click "Save as New Version" to activate it. Download Sample shows it with real data.',
                'success'
            );
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Starter attach failed', msg, 'error');
        }
    }

    selectedStarterLabelFor(key) {
        const s = STARTERS.find((x) => x.key === key);
        return s ? s.label : '';
    }

    /**
     * AI path: the HTML pasted on the wizard's AI step becomes the staged
     * template body, so the designer opens on the finished document.
     */
    async _applyPastedBody(templateId, html, templateName) {
        try {
            const fileName = (templateName || 'AI_Template').replace(/[^\w]+/g, '_') + '.html';
            const bodyResult = await saveHtmlTemplateBody({ templateId, fileName, htmlContent: html });
            this.currentFileId = bodyResult.contentDocumentId;
            this.uploadedContentVersionId = bodyResult.contentVersionId;
            this.uploadedFileName = fileName;
            this._lastUploadedHtmlText = html;
            this.stagedBodySource = 'editor';
            this.htmlEditorDirty = false;
            if (/@page\b/i.test(html)) {
                this.editHtmlBodyOwnsPageRule = true;
                this.editTemplatePageOrientation = null;
                this.editTemplatePageSize = null;
                this.editTemplatePageMargins = null;
                this.editTemplateCustomMargins = '';
            }
            this.showHtmlBodyEditor = true;
            this._syncHtmlBodyEditorDom(html);
            this.showToast(
                'AI design attached',
                'Your pasted HTML is staged — review it, then "Save as New Version" activates it.',
                'success'
            );
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Paste attach failed', msg, 'error');
        }
    }

    // --- Row Action ---
    async handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;

        if (actionName === 'delete') {
            // Deleting used to happen on the click, with nothing in between. One
            // mis-aim in a six-item row menu destroyed a template permanently —
            // and the inconsistency made it stark, because deleting a VERSION
            // (far less destructive, and it refuses to touch the active one)
            // already confirms first.
            const confirmed = await LightningConfirm.open({
                message:
                    'Delete "' +
                    (row.Name || 'this template') +
                    '"? Its versions and generated-document history go with it. This cannot be undone.',
                label: 'Delete template',
                theme: 'error'
            });
            if (!confirmed) {
                return null;
            }
            try {
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                await deleteTemplate({ templateId: row.Id });
                this.showToast('Success', 'Template deleted', 'success');
                return refreshApex(this.wiredTemplatesResult);
            } catch (error) {
                this.showToast('Error deleting template', error.body ? error.body.message : error.message, 'error');
            }
        } else if (actionName === 'edit') {
            this.openEditModal(row, 'details');
        } else if (actionName === 'design') {
            // Canvas counts. openDesignerForRow already routes it to the canvas surface
            // rather than the legacy one — the gate here just never let it through, so
            // the row action on a Canvas template answered "Designer is for HTML
            // templates" about a template whose whole point is the designer.
            if (row[F.Type] === 'HTML' || row[F.Type] === 'Canvas') {
                this.openDesignerForRow(row);
            } else {
                this.showToast(
                    'Designer is for HTML templates',
                    row[F.Type] === 'Word'
                        ? 'Open Edit → Document & History → View Converted HTML to see exactly what the PDF engine renders from this Word file.'
                        : 'This template type is file-based — use Edit to manage its document.',
                    'info'
                );
            }
        } else if (actionName === 'view') {
            this.openEditModal(row, 'tags');
        } else if (actionName === 'clone') {
            this.handleCloneTemplate(row);
        } else if (actionName === 'export') {
            this.handleExportTemplate(row);
        }
    }

    async handleCloneTemplate(row) {
        try {
            this.showToast('Cloning', 'Cloning ' + row.Name + '…', 'info');
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            const newId = await cloneTemplate({ templateId: row.Id, newName: row.Name + ' (Copy)' });
            await refreshApex(this.wiredTemplatesResult);
            this.showToast(
                'Template cloned',
                'The copy starts Inactive so it stays out of pickers — rename it and flip it Active when ready.',
                'success'
            );
            const newRow = this.templates.find((t) => t.Id === newId);
            if (newRow) {
                this.openEditModal(newRow, 'details');
            }
        } catch (error) {
            this.showToast('Error cloning template', error.body ? error.body.message : error.message, 'error');
        }
    }

    async handleExportTemplate(row) {
        try {
            this.showToast('Exporting', 'Preparing ' + row.Name + '...', 'info');
            const jsonStr = await exportTemplate({ templateId: row.Id });
            // application/json is not on the LWS createObjectURL allowlist, so a
            // Blob URL is refused outright in an LWS-enabled org. A data: URI is.
            const a = document.createElement('a');
            a.href = 'data:application/json;charset=utf-8,' + encodeURIComponent(jsonStr);
            a.download = (row.Name || 'template').replace(/[^a-zA-Z0-9_-]/g, '_') + '.docgen.json';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
            this.showToast('Exported', row.Name + ' exported successfully', 'success');
        } catch (error) {
            this.showToast('Export Error', error.body ? error.body.message : error.message, 'error');
        }
    }

    handleImportClick() {
        this.template.querySelector('input[data-id="importFileInput"]').click();
    }

    async handleImportFile(event) {
        const file = event.target.files[0];
        if (!file) return;
        // Reset the input so the same file can be re-imported
        event.target.value = '';

        if (!file.name.endsWith('.json') && !file.name.endsWith('.docgen.json')) {
            this.showToast('Invalid File', 'Please select a .docgen.json file', 'error');
            return;
        }

        try {
            this.showToast('Importing', 'Importing ' + file.name + '...', 'info');
            const jsonStr = await file.text();
            // Basic validation
            const parsed = JSON.parse(jsonStr);
            if (!parsed.template || !parsed.docgenExportVersion) {
                this.showToast('Invalid File', 'This file is not a valid Portwood export.', 'error');
                return;
            }
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await importTemplate({ jsonData: jsonStr });
            this.showToast('Imported', (parsed.template.Name || 'Template') + ' imported successfully', 'success');
            return refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Import Error', error.body ? error.body.message : error.message, 'error');
        }
    }

    // --- Edit Modal ---
    /**
     * Light list row -> full record. A row that already has the heavy fields is
     * returned untouched, so this is safe to call from any path.
     */
    async _hydrateTemplateRow(row) {
        if (!row || !row.Id) {
            return row;
        }
        // Query_Config__c is on every full record and on no light one, so its
        // presence is the marker. `in` rather than a truthiness check: a template
        // with an empty config still has the key.
        if (F.QueryConfig in row) {
            return row;
        }
        try {
            return await getTemplateById({ templateId: row.Id });
        } catch (error) {
            const msg = error && error.body && error.body.message ? error.body.message : 'Could not load the template.';
            this.showToast('Error opening template', msg, 'error');
            return null;
        }
    }

    /**
     * Open a template for editing, fetching its full record first.
     *
     * The list only carries what the grid needs, so `row` here is a light record —
     * every heavy field (query config, header/footer HTML, signer config, page
     * setup, the attached document link) arrives with this fetch. Rows that are
     * already complete are passed straight through, so callers that hand over a
     * full record cost nothing.
     */
    async openEditModal(row, activeTab) {
        row = await this._hydrateTemplateRow(row);
        if (!row) {
            return;
        }
        try {
            this._editContext = true;
            this.editTemplateId = row.Id;
            // Findings belong to the body that was linted — a different template
            // must never see the previous one's report.
            this.lintFindings = [];
            this.editTemplateName = row.Name;
            this.editTemplateCategory = row[F.Category];
            this.editTemplateType = row[F.Type];
            this.editTemplateObject = row[F.BaseObject];
            this.editTemplateOutputFormat = row[F.OutputFormat] || 'Native';
            this.editTemplatePageOrientation = row[F.PageOrientation] || 'Portrait';
            this.editTemplatePageSize = row[F.PageSize] || 'Letter';
            this.editTemplatePageMargins = row[F.PageMargins] || 'Default';
            this.editTemplateCustomMargins = row[F.CustomMargins] || '';
            this.editTemplateDesc = row[F.Desc];
            // Pass the raw stored config to the visual builder. V3 JSON must
            // NOT be flattened to V1 SOQL here — V1 can't represent filtered
            // subsets (multiple subqueries against the same relationship), so
            // flattening would silently drop alias slots. The readable textarea
            // formats V3→V1 at display time via the readableEditQueryConfig getter.
            this.editTemplateQuery = row[F.QueryConfig];
            // #161 — load configured signer form fields from the dedicated
            // Form_Fields_Config__c field (independent of Query_Config__c).
            this.editFormFieldsConfig = row[F.FormFieldsConfig] || '';
            this._hydrateSignerFields();
            // Auto-detect v4 (Apex Data Provider) bindings so admins re-opening
            // a provider-backed template land in the right mode immediately.
            this.editUseApexProvider = false;
            this._clearApexProviderState();
            this.editUseVisualBuilder = false;
            try {
                const cfg = row[F.QueryConfig] ? JSON.parse(row[F.QueryConfig]) : null;
                if (cfg && cfg.v === 4 && cfg.provider) {
                    this.editUseApexProvider = true;
                    this.editUseVisualBuilder = false;
                    this._validateAndLoadProviderFields(cfg.provider);
                } else if (cfg && cfg.v === 3) {
                    // Tree-built config: open the visual builder directly —
                    // raw V3 JSON in the manual box helps no one.
                    this.editUseVisualBuilder = true;
                }
            } catch (e) {
                /* not JSON — manual or v1 */
            }
            this.editTemplateTestRecordId = row[F.TestRecordId];
            this.editTemplateTitleFormat = row[F.DocTitleFormat];
            // F.IsActive may be undefined on records created before the field shipped;
            // treat null/undefined as Active to match the server-side OR-NULL filter.
            this.editTemplateIsActive = row[F.IsActive] !== false;
            this.editTemplateIsDefault = row[F.IsDefault] || false;
            this.editTemplateSortOrder = row[F.SortOrder];
            this.editTemplateLockOutputFormat = row[F.LockOutputFormat] || false;
            this.editTemplateSignerVerification = row[F.SignerVerification] || 'Inherit';
            this.editTemplatePrefillSignerEmail = row[F.PrefillSignerEmail] || 'Inherit';
            this.editTemplateShowDecline = row[F.ShowSignerDecline] === true;
            this.editTemplateApiName = row[F.ApiName] || '';
            this.editTemplateDefaultEmailMessage = row[F.DefaultEmailMessage] || '';
            this.editTemplateSpecificRecordIds = row[F.SpecificRecordIds];
            this.editTemplateRequiredPermissionSets = row[F.RequiredPermSets];
            this.editTemplateRecordFilter = row[F.RecordFilter];
            this.editTemplateRecordFilterResult = '';
            this.editTemplateRecordFilterResultMessage = '';
            this.editTemplateHeaderHtml = row[F.HeaderHtml] || '';
            this.editTemplateFooterHtml = row[F.FooterHtml] || '';
            this.uploadedPdfAcroFormSnapshot = null;
            this.pdfAcroFormSnapshotVersionId = null;
            this.isPdfAcroFormSnapshotLoaded = false;
            this.uploadedPdfAcroFormSnapshotJson = null;
            // Clear any body uploaded for a previously-opened template but never
            // saved — otherwise "Save as New Version" on THIS template silently
            // adopts the other template's file as its body.
            this.uploadedContentVersionId = null;
            this.uploadedFileName = '';
            this.uploadedPdfAcroFormNormalizedBase64 = null;
            // Same staleness trap: the @page-ownership flag belongs to whatever
            // HTML body was last uploaded, not to this template.
            this.editHtmlBodyOwnsPageRule = false;
            // HTML body editor state is per-template too.
            this.showHtmlBodyEditor = false;
            this._lastUploadedHtmlText = null;
            this.isLoadingHtmlBody = false;
            this.isApplyingHtmlBody = false;
            this.stagedBodySource = null;
            this.htmlEditorDirty = false;
            this.showDocxHtmlViewer = false;
            this.docxSnapshotInfo = null;
            this.isLoadingDocxHtml = false;
            this.isSwitchingToHtml = false;
            this.showDocxHtmlPreview = false;
            this.showImagePanel = false;
            this.templateImages = [];
            this.showTagPanel = false;
            this.showHtmlBodyVisual = false;
            this._visualOriginalCode = null;
            this._visualEnteredDom = null;

            let cdLinks = [];
            if (row.ContentDocumentLinks) {
                if (Array.isArray(row.ContentDocumentLinks)) {
                    cdLinks = row.ContentDocumentLinks;
                } else if (row.ContentDocumentLinks.records) {
                    cdLinks = row.ContentDocumentLinks.records;
                }
            }

            if (cdLinks && cdLinks.length > 0) {
                this.currentFileId = cdLinks[0].ContentDocumentId;
            } else {
                this.currentFileId = null;
            }

            if (!this.currentFileId) {
                this.activeEditTab = 'document';
            } else {
                this.activeEditTab = activeTab || 'details';
            }

            this.loadVersions(row.Id);
            if (row[F.Type] === 'PDF') {
                this.loadPdfAcroFormMapping();
            }
            this.isCreating = false;
            this.isEditModalOpen = true;
            this._editContext = true;
            // Baseline for the unsaved-changes warning on close. Taken here, after
            // every field above has been populated from the record, so the very
            // act of opening the modal never counts as an edit.
            this._editSnapshot = this._editFieldSignature();
            this._loadObjectMetadata(this.editTemplateObject);
            // Initialize query tree + sync textarea after DOM renders
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this._updateQueryTree();
                this._loadSampleData();
                // Native textarea doesn't reliably pick up value from LWC reactivity — set DOM directly
                const ta = this.template.querySelector('.edit-query-textarea');
                if (ta && this.editTemplateQuery) {
                    ta.value = this.editTemplateQuery;
                }
            }, 300);
        } catch (e) {
            this.showToast('Error', 'Failed to open modal: ' + e.message, 'error');
        }
    }

    /**
     * A signature of everything the edit modal can change.
     *
     * Snapshotted when the modal opens and compared when the user asks to close,
     * so "you have unsaved changes" is a fact rather than a guess. Cheap: a dozen
     * scalars stringified, computed twice per modal session.
     */
    _editFieldSignature() {
        return JSON.stringify([
            this.editTemplateName,
            this.editTemplateCategory,
            this.editTemplateType,
            this.editTemplateObject,
            this.editTemplateOutputFormat,
            this.editTemplateDesc,
            this.editTemplateQuery,
            this.editFormFieldsConfig,
            this.editTemplateTestRecordId,
            this.editTemplateTitleFormat,
            this.editTemplateIsActive,
            this.editTemplateIsDefault,
            this.editTemplateSortOrder,
            this.editTemplateLockOutputFormat,
            this.editTemplateSpecificRecordIds,
            this.editTemplateRequiredPermissionSets,
            this.editTemplateRecordFilter,
            this.editTemplateHeaderHtml,
            this.editTemplateFooterHtml,
            this.editTemplatePageOrientation,
            this.editTemplatePageSize,
            this.editTemplatePageMargins,
            this.editTemplateCustomMargins,
            this.editTemplateSignerVerification,
            this.editTemplatePrefillSignerEmail,
            this.editTemplateShowDecline,
            this.editTemplateApiName,
            this.editTemplateDefaultEmailMessage
        ]);
    }

    /**
     * The USER asking to close. Warns before discarding edits.
     *
     * Closing used to bin everything typed across eight tabs with no warning at
     * all — the modal simply set isEditModalOpen = false. Someone could retype a
     * query config, click the X, and watch it evaporate silently.
     *
     * Separate from closeEditModal() on purpose: internal callers close the modal
     * AFTER saving, and prompting them would be nonsense.
     */
    async handleCloseEditModal() {
        if (this._editSnapshot != null && this._editFieldSignature() !== this._editSnapshot) {
            const discard = await LightningConfirm.open({
                message: 'You have unsaved changes to this template. Close and discard them?',
                label: 'Discard changes?',
                theme: 'warning'
            });
            if (!discard) {
                return;
            }
        }
        this.closeEditModal();
    }
    _editSnapshot = null;

    closeEditModal() {
        this._editSnapshot = null;
        this.isEditModalOpen = false;
        this._editContext = false;
        this.queryTreeNodes = [];
        this.sampleRecordData = null;
        this.showSuggestions = false;
        this.editUseApexProvider = false;
        this._clearApexProviderState();
    }

    // --- Versions Logic ---
    get hasVersions() {
        return this.versions && this.versions.length > 0;
    }

    get currentVersionLabel() {
        if (this.hasVersions) {
            return this.versions[0].VersionNumber;
        }
        return '';
    }

    loadVersions(templateId) {
        getTemplateVersions({ templateId })
            .then((data) => {
                if (!data) {
                    this.versions = [];
                    this.editTemplateWatermarkCvId = null;
                    return;
                }
                this.versions = data.map((v) => {
                    const isActive = v[F.VerIsActive];
                    return {
                        ...v,
                        // Show the real version record name (e.g. V-0024), not a synthetic index.
                        VersionNumber: v.Name,
                        CreatedByName: v.CreatedBy ? v.CreatedBy.Name : '',
                        isActiveLabel: isActive ? '✓' : '',
                        activeClass: isActive ? 'slds-text-color_success slds-text-title_bold' : '',
                        activateVariant: isActive ? 'neutral' : 'brand',
                        // Namespace-safe disable flag for the Activate/Delete buttons —
                        // raw 'Is_Active__c' keys don't exist on subscriber-org rows
                        // (they're portwoodglobal__-prefixed there).
                        disableAction: !!isActive,
                        bodyCvId: v[F.VerCvId] || '',
                        bodyCvFileName: ''
                    };
                });
                // Sync watermark CV from the active version so the tab shows current state
                const active = data.find((v) => v[F.VerIsActive]);
                this.editTemplateWatermarkCvId = active ? active[F.VerWatermarkCv] || null : null;

                // Enrich with the body ContentVersion's number + filename so the table
                // shows which underlying file each version points at (diagnostic).
                const cvIds = data.map((v) => v[F.VerCvId]).filter(Boolean);
                if (cvIds.length) {
                    getVersionBodyFileInfo({ contentVersionIds: cvIds })
                        .then((info) => {
                            if (!info) {
                                return;
                            }
                            this.versions = this.versions.map((row) => {
                                const meta = info[row[F.VerCvId]];
                                return meta ? { ...row, bodyCvFileName: meta.fileName } : row;
                            });
                        })
                        .catch(() => {
                            // Non-fatal — leave the file columns blank if the lookup fails.
                        });
                }
            })
            .catch(() => {
                this.versions = [];
                this.editTemplateWatermarkCvId = null;
            });
    }

    async handleRestoreVersion(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        if (action === 'restore') {
            try {
                this.isLoadingVersions = true;
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                await activateVersion({ versionId: row.Id });

                this.showToast('Success', 'Version activated.', 'success');

                this.editTemplateQuery = row[F.QueryConfig]; // raw — preserves V3 alias slots
                this.editTemplateCategory = row[F.Category];
                this.editTemplateDesc = row[F.Desc];
                this.editTemplateType = row[F.Type];

                this.loadVersions(this.editTemplateId);
                refreshApex(this.wiredTemplatesResult);
            } catch (error) {
                this.showToast('Error activating version', error.body ? error.body.message : error.message, 'error');
            } finally {
                this.isLoadingVersions = false;
            }
        } else if (action === 'preview') {
            this.handlePreviewVersion(row);
        } else if (action === 'deleteVersion') {
            await this.handleDeleteVersion(row);
        }
    }

    // Issue #83 — Confirm with the user, then delete a non-active version and
    // its associated CVs. The Apex endpoint refuses to delete the active version
    // as a safety guard; the UI also disables the button on the active row.
    async handleDeleteVersion(row) {
        const verName = row.Name || 'this version';
        const ok = window.confirm(
            'Delete ' +
                verName +
                '?\n\n' +
                'This removes the version record AND its template body file plus pre-decomposed parts. ' +
                'Cannot be undone. Activate a different version first if this one is currently active.'
        );
        if (!ok) return;
        try {
            this.isLoadingVersions = true;
            await deleteTemplateVersion({ versionId: row.Id });
            this.showToast('Success', verName + ' deleted.', 'success');
            this.loadVersions(this.editTemplateId);
            refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Error deleting version', error.body ? error.body.message : error.message, 'error');
        } finally {
            this.isLoadingVersions = false;
        }
    }

    handlePreviewVersion(row) {
        this.previewVersion = row;
        this.isGeneratingPreview = false;
        this.isPreviewModalOpen = true;
    }

    closePreviewModal() {
        this.isPreviewModalOpen = false;
        this.isGeneratingPreview = false;
    }

    handleRestoreFromPreview() {
        const event = {
            detail: {
                action: { name: 'restore' },
                row: this.previewVersion
            }
        };
        this.handleRestoreVersion(event);
        this.closePreviewModal();
    }

    // --- Version Preview Helpers ---

    @track isGeneratingPreview = false;

    get isPreviewVersionActive() {
        return this.previewVersion?.[F.VerIsActive] || false;
    }

    // Namespace-aware truthy check — F.QueryConfig resolves to the namespaced
    // field name in subscriber orgs (e.g. portwoodglobal__Query_Config__c), so
    // the modal must read via this getter rather than `previewVersion.Query_Config__c`.
    get hasPreviewVersionQuery() {
        const v = this.previewVersion?.[F.QueryConfig];
        return typeof v === 'string' && v.trim().length > 0;
    }

    get previewVersionQueryFormatted() {
        const raw = this.previewVersion?.[F.QueryConfig];
        if (!raw) return '';
        // Reuse the main edit UI's V1/V2/V3-aware formatter so V3 JSON trees
        // render as readable SOQL-ish text instead of one giant JSON blob.
        const flattened = this._formatQueryConfig(raw);
        // Apply the same comma/parens line-break sweetening for readability.
        let depth = 0;
        let formatted = '';
        for (let i = 0; i < flattened.length; i++) {
            const ch = flattened[i];
            if (ch === '(') {
                depth++;
                formatted += '\n  (';
            } else if (ch === ')') {
                depth--;
                formatted += ')';
            } else if (ch === ',' && depth === 0) {
                formatted += ',\n';
            } else {
                formatted += ch;
            }
        }
        return formatted.trim();
    }

    get previewGenerateDisabled() {
        return !this.previewVersion?.[F.VerCvId] || !this.editTemplateTestRecordId || this.isGeneratingPreview;
    }

    handlePreviewDownload() {
        const cvId = this.previewVersion?.[F.VerCvId];
        if (cvId) {
            this[NavigationMixin.Navigate](
                {
                    type: 'standard__webPage',
                    attributes: {
                        url: `/sfc/servlet.shepherd/version/download/${cvId}`
                    }
                },
                false
            );
        }
    }

    async handlePreviewGenerate() {
        if (!this.previewVersion?.[F.VerCvId] || !this.editTemplateTestRecordId) {
            this.showToast('Warning', 'Template file and test record are required.', 'warning');
            return;
        }

        this.isGeneratingPreview = true;

        try {
            // Activate this version first so generation uses its file and config
            if (!this.previewVersion[F.VerIsActive]) {
                // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
                await activateVersion({ versionId: this.previewVersion.Id });
                // Sync version config to local edit state
                this.editTemplateQuery = this.previewVersion[F.QueryConfig]; // raw — preserves V3 alias slots
                this.editTemplateCategory = this.previewVersion[F.Category];
                this.editTemplateDesc = this.previewVersion[F.Desc];
                this.editTemplateType = this.previewVersion[F.Type];
                this.loadVersions(this.editTemplateId);
                refreshApex(this.wiredTemplatesResult);
            }

            const previewTemplateType = this.previewVersion[F.Type] || this.editTemplateType;
            const isPPT = ['PowerPoint', 'PPT', 'PPTX'].includes(previewTemplateType);

            if (isPPT || this.editTemplateOutputFormat === 'Native') {
                let result;
                const chartContext = await this._prepareChartsForAdmin(
                    this.editTemplateId,
                    this.editTemplateTestRecordId
                );
                try {
                    result = await this._generateOfficeSample(
                        this.editTemplateId,
                        this.editTemplateTestRecordId,
                        chartContext
                    );
                } finally {
                    await this._cleanupChartsForAdmin(chartContext.cvIds);
                }
                if (!result || !result.base64) {
                    throw new Error('Document generation returned empty result.');
                }
                const docTitle = 'Preview_' + this.previewVersion.VersionNumber + '_' + (result.title || 'Document');
                const ext = this._officeExtensionForType(previewTemplateType, result.isMacroEnabled);
                this.downloadBase64(result.base64, docTitle + ext, 'application/octet-stream');
                this.showToast(
                    'Success',
                    'Sample document generated for ' + this.previewVersion.VersionNumber,
                    'success'
                );
            } else {
                this.showToast(
                    'Info',
                    'Generating PDF sample for ' + this.previewVersion.VersionNumber + '...',
                    'info'
                );
                let pdfResult;
                if (this._isPdfTemplateType(previewTemplateType)) {
                    pdfResult = await this._generatePdfAcroFormSample(
                        this.editTemplateId,
                        this.editTemplateTestRecordId
                    );
                } else {
                    const chartContext = await this._prepareChartsForAdmin(
                        this.editTemplateId,
                        this.editTemplateTestRecordId
                    );
                    try {
                        pdfResult = await generatePdf({
                            templateId: this.editTemplateId,
                            recordId: this.editTemplateTestRecordId,
                            saveToRecord: false,
                            chartCvMap: chartContext.map,
                            chartBucketMap: chartContext.bucketMap || null
                        });
                    } finally {
                        await this._cleanupChartsForAdmin(chartContext.cvIds);
                    }
                }
                if (!pdfResult || !pdfResult.base64) {
                    throw new Error('PDF generation returned empty result.');
                }
                const pdfTitle = 'Preview_' + this.previewVersion.VersionNumber + '_' + (pdfResult.title || 'Document');
                this.downloadBase64(pdfResult.base64, pdfTitle + '.pdf', 'application/pdf');
                this.showToast('Success', 'PDF sample generated for ' + this.previewVersion.VersionNumber, 'success');
            }
        } catch (error) {
            let msg = 'Unknown error';
            if (error.body && error.body.message) msg = error.body.message;
            else if (error.message) msg = error.message;
            this.showToast('Generation Failed', msg, 'error');
        } finally {
            this.isGeneratingPreview = false;
        }
    }

    // --- Save Logic ---
    async handleSaveOnly() {
        if (!this.editTemplateName || !this.editTemplateType) {
            this.showToast('Error', 'Name and Type are required.', 'error');
            return;
        }
        // #203 — a details-only save does NOT attach a freshly-uploaded body.
        // Say so, loudly, instead of letting the admin believe the new file is
        // live while generation keeps serving the previous version.
        if (this.uploadedContentVersionId) {
            this.showToast(
                'Uploaded file not saved yet',
                'Your uploaded document is not included in a details-only save. Click "Save as New Version" to make it the active body — until then, documents still generate from the previous file.',
                'warning'
            );
        }

        const fields = {
            Id: this.editTemplateId,
            Name: this.editTemplateName,
            Category__c: this.editTemplateCategory,
            Type__c: this.editTemplateType,
            Output_Format__c: this.editTemplateOutputFormat,
            Base_Object_API__c: this.editTemplateObject,
            Description__c: this.editTemplateDesc,
            Query_Config__c: this._sanitizeQueryConfig(this.editTemplateQuery),
            // #161 — Signer Inputs form-field config (dedicated field, not Query_Config__c).
            Form_Fields_Config__c: this.editFormFieldsConfig,
            Test_Record_Id__c: this.editTemplateTestRecordId,
            Document_Title_Format__c: this.editTemplateTitleFormat,
            Is_Active__c: this.editTemplateIsActive,
            Is_Default__c: this.editTemplateIsDefault,
            Sort_Order__c: this.editTemplateSortOrder,
            Lock_Output_Format__c: this.editTemplateLockOutputFormat,
            Specific_Record_Ids__c: this.editTemplateSpecificRecordIds,
            Required_Permission_Sets__c: this.editTemplateRequiredPermissionSets,
            Record_Filter__c: this.editTemplateRecordFilter,
            Header_Html__c: this.editTemplateHeaderHtml,
            Footer_Html__c: this.editTemplateFooterHtml,
            Page_Orientation__c: this.editTemplatePageOrientation,
            Page_Size__c: this.editTemplatePageSize,
            Page_Margins__c: this.editTemplatePageMargins,
            Custom_Margins__c: this.editTemplateCustomMargins,
            Signer_Verification__c: this.editTemplateSignerVerification,
            Prefill_Signer_Email__c: this.editTemplatePrefillSignerEmail,
            Show_Signer_Decline__c: this.editTemplateShowDecline,
            API_Name__c: this.editTemplateApiName,
            Default_Email_Message__c: this.editTemplateDefaultEmailMessage
        };
        this.editTemplateQuery = fields['Query_Config__c'];

        try {
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            await saveTemplate({ fields: fields, createVersion: false, contentVersionId: null });
            this.showToast('Success', 'Template Details saved.', 'success');
            return refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Error saving template', error.body ? error.body.message : error.message, 'error');
        }
    }

    async handleSaveAndClose() {
        if (!this.editTemplateName || !this.editTemplateType) {
            this.showToast('Error', 'Name and Type are required.', 'error');
            return;
        }
        // Designer: unapplied visual/source edits fold into the staged body
        // automatically — "Save as New Version" saves what you're looking at,
        // no separate Apply click required. The dirty FLAG is advisory only:
        // the decision is a CONTENT comparison against the last staged body,
        // so a missed input event can never silently drop edits (the
        // "saved successfully but changes gone on reload" class of report).
        if (this.activeMainTab === 'design' && this.editTemplateType === 'HTML') {
            const draft = (this._currentDraftHtml() || '').trim();
            const lastStaged = (this._lastUploadedHtmlText || '').trim();
            // Whitespace-insensitive: serialize/pretty-print round-trips shift
            // formatting without changing the document.
            const norm = (x) => x.replace(/>\s+</g, '><').replace(/\s+/g, ' ').trim();
            if (draft && (this.htmlEditorDirty || norm(draft) !== norm(lastStaged))) {
                try {
                    const base = (this.uploadedFileName || 'template.html').replace(/\.(html?|zip)$/i, '');
                    await this._processAndSaveHtmlBody(this.editTemplateId, draft, base + '.html', null, 'editor');
                    this.htmlEditorDirty = false;
                } catch (err) {
                    const msg =
                        err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
                    this.showToast('Could not stage your edits', msg, 'error');
                    return;
                }
            }
        }

        const fields = {
            Id: this.editTemplateId,
            Name: this.editTemplateName,
            Category__c: this.editTemplateCategory,
            Type__c: this.editTemplateType,
            Output_Format__c: this.editTemplateOutputFormat,
            Base_Object_API__c: this.editTemplateObject,
            Description__c: this.editTemplateDesc,
            Query_Config__c: this._sanitizeQueryConfig(this.editTemplateQuery),
            // #161 — Signer Inputs form-field config (dedicated field, not Query_Config__c).
            Form_Fields_Config__c: this.editFormFieldsConfig,
            Test_Record_Id__c: this.editTemplateTestRecordId,
            Document_Title_Format__c: this.editTemplateTitleFormat,
            Is_Active__c: this.editTemplateIsActive,
            Is_Default__c: this.editTemplateIsDefault,
            Sort_Order__c: this.editTemplateSortOrder,
            Lock_Output_Format__c: this.editTemplateLockOutputFormat,
            Specific_Record_Ids__c: this.editTemplateSpecificRecordIds,
            Required_Permission_Sets__c: this.editTemplateRequiredPermissionSets,
            Record_Filter__c: this.editTemplateRecordFilter,
            Header_Html__c: this.editTemplateHeaderHtml,
            Footer_Html__c: this.editTemplateFooterHtml,
            Page_Orientation__c: this.editTemplatePageOrientation,
            Page_Size__c: this.editTemplatePageSize,
            Page_Margins__c: this.editTemplatePageMargins,
            Custom_Margins__c: this.editTemplateCustomMargins,
            Signer_Verification__c: this.editTemplateSignerVerification,
            Prefill_Signer_Email__c: this.editTemplatePrefillSignerEmail,
            Show_Signer_Decline__c: this.editTemplateShowDecline,
            API_Name__c: this.editTemplateApiName,
            Default_Email_Message__c: this.editTemplateDefaultEmailMessage
        };
        this.editTemplateQuery = fields['Query_Config__c'];

        try {
            this._syncPdfAcroFormSnapshotJson();
            const savedPdfSnapshotJson = this.uploadedPdfAcroFormSnapshotJson;
            const templateBodyContentVersionId = this.uploadedContentVersionId;
            // CxSAST: CSRF protection handled by Salesforce Aura/LWC framework
            const saveResult = await saveTemplate({
                fields: fields,
                createVersion: true,
                contentVersionId: templateBodyContentVersionId
            });
            const versionId = saveResult && saveResult.createdVersionId ? saveResult.createdVersionId : null;
            // #272 fidelity report for Word/PowerPoint uploads: the linter's
            // warnings ride the saveTemplate response (same contract as the HTML
            // path's saveHtmlTemplateBody). Advisory only — the version is already
            // stored, nothing was blocked. Render into the SAME panel the HTML
            // report uses.
            this.lintFindings = [];
            if (saveResult && Array.isArray(saveResult.warnings) && saveResult.warnings.length > 0) {
                this.lintFindings = this._mapLintFindings(saveResult.warnings);
                this._toastLintFindings();
            }
            if (versionId && savedPdfSnapshotJson) {
                await savePdfAcroFormSnapshot({
                    templateId: this.editTemplateId,
                    versionId,
                    snapshotJson: savedPdfSnapshotJson
                });
            }
            if (
                versionId &&
                this.editTemplateType === 'PDF' &&
                (this.uploadedPdfAcroFormNormalizedBase64 || templateBodyContentVersionId)
            ) {
                await this._queuePdfAcroFormPreparedBody(versionId, templateBodyContentVersionId);
            }
            if (templateBodyContentVersionId) {
                this.showToast('Success', 'New version saved. You can now Generate to test it.', 'success');
            } else if (this.activeMainTab === 'design') {
                // Designer saves auto-stage any edits before reaching here, so
                // "no new file" simply means the body didn't change — say so
                // calmly instead of the sticky re-upload warning (that warning
                // is for the file-upload modal where a stale body surprises).
                this.showToast(
                    'Saved',
                    'Version saved — the document body is unchanged from the previous version.',
                    'success'
                );
            } else {
                // Carry-forward warning (builds on #176's Version History diagnostics):
                // a new version saved WITHOUT re-uploading a body file reuses the prior
                // version's body ContentVersion. That's fine for metadata-only changes,
                // but it surprises authors who edited the document itself — e.g. added
                // {@Signature_…} tags — and expected it to take effect (the "No Signature
                // Placements Found" / stale-body reports). Sticky so it isn't missed.
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Saved — but the body file was reused',
                        message:
                            'This new version kept the PREVIOUS document body because no new file was uploaded. ' +
                            'If you changed the document itself — text, layout, or signature tags — re-upload the ' +
                            "file and save again, or your change won't appear when you generate. Metadata-only " +
                            'changes (name, mapping, title format, page setup) are saved correctly as-is.',
                        variant: 'warning',
                        mode: 'sticky'
                    })
                );
            }
            // Don't close the modal — authors want to immediately test/preview
            // the new version. Clear the just-uploaded CV reference so a follow-up
            // save doesn't double-attach the same file, refresh the version list,
            // and keep PDF authors on the mapping tab so the saved fields remain in view.
            this.uploadedContentVersionId = null;
            this._resetEditFileUploadWidget();
            if (this.editTemplateType === 'PDF' && versionId && savedPdfSnapshotJson) {
                this.pdfAcroFormSnapshotVersionId = versionId;
                this.isPdfAcroFormSnapshotLoaded = true;
                await this.loadPdfAcroFormMapping();
            } else {
                this.uploadedPdfAcroFormSnapshot = null;
                this.uploadedPdfAcroFormSnapshotJson = null;
            }
            if (this.editTemplateId) {
                this.loadVersions(this.editTemplateId);
            }
            this.activeEditTab = this.editTemplateType === 'PDF' ? 'pdfFields' : 'document';
            return refreshApex(this.wiredTemplatesResult);
        } catch (error) {
            this.showToast('Error saving template', error.body ? error.body.message : error.message, 'error');
        }
    }

    // --- Document Generation & Test Logic ---
    get editTemplateTestRecordIdEmpty() {
        return !this.editTemplateTestRecordId;
    }

    get editGenerateSampleDisabled() {
        return (
            !this.editTemplateTestRecordId ||
            this.isLoadingVersions ||
            this.isGeneratingPreview ||
            this.isPreparingPdfAcroFormBody
        );
    }

    get isRealObject() {
        return this.editTemplateObject && this.editTemplateObject !== 'ApexProvider';
    }

    handlePdfAcroFormSearchChange(event) {
        this.pdfAcroFormSearchTerm = event.target.value || '';
    }

    handlePdfAcroFormFilterChange(event) {
        this.pdfAcroFormFilter = event.detail.value || 'all';
    }

    async handleTestGenerate() {
        if (!this.editTemplateTestRecordId) {
            this.showToast('Warning', 'Please select a Test Record ID first.', 'warning');
            return;
        }

        // Auto-heal sample query config
        if (
            this.editTemplateName === 'Sample Quote Template' &&
            this.editTemplateQuery &&
            !this.editTemplateQuery.toLowerCase().includes('quotelineitems')
        ) {
            this.editTemplateQuery +=
                ', (SELECT Product2.Name, Description, Quantity, UnitPrice, TotalPrice FROM QuoteLineItems)';
        }

        // Save first
        await this.handleSaveOnly();

        this.isLoadingVersions = true;

        try {
            const isPPT = ['PowerPoint', 'PPT', 'PPTX'].includes(this.editTemplateType);

            if (isPPT || this.editTemplateOutputFormat === 'Native') {
                // Native DOCX/PPTX download
                let result;
                const chartContext = await this._prepareChartsForAdmin(
                    this.editTemplateId,
                    this.editTemplateTestRecordId
                );
                try {
                    result = await this._generateOfficeSample(
                        this.editTemplateId,
                        this.editTemplateTestRecordId,
                        chartContext
                    );
                } finally {
                    await this._cleanupChartsForAdmin(chartContext.cvIds);
                }

                if (!result || !result.base64) {
                    throw new Error('Document generation returned empty result.');
                }

                const docTitle = 'Sample_' + (result.title || 'Document');
                const ext = this._officeExtensionForType(this.editTemplateType, result.isMacroEnabled);
                this.downloadBase64(result.base64, docTitle + ext, 'application/octet-stream');
                this.showToast('Success', 'Sample Document Downloaded', 'success');
            } else {
                // PDF generation — same path as bulk
                this.showToast('Info', 'Generating PDF Sample...', 'info');
                let pdfResult;
                if (this._isPdfTemplateType(this.editTemplateType)) {
                    pdfResult = await this._generatePdfAcroFormSample(
                        this.editTemplateId,
                        this.editTemplateTestRecordId
                    );
                } else {
                    const chartContext = await this._prepareChartsForAdmin(
                        this.editTemplateId,
                        this.editTemplateTestRecordId
                    );
                    try {
                        pdfResult = await generatePdf({
                            templateId: this.editTemplateId,
                            recordId: this.editTemplateTestRecordId,
                            saveToRecord: false,
                            chartCvMap: chartContext.map,
                            chartBucketMap: chartContext.bucketMap || null
                        });
                    } finally {
                        await this._cleanupChartsForAdmin(chartContext.cvIds);
                    }
                }

                if (!pdfResult || !pdfResult.base64) {
                    throw new Error('PDF generation returned empty result.');
                }
                const pdfTitle = 'Sample_' + (pdfResult.title || 'Document');
                this.downloadBase64(pdfResult.base64, pdfTitle + '.pdf', 'application/pdf');
                this.showToast('Success', 'PDF Sample Generated', 'success');
            }
        } catch (error) {
            let msg = 'Unknown error';
            if (error.body && error.body.message) {
                msg = error.body.message;
            } else if (error.message) {
                msg = error.message;
            }
            this.showToast('Generation Failed', 'Generation Failed. ' + msg, 'error');
        } finally {
            this.isLoadingVersions = false;
        }
    }

    async _generatePdfAcroFormSample(templateId, recordId) {
        const snapshotResult = await getActivePdfAcroFormSnapshot({ templateId });
        const snapshotJson = snapshotResult && snapshotResult.snapshotJson;
        if (!snapshotJson) {
            throw new Error('PDF AcroForm mapping snapshot is missing. Save the fillable field mapping first.');
        }

        const requestedAt = new Date().toISOString();
        const jobId = await generatePdfAsync({ templateId, recordId });
        this.showToast('PDF generation queued', 'Building the sample PDF server-side...', 'info');
        const result = await this._waitForPdfSampleGeneration(jobId, recordId, requestedAt);
        if (!result || !result.contentVersionId) {
            throw new Error('PDF generation completed, but no generated file was found on the sample record.');
        }
        const base64 = await getContentVersionBase64({ contentVersionId: result.contentVersionId });
        return { base64, title: result.title || 'Document' };
    }

    async _waitForPdfSampleGeneration(jobId, recordId, requestedAt) {
        const maxAttempts = 40;
        for (let attempt = 0; attempt < maxAttempts; attempt++) {
            // eslint-disable-next-line no-await-in-loop
            const result = await getPdfSampleGenerationStatus({
                jobId,
                recordId,
                requestedAt
            });
            if (result && result.jobStatus === 'Failed') {
                throw new Error(result.extendedStatus || 'Server-side PDF generation failed.');
            }
            if (result && result.jobStatus === 'Aborted') {
                throw new Error(result.extendedStatus || 'Server-side PDF generation was aborted.');
            }
            if (result && result.contentVersionId) {
                return result;
            }
            // eslint-disable-next-line no-await-in-loop
            await new Promise((resolve) => setTimeout(resolve, 1500));
        }
        throw new Error('PDF generation is still running. Try Download Sample again in a moment.');
    }

    async _queuePdfAcroFormPreparedBody(versionId, sourceContentVersionId) {
        let base64 = this.uploadedPdfAcroFormNormalizedBase64;
        if (!versionId) {
            return;
        }
        if (!base64 && !sourceContentVersionId) {
            return;
        }
        this.isPreparingPdfAcroFormBody = true;
        this.pdfAcroFormPreparationText = 'Preparing PDF for server-side generation...';
        try {
            if (!base64 && sourceContentVersionId) {
                this.pdfAcroFormPreparationText = 'Rebuilding server-ready PDF body...';
                const uploadedBase64 = await getContentVersionBase64({
                    contentVersionId: sourceContentVersionId
                });
                const snapshot = await decomposePdfAcroFormBase64(uploadedBase64);
                if (snapshot.requiresNormalizedPdf && !snapshot.normalizedPdfBase64) {
                    throw new Error('PDF requires a normalized server-ready body, but normalization did not complete.');
                }
                base64 = snapshot.normalizedPdfBase64 || uploadedBase64;
                this.uploadedPdfAcroFormNormalizedBase64 = snapshot.normalizedPdfBase64 || null;
            }
            if (!base64) {
                throw new Error('Prepared PDF content is empty.');
            }
            const chunkSize = 450000;
            const uploadKey = String(versionId).replace(/[^A-Za-z0-9]/g, '') + '_' + Date.now();
            const chunkVersionIds = [];
            for (let offset = 0, index = 0; offset < base64.length; offset += chunkSize, index++) {
                this.pdfAcroFormPreparationText =
                    'Uploading prepared PDF chunk ' +
                    (index + 1) +
                    ' of ' +
                    Math.ceil(base64.length / chunkSize) +
                    '...';
                const chunk = base64.substring(offset, offset + chunkSize);
                const chunkVersionId = await savePdfAcroFormPreparedBodyChunk({
                    templateId: this.editTemplateId,
                    uploadKey,
                    chunkIndex: index,
                    chunk
                });
                chunkVersionIds.push(chunkVersionId);
            }
            this.pdfAcroFormPreparationText = 'Finalizing server-ready PDF body...';
            const jobId = await finalizePdfAcroFormPreparedBody({
                templateId: this.editTemplateId,
                versionId,
                fileName: this.uploadedFileName || 'template.pdf',
                chunkVersionIds
            });
            await this._waitForPdfAcroFormPreparedBody(versionId, jobId);
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast(
                'PDF preparation queued failed',
                'Template version was saved, but the server-ready PDF body was not prepared yet. ' + msg,
                'warning'
            );
        } finally {
            this.isPreparingPdfAcroFormBody = false;
            this.pdfAcroFormPreparationText = '';
        }
    }

    async _waitForPdfAcroFormPreparedBody(versionId, jobId) {
        const maxAttempts = 24;
        for (let attempt = 0; attempt < maxAttempts; attempt++) {
            this.pdfAcroFormPreparationText = 'Preparing PDF for bulk generation...';
            // eslint-disable-next-line no-await-in-loop
            const status = await getPdfAcroFormPreparedBodyStatus({ versionId, jobId });
            if (status && status.isReady) {
                this.pdfAcroFormPreparationText = 'PDF is ready for generation.';
                return;
            }
            if (status && status.jobStatus === 'Failed') {
                throw new Error(status.extendedStatus || 'PDF preparation failed.');
            }
            // eslint-disable-next-line no-await-in-loop
            await new Promise((resolve) => setTimeout(resolve, 1500));
        }
        throw new Error('PDF preparation is still running. Try Download Sample again in a moment.');
    }

    _isPdfTemplateType(templateType) {
        return String(templateType || '').toLowerCase() === 'pdf';
    }

    _mergePdfAcroFormMappings(freshSnapshot, savedSnapshot) {
        const savedByObjectNumber = new Map();
        const savedByName = new Map();
        (savedSnapshot.fields || []).forEach((field) => {
            if (field.objectNumber != null) {
                savedByObjectNumber.set(String(field.objectNumber), field);
            }
            if (field.name) {
                savedByName.set(field.name, field);
            }
        });
        return {
            ...freshSnapshot,
            normalizedPdfBase64: undefined,
            fields: (freshSnapshot.fields || []).map((field) => {
                const saved = savedByObjectNumber.get(String(field.objectNumber)) || savedByName.get(field.name) || {};
                return {
                    ...field,
                    friendlyLabel: saved.friendlyLabel || field.friendlyLabel || '',
                    mappedPath: saved.mappedPath || field.mappedPath || '',
                    buttonOnValue: saved.buttonOnValue || field.buttonOnValue,
                    buttonOnValues: saved.buttonOnValues || field.buttonOnValues
                };
            })
        };
    }

    _pdfBase64ContainsToken(base64, token) {
        try {
            return atob(base64 || '').includes(token);
        } catch (e) {
            return false;
        }
    }

    _officeExtensionForType(templateType, isMacroEnabled) {
        if (['PowerPoint', 'PPT', 'PPTX'].includes(templateType)) {
            return '.pptx';
        }
        if (templateType === 'Excel') {
            // Macro-enabled workbooks must download as .xlsm or Excel strips the
            // VBA project. The flag comes back with the generateDocumentParts payload.
            return isMacroEnabled ? '.xlsm' : '.xlsx';
        }
        if (templateType === 'PDF') {
            return '.pdf';
        }
        return '.docx';
    }

    async _generateOfficeSample(templateId, recordId, chartContext) {
        const parts = await generateDocumentParts({
            templateId,
            recordId,
            chartCvMap: chartContext.map,
            chartBucketMap: chartContext.bucketMap || null
        });
        if (!parts || !parts.allXmlParts) {
            throw new Error('Document generation returned empty result.');
        }

        const allImages = { ...(parts.imageBase64Map || {}) };
        if (parts.imageCvIdMap) {
            const uniqueCvIds = new Map();
            for (const [mediaPath, cvId] of Object.entries(parts.imageCvIdMap)) {
                if (!uniqueCvIds.has(cvId)) {
                    uniqueCvIds.set(cvId, []);
                }
                uniqueCvIds.get(cvId).push(mediaPath);
            }
            for (const [cvId, mediaPaths] of uniqueCvIds) {
                try {
                    // eslint-disable-next-line no-await-in-loop
                    const b64 = await getContentVersionBase64({ contentVersionId: cvId });
                    if (b64) {
                        for (const mediaPath of mediaPaths) {
                            allImages[mediaPath] = b64;
                        }
                    }
                } catch (imgErr) {
                    console.warn('Portwood admin: Failed to fetch image CV ' + cvId, imgErr);
                }
            }
        }

        if (parts.imageUrlMap) {
            for (const [mediaPath, url] of Object.entries(parts.imageUrlMap)) {
                if (!/rtaImage/i.test(url)) continue;
                try {
                    // eslint-disable-next-line no-await-in-loop
                    const pdfB64 = await renderImageAsPdfBase64({ imageUrl: url });
                    if (!pdfB64) continue;
                    // eslint-disable-next-line no-await-in-loop
                    const extracted = await extractFirstImageFromPdfBase64(pdfB64);
                    if (extracted && extracted.base64) {
                        allImages[mediaPath] = extracted.base64;
                        if (extracted.width && extracted.height) {
                            this._updateDocxImageSizeIfNotExplicit(parts, mediaPath, extracted.width, extracted.height);
                        }
                    }
                } catch (urlErr) {
                    console.warn('Portwood admin: rich text image extract failed for ' + url, urlErr);
                }
            }
        }

        const fileBytes = buildDocx(parts.allXmlParts, allImages);
        return {
            base64: this._uint8ArrayToBase64(fileBytes),
            title: parts.title || 'Document',
            isMacroEnabled: parts.isMacroEnabled === true
        };
    }

    _uint8ArrayToBase64(bytes) {
        let binary = '';
        for (let i = 0; i < bytes.length; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    }

    _updateDocxImageSizeIfNotExplicit(parts, mediaPath, widthPx, heightPx) {
        if (!parts || !parts.allXmlParts) return;
        const docXml = parts.allXmlParts['word/document.xml'];
        const relsXml = parts.allXmlParts['word/_rels/document.xml.rels'];
        if (!docXml || !relsXml) return;

        const targetName = mediaPath.replace(/^word\//, '');
        const relMatch = relsXml.match(
            new RegExp(
                '<Relationship\\s+Id="([^"]+)"[^>]*?Target="' + targetName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '"',
                'i'
            )
        );
        if (!relMatch) return;
        const relId = relMatch[1];

        const blipIdx = docXml.indexOf('r:embed="' + relId + '"');
        if (blipIdx === -1) return;
        const drawStart = docXml.lastIndexOf('<w:drawing', blipIdx);
        const drawEnd = docXml.indexOf('</w:drawing>', blipIdx);
        if (drawStart === -1 || drawEnd === -1) return;

        const drawingXml = docXml.substring(drawStart, drawEnd + '</w:drawing>'.length);
        if (drawingXml.indexOf('DOCGEN_EXPLICIT_SIZE') !== -1) return;

        const cxEmu = widthPx * 9525;
        const cyEmu = heightPx * 9525;
        let updated = drawingXml.replace(
            /<wp:extent\s+cx="\d+"\s+cy="\d+"\s*\/>/,
            '<wp:extent cx="' + cxEmu + '" cy="' + cyEmu + '"/>'
        );
        updated = updated.replace(
            /<a:ext\s+cx="\d+"\s+cy="\d+"\s*\/>/,
            '<a:ext cx="' + cxEmu + '" cy="' + cyEmu + '"/>'
        );
        if (updated !== drawingXml) {
            parts.allXmlParts['word/document.xml'] =
                docXml.substring(0, drawStart) + updated + docXml.substring(drawEnd + '</w:drawing>'.length);
        }
    }

    /**
     * Downloads a base64-encoded file via an anchor element.
     */
    downloadBase64(base64Data, fileName, mimeType) {
        downloadBase64Util(base64Data, fileName, mimeType);
    }

    // --- File Upload ---
    async handleEditUploadFinished(event) {
        const uploadedFiles = event.detail.files;
        if (!uploadedFiles || uploadedFiles.length === 0) {
            return;
        }
        const file = uploadedFiles[0];

        // 10 MB cap on every DOCX/PPTX template upload. Both the async-decompose
        // Queueable (PDF generation prep) and the server-side merge step in
        // generateDocumentParts (DOCX generation) need to decompress the full
        // ZIP, and Apex async heap (12 MB) can't survive much beyond ~10 MB
        // binary template + per-entry blobs. One uniform rule beats a
        // per-output-format ceiling and matches real-world template sizes
        // (typical DOCX templates are well under 5 MB; 10 MB+ is almost always
        // uncompressed images).
        const TEMPLATE_MAX_BYTES = 10 * 1024 * 1024;
        let uploadedVersionId;
        try {
            uploadedVersionId = file.contentVersionId;
            if (!uploadedVersionId && file.documentId) {
                uploadedVersionId = await getLatestContentVersionId({
                    contentDocumentId: file.documentId
                });
            }
            if (!uploadedVersionId || !String(uploadedVersionId).startsWith('068')) {
                throw new Error('Uploaded file version could not be resolved.');
            }
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Upload scan failed', msg, 'error');
            return;
        }
        try {
            const size = await getContentVersionSize({
                contentVersionId: uploadedVersionId
            });
            if (size > TEMPLATE_MAX_BYTES) {
                await deleteContentVersionDocument({
                    contentVersionId: uploadedVersionId
                });
                this.showToast(
                    'Template too large',
                    'Templates must be 10 MB or smaller (' +
                        (size / 1024 / 1024).toFixed(1) +
                        ' MB uploaded). Almost always the cause is uncompressed images — in Word, right-click an image → Compress Pictures → Email (96 ppi) or Web (150 ppi). A 20 MB template typically drops to 1–2 MB with no visible quality loss.',
                    'error'
                );
                return;
            }
        } catch (err) {
            // eslint-disable-next-line no-console
            console.warn('Portwood size guard failed (continuing):', err);
        }

        this.showToast('Success', 'File Uploaded: ' + file.name, 'success');
        this.currentFileId = file.documentId;
        this.uploadedContentVersionId = uploadedVersionId;
        this.uploadedFileName = file.name;
        this.uploadedPdfAcroFormSnapshot = null;
        this.uploadedPdfAcroFormSnapshotJson = null;
        this.uploadedPdfAcroFormNormalizedBase64 = null;

        if (this.editTemplateType === 'PDF' || (file.name || '').toLowerCase().endsWith('.pdf')) {
            try {
                const base64 = await getContentVersionBase64({
                    contentVersionId: uploadedVersionId
                });
                const snapshot = await decomposePdfAcroFormBase64(base64);
                this.uploadedPdfAcroFormNormalizedBase64 = snapshot.normalizedPdfBase64 || null;
                delete snapshot.normalizedPdfBase64;
                this.uploadedPdfAcroFormSnapshot = snapshot;
                this.pdfAcroFormSnapshotVersionId = null;
                this.isPdfAcroFormSnapshotLoaded = false;
                this._syncPdfAcroFormSnapshotJson();
                const fieldCount = snapshot.fields ? snapshot.fields.length : 0;
                this.showToast(
                    'Fillable fields found',
                    fieldCount + ' fillable field' + (fieldCount === 1 ? '' : 's') + ' decomposed.',
                    'success'
                );
                this.activeEditTab = 'pdfFields';
            } catch (err) {
                const msg = err && err.message ? err.message : 'Unable to decompose fillable fields.';
                this.showToast('Fillable field scan skipped', msg, 'warning');
            }
        }
        this._resetEditFileUploadWidget();
    }

    _resetEditFileUploadWidget() {
        this.showEditFileUpload = false;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.showEditFileUpload = true;
        }, 0);
    }

    _syncPdfAcroFormSnapshotJson() {
        const snapshot = this.uploadedPdfAcroFormSnapshot
            ? {
                  ...this.uploadedPdfAcroFormSnapshot,
                  fields: (this.uploadedPdfAcroFormSnapshot.fields || []).map((field) => ({
                      ...field,
                      body: undefined,
                      widgetBody: undefined,
                      widgets: (field.widgets || []).map((widget) => ({
                          ...widget,
                          body: undefined
                      }))
                  }))
              }
            : null;
        this.uploadedPdfAcroFormSnapshotJson = this.uploadedPdfAcroFormSnapshot
            ? JSON.stringify({
                  ...snapshot,
                  xfaPackets: undefined,
                  normalizedPdfBase64: undefined
              })
            : null;
    }

    async loadPdfAcroFormMapping() {
        if (!this.editTemplateId || this.editTemplateType !== 'PDF') {
            return;
        }
        try {
            const result = await getActivePdfAcroFormSnapshot({ templateId: this.editTemplateId });
            this.pdfAcroFormSnapshotVersionId = result && result.versionId ? result.versionId : null;
            if (result && result.snapshotJson) {
                this.uploadedPdfAcroFormSnapshot = JSON.parse(result.snapshotJson);
                this.isPdfAcroFormSnapshotLoaded = true;
                this._syncPdfAcroFormSnapshotJson();
            } else {
                this.uploadedPdfAcroFormSnapshot = null;
                this.isPdfAcroFormSnapshotLoaded = false;
                this.uploadedPdfAcroFormSnapshotJson = null;
            }
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('PDF mapping load failed', msg, 'warning');
        }
    }

    async handleReloadPdfAcroFormMapping() {
        await this.loadPdfAcroFormMapping();
    }

    async handleSavePdfAcroFormMapping() {
        this._syncPdfAcroFormSnapshotJson();
        if (!this.editTemplateId || !this.hasSavedPdfAcroFormSnapshotTarget || !this.uploadedPdfAcroFormSnapshotJson) {
            this.showToast(
                'PDF mapping is a draft',
                'Save as New Version first, then use Save Mapping for later edits.',
                'warning'
            );
            return;
        }
        this.isSavingPdfAcroFormMapping = true;
        try {
            await savePdfAcroFormSnapshot({
                templateId: this.editTemplateId,
                versionId: this.pdfAcroFormSnapshotVersionId,
                snapshotJson: this.uploadedPdfAcroFormSnapshotJson
            });
            this.isPdfAcroFormSnapshotLoaded = true;
            this.showToast('Saved', 'Fillable field mapping saved.', 'success');
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Error saving PDF mapping', msg, 'error');
        } finally {
            this.isSavingPdfAcroFormMapping = false;
        }
    }

    handlePdfAcroFormMappingChange(event) {
        const index = Number(event.currentTarget.dataset.index);
        if (!this.hasUploadedPdfAcroFormFields || Number.isNaN(index)) {
            return;
        }
        const fields = this.uploadedPdfAcroFormSnapshot.fields.map((field, i) => {
            if (i !== index) {
                return field;
            }
            return {
                ...field,
                mappedPath: (event.detail.value || '').trim()
            };
        });
        this.uploadedPdfAcroFormSnapshot = {
            ...this.uploadedPdfAcroFormSnapshot,
            fields
        };
        this._syncPdfAcroFormSnapshotJson();
    }

    handlePdfAcroFormFriendlyLabelChange(event) {
        const index = Number(event.currentTarget.dataset.index);
        if (!this.hasUploadedPdfAcroFormFields || Number.isNaN(index)) {
            return;
        }
        const fields = this.uploadedPdfAcroFormSnapshot.fields.map((field, i) => {
            if (i !== index) {
                return field;
            }
            return {
                ...field,
                friendlyLabel: (event.detail.value || '').trim()
            };
        });
        this.uploadedPdfAcroFormSnapshot = {
            ...this.uploadedPdfAcroFormSnapshot,
            fields
        };
        this._syncPdfAcroFormSnapshotJson();
    }

    handlePdfAcroFormButtonValueChange(event) {
        const index = Number(event.currentTarget.dataset.index);
        if (!this.hasUploadedPdfAcroFormFields || Number.isNaN(index)) {
            return;
        }
        const fields = this.uploadedPdfAcroFormSnapshot.fields.map((field, i) => {
            if (i !== index) {
                return field;
            }
            return {
                ...field,
                buttonOnValue: (event.detail.value || '').trim() || 'Yes'
            };
        });
        this.uploadedPdfAcroFormSnapshot = {
            ...this.uploadedPdfAcroFormSnapshot,
            fields
        };
        this._syncPdfAcroFormSnapshotJson();
    }

    handleClearPdfAcroFormMappings() {
        if (!this.hasUploadedPdfAcroFormFields) {
            return;
        }
        const fields = this.uploadedPdfAcroFormSnapshot.fields.map((field) => ({
            ...field,
            mappedPath: ''
        }));
        this.uploadedPdfAcroFormSnapshot = {
            ...this.uploadedPdfAcroFormSnapshot,
            fields
        };
        this._syncPdfAcroFormSnapshotJson();
    }

    @track isUploadingHtml = false;

    // v1.90 — true when the HTML source declares an @page rule in any <style> block.
    // Mirrors DocGenService.hasSourcePageRule so the wizard's clear/hide decision
    // matches the engine's suppress decision.
    htmlContainsPageRule(htmlText) {
        if (!htmlText || typeof htmlText !== 'string') {
            return false;
        }
        // Cheap, lowercase substring scan — same approach used server-side.
        return htmlText.toLowerCase().indexOf('@page') !== -1;
    }

    get hasLintFindings() {
        return this.lintFindings && this.lintFindings.length > 0;
    }

    /**
     * Fidelity report (#272): server Finding DTOs → badge rows, the same shape
     * the Agentforce report renders. Lint actions are always 'warning'.
     */
    _mapLintFindings(warnings) {
        return (warnings || []).map((f, i) => ({
            key: `lint-${i}`,
            rule: f.rule,
            detail: f.detail,
            occurrences: f.occurrences,
            badge: f.action === 'repaired' ? 'Repaired' : f.action === 'removed' ? 'Removed' : 'Check this',
            badgeClass:
                f.action === 'warning' ? 'slds-theme_warning' : f.action === 'repaired' ? 'slds-theme_success' : ''
        }));
    }

    // Sticky so the author can read it while scrolling to the report; the save
    // itself already got its own success toast.
    _toastLintFindings() {
        const n = this.lintFindings.length;
        this.showToast(
            'Saved — ' + n + ' template warning' + (n === 1 ? '' : 's'),
            'This will still render. The fidelity report in the edit view lists what the PDF engine handles differently — nothing was blocked.',
            'warning',
            'sticky'
        );
    }

    // Canvas saves bypass _processAndSaveHtmlBody (docGenCanvas calls
    // saveAndPublishHtmlBody itself), so the warnings arrive on the 'saved'
    // event instead of a save response this component holds.
    handleCanvasSaved(event) {
        const warnings = event && event.detail ? event.detail.warnings : null;
        this.lintFindings = this._mapLintFindings(warnings);
        if (this.lintFindings.length > 0) {
            this._toastLintFindings();
        }
    }

    triggerHtmlFilePicker() {
        const input = this.template.querySelector('.docgen-html-file-input');
        if (input) {
            input.click();
        }
    }

    async handleHtmlFileSelected(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) {
            return;
        }
        const lower = (file.name || '').toLowerCase();
        if (!lower.endsWith('.html') && !lower.endsWith('.htm') && !lower.endsWith('.zip')) {
            this.showToast('Unsupported file', 'Please choose an .html, .htm, or .zip file.', 'error');
            event.target.value = '';
            return;
        }
        this.isUploadingHtml = true;
        try {
            const templateId = this.editTemplateId;
            let htmlText;
            let imagePaths = [];
            let imageBytes = [];

            if (lower.endsWith('.zip')) {
                const buffer = await file.arrayBuffer();
                const entries = await readZip(buffer);
                const imgExts = new Set(['png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff', 'svg']);
                for (const entry of entries) {
                    const n = entry.name.toLowerCase();
                    if (!htmlText && (n.endsWith('.html') || n.endsWith('.htm'))) {
                        htmlText = new TextDecoder('utf-8').decode(entry.data);
                    } else {
                        const dot = n.lastIndexOf('.');
                        if (dot > 0 && imgExts.has(n.substring(dot + 1))) {
                            imagePaths.push(entry.name);
                            imageBytes.push(entry.data);
                        }
                    }
                }
                if (!htmlText) {
                    throw new Error('Zip contains no .html or .htm file.');
                }
            } else {
                htmlText = await file.text();
            }

            await this._processAndSaveHtmlBody(templateId, htmlText, file.name, { imagePaths, imageBytes });
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Upload Failed', msg, 'error');
        } finally {
            this.isUploadingHtml = false;
            event.target.value = '';
        }
    }

    /**
     * Shared HTML-body pipeline (file upload, paste-back editor, starter):
     * extract inline data: URI images, upload every image part, rewrite
     * <img src> to CV URLs, store the body, and sync the @page-ownership
     * state. Throws on failure — callers own the error toast.
     */
    async _processAndSaveHtmlBody(templateId, htmlText, fileName, zipImages, source) {
        // A new save invalidates whatever the last fidelity report said — never
        // leave stale findings showing for a body they were not run against.
        this.lintFindings = [];
        // REGIONS: this is the single choke point every body reaches on its way to a
        // ContentVersion — editor save, file upload, AI paste-back, switch-to-HTML.
        // Adopting here means an author can upload an HTML file that carries
        // data-dg-region markers and have its header and footer land in the right
        // fields, and it means no marker can reach the renderer by any route.
        // Idempotent: a body that came through _currentDraftHtml is already split,
        // reports hadRegions === false, and passes through untouched.
        htmlText = this._adoptRegions(htmlText).body;
        // GUARD: never stage editor-internal artifacts. If a preview-wrapped
        // payload (scoped .dg-pv page), tag pills, or drop markers slip in —
        // e.g. from a stale cached bundle's older code path — unwrap and
        // strip them so the stored body is always clean template HTML.
        htmlText = stripRegionMarkers(this._sanitizeStagedHtml(htmlText));
        const imagePaths = (zipImages && zipImages.imagePaths) || [];
        const imageBytes = (zipImages && zipImages.imageBytes) || [];

        // Extract inline data: URI images (common in Notion, ChatGPT, Apple
        // Pages, or any rich-text-paste HTML). Blob.toPdf can't decode
        // data URIs, so each inline image becomes its own ContentVersion
        // with the src rewritten to /sfc/... just like zipped images.
        const dataUriMatches = [];
        const dataUriRe = /src\s*=\s*(["'])(data:image\/([a-zA-Z0-9+.-]+);base64,([A-Za-z0-9+/=\s]+?))\1/g;
        let m;
        while ((m = dataUriRe.exec(htmlText)) !== null) {
            const dataUri = m[2];
            let ext = m[3].toLowerCase();
            if (ext === 'jpeg') {
                ext = 'jpg';
            }
            if (ext === 'svg+xml') {
                ext = 'svg';
            }
            const base64 = m[4].replace(/\s+/g, '');
            dataUriMatches.push({ dataUri, ext, base64 });
        }

        // Upload each image; server returns CV Id + URL per part
        const urlByPath = {};
        for (let i = 0; i < imagePaths.length; i++) {
            const base = imagePaths[i].split('/').pop() || imagePaths[i];
            // eslint-disable-next-line no-await-in-loop
            const imgResult = await saveHtmlTemplateImage({
                templateId,
                fileName: base,
                base64Content: bytesToBase64(imageBytes[i])
            });
            urlByPath[imagePaths[i]] = imgResult.url;
            if (base !== imagePaths[i]) {
                urlByPath[base] = imgResult.url;
            }
        }

        // Upload extracted data: URIs; key by the full data: string so the
        // regex-replace below swaps each original URI for its CV URL.
        const dataUriUrlMap = [];
        for (let i = 0; i < dataUriMatches.length; i++) {
            const d = dataUriMatches[i];
            // eslint-disable-next-line no-await-in-loop
            const imgResult = await saveHtmlTemplateImage({
                templateId,
                fileName: 'inline_' + (i + 1) + '.' + d.ext,
                base64Content: d.base64
            });
            dataUriUrlMap.push({ dataUri: d.dataUri, url: imgResult.url });
        }

        // Rewrite <img src="..."> references client-side
        let rewritten = htmlText;
        for (const path of Object.keys(urlByPath)) {
            const url = urlByPath[path];
            rewritten = rewritten.split('"' + path + '"').join('"' + url + '"');
            rewritten = rewritten.split("'" + path + "'").join("'" + url + "'");
        }
        for (const entry of dataUriUrlMap) {
            rewritten = rewritten.split(entry.dataUri).join(entry.url);
        }
        const totalImages = imagePaths.length + dataUriMatches.length;

        // Save the final HTML body
        const bodyResult = await saveHtmlTemplateBody({
            templateId,
            fileName,
            htmlContent: rewritten
        });

        this.currentFileId = bodyResult.contentDocumentId;
        this.uploadedContentVersionId = bodyResult.contentVersionId;
        this.uploadedFileName = fileName;
        this._lastUploadedHtmlText = rewritten;
        this.stagedBodySource = source || 'file';
        this.htmlEditorDirty = false;
        // Keep the editor in lockstep with whatever just got staged — a file
        // upload while the editor is open must not leave stale HTML showing.
        if (this.showHtmlBodyEditor) {
            this._syncHtmlBodyEditorDom(rewritten);
        }
        const imgMsg =
            totalImages > 0 ? ' (' + totalImages + ' image' + (totalImages === 1 ? '' : 's') + ' extracted)' : '';
        // v1.90 — detect author-declared @page rule; if present, the engine suppresses
        // its own size/margin and the template-level page fields are dead inputs. Hide
        // them and clear in-memory values so a subsequent Save doesn't silently
        // re-introduce conflicting values.
        this.editHtmlBodyOwnsPageRule = this.htmlContainsPageRule(rewritten);
        if (this.editHtmlBodyOwnsPageRule) {
            this.editTemplatePageOrientation = null;
            this.editTemplatePageSize = null;
            this.editTemplatePageMargins = null;
            this.editTemplateCustomMargins = '';
        }
        const pageMsg = this.editHtmlBodyOwnsPageRule
            ? ' Your HTML defines its own @page CSS — template page-layout fields cleared.'
            : '';
        // #272 fidelity report — the linter's warnings ride the save response.
        // Advisory only: the body above is already stored.
        this.lintFindings = this._mapLintFindings(bodyResult.warnings);
        this.showToast(
            source === 'editor' ? 'Editor HTML staged' : 'Uploaded',
            fileName + imgMsg + '.' + pageMsg + ' Click "Save as New Version" to activate.',
            'success'
        );
        if (this.lintFindings.length > 0) {
            this._toastLintFindings();
        }
        return rewritten;
    }

    /**
     * Strip every editor-internal artifact from HTML about to be staged:
     * tag pills back to plain text, drop markers gone, and — if the text is
     * (or contains) a scoped preview page — unwrap .dg-pv and remove the
     * injected preview <style>. Idempotent on clean input.
     */
    _sanitizeStagedHtml(html) {
        if (
            !html ||
            (html.indexOf('data-dg-tag') === -1 &&
                html.indexOf('dg-pv') === -1 &&
                html.indexOf('dg-drop-marker') === -1)
        ) {
            return html;
        }
        try {
            const tpl = document.createElement('template');
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            tpl.innerHTML = html;
            const root = tpl.content;
            for (const marker of root.querySelectorAll('.dg-drop-marker')) {
                marker.remove();
            }
            this._unpillifyTags(root);
            const pv = root.querySelector('div.dg-pv');
            if (pv) {
                // Preview-wrapped payload: keep only the page content, minus
                // the injected scoped stylesheet.
                for (const styleEl of pv.querySelectorAll(':scope > style')) {
                    styleEl.remove();
                }
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                const inner = pv.innerHTML.trim();
                // Preserve an original shell if one wrapped the preview; else
                // the content becomes the document body in a minimal shell.
                const bodyRe = /(<body\b[^>]*>)[\s\S]*?(<\/body\s*>)/i;
                const outer = html.replace(/[\s\S]*/, ''); // placeholder, replaced below
                void outer;
                if (bodyRe.test(html) && !/class="dg-pv"/.test(html.split(/<body\b[^>]*>/i)[0] || '')) {
                    return html.replace(bodyRe, (m, open, close) => open + '\n' + inner + '\n' + close);
                }
                return (
                    '<!DOCTYPE html>\n<html>\n<head>\n<meta charset="utf-8" />\n<style>\n@page { size: Letter portrait; margin: 0.75in; }\nbody { font-family: Helvetica, Arial, sans-serif; font-size: 10.5pt; color: #1a1a1a; }\n</style>\n</head>\n<body>\n' +
                    inner +
                    '\n</body>\n</html>\n'
                );
            }
            // No pv wrapper — serialize the cleaned fragment back out.
            const container = document.createElement('div');
            container.appendChild(root.cloneNode(true));
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            return container.innerHTML;
        } catch (e) {
            return html;
        }
    }

    // --- HTML body editor (paste-back surface) ---
    get htmlBodyEditorToggleLabel() {
        return this.showHtmlBodyEditor ? 'Hide HTML Editor' : 'Edit HTML';
    }

    /** One-line answer to "what will Save as New Version actually save?" */
    get htmlEditorStatusText() {
        if (this.htmlEditorDirty) {
            return 'Unapplied edits — "Save as New Version" saves them; Reload discards.';
        }
        if (this.stagedBodySource === 'editor') {
            return 'Staged: your editor HTML — "Save as New Version" saves it.';
        }
        if (this.stagedBodySource === 'starter') {
            return 'Staged: starter design (' + this.uploadedFileName + ') — "Save as New Version" saves it.';
        }
        if (this.stagedBodySource === 'file') {
            return (
                'Staged: uploaded file "' + this.uploadedFileName + '" (shown below) — "Save as New Version" saves it.'
            );
        }
        return 'Showing the current saved body — nothing staged yet.';
    }

    get htmlEditorStatusClass() {
        return this.htmlEditorDirty ? 'dg-html-editor-status dg-html-editor-status_dirty' : 'dg-html-editor-status';
    }

    handleHtmlBodyEditorInput() {
        this.htmlEditorDirty = true;
        // Live preview beside the code — debounced so typing stays smooth.
        clearTimeout(this._codePreviewTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._codePreviewTimer = setTimeout(() => this._refreshCodePreview(), 400);
    }

    /** Re-render the side-by-side preview from the code editor's current text. */
    _refreshCodePreview() {
        const host = this.template.querySelector('.dg-code-preview');
        const ta = this.template.querySelector('.dg-html-body-editor');
        if (host && ta) {
            // eslint-disable-next-line @lwc/lwc/no-inner-html
            host.innerHTML = scopeHtmlForInlinePreview(ta.value || '');
            const pv = host.querySelector('.dg-pv');
            if (pv) {
                // The preview sheet mirrors the page setup too.
                this._applyCanvasDimensions(pv);
            }
        }
    }

    /**
     * Canvas templates get the canvas editor; everything else keeps the flow designer.
     * Two mutually exclusive getters rather than one negated in the markup, so the
     * template reads as "which editor" instead of "the designer, unless…".
     */
    get isCanvasTemplate() {
        return this.editTemplateType === 'Canvas';
    }

    get showCanvasDesigner() {
        return this.showHtmlBodyVisual && this.isCanvasTemplate;
    }

    get showFlowDesigner() {
        return this.showHtmlBodyVisual && !this.isCanvasTemplate;
    }

    get codeSplitClass() {
        return this.showHtmlBodyVisual ? 'dg-code-split slds-hide' : 'dg-code-split';
    }

    // --- Visual | Source segmented switch (persistent header, like any editor) ---
    get visualModeBtnClass() {
        return this.showHtmlBodyVisual
            ? 'dg-fmt-btn dg-fmt-btn_word dg-mode-btn dg-mode-btn_active'
            : 'dg-fmt-btn dg-fmt-btn_word dg-mode-btn';
    }

    get sourceModeBtnClass() {
        return this.showHtmlBodyVisual
            ? 'dg-fmt-btn dg-fmt-btn_word dg-mode-btn'
            : 'dg-fmt-btn dg-fmt-btn_word dg-mode-btn dg-mode-btn_active';
    }

    handleSelectVisualMode() {
        if (!this.showHtmlBodyVisual) {
            const ta = this.template.querySelector('.dg-html-body-editor');
            this._enterVisualMode((ta && ta.value) || '');
        }
    }

    handleSelectSourceMode() {
        if (this.showHtmlBodyVisual) {
            this._exitVisualMode();
        }
    }

    // --- Page setup: size / orientation / margins → @page rule + canvas sheet ---
    get pageSizeChoices() {
        return [
            { key: 'Letter', label: 'Letter' },
            { key: 'Legal', label: 'Legal' },
            { key: 'A4', label: 'A4' }
        ];
    }

    _parsePageSetup(code) {
        const setup = {
            size: 'Letter',
            orient: 'portrait',
            margin: '0.75',
            customW: '8.5',
            customH: '11',
            customMargin: '0.75'
        };
        // Take the LAST simple @page rule — CSS cascade means that's the one
        // the PDF engine honors when a doc carries more than one.
        let m = null;
        const pageRe = /@page\s*\{([^}]*)\}/gi;
        let hit;
        while ((hit = pageRe.exec(code || '')) !== null) {
            m = hit;
        }
        if (m) {
            const body = m[1];
            const sm = /size\s*:\s*(letter|legal|a4)\s*(portrait|landscape)?/i.exec(body);
            const cm = /size\s*:\s*([\d.]+)\s*in\s+([\d.]+)\s*in/i.exec(body);
            if (cm) {
                setup.size = 'Custom';
                setup.customW = cm[1];
                setup.customH = cm[2];
            } else if (sm) {
                const raw = sm[1].toLowerCase();
                setup.size = raw === 'a4' ? 'A4' : raw.charAt(0).toUpperCase() + raw.slice(1);
                if (sm[2]) {
                    setup.orient = sm[2].toLowerCase();
                }
            }
            const mm = /margin\s*:\s*([\d.]+)\s*in/i.exec(body);
            if (mm) {
                setup.margin = ['0.5', '0.75', '1'].includes(mm[1]) ? mm[1] : 'custom';
                setup.customMargin = mm[1];
            }
        }
        this.pageSetup = setup;
    }

    get isCustomPageSize() {
        return this.pageSetup.size === 'Custom';
    }

    get isCustomMargin() {
        return this.pageSetup.margin === 'custom';
    }

    handlePageSetupChange(event) {
        const field = event.currentTarget.dataset.field;
        this.pageSetup = { ...this.pageSetup, [field]: event.currentTarget.value };
        this._applyPageSetup();
    }

    _applyPageSetup() {
        const ta = this.template.querySelector('.dg-html-body-editor');
        if (!ta) {
            return;
        }
        const sizePart = this.isCustomPageSize
            ? (parseFloat(this.pageSetup.customW) || 8.5) + 'in ' + (parseFloat(this.pageSetup.customH) || 11) + 'in'
            : this.pageSetup.size + ' ' + this.pageSetup.orient;
        const marginVal = this.isCustomMargin ? parseFloat(this.pageSetup.customMargin) || 0.75 : this.pageSetup.margin;
        const rule = '@page { size: ' + sizePart + '; margin: ' + marginVal + 'in; }';
        let code = ta.value || '';
        if (/@page\s*\{[^}]*\}/i.test(code)) {
            code = code.replace(/@page\s*\{[^}]*\}/i, rule);
        } else if (/<style\b[^>]*>/i.test(code)) {
            code = code.replace(/<style\b[^>]*>/i, (m) => m + '\n        ' + rule);
        } else {
            code = '<style>\n' + rule + '\n</style>\n' + code;
        }
        ta.value = code;
        this._visualOriginalCode = code;
        this.htmlEditorDirty = true;
        this._applyCanvasDimensions();
        this._refreshCodePreview();
    }

    /** Make the on-screen sheet match the page setup (Lucid-style canvas). */
    _applyCanvasDimensions(targetPv) {
        const pvs = [];
        if (targetPv) {
            pvs.push(targetPv);
        } else {
            for (const hostSel of ['.dg-visual-host', '.dg-code-preview']) {
                const host = this.template.querySelector(hostSel);
                const pv = host && host.querySelector('.dg-pv');
                if (pv) {
                    pvs.push(pv);
                }
            }
        }
        if (!pvs.length) {
            return;
        }
        const widths = { Letter: 816, Legal: 816, A4: 794 };
        const heights = { Letter: 1056, Legal: 1344, A4: 1123 };
        let w;
        let h;
        if (this.isCustomPageSize) {
            w = Math.round((parseFloat(this.pageSetup.customW) || 8.5) * 96);
            h = Math.round((parseFloat(this.pageSetup.customH) || 11) * 96);
        } else {
            const landscape = this.pageSetup.orient === 'landscape';
            w = landscape ? heights[this.pageSetup.size] || 1056 : widths[this.pageSetup.size] || 816;
            h = landscape ? widths[this.pageSetup.size] || 816 : heights[this.pageSetup.size] || 1056;
        }
        const marginVal = this.isCustomMargin
            ? parseFloat(this.pageSetup.customMargin) || 0.75
            : parseFloat(this.pageSetup.margin || '0.75');
        const pad = Math.round(marginVal * 96);
        for (const pv of pvs) {
            pv.style.maxWidth = w + 'px';
            pv.style.width = w + 'px';
            pv.style.minHeight = h + 'px';
            pv.style.padding = pad + 'px';
        }
        // The running header/footer are the sheet's top and bottom MARGIN ZONES, not
        // panels parked above and below it. They must match the page exactly — same
        // width, same horizontal padding — or the header text will not line up with
        // the body text directly beneath it and the illusion of one continuous sheet
        // breaks. This is what makes them read as part of the canvas.
        for (const which of ['header', 'footer']) {
            const band = this.template.querySelector('.dg-chrome-band_' + which);
            if (band) {
                band.style.width = w + 'px';
                band.style.maxWidth = w + 'px';
                band.style.paddingLeft = pad + 'px';
                band.style.paddingRight = pad + 'px';
            }
        }
    }

    // --- Format Code + Code ⇄ Preview (shared by the HTML editor and the DOCX viewer) ---
    get docxHtmlPreviewToggleLabel() {
        return this.showDocxHtmlPreview ? 'Show Code' : 'Preview';
    }

    get htmlBodyEditorClass() {
        return this.showHtmlBodyVisual ? 'dg-html-body-editor slds-hide' : 'dg-html-body-editor';
    }

    get visualToggleLabel() {
        return this.showHtmlBodyVisual ? 'Back to Code' : 'Visual';
    }

    /** Designer canvas: same editor classes plus the full-height variant. */
    get designerEditorClass() {
        return this.htmlBodyEditorClass + ' dg-designer-size';
    }

    // --- Visual-mode format bar (alignment, size, colors) ---
    get textColorSwatches() {
        return [
            { key: 'c_black', value: '#1a1a1a', style: 'background: #1a1a1a', title: 'Black text' },
            { key: 'c_navy', value: '#1f3a5f', style: 'background: #1f3a5f', title: 'Navy text' },
            { key: 'c_gray', value: '#666666', style: 'background: #666666', title: 'Gray text' },
            { key: 'c_blue', value: '#1b5e9e', style: 'background: #1b5e9e', title: 'Blue text' },
            { key: 'c_green', value: '#1c7a3d', style: 'background: #1c7a3d', title: 'Green text' },
            { key: 'c_red', value: '#b91c1c', style: 'background: #b91c1c', title: 'Red text' },
            { key: 'c_white', value: '#ffffff', style: 'background: #ffffff; border-color: #999', title: 'White text' }
        ];
    }

    get highlightSwatches() {
        return [
            {
                key: 'h_none',
                value: 'transparent',
                style: 'background: #fff; border-color: #999',
                title: 'No highlight'
            },
            { key: 'h_yellow', value: '#fef3c7', style: 'background: #fef3c7', title: 'Yellow highlight' },
            { key: 'h_blue', value: '#e8f0fb', style: 'background: #e8f0fb', title: 'Blue highlight' },
            { key: 'h_green', value: '#e3f5e9', style: 'background: #e3f5e9', title: 'Green highlight' },
            { key: 'h_gray', value: '#f2f4f7', style: 'background: #f2f4f7', title: 'Gray highlight' },
            { key: 'h_navy', value: '#1f3a5f', style: 'background: #1f3a5f', title: 'Navy fill (use white text)' }
        ];
    }

    /** The PDF engine ships exactly four fonts — the picker offers exactly those. */
    get fontChoices() {
        return [
            {
                key: 'f_helv',
                label: 'Helvetica',
                value: 'Helvetica, Arial, sans-serif',
                style: 'font-family: Helvetica, Arial, sans-serif',
                title: 'Helvetica — clean sans-serif (default)'
            },
            {
                key: 'f_times',
                label: 'Times',
                value: "'Times New Roman', Times, serif",
                style: "font-family: 'Times New Roman', Times, serif",
                title: 'Times — formal serif'
            },
            {
                key: 'f_courier',
                label: 'Courier',
                value: "'Courier New', Courier, monospace",
                style: "font-family: 'Courier New', Courier, monospace",
                title: 'Courier — monospace, great for codes and numbers'
            },
            {
                key: 'f_unicode',
                label: 'Unicode',
                value: "'Arial Unicode MS', Arial, sans-serif",
                style: 'font-family: Arial, sans-serif',
                title: 'Arial Unicode MS — widest character coverage (international text)'
            }
        ];
    }

    /** Keep the page's text selection alive while clicking toolbar controls. */
    handleFmtMouseDown(event) {
        event.preventDefault();
    }

    /** Caret with no selection? Format the word under it — click, color, done. */
    _expandCaretToWord() {
        try {
            const sel = window.getSelection();
            if (!sel || !sel.rangeCount || !sel.isCollapsed || typeof sel.modify !== 'function') {
                return;
            }
            const host = this.template.querySelector('.dg-visual-host');
            const pv = host && host.querySelector('.dg-pv');
            const anchorEl =
                sel.anchorNode && sel.anchorNode.nodeType === 3 ? sel.anchorNode.parentElement : sel.anchorNode;
            if (pv && anchorEl && pv.contains(anchorEl)) {
                sel.modify('move', 'backward', 'word');
                sel.modify('extend', 'forward', 'word');
            }
        } catch (e) {
            /* best effort */
        }
    }

    /** Toolbar breadcrumb: what element is the caret inside? */
    _onSelectionChange = () => {
        if (!this.showHtmlBodyVisual || this.activeMainTab !== 'design') {
            return;
        }
        let node = null;
        try {
            const sel = window.getSelection();
            node = sel && sel.anchorNode;
        } catch (e) {
            return;
        }
        while (node && node.nodeType === 3) {
            node = node.parentNode;
        }
        // #247 — the caret can now be in the body OR in a running header/footer band.
        // Resolve which surface owns it so the tracker and the context label follow.
        const pv = this._surfaceContaining(node);
        if (!node || !pv) {
            this.selectionContextLabel = '';
            return;
        }
        // Stash the live caret so the "/" hotkey recovery can restore it after
        // Lightning's global-search handler steals focus.
        try {
            const sel = window.getSelection();
            if (sel && sel.rangeCount) {
                this._lastCanvasRange = sel.getRangeAt(0).cloneRange();
            }
        } catch (e) {
            /* best effort */
        }
        // #238/#239/#240 — record the durable caret while the canvas still owns the
        // selection. Every toolbar control (color pickers, table tools, chip insert)
        // reads THIS, not the live selection, because clicking any of them moves focus
        // out of the canvas and destroys the live one.
        this._recordCaret(node, pv);
        const names = {
            H1: 'Heading 1',
            H2: 'Heading 2',
            H3: 'Heading 3',
            P: 'Paragraph',
            TD: 'Table cell',
            TH: 'Header cell',
            LI: 'List item',
            B: 'Bold text',
            STRONG: 'Bold text',
            I: 'Italic text',
            EM: 'Italic text',
            IMG: 'Image'
        };
        let label = '';
        let el = node;
        while (el && el !== pv) {
            const n = names[el.tagName];
            if (n) {
                label = n;
                break;
            }
            el = el.parentElement;
        }
        const where =
            this._activeSurface === 'header' ? 'Header — ' : this._activeSurface === 'footer' ? 'Footer — ' : '';
        this.selectionContextLabel = 'Editing: ' + where + (label || 'Page');
    };

    /**
     * #247 — which editable surface (body canvas or chrome band) holds this node, if
     * any. Also sets _activeSurface, so a caret moved by keyboard rather than by click
     * still redirects the toolbar to the right surface.
     */
    _surfaceContaining(node) {
        if (!node) {
            return null;
        }
        const body = this._bodyCanvas();
        if (body && this._isInCanvas(node, body)) {
            this._setActiveSurface('body');
            return body;
        }
        for (const which of ['header', 'footer']) {
            const band = this.template.querySelector('.dg-chrome-band_' + which);
            if (band && this._isInCanvas(node, band)) {
                this._setActiveSurface(which);
                return band;
            }
        }
        return null;
    }

    /**
     * Which surface a node belongs to, WITHOUT changing the active one.
     *
     * _surfaceContaining doubles as the setter for _activeSurface, which is right
     * for the caret and wrong for anything driven by the pointer — hover chrome
     * must not decide what the toolbar is acting on.
     */
    _surfaceOwning(node) {
        if (!node) {
            return null;
        }
        for (const surface of this._allSurfaces()) {
            if (this._isInCanvas(node, surface)) {
                return surface;
            }
        }
        return null;
    }

    /**
     * Single writer for _activeSurface, mirroring it into a tracked flag.
     *
     * The flag drives the contextual header/footer tools in the format bar — the
     * same idiom as caretInTable, which shows the 24 table controls only when the
     * caret is in a table. Header and footer tools used to live in a separate
     * floating panel with its own raw-HTML textareas, so editing a header meant
     * leaving the page, working in a different medium, and keeping two editors of
     * the same two fields in your head. Flipped only on change, so the toolbar does
     * not re-render on every caret move.
     */
    _setActiveSurface(which) {
        this._activeSurface = which;
        const inChrome = which === 'header' || which === 'footer';
        if (this.caretInChrome !== inChrome) {
            this.caretInChrome = inChrome;
        }
        const label = which === 'header' ? 'Header' : which === 'footer' ? 'Footer' : '';
        if (this.activeChromeLabel !== label) {
            this.activeChromeLabel = label;
        }
    }
    /** True while the caret is in a running header/footer — drives the contextual row. */
    @track caretInChrome = false;
    @track activeChromeLabel = '';

    // ===== Durable caret tracker (#238 / #239 / #240) =========================
    //
    // The Designer's original model read `window.getSelection()` at the moment a
    // toolbar control fired. That works for the swatch buttons only because they
    // preventDefault() on mousedown and so never move focus. Everything else — the
    // <input type="color"> pickers (which hand focus to a native OS dialog), the chip
    // rail, the table popovers — loses the selection before its handler runs, which
    // is why colors silently did nothing and inserts always fell through to
    // pv.appendChild at the end of the document.
    //
    // The fix is to stop asking "where is the caret now?" and instead remember where
    // it last was while the canvas owned it. `_caret` is written on selectionchange
    // (above) and read by every action.
    _caret = { range: null, blockEl: null, cellEl: null };
    /** True while the caret is inside a table — drives the contextual table row. */
    @track caretInTable = false;
    // Blocks that count as "the thing the caret is in" for highlight + fill purposes.
    static get CARET_BLOCK_SELECTOR() {
        return 'p, div, h1, h2, h3, h4, h5, h6, td, th, li, blockquote, pre';
    }

    /** Capture caret position + its block/cell context. Called while the canvas is focused. */
    _recordCaret(node, pv) {
        try {
            const sel = window.getSelection();
            const range = sel && sel.rangeCount ? sel.getRangeAt(0).cloneRange() : null;
            const el = node && node.nodeType === 3 ? node.parentElement : node;
            const blockEl = el && el.closest ? el.closest(DocGenAdmin.CARET_BLOCK_SELECTOR) : null;
            const cellEl = el && el.closest ? el.closest('td, th') : null;
            this._caret = { range, blockEl, cellEl };
            this._paintActiveBlock(pv, blockEl, cellEl);
            // Drives the contextual table row. Kept as a tracked boolean flipped only
            // on change, so the toolbar does not re-render on every caret move.
            const inTable = !!cellEl || !!(this._cellSel && this._cellSel.length);
            if (this.caretInTable !== inTable) {
                this.caretInTable = inTable;
            }
            this._syncSelectionBubble();
        } catch (e) {
            /* best effort — a stale caret beats no caret */
        }
    }

    /**
     * #238 — mark where you are. CSS cannot thicken or restyle a caret beyond
     * `caret-color`, and a 1px bar is genuinely hard to find on a pill-dense page, so
     * the containing block (and cell, when in a table) gets a tint instead.
     *
     * Applied as INLINE style, not via docGenAdmin.css: the canvas is an
     * lwc:dom="manual" host and component styles do not reach nodes written into it by
     * hand — the same reason _showDropMarker sets style.cssText directly.
     *
     * Because it is inline it would otherwise serialize into the saved body, so the
     * author's original `style` attribute is captured verbatim and put back the moment
     * the caret moves (and unconditionally before serialization).
     */
    _paintActiveBlock(pv, blockEl, cellEl) {
        if (!pv) {
            return;
        }
        try {
            const target = cellEl || blockEl;
            if (this._paintedEl === target) {
                return;
            }
            // Sweep EVERY painted element, not just the one we think we painted.
            // Three systems tint things — the active block, the Excel-style cell
            // selection and the table band hover — and each kept its own bookkeeping.
            // When one repainted an element another had already touched, the restore
            // bookkeeping went stale and the tint was stranded, so moving block to
            // block or cell to cell left several areas lit at once.
            this._clearActiveBlockPaint();
            if (!target || target === pv) {
                return;
            }
            this._paintedEl = target;
            target.setAttribute('data-dg-paint', 'block');
            // NO background-color, and NO style-attribute snapshot. See the
            // CHROME PROPERTY RULE above _clearActiveBlockPaint: this highlight
            // used to tint the background and restore the whole style attribute it
            // captured on arrival, so a fill applied while the caret sat in the cell
            // — which is the normal order: click the cell, then click the swatch —
            // was reverted the moment the caret moved on.
            const isCell = target.tagName === 'TD' || target.tagName === 'TH';
            if (isCell) {
                target.style.outline = '2px solid #7c3aed';
                target.style.outlineOffset = '-2px';
            } else {
                target.style.boxShadow = '-3px 0 0 0 #7c3aed';
            }
        } catch (e) {
            /* highlight is cosmetic — never let it break editing */
        }
    }

    /**
     * THE CHROME PROPERTY RULE
     * ------------------------
     * Editor chrome is drawn with inline styles, because component CSS cannot reach
     * nodes inside an lwc:dom="manual" host. That makes the canvas a shared writing
     * surface between the editor and the author, and it only stays safe under two
     * rules:
     *
     *   1. Chrome NEVER writes a property the author can write. Each system owns
     *      its own channel — caret highlight: outline (cells) / box-shadow (blocks);
     *      cell selection: inset box-shadow; band hover: filter. background-color
     *      belongs to the author alone.
     *   2. Chrome NEVER snapshots and restores a whole style attribute. A snapshot
     *      is a photograph of the element at one instant, and every edit the author
     *      makes afterwards is erased when it is put back.
     *
     * Both rules were broken here, and between them they are why a cell fill would
     * not stick: the highlight tinted background-color, captured the style attribute
     * on arrival, and restored it on departure — so a fill applied while the caret
     * was in the cell lived exactly as long as the caret stayed there.
     *
     * Sweeping by marker rather than by remembered reference is what stops tints
     * being stranded when the canvas re-renders or two systems touch one element.
     *
     * As a bonus, outline and filter are both ignored by Flying Saucer, so even if a
     * tint ever did leak into a saved template it could not change the PDF.
     */
    _clearActiveBlockPaint() {
        const el = this._paintedEl;
        this._paintedEl = null;
        if (el) {
            try {
                this._stripCaretProps(el);
                el.removeAttribute('data-dg-paint');
            } catch (e) {
                /* detached */
            }
        }
        // Scoped to the caret highlight's own marker. Sweeping every [data-dg-paint]
        // also hit the row/column hover tint, which is applied OVER the author's
        // fill — clearing that blind was the first half of "tables keep overwriting
        // fill colors". Each system undoes only its own tint.
        for (const surface of this._allSurfaces()) {
            let stragglers;
            try {
                stragglers = surface.querySelectorAll('[data-dg-paint="block"]');
            } catch (e) {
                continue;
            }
            for (const node of stragglers) {
                this._stripCaretProps(node);
                node.removeAttribute('data-dg-paint');
            }
        }
    }

    /** The caret highlight's own channels — outline on cells, a bar on blocks. */
    _stripCaretProps(el) {
        el.style.outline = '';
        el.style.outlineOffset = '';
        el.style.boxShadow = '';
        if (!el.getAttribute('style')) {
            el.removeAttribute('style');
        }
    }

    /**
     * Every channel any chrome system is allowed to write, and nothing else.
     *
     * background-color is deliberately absent: it is the author's, and clearing it
     * is what destroyed cell fills. Drops the style attribute entirely once empty so
     * serialized HTML does not accumulate `style=""`.
     */
    _stripChromeProps(el) {
        el.style.outline = '';
        el.style.outlineOffset = '';
        el.style.boxShadow = '';
        el.style.filter = '';
        el.style.backgroundClip = '';
        if (!el.getAttribute('style')) {
            el.removeAttribute('style');
        }
    }

    /**
     * Drop every transient editor tint, each undone by the system that applied it.
     *
     * The caret highlight restores four properties; the row/column hover tint
     * restores a captured style attribute verbatim, because it paints over whatever
     * fill the author already set. Anything that serializes or snapshots the canvas
     * must go through here, or it bakes editor chrome into the saved template.
     */
    _clearEditorPaint() {
        this._highlightTableBand(null);
        this._clearActiveBlockPaint();
        // Deliberately does NOT touch the cell SELECTION.
        //
        // The selection is a model (_cellSel) as well as a highlight, and it is what
        // "fill these four cells" means. Clearing it here destroyed multi-cell fill
        // outright: handleTableAction captures undo first, undo snapshots, the
        // snapshot cleared the selection, and the fill then had nothing left to
        // apply to but the caret's own cell. Its chrome is stripped from the
        // serialized COPY by _unpillifyTags, which is the right place — that strips
        // what is being saved without touching what the author has selected.
        for (const surface of this._allSurfaces()) {
            let residue;
            try {
                residue = surface.querySelectorAll('[data-dg-paint]');
            } catch (e) {
                continue;
            }
            for (const el of residue) {
                this._stripChromeProps(el);
                el.removeAttribute('data-dg-paint');
            }
        }
    }

    _paintedEl = null;

    /**
     * The editing surface the caret is currently in.
     *
     * #247 — the Designer now has three editable surfaces, not one: the page body and
     * the running header/footer bands. Every existing caller of _canvas() (formatting,
     * table tools, chip insert, the caret tracker) becomes header-aware for free by
     * resolving through here, which is why the bands support the full toolbar rather
     * than being a second, weaker editor.
     */
    _activeSurface = 'body';

    _canvas() {
        if (this._activeSurface === 'header' || this._activeSurface === 'footer') {
            const band = this.template.querySelector('.dg-chrome-band_' + this._activeSurface);
            if (band && band.isConnected) {
                return band;
            }
        }
        return this._bodyCanvas();
    }

    /**
     * The page body specifically. Anything that is about the SHEET rather than about
     * the caret — zoom, page dimensions, watermark, oversize-table refitting — must use
     * this, or it would apply itself to whichever band happens to be focused.
     */
    _bodyCanvas() {
        const host = this.template.querySelector('.dg-visual-host');
        return (host && host.querySelector('.dg-pv')) || null;
    }

    // ===== Floating layer ====================================================
    //
    // CSS has no anchored positioning, so a popover declared `position: absolute`
    // inside the toolbar is at the mercy of every ancestor's overflow. That is not a
    // hypothetical: a toolbar rewrite set `overflow-x: auto`, the spec coerced
    // `overflow-y` from `visible` to `auto` with it, and every menu silently rendered
    // inside a 38px clipping box. Nothing was visible and the editor read as dead.
    //
    // The fix is structural, not a tweak: floating elements are `position: fixed` and
    // positioned in VIEWPORT coordinates from the anchor's rect, so no ancestor's
    // overflow can clip them. Placement flips when it would leave the viewport and is
    // clamped to stay on screen — the collision behaviour Floating UI exists to provide.
    //
    // @param anchorEl  the control the floating element belongs to
    // @param floatEl   the floating element (must be position: fixed in CSS)
    // @param opts      { gap, prefer: 'bottom'|'top', align: 'start'|'center'|'end' }
    _positionFloating(anchorEl, floatEl, opts = {}) {
        if (!anchorEl || !floatEl) {
            return;
        }
        const gap = opts.gap == null ? 6 : opts.gap;
        const prefer = opts.prefer || 'bottom';
        const align = opts.align || 'start';
        try {
            // Measure only after the element is laid out; callers call this from
            // renderedCallback or immediately after making it visible.
            const a = anchorEl.getBoundingClientRect();
            const f = floatEl.getBoundingClientRect();
            const vw = document.documentElement.clientWidth;
            const vh = document.documentElement.clientHeight;
            const fw = f.width || floatEl.offsetWidth || 160;
            const fh = f.height || floatEl.offsetHeight || 120;

            // Vertical: use the preferred side unless it would overflow AND the other
            // side has more room.
            const roomBelow = vh - a.bottom;
            const roomAbove = a.top;
            let top;
            if (prefer === 'top') {
                top = roomAbove >= fh + gap || roomAbove >= roomBelow ? a.top - fh - gap : a.bottom + gap;
            } else {
                top = roomBelow >= fh + gap || roomBelow >= roomAbove ? a.bottom + gap : a.top - fh - gap;
            }

            // Horizontal: align to the anchor, then clamp into the viewport so a
            // control near the right edge does not push its menu off screen.
            let left;
            if (align === 'center') {
                left = a.left + a.width / 2 - fw / 2;
            } else if (align === 'end') {
                left = a.right - fw;
            } else {
                left = a.left;
            }
            const margin = 8;
            left = Math.max(margin, Math.min(left, vw - fw - margin));
            top = Math.max(margin, Math.min(top, vh - fh - margin));

            floatEl.style.position = 'fixed';
            floatEl.style.left = Math.round(left) + 'px';
            floatEl.style.top = Math.round(top) + 'px';
            floatEl.style.zIndex = '9000';
        } catch (e) {
            /* positioning is best-effort — never break the editor over chrome */
        }
    }

    /**
     * Reposition every open floating element. Bound to scroll/resize while something
     * is open, because `fixed` coordinates are viewport-absolute and go stale the
     * moment anything moves.
     */
    _repositionFloatingLayer = () => {
        const openMenu = this.template.querySelector('.dg-fmt-menu');
        if (openMenu && this._floatAnchor && this._floatAnchor.isConnected) {
            this._positionFloating(this._floatAnchor, openMenu);
        }
        const bubble = this.template.querySelector('.dg-sel-bubble');
        if (bubble && this.selectionBubble) {
            this._positionSelectionBubble(bubble);
        }
        const pm = this.template.querySelector('.dg-pill-menu');
        if (pm && this._floatAnchor && this._floatAnchor.isConnected) {
            this._positionFloating(this._floatAnchor, pm, { gap: 6 });
        }
    };

    _watchFloatingLayer(on) {
        if (on && !this._floatWatching) {
            window.addEventListener('scroll', this._repositionFloatingLayer, true);
            window.addEventListener('resize', this._repositionFloatingLayer);
            this._floatWatching = true;
        } else if (!on && this._floatWatching) {
            window.removeEventListener('scroll', this._repositionFloatingLayer, true);
            window.removeEventListener('resize', this._repositionFloatingLayer);
            this._floatWatching = false;
        }
    }
    _floatWatching = false;
    _floatAnchor = null;

    // ===== Selection bubble ==================================================
    //
    // The third layer of the editor's chrome, alongside the persistent bar and the
    // slash menu. Research on block editors is consistent that you need all three:
    // a bubble for "format what I just selected", a static bar for discoverability,
    // and slash for "insert something new". The bubble is what earns the persistent
    // bar the right to be small.
    //
    // Deliberately additive: nothing is removed from the toolbar to make this work,
    // so it cannot repeat the fae4f53 failure where controls were relocated into
    // chrome that turned out not to render.
    @track selectionBubble = null;

    /** A trimmed swatch set — the bubble is for quick hits, not the full palette. */
    get bubbleColorSwatches() {
        return (this.textColorSwatches || []).slice(0, 5);
    }

    // ===== Toolbar popovers ==================================================
    //
    // 13 colour swatches, 4 font buttons and an alignment row sat permanently in the
    // bar — a menu pretending to be a toolbar. They move behind three triggers here.
    //
    // This is the change that broke the editor last time, so it is built differently:
    // the popover uses the PROVEN fixed-position floating layer (_positionFloating,
    // already covered by smoke assertions for clipping and hit-testing), and the
    // inline controls are only removed after the popover is verified green.
    @track openFmtMenu = null;

    handleFmtMenuToggle(event) {
        const which = event.currentTarget.dataset.menu;
        const next = this.openFmtMenu === which ? null : which;
        this.openFmtMenu = next;
        this._floatAnchor = next ? event.currentTarget : null;
        this._watchFloatingLayer(!!next || !!this.selectionBubble);
    }

    closeFmtMenu() {
        this.openFmtMenu = null;
        this._watchFloatingLayer(!!this.selectionBubble);
    }

    get isTextColorMenuOpen() {
        return this.openFmtMenu === 'textColor';
    }
    get isHighlightMenuOpen() {
        return this.openFmtMenu === 'highlight';
    }
    get isFontMenuOpen() {
        return this.openFmtMenu === 'font';
    }
    get isAlignMenuOpen() {
        return this.openFmtMenu === 'align';
    }

    /** Current text colour, painted as the underbar on the trigger. */
    get textColorBarStyle() {
        return 'background:' + (this._lastTextColor || '#16325c') + ';';
    }
    get highlightBarStyle() {
        return 'background:' + (this._lastHighlight || '#fef3c7') + ';';
    }
    _lastTextColor = '#16325c';
    _lastHighlight = '#fef3c7';

    /** Show/hide the bubble as the selection changes inside any editing surface. */
    _syncSelectionBubble() {
        if (!this.showHtmlBodyVisual) {
            if (this.selectionBubble) {
                this.selectionBubble = null;
                this._watchFloatingLayer(false);
            }
            return;
        }
        let show = false;
        try {
            const sel = window.getSelection();
            if (sel && sel.rangeCount && !sel.isCollapsed) {
                const node = sel.getRangeAt(0).startContainer;
                const el = node && node.nodeType === 3 ? node.parentElement : node;
                // Only for real text selections inside an editable surface — a
                // pill-only selection has its own menu.
                if (el && this._surfaceContaining(el) && (sel.toString() || '').trim().length) {
                    show = true;
                }
            }
        } catch (e) {
            show = false;
        }
        if (show !== !!this.selectionBubble) {
            this.selectionBubble = show ? { visible: true } : null;
            this._watchFloatingLayer(show || !!this.openFmtMenu);
        }
    }

    /**
     * Park the bubble ABOVE the selection where there is room, below it otherwise —
     * it must never cover the text being formatted.
     */
    _positionSelectionBubble(bubbleEl) {
        try {
            const sel = window.getSelection();
            if (!sel || !sel.rangeCount) {
                return;
            }
            const rects = sel.getRangeAt(0).getClientRects();
            const r = rects && rects.length ? rects[0] : sel.getRangeAt(0).getBoundingClientRect();
            if (!r || (!r.width && !r.height)) {
                return;
            }
            // Synthesize an anchor rect from the selection itself.
            const anchor = {
                getBoundingClientRect: () => r
            };
            this._positionFloating(anchor, bubbleEl, { gap: 8, prefer: 'top', align: 'center' });
            // _positionFloating clamps into the viewport, and that clamp can land the
            // bubble back on top of the very text it is meant to format — there is no
            // room above near the top of the screen, and the flip below can still be
            // pulled back up. Detect the overlap and force it to the side with room.
            const full = sel.getRangeAt(0).getBoundingClientRect();
            const br = bubbleEl.getBoundingClientRect();
            const overlaps = br.bottom > full.top + 2 && br.top < full.bottom - 2;
            if (overlaps) {
                const vh = document.documentElement.clientHeight;
                const below = full.bottom + 8;
                const above = full.top - br.height - 8;
                // Prefer whichever side actually fits; below wins ties because the
                // sticky toolbar occupies the top of the canvas.
                const top = below + br.height <= vh ? below : Math.max(2, above);
                bubbleEl.style.top = Math.round(top) + 'px';
            }
        } catch (e) {
            /* best effort */
        }
    }

    /**
     * #247 — mount the header/footer bands: write their stored HTML in, turn on
     * contenteditable, pillify merge tags, and wire the listeners that keep the
     * template record in sync. Runs from renderedCallback alongside the body canvas.
     */
    _mountChromeBands() {
        for (const which of ['header', 'footer']) {
            const band = this.template.querySelector('.dg-chrome-band_' + which);
            if (!band) {
                continue;
            }
            const stored = (which === 'header' ? this.editTemplateHeaderHtml : this.editTemplateFooterHtml) || '';
            if (this._bandMounted !== band || this._bandSource[which] !== stored) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM band write; content is re-cleaned by _extractBandHtml on the way out
                band.innerHTML = stored || '<p><br/></p>';
                this._bandSource[which] = stored;
                band.setAttribute('contenteditable', 'true');
                band.setAttribute('spellcheck', 'false');
                this._pillifyTags(band);
            }
            this._matchBandTypographyToPage(band);
            if (band.dataset.dgWired === '1') {
                continue;
            }
            band.dataset.dgWired = '1';
            band.addEventListener('focusin', () => {
                this._setActiveSurface(which);
                this._canvasFocused = true;
            });
            // Same undo capture as the body canvas — the bands are edit surfaces
            // for two template fields, and Ctrl+Z has to mean the same thing in all
            // three or the author learns it is unreliable.
            band.addEventListener('input', () => {
                this._setActiveSurface(which);
                this._syncBandToRecord(which, band);
                this._maybePillifyTyped();
                // The ` / [ insert menu. _maybeOpenSlashMenu resolves its surface
                // through _surfaceContaining and has always handled the bands — it
                // was simply never called from one, so the menu could only ever be
                // opened in the body.
                this._maybeOpenSlashMenu();
            });
            band.addEventListener('keydown', (e) => {
                if (this._undoKeydown(e)) {
                    return;
                }
                // BEFORE the Enter handler, exactly as on the body canvas: while the
                // insert menu is open it owns arrows/Enter/Escape, and Enter there
                // means "pick this item", not "break the line".
                if (this._slashMenuKeydown(e)) {
                    return;
                }
                if (this._handleTabKey(e)) {
                    return;
                }
                // Tight line spacing matters most of all in a running header, where
                // an address block is the common case and a paragraph gap between
                // its lines is never what the author wanted.
                if (this._handleEnterKey(e)) {
                    e.stopPropagation();
                    return;
                }
                e.stopPropagation();
            });
            // Image resize/move — the same handlers the body canvas gets.
            //
            // Without them, dragging an image's corner in a band fell through to the
            // browser's NATIVE image drag inside a contenteditable, which copies the
            // image rather than resizing it: "resizing images in the header adds
            // additional images and duplicates it". _imgResizeStart preventDefaults
            // on mousedown, which is what stops the native drag ever starting.
            // Everything else behaves exactly as it does on the page — one list,
            // one place. See _wireSurfaceInteractions.
            this._wireSurfaceInteractions(band);
        }
        this._bandMounted = this.template.querySelector('.dg-chrome-band_header');
    }
    _bandMounted = null;
    _bandSource = { header: null, footer: null };

    /**
     * Give a band the PAGE's typography.
     *
     * The template's own CSS is scoped to `.dg-pv` by scopeHtmlForInlinePreview, and
     * the bands live outside it, so they fell back to the Salesforce UI font at a UI
     * size in a UI grey. A running header prints in the DOCUMENT's typeface at the
     * document's size — so the band was showing the author something that would never
     * appear in the PDF, in the one place where "what you see is what prints" is the
     * entire point of putting it on the sheet.
     *
     * Copies the computed values rather than the declared ones, so a template whose
     * font comes from a stylesheet, a `body` rule or a default all resolve the same
     * way. Inline, because component CSS cannot reach an lwc:dom="manual" node.
     */
    _matchBandTypographyToPage(band) {
        const pv = this._bodyCanvas();
        if (!pv || !band) {
            return;
        }
        try {
            const cs = getComputedStyle(pv);
            band.style.fontFamily = cs.fontFamily;
            band.style.fontSize = cs.fontSize;
            band.style.lineHeight = cs.lineHeight;
            // Colour goes through custom properties rather than `color` directly, so
            // the CSS above can swap between the dim and full-strength inks on focus
            // — an inline `color` would win over both. The dim is alpha on the
            // document's OWN ink, so it stays the author's colour, just quieter.
            const ink = cs.color || 'rgb(44, 44, 56)';
            band.style.setProperty('--dg-band-ink', ink);
            band.style.setProperty('--dg-band-ink-dim', this._dimInk(ink));
        } catch (e) {
            /* cosmetic — never let it break mounting the band */
        }
    }

    /** rgb()/rgba() → the same colour at 62% alpha. Falls back to the input. */
    _dimInk(color) {
        const m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/i.exec(color || '');
        return m ? `rgba(${m[1]}, ${m[2]}, ${m[3]}, 0.62)` : color;
    }

    /**
     * Serialize a band back to its template field, pills unwrapped to plain tags.
     *
     * markDirty is false when the caller is only READING the model (preview, View
     * Source), so looking at the document cannot make it look edited.
     */
    _syncBandToRecord(which, band, markDirty = true) {
        const html = this._extractBandHtml(band);
        if (which === 'header') {
            this.editTemplateHeaderHtml = html;
        } else {
            this.editTemplateFooterHtml = html;
        }
        // Keep the remount guard in step, or the next render would overwrite what the
        // author is typing with the value they started from.
        this._bandSource[which] = html;
        if (markDirty) {
            this.htmlEditorDirty = true;
        }
    }

    /**
     * Band → clean HTML. Same string-round-trip discipline as _extractVisualBody:
     * read innerHTML as a STRING and re-parse, never cloneNode, because under the LWS
     * namespace sandbox cloneNode silently drops nodes native contenteditable inserted.
     */
    _extractBandHtml(band) {
        this._clearEditorPaint();
        const tpl = document.createElement('template');
        // eslint-disable-next-line @lwc/lwc/no-inner-html -- string round-trip of a live band; re-cleaned below, never cloneNode (LWS drops browser-inserted nodes)
        tpl.innerHTML = band.innerHTML;
        const root = tpl.content;
        for (const el of root.querySelectorAll('style, .dg-drop-marker')) {
            el.remove();
        }
        this._unpillifyTags(root);
        const container = document.createElement('div');
        container.appendChild(root);
        // eslint-disable-next-line @lwc/lwc/no-inner-html -- serialize the cleaned fragment back to a string
        const out = container.innerHTML.trim();
        // The placeholder an empty band is seeded with must not become real content.
        return out === '<p><br></p>' || out === '<p><br/></p>' ? '' : out;
    }

    // ===== #244: Designer zoom ===============================================
    // A document with several merge-tag pills in one table cell is far denser on
    // screen than it will be in the PDF — pills carry padding and a border — which
    // makes precise cursor placement hard exactly where it matters most.
    //
    // Implemented as a CSS transform on the canvas. It is a VIEW setting only: the
    // transform lives on .dg-pv itself, and serialization reads pv.innerHTML (children
    // only), so zoom can never reach the saved template body.
    @track designerZoom = 1;

    get zoomOptions() {
        const opts = [0.5, 0.75, 1, 1.25, 1.5, 2].map((z) => ({
            value: String(z),
            label: Math.round(z * 100) + '%',
            selected: z === this.designerZoom
        }));
        // Fit width — a Letter page is 816px, so on a 1358px column 40% of the
        // screen was empty desk at 100%. This spends it on the document.
        opts.push({ value: 'fit', label: 'Fit width', selected: this._zoomIsFit });
        return opts;
    }
    _zoomIsFit = false;

    /** Scale that makes the page fill the available column, less breathing room. */
    _fitWidthZoom() {
        const pv = this._bodyCanvas();
        const col = this.template.querySelector('.dg-designer-canvas-col');
        if (!pv || !col) {
            return 1;
        }
        const pageW = parseFloat(pv.style.width) || pv.getBoundingClientRect().width || 816;
        const avail = col.getBoundingClientRect().width - 56;
        if (!(avail > 0) || !(pageW > 0)) {
            return 1;
        }
        // Clamped: never below 50% (unreadable) and never above 200% (the sheet
        // would dwarf the chrome).
        return Math.max(0.5, Math.min(2, Math.round((avail / pageW) * 100) / 100));
    }

    // ===== Focus mode ========================================================
    //
    // 389px of chrome sat above the toolbar on a 900px screen — 43% of the viewport
    // spent before any document was visible. Focus mode collapses the secondary rows
    // (template picker, save/edit, page setup, status) and leaves the toolbar and the
    // page. Nothing is removed, only hidden, and one click brings it all back.
    @track focusMode = false;

    get focusModeLabel() {
        return this.focusMode ? 'Exit focus' : 'Focus';
    }

    get designerShellClass() {
        return this.focusMode ? 'dg-designer-chrome dg-designer-chrome_focus' : 'dg-designer-chrome';
    }

    handleToggleFocusMode() {
        this.focusMode = !this.focusMode;
        // Re-fit after the layout settles: collapsing the chrome changes the space
        // the page has to fill.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (this._zoomIsFit) {
                this.designerZoom = this._fitWidthZoom();
            }
            this._applyZoom();
            this._applyCanvasDimensions();
        }, 60);
    }

    get zoomLabel() {
        return Math.round(this.designerZoom * 100) + '%';
    }

    handleZoomChange(event) {
        const raw = event.currentTarget.value;
        if (raw === 'fit') {
            this._zoomIsFit = true;
            this.designerZoom = this._fitWidthZoom();
            this._applyZoom();
            return;
        }
        const z = parseFloat(raw);
        if (!isNaN(z)) {
            this._zoomIsFit = false;
            this.designerZoom = z;
            this._applyZoom();
        }
    }

    handleZoomStep(event) {
        const dir = parseFloat(event.currentTarget.dataset.zstep) || 0;
        const steps = [0.5, 0.75, 1, 1.25, 1.5, 2];
        let idx = steps.indexOf(this.designerZoom);
        if (idx === -1) {
            idx = steps.indexOf(1);
        }
        idx = Math.min(steps.length - 1, Math.max(0, idx + dir));
        this.designerZoom = steps[idx];
        this._applyZoom();
    }

    /** Ctrl/Cmd + wheel zooms, matching every other canvas tool. */
    handleCanvasWheel = (event) => {
        if (!this.showHtmlBodyVisual || !(event.ctrlKey || event.metaKey)) {
            return;
        }
        event.preventDefault();
        this.handleZoomStep({ currentTarget: { dataset: { zstep: event.deltaY < 0 ? '1' : '-1' } } });
    };

    /**
     * Zoom the SHEET — body page and both running-chrome bands together.
     *
     * Previously this scaled only the body canvas, so zooming in left the header and
     * footer at their original size: the page grew out from under its own chrome. They
     * are part of the same sheet and have to scale as one, which is also the only way
     * the Word-style margin layout stays true at any zoom level.
     */
    _applyZoom() {
        const z = this.designerZoom || 1;
        const targets = this._allSurfaces();
        if (!targets.length) {
            return;
        }
        for (const el of targets) {
            try {
                el.style.transformOrigin = 'top center';
                el.style.transform = z === 1 ? '' : `scale(${z})`;
            } catch (e) {
                /* zoom is cosmetic — never let it break editing */
            }
        }
        this._reserveZoomSpace();
        this._watchSurfaceGrowth();
        this._applyPillSpread();
    }

    /**
     * Give each scaled surface the layout space its transform actually occupies.
     *
     * `transform: scale()` does NOT change an element's layout box, so at 150% a
     * 189px-tall running header paints 284px tall while the flow still believes it
     * is 189px. The page therefore starts 73px INSIDE the header, and because the
     * band is an earlier sibling it loses the paint order and disappears behind the
     * page — "the header does not push the body down and ends up behind it".
     *
     * The margin was already being reserved, but only at the moment the zoom
     * CHANGED. A band that grew afterwards — which is the entire lifecycle of a
     * header being authored — kept the reservation computed for its old height.
     * That is why it took a big header to show up.
     */
    _reserveZoomSpace() {
        const z = this.designerZoom || 1;
        for (const el of this._allSurfaces()) {
            try {
                if (z <= 1) {
                    if (el.style.marginBottom) {
                        el.style.marginBottom = '';
                    }
                    continue;
                }
                // offsetHeight is the LAYOUT height, unaffected by the transform.
                const want = Math.round((z - 1) * (el.offsetHeight || 0)) + 'px';
                if (el.style.marginBottom !== want) {
                    el.style.marginBottom = want;
                }
            } catch (e) {
                /* cosmetic */
            }
        }
    }

    /**
     * Recompute the reservation whenever a surface changes size, whatever caused it.
     *
     * Hooking the input handlers would miss every other growth path — an inserted
     * table, an undo, an image finishing loading, a webfont settling. Observing the
     * elements catches all of them for one listener. Setting margin-bottom does not
     * change an observed element's own box, so this cannot feed back on itself.
     */
    _watchSurfaceGrowth() {
        if (typeof ResizeObserver === 'undefined') {
            return;
        }
        try {
            if (!this._surfaceRo) {
                this._surfaceRo = new ResizeObserver(() => this._reserveZoomSpace());
            }
            const seen = this._surfaceRoSeen || (this._surfaceRoSeen = new Set());
            for (const el of this._allSurfaces()) {
                if (!seen.has(el)) {
                    seen.add(el);
                    this._surfaceRo.observe(el);
                }
            }
        } catch (e) {
            /* observation is an optimisation — _applyZoom still reserves on change */
        }
    }
    _surfaceRo = null;
    _surfaceRoSeen = null;

    /** Body canvas + both chrome bands — every region the author can type into. */
    _allSurfaces() {
        const out = [];
        const body = this._bodyCanvas();
        if (body) {
            out.push(body);
        }
        for (const which of ['header', 'footer']) {
            const band = this.template.querySelector('.dg-chrome-band_' + which);
            if (band) {
                out.push(band);
            }
        }
        return out;
    }

    /**
     * Zooming in must make dense merge-tag areas EASIER TO EDIT, not merely bigger.
     *
     * A pure transform scales the crowding along with everything else — four pills
     * jammed into one table cell are still four pills jammed into one cell, just larger.
     * Above 100% pills therefore gain horizontal margin, padding and line-height ON TOP
     * of the scale, which pulls them into individually clickable targets and lets a
     * cramped cell wrap onto more lines.
     *
     * Safe to mutate: _unpillifyTags keeps only font-weight/style/decoration/colour/
     * family/size from a pill when serializing, so margin, padding and line-height are
     * dropped on the way out and can never reach the saved template.
     */
    _applyPillSpread() {
        const z = this.designerZoom || 1;
        // Nothing below 1x — shrinking should stay faithful to the printed layout.
        const extra = z > 1 ? z - 1 : 0;
        for (const surface of this._allSurfaces()) {
            let pills;
            try {
                pills = surface.querySelectorAll('[data-dg-tag]');
            } catch (e) {
                continue;
            }
            for (const pill of pills) {
                if (extra === 0) {
                    pill.style.margin = '';
                    pill.style.lineHeight = '';
                    pill.style.padding = '0 6px';
                    continue;
                }
                pill.style.margin = `${(extra * 2.5).toFixed(1)}px ${(extra * 7).toFixed(1)}px`;
                pill.style.padding = `0 ${(6 + extra * 5).toFixed(1)}px`;
                pill.style.lineHeight = (1 + extra * 0.55).toFixed(2);
            }
        }
    }

    /**
     * Put the caret back where the author left it, and — critically — return focus to
     * the canvas FIRST. `document.execCommand` is a no-op while an <input> or another
     * window holds focus, which was the whole reason the color pickers appeared to do
     * nothing. Returns true when a caret was restored.
     */
    _restoreCaret() {
        const pv = this._canvas();
        if (!pv) {
            return false;
        }
        // If the LIVE selection is already inside an editable surface, it is the truth —
        // leave it alone. Restoring unconditionally overwrote a perfectly good selection
        // with a remembered (and possibly stale, or detached by a re-render) one, which
        // is why align-left, ordered-list and clear-formatting could silently no-op:
        // the command ran against the wrong range. Only restore when the live selection
        // has actually been lost.
        try {
            const live = window.getSelection();
            if (live && live.rangeCount) {
                const node = live.getRangeAt(0).startContainer;
                const el = node && node.nodeType === 3 ? node.parentElement : node;
                if (el && this._surfaceContaining(el)) {
                    return true;
                }
            }
        } catch (e) {
            /* fall through to the remembered caret */
        }
        const range = (this._caret && this._caret.range) || this._savedFmtRange || this._lastCanvasRange;
        try {
            pv.focus();
        } catch (e) {
            /* focus is best-effort */
        }
        if (!range) {
            return false;
        }
        try {
            // A range whose containers were detached by a re-render throws on addRange
            // (or silently selects nothing). Verify it still points into a live surface.
            const anchor =
                range.startContainer && range.startContainer.nodeType === 3
                    ? range.startContainer.parentElement
                    : range.startContainer;
            if (!anchor || !anchor.isConnected || !this._surfaceContaining(anchor)) {
                return false;
            }
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            return true;
        } catch (e) {
            return false;
        }
    }

    /**
     * Containment test that survives the LWS namespace sandbox. `pv.contains(el)` can
     * report false for a node that IS inside the canvas when the two are different
     * proxy identities for the same underlying node — the failure behind #240's
     * "always inserts at the bottom". Walking parentNode compares each hop directly.
     */
    _isInCanvas(el, pv) {
        if (!el || !pv) {
            return false;
        }
        try {
            if (pv.contains(el)) {
                return true;
            }
        } catch (e) {
            /* fall through to the manual walk */
        }
        let cur = el;
        let hops = 0;
        while (cur && hops < 200) {
            if (cur === pv) {
                return true;
            }
            cur = cur.parentNode;
            hops++;
        }
        return false;
    }

    // ===== Designer undo stack (DESIGNER_PLAN_V2 step 1) ======================
    //
    // Every structural edit in this editor is direct DOM surgery —
    // insertAdjacentElement, remove(), _safeReplace. The browser's native undo
    // stack has no record of any of it, so Ctrl+Z stepped straight PAST an
    // inserted row or a moved block to whatever execCommand last did. There was
    // nothing to undo to, because no state was ever captured.
    //
    // This captures it. _pushUndo(label) snapshots all three editable surfaces
    // (body + running header + running footer) as HTML STRINGS before a mutation
    // runs, so undo restores the whole document, not one surface.
    //
    // Snapshots, deliberately, rather than an operation log: the ~15 mutation
    // sites are already written as DOM surgery, so an operation log would mean
    // rewriting every one of them with an inverse and keeping the pair in sync
    // forever. A snapshot is one call at the top of the handler and cannot drift
    // out of sync with the operation it describes.
    //
    // The stack owns TYPING TOO (via beforeinput, coalesced into bursts) rather
    // than leaving plain text edits to native undo. Two undo stacks racing over
    // one document is the exact failure being fixed here: whichever one the
    // browser picks, the other's history is silently wrong. One stack, one
    // model, and Ctrl+Z is preventDefault-ed so native undo never also fires.
    _undoStack = [];
    _redoStack = [];
    /** Label + timestamp of the last capture, for burst coalescing. */
    _undoMark = { label: null, ts: 0 };
    /** Snapshots are strings and a large template is ~100KB — memory needs a bound. */
    UNDO_CAP = 50;
    /** Same-label edits inside this window are one logical step. */
    UNDO_COALESCE_MS = 700;
    @track canUndo = false;
    @track canRedo = false;

    get undoDisabled() {
        return !this.canUndo;
    }
    get redoDisabled() {
        return !this.canRedo;
    }

    /**
     * All three surfaces as HTML strings, or null when the canvas is not mounted.
     *
     * The caret highlight is stripped first. It is applied as `data-dg-paint` plus
     * inline style on a LIVE block (component CSS cannot reach manual-DOM nodes), so
     * a snapshot that kept it would restore a purple tint onto a block the caret had
     * since left, and would make two otherwise-identical documents compare unequal —
     * defeating the dedupe that stops the stack filling with no-ops. Same discipline
     * _extractVisualBody already uses before serializing to save.
     *
     * It is put straight back afterwards, so the author never sees it blink.
     */
    _snapshotSurfaces() {
        const body = this._bodyCanvas();
        if (!body) {
            return null;
        }
        const painted = this._paintedEl;
        this._clearEditorPaint();
        // eslint-disable-next-line @lwc/lwc/no-inner-html -- READ, not a write: snapshots the canvas for undo. Reading innerHTML injects nothing, and under LWS the string is the ONLY faithful way to capture the canvas (cloneNode silently omits browser-inserted nodes — the v3.41 bug).
        const snap = { body: body.innerHTML, header: null, footer: null };
        for (const which of ['header', 'footer']) {
            const band = this.template.querySelector('.dg-chrome-band_' + which);
            if (band) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- READ, not a write; same undo snapshot as above.
                snap[which] = band.innerHTML;
            }
        }
        if (painted && painted.isConnected) {
            this._paintActiveBlock(body, painted, null);
        }
        return snap;
    }

    _sameSnapshot(a, b) {
        return !!a && !!b && a.body === b.body && a.header === b.header && a.footer === b.footer;
    }

    /**
     * Capture the document as it stands RIGHT NOW, before the caller mutates it.
     * Call this at the TOP of a mutating handler, never after.
     */
    _pushUndo(label) {
        if (!this.showHtmlBodyVisual || this._restoringUndo) {
            return;
        }
        const snap = this._snapshotSurfaces();
        if (!snap) {
            return;
        }
        const now = Date.now();
        const top = this._undoStack[this._undoStack.length - 1];
        // A typing burst is one logical edit — one Ctrl+Z should take the word
        // back, not one keystroke. Coalescing is limited to `type:` labels on
        // purpose: two Bold clicks or two + presses are two deliberate acts and
        // each deserves its own step, however fast they land.
        const coalescing =
            label &&
            label.indexOf('type:') === 0 &&
            this._undoMark.label === label &&
            now - this._undoMark.ts < this.UNDO_COALESCE_MS &&
            top;
        if (coalescing || this._sameSnapshot(top, snap)) {
            this._undoMark = { label, ts: now };
            return;
        }
        snap.label = label || 'edit';
        this._undoStack.push(snap);
        if (this._undoStack.length > this.UNDO_CAP) {
            this._undoStack.shift();
        }
        // A fresh edit forks the timeline — anything redone from here is gone.
        this._redoStack = [];
        this._undoMark = { label, ts: now };
        this.canUndo = true;
        this.canRedo = false;
    }

    /**
     * Write a snapshot back into the live surfaces.
     *
     * innerHTML, not node grafting: under the LWS namespace sandbox the nodes an
     * innerHTML write creates are sandbox-owned and therefore behave, which is the
     * same reason _extractVisualBody reads the string rather than cloning.
     *
     * Everything the canvas hangs off a specific NODE has to be re-established:
     * _pvStyleEl (the floor guard's handle on the scoped <style>), the zoom
     * transform and pill spread (inline styles on nodes that no longer exist), and
     * the overlays, which point at rows and blocks that were just detached.
     */
    _restoreUndoSnapshot(snap) {
        const body = this._bodyCanvas();
        if (!body || !snap) {
            return false;
        }
        this._restoringUndo = true;
        try {
            this.pillMenu = null;
            this._activePill = null;
            this._clearCellSel();
            this.tableOverlay = null;
            this._overlayTable = null;
            this.blockHandle = null;
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- restoring a snapshot this component took of its own canvas
            body.innerHTML = snap.body;
            this._pvStyleEl = body.querySelector('style');
            for (const which of ['header', 'footer']) {
                const band = this.template.querySelector('.dg-chrome-band_' + which);
                if (band && snap[which] != null) {
                    // eslint-disable-next-line @lwc/lwc/no-inner-html -- restoring a snapshot this component took of its own band
                    band.innerHTML = snap[which];
                    // The bands are the live edit surface for two template FIELDS;
                    // restoring the DOM without re-syncing would leave the record
                    // holding the undone version.
                    this._syncBandToRecord(which, band);
                }
            }
            // Pills survive as elements in the string, but a pill written by an older
            // bundle (or raw {tag} text typed before the snapshot) needs wrapping.
            // _pillifyTags is idempotent — it refuses to wrap inside an existing pill.
            this._pillifyTags(body);
            this._applyZoom();
            this._applyPillSpread();
            this.htmlEditorDirty = true;
        } finally {
            this._restoringUndo = false;
        }
        try {
            body.focus();
        } catch (e) {
            /* focus is best-effort */
        }
        return true;
    }
    _restoringUndo = false;

    handleUndo() {
        if (!this._undoStack.length) {
            return;
        }
        const current = this._snapshotSurfaces();
        const snap = this._undoStack.pop();
        if (current) {
            this._redoStack.push(current);
        }
        this._restoreUndoSnapshot(snap);
        // The next edit after an undo must start a new step, never coalesce into
        // the one that was just taken off the stack.
        this._undoMark = { label: null, ts: 0 };
        this.canUndo = this._undoStack.length > 0;
        this.canRedo = this._redoStack.length > 0;
    }

    handleRedo() {
        if (!this._redoStack.length) {
            return;
        }
        const current = this._snapshotSurfaces();
        const snap = this._redoStack.pop();
        if (current) {
            this._undoStack.push(current);
        }
        this._restoreUndoSnapshot(snap);
        this._undoMark = { label: null, ts: 0 };
        this.canUndo = this._undoStack.length > 0;
        this.canRedo = this._redoStack.length > 0;
    }

    /** A different document is now on the canvas — its history does not apply. */
    _resetUndoHistory() {
        this._undoStack = [];
        this._redoStack = [];
        this._undoMark = { label: null, ts: 0 };
        this.canUndo = false;
        this.canRedo = false;
    }

    /**
     * Wire every interaction that must behave IDENTICALLY on all three editable
     * surfaces — the page body and the two running bands.
     *
     * These used to be written out against the body canvas only, and the bands got
     * whichever ones somebody remembered. The result was a long tail of "it works
     * on the page but not in the header": no right-click menu, no double-click pill
     * editing, no table row/column handles, no toolbar state following the caret,
     * inserts landing in the wrong surface, drops silently discarded, image resizes
     * duplicating the image. Every one was found separately, by a person, after
     * shipping.
     *
     * One list, applied to every surface, is what stops that recurring. Anything
     * genuinely surface-specific (the body's caret-floor guard, the bands' field
     * sync) stays with its own surface.
     */
    _wireSurfaceInteractions(surface) {
        surface.addEventListener('click', (e) => {
            const pill = e.target && e.target.closest ? e.target.closest('[data-dg-tag]') : null;
            if (pill && pill.getAttribute('contenteditable') !== 'true') {
                e.preventDefault();
                this._openPillMenu(pill);
            } else if (!pill && e.target && e.target.tagName === 'IMG') {
                // Plain image: a toolbar target (align etc.) without a pill menu.
                this._activePill = e.target;
                this.pillMenu = null;
            } else if (!pill) {
                this.pillMenu = null;
                this._activePill = null;
                this._closeSlashMenu();
                this.ctxMenu = null;
                // A plain click clears the cell selection — except the mouseup that
                // just finished a drag-select (the toolbar and right-click do not
                // fire a surface click, so the selection survives them).
                if (!this._cellSelecting) {
                    this._clearCellSel();
                }
            }
        });
        surface.addEventListener('dblclick', (e) => {
            const pill = e.target && e.target.closest ? e.target.closest('[data-dg-tag]') : null;
            if (pill) {
                e.preventDefault();
                this._beginPillEdit(pill);
                return;
            }
            // Word-style click-and-type: double-click empty space starts a cursor.
            this._placeCaretAtPoint(e, surface);
        });
        // Right-click: contextual menu (pill menu on pills; insert/format/table
        // actions elsewhere).
        surface.addEventListener('contextmenu', (e) => {
            e.preventDefault();
            this._closeSlashMenu();
            const pill = e.target && e.target.closest ? e.target.closest('[data-dg-tag]') : null;
            if (pill && pill.getAttribute('contenteditable') !== 'true') {
                this.ctxMenu = null;
                this._openPillMenu(pill);
                return;
            }
            this.pillMenu = null;
            this._placeCaretAtPoint(e, surface);
            const col = this.template.querySelector('.dg-designer-canvas-col');
            const colRect = col ? col.getBoundingClientRect() : { left: 0, top: 0 };
            this._ctxPoint = { x: e.clientX, y: e.clientY };
            this._ctxCell = e.target && e.target.closest ? e.target.closest('td, th') : null;
            try {
                const cs = window.getSelection();
                this._ctxRange = cs && cs.rangeCount ? cs.getRangeAt(0).cloneRange() : null;
            } catch (err) {
                this._ctxRange = null;
            }
            this._focusCtxSearch = true;
            // FIT THE MENU TO THE SPACE THAT ACTUALLY EXISTS.
            //
            // `top` used to be the click point with no clamp and the menu had no
            // max-height, so right-clicking low on the page opened a long menu
            // straight off the bottom of the screen with its last items
            // unreachable by any means — no scroll, nowhere to scroll to. The
            // in-table menu is the worst case because it appends a whole extra
            // group of row and column commands.
            //
            // The inline max-height is computed from the room below the click,
            // so the menu always ends on-screen and scrolls internally for the
            // rest. When there is barely any room below, it lifts instead of
            // being squeezed into a sliver.
            const MIN_H = 200;
            const spaceBelow = window.innerHeight - e.clientY - 16;
            const menuMax = Math.max(MIN_H, Math.min(Math.round(window.innerHeight * 0.62), spaceBelow));
            let top = e.clientY - colRect.top + 4;
            if (spaceBelow < MIN_H) {
                top = Math.max(0, top - (MIN_H - spaceBelow));
            }
            this.ctxMenu = {
                inTable: !!(e.target && e.target.closest && e.target.closest('td, th')),
                posStyle:
                    'left: ' +
                    Math.max(0, e.clientX - colRect.left) +
                    'px; top: ' +
                    top +
                    'px; max-height: ' +
                    menuMax +
                    'px;'
            };
        });
        surface.addEventListener('mousemove', (e) => {
            this._imgResizeHover(e);
            this._cellSelMove(e, surface);
            this._tableResizeHover(e, surface);
        });
        // Table row/column handles and the block gutter handle follow the pointer.
        surface.addEventListener('mousemove', this.handleCanvasMouseMove);
        surface.addEventListener('mousedown', (e) => {
            // Nested-contenteditable blur is unreliable — a click outside an in-edit
            // pill commits it explicitly, so the user is never caught inside it.
            if (this._editingPill && !this._editingPill.contains(e.target) && this._finishPillEdit) {
                this._finishPillEdit();
            }
            if (this._imgResizeStart(e, surface)) {
                return;
            }
            this._cellSelDown(e, surface);
            this._tableResizeStart(e, surface);
        });
        surface.addEventListener('keyup', () => this._refreshFmtState());
        surface.addEventListener('mouseup', () => {
            // After the click's selection settles.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this._refreshFmtState(), 0);
        });
        // Chip drops staged by the document-level drag listener execute HERE —
        // surface listeners are the context where DOM insertion reliably works
        // under LWS.
        surface.addEventListener('mouseup', () => this._performPendingDropInsert());
        // Drag targets: tag chips and image thumbnails drop exactly where the user
        // points, with a live insertion marker so the drop point is never a guess.
        surface.addEventListener('dragover', (e) => {
            e.preventDefault();
            this._showDropMarker(e, surface);
        });
        surface.addEventListener('dragleave', (e) => {
            if (e.target === surface) {
                this._hideDropMarker(surface);
            }
        });
        surface.addEventListener('drop', (e) => this._handleVisualDrop(e, surface));
        // Undo capture for plain typing. beforeinput fires BEFORE the browser
        // mutates the DOM, the only moment the pre-edit state still exists.
        surface.addEventListener('beforeinput', (e) => {
            this._pushUndo('type:' + ((e && e.inputType) || 'text'));
        });
    }

    /**
     * Tab moves to the next cell; Tab in the last cell adds a row.
     *
     * The Word/Excel contract, and the reason tables are quick to fill in there.
     * Without it Tab moved FOCUS out of the editor entirely — the author lost their
     * caret and had to click back in for every cell.
     *
     * Shift+Tab walks backwards and stops at the first cell rather than wrapping,
     * because wrapping to the end of the table is never what someone reaching
     * backwards wants. Outside a table Tab is left alone, so keyboard navigation
     * out of the editor still works.
     *
     * The new cell's contents are SELECTED rather than the caret collapsed into
     * them, so typing replaces the placeholder the way it does in a spreadsheet.
     */
    _handleTabKey(e) {
        if (!e || e.key !== 'Tab' || e.ctrlKey || e.metaKey || e.altKey) {
            return false;
        }
        const cell = this._selectedTableCell();
        if (!cell) {
            return false;
        }
        const table = cell.closest ? cell.closest('table') : null;
        if (!table) {
            return false;
        }
        e.preventDefault();
        e.stopPropagation();
        const cells = Array.prototype.slice.call(table.querySelectorAll('td, th'));
        const idx = cells.indexOf(cell);
        let target = null;
        if (e.shiftKey) {
            if (idx <= 0) {
                return true; // already at the first cell — stay put
            }
            target = cells[idx - 1];
        } else if (idx > -1 && idx < cells.length - 1) {
            target = cells[idx + 1];
        } else {
            // Last cell: grow the table, the way Word does.
            this._pushUndo('table:tab-row');
            const lastRow = table.rows[table.rows.length - 1];
            if (!lastRow) {
                return true;
            }
            const clone = lastRow.cloneNode(true);
            for (const c of clone.children) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                c.innerHTML = '&nbsp;';
                c.removeAttribute('rowspan');
            }
            lastRow.insertAdjacentElement('afterend', clone);
            this._clampTablesToCanvas();
            this.htmlEditorDirty = true;
            target = clone.children[0];
        }
        if (!target) {
            return true;
        }
        try {
            const range = document.createRange();
            range.selectNodeContents(target);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            const surface = this._surfaceOwning(target);
            if (surface) {
                surface.focus();
            }
            this._recordCaret(target, surface);
            target.scrollIntoView({ block: 'nearest' });
        } catch (err) {
            /* caret placement is best-effort */
        }
        return true;
    }

    /**
     * Enter inserts a LINE BREAK; Shift+Enter starts a NEW PARAGRAPH.
     *
     * Both are handled here. Neither can be delegated: the browser's plain Enter
     * makes a paragraph and its Shift+Enter makes a line break, so leaving either
     * to the default would give two keys with the same effect and no way to reach
     * the other behaviour.
     *
     * This is deliberately the inverse of the usual convention, because in a
     * DOCUMENT template the usual convention produces the wrong output most of the
     * time. contenteditable's Enter creates a new <p>, and a <p> carries the
     * template's paragraph margin — so an address block, a signature block, a
     * multi-line header all came out double-spaced, and the author had to go to the
     * source to fix what looked like an editor bug. A <br> keeps the lines in one
     * paragraph and the spacing tight, which is what "the next line" almost always
     * means here. Shift+Enter is still one keystroke away when a real paragraph
     * break is wanted.
     *
     * Lists are the exception: inside an <li>, Enter genuinely means "next item",
     * so the browser's own handling is left alone.
     *
     * Returns true when it handled the event.
     */
    _handleEnterKey(e) {
        if (!e || e.key !== 'Enter' || e.ctrlKey || e.metaKey || e.altKey) {
            return false;
        }
        let node = null;
        let sel = null;
        try {
            sel = window.getSelection();
            node = sel && sel.rangeCount ? sel.getRangeAt(0).startContainer : null;
        } catch (err) {
            return false;
        }
        if (!node) {
            return false;
        }
        const el = node.nodeType === 3 ? node.parentElement : node;
        if (!el || !this._surfaceContaining(el)) {
            return false;
        }
        // "Next item" beats "next line" inside a list.
        if (el.closest && el.closest('li')) {
            return false;
        }
        e.preventDefault();
        // Shift+Enter must be handled EXPLICITLY, not delegated. The browser's own
        // Shift+Enter is already a line break, so simply letting it through left
        // both keys doing the same thing and no way to make a real paragraph at all.
        if (e.shiftKey) {
            this._pushUndo('paragraph');
            try {
                document.execCommand('insertParagraph');
                this.htmlEditorDirty = true;
            } catch (err) {
                /* nothing sensible to fall back to — the caret is unchanged */
            }
            return true;
        }
        this._pushUndo('linebreak');
        try {
            if (document.execCommand('insertLineBreak')) {
                this.htmlEditorDirty = true;
                return true;
            }
        } catch (err) {
            /* fall through to the manual insert */
        }
        try {
            const range = sel.getRangeAt(0);
            range.deleteContents();
            const br = document.createElement('br');
            range.insertNode(br);
            // A <br> at the very end of a block renders nothing — the line only
            // becomes visible once something follows it. Browsers solve this with a
            // trailing filler break; without it Enter at the end of a paragraph
            // looks like it did nothing at all.
            if (!br.nextSibling) {
                br.parentNode.insertBefore(document.createElement('br'), br.nextSibling);
            }
            const after = document.createRange();
            after.setStartAfter(br);
            after.collapse(true);
            sel.removeAllRanges();
            sel.addRange(after);
            this.htmlEditorDirty = true;
        } catch (err) {
            /* the browser's default already ran or the selection is gone */
        }
        return true;
    }

    /**
     * Ctrl/Cmd+Z and Ctrl+Shift+Z / Ctrl+Y on any editable surface.
     * Returns true when it handled the event, so the caller can stop there.
     */
    _undoKeydown(e) {
        if (!(e.ctrlKey || e.metaKey) || e.altKey) {
            return false;
        }
        const k = (e.key || '').toLowerCase();
        const isUndo = k === 'z' && !e.shiftKey;
        const isRedo = (k === 'z' && e.shiftKey) || k === 'y';
        if (!isUndo && !isRedo) {
            return false;
        }
        // Without preventDefault the browser ALSO runs its own undo, on a history
        // that knows nothing about the DOM surgery — two stacks, one document.
        e.preventDefault();
        e.stopPropagation();
        if (isUndo) {
            this.handleUndo();
        } else {
            this.handleRedo();
        }
        return true;
    }

    // ===== #241: Confluence-style table row/column handles ====================
    //
    // The add/remove actions already existed, but only as four similar-looking text
    // buttons in the format bar that act on "the current cell" — so the author had to
    // click the right cell, travel to the toolbar, and guess where the new column
    // would land. These handles put the affordance on the table itself.
    //
    // The handle elements are rendered by the LWC template as siblings of the canvas
    // (see .dg-canvas-wrap in the markup), NOT injected into it. The canvas gets
    // serialized straight back into the saved template body, so chrome placed inside
    // would need stripping on the way out — keeping it outside removes that risk
    // entirely.
    @track tableOverlay = null;
    _overlayTable = null;

    /**
     * mousemove fires continuously; recomputing rects on every one of them would be
     * wasteful. Skip the work while the pointer stays inside the table the overlay is
     * already drawn for, and rAF-coalesce the rest.
     */
    handleCanvasMouseMove = (event) => {
        // Time-based throttle, NOT requestAnimationFrame. The rAF version latched: it
        // set a pending-flag, and if the frame never ran — background tab, throttled
        // renderer, headless — the flag was never cleared and every later mousemove
        // returned early, permanently disabling the table handles. A timestamp cannot
        // get stuck.
        const now = Date.now();
        if (now - this._overlayLastRun < 40) {
            return;
        }
        this._overlayLastRun = now;
        try {
            this._updateTableOverlay(event);
            this._updateBlockHandle(event);
        } catch (e) {
            // Was silently swallowed, which hid the handles never rendering at all.
            // Still non-fatal, but no longer invisible.
            // eslint-disable-next-line no-console
            console.warn('Portwood: table overlay failed', e);
        }
    };
    _overlayLastRun = 0;
    _overlayClearTimer = null;

    /**
     * Leaving the canvas no longer kills the table chrome instantly.
     *
     * There was already a SPATIAL grace — _pointerNearTable keeps the overlay
     * alive within 72px — but it only applies while the pointer is still on the
     * canvas. Move up towards the toolbar, or off the sheet entirely, and
     * mouseleave fired and everything vanished at once. The controls sit in the
     * margin around the table, so travelling to one is exactly the movement that
     * used to dismiss it: the + you were aiming at disappeared out from under
     * the cursor.
     *
     * Now the clear is SCHEDULED, and any return cancels it.
     */
    handleCanvasMouseLeave() {
        this._scheduleOverlayClear();
    }

    _cancelOverlayClear() {
        if (this._overlayClearTimer) {
            clearTimeout(this._overlayClearTimer);
            this._overlayClearTimer = null;
        }
    }

    _scheduleOverlayClear(delay = 700) {
        this._cancelOverlayClear();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._overlayClearTimer = setTimeout(() => {
            this._overlayClearTimer = null;
            this.tableOverlay = null;
            this._overlayTable = null;
            this.blockHandle = null;
            this._highlightTableBand(null);
        }, delay);
    }

    // ===== Block gutter handle (Notion) ======================================
    //
    // A handle in the left gutter of whichever block the pointer is over: `+` to add
    // a paragraph beneath it, `⋮⋮` to grab and reorder. This is the affordance that
    // makes a document feel composable rather than typed-into.
    //
    // Rendered as an LWC-owned sibling of the canvas (same as the table handles), so
    // no block chrome can ever reach the serialized template body.
    @track blockHandle = null;

    /** Track which block the pointer is over, for the gutter handle. */
    _updateBlockHandle(event) {
        const pv = this._bodyCanvas();
        const wrap = this.template.querySelector('.dg-canvas-wrap');
        if (!pv || !wrap) {
            return;
        }
        let node = event.target;
        while (node && node.nodeType === 3) {
            node = node.parentNode;
        }
        const blk =
            node && node.closest ? node.closest('p, h1, h2, h3, h4, h5, h6, li, blockquote, table, div.dg-band') : null;
        // Never offer a handle for the canvas itself or for content inside a table
        // cell — the table gutters own that space.
        if (!blk || blk === pv || !this._isInCanvas(blk, pv) || (blk.closest && blk.closest('td, th'))) {
            if (this.blockHandle) {
                this.blockHandle = null;
                this._handleBlockEl = null;
            }
            return;
        }
        if (this._handleBlockEl === blk && this.blockHandle) {
            return;
        }
        this._handleBlockEl = blk;
        const r = blk.getBoundingClientRect();
        const wrapRect = wrap.getBoundingClientRect();
        if (r.bottom < wrapRect.top || r.top > wrapRect.bottom) {
            this.blockHandle = null;
            return;
        }
        // OFFSET BY THE HANDLE'S REAL WIDTH, not a constant that predates it.
        //
        // This was a flat 42px, chosen when the handle was three 13px buttons
        // with 1px gaps (~43px). Enlarging them to 22px with 3px gaps and
        // padding took it to ~76px — so anchoring at -42 pushed the last 34px
        // of the handle INTO the block, where it sat on top of the first table
        // cell and swallowed the clicks meant for the text. Making a control
        // easier to hit made the thing behind it impossible to edit.
        //
        // A table gets extra clearance because its own row gutter already
        // occupies that margin; without it the two sets of controls stack.
        const zoom = this.designerZoom || 1;
        const isTable = blk.tagName === 'TABLE';
        const handleW = 72; // 3 buttons x 22 + 2 gaps x 3 (no container chip)
        const clearance = handleW + 10 + (isTable ? 34 : 0);
        this.blockHandle = {
            style: `left:${r.left - wrapRect.left - Math.round(clearance * zoom)}px; top:${r.top - wrapRect.top + 1}px;`
        };
    }
    _handleBlockEl = null;

    /** `+` — insert an empty paragraph directly after the hovered block. */
    handleBlockInsertAfter() {
        const blk = this._handleBlockEl;
        if (!blk || !blk.isConnected) {
            return;
        }
        this._pushUndo('block-insert');
        const p = document.createElement('p');
        // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
        p.innerHTML = '<br/>';
        blk.insertAdjacentElement('afterend', p);
        this.htmlEditorDirty = true;
        try {
            const r = document.createRange();
            r.selectNodeContents(p);
            r.collapse(true);
            const s = window.getSelection();
            s.removeAllRanges();
            s.addRange(r);
            p.scrollIntoView({ block: 'nearest' });
        } catch (e) {
            /* caret placement is best effort */
        }
        this.blockHandle = null;
    }

    /** Grab handle — move the hovered block up or down one position. */
    handleBlockMove(event) {
        const blk = this._handleBlockEl;
        if (!blk || !blk.isConnected) {
            return;
        }
        const dir = event.currentTarget.dataset.dir;
        const sibling = dir === 'up' ? blk.previousElementSibling : blk.nextElementSibling;
        // Never reorder past the canvas's scoped <style> — moving a block above it
        // would put content before the stylesheet and drop the page styling.
        if (!sibling || sibling.tagName === 'STYLE') {
            return;
        }
        this._pushUndo('block-move');
        if (dir === 'up') {
            sibling.insertAdjacentElement('beforebegin', blk);
        } else {
            sibling.insertAdjacentElement('afterend', blk);
        }
        this.htmlEditorDirty = true;
        try {
            blk.scrollIntoView({ block: 'nearest' });
        } catch (e) {
            /* best effort */
        }
        // Reposition against the block's new location.
        this._handleBlockEl = null;
        this.blockHandle = null;
    }

    /** Recompute the handle strip for whichever table the pointer is over. */
    /**
     * Is the pointer still inside the band of space this table's chrome occupies?
     *
     * Scaled with the zoom, because the gutters are: at 1.5x a 50px row gutter is
     * 75 screen px, and a fixed tolerance would strand the handles again.
     */
    _pointerNearTable(event, table) {
        try {
            const r = table.getBoundingClientRect();
            // Must cover the widest chrome — the row gutter (50) plus the handle
            // itself — with a little slack for pointer travel.
            const pad = Math.round(72 * (this.designerZoom || 1));
            return (
                event.clientX >= r.left - pad &&
                event.clientX <= r.right + pad &&
                event.clientY >= r.top - pad &&
                event.clientY <= r.bottom + pad
            );
        } catch (e) {
            return false;
        }
    }

    _updateTableOverlay(event) {
        if (!this.showHtmlBodyVisual) {
            return;
        }
        const pv = this._canvas();
        const wrap = this.template.querySelector('.dg-canvas-wrap');
        if (!pv || !wrap) {
            return;
        }
        let node = event.target;
        while (node && node.nodeType === 3) {
            node = node.parentNode;
        }
        const table = node && node.closest ? node.closest('table') : null;
        // Resolve the surface from what the POINTER is over, not from _canvas(),
        // which follows FOCUS. Hovering a table in the running header while the
        // caret was still in the body resolved to the body canvas, the containment
        // test failed, and the handles never appeared for header/footer tables.
        //
        // _surfaceOwning, not _surfaceContaining: the latter also SETS the active
        // surface, so merely moving the pointer over the header would have
        // redirected the toolbar away from where the caret actually is.
        const owner = (table && this._surfaceOwning(table)) || pv;
        if (!table || !this._isInCanvas(table, owner)) {
            // Do NOT drop the overlay the instant the pointer leaves the table.
            //
            // The handles and seams are deliberately positioned OUTSIDE the table
            // edge (8px for a seam, up to 50px for a row handle), so moving the
            // pointer towards one necessarily leaves the table first — which cleared
            // the overlay and made the + vanish out from under the cursor mid-click.
            // Keep it alive while the pointer is still within the gutter the chrome
            // occupies; leaving the canvas entirely is handled by mouseleave.
            if (this.tableOverlay && this._overlayTable && this._pointerNearTable(event, this._overlayTable)) {
                // Still in the gutter the chrome occupies — cancel any pending
                // dismissal, the pointer is on its way to a control.
                this._cancelOverlayClear();
                return;
            }
            if (this.tableOverlay) {
                // Shorter than the leave-the-canvas grace: the pointer is
                // demonstrably still on the page and has moved away on purpose.
                this._scheduleOverlayClear(400);
            }
            return;
        }
        // Back over a table — whatever dismissal was pending is off.
        this._cancelOverlayClear();
        this._overlayTable = table;
        const wrapRect = wrap.getBoundingClientRect();
        // The overlay elements are positioned inside .dg-canvas-wrap, which spans the
        // PAGE only — but a table can live in a running band, which sits above or
        // below it. Culling against the wrap therefore discarded every column and row
        // of a header/footer table as "off-screen" and the handles never rendered.
        // Cull against the whole sheet instead; the offsets stay relative to the wrap
        // and simply go negative for a header, which absolute positioning handles.
        const paper = this.template.querySelector('.dg-sheet-paper');
        const clipRect = paper ? paper.getBoundingClientRect() : wrapRect;
        // Gutter offsets are in SCREEN pixels, but the page is transform-scaled. A
        // fixed 20px gutter is only ~12 document px at 1.6x, which slides the handles
        // on top of the table. Scale the offsets so the gutter stays proportional.
        const gz = this.designerZoom || 1;
        // The ROW gutter must clear the handle's own width (42px in CSS), not just
        // leave a 20px gap — offsetting by 20 put the buttons on top of the first
        // column. Columns only need the bar height.
        const gut = Math.round(20 * gz);
        const rowGut = Math.round(50 * gz);
        const seamOff = Math.round(8 * gz);
        const colTop = Math.round(24 * gz);
        // Column boundaries come from the widest row so a header with colspans
        // doesn't produce fewer handles than the table has columns.
        let widest = null;
        let widestSpan = -1;
        for (const tr of table.rows) {
            let span = 0;
            for (const c of tr.children) {
                span += c.colSpan || 1;
            }
            if (span > widestSpan) {
                widestSpan = span;
                widest = tr;
            }
        }
        const cols = [];
        const seams = [];
        if (widest) {
            let i = 0;
            const tRect = table.getBoundingClientRect();
            for (const cell of widest.children) {
                const r = cell.getBoundingClientRect();
                // Skip anything scrolled out of view — the handles are absolutely
                // positioned in a non-scrolling wrapper, so an off-screen handle would
                // float over unrelated chrome.
                if (r.bottom < clipRect.top || r.top > clipRect.bottom) {
                    i += cell.colSpan || 1;
                    continue;
                }
                // Confluence's model: the BAR is the select target and carries no
                // buttons at rest — that is what removes the clutter. Insert lives on
                // the seam between bars, delete lives in the bar's own menu.
                cols.push({
                    key: 'c' + i,
                    index: i,
                    style: `left:${r.left - wrapRect.left}px; top:${tRect.top - wrapRect.top - gut}px; width:${r.width}px;`
                });
                // Leading seam for the first column, then one after every column.
                if (i === 0) {
                    seams.push({
                        key: 's-lead',
                        index: 0,
                        axis: 'col',
                        style: `left:${r.left - wrapRect.left - seamOff}px; top:${tRect.top - wrapRect.top - colTop}px;`
                    });
                }
                seams.push({
                    key: 'sc' + i,
                    index: i + (cell.colSpan || 1),
                    axis: 'col',
                    style: `left:${r.right - wrapRect.left - seamOff}px; top:${tRect.top - wrapRect.top - colTop}px;`
                });
                i += cell.colSpan || 1;
            }
        }
        const rows = [];
        let ri = 0;
        const tRect2 = table.getBoundingClientRect();
        for (const tr of table.rows) {
            const r = tr.getBoundingClientRect();
            if (r.bottom < clipRect.top || r.top > clipRect.bottom) {
                ri++;
                continue;
            }
            rows.push({
                key: 'r' + ri,
                index: ri,
                style: `left:${tRect2.left - wrapRect.left - rowGut}px; top:${r.top - wrapRect.top}px; height:${r.height}px;`
            });
            if (ri === 0) {
                seams.push({
                    key: 's-rlead',
                    index: 0,
                    axis: 'row',
                    style: `left:${tRect2.left - wrapRect.left - rowGut - seamOff}px; top:${r.top - wrapRect.top - seamOff}px;`
                });
            }
            seams.push({
                key: 'sr' + ri,
                index: ri + 1,
                axis: 'row',
                style: `left:${tRect2.left - wrapRect.left - rowGut - seamOff}px; top:${r.bottom - wrapRect.top - seamOff}px;`
            });
            ri++;
        }
        this.tableOverlay = { cols, rows, seams };
    }

    // ===== Ghost preview =====================================================
    //
    // Hovering an insert control paints a translucent column/row exactly where the new
    // one will land; hovering a delete control paints the band that will disappear in
    // red. Showing the RESULT beats labelling the action — you stop having to hold a
    // model of "before or after this cell?" in your head.
    @track tableGhost = null;

    /** Ghost for a seam `+`: a column/row sized like its neighbour, at the seam. */
    handleSeamPreview(event) {
        this._cancelOverlayClear();
        const table = this._overlayTable;
        const wrap = this.template.querySelector('.dg-canvas-wrap');
        if (!table || !table.isConnected || !wrap) {
            return;
        }
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        const axis = event.currentTarget.dataset.axis;
        const wrapRect = wrap.getBoundingClientRect();
        const tRect = table.getBoundingClientRect();
        try {
            if (axis === 'col') {
                const row = table.rows[0];
                if (!row) {
                    return;
                }
                // Width of the column it will sit beside; clamp to the last one when
                // inserting at the trailing edge.
                const ref = row.children[Math.min(idx, row.children.length - 1)];
                if (!ref) {
                    return;
                }
                const rr = ref.getBoundingClientRect();
                const left = idx >= row.children.length ? rr.right : rr.left;
                this.tableGhost = {
                    style: `left:${left - wrapRect.left}px; top:${tRect.top - wrapRect.top}px; width:${rr.width}px; height:${tRect.height}px;`,
                    cls: 'dg-tbl-ghost'
                };
            } else {
                const ref = table.rows[Math.min(idx, table.rows.length - 1)];
                if (!ref) {
                    return;
                }
                const rr = ref.getBoundingClientRect();
                const top = idx >= table.rows.length ? rr.bottom : rr.top;
                this.tableGhost = {
                    style: `left:${tRect.left - wrapRect.left}px; top:${top - wrapRect.top}px; width:${tRect.width}px; height:${rr.height}px;`,
                    cls: 'dg-tbl-ghost'
                };
            }
        } catch (e) {
            this.tableGhost = null;
        }
    }

    /** Ghost for a delete control: paint what is about to be removed, in red. */
    handleRemovePreview(event) {
        const table = this._overlayTable;
        const wrap = this.template.querySelector('.dg-canvas-wrap');
        if (!table || !table.isConnected || !wrap) {
            return;
        }
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        const axis = event.currentTarget.dataset.axis || (event.currentTarget.dataset.dir ? 'row' : 'col');
        const wrapRect = wrap.getBoundingClientRect();
        const tRect = table.getBoundingClientRect();
        try {
            if (axis === 'col') {
                const row = table.rows[0];
                const ref = row && row.children[idx];
                if (!ref) {
                    return;
                }
                const rr = ref.getBoundingClientRect();
                this.tableGhost = {
                    style: `left:${rr.left - wrapRect.left}px; top:${tRect.top - wrapRect.top}px; width:${rr.width}px; height:${tRect.height}px;`,
                    cls: 'dg-tbl-ghost dg-tbl-ghost_remove'
                };
            } else {
                const ref = table.rows[idx];
                if (!ref) {
                    return;
                }
                const rr = ref.getBoundingClientRect();
                this.tableGhost = {
                    style: `left:${tRect.left - wrapRect.left}px; top:${rr.top - wrapRect.top}px; width:${tRect.width}px; height:${rr.height}px;`,
                    cls: 'dg-tbl-ghost dg-tbl-ghost_remove'
                };
            }
        } catch (e) {
            this.tableGhost = null;
        }
    }

    handleGhostClear() {
        this.tableGhost = null;
    }

    /**
     * Insert at a SEAM — the boundary between two bars, not "before/after the current
     * cell". Confluence's affordance: you point at the gap where the new column or row
     * will go, so the insertion point is never a guess. index is the grid position the
     * new column/row takes.
     */
    handleSeamInsert(event) {
        const table = this._tableFromOverlay();
        if (!table) {
            return;
        }
        this._pushUndo('seam-insert');
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        const axis = event.currentTarget.dataset.axis;
        if (axis === 'col') {
            for (const tr of table.rows) {
                const ref = tr.children[Math.min(idx, tr.children.length - 1)];
                if (!ref) {
                    continue;
                }
                const c = ref.cloneNode(false);
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                c.innerHTML = '&nbsp;';
                c.removeAttribute('colspan');
                if (idx >= tr.children.length) {
                    ref.insertAdjacentElement('afterend', c);
                } else {
                    ref.insertAdjacentElement('beforebegin', c);
                }
            }
        } else {
            const ref = table.rows[Math.min(idx, table.rows.length - 1)];
            if (!ref) {
                return;
            }
            const clone = ref.cloneNode(true);
            for (const c of clone.children) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                c.innerHTML = '&nbsp;';
                c.removeAttribute('rowspan');
            }
            if (idx >= table.rows.length) {
                ref.insertAdjacentElement('afterend', clone);
            } else {
                ref.insertAdjacentElement('beforebegin', clone);
            }
        }
        this._clampTablesToCanvas();
        this.htmlEditorDirty = true;
        this.tableOverlay = null;
    }

    /** Tint the column/row a handle refers to, so "which one" is never a guess. */
    handleTableHandleEnter(event) {
        // The pointer is ON a control — it cannot be a dismissal.
        this._cancelOverlayClear();
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        const isCol = event.currentTarget.classList.contains('dg-tbl-handle_col');
        this._highlightTableBand(isCol ? { col: idx } : { row: idx });
    }

    handleTableHandleLeave() {
        this._highlightTableBand(null);
    }

    _highlightTableBand(spec) {
        // Undo the previous band first. Clears only `filter`, never a captured style
        // attribute — see THE CHROME PROPERTY RULE. Restoring a snapshot here erased
        // any fill the author applied to those cells while the band was lit, which is
        // precisely what the row/column handles invite you to do.
        for (const el of this._bandPainted || []) {
            try {
                el.style.filter = '';
                if (!el.getAttribute('style')) {
                    el.removeAttribute('style');
                }
                el.removeAttribute('data-dg-paint');
            } catch (e) {
                /* detached */
            }
        }
        this._bandPainted = [];
        const table = this._overlayTable;
        if (!spec || !table || !table.isConnected) {
            return;
        }
        const targets = [];
        if (typeof spec.col === 'number') {
            for (const tr of table.rows) {
                let i = 0;
                for (const cell of tr.children) {
                    const span = cell.colSpan || 1;
                    if (spec.col >= i && spec.col < i + span) {
                        targets.push(cell);
                    }
                    i += span;
                }
            }
        } else if (typeof spec.row === 'number' && table.rows[spec.row]) {
            for (const cell of table.rows[spec.row].children) {
                targets.push(cell);
            }
        }
        for (const cell of targets) {
            this._bandPainted.push(cell);
            cell.setAttribute('data-dg-paint', 'band');
            // `filter` tints whatever is underneath — the author's fill included —
            // without writing a property the author owns. Flying Saucer ignores
            // filter, so even a leaked tint could not reach the PDF.
            cell.style.filter = 'brightness(0.93) saturate(1.25)';
        }
    }
    _bandPainted = [];

    /**
     * The handle actions address a column/row by INDEX, whereas handleTableAction
     * addresses "the cell the caret is in". Rather than fake a caret, operate on the
     * grid directly — and clear the band highlight first so its inline style can't be
     * cloned into a newly inserted row.
     */
    _tableFromOverlay() {
        this._highlightTableBand(null);
        const table = this._overlayTable;
        return table && table.isConnected ? table : null;
    }

    handleInsertColAt(event) {
        const table = this._tableFromOverlay();
        if (!table) {
            return;
        }
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        for (const tr of table.rows) {
            const ref = tr.children[Math.min(idx, tr.children.length - 1)];
            if (ref) {
                const c = ref.cloneNode(false);
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                c.innerHTML = '&nbsp;';
                c.removeAttribute('colspan');
                ref.insertAdjacentElement('beforebegin', c);
            }
        }
        this._clampTablesToCanvas();
        this.htmlEditorDirty = true;
        this.tableOverlay = null;
    }

    handleDeleteColAt(event) {
        const table = this._tableFromOverlay();
        if (!table) {
            return;
        }
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        for (const tr of table.rows) {
            if (tr.children[idx]) {
                tr.children[idx].remove();
            }
        }
        if (!table.querySelector('td, th')) {
            table.remove();
        }
        this._clampTablesToCanvas();
        this.htmlEditorDirty = true;
        this.tableOverlay = null;
    }

    handleInsertRowAt(event) {
        const table = this._tableFromOverlay();
        if (!table) {
            return;
        }
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        const row = table.rows[idx];
        if (!row) {
            return;
        }
        const clone = row.cloneNode(true);
        for (const c of clone.children) {
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            c.innerHTML = '&nbsp;';
            c.removeAttribute('rowspan');
        }
        row.insertAdjacentElement('beforebegin', clone);
        this._clampTablesToCanvas();
        this.htmlEditorDirty = true;
        this.tableOverlay = null;
    }

    handleDeleteRowAt(event) {
        const table = this._tableFromOverlay();
        if (!table) {
            return;
        }
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        const row = table.rows[idx];
        if (row) {
            row.remove();
        }
        if (!table.querySelector('tr')) {
            table.remove();
        }
        this._clampTablesToCanvas();
        this.htmlEditorDirty = true;
        this.tableOverlay = null;
    }

    // --- Table tools (visual mode): operate on the cell holding the caret ---
    // ===== Excel-style cell selection =====
    // Drag from one cell into another to select a rectangle (purple tint).
    // The selection SURVIVES right-clicks and toolbar clicks — Fill, Merge,
    // and row/column ops act on it. Click outside a table to clear.
    // _isInCanvas, not pv.contains: contains() is unreliable under the LWS namespace
    // sandbox and has already broken four features. It matters more here now that
    // these run on the running header and footer as well as the page.
    _cellSelDown(e, pv) {
        const cell = e.target && e.target.closest ? e.target.closest('td, th') : null;
        this._cellSelAnchor = cell && this._isInCanvas(cell, pv) ? cell : null;
        this._cellSelecting = false;
    }

    _cellSelMove(e, pv) {
        if (this._colResizing || !this._cellSelAnchor || !(e.buttons & 1)) {
            return;
        }
        const cell = e.target && e.target.closest ? e.target.closest('td, th') : null;
        if (!cell || !this._isInCanvas(cell, pv)) {
            return;
        }
        const table = this._cellSelAnchor.closest('table');
        if (cell === this._cellSelAnchor || cell.closest('table') !== table) {
            return;
        }
        // Crossed a cell boundary — this drag selects cells, not text.
        this._cellSelecting = true;
        try {
            e.preventDefault();
            const ws = window.getSelection();
            ws.removeAllRanges();
        } catch (err) {
            /* best effort */
        }
        this._applyCellSelRect(table, this._cellSelAnchor, cell);
    }

    _applyCellSelRect(table, a, f) {
        this._clearCellSel();
        const rows = Array.from(table.rows);
        const r1 = Math.min(rows.indexOf(a.parentElement), rows.indexOf(f.parentElement));
        const r2 = Math.max(rows.indexOf(a.parentElement), rows.indexOf(f.parentElement));
        const c1 = Math.min(a.cellIndex, f.cellIndex);
        const c2 = Math.max(a.cellIndex, f.cellIndex);
        const sel = [];
        for (let r = r1; r <= r2; r++) {
            for (let c = c1; c <= c2; c++) {
                const el = rows[r] && rows[r].children[c];
                if (el) {
                    el.setAttribute('data-dg-selcell', '1');
                    el.style.boxShadow = 'inset 0 0 0 2px #7c3aed';
                    el.style.backgroundClip = 'padding-box';
                    sel.push(el);
                }
            }
        }
        this._cellSel = sel;
    }

    /**
     * Clear the Excel-style cell selection.
     *
     * Sweeps the DOM for the selection marker rather than only walking the tracked
     * array. Any cell that left the array — replaced by a re-render, moved by a
     * row/column insert, or orphaned when _cellSel was reassigned — kept its
     * data-dg-selcell attribute and its highlight, so the table appeared to have more
     * cells selected than it did and the highlight "hung" until the canvas was rebuilt.
     * The array is still cleared first so detached nodes are handled too.
     */
    _clearCellSel() {
        for (const el of this._cellSel || []) {
            try {
                el.removeAttribute('data-dg-selcell');
                el.style.boxShadow = '';
                el.style.backgroundClip = '';
                if (!el.getAttribute('style')) {
                    el.removeAttribute('style');
                }
            } catch (e) {
                /* detached */
            }
        }
        this._cellSel = null;
        for (const surface of this._allSurfaces()) {
            let stragglers;
            try {
                stragglers = surface.querySelectorAll('[data-dg-selcell]');
            } catch (e) {
                continue;
            }
            for (const el of stragglers) {
                el.removeAttribute('data-dg-selcell');
                el.style.boxShadow = '';
                el.style.backgroundClip = '';
                if (!el.getAttribute('style')) {
                    el.removeAttribute('style');
                }
            }
        }
    }

    /**
     * A table must never extend past the sheet.
     *
     * _fitOversizeTables only runs once, at mount, so a table that GREW after that —
     * a column added, a border dragged, a merge undone — could overhang the page with
     * nothing to pull it back. This runs after every table mutation. Silent by design:
     * the overflow is a direct consequence of the edit the author just made, so a toast
     * would fire on their own action every time.
     */
    _clampTablesToCanvas() {
        for (const surface of this._allSurfaces()) {
            let cs;
            try {
                cs = getComputedStyle(surface);
            } catch (e) {
                continue;
            }
            const contentW =
                surface.getBoundingClientRect().width -
                (parseFloat(cs.paddingLeft) || 0) -
                (parseFloat(cs.paddingRight) || 0);
            if (!(contentW > 0)) {
                continue;
            }
            for (const t of surface.querySelectorAll('table')) {
                // max-width alone is not enough: table-layout:auto refuses to shrink
                // below min-content, so a table of wide cells still overhangs.
                t.style.maxWidth = '100%';
                if (t.getBoundingClientRect().width > contentW + 1) {
                    t.style.width = '100%';
                    t.style.tableLayout = 'fixed';
                }
            }
        }
    }

    _selectedTableCell() {
        if (this._cellSel && this._cellSel.length) {
            return this._cellSel[0];
        }
        let node = null;
        try {
            const sel = window.getSelection();
            node = sel && sel.anchorNode;
        } catch (e) {
            node = null;
        }
        while (node && node.nodeType === 3) {
            node = node.parentNode;
        }
        const pv = this._canvas();
        if (!node || !pv || !this._isInCanvas(node, pv) || !node.closest) {
            // #239 — the live selection is gone (a color picker or popover took focus).
            // The remembered cell is the whole point of the caret tracker: without it
            // this returned null and cell fill toasted "Click inside a table cell first"
            // even though the author's caret was plainly in a cell.
            const remembered = this._caret && this._caret.cellEl;
            if (remembered && remembered.isConnected && this._isInCanvas(remembered, pv)) {
                return remembered;
            }
            if (this._ctxCell && this._ctxCell.isConnected && pv && this._isInCanvas(this._ctxCell, pv)) {
                return this._ctxCell;
            }
            return null;
        }
        const cell = node.closest('td, th');
        if (cell && this._isInCanvas(cell, pv)) {
            return cell;
        }
        const remembered = this._caret && this._caret.cellEl;
        if (remembered && remembered.isConnected && this._isInCanvas(remembered, pv)) {
            return remembered;
        }
        // Right-click doesn't reliably move the caret under LWS — fall back
        // to the cell the context menu was opened on.
        if (this._ctxCell && this._ctxCell.isConnected && this._isInCanvas(this._ctxCell, pv)) {
            return this._ctxCell;
        }
        return null;
    }

    handleTableAction(event) {
        if (!this.showHtmlBodyVisual) {
            return;
        }
        const action = event.currentTarget.dataset.taction;
        const value = event.currentTarget.dataset.value || null;
        // Every branch below is DOM surgery the browser's undo history cannot see.
        // One capture at the top covers all ~20 of them.
        this._pushUndo('table:' + action);
        // #239 — the <select> controls (border width, cell padding, table alignment)
        // take focus when opened, which destroys the live selection before this runs.
        // Restore before resolving the target cell.
        this._restoreCaret();
        const cell = this._selectedTableCell();
        if (!cell) {
            // Fill works everywhere: outside a table it colors the block the
            // caret is in (paragraph, heading, list item, div panel).
            if (action === 'cellFill') {
                const blk = this._selectedBlockElement();
                if (blk) {
                    blk.style.background = value === 'transparent' ? '' : value;
                    if (value !== 'transparent' && !blk.style.padding) {
                        blk.style.padding = '6pt 8pt';
                    }
                    this.htmlEditorDirty = true;
                    return;
                }
            }
            this.showToast(
                'Click inside a table cell first',
                'Put your cursor in the table you want to change, then use the table tools.',
                'info'
            );
            return;
        }
        const row = cell.parentElement;
        const table = cell.closest('table');
        const cellIndex = Array.prototype.indexOf.call(row.children, cell);
        if (action === 'rowBefore') {
            const clone = row.cloneNode(true);
            for (const c of clone.children) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                c.innerHTML = '&nbsp;';
                c.removeAttribute('rowspan');
            }
            row.insertAdjacentElement('beforebegin', clone);
        } else if (action === 'colBefore') {
            for (const tr of table.rows) {
                const ref = tr.children[Math.min(cellIndex, tr.children.length - 1)];
                if (ref) {
                    const c = ref.cloneNode(false);
                    // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                    c.innerHTML = '&nbsp;';
                    c.removeAttribute('colspan');
                    ref.insertAdjacentElement('beforebegin', c);
                }
            }
        } else if (action === 'mergeCells') {
            this._mergeCells(cell, table);
        } else if (action === 'splitCell') {
            // The clicked/first-selected cell may not be the merged one — find
            // the merged cell anywhere in the selection.
            const merged = (this._cellSel || []).find((c) => (c.colSpan || 1) > 1 || (c.rowSpan || 1) > 1) || cell;
            const mRow = merged.parentElement;
            const mTable = merged.closest('table');
            const mIdx = Array.prototype.indexOf.call(mRow.children, merged);
            this._clearCellSel();
            this._splitCell(merged, mRow, mTable, mIdx);
        } else if (action === 'tableDel') {
            table.remove();
        } else if (action === 'rowAfter') {
            const clone = row.cloneNode(true);
            for (const c of clone.children) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                c.innerHTML = '&nbsp;';
            }
            row.insertAdjacentElement('afterend', clone);
        } else if (action === 'rowDel') {
            row.remove();
            if (table && !table.querySelector('tr')) {
                table.remove();
            }
        } else if (action === 'colAfter') {
            for (const tr of table.rows) {
                const ref = tr.children[Math.min(cellIndex, tr.children.length - 1)];
                if (ref) {
                    const c = ref.cloneNode(false);
                    // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                    c.innerHTML = '&nbsp;';
                    ref.insertAdjacentElement('afterend', c);
                }
            }
        } else if (action === 'colDel') {
            for (const tr of table.rows) {
                if (tr.children[cellIndex]) {
                    tr.children[cellIndex].remove();
                }
            }
            if (table && !table.querySelector('td, th')) {
                table.remove();
            }
        } else if (action === 'repeatHeader') {
            // {RepeatHeader} in the header row makes it repeat on every PDF
            // page (the v2.9 large-table behavior). Toggle it.
            const headerRow = (table.tHead && table.tHead.rows[0]) || table.rows[0];
            const firstCell = headerRow && headerRow.cells[0];
            if (firstCell) {
                const existing = Array.from(headerRow.querySelectorAll('[data-dg-tag]')).find((pl) =>
                    /repeatheader/i.test(pl.textContent)
                );
                if (existing) {
                    existing.remove();
                    this.showToast('Repeat header off', 'This table header no longer repeats on every page.', 'info');
                } else {
                    firstCell.insertBefore(document.createTextNode('{RepeatHeader}'), firstCell.firstChild);
                    this._pillifyTags(firstCell);
                    this.showToast(
                        'Repeat header on',
                        'The header row now repeats at the top of every PDF page this table spans.',
                        'success'
                    );
                }
                this.htmlEditorDirty = true;
            }
        } else if (action === 'headerRow') {
            for (const c of row.children) {
                c.style.background = '#1f3a5f';
                c.style.color = '#ffffff';
                c.style.fontWeight = 'bold';
            }
        } else if (action === 'cellFill') {
            const targets = this._cellSel && this._cellSel.length ? this._cellSel : [cell];
            for (const c of targets) {
                c.style.background = value === 'transparent' ? '' : value;
            }
        } else if (action === 'vAlign') {
            // #246 — top | middle | bottom, the only three CSS 2.1 allows on a table
            // cell (and therefore the only three Flying Saucer honors). Applies to the
            // Excel-style multi-cell selection when there is one.
            const targets = this._cellSel && this._cellSel.length ? this._cellSel : [cell];
            for (const c of targets) {
                c.style.verticalAlign = value;
            }
        } else if (action === 'vAlignTable') {
            // Whole-table sweep — the common case is "make this entire header band
            // middle-aligned", which is tedious cell by cell.
            for (const c of table.querySelectorAll('td, th')) {
                c.style.verticalAlign = value;
            }
        } else if (action === 'distributeCols') {
            this._distributeColumnsEvenly(table);
        } else if (action === 'tableWidth') {
            table.style.width = value;
            if (value === 'auto') {
                table.style.tableLayout = 'auto';
            }
        } else if (action === 'cellPadding') {
            for (const c of table.querySelectorAll('td, th')) {
                c.style.padding = value;
            }
        } else if (action === 'tableAlign') {
            // margin auto is the CSS 2.1 way to centre a table; float would break the
            // page flow Flying Saucer builds.
            if (value === 'center') {
                table.style.marginLeft = 'auto';
                table.style.marginRight = 'auto';
            } else if (value === 'right') {
                table.style.marginLeft = 'auto';
                table.style.marginRight = '0';
            } else {
                table.style.marginLeft = '0';
                table.style.marginRight = 'auto';
            }
        } else if (
            action === 'bordersAll' ||
            action === 'bordersOutline' ||
            action === 'bordersRows' ||
            action === 'bordersNone'
        ) {
            this._lastBorderMode = action;
            this._applyBorders(action, table);
        }
        // Any structural change can push the table past the sheet edge.
        this._clampTablesToCanvas();
        this.htmlEditorDirty = true;
    }

    /**
     * #242 — snap every column to the same width.
     *
     * Operates on the GRID, not on row.children: with colspans a row can have fewer
     * cells than the table has columns, so counting children would produce uneven
     * widths on exactly the tables that need this most.
     *
     * Rewrites an existing <colgroup> rather than adding one — two colgroups on a
     * single table was the v2.8.0 giant-table bug that rendered everything at 200%
     * width and packed the cells into the left half of the page.
     */
    _distributeColumnsEvenly(table) {
        if (!table) {
            return;
        }
        // Widest row in grid terms = the real column count.
        let columns = 0;
        for (const tr of table.rows) {
            let span = 0;
            for (const c of tr.children) {
                span += c.colSpan || 1;
            }
            columns = Math.max(columns, span);
        }
        if (columns < 1) {
            return;
        }
        const pct = (100 / columns).toFixed(4) + '%';
        // Authored per-cell widths would override the colgroup, so clear them.
        for (const c of table.querySelectorAll('td, th')) {
            c.style.width = '';
            c.removeAttribute('width');
        }
        let colgroup = table.querySelector('colgroup');
        if (colgroup) {
            while (colgroup.firstChild) {
                colgroup.removeChild(colgroup.firstChild);
            }
        } else {
            colgroup = document.createElement('colgroup');
            table.insertBefore(colgroup, table.firstChild);
        }
        for (let i = 0; i < columns; i++) {
            const col = document.createElement('col');
            col.style.width = pct;
            colgroup.appendChild(col);
        }
        // table-layout: fixed is what makes the colgroup authoritative; without it the
        // browser (and Flying Saucer) size columns from content and ignore the widths.
        table.style.tableLayout = 'fixed';
        if (!table.style.width) {
            table.style.width = '100%';
        }
        this.showToast('Columns distributed', `All ${columns} columns set to ${pct}.`, 'success');
    }

    // --- Table borders: style presets x width x color, selection-aware ---
    @track _borderPrefs = { width: '0.75', color: '#666666' };
    _lastBorderMode = 'bordersAll';

    get borderWidthOptions() {
        return [
            { value: '0.5', label: 'Hairline' },
            { value: '0.75', label: 'Thin' },
            { value: '1', label: 'Medium' },
            { value: '1.5', label: 'Thick' },
            { value: '2.25', label: 'Heavy' }
        ].map((o) => ({ ...o, selected: o.value === this._borderPrefs.width }));
    }

    get borderColorValue() {
        return this._borderPrefs.color;
    }

    _applyBorders(mode, table) {
        const line = this._borderPrefs.width + 'pt solid ' + this._borderPrefs.color;
        // A multi-cell drag selection scopes All/None to just those cells.
        const selCells = this._cellSel && this._cellSel.length > 1 ? this._cellSel : null;
        if (mode === 'bordersAll') {
            table.style.borderCollapse = 'collapse';
            if (selCells) {
                for (const c of selCells) {
                    c.style.border = line;
                }
            } else {
                table.style.border = line;
                for (const c of table.querySelectorAll('td, th')) {
                    c.style.border = line;
                }
            }
        } else if (mode === 'bordersOutline') {
            table.style.borderCollapse = 'collapse';
            table.style.border = line;
            for (const c of table.querySelectorAll('td, th')) {
                c.style.border = 'none';
            }
        } else if (mode === 'bordersRows') {
            table.style.borderCollapse = 'collapse';
            table.style.border = 'none';
            for (const c of table.querySelectorAll('td, th')) {
                c.style.border = 'none';
                c.style.borderBottom = line;
            }
        } else if (mode === 'bordersNone') {
            if (selCells) {
                for (const c of selCells) {
                    c.style.border = 'none';
                }
            } else {
                table.style.border = 'none';
                for (const c of table.querySelectorAll('td, th')) {
                    c.style.border = 'none';
                }
            }
        }
    }

    // --- #242: whole-table properties ----------------------------------------
    @track _tablePrefs = { padding: '4pt', align: 'left' };

    get cellPaddingOptions() {
        return [
            { value: '0pt 4pt', label: 'Padding: tight' },
            { value: '4pt', label: 'Padding: normal' },
            { value: '0pt 5.4pt', label: 'Padding: Word default' },
            { value: '8pt', label: 'Padding: roomy' }
        ].map((o) => ({ ...o, selected: o.value === this._tablePrefs.padding }));
    }

    get tableAlignOptions() {
        return [
            { value: 'left', label: 'Table: left' },
            { value: 'center', label: 'Table: centered' },
            { value: 'right', label: 'Table: right' }
        ].map((o) => ({ ...o, selected: o.value === this._tablePrefs.align }));
    }

    handleCellPaddingChange(event) {
        const value = event.currentTarget.value;
        this._tablePrefs = { ...this._tablePrefs, padding: value };
        this._applyTableProp('cellPadding', value);
    }

    handleTableAlignChange(event) {
        const value = event.currentTarget.value;
        this._tablePrefs = { ...this._tablePrefs, align: value };
        this._applyTableProp('tableAlign', value);
    }

    /**
     * The <select> controls can't reuse handleTableAction directly — it reads the
     * action and value off data- attributes, and a <select> carries its value on the
     * element. Synthesize the same shape so all table mutation stays in one place.
     */
    _applyTableProp(action, value) {
        this.handleTableAction({
            currentTarget: { dataset: { taction: action, value: value } }
        });
    }

    handleBorderWidthChange(event) {
        this._borderPrefs = { ...this._borderPrefs, width: event.currentTarget.value };
        this._reapplyBorders();
    }

    handleBorderColorChange(event) {
        this._borderPrefs = { ...this._borderPrefs, color: event.currentTarget.value };
        this._reapplyBorders();
    }

    /** Width/color changed — restyle the table under the cursor live, using
     *  whichever border style was applied last. */
    _reapplyBorders() {
        if (!this.showHtmlBodyVisual) {
            return;
        }
        let cell = this._selectedTableCell();
        if (!cell && this._savedFmtRange) {
            try {
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(this._savedFmtRange);
            } catch (e) {
                /* best effort */
            }
            cell = this._selectedTableCell();
        }
        // Fall back to what was captured on mousedown. After the native colour
        // dialog the live lookup finds nothing, and this is the only record of
        // which table the user was pointing at.
        let table = cell && cell.closest ? cell.closest('table') : null;
        if (!table && this._borderTargetTable && this._borderTargetTable.isConnected) {
            table = this._borderTargetTable;
        }
        // Last resort: the table the pointer was last over. Reaching the border
        // controls means crossing out of the table, and a user who has merely
        // HOVERED a table — never clicked into it — has no caret and no
        // selection, so both lookups above come back empty and the control did
        // nothing with no explanation. _overlayTable is already tracked for the
        // row/column chrome, so the answer was there to be used.
        if (!table && this._overlayTable && this._overlayTable.isConnected) {
            table = this._overlayTable;
        }
        // Restore the cell selection too, so a colour picked for three selected
        // cells still lands on those three and not on the whole table.
        if ((!this._cellSel || !this._cellSel.length) && this._borderTargetCells) {
            const alive = this._borderTargetCells.filter((c) => c && c.isConnected);
            if (alive.length) {
                this._cellSel = alive;
            }
        }
        if (table) {
            this._applyBorders(this._lastBorderMode || 'bordersAll', table);
            this.htmlEditorDirty = true;
        }
    }

    // --- Column drag-resize (grab a cell's right edge) ---
    _resizeEdgeCell(event, pv) {
        const info = this._resizeEdgeInfo(event, pv);
        return info && info.kind === 'col' ? info.cell : null;
    }

    /** Which resize handle (if any) the pointer is over: a column boundary
     *  (right edge of a cell) or a row boundary (bottom edge). */
    _resizeEdgeInfo(event, pv) {
        const cell = event.target && event.target.closest ? event.target.closest('td, th') : null;
        if (!cell || !pv.contains(cell)) {
            return null;
        }
        const rect = cell.getBoundingClientRect();
        if (event.clientX >= rect.right - 5 && event.clientX <= rect.right + 5) {
            return { kind: 'col', cell };
        }
        if (event.clientY >= rect.bottom - 4 && event.clientY <= rect.bottom + 4) {
            return { kind: 'row', cell };
        }
        // Just BELOW a boundary the pointer is on the next cell's top — grab
        // the previous row so the whole boundary (±4px) is a handle.
        if (event.clientY <= rect.top + 4) {
            const row = cell.parentElement;
            const prev = row && row.previousElementSibling;
            if (prev && prev.tagName === 'TR' && prev.cells && prev.cells.length) {
                return { kind: 'row', cell: prev.cells[0] };
            }
        }
        return null;
    }

    /** The visual column index a cell starts at (colspan-aware). */
    _colIndexForCell(cell) {
        let idx = 0;
        let el = cell.previousElementSibling;
        while (el) {
            idx += el.colSpan || 1;
            el = el.previousElementSibling;
        }
        return idx;
    }

    /**
     * Make ANY table resizable — pasted, Word-converted, hand-authored.
     * Measures the real on-screen column widths, freezes them into a
     * <colgroup> of px-width <col>s + table-layout:fixed (pure CSS 2.1 —
     * exactly what Flying Saucer honors in the PDF), and clears authored
     * per-cell widths that would fight the colgroup. Returns the <col> list.
     */
    _normalizeTableForResize(table) {
        let colCount = 0;
        for (const tr of table.rows) {
            let n = 0;
            for (const c of tr.children) {
                n += c.colSpan || 1;
            }
            colCount = Math.max(colCount, n);
        }
        if (!colCount) {
            return [];
        }
        // Best reference row: full column count, no spans.
        let ref = null;
        for (const tr of table.rows) {
            if (tr.children.length === colCount) {
                let clean = true;
                for (const c of tr.children) {
                    if ((c.colSpan || 1) !== 1) {
                        clean = false;
                        break;
                    }
                }
                if (clean) {
                    ref = tr;
                    break;
                }
            }
        }
        const widths = [];
        if (ref) {
            for (const c of ref.children) {
                widths.push(Math.max(24, Math.round(c.getBoundingClientRect().width)));
            }
        } else {
            // Every row has spans — spread each spanning cell's width evenly.
            const acc = new Array(colCount).fill(0);
            for (const tr of table.rows) {
                let k = 0;
                for (const c of tr.children) {
                    const span = c.colSpan || 1;
                    const w = c.getBoundingClientRect().width / span;
                    for (let i = 0; i < span && k + i < colCount; i++) {
                        acc[k + i] = Math.max(acc[k + i], w);
                    }
                    k += span;
                }
            }
            for (const w of acc) {
                widths.push(Math.max(24, Math.round(w) || 24));
            }
        }
        const tableW = Math.round(table.getBoundingClientRect().width);
        const doc = table.ownerDocument || document;
        let cg = null;
        for (const child of table.children) {
            if (child.tagName === 'COLGROUP') {
                cg = child;
                break;
            }
        }
        if (cg && cg.querySelectorAll('col').length !== colCount) {
            cg.remove();
            cg = null;
        }
        if (!cg) {
            cg = doc.createElement('colgroup');
            for (let i = 0; i < colCount; i++) {
                cg.appendChild(doc.createElement('col'));
            }
            table.insertBefore(cg, table.firstChild);
        }
        const cols = Array.from(cg.querySelectorAll('col'));
        cols.forEach((col, i) => {
            col.removeAttribute('width');
            col.style.width = widths[i] + 'px';
        });
        table.style.tableLayout = 'fixed';
        table.style.width = tableW + 'px';
        table.style.maxWidth = '100%';
        // Authored cell widths beat/fight the colgroup — clear them so the
        // colgroup is the single source of column geometry from here on.
        for (const tr of table.rows) {
            for (const c of tr.children) {
                c.removeAttribute('width');
                if (c.style && c.style.width) {
                    c.style.width = '';
                }
            }
        }
        return cols;
    }

    /** Corner-drag resize for canvas images; asset tags get the new size
     *  written back as {%asset:key:<W>x} (width-only, aspect preserved). */
    _imgCornerHit(event, img) {
        const r = img.getBoundingClientRect();
        return event.clientX >= r.right - 16 && event.clientY >= r.bottom - 16;
    }

    _imgResizeHover(event) {
        const img = event.target && event.target.tagName === 'IMG' ? event.target : null;
        if (img) {
            img.style.cursor = this._imgCornerHit(event, img) ? 'nwse-resize' : 'grab';
        }
    }

    _imgResizeStart(event, pv) {
        const img = event.target && event.target.tagName === 'IMG' ? event.target : null;
        // _isInCanvas, not pv.contains — contains() is unreliable under the LWS
        // namespace sandbox and would silently refuse to resize an image that IS in
        // the surface, dropping the drag back to the native (duplicating) one.
        if (!img || !this._isInCanvas(img, pv)) {
            return false;
        }
        // Body of the image = pick it up and move it; only the bottom-right
        // corner resizes.
        if (!this._imgCornerHit(event, img)) {
            return this._imgMoveStart(event, img, pv);
        }
        event.preventDefault();
        const startX = event.clientX;
        const startW = img.getBoundingClientRect().width;
        const doc = pv.ownerDocument || document;
        const onMove = (ev) => {
            const w = Math.max(24, Math.round(startW + (ev.clientX - startX)));
            img.style.width = w + 'px';
            img.style.height = 'auto';
            img.style.maxWidth = '';
        };
        const onUp = () => {
            doc.removeEventListener('mousemove', onMove);
            doc.removeEventListener('mouseup', onUp);
            const attr = img.getAttribute('data-dg-tag');
            const m = attr && /^\{%asset:([a-z0-9-]+)/i.exec(attr);
            if (m) {
                // Record BOTH dimensions, not just the width.
                //
                // A width-only tag renders as `width:Npx;height:auto`, and nothing
                // server-side can know what height that resolves to — the aspect
                // ratio lives in the image file. For a running header that matters a
                // lot: the engine has to grow the page's top margin to fit the
                // header, and it cannot size a margin it cannot measure, so a tall
                // logo silently overflowed the margin box and painted behind the
                // body. The browser is the only place the rendered height is known,
                // so it is the place that should write it down.
                const box = img.getBoundingClientRect();
                const w = Math.round(box.width);
                const h = Math.round(box.height);
                const size = h > 0 ? w + 'x' + h : w + 'x';
                img.setAttribute('data-dg-tag', '{%asset:' + m[1] + ':' + size + '}');
                img.title = img.getAttribute('data-dg-tag') + ' — drag the corner to resize';
            }
            this.htmlEditorDirty = true;
        };
        doc.addEventListener('mousemove', onMove);
        doc.addEventListener('mouseup', onUp);
        return true;
    }

    /**
     * Google-Docs-style image move: drag the image body, a purple drop marker
     * tracks the caret position under the pointer, release re-homes the image
     * there. A sub-threshold drag stays a plain click (pill menu etc.).
     */
    _imgMoveStart(event, img, pv) {
        event.preventDefault();
        const startX = event.clientX;
        const startY = event.clientY;
        const doc = pv.ownerDocument || document;
        let moving = false;
        const onMove = (ev) => {
            if (!moving && Math.abs(ev.clientX - startX) + Math.abs(ev.clientY - startY) < 6) {
                return;
            }
            moving = true;
            img.style.opacity = '0.45';
            img.style.cursor = 'grabbing';
            this._showDropMarker(ev, pv);
        };
        const onUp = (ev) => {
            doc.removeEventListener('mousemove', onMove);
            doc.removeEventListener('mouseup', onUp);
            if (!moving) {
                return;
            }
            this._hideDropMarker(pv);
            img.style.opacity = '';
            img.style.cursor = '';
            try {
                this._placeCaretAtPoint(ev, pv);
                const sel = window.getSelection();
                if (sel && sel.rangeCount) {
                    const r = sel.getRangeAt(0);
                    // Never drop INSIDE another pill — land after it instead.
                    let node = r.startContainer.nodeType === 3 ? r.startContainer.parentElement : r.startContainer;
                    const inPill = node && node.closest ? node.closest('[data-dg-tag]') : null;
                    if (inPill && inPill !== img) {
                        r.setStartAfter(inPill);
                    }
                    r.collapse(true);
                    r.insertNode(img);
                    r.setStartAfter(img);
                    r.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(r);
                    this.htmlEditorDirty = true;
                }
            } catch (e) {
                /* keep the image where it was */
            }
        };
        doc.addEventListener('mousemove', onMove);
        doc.addEventListener('mouseup', onUp);
        return true;
    }

    _tableResizeHover(event, pv) {
        if (this._colResizing) {
            return;
        }
        const info = this._resizeEdgeInfo(event, pv);
        const hovered = event.target && event.target.closest ? event.target.closest('td, th') : null;
        if (hovered) {
            hovered.style.cursor = info ? (info.kind === 'col' ? 'col-resize' : 'row-resize') : '';
        }
    }

    _tableResizeStart(event, pv) {
        const info = this._resizeEdgeInfo(event, pv);
        if (!info) {
            return;
        }
        event.preventDefault();
        // Capture once at grab, not per mousemove: a drag is one edit, and the
        // move handler fires dozens of times.
        this._pushUndo('table-resize');
        this._colResizing = true;
        const doc = pv.ownerDocument || document;
        let onMove;
        if (info.kind === 'row') {
            const row = info.cell.parentElement;
            const startY = event.clientY;
            const startH = row.getBoundingClientRect().height;
            onMove = (ev) => {
                row.style.height = Math.max(12, Math.round(startH + (ev.clientY - startY))) + 'px';
            };
        } else {
            // Any table becomes resizable on first grab — colgroup + fixed
            // layout frozen from the measured on-screen geometry.
            const cell = info.cell;
            const table = cell.closest('table');
            const cols = this._normalizeTableForResize(table);
            const kRight = this._colIndexForCell(cell) + (cell.colSpan || 1) - 1;
            const colA = cols[kRight];
            const colB = cols[kRight + 1] || null;
            if (!colA) {
                this._colResizing = false;
                return;
            }
            const startX = event.clientX;
            const wA = parseFloat(colA.style.width) || 24;
            const wB = colB ? parseFloat(colB.style.width) || 24 : 0;
            const tableStartW = parseFloat(table.style.width) || table.getBoundingClientRect().width;
            onMove = (ev) => {
                const dx = ev.clientX - startX;
                if (colB) {
                    // Move the boundary: left column grows, right one gives
                    // way — the table keeps its footprint (Canva/Excel feel).
                    const total = wA + wB;
                    const a = Math.round(Math.max(24, Math.min(total - 24, wA + dx)));
                    colA.style.width = a + 'px';
                    colB.style.width = total - a + 'px';
                } else {
                    // Last column: the table itself grows or shrinks.
                    const a = Math.round(Math.max(24, wA + dx));
                    colA.style.width = a + 'px';
                    table.style.width = Math.round(tableStartW + (a - wA)) + 'px';
                }
            };
        }
        const onUp = () => {
            doc.removeEventListener('mousemove', onMove);
            doc.removeEventListener('mouseup', onUp);
            this._colResizing = false;
            this.htmlEditorDirty = true;
        };
        doc.addEventListener('mousemove', onMove);
        doc.addEventListener('mouseup', onUp);
    }

    /**
     * Turn the caret's paragraph into a list item (or back). Enter inside a
     * list adds items natively; toggling a list item lifts it back out as a
     * paragraph. Inside a table cell the list wraps the cell's content.
     */
    _toggleListAtCaret(ordered) {
        const blk = this._selectedBlockElement();
        if (!blk) {
            this.showToast(
                'Click into some text first',
                'Put your cursor in a paragraph, then click the list button.',
                'info'
            );
            return;
        }
        // List toggling is DOM surgery here, not execCommand (LWS breaks the list
        // commands) — so it needs its own capture like every other surgical edit.
        this._pushUndo('list');
        const doc = blk.ownerDocument || document;
        const placeCaret = (el) => {
            try {
                const r = doc.createRange();
                r.selectNodeContents(el);
                r.collapse(false);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(r);
            } catch (e) {
                /* best effort */
            }
        };
        if (blk.tagName === 'LI') {
            // Toggle OFF: lift this item out of the list as a paragraph.
            const list = blk.parentElement;
            const p = doc.createElement('p');
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            p.innerHTML = blk.innerHTML;
            list.insertAdjacentElement('afterend', p);
            blk.remove();
            if (list && !list.querySelector('li')) {
                list.remove();
            }
            placeCaret(p);
        } else if (blk.tagName === 'TD' || blk.tagName === 'TH') {
            const list = doc.createElement(ordered ? 'ol' : 'ul');
            list.style.margin = '2pt 0 2pt 14pt';
            const li = doc.createElement('li');
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            li.innerHTML = blk.innerHTML && blk.innerHTML.trim() !== '&nbsp;' ? blk.innerHTML : 'List item';
            list.appendChild(li);
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            blk.innerHTML = '';
            blk.appendChild(list);
            placeCaret(li);
        } else {
            const list = doc.createElement(ordered ? 'ol' : 'ul');
            list.style.margin = '6pt 0 6pt 18pt';
            const li = doc.createElement('li');
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            li.innerHTML = blk.innerHTML || 'List item';
            list.appendChild(li);
            this._safeReplace(blk, list);
            placeCaret(li);
        }
        this.htmlEditorDirty = true;
    }

    /**
     * The block element (p, heading, list item, div, td) holding the caret.
     *
     * Two defects fixed here, both caught by the UI smoke harness:
     *
     * 1. It resolved the canvas as `.dg-visual-host .dg-pv` and tested membership with
     *    `pv.contains(node)`. That is the call documented as unreliable across LWS proxy
     *    identities in #240 — when it returned a false negative this method returned
     *    null and BOTH list buttons silently did nothing but show "Click into some text
     *    first". Now uses the surface resolver and the parentNode walk.
     * 2. It could only ever see the body, so lists (and anything else built on it) were
     *    dead in the running header and footer bands.
     */
    _selectedBlockElement() {
        let node = null;
        try {
            const sel = window.getSelection();
            node = sel && sel.anchorNode;
        } catch (e) {
            node = null;
        }
        while (node && node.nodeType === 3) {
            node = node.parentNode;
        }
        let surface = node ? this._surfaceContaining(node) : null;
        if (!surface || !node || !node.closest) {
            // Selection lost (a toolbar control took focus) — fall back to the caret
            // the tracker remembered while the surface still had it.
            const remembered = this._caret && this._caret.blockEl;
            if (remembered && remembered.isConnected && this._surfaceContaining(remembered)) {
                return remembered;
            }
            return null;
        }
        const blk = node.closest('p, h1, h2, h3, h4, h5, h6, li, div, td, th, blockquote');
        return blk && blk !== surface && this._isInCanvas(blk, surface) ? blk : null;
    }

    /**
     * Apply formatting to the current selection in the editable page.
     * styleWithCSS makes execCommand emit inline CSS spans — exactly the
     * flat, Flying Saucer-safe styling the PDF engine renders.
     */
    // --- Active-format indication: B/I/U/S read as pressed at the caret ---
    @track fmtState = { bold: false, italic: false, underline: false, strike: false };
    // Google-Docs-style size box: shows the size at the caret, sets any pt.
    @track fmtSizePt = 11;

    handleFontSizeStep(event) {
        const dir = parseInt(event.currentTarget.dataset.szstep, 10) || 0;
        const cur = parseFloat(this.fmtSizePt) || 11;
        this._applyFontSizePt(Math.max(6, Math.min(96, Math.round(cur + dir))));
    }

    handleFontSizeInput(event) {
        const v = parseFloat(event.currentTarget.value);
        if (isNaN(v)) {
            return;
        }
        // The input steals focus — put the page selection back first.
        if (this._savedFmtRange) {
            try {
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(this._savedFmtRange);
            } catch (e) {
                /* best effort */
            }
        }
        this._applyFontSizePt(Math.max(6, Math.min(96, v)));
    }

    /**
     * Exact point size on the selection. Pills take it directly; text goes
     * through execCommand's only enlargement hook (fontSize 7) and the marker
     * spans it creates are immediately retargeted to the requested pt.
     */
    _applyFontSizePt(pt) {
        if (!this.showHtmlBodyVisual) {
            return;
        }
        const host = this.template.querySelector('.dg-visual-host');
        const pv = host && host.querySelector('.dg-pv');
        const pills = this._pillsInSelection();
        for (const pill of pills) {
            pill.style.fontSize = pt + 'pt';
        }
        if (pills.length) {
            this.htmlEditorDirty = true;
        }
        // Pill-only selection: done. execCommand would strip the size we just
        // set and tear the pill out of its styled ancestor.
        if (!this._selectionHasNonPillText()) {
            if (!pills.length) {
                this._expandCaretToWord();
                if (!this._selectionHasNonPillText()) {
                    this.fmtSizePt = pt;
                    return;
                }
                this._execFontSizeOnSelection(pt, pv, []);
            }
            this.fmtSizePt = pt;
            return;
        }
        this._execFontSizeOnSelection(pt, pv, pills);
        this.fmtSizePt = pt;
    }

    /** The exact-size trick for real text: fontSize 7 as a marker, retargeted
     *  to the requested pt. Pills in a mixed selection get their styles
     *  snapshot-restored around it. */
    _execFontSizeOnSelection(pt, pv, pills) {
        const isMarker = (el) => {
            const fs = el.style.fontSize;
            return fs === 'xxx-large' || fs === '48px';
        };
        const before = new Set();
        if (pv) {
            for (const el of pv.querySelectorAll('[style*="font-size"]')) {
                if (isMarker(el)) {
                    before.add(el);
                }
            }
        }
        const pillSnap = pills.map((pillEl) => [pillEl, pillEl.style.cssText]);
        try {
            document.execCommand('styleWithCSS', false, 'true');
            if (document.execCommand('fontSize', false, '7') && pv) {
                for (const el of pv.querySelectorAll('[style*="font-size"]')) {
                    if (isMarker(el) && !before.has(el)) {
                        el.style.fontSize = pt + 'pt';
                    }
                }
                this.htmlEditorDirty = true;
            }
            for (const [pillEl, css] of pillSnap) {
                pillEl.style.cssText = css;
            }
        } catch (e) {
            /* formatting unavailable */
        }
    }

    get boldBtnClass() {
        return this.fmtState.bold ? 'dg-fmt-btn dg-fmt-on' : 'dg-fmt-btn';
    }
    get italicBtnClass() {
        return this.fmtState.italic ? 'dg-fmt-btn dg-fmt-on' : 'dg-fmt-btn';
    }
    get underlineBtnClass() {
        return this.fmtState.underline ? 'dg-fmt-btn dg-fmt-on' : 'dg-fmt-btn';
    }
    get strikeBtnClass() {
        return this.fmtState.strike ? 'dg-fmt-btn dg-fmt-on' : 'dg-fmt-btn';
    }

    _refreshFmtState() {
        if (!this.showHtmlBodyVisual) {
            return;
        }
        const next = { bold: false, italic: false, underline: false, strike: false };
        try {
            const sel = window.getSelection();
            let node = sel && sel.anchorNode;
            while (node && node.nodeType === 3) {
                node = node.parentNode;
            }
            const host = this.template.querySelector('.dg-visual-host');
            const pv = host && host.querySelector('.dg-pv');
            // A single selected pill reports its own look, not its parent's.
            const selPills = this._pillsInSelection();
            if (selPills.length === 1) {
                node = selPills[0];
            }
            if (node && pv && pv.contains(node)) {
                const cs = window.getComputedStyle(node);
                next.bold = cs.fontWeight === 'bold' || parseInt(cs.fontWeight, 10) >= 600;
                next.italic = cs.fontStyle === 'italic';
                const px = parseFloat(cs.fontSize);
                if (px) {
                    const pt = Math.round(px * 0.75 * 2) / 2;
                    if (pt !== this.fmtSizePt) {
                        this.fmtSizePt = pt;
                    }
                }
                // Decorations don't inherit through computed style — walk up.
                let el = node;
                while (el && el !== pv) {
                    const dcs = window.getComputedStyle(el);
                    const deco = dcs.textDecorationLine || dcs.textDecoration || '';
                    if (deco.indexOf('underline') !== -1 || el.tagName === 'U') {
                        next.underline = true;
                    }
                    if (
                        deco.indexOf('line-through') !== -1 ||
                        el.tagName === 'S' ||
                        el.tagName === 'STRIKE' ||
                        el.tagName === 'DEL'
                    ) {
                        next.strike = true;
                    }
                    el = el.parentElement;
                }
            }
        } catch (e) {
            /* leave defaults */
        }
        const cur = this.fmtState;
        if (
            cur.bold !== next.bold ||
            cur.italic !== next.italic ||
            cur.underline !== next.underline ||
            cur.strike !== next.strike
        ) {
            this.fmtState = next;
        }
    }

    handleFormatAction(event) {
        if (!this.showHtmlBodyVisual) {
            return;
        }
        const cmd = event.currentTarget.dataset.cmd;
        const value = event.currentTarget.dataset.value || null;
        if (!cmd) {
            return;
        }
        // Undo/redo are the designer's own stack, not execCommand's. execCommand
        // only ever knew about typing, so the toolbar buttons appeared to skip
        // straight past every table and block edit.
        if (cmd === 'undo') {
            this.handleUndo();
            return;
        }
        if (cmd === 'redo') {
            this.handleRedo();
            return;
        }
        // Formatting is a mutation like any other — capture before execCommand
        // runs, or Ctrl+Z after "Bold" would jump back past it.
        this._pushUndo('fmt:' + cmd);
        // #239 — the swatch buttons preventDefault on mousedown so the selection is
        // normally still live here, but the border-width <select> and any control that
        // does take focus land in this handler too. Restoring is idempotent when the
        // caret never moved.
        this._restoreCaret();
        // Keep the trigger's underbar showing the colour that was actually applied,
        // and dismiss the popover the way every other menu in Lightning does.
        if (cmd === 'foreColor' && value) {
            this._lastTextColor = value;
        } else if (cmd === 'hiliteColor' && value) {
            this._lastHighlight = value;
        }
        if (this.openFmtMenu) {
            this.closeFmtMenu();
        }
        // Lists via DOM surgery — LWS quietly breaks execCommand's list
        // commands, and this way numbers/bullets always render.
        if (cmd === 'insertUnorderedList' || cmd === 'insertOrderedList') {
            this._toggleListAtCaret(cmd === 'insertOrderedList');
            return;
        }
        // MULTI-CELL SELECTION TAKES PRECEDENCE.
        //
        // Selecting a block of cells and pressing Center used to centre exactly
        // one of them — whichever happened to hold the caret — because
        // execCommand only ever sees the caret, and the cell selection is a
        // model of ours it knows nothing about. Fill colour already applied to
        // the whole selection, so the toolbar behaved inconsistently with itself.
        //
        // Captured before any mutation: the array must not be read back after
        // the DOM has moved underneath it.
        const selCells = this._cellSel && this._cellSel.length ? this._cellSel.filter((c) => c && c.isConnected) : [];
        if (selCells.length > 1 && this._applyFmtAcrossCells(selCells, cmd, value)) {
            this.htmlEditorDirty = true;
            return;
        }
        // Alignment on a clicked image: align the block that holds it —
        // pure text-align, CSS 2.1-safe, exactly what the PDF engine honors.
        if (/^justify(Left|Center|Right)$/.test(cmd)) {
            const target = this._activePill;
            if (target && target.isConnected && target.tagName === 'IMG') {
                const dir = cmd === 'justifyLeft' ? 'left' : cmd === 'justifyRight' ? 'right' : 'center';
                const blk =
                    target.parentElement && target.parentElement.closest
                        ? target.parentElement.closest('p, div, h1, h2, h3, h4, td, th, li')
                        : null;
                if (blk) {
                    blk.style.textAlign = dir;
                    this.htmlEditorDirty = true;
                    return;
                }
            }
        }
        // Merge-tag pills in the selection take the format directly —
        // execCommand can't reach inside contenteditable=false atoms, and on a
        // pill-only selection it MANGLES the pill (strips inline styles, breaks
        // it out of its styled ancestor). Never let a pill-only selection near
        // execCommand.
        const selPills = this._pillsInSelection();
        if (selPills.length && this._applyFormatToPills(cmd, value, selPills)) {
            this.htmlEditorDirty = true;
            if (!this._selectionHasNonPillText()) {
                this._refreshFmtState();
                return;
            }
        }
        if (
            /^(bold|italic|underline|strikeThrough|superscript|subscript|foreColor|hiliteColor|fontName|fontSize)$/.test(
                cmd
            )
        ) {
            if (!this._selectionHasNonPillText()) {
                this._expandCaretToWord();
            }
        }
        // Mixed text+pill selection: execCommand may strip the pills' inline
        // styles while wrapping the text — snapshot and restore them.
        const pillSnap = selPills.map((pillEl) => [pillEl, pillEl.style.cssText]);
        try {
            document.execCommand('styleWithCSS', false, 'true');
            const ok = document.execCommand(cmd, false, value);
            for (const [pillEl, css] of pillSnap) {
                pillEl.style.cssText = css;
            }
            if (ok) {
                this.htmlEditorDirty = true;
                this._refreshFmtState();
            } else if (cmd !== 'undo' && cmd !== 'redo') {
                this.showToast(
                    'Select some text first',
                    'Highlight text in the page, then click a format button.',
                    'info'
                );
            }
        } catch (e) {
            this.showToast('Formatting unavailable', 'This browser blocked the formatting command.', 'warning');
        }
    }

    /**
     * Custom color pickers: opening the native picker steals focus, so the
     * page selection is snapshotted on mousedown and restored before the
     * chosen color is applied.
     */
    handleColorPickMouseDown() {
        try {
            const sel = window.getSelection();
            this._savedFmtRange = sel && sel.rangeCount ? sel.getRangeAt(0).cloneRange() : null;
        } catch (e) {
            this._savedFmtRange = null;
        }
        // ALSO capture the border target, now, before anything steals focus.
        //
        // A saved text RANGE is not enough for the border controls. Clicking the
        // colour swatch opens the native OS colour dialog, which takes focus off
        // the page entirely; by the time change fires, _selectedTableCell()
        // finds nothing and _reapplyBorders returns without touching the table —
        // so picking a border colour appeared to do nothing at all. A drag
        // selection of cells has no useful caret range either, so the range
        // alone could never have covered that case.
        try {
            const cell = this._selectedTableCell();
            this._borderTargetTable = cell && cell.closest ? cell.closest('table') : null;
            if (!this._borderTargetTable && this._cellSel && this._cellSel.length && this._cellSel[0].closest) {
                this._borderTargetTable = this._cellSel[0].closest('table');
            }
            this._borderTargetCells = this._cellSel && this._cellSel.length ? this._cellSel.slice() : null;
        } catch (e) {
            this._borderTargetTable = null;
            this._borderTargetCells = null;
        }
    }

    handleColorPickChange(event) {
        if (!this.showHtmlBodyVisual) {
            return;
        }
        const cmd = event.currentTarget.dataset.cmd;
        const value = event.currentTarget.value;
        // #239 — re-focus the canvas BEFORE restoring the range. The old code restored
        // the range but left focus on the <input type="color"> (or on the native OS
        // color dialog), and execCommand does nothing in that state — the picker looked
        // like it worked and changed nothing.
        this._restoreCaret();
        if (cmd === 'cellFill') {
            const cell = this._selectedTableCell();
            if (cell) {
                cell.style.background = value;
                this.htmlEditorDirty = true;
            } else {
                this.showToast(
                    'Click inside a table cell first',
                    'Put your cursor in a cell, then pick the fill color.',
                    'info'
                );
            }
            return;
        }
        const pillTargets = this._pillsInSelection();
        if (pillTargets.length && this._applyFormatToPills(cmd, value, pillTargets)) {
            this.htmlEditorDirty = true;
            if (!this._selectionHasNonPillText()) {
                return;
            }
        }
        if (!this._selectionHasNonPillText()) {
            this._expandCaretToWord();
        }
        const pillCssSnap = pillTargets.map((pillEl) => [pillEl, pillEl.style.cssText]);
        try {
            document.execCommand('styleWithCSS', false, 'true');
            if (document.execCommand(cmd, false, value)) {
                this.htmlEditorDirty = true;
            }
            for (const [pillEl, css] of pillCssSnap) {
                pillEl.style.cssText = css;
            }
        } catch (e) {
            /* ignore */
        }
    }

    /**
     * Enter/exit visual (in-place) editing. The template renders through the
     * SAME scoped-preview pipeline the Preview toggle uses — tables, bands,
     * everything — and the rendered page is made contenteditable, so authors
     * edit text exactly where it appears. On exit, only the edited body
     * content is swapped back between the ORIGINAL document's <body> tags:
     * head, styles, and @page are never round-tripped, so structure can't be
     * mangled. Unchanged sessions restore the original code byte-for-byte.
     */
    handleToggleHtmlVisual() {
        if (this.showHtmlBodyVisual) {
            this._exitVisualMode();
            return;
        }
        const ta = this.template.querySelector('.dg-html-body-editor');
        const html = (ta && ta.value) || '';
        if (!html.trim()) {
            this.showToast('Nothing to edit', 'Load or paste a template body first.', 'warning');
            return;
        }
        this._enterVisualMode(html);
    }

    _enterVisualMode(html) {
        // Regions: the source the author edits is ONE document, header and footer
        // included. The canvas only ever renders the body, and the bands render the
        // chrome, so peel them apart on the way in. A legacy template carries no
        // markers — hadRegions is false and nothing is touched, which is why an
        // existing header is never blanked by opening the designer.
        const parts = this._adoptRegions(html);
        html = parts.body;
        this._visualOriginalCode = html;
        this._visualEnteredDom = null; // captured in renderedCallback after mount
        // A different document is about to occupy the canvas — undoing into the
        // previous one's history would splice two unrelated documents together.
        this._resetUndoHistory();
        this._parsePageSetup(html);
        this.showHtmlBodyVisual = true;
        // Reuse the preview pipeline, but flag the write as editable so
        // renderedCallback turns the rendered page into an editor.
        const scoped = scopeHtmlForInlinePreview(html);
        this._pendingPreviewWrite = { selector: '.dg-visual-host', html: scoped, editable: true };
    }

    /**
     * Merge tags become atomic pills in the editable page: friendly colored
     * chips (purple fields, green loop/section markers) that read as objects
     * instead of code, and — because they're contenteditable=false — can only
     * be deleted whole, never half-mangled. Walks TEXT nodes only, so tags
     * inside attributes are untouched.
     */
    /**
     * ChildNode.replaceWith is MISSING on LWS-proxied nodes inside the
     * MANAGED PACKAGE's namespace sandbox (fine in source-deployed orgs —
     * which is why it passed every scratch-org test and then threw
     * "t.replaceWith is not a function" for subscribers, hanging the
     * designer). replaceChild via the parent works everywhere.
     */
    _safeReplace(node, replacement) {
        try {
            if (typeof node.replaceWith === 'function') {
                node.replaceWith(replacement);
                return;
            }
        } catch (e) {
            /* fall through to replaceChild */
        }
        const parent = node.parentNode;
        if (parent) {
            parent.replaceChild(replacement, node);
        }
    }

    _pillifyTags(root) {
        const doc = root.ownerDocument || document;
        // Repair pass: flatten any pill-inside-pill layering left behind by
        // older bundles before wrapping anything new.
        let nested = root.querySelectorAll('[data-dg-tag] [data-dg-tag]');
        while (nested.length) {
            for (const inner of nested) {
                this._safeReplace(inner, doc.createTextNode(inner.textContent));
            }
            nested = root.querySelectorAll('[data-dg-tag] [data-dg-tag]');
        }
        const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        const targets = [];
        while (walker.nextNode()) {
            const node = walker.currentNode;
            const parent = node.parentElement;
            // Never wrap inside <style>, and NEVER inside an existing pill —
            // re-pillifying pill text nests a new layer on every insert.
            // parent === null is a FRAGMENT-ROOT text node (bare tag snippet
            // from a chip) — those must pillify too.
            const blocked = parent && (parent.tagName === 'STYLE' || parent.closest('[data-dg-tag]'));
            if (/\{[^{}]+\}/.test(node.nodeValue) && !blocked) {
                targets.push(node);
            }
        }
        for (const node of targets) {
            const frag = doc.createDocumentFragment();
            for (const part of node.nodeValue.split(/(\{[^{}]+\})/g)) {
                if (/^\{[^{}]+\}$/.test(part)) {
                    const assetImg = this._assetImgFor(part, doc);
                    if (assetImg) {
                        frag.appendChild(assetImg);
                        continue;
                    }
                    const pill = doc.createElement('span');
                    pill.setAttribute('data-dg-tag', 'true');
                    pill.setAttribute('contenteditable', 'false');
                    pill.textContent = part;
                    pill.style.cssText = this._pillStyleFor(part);
                    this._sizeBarcodePill(pill, part);
                    frag.appendChild(pill);
                } else if (part) {
                    frag.appendChild(doc.createTextNode(part));
                }
            }
            node.parentNode.replaceChild(frag, node);
        }
    }

    /** Barcode/QR pills occupy their rendered footprint on the canvas so the
     *  page's proportions match the PDF ({*Id:qr:95} = a 95px square, not a
     *  small chip). Placeholder box only — the real code renders in the PDF. */
    _sizeBarcodePill(pill, tagText) {
        const m = /^\{\*([^:}]+)(?::(qr|code128|code39))?(?::(\d+)(?:x(\d+))?)?\}$/i.exec((tagText || '').trim());
        if (!m) {
            return;
        }
        const kind = (m[2] || 'qr').toLowerCase();
        let w;
        let h;
        if (kind === 'qr') {
            w = parseInt(m[3], 10) || 120;
            h = w;
        } else {
            w = parseInt(m[3], 10) || 280;
            h = parseInt(m[4], 10) || 60;
        }
        pill.style.display = 'inline-block';
        pill.style.width = w + 'px';
        pill.style.height = h + 'px';
        pill.style.lineHeight = h + 'px';
        pill.style.textAlign = 'center';
        pill.style.overflow = 'hidden';
        pill.style.fontSize = '10px';
        pill.style.background = 'repeating-linear-gradient(90deg, #e6e2f5 0 3px, #f6f4fc 3px 6px)';
        pill.style.borderStyle = 'dashed';
    }

    /**
     * Apply a toolbar command to EVERY cell in the multi-cell selection.
     *
     * Returns true when it handled the command, false to let the normal
     * caret-based path run — a command this does not understand must fall
     * through rather than be silently swallowed.
     *
     * Two different mechanisms, because two different things are being set:
     *
     *  - Alignment is a property of the CELL. Written as cell.style.textAlign,
     *    which is CSS 2.1 and exactly what the PDF engine honours. Running
     *    execCommand('justifyCenter') per cell would instead wrap the contents
     *    in alignment divs that survive into the generated document.
     *  - Character formatting belongs to the cell's CONTENTS, so each cell's
     *    contents are selected in turn and the command run over them.
     */
    _applyFmtAcrossCells(cells, cmd, value) {
        const align = /^justify(Left|Center|Right)$/.exec(cmd);
        if (align) {
            const dir = align[1].toLowerCase();
            for (const cell of cells) {
                cell.style.textAlign = dir;
            }
            this._repaintCellSel(cells);
            return true;
        }

        // DOM SURGERY, NOT execCommand.
        //
        // The obvious implementation — select each cell's contents and run
        // document.execCommand('bold') — was written first and does NOTHING.
        // It reported success and left all three cells unbolded. This is the
        // same LWS behaviour that already forced the list commands off
        // execCommand: inside a manual-DOM host it quietly declines to act on a
        // programmatically-built range. Wrapping the contents by hand always
        // works, and produces the plain <b>/<i>/<u>/<s> the PDF engine wants.
        const WRAP = { bold: 'b', italic: 'i', underline: 'u', strikeThrough: 's' };
        // Cell-level properties. Setting these on the CELL rather than around
        // its contents keeps the markup clean and inherits to everything inside,
        // which is what selecting a whole cell implies anyway.
        const CELL_STYLE = { foreColor: 'color', fontName: 'fontFamily' };

        if (WRAP[cmd]) {
            const tag = WRAP[cmd];
            // Toggle on the whole selection, decided ONCE: if every cell is
            // already wrapped, this is an un-bold. Deciding per cell would make
            // a mixed selection alternate instead of converging.
            const allWrapped = cells.every((c) => {
                const kids = Array.from(c.childNodes).filter((n) => n.nodeType !== 3 || n.nodeValue.trim());
                return kids.length === 1 && kids[0].nodeName && kids[0].nodeName.toLowerCase() === tag;
            });
            for (const cell of cells) {
                if (allWrapped) {
                    const only = Array.from(cell.childNodes).find(
                        (n) => n.nodeName && n.nodeName.toLowerCase() === tag
                    );
                    if (only) {
                        while (only.firstChild) {
                            cell.insertBefore(only.firstChild, only);
                        }
                        only.remove();
                    }
                    // "Does this cell hold anything?" via childNodes rather than
                    // innerHTML — same predicate as the allWrapped check above, and it
                    // keeps @lwc/lwc/no-inner-html quiet. textContent is NOT equivalent:
                    // a cell holding only an <img> has empty text but is not empty.
                } else if (Array.from(cell.childNodes).some((n) => n.nodeType !== 3 || n.nodeValue.trim())) {
                    const el = (cell.ownerDocument || document).createElement(tag);
                    while (cell.firstChild) {
                        el.appendChild(cell.firstChild);
                    }
                    cell.appendChild(el);
                }
            }
            this._repaintCellSel(cells);
            return true;
        }

        if (CELL_STYLE[cmd] && value) {
            for (const cell of cells) {
                cell.style[CELL_STYLE[cmd]] = value;
            }
            this._repaintCellSel(cells);
            return true;
        }

        // Anything else falls through to the normal caret path rather than
        // being half-applied. hiliteColor in particular is the table Fill
        // control's job, and removeFormat/super/subscript across whole cells
        // would mean something different from what the button promises.
        return false;
    }

    /**
     * Re-assert the cell-selection highlight after a formatting pass.
     *
     * execCommand rewrites a cell's inner markup, and _pushUndo's snapshot
     * clears the caret paint, so the purple ring can be lost even though the
     * selection is logically unchanged. Losing it makes the next command look
     * like it applied to nothing — the user pressed Center, then Bold, and Bold
     * only hit one cell because the selection had visually evaporated.
     */
    _repaintCellSel(cells) {
        for (const cell of cells) {
            if (!cell || !cell.isConnected) {
                continue;
            }
            cell.setAttribute('data-dg-selcell', '1');
            cell.style.boxShadow = 'inset 0 0 0 2px #7c3aed';
            cell.style.backgroundClip = 'padding-box';
        }
        this._cellSel = cells.filter((c) => c && c.isConnected);
    }

    _pillStyleFor(tagText) {
        // Chrome only (tint + border) — font family/size/color/weight INHERIT
        // from the surrounding text, so a pill inside a 24pt serif heading
        // reads exactly like the value will print.
        //
        // CONTAINMENT is the load-bearing part, not the tint. This used to be
        // `white-space: nowrap` with no width limit, so a long tag such as
        // {Statement_Date__c:MMMM d, yyyy} in a narrow table cell could not
        // wrap: it spilled straight out of the cell and sat on top of the
        // neighbouring one. The overlapping pill then swallowed the clicks meant
        // for whatever was underneath, so both became uneditable — a pill you
        // can see, cannot click, and cannot get rid of.
        //
        //   max-width:100%   — never wider than the cell that holds it
        //   white-space:normal + overflow-wrap:anywhere
        //                    — wrap INSIDE the cell instead of escaping it. A
        //                      tag may break across two lines, which is far
        //                      better than one that cannot be edited.
        //   display:inline-block + vertical-align:baseline
        //                    — max-width only applies to a block-ish box, and
        //                      baseline keeps it sitting on the text line.
        const isStructural = /^[#/:%@*]/.test((tagText || '').charAt(1));
        const containment =
            'display:inline-block;max-width:100%;white-space:normal;overflow-wrap:anywhere;' +
            'vertical-align:baseline;box-sizing:border-box;';
        return isStructural
            ? 'background:#e3f5e9;border:1px solid #9fd6b1;border-radius:9px;padding:0 6px;cursor:pointer;' +
                  containment
            : 'background:#ede7fd;border:1px solid #c9b8f5;border-radius:9px;padding:0 6px;cursor:pointer;' +
                  containment;
    }

    /**
     * True only when the selection contains editable text OUTSIDE pills.
     * sel.toString() lies here — a selected pill contributes its tag text,
     * which sent pill-only selections down the execCommand path where the
     * browser strips the pill's inline styles and restructures around it.
     */
    _selectionHasNonPillText() {
        let sel = null;
        try {
            sel = window.getSelection();
        } catch (e) {
            return false;
        }
        if (!sel || !sel.rangeCount || sel.isCollapsed) {
            return false;
        }
        try {
            const frag = sel.getRangeAt(0).cloneContents();
            for (const pillEl of frag.querySelectorAll('[data-dg-tag]')) {
                pillEl.remove();
            }
            return (frag.textContent || '').trim().length > 0;
        } catch (e) {
            return false;
        }
    }

    /** Pills whose box intersects the current selection (text pills only). */
    _pillsInSelection() {
        const host = this.template.querySelector('.dg-visual-host');
        const pv = host && host.querySelector('.dg-pv');
        if (!pv) {
            return [];
        }
        let sel = null;
        try {
            sel = window.getSelection();
        } catch (e) {
            return [];
        }
        if (!sel || !sel.rangeCount) {
            return [];
        }
        const range = sel.getRangeAt(0);
        const out = [];
        for (const pill of pv.querySelectorAll('[data-dg-tag]')) {
            if (pill.tagName === 'IMG') {
                continue;
            }
            let hit = false;
            try {
                hit = sel.containsNode(pill, true);
            } catch (e) {
                hit = false;
            }
            if (!hit) {
                try {
                    hit = range.intersectsNode(pill);
                } catch (e) {
                    /* LWS can refuse cross-realm Range checks */
                }
            }
            if (hit) {
                out.push(pill);
            }
        }
        // The last-clicked pill is ALWAYS a target, even when the sandboxed
        // Selection API won't report it (LWS realm quirk observed live:
        // main-world selection shows the pill, component-realm checks come
        // back empty). Cleared when the user clicks elsewhere on the page.
        if (this._activePill && this._activePill.isConnected && out.indexOf(this._activePill) === -1) {
            out.push(this._activePill);
        }
        return out;
    }

    /**
     * Toolbar formatting applied straight onto pills — merge tags are
     * contenteditable=false atoms, so execCommand skips them. The styles
     * survive serialization (see _unpillifyTags).
     */
    _applyFormatToPills(cmd, value, pills) {
        const sizePx = { 1: '10px', 2: '13px', 3: '16px', 4: '18px', 5: '24px', 6: '32px', 7: '48px' };
        let handled = true;
        for (const pill of pills) {
            const st = pill.style;
            if (cmd === 'bold') {
                st.fontWeight = st.fontWeight === 'bold' ? '' : 'bold';
            } else if (cmd === 'italic') {
                st.fontStyle = st.fontStyle === 'italic' ? '' : 'italic';
            } else if (cmd === 'underline') {
                st.textDecorationLine = st.textDecorationLine === 'underline' ? '' : 'underline';
            } else if (cmd === 'strikeThrough') {
                st.textDecorationLine = st.textDecorationLine === 'line-through' ? '' : 'line-through';
            } else if (cmd === 'foreColor') {
                st.color = value || '';
            } else if (cmd === 'fontName') {
                st.fontFamily = value || '';
            } else if (cmd === 'fontSize') {
                st.fontSize = sizePx[value] || '';
            } else {
                handled = false;
            }
        }
        return handled;
    }

    /**
     * Pill inspector: parse the clicked pill's tag and offer one-click
     * transformations — format suffixes, or re-render the same field as a
     * QR code, barcode, or image.
     */
    _openPillMenu(pill) {
        this._activePill = pill;
        // Select the pill so the main toolbar (B/I/size/color/font) targets it.
        try {
            const doc = pill.ownerDocument || document;
            const r = doc.createRange();
            r.selectNode(pill);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(r);
        } catch (e) {
            /* best effort */
        }
        const raw = (pill.textContent || '').trim();
        const inner = raw.replace(/^\{|\}$/g, '');
        const first = inner.charAt(0);
        let field = null;
        if (first === '*' || first === '%') {
            field = inner.slice(1).split(':')[0];
        } else if (!/^[#/:@]/.test(first) && !/^(SUM|AVG|MIN|MAX|COUNT|Chart)\b/i.test(inner)) {
            field = inner.split(':')[0];
        }
        let sections = [];
        if (field) {
            const f = field;
            const opt = (key, label, tag) => ({
                key,
                label,
                tag,
                cls: tag === raw ? 'dg-pill-menu-item dg-pill-menu-item_active' : 'dg-pill-menu-item'
            });
            const cur = (code, sample) => opt('cur_' + code, code + '  ' + sample, '{' + f + ':currency:' + code + '}');
            const dt = (pat, sample) => opt('dt_' + pat, sample, '{' + f + ':' + pat + '}');
            sections = [
                {
                    key: 'text',
                    label: 'Text',
                    options: [
                        opt('plain', 'Plain text', '{' + f + '}'),
                        opt('label', 'Picklist label', '{' + f + ':label}'),
                        opt('checkbox', 'Checkbox [X]/[ ]', '{' + f + ':checkbox}')
                    ]
                },
                {
                    key: 'currency',
                    label: 'Currency',
                    options: [
                        opt(
                            'cur_auto',
                            "Record's currency (multi-currency orgs) — recommended",
                            '{' + f + ':currency:auto}'
                        ),
                        opt('currency', "User's currency — $1,234.00", '{' + f + ':currency}'),
                        cur('USD', '$1,234.56'),
                        cur('EUR', '1.234,56 €'),
                        cur('GBP', '£1,234.56'),
                        cur('JPY', '¥1,235'),
                        cur('CAD', 'CA$1,234.56'),
                        cur('AUD', 'A$1,234.56'),
                        cur('CHF', "CHF 1'234.56"),
                        cur('CNY', '¥1,234.56'),
                        cur('INR', '₹1,23,456.00'),
                        cur('BRL', 'R$ 1.234,56'),
                        cur('MXN', 'MX$1,234.56')
                    ]
                },
                {
                    key: 'dates',
                    label: 'Dates',
                    options: [
                        opt('date_user', "Reader's locale date (auto)", '{' + f + ':date}'),
                        opt('date_gb', 'UK locale — 17/04/2026', '{' + f + ':date:en_GB}'),
                        opt('date_de', 'German locale — 17.04.2026', '{' + f + ':date:de_DE}'),
                        opt('date_fr', 'French locale — 17/04/2026', '{' + f + ':date:fr_FR}'),
                        opt('date_jp', 'Japanese locale — 2026/04/17', '{' + f + ':date:ja_JP}'),
                        opt('date_br', 'Brazilian locale — 17/04/2026', '{' + f + ':date:pt_BR}'),
                        dt('MMMM d, yyyy', 'April 17, 2026 — US long'),
                        dt('MMM d, yyyy', 'Apr 17, 2026'),
                        dt('MM/dd/yyyy', '04/17/2026 — US'),
                        dt('dd/MM/yyyy', '17/04/2026 — UK · EU'),
                        dt('d MMMM yyyy', '17 April 2026 — EU long'),
                        dt('dd.MM.yyyy', '17.04.2026 — DE · CH'),
                        dt('yyyy-MM-dd', '2026-04-17 — ISO'),
                        dt('yyyy年M月d日', '2026年4月17日 — JP'),
                        dt('EEEE, MMMM d, yyyy', 'Friday, April 17, 2026'),
                        dt('MMMM yyyy', 'April 2026 — month only'),
                        dt('MMMM d, yyyy h:mm a', 'April 17, 2026 3:45 PM')
                    ]
                },
                {
                    key: 'numbers',
                    label: 'Numbers',
                    options: [
                        opt('number', 'Number — 1,234', '{' + f + ':number}'),
                        opt('number_eu', 'Number EU — 1.234', '{' + f + ':number:de_DE}'),
                        opt('percent_eu', 'Percent EU — 15,5%', '{' + f + ':percent:de_DE}'),
                        dt('#,##0.00', '1,234.50 — two decimals'),
                        dt('#,##0', '1,235 — whole'),
                        dt('0.00', '1234.50 — no thousands'),
                        opt('percent', 'Percent — 15.5%', '{' + f + ':percent}')
                    ]
                },
                {
                    key: 'other',
                    label: 'Codes & images',
                    options: [
                        opt('qr', 'QR code', '{*' + f + ':qr:200}'),
                        opt('barcode', 'Barcode (Code 128)', '{*' + f + ':code128:300x80}'),
                        opt('barcode39', 'Barcode (Code 39)', '{*' + f + ':code39:300x80}'),
                        opt('image', 'Image field', '{%' + f + '}')
                    ]
                }
            ];
        }
        // The menu was positioned absolutely against .dg-designer-canvas-col — which is
        // `overflow-y: auto`, so the menu was clipped by the scroll container and
        // scrolled away with the content. Same defect class as the toolbar popovers.
        // It now joins the fixed floating layer and is placed from the pill's viewport
        // rect in renderedCallback, once the element exists and can be measured.
        this._floatAnchor = pill;
        this.pillMenu = {
            tagText: raw,
            sections,
            hasOptions: sections.length > 0,
            posStyle: 'left: -9999px; top: -9999px;'
        };
        this._watchFloatingLayer(true);
    }

    handlePillTransform(event) {
        const tag = event.currentTarget.dataset.tag;
        if (this._activePill && tag) {
            this._pushUndo('pill-transform');
            this._activePill.textContent = tag;
            this._activePill.style.cssText = this._pillStyleFor(tag);
            this.htmlEditorDirty = true;
        }
        this.pillMenu = null;
    }

    /**
     * The menu's first line edits the tag directly.
     *
     * Enter applies, Escape abandons. Both stopPropagation: the canvas has its
     * own Enter/Escape handling (new paragraph, dismiss menus), and without this
     * typing a tag would also split the block underneath.
     */
    handlePillHeadKeydown(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            event.stopPropagation();
            this._commitPillHead(event.currentTarget.value);
        } else if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            this.pillMenu = null;
        } else {
            // Every other key too — a '/' or backtick typed into this field must
            // not reach the canvas and open the slash or tag menu on top of it.
            event.stopPropagation();
        }
    }

    handlePillHeadCommit(event) {
        this._commitPillHead(event.currentTarget.value);
    }

    _commitPillHead(raw) {
        const text = (raw || '').trim();
        // A blank field is treated as "no change", never as delete. Committing ''
        // is how an image pill previously got destroyed by an edit — removal is
        // what the Remove command is for, and it should be deliberate.
        if (!text || !this._activePill) {
            this.pillMenu = null;
            return;
        }
        // Typing "Name" rather than "{Name}" is the common case; brace it.
        const tag = text.startsWith('{') ? text : '{' + text.replace(/^\{|\}$/g, '') + '}';
        if (tag === (this._activePill.textContent || '').trim()) {
            this.pillMenu = null;
            return;
        }
        this._pushUndo('pill-edit');
        this._activePill.textContent = tag;
        this._activePill.style.cssText = this._pillStyleFor(tag);
        this.htmlEditorDirty = true;
        this.pillMenu = null;
    }

    handlePillRemove() {
        if (this._activePill) {
            this._pushUndo('pill-remove');
            this._activePill.remove();
            this.htmlEditorDirty = true;
        }
        this.pillMenu = null;
        this._activePill = null;
    }

    handlePillMenuClose() {
        this.pillMenu = null;
    }

    handlePillEdit() {
        if (this._activePill) {
            this._beginPillEdit(this._activePill);
        }
        this.pillMenu = null;
    }

    /**
     * Edit a pill's tag text in place (loop names, conditionals, modifiers —
     * anything). Enter or clicking away commits; braces are auto-completed;
     * an emptied pill removes itself.
     */
    _beginPillEdit(pill) {
        this.pillMenu = null;
        // Image pills have no text — editing one as text committed '' and
        // DELETED the image. Swap the img for a text pill showing its tag,
        // edit that, and the commit re-imagifies asset tags below.
        if (pill.tagName === 'IMG') {
            const imgTag = pill.getAttribute('data-dg-tag') || '';
            const doc = pill.ownerDocument || document;
            const span = doc.createElement('span');
            span.setAttribute('data-dg-tag', 'true');
            span.setAttribute('contenteditable', 'false');
            span.textContent = imgTag;
            span.style.cssText = this._pillStyleFor(imgTag);
            this._safeReplace(pill, span);
            pill = span;
        }
        pill.setAttribute('contenteditable', 'true');
        pill.style.borderStyle = 'dashed';
        pill.style.cursor = 'text';
        this._editingPill = pill;
        try {
            const range = document.createRange();
            range.selectNodeContents(pill);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
        } catch (e) {
            /* selection best-effort */
        }
        const finish = () => {
            if (this._editingPill !== pill) {
                return; // already committed (blur + outside-click both fired)
            }
            this._editingPill = null;
            pill.removeEventListener('blur', finish);
            let t = (pill.textContent || '').trim();
            if (!t || t === '{}' || t === '{' || t === '}') {
                pill.remove();
                this.htmlEditorDirty = true;
                return;
            }
            if (!t.startsWith('{')) {
                t = '{' + t;
            }
            if (!t.endsWith('}')) {
                t = t + '}';
            }
            pill.textContent = t;
            pill.setAttribute('contenteditable', 'false');
            pill.style.cssText = this._pillStyleFor(t);
            this.htmlEditorDirty = true;
            // An asset tag goes back to being a real image on the canvas.
            if (/^\{%asset:/i.test(t)) {
                this._imagifyAssetPills();
            }
            // Park the caret AFTER the pill — leaving it inside means the next
            // keystrokes grow the pill instead of typing beside it.
            try {
                const host = this.template.querySelector('.dg-visual-host');
                const pv = host && host.querySelector('.dg-pv');
                const r = document.createRange();
                r.setStartAfter(pill);
                r.collapse(true);
                const s = window.getSelection();
                s.removeAllRanges();
                s.addRange(r);
                if (pv) {
                    pv.focus();
                }
            } catch (e) {
                /* caret parking best-effort */
            }
        };
        this._finishPillEdit = finish;
        pill.addEventListener('blur', finish);
        pill.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === 'Escape') {
                e.preventDefault();
                e.stopPropagation();
                finish();
            }
        });
        pill.focus();
    }

    /**
     * Type-to-pill: when typing in the page completes a {tag} in a plain
     * text node, snap it into a pill and put the caret right after it.
     */
    /**
     * The page's scoped <style> is the canvas's first child INSIDE the
     * contenteditable — if a native edit (select-all delete, cut, backspace
     * from the root) removes it, the white page styling vanishes with it.
     * Reattach it at the top whenever it goes missing.
     */
    _healCanvasStyle(pv) {
        try {
            const st = this._pvStyleEl;
            if (st && !pv.contains(st)) {
                pv.insertBefore(st, pv.firstChild);
            }
        } catch (e) {
            /* best effort */
        }
    }

    /**
     * Clicking the page's top-left corner (or Ctrl+Home in some engines)
     * collapses the selection at the canvas ROOT, at or before the scoped
     * <style> node. From there Space inserts nothing visible and Backspace
     * consumes the style element ("the whole white canvas disappears" —
     * community report, Edge). Move such a caret to the start of the first
     * real content node so native editing always acts on content.
     */
    /**
     * Backspace/Delete must not be able to destroy the document's floor.
     *
     * On a new or nearly-empty page, holding Backspace ate the last block and then
     * the scoped <style> element that gives the canvas its page styling — the white
     * sheet vanished and the editor became unusable with no obvious way back. Nothing
     * short of reloading recovered it.
     *
     * Two guards: refuse a deleting keystroke that would leave no editable block, and
     * refuse one whose selection has swallowed the <style>.
     */
    _guardCanvasFloor(e, pv) {
        if (!e || (e.key !== 'Backspace' && e.key !== 'Delete')) {
            return;
        }
        try {
            const style = this._pvStyleEl;
            const blocks = pv.querySelectorAll('p, h1, h2, h3, h4, h5, h6, li, td, th, div, blockquote, table');
            const sel = window.getSelection();

            // A selection that spans the stylesheet would take it with it.
            if (style && sel && sel.rangeCount && !sel.isCollapsed) {
                const r = sel.getRangeAt(0);
                if (r.intersectsNode && r.intersectsNode(style)) {
                    e.preventDefault();
                    return;
                }
            }

            // Last block, caret at its very start, nothing selected: the next
            // Backspace merges it into the canvas root and strands the caret before
            // the stylesheet. Keep one empty paragraph as the floor.
            if (blocks.length <= 1 && e.key === 'Backspace' && sel && sel.isCollapsed) {
                const only = blocks[0];
                const atStart =
                    !only ||
                    (sel.anchorNode === only && sel.anchorOffset === 0) ||
                    (sel.anchorNode &&
                        sel.anchorNode.nodeType === 3 &&
                        sel.anchorOffset === 0 &&
                        only &&
                        only.contains(sel.anchorNode) &&
                        (only.textContent || '').length <= 1);
                if (atStart) {
                    e.preventDefault();
                }
            }
        } catch (err) {
            /* never let a guard break typing */
        }
    }

    _normalizeRootCaret(pv) {
        try {
            const sel = window.getSelection();
            if (!sel || !sel.rangeCount || !sel.isCollapsed || sel.anchorNode !== pv) {
                return;
            }
            const st = this._pvStyleEl;
            const styleIdx = st && pv.contains(st) ? Array.prototype.indexOf.call(pv.childNodes, st) : -1;
            if (sel.anchorOffset > styleIdx + 1) {
                return;
            }
            let target = null;
            for (let i = styleIdx + 1; i < pv.childNodes.length; i++) {
                const n = pv.childNodes[i];
                if (n.nodeType === 1 || (n.nodeType === 3 && n.nodeValue.trim())) {
                    target = n;
                    break;
                }
            }
            if (!target) {
                return;
            }
            const r = document.createRange();
            r.setStart(target, 0);
            r.collapse(true);
            sel.removeAllRanges();
            sel.addRange(r);
        } catch (e) {
            /* best effort */
        }
    }

    _maybePillifyTyped() {
        try {
            const sel = window.getSelection();
            if (!sel || !sel.rangeCount || !sel.isCollapsed) {
                return;
            }
            const node = sel.anchorNode;
            if (!node || node.nodeType !== 3) {
                return;
            }
            const parent = node.parentElement;
            if (!parent || parent.tagName === 'STYLE' || parent.closest('[data-dg-tag]')) {
                return;
            }
            // #247 — type-to-pill has to work in the running header/footer bands too,
            // not just the page body.
            const pv = this._surfaceContaining(node);
            if (!pv || !/\{[^{}]+\}/.test(node.nodeValue)) {
                return;
            }
            const doc = node.ownerDocument || document;
            const frag = doc.createDocumentFragment();
            let lastPill = null;
            for (const part of node.nodeValue.split(/(\{[^{}]+\})/g)) {
                if (/^\{[^{}]+\}$/.test(part)) {
                    const pillEl = doc.createElement('span');
                    pillEl.setAttribute('data-dg-tag', 'true');
                    pillEl.setAttribute('contenteditable', 'false');
                    pillEl.textContent = part;
                    pillEl.style.cssText = this._pillStyleFor(part);
                    frag.appendChild(pillEl);
                    lastPill = pillEl;
                } else if (part) {
                    frag.appendChild(doc.createTextNode(part));
                }
            }
            node.parentNode.replaceChild(frag, node);
            // An asset tag becomes the real image, the same as one dropped in from
            // the rail. Only the INSERT paths ran _assetImgFor, so a tag the author
            // typed (or pasted) stayed a green text pill and they could not see the
            // logo they had just placed. Done before the caret is parked, because
            // imagifying swaps the node the caret would be anchored to.
            if (lastPill && /^\{%asset:/i.test(lastPill.textContent || '')) {
                const img = this._assetImgFor((lastPill.textContent || '').trim(), doc);
                if (img) {
                    this._safeReplace(lastPill, img);
                    lastPill = img;
                }
            }
            if (lastPill) {
                const r = doc.createRange();
                r.setStartAfter(lastPill);
                r.collapse(true);
                sel.removeAllRanges();
                sel.addRange(r);
            }
            // A freshly typed pill takes its style straight from _pillStyleFor, which
            // knows nothing about zoom — re-apply the spread so it matches its
            // neighbours instead of snapping back to tight spacing.
            this._applyPillSpread();
        } catch (e) {
            /* best effort */
        }
    }

    /** Pills back to plain merge-tag text (exit path). */
    /** WYSIWYG assets: {%asset:key} pills become the real image on canvas.
     *  The true tag lives in data-dg-tag; save round-trips through it. */
    _assetImgFor(tag, doc) {
        const m = /^\{%asset:([a-z0-9-]+)(?::([^}]+))?\}$/i.exec(tag);
        if (!m || !this._assetUrlByKey) {
            return null;
        }
        const url = this._assetUrlByKey[m[1].toLowerCase()];
        if (!url) {
            return null;
        }
        const img = doc.createElement('img');
        img.setAttribute('data-dg-tag', tag);
        img.setAttribute('contenteditable', 'false');
        // The editor implements its own move (_imgMoveStart) and resize with mouse
        // events. Leaving the image natively draggable means any mousedown the
        // editor does not claim becomes a browser drag inside a contenteditable —
        // which COPIES the image rather than moving it, so a fumbled resize left a
        // duplicate behind. Nothing here needs the native behaviour.
        img.setAttribute('draggable', 'false');
        img.src = url;
        img.style.cssText = 'vertical-align:middle;outline:1px dashed #b8e6c9;outline-offset:2px;cursor:nwse-resize;';
        const size = m[2];
        if (size) {
            const wh = /^(m?)(\d+)(px|%)?x?(m?)(\d*)(px|%)?$/i.exec(size.replace(/\s/g, ''));
            if (wh && wh[2]) {
                img.style.width = wh[2] + (wh[3] === '%' ? '%' : 'px');
                if (wh[5]) {
                    img.style.height = wh[5] + (wh[6] === '%' ? '%' : 'px');
                }
            }
        } else {
            img.style.maxWidth = '220px';
        }
        img.title = tag + ' — drag the corner to resize';
        return img;
    }

    /**
     * Turn {%asset:key} pills into the real image, on EVERY surface.
     *
     * This walked the body canvas only, so an asset dropped into a running header
     * stayed a green text pill on the sheet and only became an image in the PDF
     * preview — the author could not see their own logo while placing it, in the
     * one place a logo almost always goes.
     *
     * It matters that this runs over the bands and not just at pillify time: the
     * asset URL map arrives asynchronously, so a band mounted before the assets
     * load has text pills that only this pass can upgrade.
     */
    _imagifyAssetPills() {
        try {
            for (const surface of this._allSurfaces()) {
                const doc = surface.ownerDocument || document;
                for (const pill of Array.from(surface.querySelectorAll('span[data-dg-tag]'))) {
                    const tag = (pill.textContent || '').trim();
                    const img = this._assetImgFor(tag, doc);
                    if (img) {
                        this._safeReplace(pill, img);
                    }
                }
                this._stampAssetImageHeights(surface);
            }
        } catch (e) {
            /* best effort */
        }
    }

    /**
     * Repair width-only asset tags by measuring the rendered image.
     *
     * `{%asset:logo:200x}` renders as `width:200px;height:auto`, and the height
     * exists only in the image file — so the PDF engine cannot size the page margin
     * a running header needs, and a tall logo overflows it. Templates saved before
     * the resize handler recorded both dimensions are all in this state.
     *
     * Measuring here fixes them in place: the PDF preview reads the live surfaces,
     * so it is correct immediately, and the repaired tag persists on the next save.
     * Deliberately does NOT set htmlEditorDirty — opening a template must not
     * announce unsaved changes the author did not make.
     */
    _stampAssetImageHeights(surface) {
        let imgs;
        try {
            imgs = surface.querySelectorAll('img[data-dg-tag]');
        } catch (e) {
            return;
        }
        for (const img of imgs) {
            const m = /^\{%asset:([a-z0-9-]+):(\d+)x\}$/i.exec(img.getAttribute('data-dg-tag') || '');
            if (!m) {
                continue;
            }
            const stamp = () => {
                let h = Math.round(img.getBoundingClientRect().height);
                if (!(h > 0) && img.naturalWidth > 0) {
                    // Not laid out yet (a hidden surface) — derive it from the file.
                    h = Math.round((parseInt(m[2], 10) * img.naturalHeight) / img.naturalWidth);
                }
                if (!(h > 0)) {
                    return;
                }
                const next = '{%asset:' + m[1] + ':' + m[2] + 'x' + h + '}';
                img.setAttribute('data-dg-tag', next);
                img.title = next + ' — drag the corner to resize';
            };
            if (img.complete && img.naturalWidth) {
                stamp();
            } else {
                img.addEventListener('load', stamp, { once: true });
            }
        }
    }

    _unpillifyTags(root) {
        // Editor-only selection chrome must never reach saved HTML.
        for (const el of root.querySelectorAll('[data-dg-selcell]')) {
            el.removeAttribute('data-dg-selcell');
            el.style.boxShadow = '';
            el.style.backgroundClip = '';
            if (!el.getAttribute('style')) {
                el.removeAttribute('style');
            }
        }
        // Hover-cursor styles (col/row-resize, grab) and LWC's scoping
        // attributes are editor residue — scrub both from the whole tree.
        for (const el of root.querySelectorAll('*')) {
            if (el.style && el.style.cursor) {
                el.style.cursor = '';
                if (!el.getAttribute('style')) {
                    el.removeAttribute('style');
                }
            }
            for (const attr of [...el.attributes]) {
                if (attr.name.startsWith('lwc-')) {
                    el.removeAttribute(attr.name);
                }
            }
        }
        for (const pill of root.querySelectorAll('[data-dg-tag]')) {
            const attr = pill.getAttribute('data-dg-tag');
            const doc = root.ownerDocument || document;
            const tag = pill.tagName === 'IMG' && attr && attr.startsWith('{') ? attr : pill.textContent;
            // User formatting applied to the pill (the chrome in _pillStyleFor
            // never sets these props) rides out as a styled span so the merged
            // value prints with it.
            const st = pill.style;
            const kept = [];
            // Barcode pills carry placeholder-box styling (size, 10px label) —
            // none of it is user formatting; never serialize it.
            const isBarcodePill = (tag || '').trim().startsWith('{*');
            if (pill.tagName !== 'IMG' && !isBarcodePill) {
                if (st.fontWeight) kept.push(['font-weight', st.fontWeight]);
                if (st.fontStyle) kept.push(['font-style', st.fontStyle]);
                if (st.textDecorationLine) kept.push(['text-decoration', st.textDecorationLine]);
                if (st.color) kept.push(['color', st.color]);
                if (st.fontFamily) kept.push(['font-family', st.fontFamily]);
                if (st.fontSize) kept.push(['font-size', st.fontSize]);
            }
            if (!kept.length) {
                this._safeReplace(pill, doc.createTextNode(tag));
                continue;
            }
            const parent = pill.parentElement;
            const parentIsWrapper =
                parent && parent.tagName === 'SPAN' && parent.childNodes.length === 1 && parent.getAttribute('style');
            if (parentIsWrapper) {
                // Round-trip case: merge into the existing wrapper instead of
                // nesting a new span every save.
                for (const [prop, val] of kept) {
                    parent.style.setProperty(prop, val);
                }
                this._safeReplace(pill, doc.createTextNode(tag));
            } else {
                const wrap = doc.createElement('span');
                for (const [prop, val] of kept) {
                    wrap.style.setProperty(prop, val);
                }
                wrap.textContent = tag;
                this._safeReplace(pill, wrap);
            }
        }
    }

    // ===== Regions plumbing (DESIGNER_PLAN_V2 step 2) =========================
    //
    // The author has ONE source document; the render engine keeps the three-field
    // contract it has today. These two methods are the whole boundary between
    // those views, so there is exactly one place a region marker can leak.

    /**
     * Take a document that may carry region markers, move its header and footer
     * into the template fields, and hand back the body-only document.
     *
     * Only overwrites the header/footer fields when markers were actually present.
     * A legacy template reports hadRegions === false, so opening one can never
     * blank a header that lives only in Header_Html__c — the backwards-compatibility
     * guarantee, and the reason this needs no migration.
     */
    _adoptRegions(html) {
        const parts = splitRegions(html || '');
        if (parts.hadRegions) {
            if (parts.header !== null) {
                this.editTemplateHeaderHtml = parts.header;
            }
            if (parts.footer !== null) {
                this.editTemplateFooterHtml = parts.footer;
            }
        }
        return parts;
    }

    /**
     * The one source document, header and footer included — what "View Source"
     * shows and what the author thinks of as "the template". Never goes to a
     * ContentVersion; _currentDraftHtml is the renderer-bound view.
     */
    _currentDraftDocument() {
        const s = this._draftSurfaces();
        return joinRegions(s.body, s.header, s.footer);
    }

    /**
     * The whole document as one model, read in a single pass.
     *
     * Previously the body came from the live canvas while the header and footer
     * came from the template FIELDS — two independent reads, taken at two
     * different moments, of state kept in step by an input listener. A header
     * keystroke whose input event had not yet synced produced a preview showing
     * the body the author was looking at next to the header they had already
     * changed, and every new surface needed its own copy of that plumbing.
     *
     * Reading all three from the live surfaces at the same instant is what
     * DESIGNER_PLAN_V2 step 5 means by "preview from the model": there is one
     * document, and the preview renders it. The fields stay the persistence
     * format and remain the fallback for source mode, where there are no bands.
     */
    _draftSurfaces() {
        const chrome = this._liveChrome();
        return { body: this._currentDraftHtml() || '', header: chrome.header, footer: chrome.footer };
    }

    /**
     * The running header and footer as they stand on the LIVE bands.
     *
     * Reads through _syncBandToRecord so the template fields — the persistence
     * format — are brought current in the same pass. That is what makes an
     * un-synced keystroke reach Save as well as Preview, instead of each caller
     * needing its own copy of the plumbing. markDirty is false: reading the
     * document must not mark it edited.
     *
     * In source mode there are no bands, so the fields are the model.
     */
    _liveChrome() {
        if (this.showHtmlBodyVisual) {
            for (const which of ['header', 'footer']) {
                const band = this.template.querySelector('.dg-chrome-band_' + which);
                if (band) {
                    this._syncBandToRecord(which, band, false);
                }
            }
        }
        return { header: this.editTemplateHeaderHtml || '', footer: this.editTemplateFooterHtml || '' };
    }

    /** Leave visual mode — lossless when nothing changed. */
    /**
     * The BODY document as it stands RIGHT NOW — visual-mode edits serialized
     * non-destructively (same clone/unpillify/body-swap as exit, without
     * leaving visual mode), source mode read straight from the textarea.
     *
     * Renderer-bound: this is what gets staged into a ContentVersion and what the
     * PDF preview merges, so it is body-only and carries no region markers. The
     * source textarea holds the JOINED document, so reading it back here splits it
     * first — that is how an author's edit to the header inside View Source finds
     * its way to Header_Html__c.
     */
    _currentDraftHtml() {
        if (this.showHtmlBodyVisual) {
            const host = this.template.querySelector('.dg-visual-host');
            const pv = host && host.querySelector('.dg-pv');
            if (pv && this._visualOriginalCode != null) {
                const edited = this._extractVisualBody(pv);
                const bodyRe = /(<body\b[^>]*>)[\s\S]*?(<\/body\s*>)/i;
                const doc = bodyRe.test(this._visualOriginalCode)
                    ? this._visualOriginalCode.replace(bodyRe, (m, open, close) => open + '\n' + edited + '\n' + close)
                    : edited;
                // Belt and braces — the canvas holds body only, but a marker pasted
                // into it must not survive to the renderer.
                return stripRegionMarkers(doc);
            }
        }
        const ta = this.template.querySelector('.dg-html-body-editor');
        const raw = (ta && ta.value) || this._lastUploadedHtmlText || '';
        return this._adoptRegions(raw).body;
    }

    /**
     * Serialize the live visual canvas back to clean body HTML.
     *
     * Reads pv.innerHTML as a STRING and re-parses it inside a <template>,
     * rather than cloning the live canvas with pv.cloneNode(true). Under the
     * managed-package LWS namespace sandbox, cloneNode(true) silently omits
     * nodes that native contenteditable inserted — a paragraph added with
     * Enter, a pasted block — while the innerHTML string getter includes them.
     * Cloning therefore dropped anything STRUCTURALLY ADDED in the visual
     * editor (new <p>), even though edits to pre-existing blocks survived,
     * because those pre-existing nodes were created by our own innerHTML write
     * and so clone fine (community report: new paragraph never reaches
     * Source/Save). The re-parsed nodes are all sandbox-owned, so
     * _unpillifyTags / _safeReplace operate on them exactly as they do on the
     * upload path (see _sanitizeStagedHtml, which uses the same technique).
     */
    _extractVisualBody(pv) {
        // #238 — drop EVERY editor tint before the string round-trip. They are applied
        // as inline style (component CSS can't reach manual-DOM nodes), so leaving one
        // on would bake a purple tint into the saved template body — and the
        // row/column tint sits on top of the author's own cell fill.
        this._clearEditorPaint();
        const tpl = document.createElement('template');
        // eslint-disable-next-line @lwc/lwc/no-inner-html -- string round-trip of the live canvas; re-cleaned below, never cloneNode (LWS drops browser-inserted nodes)
        tpl.innerHTML = pv.innerHTML;
        const root = tpl.content;
        for (const styleEl of root.querySelectorAll('style')) {
            styleEl.remove();
        }
        for (const markerEl of root.querySelectorAll('.dg-drop-marker')) {
            markerEl.remove();
        }
        this._unpillifyTags(root);
        const container = document.createElement('div');
        container.appendChild(root);
        // eslint-disable-next-line @lwc/lwc/no-inner-html -- serialize the cleaned fragment back to a string
        return container.innerHTML.trim();
    }

    // --- Live PDF preview (real Blob.toPdf output in a blob: iframe) ---
    async handlePdfPreview() {
        if (!this.editTemplateTestRecordId) {
            this.showToast(
                'Pick a sample record',
                'PDF preview merges real data — choose a Sample Record in the toolbar first.',
                'warning'
            );
            return;
        }
        // ONE read of the model, not three reads of three surfaces — see
        // _draftSurfaces. Taken before the popup-blocked early return so both
        // request shapes below send the same document.
        const draft = this._draftSurfaces();
        const draftHtml = (draft.body || '').trim();
        if (!draftHtml) {
            this.showToast('Nothing to preview', 'The editor is empty.', 'warning');
            return;
        }
        // A ready-but-unopened preview from the last render: open it in THIS
        // click (synchronous = never popup-blocked), then reset.
        if (this._pendingPreviewUrl) {
            const readyWin = window.open(this._pendingPreviewUrl, '_blank');
            if (readyWin) {
                this._pendingPreviewUrl = null;
                this.pdfPreviewReady = false;
            }
            return;
        }
        this.isPdfPreviewLoading = true;
        try {
            const res = await previewDraftPdfData({
                templateId: this.editTemplateId,
                recordId: this.editTemplateTestRecordId,
                draftHtml,
                draftHeaderHtml: draft.header,
                draftFooterHtml: draft.footer
            });
            if (res && res.base64) {
                const raw = atob(res.base64);
                const bytes = new Uint8Array(raw.length);
                for (let i = 0; i < raw.length; i++) {
                    bytes[i] = raw.charCodeAt(i);
                }
                const url = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
                // Usually still inside the click's activation window, so this
                // opens directly. (LWS neuters a pre-opened window's proxy —
                // document.write/location are silent no-ops — so the tab must
                // be opened WITH its URL.)
                const win = window.open(url, '_blank');
                if (!win) {
                    // Popup blocked: arm the button for a synchronous open.
                    this._pendingPreviewUrl = url;
                    this.pdfPreviewReady = true;
                    this.showToast(
                        'Preview ready',
                        'Your PDF is rendered — click "Open preview" to view it.',
                        'success'
                    );
                }
                return;
            }
            // Too large for the Aura payload — ContentVersion + native viewer.
            const res2 = await previewDraftPdf({
                templateId: this.editTemplateId,
                recordId: this.editTemplateTestRecordId,
                draftHtml,
                draftHeaderHtml: draft.header,
                draftFooterHtml: draft.footer
            });
            if (!res2 || !res2.contentDocumentId) {
                throw new Error('Preview returned no PDF.');
            }
            this[NavigationMixin.Navigate]({
                type: 'standard__namedPage',
                attributes: { pageName: 'filePreview' },
                state: { selectedRecordId: res2.contentDocumentId }
            });
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('PDF preview failed', msg, 'error');
        } finally {
            this.isPdfPreviewLoading = false;
        }
    }

    handleClosePdfPreview() {
        this.pdfPreviewUrl = null;
    }

    @track pdfPreviewReady = false;

    get pdfPreviewBtnLabel() {
        if (this.pdfPreviewReady) {
            return 'Open preview \u2197';
        }
        return this.isPdfPreviewLoading ? 'Rendering…' : 'PDF Preview';
    }

    _exitVisualMode() {
        // #238 — MUST come before the innerHTML read below. The caret highlight is an
        // inline style, so leaving it on makes an untouched session compare unequal to
        // _visualEnteredDom and rewrite the body — breaking the documented guarantee
        // that an unchanged session restores the original code byte-for-byte.
        this._clearEditorPaint();
        // Read the chrome off the live bands while they still exist, so View Source
        // shows the header the author is looking at rather than the last value an
        // input event happened to sync.
        const chrome = this._liveChrome();
        const host = this.template.querySelector('.dg-visual-host');
        const pv = host && host.querySelector('.dg-pv');
        const ta = this.template.querySelector('.dg-html-body-editor');
        if (pv && ta && this._visualOriginalCode != null) {
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            const current = pv.innerHTML;
            if (this._visualEnteredDom !== null && current !== this._visualEnteredDom) {
                // Extract the edited content: everything except the scoped
                // <style> the preview pipeline injected, with tag pills
                // unwrapped back to plain merge-tag text. String round-trip,
                // NOT cloneNode — see _extractVisualBody (LWS drops
                // browser-inserted paragraphs from a cloned canvas).
                const edited = this._extractVisualBody(pv);
                // Swap ONLY the body content back into the original document —
                // head/styles/@page are untouched by design.
                const bodyRe = /(<body\b[^>]*>)[\s\S]*?(<\/body\s*>)/i;
                let newCode;
                if (bodyRe.test(this._visualOriginalCode)) {
                    newCode = this._visualOriginalCode.replace(
                        bodyRe,
                        (m, open, close) => open + '\n' + edited + '\n' + close
                    );
                } else {
                    // Body-fragment template (no <body> wrapper): the content IS the doc.
                    newCode = edited;
                }
                // Regions: what the author sees in View Source is the WHOLE
                // document, running header and footer included. This is the join;
                // _currentDraftHtml splits it back apart on the way to the renderer.
                // Templates with neither header nor footer come back unmarked, so a
                // plain document's source is byte-for-byte what it always was.
                ta.value = prettyPrintHtml(joinRegions(newCode, chrome.header, chrome.footer));
                this.htmlEditorDirty = true;
            } else {
                // Untouched — hand back the original text exactly, but still show
                // the chrome: the author asked to see the source of the document,
                // not of the body.
                ta.value = joinRegions(this._visualOriginalCode, chrome.header, chrome.footer);
            }
        }
        this.showHtmlBodyVisual = false;
        this._visualOriginalCode = null;
        this._visualEnteredDom = null;
        this.pillMenu = null;
        this._activePill = null;
        // Landing back in Code view — make the side-by-side preview current.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this._refreshCodePreview(), 120);
    }

    get docxHtmlEditorClass() {
        return this.showDocxHtmlPreview
            ? 'dg-html-body-editor dg-docx-html-editor slds-hide'
            : 'dg-html-body-editor dg-docx-html-editor';
    }

    handleFormatHtml(event) {
        const isDocx = event.currentTarget.dataset.target === 'docx';
        const ta = this.template.querySelector(isDocx ? '.dg-docx-html-editor' : '.dg-html-body-editor');
        if (!ta || !ta.value || !ta.value.trim()) {
            this.showToast('Nothing to format', 'The editor is empty.', 'warning');
            return;
        }
        ta.value = prettyPrintHtml(ta.value);
        if (!isDocx) {
            // Formatting changes the text that Apply would stage — surface it.
            this.htmlEditorDirty = true;
            this._refreshCodePreview();
        }
    }

    // Preview exists only on the DOCX converted-HTML viewer — the HTML body
    // editor's Visual mode IS the preview (same render, plus editing).
    handleToggleHtmlPreview() {
        this.showDocxHtmlPreview = !this.showDocxHtmlPreview;
        if (this.showDocxHtmlPreview) {
            this._renderHtmlPreview('.dg-docx-preview', '.dg-docx-html-editor');
        }
    }

    /**
     * Render the textarea's HTML into the inline preview div. LWS blocks
     * iframe srcdoc/document.write, so the markup goes in via innerHTML with
     * its CSS scoped to the preview container (see scopeHtmlForInlinePreview).
     * Merge tags show literally — Download Sample remains the real-data path.
     */
    _renderHtmlPreview(hostSelector, taSelector) {
        const ta = this.template.querySelector(taSelector);
        const scoped = scopeHtmlForInlinePreview((ta && ta.value) || '');
        // The host div mounts on the NEXT render cycle (it's behind an
        // if:true the caller just flipped) — renderedCallback completes the
        // write once the node exists.
        this._pendingPreviewWrite = { selector: hostSelector, html: scoped };
        const host = this.template.querySelector(hostSelector);
        if (host) {
            // Already mounted (e.g. re-render of an open preview) — write now.
            // eslint-disable-next-line @lwc/lwc/no-inner-html
            host.innerHTML = scoped;
            this._pendingPreviewWrite = null;
        }
    }

    async toggleHtmlBodyEditor() {
        if (this.showHtmlBodyEditor) {
            this.showHtmlBodyEditor = false;
            this.showHtmlBodyVisual = false;
            this._visualOriginalCode = null;
            this._visualEnteredDom = null;
            return;
        }
        this.showHtmlBodyEditor = true;
        await this._loadBodyIntoEditor();
        // The page, not the code, is the front door: when a body exists,
        // open straight into visual editing. Code stays one click away.
        const body = this._lastUploadedHtmlText;
        if (body && body.trim()) {
            this._enterVisualMode(body);
        }
    }

    /** Reload = show what's actually staged (or saved), discarding unapplied edits. */
    async handleReloadHtmlBodyEditor() {
        // Reload means "discard my edits" — visual edits included.
        this.showHtmlBodyVisual = false;
        await this._loadBodyIntoEditor();
    }

    /** Fill the editor with the staged body, falling back to the stored one. */
    async _loadBodyIntoEditor() {
        if (this._lastUploadedHtmlText != null) {
            this._syncHtmlBodyEditorDom(this._lastUploadedHtmlText);
            this.htmlEditorDirty = false;
            return;
        }
        // No body touched this session — pull the latest stored body.
        this.isLoadingHtmlBody = true;
        try {
            const body = await getHtmlTemplateBody({ templateId: this.editTemplateId });
            this._lastUploadedHtmlText = body || '';
            this._syncHtmlBodyEditorDom(this._lastUploadedHtmlText);
            this.htmlEditorDirty = false;
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Could not load HTML body', msg, 'error');
            this._syncHtmlBodyEditorDom('');
        } finally {
            this.isLoadingHtmlBody = false;
        }
    }

    /** Native textarea doesn't track LWC state — set the DOM after render. */
    _syncHtmlBodyEditorDom(text) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const ta = this.template.querySelector('.dg-html-body-editor');
            if (ta) {
                ta.value = text || '';
            }
            this._refreshCodePreview();
        }, 120);
    }

    // --- DOCX→HTML transparency viewer (Word templates, PDF output) ---
    get showDocxConvertedHtmlSection() {
        return this.editTemplateType === 'Word' && this.editTemplateOutputFormat === 'PDF';
    }

    get docxHtmlViewerToggleLabel() {
        return this.showDocxHtmlViewer ? 'Hide Converted HTML' : 'View Converted HTML';
    }

    get docxViewerStatusText() {
        const info = this.docxSnapshotInfo;
        if (!info) {
            return 'Loading conversion snapshot…';
        }
        if (info.status === 'NoActiveVersion') {
            return 'No active version yet — upload a Word file and "Save as New Version" first.';
        }
        if (!info.html) {
            const st = info.status || 'Pending';
            return (
                'Conversion snapshot not baked yet (status: ' + st + '). Re-save the version, then reopen this viewer.'
            );
        }
        return (
            'Converted HTML from ' +
            (info.versionName || 'the active version') +
            ' — this is exactly what the PDF engine renders from your Word file.'
        );
    }

    async toggleDocxHtmlViewer() {
        if (this.showDocxHtmlViewer) {
            this.showDocxHtmlViewer = false;
            return;
        }
        this.showDocxHtmlViewer = true;
        this.isLoadingDocxHtml = true;
        this.docxSnapshotInfo = null;
        try {
            const info = await getConvertedHtmlSnapshot({ templateId: this.editTemplateId });
            this.docxSnapshotInfo = info || { html: null, status: 'Unknown' };
            this._syncDocxHtmlViewerDom((info && info.html) || '');
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Could not load converted HTML', msg, 'error');
            this.docxSnapshotInfo = { html: null, status: 'Error' };
            this._syncDocxHtmlViewerDom('');
        } finally {
            this.isLoadingDocxHtml = false;
        }
    }

    _syncDocxHtmlViewerDom(text) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const ta = this.template.querySelector('.dg-docx-html-editor');
            if (ta) {
                ta.value = text || '';
            }
        }, 120);
    }

    /**
     * One-way ramp from Word to HTML: the (possibly fine-tuned) converted
     * HTML becomes the template's real body and Type flips to HTML, so edits
     * stick instead of being clobbered by the next DOCX re-decomposition.
     */
    async handleSwitchToHtmlTemplate() {
        const ta = this.template.querySelector('.dg-docx-html-editor');
        const text = ta ? ta.value : '';
        if (!text || !text.trim()) {
            this.showToast('Nothing to convert', 'The converted-HTML view is empty.', 'warning');
            return;
        }
        const proceed = await LightningConfirm.open({
            message:
                "This makes the HTML shown (including your edits) the template's real body and changes the template Type from Word to HTML. " +
                'The Word file stays in Version History, but future edits happen in the HTML editor. Continue?',
            label: 'Switch to HTML Template',
            theme: 'warning'
        });
        if (!proceed) {
            return;
        }
        this.isSwitchingToHtml = true;
        try {
            const fields = { Id: this.editTemplateId };
            fields[TYPE_FIELD.fieldApiName] = 'HTML';
            fields[OUTPUT_FORMAT_FIELD.fieldApiName] = 'PDF';
            await updateRecord({ fields });
            this.editTemplateType = 'HTML';
            this.editTemplateOutputFormat = 'PDF';
            this.showDocxHtmlViewer = false;
            // Stage the tuned HTML as the body through the standard pipeline.
            // Keep the Word file's identity: Sales_Quote.docx → Sales_Quote.html.
            const htmlName =
                ((this.uploadedFileName || this.editTemplateName || 'template').replace(/\.(docx?|html?|zip)$/i, '') ||
                    'template') + '.html';
            await this._processAndSaveHtmlBody(this.editTemplateId, text, htmlName, null, 'editor');
            this.showHtmlBodyEditor = true;
            this._syncHtmlBodyEditorDom(text);
            await refreshApex(this.wiredTemplatesResult);
            this.showToast(
                'Now an HTML template',
                'Your converted HTML is staged — review it in the editor and click "Save as New Version" to activate.',
                'success'
            );
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Switch failed', msg, 'error');
        } finally {
            this.isSwitchingToHtml = false;
        }
    }

    // --- Designer tab (full-screen editing surface) ---
    get designerHasTemplate() {
        // Canvas counts too — it opens the canvas surface rather than the flow shell.
        // Gating on HTML alone meant clicking a Canvas template in the picker did
        // nothing at all: the tab switched, this getter reported no template, and the
        // picker just re-rendered. A dead click with no error is the worst version.
        return !!this.editTemplateId && (this.editTemplateType === 'HTML' || this.editTemplateType === 'Canvas');
    }

    get isCanvasTemplate() {
        return this.editTemplateType === 'Canvas';
    }

    /** The Designer tab's two surfaces — which editor, not "designer unless…". */
    get showCanvasDesignerTab() {
        return this.designerHasTemplate && this.isCanvasTemplate;
    }

    get showFlowDesignerTab() {
        return this.designerHasTemplate && !this.isCanvasTemplate;
    }

    get designerTitle() {
        return this.editTemplateName || 'Template Designer';
    }

    /** Switch templates without leaving the designer. */
    /**
     * The in-designer switcher. Ordered by what you touched last, so the top of the
     * dropdown is useful in an org with hundreds rather than alphabetical-by-accident.
     *
     * Deliberately NOT capped: capping would make templates unreachable from the
     * switcher, and losing capability is a worse answer to scale than a long
     * dropdown. The searched, bounded picker on the empty state is the route that
     * scales; this is the "switch to something I was just in" shortcut.
     */
    get designerTemplateOptions() {
        return this._designerCandidates().map((t) => ({ label: t.Name, value: t.Id }));
    }

    // --- Right-click context menu handlers ---
    /** Type-to-search inside the right-click menu — the full command catalog. */
    handleCtxSearch(event) {
        const q = (event.target.value || '').toLowerCase().trim();
        if (!q) {
            this.ctxMenu = { ...this.ctxMenu, query: '', items: null };
            return;
        }
        const terms = q.split(/\s+/).filter(Boolean);
        const items = this._slashCatalog()
            .filter((o) => {
                const hay = (o.label + ' ' + o.group + ' ' + (o.keywords || '')).toLowerCase();
                return terms.every((t) => hay.includes(t));
            })
            .slice(0, 9);
        this.ctxMenu = { ...this.ctxMenu, query: q, items };
    }

    handleCtxSearchKeydown(event) {
        event.stopPropagation();
        if (event.key === 'Escape') {
            this.ctxMenu = null;
        } else if (event.key === 'Enter' && this.ctxMenu && this.ctxMenu.items && this.ctxMenu.items.length) {
            this._runCtxItem(this.ctxMenu.items[0]);
        }
    }

    handleCtxSearchedItemClick(event) {
        const key = event.currentTarget.dataset.key;
        const item = this.ctxMenu && this.ctxMenu.items ? this.ctxMenu.items.find((o) => o.key === key) : null;
        this._runCtxItem(item);
    }

    _runCtxItem(item) {
        this.ctxMenu = null;
        if (!item) {
            return;
        }
        // Restore the caret captured at right-click (the search box stole focus).
        try {
            const pv = this._getVisualPv();
            if (pv && this._ctxRange) {
                pv.focus();
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(this._ctxRange);
            }
        } catch (e) {
            /* best effort — insert falls back to append */
        }
        if (item.cmd) {
            if (item.cmd === 'ul' || item.cmd === 'ol') {
                this._toggleListAtCaret(item.cmd === 'ol');
            } else if (item.cmd === 'table') {
                this.handleInsertTable();
            } else {
                try {
                    document.execCommand('styleWithCSS', false, false);
                } catch (e) {
                    /* best effort */
                }
                document.execCommand(item.cmd, false, null);
            }
            this.htmlEditorDirty = true;
            return;
        }
        this._insertIntoVisualPage(item.snippet);
    }

    handleCtxClose() {
        this.ctxMenu = null;
    }
    handleCtxFormat(event) {
        this.ctxMenu = null;
        this.handleFormatAction(event);
    }
    handleCtxTable(event) {
        this.ctxMenu = null;
        this.handleTableAction(event);
    }
    handleCtxList(event) {
        const ordered = event.currentTarget.dataset.kind === 'ol';
        this.ctxMenu = null;
        this._toggleListAtCaret(ordered);
    }
    handleCtxInsert() {
        const pt = this._ctxPoint;
        this.ctxMenu = null;
        if (pt) {
            this._openSlashMenuAtPoint(pt.x, pt.y);
        }
    }
    handleCtxDeleteBlock() {
        this.ctxMenu = null;
        const blk = this._selectedBlockElement();
        if (blk) {
            blk.remove();
            this.htmlEditorDirty = true;
        }
    }

    /** Open the insert menu at an arbitrary point (right-click path — no typed
     *  trigger, so executing an item skips trigger-text removal). */
    _openSlashMenuAtPoint(x, y) {
        this._slashQuery = '';
        this._slashCtx = null;
        this._slashSel = 0;
        const col = this.template.querySelector('.dg-designer-canvas-col');
        const colRect = col ? col.getBoundingClientRect() : { left: 0, top: 0 };
        this._renderSlashMenu({ left: x, bottom: y, width: 1, height: 1 }, colRect);
    }

    /** Versions panel: load any version's body into the editor (staged only
     *  when the author saves — loading changes nothing by itself). */
    async handleLoadVersionIntoDesigner(event) {
        const cvId = event.currentTarget.dataset.cvid;
        const verName = event.currentTarget.dataset.ver;
        if (!cvId) {
            return;
        }
        try {
            const b64 = await getContentVersionBase64({ contentVersionId: cvId });
            const bin = atob(b64);
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) {
                bytes[i] = bin.charCodeAt(i);
            }
            const text = new TextDecoder('utf-8').decode(bytes);
            if (!/</.test(text.slice(0, 500))) {
                this.showToast(
                    'Not an HTML body',
                    verName +
                        ' points at a non-HTML file (e.g. the original .docx) — download it from Edit Template instead.',
                    'warning'
                );
                return;
            }
            this.activePanel = null;
            if (this.showHtmlBodyVisual) {
                this._exitVisualMode();
            }
            this._syncHtmlBodyEditorDom(text);
            this._lastUploadedHtmlText = text;
            this.htmlEditorDirty = true;
            this._enterVisualMode(text);
            this.showToast(
                'Loaded ' + verName,
                'This version is now in the editor. Nothing changed yet — Save as New Version creates a NEW version from it.',
                'success'
            );
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Could not load version', msg, 'error');
        }
    }

    // --- Query panel: check a field, it's in the query. ---
    /** V1 flat-string configs only — JSON (V3/V4) configs stay in the modal. */
    get designerQueryEditable() {
        const q = (this.editTemplateQuery || '').trim();
        return !q.startsWith('{') && this.editTemplateObject && this.editTemplateObject !== 'FlowJsonData';
    }

    async _loadDesignerQueryMeta() {
        if (!this.designerQueryEditable || this._queryMetaFor === this.editTemplateObject) {
            return;
        }
        try {
            const [fields, rels, parentRels] = await Promise.all([
                getObjectFields({ objectName: this.editTemplateObject }),
                getChildRelationships({ objectName: this.editTemplateObject }),
                getParentRelationships({ objectName: this.editTemplateObject })
            ]);
            const childFieldsByRel = {};
            const shape = extractQueryShape(this.editTemplateQuery, this.editTemplateObject);
            const { parentFieldsByRel, parentRelsByPath } = await this._prefetchParentMeta(shape, parentRels);
            await Promise.all(
                (shape.children || []).map(async (c) => {
                    const rel = (rels || []).find((r) => r.value === c.relationshipName);
                    if (rel) {
                        try {
                            childFieldsByRel[c.relationshipName] = await getObjectFields({
                                objectName: rel.childObjectApiName
                            });
                        } catch (e) {
                            /* skip */
                        }
                    }
                })
            );
            this._queryMetaFor = this.editTemplateObject;
            this.designerQueryMeta = {
                fields: fields || [],
                rels: rels || [],
                parentRels: parentRels || [],
                childFieldsByRel,
                parentFieldsByRel,
                parentRelsByPath
            };
        } catch (e) {
            this.designerQueryMeta = null;
        }
    }

    /** Shared: checkbox sections from a describe meta + a V1 query string. */
    /** Every relationship path the query's dot-path fields traverse, at every
     *  depth, shallow-first: Account.Owner.Name -> ['Account','Account.Owner']. */
    _parentRelsInQuery(shape) {
        const rels = new Set();
        for (const pf of shape.parentFields || []) {
            const segs = pf.split('.');
            for (let i = 1; i < segs.length; i++) {
                rels.add(segs.slice(0, i).join('.'));
            }
        }
        return [...rels].sort((a, b) => a.split('.').length - b.split('.').length);
    }

    /** Field lists + onward lookups for every parent path in the query —
     *  resolved hop by hop so any depth reloads correctly. */
    async _prefetchParentMeta(shape, baseParentRels) {
        const parentFieldsByRel = {};
        const parentRelsByPath = {};
        for (const path of this._parentRelsInQuery(shape)) {
            const segs = path.split('.');
            const upPath = segs.slice(0, -1).join('.');
            const relsList = segs.length === 1 ? baseParentRels || [] : parentRelsByPath[upPath] || [];
            const r = relsList.find((x) => x.value === segs[segs.length - 1]);
            if (!r) {
                continue;
            }
            try {
                const [flds, prels] = await Promise.all([
                    getObjectFields({ objectName: r.targetObject }),
                    getParentRelationships({ objectName: r.targetObject })
                ]);
                parentFieldsByRel[path] = flds || [];
                parentRelsByPath[path] = prels || [];
            } catch (e) {
                /* skip */
            }
        }
        return { parentFieldsByRel, parentRelsByPath };
    }

    _buildQuerySections(query, objectName, meta, search) {
        if (!meta) {
            return [];
        }
        const q = (search || '').toLowerCase().trim();
        const shape = extractQueryShape(query, objectName);
        const baseSet = new Set((shape.baseFields || []).map((f) => f.toLowerCase()));
        const SKIP = /^(Id|IsDeleted|SystemModstamp|CurrencyIsoCode|Jigsaw.*|CleanStatus|PhotoUrl)$/;
        const match = (label, api) => !q || (label + ' ' + api).toLowerCase().includes(q);
        const sections = [];
        sections.push({
            key: 'base',
            label: objectName + ' fields',
            rows: meta.fields
                .filter((f) => !SKIP.test(f.value) && match(f.label, f.value))
                .map((f) => ({
                    key: 'b_' + f.value,
                    label: f.label,
                    api: f.value,
                    checked: baseSet.has(f.value.toLowerCase()),
                    kind: 'base',
                    rel: '',
                    target: ''
                }))
        });
        // Parent records already traversed by the query (Account.Name, ...):
        // one section per lookup, checkboxes emit dot-paths.
        const parentFieldSet = new Set((shape.parentFields || []).map((f) => f.toLowerCase()));
        const parentFieldsByRel = meta.parentFieldsByRel || {};
        const parentRelsByPath = meta.parentRelsByPath || {};
        const pathsInQuery = new Set(this._parentRelsInQuery(shape));
        for (const prel of this._parentRelsInQuery(shape)) {
            const pf = parentFieldsByRel[prel] || [];
            const rows = pf
                .filter((f) => !SKIP.test(f.value) && match(f.label, prel + '.' + f.value))
                .map((f) => ({
                    key: 'p_' + prel + '_' + f.value,
                    label: f.label,
                    api: f.value,
                    checked: parentFieldSet.has((prel + '.' + f.value).toLowerCase()),
                    kind: 'parent',
                    rel: prel,
                    target: ''
                }));
            // Keep going up: this parent's own lookups (tree-builder style),
            // until SOQL's 5-hop relationship ceiling.
            if (prel.split('.').length < 5) {
                for (const r of parentRelsByPath[prel] || []) {
                    const nested = prel + '.' + r.value;
                    if (pathsInQuery.has(nested) || !match(r.label, nested)) {
                        continue;
                    }
                    rows.push({
                        key: 'pr_' + nested,
                        label: '\u2191 ' + r.label + ' (' + nested + '.\u2026)',
                        api: r.value,
                        checked: false,
                        kind: 'prel',
                        rel: nested,
                        target: r.targetObject
                    });
                }
            }
            sections.push({ key: 'prel_' + prel, label: prel + ' (parent record)', rows });
        }
        for (const c of shape.children || []) {
            const cf = meta.childFieldsByRel[c.relationshipName] || [];
            const inSet = new Set((c.fields || []).map((f) => f.toLowerCase()));
            sections.push({
                key: 'rel_' + c.relationshipName,
                label: c.relationshipName + ' (child list)',
                rows: cf
                    .filter((f) => !SKIP.test(f.value) && match(f.label, f.value))
                    .map((f) => ({
                        key: 'c_' + c.relationshipName + '_' + f.value,
                        label: f.label,
                        api: f.value,
                        checked: inSet.has(f.value.toLowerCase()),
                        kind: 'child',
                        rel: c.relationshipName,
                        target: ''
                    }))
            });
        }
        const inQuery = new Set((shape.children || []).map((c) => c.relationshipName));
        const NOISE =
            /Histories|Feeds|Shares|Teams|ContentDocumentLinks|ProcessInstances|ActivityHistories|Emails|Events|Tasks|Notes|Attachments|DuplicateRecord|RecordAction|TopicAssign|Vote/i;
        const addable = meta.rels.filter(
            (r) => !inQuery.has(r.value) && !NOISE.test(r.value) && match(r.label, r.value)
        );
        const parentsInQuery = new Set(this._parentRelsInQuery(shape));
        const addableParents = (meta.parentRels || []).filter(
            (r) => !parentsInQuery.has(r.value) && match(r.label, r.value)
        );
        if (addableParents.length) {
            sections.push({
                key: 'addparent',
                label: 'Add parent fields (lookups)',
                rows: addableParents.map((r) => ({
                    key: 'pr_' + r.value,
                    label: r.label + ' (' + r.value + '.\u2026)',
                    api: r.value,
                    checked: false,
                    kind: 'prel',
                    rel: r.value,
                    target: r.targetObject
                }))
            });
        }
        if (addable.length) {
            sections.push({
                key: 'addrel',
                label: 'Add a child list',
                rows: addable.map((r) => ({
                    key: 'r_' + r.value,
                    label: r.label + ' (' + r.value + ')',
                    api: r.value,
                    checked: false,
                    kind: 'rel',
                    rel: r.value,
                    target: ''
                }))
            });
        }
        return sections.filter((sec) => sec.rows.length);
    }

    /** Shared: apply a checkbox toggle to a V1 query string. Returns
     *  { query, childFields } — childFields set when a new rel was seeded. */
    async _applyQueryToggle(query, objectName, meta, dataset, on) {
        const { kind, api, rel, target } = dataset;
        const shape = extractQueryShape(query, objectName);
        const base = [...(shape.baseFields || [])];
        const parents = [...(shape.parentFields || [])];
        let children = (shape.children || []).map((c) => ({ rel: c.relationshipName, fields: [...c.fields] }));
        let childFields = null;
        let parentFields = null;
        let parentRelsForPath = null;
        if (kind === 'base') {
            const idx = base.findIndex((f) => f.toLowerCase() === api.toLowerCase());
            if (on && idx === -1) {
                base.push(api);
            } else if (!on && idx > -1) {
                base.splice(idx, 1);
            }
        } else if (kind === 'child') {
            const c = children.find((x) => x.rel === rel);
            if (c) {
                const idx = c.fields.findIndex((f) => f.toLowerCase() === api.toLowerCase());
                if (on && idx === -1) {
                    c.fields.push(api);
                } else if (!on && idx > -1) {
                    c.fields.splice(idx, 1);
                }
                if (!c.fields.length) {
                    children = children.filter((x) => x !== c);
                }
            }
        } else if (kind === 'parent') {
            const path = rel + '.' + api;
            const idx = parents.findIndex((f) => f.toLowerCase() === path.toLowerCase());
            if (on && idx === -1) {
                parents.push(path);
            } else if (!on && idx > -1) {
                parents.splice(idx, 1);
            }
        } else if (kind === 'prel' && on) {
            if (target) {
                try {
                    const [flds, prels] = await Promise.all([
                        getObjectFields({ objectName: target }),
                        getParentRelationships({ objectName: target })
                    ]);
                    parentFields = flds || [];
                    parentRelsForPath = prels || [];
                } catch (e) {
                    parentFields = [];
                }
            }
            if (!parents.some((f) => f.toLowerCase() === (rel + '.name').toLowerCase())) {
                const names = (parentFields || []).map((f) => f.value);
                const seed = names.includes('Name') ? 'Name' : names[0] || 'Name';
                parents.push(rel + '.' + seed);
            }
        } else if (kind === 'rel' && on) {
            let seed = ['Name'];
            try {
                const relMeta = (meta.rels || []).find((r) => r.value === rel);
                if (relMeta) {
                    childFields = (await getObjectFields({ objectName: relMeta.childObjectApiName })) || [];
                    const names = childFields.map((f) => f.value);
                    seed = ['Name', 'FirstName', 'LastName', 'Email', 'Amount', 'StageName', 'Quantity', 'UnitPrice']
                        .filter((f) => names.includes(f))
                        .slice(0, 4);
                    if (!seed.length) {
                        seed = [names.find((n) => n === 'Name') || names[0]].filter(Boolean);
                    }
                }
            } catch (e) {
                /* keep Name seed */
            }
            children.push({ rel, fields: seed });
        }
        if (!base.length) {
            base.push('Name');
        }
        const parts = [[...base, ...parents].join(', ')];
        for (const c of children) {
            parts.push('(SELECT ' + c.fields.join(', ') + ' FROM ' + c.rel + ')');
        }
        return { query: parts.join(', '), childFields, parentFields, parentRelsForPath, rel };
    }

    /** Sections of checkbox rows driven by describe + the CURRENT query. */
    get designerQuerySections() {
        if (!this.designerQueryEditable) {
            return [];
        }
        return this._buildQuerySections(
            this.editTemplateQuery,
            this.editTemplateObject,
            this.designerQueryMeta,
            this.panelSearch
        );
    }

    /** One click = query updated. Rebuilds the V1 string from the shape. */
    async handleQueryFieldToggle(event) {
        const res = await this._applyQueryToggle(
            this.editTemplateQuery,
            this.editTemplateObject,
            this.designerQueryMeta,
            event.currentTarget.dataset,
            event.currentTarget.checked
        );
        if (res.childFields) {
            this.designerQueryMeta = {
                ...this.designerQueryMeta,
                childFieldsByRel: { ...this.designerQueryMeta.childFieldsByRel, [res.rel]: res.childFields }
            };
        }
        if (res.parentFields) {
            this.designerQueryMeta = {
                ...this.designerQueryMeta,
                parentFieldsByRel: { ...(this.designerQueryMeta.parentFieldsByRel || {}), [res.rel]: res.parentFields },
                parentRelsByPath: {
                    ...(this.designerQueryMeta.parentRelsByPath || {}),
                    [res.rel]: res.parentRelsForPath || []
                }
            };
        }
        this.editTemplateQuery = res.query;
    }

    get designerQueryFieldCount() {
        const shape = extractQueryShape(this.editTemplateQuery, this.editTemplateObject);
        let n = (shape.baseFields || []).length + (shape.parentFields || []).length;
        for (const c of shape.children || []) {
            n += (c.fields || []).length;
        }
        return n;
    }

    // --- Header / Footer panel (repeats on every PDF page) ---
    handleDesignerHeaderChange(event) {
        this.editTemplateHeaderHtml = event.target.value;
        this.htmlEditorDirty = true;
    }
    handleDesignerFooterChange(event) {
        this.editTemplateFooterHtml = event.target.value;
        this.htmlEditorDirty = true;
    }
    handleHfFocus(event) {
        this._lastHfFocus = event.target.dataset.hf;
    }
    handleHfTokenInsert(event) {
        // Token keys, not literal tags — LWC decodes entities in attributes
        // BEFORE expression parsing, so brace literals can't live in markup.
        const TOKS = {
            pagexy: 'Page {PageNumber} of {TotalPages}',
            pagenum: '{PageNumber}',
            pagetotal: '{TotalPages}',
            today: '{Today:MMMM d, yyyy}',
            name: '{Name}'
        };
        const tok = TOKS[event.currentTarget.dataset.tok];
        if (!tok) {
            return;
        }
        // On the sheet, a page counter goes in at the caret like anything else —
        // same path as a merge-tag chip, so it pillifies, undoes and formats
        // identically. _insertIntoVisualPage resolves the target from the caret, so
        // it lands in whichever band the author is actually in.
        if (this.showHtmlBodyVisual) {
            this._restoreCaret();
            this._insertIntoVisualPage(tok);
            return;
        }
        // Source mode has no bands — fall back to the raw field.
        const which = this._lastHfFocus === 'header' ? 'header' : 'footer';
        const ta = this.template.querySelector(which === 'header' ? '.dg-hf-header' : '.dg-hf-footer');
        if (!ta) {
            return;
        }
        const st = typeof ta.selectionStart === 'number' ? ta.selectionStart : ta.value.length;
        const en = typeof ta.selectionEnd === 'number' ? ta.selectionEnd : st;
        ta.value = ta.value.slice(0, st) + tok + ta.value.slice(en);
        if (which === 'header') {
            this.editTemplateHeaderHtml = ta.value;
        } else {
            this.editTemplateFooterHtml = ta.value;
        }
        this.htmlEditorDirty = true;
    }

    /**
     * Put the caret in a running band and scroll it into view.
     *
     * The Header/Footer panel is a way to GET to the bands, not a second place to
     * edit them — so this is the whole of it. Closes the panel on the way, because
     * leaving a floating panel open over the sheet you were just sent to edit is
     * the kind of small friction that made the header feel like a separate mode.
     */
    handleJumpToBand(event) {
        const which = event.currentTarget.dataset.surface === 'footer' ? 'footer' : 'header';
        this.activePanel = null;
        // eslint-disable-next-line @lwc/lwc/no-async-operation -- wait for the panel to unmount so the scroll lands correctly
        setTimeout(() => {
            const band = this.template.querySelector('.dg-chrome-band_' + which);
            if (!band) {
                return;
            }
            try {
                band.scrollIntoView({ block: 'center', behavior: 'smooth' });
                band.focus();
                const first = band.querySelector('p, div, span') || band;
                const r = document.createRange();
                r.selectNodeContents(first);
                r.collapse(false);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(r);
                this._setActiveSurface(which);
            } catch (e) {
                /* focus is best-effort */
            }
        }, 80);
    }

    async handleDesignerTemplateSwitch(event) {
        const id = event.detail.value;
        if (!id || id === this.editTemplateId) {
            return;
        }
        if (this.htmlEditorDirty) {
            const ok = await LightningConfirm.open({
                message: 'Switch templates? Unapplied edits in this editor will be discarded — staged bodies are kept.',
                label: 'Switch template',
                theme: 'warning'
            });
            if (!ok) {
                // Re-render snaps the picker back to the current template.
                this.editTemplateId = this.editTemplateId; // eslint-disable-line no-self-assign
                return;
            }
        }
        const row = (this.templates || []).find((t) => t.Id === id);
        if (!row) {
            return;
        }
        if (this.showHtmlBodyVisual) {
            this._exitVisualMode();
        }
        this.handleClosePdfPreview();
        this.activePanel = null;
        await this.openDesignerForRow(row);
    }

    /** Row action / modal button → full-screen designer for HTML templates. */
    // ===== Designer tab: choosing a template at scale =========================
    //
    // An org with 400 templates is not an edge case, and a flat list of every one
    // is unusable at that size AND expensive — 400 buttons is 400 DOM nodes on a
    // tab you have not started working on yet. The list is therefore SEARCHED,
    // ordered by what you touched last, and capped: you see the handful you
    // probably want, the count tells you what is behind the filter, and the DOM
    // stays the same size whether the org has 5 templates or 5000.
    @track designerPickerQuery = '';
    @track designerPickerLimit = 8;
    /** How many more to reveal per click of "Show more". */
    DESIGNER_PICKER_PAGE = 25;

    get hasDesignerTemplates() {
        return this._designerCandidates().length > 0;
    }

    /** Every template the designer can open, most recently modified first. */
    _designerCandidates() {
        // Canvas templates open too — into the canvas editor rather than the flow
        // designer (see showCanvasDesigner). Filtering to HTML alone made a Canvas
        // template creatable and renderable but impossible to reopen, which is a dead
        // end the author can only escape by rebuilding it.
        const rows = (this.templates || []).filter((t) => t[F.Type] === 'HTML' || t[F.Type] === 'Canvas');
        return rows.sort((a, b) => String(b.LastModifiedDate || '').localeCompare(String(a.LastModifiedDate || '')));
    }

    _designerMatches() {
        const q = (this.designerPickerQuery || '').trim().toLowerCase();
        const rows = this._designerCandidates();
        if (!q) {
            return rows;
        }
        return rows.filter((t) =>
            [t.Name, t[F.Category], t[F.BaseObject], t.displayBaseObject, t[F.ApiName], t[F.Desc]]
                .filter(Boolean)
                .some((v) => String(v).toLowerCase().includes(q))
        );
    }

    get designerOpenList() {
        return this._designerMatches()
            .slice(0, this.designerPickerLimit)
            .map((t) => ({
                value: t.Id,
                label: t.Name,
                // One quiet line of context, so two templates called "Invoice" are
                // still tellable apart without opening them.
                meta: [t[F.Category], t.displayBaseObject].filter(Boolean).join(' · ')
            }));
    }

    get designerPickerSummary() {
        const total = this._designerCandidates().length;
        const matched = this._designerMatches().length;
        const shown = Math.min(matched, this.designerPickerLimit);
        if (matched === 0) {
            return 'No templates match “' + this.designerPickerQuery + '”';
        }
        if (matched === total && matched <= shown) {
            return total === 1 ? '1 template' : total + ' templates';
        }
        return (
            'Showing ' + shown + ' of ' + matched + (matched === total ? '' : ' matching') + ' · ' + total + ' total'
        );
    }

    get designerPickerHasMore() {
        return this._designerMatches().length > this.designerPickerLimit;
    }

    handleDesignerPickerSearch(event) {
        this.designerPickerQuery = event.target.value || '';
        // A new search starts from the top again, or "show more" state from the
        // previous query silently widens this one.
        this.designerPickerLimit = 8;
    }

    /** Enter opens the best match — the fastest path when you know the name. */
    handleDesignerPickerKeydown(event) {
        if (event.key !== 'Enter') {
            return;
        }
        event.preventDefault();
        const first = this._designerMatches()[0];
        if (first) {
            this.openDesignerForRow(first);
        }
    }

    handleDesignerPickerMore() {
        this.designerPickerLimit += this.DESIGNER_PICKER_PAGE;
    }

    /**
     * Open a template straight from the Designer tab's empty state.
     *
     * Same path as the "Design" row action, so there is one way a template gets
     * opened and no second code path to keep in step.
     */
    async handleOpenTemplateInDesigner(event) {
        const id = event.currentTarget.dataset.id;
        const row = (this.templates || []).find((t) => t.Id === id);
        if (!row) {
            this.showToast('Template not found', 'It may have been deleted — refresh and try again.', 'warning');
            return;
        }
        await this.openDesignerForRow(row);
    }

    async openDesignerForRow(row) {
        // AWAITED: openEditModal fetches the template's full record now, and
        // _openDesignerSurface reads the fields it populates. Without the await the
        // designer mounted against an empty template and simply did not open.
        await this.openEditModal(row, 'document');
        this.isEditModalOpen = false;
        await this._openDesignerSurface();
    }

    async handleOpenDesignerFromModal() {
        this.isEditModalOpen = false;
        await this._openDesignerSurface();
    }

    async _openDesignerSurface() {
        this.activeMainTab = 'design';
        if (this.isCanvasTemplate) {
            // The canvas owns its own load and serialize cycle, so NONE of the flow
            // designer's setup applies. Bailing out before it rather than after also
            // skips _loadBodyIntoEditor, which staged the canvas body into the HTML
            // textarea — a second, divergent copy of a document the canvas is about to
            // load itself, and the exact shape of the two-bodies bug this editor exists
            // to avoid.
            this._loadWizardAssets();
            return;
        }
        this.showHtmlBodyEditor = true;
        this.showBlockPanel = true;
        this.showTagPanel = true;
        this.showImagePanel = true;
        await this._loadBodyIntoEditor();
        // Asset library feeds the Images panel + slash menu + tag pills.
        this._loadWizardAssets();
        // Not awaited — the toolbar button appears when the answer arrives, and
        // an org without Einstein just never shows it.
        this._refreshAgentforceAvailability();
        let body = this._lastUploadedHtmlText;
        if (!body || !body.trim()) {
            // Blank template: seed a clean sheet so click-and-type just works.
            body =
                '<!DOCTYPE html>\n<html>\n<head>\n<meta charset="utf-8" />\n<style>\n@page { size: Letter portrait; margin: 0.75in; }\nbody { font-family: Helvetica, Arial, sans-serif; font-size: 10.5pt; color: #1a1a1a; }\n</style>\n</head>\n<body>\n<p>Start typing your document here — or drag in blocks, tags, and images from the rail.</p>\n</body>\n</html>\n';
            this._syncHtmlBodyEditorDom(body);
        }
        this._enterVisualMode(body);
    }

    /**
     * The canvas saved a new Query Config. Mirror it locally so the field picker
     * reflects it immediately — without this the author saves a query and the chips
     * keep offering the old fields until the whole tab is reloaded.
     */
    handleCanvasQueryUpdated(event) {
        this.editTemplateQuery = (event.detail && event.detail.query) || this.editTemplateQuery;
    }

    /** Designer → this template's full edit modal, no list-hunting. */
    handleEditTemplateFromDesigner() {
        if (this.showHtmlBodyVisual) {
            this._exitVisualMode();
        }
        this.handleClosePdfPreview();
        this.activePanel = null;
        this._closeSlashMenu();
        this.activeMainTab = 'list';
        this.activeEditTab = 'document';
        this.isEditModalOpen = true;
    }

    /**
     * Canvas "Templates" button. Routes through the SAME exit as the flow designer so
     * there is one definition of what leaving the designer means — a second path would
     * drift, and the one that skipped a cleanup step would be the one nobody noticed.
     * The canvas has already confirmed any unsaved changes before dispatching.
     */
    /**
     * Canvas "Templates" — back to the DESIGNER's own picker, not out to the list.
     *
     * Leaving the designer entirely was the wrong destination: the button sits in the
     * designer's toolbar next to a template name, so it reads as "show me the other
     * templates", and closing the whole surface to reach the record list made picking
     * a second template a four-click round trip. Clearing the selection is enough —
     * designerHasTemplate goes false and the tab renders its picker.
     */
    handleCanvasBack() {
        if (this.showHtmlBodyVisual) {
            this._exitVisualMode();
        }
        this.handleClosePdfPreview();
        this.activePanel = null;
        this.editTemplateId = null;
        this.editTemplateType = null;
        this.activeMainTab = 'design';
    }

    handleCloseDesigner() {
        if (this.showHtmlBodyVisual) {
            this._exitVisualMode();
        }
        this.handleClosePdfPreview();
        this.activePanel = null;
        if (this.htmlEditorDirty || this.stagedBodySource) {
            this.showToast(
                'Heads up',
                this.stagedBodySource
                    ? 'Your staged body is kept — reopen the designer or the template editor to Save as New Version.'
                    : 'Unapplied editor changes were left un-staged.',
                'info'
            );
        }
        this.activeMainTab = 'list';
    }

    // --- Blocks palette (drag-in layout pieces) ---
    get blockPaletteSections() {
        const shape = extractQueryShape(this.editTemplateQuery, this.editTemplateObject);
        const sections = buildBlockPalette(shape);
        return [
            {
                key: 'sections',
                label: 'Sections',
                hint: 'Flexipage-style equal columns — up to 12, like a page layout.',
                items: SECTION_COLUMN_PRESETS.map((n) => ({
                    key: 'seccols' + n,
                    label: n + ' columns',
                    title: n + ' equal-width columns section',
                    snippet: columnsSectionSnippet(n)
                }))
            },
            ...sections
        ];
    }

    // --- Floating searchable panels (replace the fixed right rail) ---
    get showFloatPanel() {
        return !!this.activePanel;
    }
    get isPanelInsert() {
        return this.activePanel === 'insert';
    }
    get isPanelTags() {
        return this.activePanel === 'tags';
    }
    get isPanelImages() {
        return this.activePanel === 'images';
    }
    get isPanelWatermark() {
        return this.activePanel === 'watermark';
    }
    get isPanelHf() {
        return this.activePanel === 'hf';
    }
    get isPanelVersions() {
        return this.activePanel === 'versions';
    }
    get isPanelQuery() {
        return this.activePanel === 'query';
    }
    get showPanelSearch() {
        // The query panel's tree builder brings its own search box.
        return !this.isPanelWatermark && !this.isPanelHf && !this.isPanelVersions && !this.isPanelQuery;
    }

    /** The query panel hosts the full visual builder — give it real width. */
    get floatPanelClass() {
        return this.isPanelQuery ? 'dg-float-panel dg-float-panel_wide' : 'dg-float-panel';
    }

    /** The visual builder works for SOQL-backed templates (V1 string or V3
     *  tree). Apex-provider (V4) and Flow-JSON templates manage data in the
     *  Edit modal instead. */
    get designerQueryTreeAvailable() {
        if (!this.editTemplateObject || this.editTemplateObject === 'FlowJsonData') {
            return false;
        }
        const q = (this.editTemplateQuery || '').trim();
        if (q.startsWith('{')) {
            try {
                const cfg = JSON.parse(q);
                return cfg && cfg.v === 3;
            } catch (e) {
                return false;
            }
        }
        return true;
    }
    get floatPanelTitle() {
        return {
            insert: 'Insert blocks',
            tags: 'Merge tags',
            images: 'Image assets',
            watermark: 'Watermark',
            hf: 'Header & Footer',
            versions: 'Version history',
            query: 'Query fields'
        }[this.activePanel];
    }
    get panelSearchPlaceholder() {
        return this.activePanel === 'tags' ? 'Search fields, loops, charts…' : 'Search…';
    }

    handlePanelToggle(event) {
        const p = event.currentTarget.dataset.panel;
        this.activePanel = this.activePanel === p ? null : p;
        this.panelSearch = '';
        this._focusPanelSearch = !!this.activePanel;
        if (this.activePanel === 'images') {
            this._loadWizardAssets();
        }
        if (this.activePanel === 'versions' && this.editTemplateId) {
            this.loadVersions(this.editTemplateId);
        }
        if (this.activePanel === 'query') {
            this._loadDesignerQueryMeta();
        }
        if (this.activePanel) {
            this._enableFloatPanelChrome();
        } else {
            this._disableFloatPanelChrome();
        }
    }
    handlePanelClose() {
        this.activePanel = null;
        this._disableFloatPanelChrome();
    }

    /**
     * The floating menu panel (Insert / Tags / Images / Query / Versions /
     * Header-Footer / Watermark) is position:fixed. A static top offset slides
     * under the Salesforce tab bar in taller chrome (console / NPSP navigation),
     * hiding the panel header and its close button. While a panel is open we (a)
     * pin its top just below the ACTUAL designer chrome — measured live so it
     * adapts to any org's chrome height — and (b) let Escape close it. The header
     * is also made sticky in CSS so the close X stays reachable without scrolling.
     */
    _enableFloatPanelChrome() {
        this._positionFloatPanel();
        if (this._panelChromeBound) {
            return;
        }
        if (!this._onPanelKeydown) {
            this._onPanelKeydown = (e) => {
                if (e.key === 'Escape') {
                    e.preventDefault();
                    this.handlePanelClose();
                }
            };
        }
        if (!this._onPanelReflow) {
            this._onPanelReflow = () => this._positionFloatPanel();
        }
        document.addEventListener('keydown', this._onPanelKeydown, true);
        window.addEventListener('resize', this._onPanelReflow);
        document.addEventListener('scroll', this._onPanelReflow, true);
        this._panelChromeBound = true;
    }

    _disableFloatPanelChrome() {
        if (!this._panelChromeBound) {
            return;
        }
        document.removeEventListener('keydown', this._onPanelKeydown, true);
        window.removeEventListener('resize', this._onPanelReflow);
        document.removeEventListener('scroll', this._onPanelReflow, true);
        this._panelChromeBound = false;
    }

    _positionFloatPanel() {
        if (this._reflowQueued) {
            return;
        }
        this._reflowQueued = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            this._reflowQueued = false;
            const panel = this.template.querySelector('.dg-float-panel');
            const chrome = this.template.querySelector('.dg-designer-chrome');
            if (!panel || !chrome) {
                return;
            }
            const bottom = chrome.getBoundingClientRect().bottom;
            // Keep a sane floor so a mis-measured/absent chrome never parks the
            // panel off-screen; +8px leaves a small gap under the chrome.
            panel.style.top = Math.max(56, Math.round(bottom) + 8) + 'px';
        });
    }
    handlePanelSearch(event) {
        this.panelSearch = event.target.value || '';
    }

    _filterSections(sections) {
        const q = (this.panelSearch || '').toLowerCase().trim();
        if (!q) {
            return sections;
        }
        return sections
            .map((s) => ({
                ...s,
                items: s.items.filter((it) =>
                    (it.label + ' ' + (it.title || '') + ' ' + s.label).toLowerCase().includes(q)
                )
            }))
            .filter((s) => s.items.length);
    }
    get filteredBlockSections() {
        return this._filterSections(this.blockPaletteSections);
    }
    get filteredTagSections() {
        return this._filterSections(this.tagPaletteSections);
    }
    get filteredTemplateImages() {
        const q = (this.panelSearch || '').toLowerCase().trim();
        const imgs = this.templateImages || [];
        return q ? imgs.filter((i) => (i.fileName || '').toLowerCase().includes(q)) : imgs;
    }
    get hasFilteredTemplateImages() {
        return this.filteredTemplateImages.length > 0;
    }
    /** Asset library entries for the designer panel — searchable by name/key. */
    get filteredAssets() {
        const q = (this.panelSearch || '').toLowerCase().trim();
        const assets = this.wizardAssets || [];
        return q
            ? assets.filter((a) => (a.name + ' ' + a.assetKey + ' ' + a.mergeTag).toLowerCase().includes(q))
            : assets;
    }
    get hasFilteredAssets() {
        return this.filteredAssets.length > 0;
    }

    // --- Notion-style slash-command menu ---
    /** EVERY command, flattened and searchable by plain-language intent —
     *  "close tag", "start loop", "money", "bold" all find their thing. */
    _slashCatalog() {
        const out = [];
        let i = 0;
        const add = (label, group, item) => out.push({ key: 's' + i++, label, group, ...item });
        // Plain-language loop + conditional entries, built from the real query.
        const shape = extractQueryShape(this.editTemplateQuery, this.editTemplateObject);
        for (const c of shape.children || []) {
            add(`Start loop — repeat for each ${c.relationshipName}`, 'Loops', {
                snippet: '{#' + c.relationshipName + '}',
                keywords: 'start open begin loop repeat each every child rows for'
            });
            add(`Close loop — end of ${c.relationshipName}`, 'Loops', {
                snippet: '{/' + c.relationshipName + '}',
                keywords: 'close end stop finish loop tag slash'
            });
        }
        add('Show only when… (start of if)', 'Conditionals', {
            snippet: '{#FieldName}',
            keywords: 'if condition conditional when show only start open hide'
        });
        add('Otherwise… (else)', 'Conditionals', {
            snippet: '{:else}',
            keywords: 'else otherwise fallback condition'
        });
        add('End of condition (close the if)', 'Conditionals', {
            snippet: '{/FieldName}',
            keywords: 'close end if condition tag finish stop'
        });
        // Editor commands — the format bar, searchable from the keyboard.
        const CMDS = [
            ['Bold text', 'bold', 'bold strong heavy thick'],
            ['Italic text', 'italic', 'italic slant emphasis'],
            ['Underline text', 'underline', 'underline'],
            ['Strikethrough text', 'strikeThrough', 'strike strikethrough cross out'],
            ['Bulleted list', 'ul', 'bullet bulleted list dots points unordered'],
            ['Numbered list', 'ol', 'number numbered list ordered steps 123'],
            ['Align left', 'justifyLeft', 'align left'],
            ['Align center', 'justifyCenter', 'align center middle'],
            ['Align right', 'justifyRight', 'align right'],
            ['Clear formatting', 'removeFormat', 'clear remove formatting plain reset'],
            ['Insert table (3 columns)', 'table', 'table grid columns rows insert']
        ];
        for (const [label, cmd, keywords] of CMDS) {
            add(label, 'Formatting', { cmd, keywords });
        }
        for (const sec of this.blockPaletteSections) {
            for (const it of sec.items) {
                add(it.label, sec.label, { snippet: it.snippet, keywords: it.title || '' });
            }
        }
        for (const sec of this.tagPaletteSections) {
            for (const it of sec.items) {
                add(it.label, sec.label, { snippet: it.snippet, keywords: (it.title || '') + ' merge tag field' });
            }
        }
        for (const a of this.wizardAssets || []) {
            add(a.name, 'Image assets', { snippet: a.mergeTag, keywords: 'image picture logo asset photo' });
        }
        return out;
    }

    _maybeOpenSlashMenu() {
        try {
            const sel = window.getSelection();
            if (!sel || !sel.rangeCount || !sel.isCollapsed) {
                this._closeSlashMenu();
                return;
            }
            const node = sel.anchorNode;
            if (!node || node.nodeType !== 3) {
                this._closeSlashMenu();
                return;
            }
            // pv.contains() is the LWS-unreliable call documented in #240; a false
            // negative here meant the ` / [ insert menu simply never opened. It also
            // could not see the running header/footer bands at all.
            const pv = this._surfaceContaining(node);
            if (!pv || (node.parentElement && node.parentElement.closest('[data-dg-tag]'))) {
                this._closeSlashMenu();
                return;
            }
            const upto = node.nodeValue.slice(0, sel.anchorOffset);
            // Trigger keys: ` or [ — "/" belongs to Lightning global search.
            const m = upto.match(/(^|[\s ])[`[]([\w -]{0,30})$/);
            if (!m) {
                this._closeSlashMenu();
                return;
            }
            const query = m[2] || '';
            if (!this.slashMenu || this._slashQuery !== query) {
                this._slashSel = 0;
            }
            this._slashQuery = query;
            // endOffset is where the caret was when the menu opened. The removal
            // path used to fall back to the END OF THE TEXT NODE whenever the
            // live selection was no longer in that node — which is exactly what
            // happens the moment focus moves into the menu's own search box, so
            // choosing an item would have deleted everything after the trigger
            // character. Recording the offset makes clicking into the menu safe.
            this._slashCtx = { node, slashIndex: upto.length - query.length - 1, endOffset: upto.length };
            const range = sel.getRangeAt(0).cloneRange();
            let rect = range.getBoundingClientRect();
            if (!rect || (!rect.width && !rect.height)) {
                rect = (node.parentElement || pv).getBoundingClientRect();
            }
            const col = this.template.querySelector('.dg-designer-canvas-col');
            const colRect = col ? col.getBoundingClientRect() : { left: 0, top: 0 };
            this._renderSlashMenu(rect, colRect);
        } catch (e) {
            // Surface failures IN the menu — console output from LWS contexts
            // is unreliable, silent closes hide real bugs.
            this.slashMenu = {
                query: '',
                hasItems: false,
                posStyle: 'left: 40px; top: 40px;',
                items: [],
                errorMsg: (e && e.message) || String(e)
            };
        }
    }

    _renderSlashMenu(rect, colRect) {
        const q = (this._slashQuery || '').toLowerCase().trim();
        const all = this._slashCatalog();
        // Every word of the query must match somewhere in label/group/keywords
        // — so "close loop", "start loop", "end if" all find their command.
        const terms = q.split(/\s+/).filter(Boolean);
        const scored = terms.length
            ? all.filter((o) => {
                  const hay = (o.label + ' ' + o.group + ' ' + (o.keywords || '')).toLowerCase();
                  return terms.every((t) => hay.includes(t));
              })
            : all;
        // Was 10. With no search box in the menu and no scrolling, ten was also
        // the number of commands that EXISTED as far as a mouse was concerned:
        // everything after the tenth was unreachable unless you knew to type.
        // The menu scrolls now, so the cap only exists to keep the list sane.
        const items = scored.slice(0, 40);
        if (this._slashSel >= items.length) {
            this._slashSel = Math.max(0, items.length - 1);
        }
        // Sized to the room below the trigger, same as the right-click menu:
        // without this a menu opened low on the page runs off the bottom and
        // its last commands are unreachable however tall the list is allowed
        // to be.
        let posStyle;
        if (rect) {
            const MIN_H = 200;
            const spaceBelow = window.innerHeight - rect.bottom - 16;
            const menuMax = Math.max(MIN_H, Math.min(Math.round(window.innerHeight * 0.62), spaceBelow));
            let top = rect.bottom - colRect.top + 6;
            if (spaceBelow < MIN_H) {
                top = Math.max(0, top - (MIN_H - spaceBelow));
            }
            posStyle =
                'left: ' +
                Math.max(0, rect.left - colRect.left) +
                'px; top: ' +
                top +
                'px; max-height: ' +
                menuMax +
                'px;';
        } else {
            posStyle = this.slashMenu ? this.slashMenu.posStyle : '';
        }
        this.slashMenu = {
            query: this._slashQuery,
            hasItems: items.length > 0,
            posStyle,
            items: items.map((o, idx) => ({
                ...o,
                itemClass: idx === this._slashSel ? 'dg-slash-item dg-slash-item_active' : 'dg-slash-item'
            }))
        };
    }

    _closeSlashMenu() {
        if (this.slashMenu) {
            this.slashMenu = null;
            this._slashCtx = null;
            this._slashSel = 0;
        }
    }

    /** Keyboard driving for the open slash menu; returns true when consumed. */
    _slashMenuKeydown(e) {
        if (!this.slashMenu) {
            return false;
        }
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
            e.preventDefault();
            const n = this.slashMenu.items.length;
            if (n) {
                this._slashSel = (this._slashSel + (e.key === 'ArrowDown' ? 1 : n - 1)) % n;
                this._renderSlashMenu(null, null);
            }
            return true;
        }
        if (e.key === 'Enter' || e.key === 'Tab') {
            e.preventDefault();
            this._executeSlashItem(this.slashMenu.items[this._slashSel]);
            return true;
        }
        if (e.key === 'Escape') {
            e.preventDefault();
            this._closeSlashMenu();
            return true;
        }
        return false;
    }

    handleSlashItemClick(event) {
        const key = event.currentTarget.dataset.key;
        const item = this.slashMenu && this.slashMenu.items.find((o) => o.key === key);
        this._executeSlashItem(item);
    }

    handleSlashMenuClose() {
        this._closeSlashMenu();
    }

    /**
     * Filter from the menu's OWN search box.
     *
     * The menu used to filter from what you typed in the page, which works only
     * for as long as the caret stays there. Clicking the menu — the obvious
     * thing to do with a menu — moved focus and silently ended filtering, and
     * with a long catalog the commands below the fold could not be reached at
     * all. Typing here does not touch the document; _slashCtx still records
     * where the trigger character was, so inserting still lands in the right
     * place.
     */
    handleSlashSearch(event) {
        this._slashQuery = event.currentTarget.value || '';
        this._slashSel = 0;
        this._renderSlashMenu(null, { left: 0, top: 0 });
    }

    /** Arrow/Enter/Escape inside that search box, so it works without the mouse. */
    handleSlashSearchKeydown(event) {
        const items = (this.slashMenu && this.slashMenu.items) || [];
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            event.stopPropagation();
            if (!items.length) {
                return;
            }
            const step = event.key === 'ArrowDown' ? 1 : -1;
            this._slashSel = (this._slashSel + step + items.length) % items.length;
            this._renderSlashMenu(null, { left: 0, top: 0 });
            return;
        }
        if (event.key === 'Enter') {
            event.preventDefault();
            event.stopPropagation();
            if (items[this._slashSel]) {
                this._executeSlashItem(items[this._slashSel]);
            }
            return;
        }
        if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            this._closeSlashMenu();
            return;
        }
        // Everything else stays here: the canvas has its own handlers for
        // backtick and "[", and a search box that reopened the menu it lives in
        // would be its own kind of broken.
        event.stopPropagation();
    }

    /** Remove the typed "/query" trigger text, then insert the chosen thing there. */
    _executeSlashItem(item) {
        const ctx = this._slashCtx;
        this._closeSlashMenu();
        if (!item) {
            return;
        }
        try {
            if (ctx && ctx.node && ctx.node.parentNode) {
                const sel = window.getSelection();
                // Live caret when the user is still typing in the page; the
                // offset recorded at open when they are not (they clicked into
                // the menu, or typed in its search box). Never the end of the
                // node — that deletes whatever followed the trigger.
                const end =
                    sel && sel.rangeCount && sel.anchorNode === ctx.node
                        ? sel.anchorOffset
                        : typeof ctx.endOffset === 'number'
                          ? ctx.endOffset
                          : ctx.node.nodeValue.length;
                const r = document.createRange();
                r.setStart(ctx.node, Math.max(0, ctx.slashIndex));
                r.setEnd(ctx.node, Math.min(end, ctx.node.nodeValue.length));
                r.deleteContents();
                const s = window.getSelection();
                s.removeAllRanges();
                s.addRange(r);
            }
        } catch (e) {
            /* insertion falls back to caret/append */
        }
        // Formatting commands act at the caret instead of inserting markup.
        if (item.cmd) {
            if (item.cmd === 'ul' || item.cmd === 'ol') {
                this._toggleListAtCaret(item.cmd === 'ol');
            } else if (item.cmd === 'table') {
                this.handleInsertTable();
            } else {
                try {
                    document.execCommand('styleWithCSS', false, false);
                } catch (e) {
                    /* best effort */
                }
                document.execCommand(item.cmd, false, null);
            }
            this.htmlEditorDirty = true;
            return;
        }
        this._insertIntoVisualPage(item.snippet);
    }

    // --- Tags palette (Insert Tags without memorizing syntax) ---
    get tagPanelToggleLabel() {
        return this.showTagPanel ? 'Hide Tags' : 'Insert Tags';
    }

    get tagPaletteSections() {
        const shape = extractQueryShape(this.editTemplateQuery, this.editTemplateObject);
        const sections = buildTagPalette(shape);
        // Signer form fields ({?key}) configured on the Signer Inputs tab.
        try {
            const cfg = (this.editFormFieldsConfig || '').trim();
            if (cfg.startsWith('{')) {
                const parsed = JSON.parse(cfg);
                if (Array.isArray(parsed.formFields) && parsed.formFields.length) {
                    sections.push({
                        key: 'formfields',
                        label: 'Signer form fields',
                        hint: 'Filled in by the signer during e-signing. Configure keys under Edit Template → Signer Inputs.',
                        items: parsed.formFields.map((ff) => ({
                            key: 'ff_' + ff.key,
                            label: ff.label || ff.key,
                            snippet: '{?' + ff.key + '}',
                            title:
                                '{?' +
                                ff.key +
                                "} — the signer's answer. Add a default with {?" +
                                ff.key +
                                '|fallback}.'
                        }))
                    });
                }
            }
        } catch (e) {
            /* malformed config — skip */
        }
        // The configured-fields section above only appears once a template already HAS
        // form fields, which made the {?key} writeback grammar undiscoverable to anyone
        // who had not used it before. Always offer the syntax itself, plus a pointer to
        // where keys are configured.
        sections.push({
            key: 'writeback',
            label: 'Signer inputs & writeback',
            hint: 'The signer fills these in during e-signing. The answer is merged into the signed PDF and can be written back to the record — configure keys under Edit Template → Signer Inputs.',
            items: [
                {
                    key: 'wb_basic',
                    label: 'Signer answer',
                    snippet: '{?key}',
                    title: "{?key} — the signer's answer for the form field named `key`. Renders empty if unanswered."
                },
                {
                    key: 'wb_fallback',
                    label: 'Signer answer + default',
                    snippet: '{?key|fallback}',
                    title: '{?key|fallback} — same, but prints `fallback` when the signer leaves it blank.'
                }
            ]
        });
        // {RepeatHeader} was only reachable as a table-toolbar toggle, so it was
        // invisible to anyone browsing the tag rail for it.
        sections.push({
            key: 'tablemarkers',
            label: 'Table markers',
            hint: 'Place inside a table to control how it paginates in the PDF.',
            items: [
                {
                    key: 'tm_repeat',
                    label: 'Repeat header row',
                    snippet: '{RepeatHeader}',
                    title: '{RepeatHeader} — put it in the header row and that row repeats at the top of every PDF page the table spans.'
                }
            ]
        });
        return sections;
    }

    toggleTagPanel() {
        this.showTagPanel = !this.showTagPanel;
    }

    handleInsertTagSnippet(event) {
        // A completed mouse-drag suppresses the click that follows it.
        if (this._suppressChipClick) {
            this._suppressChipClick = false;
            return;
        }
        const snippet = event.currentTarget.dataset.snippet;
        const isBlock = event.currentTarget.dataset.kind === 'block';
        if (!snippet) {
            return;
        }
        if (this.showHtmlBodyVisual) {
            this._insertIntoVisualPage(snippet);
            // #240 — the message now reflects where it actually landed.
            const appended = this._lastInsertWasAppended;
            this.showToast(
                isBlock ? 'Block added' : 'Tag inserted',
                appended
                    ? 'Added at the end of the document — click into the page first to place it at your cursor, or drag chips from the rail to drop them exactly where you point.'
                    : 'Added at your cursor.',
                'success'
            );
            return;
        }
        if (this._insertAtEditorCursor(snippet)) {
            this.showToast(
                isBlock ? 'Block added' : 'Tag inserted',
                snippet.length > 60
                    ? (isBlock ? 'Block' : 'Loop table') + ' inserted at your cursor.'
                    : snippet + ' inserted at your cursor.',
                'success'
            );
        }
    }

    /**
     * Which surface an insert belongs to: the one that owns the caret.
     *
     * This used to be hardcoded to the body canvas. With the caret in a running
     * header, the containment test below therefore failed for EVERY candidate
     * range — the caret was in the band, the test asked whether it was in the
     * body — and the insert fell through to appending at the end of the body.
     * That is the whole of "tags and images never land in the header, they go to
     * the bottom of the page": headers with images or merge tags in them were
     * simply not buildable from the rail.
     *
     * The remembered caret is the primary signal, because clicking a chip in the
     * rail moves focus out of whichever surface the author was editing (the same
     * reason #240 had to stop asking for the live selection). _activeSurface is
     * the fallback for a band that was focused but never had a selection recorded.
     */
    /**
     * Whichever editable surface the pointer is over — body, running header or
     * running footer. Drag paths asked only about the body canvas, so a chip or
     * image dragged onto a band showed no drop marker and, on release, inserted
     * into the body instead.
     */
    _surfaceAtPoint(x, y) {
        for (const surface of this._allSurfaces()) {
            try {
                const r = surface.getBoundingClientRect();
                if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
                    return surface;
                }
            } catch (e) {
                /* a detached surface is simply not under the pointer */
            }
        }
        return null;
    }

    _insertTargetSurface() {
        const remembered = this._caret && this._caret.range;
        if (remembered) {
            try {
                const node = remembered.startContainer;
                const el = node && node.nodeType === 3 ? node.parentElement : node;
                const surface = el && this._surfaceContaining(el);
                if (surface) {
                    return surface;
                }
            } catch (e) {
                /* fall through to the active surface */
            }
        }
        if (this._activeSurface === 'header' || this._activeSurface === 'footer') {
            const band = this.template.querySelector('.dg-chrome-band_' + this._activeSurface);
            if (band) {
                return band;
            }
        }
        return this._bodyCanvas();
    }

    /**
     * Insert markup into the editable visual page — at the caret when there
     * is one (chips keep it alive via mousedown-preventDefault), otherwise
     * appended at the end of whichever surface owns it.
     */
    /**
     * Parks the caret immediately AFTER a just-inserted node.
     *
     * Range.insertNode leaves the range positioned before the content it inserted, so
     * without this the caret sits to the left of a freshly inserted merge tag and the
     * next keystroke types in front of it. Same job the type-to-pill and pill-edit
     * paths already do for themselves — a merge-tag pill is contenteditable=false, so
     * "next to it" is the only sane resting place.
     *
     * Also refreshes the REMEMBERED caret (#240 made inserts prefer `_caret` over the
     * live selection). Leaving it on the pre-insert position would send the next insert
     * back to where this one started, stacking tags in reverse order.
     */
    _parkCaretAfter(node, pv) {
        if (!node || !node.parentNode) {
            return;
        }
        try {
            const doc = (pv && pv.ownerDocument) || document;
            const r = doc.createRange();
            r.setStartAfter(node);
            r.collapse(true);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(r);
            if (pv && pv.focus) {
                pv.focus();
            }
            this._lastCanvasRange = r.cloneRange();
            // Recompute from the selection just set so _caret's block/cell context and
            // the active-block highlight follow the caret instead of going stale.
            this._recordCaret(r.startContainer, pv);
        } catch (e) {
            /* caret parking is best-effort — the insert itself already succeeded */
        }
    }

    _insertIntoVisualPage(markup) {
        const pv = this._insertTargetSurface();
        if (!pv) {
            return;
        }
        // Covers every insert route that funnels through here — slash menu, block
        // palette, tag chips, image assets, the table grid picker.
        this._pushUndo('insert');
        const doc = pv.ownerDocument || document;
        const tpl = doc.createElement('template');
        // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
        tpl.innerHTML = markup;
        this._pillifyTags(tpl.content);
        // Capture BEFORE insertion — insertNode empties the fragment.
        const firstEl = tpl.content.firstElementChild;
        // Same reason, but for the caret: after Range.insertNode the range still starts
        // BEFORE the inserted content (that is what the DOM spec says it does), so the
        // caret ends up to the LEFT of the tag that was just inserted and the next
        // keystroke types in front of it. Remember the last node so the caret can be
        // parked after it once the fragment has been spliced in.
        const lastNode = tpl.content.lastChild;
        let inserted = false;
        // #240 — prefer the REMEMBERED caret over the live selection. Clicking a chip in
        // the rail moves focus out of the canvas, so by the time this runs the live
        // selection is usually gone and every insert fell through to pv.appendChild —
        // the "always inserts at the bottom" report.
        const candidates = [];
        if (this._caret && this._caret.range) {
            candidates.push(this._caret.range);
        }
        try {
            const sel = window.getSelection();
            if (sel && sel.rangeCount) {
                candidates.push(sel.getRangeAt(0));
            }
        } catch (e) {
            /* live selection is optional — the remembered one is the primary */
        }
        if (this._lastCanvasRange) {
            candidates.push(this._lastCanvasRange);
        }
        for (const range of candidates) {
            try {
                const node = range.startContainer;
                const el = node.nodeType === 3 ? node.parentElement : node;
                // Never split a merge-tag pill: they are contenteditable=false atoms and
                // an insert inside one corrupts the tag.
                if (el && this._isInCanvas(el, pv) && el.closest && !el.closest('[data-dg-tag]')) {
                    const target = range.cloneRange();
                    target.collapse(true);
                    target.insertNode(tpl.content);
                    inserted = true;
                    break;
                }
            } catch (e) {
                /* try the next candidate */
            }
        }
        if (!inserted) {
            pv.appendChild(tpl.content);
        }
        // Both routes land here: type-after-the-tag is what an author expects whether
        // the insert went to the caret or was appended.
        this._parkCaretAfter(lastNode, pv);
        // Report what ACTUALLY happened — the old toast said "added at the end"
        // unconditionally, which misreported every successful caret insert.
        this._lastInsertWasAppended = !inserted;
        // Never make the user hunt for what they just added.
        if (firstEl && firstEl.scrollIntoView) {
            try {
                firstEl.scrollIntoView({ block: 'center', behavior: 'smooth' });
            } catch (e) {
                /* best effort */
            }
        }
        this.htmlEditorDirty = true;
    }

    /**
     * Merge cells: with a selection spanning multiple cells, merges the whole
     * rectangle (top-left keeps colspan/rowspan + everyone's content); with a
     * collapsed selection, merges the current cell with the one to its right.
     * Uniform grids assumed — pre-merged regions inside the rectangle are
     * flattened into it.
     */
    _mergeCells(cell, table) {
        // Excel-style cell selection wins when present.
        if (this._cellSel && this._cellSel.length > 1) {
            const a0 = this._cellSel[0];
            const f0 = this._cellSel[this._cellSel.length - 1];
            const t0 = a0.closest('table');
            this._clearCellSel();
            this._mergeRect(t0, a0, f0);
            return;
        }
        const sel = window.getSelection();
        let a = cell;
        let f = cell;
        try {
            if (sel && sel.anchorNode && sel.focusNode) {
                const an = sel.anchorNode.nodeType === 3 ? sel.anchorNode.parentElement : sel.anchorNode;
                const fn = sel.focusNode.nodeType === 3 ? sel.focusNode.parentElement : sel.focusNode;
                const ac = an && an.closest ? an.closest('td, th') : null;
                const fc = fn && fn.closest ? fn.closest('td, th') : null;
                if (ac && fc && table.contains(ac) && table.contains(fc)) {
                    a = ac;
                    f = fc;
                }
            }
        } catch (e) {
            /* selection best-effort */
        }
        if (a === f) {
            const nxt = a.nextElementSibling;
            if (!nxt) {
                this.showToast(
                    'Nothing to merge',
                    'Select across the cells you want to merge (click the first, shift-click the last), or put the caret in a cell that has a neighbor to its right.',
                    'info'
                );
                return;
            }
            if ((nxt.textContent || '').trim()) {
                // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                a.innerHTML = a.innerHTML + ' ' + nxt.innerHTML;
            }
            a.colSpan = (a.colSpan || 1) + (nxt.colSpan || 1);
            nxt.remove();
            this.htmlEditorDirty = true;
            return;
        }
        this._mergeRect(table, a, f);
    }

    _mergeRect(table, a, f) {
        const rows = Array.from(table.rows);
        const r1 = Math.min(rows.indexOf(a.parentElement), rows.indexOf(f.parentElement));
        const r2 = Math.max(rows.indexOf(a.parentElement), rows.indexOf(f.parentElement));
        const c1 = Math.min(a.cellIndex, f.cellIndex);
        const c2 = Math.max(a.cellIndex, f.cellIndex);
        const keep = rows[r1].children[c1];
        let extra = '';
        for (let r = r1; r <= r2; r++) {
            for (let c = c2; c >= c1; c--) {
                const el = rows[r] && rows[r].children[c];
                if (!el || el === keep) {
                    continue;
                }
                if ((el.textContent || '').trim()) {
                    // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
                    extra += ' ' + el.innerHTML;
                }
                el.remove();
            }
        }
        if (extra) {
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            keep.innerHTML = keep.innerHTML + extra;
        }
        keep.colSpan = c2 - c1 + 1;
        keep.rowSpan = r2 - r1 + 1;
        // Excel behavior: the merged cell stays selected, so Split (or Fill)
        // right after Merge just works.
        this._clearCellSel();
        keep.setAttribute('data-dg-selcell', '1');
        keep.style.boxShadow = 'inset 0 0 0 2px #7c3aed';
        this._cellSel = [keep];
        this.htmlEditorDirty = true;
    }

    /** Split a merged cell back into its grid cells (empties added). */
    _splitCell(cell, row, table, cellIndex) {
        const cs = cell.colSpan || 1;
        const rs = cell.rowSpan || 1;
        if (cs === 1 && rs === 1) {
            this.showToast('Not a merged cell', 'Split only applies to cells that were merged.', 'info');
            return;
        }
        const doc = cell.ownerDocument || document;
        const mkCell = () => {
            const c = doc.createElement(cell.tagName.toLowerCase());
            const style = cell.getAttribute('style');
            if (style) {
                c.setAttribute('style', style);
            }
            // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
            c.innerHTML = '&nbsp;';
            return c;
        };
        cell.removeAttribute('colspan');
        cell.removeAttribute('rowspan');
        for (let i = 1; i < cs; i++) {
            cell.insertAdjacentElement('afterend', mkCell());
        }
        if (rs > 1) {
            const rows = Array.from(table.rows);
            const rIdx = rows.indexOf(row);
            for (let r = rIdx + 1; r < rIdx + rs && r < rows.length; r++) {
                const ref = rows[r].children[Math.min(cellIndex, rows[r].children.length - 1)];
                for (let i = 0; i < cs; i++) {
                    const c = mkCell();
                    if (ref) {
                        ref.insertAdjacentElement('beforebegin', c);
                    } else {
                        rows[r].appendChild(c);
                    }
                }
            }
        }
        this.htmlEditorDirty = true;
    }

    /** Table group's "+ Table": a styled 3-column data table at the caret. */
    // ===== Word-style insert-table grid picker ===============================
    //
    // The old button dropped a fixed 3-column table and left the author to add or
    // delete their way to the shape they wanted. This is the Word/Google Docs
    // affordance: hover a grid, see "4 x 3 table", click to place exactly that.
    @track tableGrid = null;
    static GRID_MAX_COLS = 8;
    static GRID_MAX_ROWS = 8;

    handleTableGridToggle(event) {
        if (this.tableGrid) {
            this.tableGrid = null;
            this._watchFloatingLayer(!!this.selectionBubble);
            return;
        }
        // Remember where the caret was BEFORE the picker took focus, or the table
        // lands at the end of the document instead of where the author was working.
        this.tableGrid = { rows: 0, cols: 0, label: 'Pick a size' };
        this._floatAnchor = event.currentTarget;
        this._watchFloatingLayer(true);
    }

    /** Cells for the picker, flagged so the hovered rectangle lights up. */
    get tableGridCells() {
        const cells = [];
        const hotR = this.tableGrid ? this.tableGrid.rows : 0;
        const hotC = this.tableGrid ? this.tableGrid.cols : 0;
        for (let r = 1; r <= DocGenAdmin.GRID_MAX_ROWS; r++) {
            for (let c = 1; c <= DocGenAdmin.GRID_MAX_COLS; c++) {
                cells.push({
                    key: r + 'x' + c,
                    r,
                    c,
                    cls: r <= hotR && c <= hotC ? 'dg-grid-cell dg-grid-cell_on' : 'dg-grid-cell'
                });
            }
        }
        return cells;
    }

    get tableGridLabel() {
        if (!this.tableGrid || !this.tableGrid.rows) {
            return 'Pick a size';
        }
        return `${this.tableGrid.cols} × ${this.tableGrid.rows} table`;
    }

    handleTableGridHover(event) {
        const r = parseInt(event.currentTarget.dataset.r, 10);
        const c = parseInt(event.currentTarget.dataset.c, 10);
        if (!isNaN(r) && !isNaN(c)) {
            this.tableGrid = { rows: r, cols: c };
        }
    }

    handleTableGridPick(event) {
        const rows = parseInt(event.currentTarget.dataset.r, 10);
        const cols = parseInt(event.currentTarget.dataset.c, 10);
        this.tableGrid = null;
        this._watchFloatingLayer(!!this.selectionBubble);
        if (isNaN(rows) || isNaN(cols)) {
            return;
        }
        this.handleInsertTable(cols, rows);
    }

    /**
     * @param cols  columns to build (default 3 — the historic behaviour)
     * @param bodyRows  body rows BENEATH the header row (default 2)
     */
    handleInsertTable(cols, bodyRows) {
        const nCols = typeof cols === 'number' && cols > 0 ? cols : 3;
        const nRows = typeof bodyRows === 'number' && bodyRows > 0 ? bodyRows : 2;
        const thStyle = 'background: #1f3a5f; color: #ffffff; text-align: left; padding: 5pt 7pt; font-size: 9.5pt';
        const tdStyle = 'padding: 5pt 7pt; border-bottom: 0.75pt solid #dddddd';
        let head = '';
        for (let c = 1; c <= nCols; c++) {
            head += '<th style="' + thStyle + '">Column ' + c + '</th>';
        }
        let body = '';
        for (let r = 0; r < nRows; r++) {
            body += '<tr style="page-break-inside: avoid">';
            for (let c = 0; c < nCols; c++) {
                body += '<td style="' + tdStyle + '">&nbsp;</td>';
            }
            body += '</tr>';
        }
        // width:100% + table-layout:fixed so an 8-column table cannot overhang the
        // sheet the moment it is created.
        const markup =
            '\n<table style="width: 100%; border-collapse: collapse; table-layout: fixed; max-width: 100%">' +
            '<thead><tr>' +
            head +
            '</tr></thead><tbody>' +
            body +
            '</tbody></table>\n';
        if (this.showHtmlBodyVisual) {
            this._insertIntoVisualPage(markup);
            this._clampTablesToCanvas();
        } else {
            this._insertAtEditorCursor(markup);
        }
        this.showToast(
            'Table added',
            `${nCols} × ${nRows + 1} table inserted. Drag a cell edge to resize columns; hover the table for row and column controls.`,
            'success'
        );
    }

    _legacyInsertTableUnused() {
        const th = 'background: #1f3a5f; color: #ffffff; text-align: left; padding: 5pt 7pt; font-size: 9.5pt';
        const cell = 'padding: 5pt 7pt; border-bottom: 0.75pt solid #dddddd';
        const snippet =
            '\n<table style="width: 100%; border-collapse: collapse">' +
            '<thead><tr>' +
            '<th style="' +
            th +
            '">Column 1</th><th style="' +
            th +
            '">Column 2</th><th style="' +
            th +
            '">Column 3</th>' +
            '</tr></thead><tbody>' +
            '<tr style="page-break-inside: avoid"><td style="' +
            cell +
            '">&nbsp;</td><td style="' +
            cell +
            '">&nbsp;</td><td style="' +
            cell +
            '">&nbsp;</td></tr>' +
            '<tr style="page-break-inside: avoid"><td style="' +
            cell +
            '">&nbsp;</td><td style="' +
            cell +
            '">&nbsp;</td><td style="' +
            cell +
            '">&nbsp;</td></tr>' +
            '</tbody></table>\n';
        if (this.showHtmlBodyVisual) {
            this._insertIntoVisualPage(snippet);
        } else {
            this._insertAtEditorCursor(snippet);
        }
        this.showToast(
            'Table added',
            'Drag a cell edge to resize columns; use the Table tools for rows, columns, and borders.',
            'success'
        );
    }

    /**
     * Block-level elements the landing box can outline. A caret alone answers
     * "between which characters"; authors dragging a tag want "into which cell /
     * which paragraph", which is a different question and the one that actually
     * decides whether the drop was right.
     */
    static get DROP_ZONE_BLOCKS() {
        return 'td,th,li,p,h1,h2,h3,h4,h5,h6,blockquote,pre';
    }

    /**
     * Purple insertion caret plus a translucent landing box, both tracking the
     * pointer while dragging.
     *
     * The box carries `dg-drop-marker` in ADDITION to its own class on purpose. Four
     * separate places strip editor chrome out of the serialized body by that class
     * name (the save path, the Source view, the preview scrub and the region walker).
     * Giving the box a brand-new class would have meant finding all four and adding it
     * to each — and missing one leaks `<div class="dg-drop-zone">` into a customer's
     * saved template. Sharing the class means every existing stripper already handles
     * it, and the smoke suite's "no editor chrome leaks into the serialized body" check
     * covers it for free.
     */
    _showDropMarker(event, pv) {
        // :not(.dg-drop-zone) — both elements answer to .dg-drop-marker now, so the
        // caret lookup has to exclude the box or it styles the wrong node.
        let marker = pv.querySelector('.dg-drop-marker:not(.dg-drop-zone)');
        if (!marker) {
            marker = document.createElement('span');
            marker.className = 'dg-drop-marker';
            marker.setAttribute('contenteditable', 'false');
            marker.style.cssText =
                'position: absolute; width: 3px; background: #7c3aed; pointer-events: none; z-index: 99; border-radius: 2px; box-shadow: 0 0 4px rgba(124, 58, 237, 0.7);';
            pv.style.position = 'relative';
            pv.appendChild(marker);
        }
        let zone = pv.querySelector('.dg-drop-zone');
        if (!zone) {
            zone = document.createElement('div');
            zone.className = 'dg-drop-marker dg-drop-zone';
            zone.setAttribute('contenteditable', 'false');
            // z-index below the caret so the precise insertion point stays readable
            // on top of the box.
            zone.style.cssText =
                'position: absolute; pointer-events: none; z-index: 98; border: 2px dashed rgba(124, 58, 237, 0.75); border-radius: 4px; background: rgba(124, 58, 237, 0.10); box-sizing: border-box;';
            pv.style.position = 'relative';
            pv.appendChild(zone);
        }
        let rect = null;
        let blockRect = null;
        try {
            const range = document.caretRangeFromPoint(event.clientX, event.clientY);
            if (range && pv.contains(range.startContainer)) {
                const rects = range.getClientRects();
                rect = rects && rects.length ? rects[0] : null;
                const el =
                    range.startContainer.nodeType === 3 ? range.startContainer.parentElement : range.startContainer;
                if (!rect) {
                    rect = el ? el.getBoundingClientRect() : null;
                }
                // The landing box outlines the block that will RECEIVE the drop.
                // Bounded to inside the canvas: closest() would happily walk out to the
                // editor chrome and outline the whole page.
                const block = el && el.closest ? el.closest(DocGenAdmin.DROP_ZONE_BLOCKS) : null;
                if (block && pv.contains(block) && block !== pv) {
                    blockRect = block.getBoundingClientRect();
                }
            }
        } catch (e) {
            rect = null;
            blockRect = null;
        }
        if (rect) {
            const pvRect = pv.getBoundingClientRect();
            // #244 — getBoundingClientRect returns SCALED screen pixels, but the marker
            // is positioned in the canvas's own (unscaled) coordinate space because it
            // is a child of the scaled element. Divide the delta back out or the marker
            // drifts further from the pointer the more you zoom.
            const z = this.designerZoom || 1;
            marker.style.left = (rect.left - pvRect.left) / z + 'px';
            marker.style.top = (rect.top - pvRect.top) / z + 'px';
            marker.style.height = (rect.height || 16) / z + 'px';
            marker.style.display = 'block';
        } else {
            marker.style.display = 'none';
        }
        if (blockRect) {
            const pvRect2 = pv.getBoundingClientRect();
            const z2 = this.designerZoom || 1;
            // Same unscaling as the caret (#244): the box is a child of the scaled
            // canvas but getBoundingClientRect reports scaled screen pixels, so without
            // dividing z back out the outline drifts off the block as you zoom.
            zone.style.left = (blockRect.left - pvRect2.left) / z2 + 'px';
            zone.style.top = (blockRect.top - pvRect2.top) / z2 + 'px';
            zone.style.width = blockRect.width / z2 + 'px';
            zone.style.height = blockRect.height / z2 + 'px';
            zone.style.display = 'block';
        } else {
            // Between blocks, or over empty canvas — the caret alone is the honest
            // answer. An outline with nothing to outline would be a guess.
            zone.style.display = 'none';
        }
        pv.style.boxShadow = '0 0 0 3px rgba(124, 58, 237, 0.35)';
    }

    _hideDropMarker(pv) {
        // querySelectorAll, not querySelector: the caret and the landing box BOTH carry
        // dg-drop-marker, and removing only the first left the other one painted on the
        // canvas after the drop finished.
        for (const marker of pv.querySelectorAll('.dg-drop-marker')) {
            marker.remove();
        }
        pv.style.boxShadow = '';
    }

    /** Drop a dragged tag chip / image thumbnail at the pointed-at spot. */
    _handleVisualDrop(event, pv) {
        event.preventDefault();
        this._hideDropMarker(pv);
        // Internal chip/thumbnail drags carry their payload in component state
        // (_dragSnippet) — dataTransfer doesn't survive LWS reliably. External
        // drops (text dragged from elsewhere) still read dataTransfer.
        let text = this._dragSnippet;
        this._dragSnippet = null;
        if (!text) {
            try {
                text = event.dataTransfer && event.dataTransfer.getData('text/plain');
            } catch (e) {
                text = null;
            }
        }
        if (!text) {
            return;
        }
        this._pushUndo('drop');
        const doc = pv.ownerDocument || document;
        const tpl = doc.createElement('template');
        // eslint-disable-next-line @lwc/lwc/no-inner-html -- deliberate manual-DOM canvas write; content passes _sanitizeStagedHtml / scopeHtmlForInlinePreview
        tpl.innerHTML = text;
        this._pillifyTags(tpl.content);
        let range = null;
        try {
            if (doc.caretRangeFromPoint) {
                range = doc.caretRangeFromPoint(event.clientX, event.clientY);
            } else if (doc.caretPositionFromPoint) {
                const p = doc.caretPositionFromPoint(event.clientX, event.clientY);
                if (p) {
                    range = doc.createRange();
                    range.setStart(p.offsetNode, p.offset);
                }
            }
        } catch (e) {
            range = null;
        }
        // Only honor drop points inside the page; otherwise append at the end.
        if (range && pv.contains(range.startContainer)) {
            range.collapse(true);
            range.insertNode(tpl.content);
        } else {
            pv.appendChild(tpl.content);
        }
        this.htmlEditorDirty = true;
    }

    /** Tag chips and image thumbnails are draggable onto the visual page.
     *  Payload rides in _dragSnippet (LWS-proof); dataTransfer is set too for
     *  drops outside the canvas (e.g. into the Source textarea). */
    // --- Mouse-driven chip drag (HTML5 DnD does not survive LWS + manual DOM) ---
    // mousedown arms it; 7px of movement starts it (a ghost chip follows the
    // cursor and the purple drop caret tracks the pointer); mouseup over the
    // page inserts at that exact point. A no-movement mouseup stays a click.
    handleChipDragMouseDown(event) {
        // preventDefault keeps the canvas caret alive (same job the old
        // handleFmtMouseDown did on these chips).
        event.preventDefault();
        const snippet = event.currentTarget.dataset.snippet;
        if (!snippet) {
            return;
        }
        this._pointerDrag = {
            snippet,
            label: (event.currentTarget.textContent || 'Insert').trim().slice(0, 40),
            startX: event.clientX,
            startY: event.clientY,
            started: false,
            ghost: null
        };
        this._onPointerDragMove = (e) => this._pointerDragMove(e);
        this._onPointerDragUp = (e) => this._pointerDragUp(e);
        document.addEventListener('mousemove', this._onPointerDragMove, true);
        document.addEventListener('mouseup', this._onPointerDragUp, true);
    }

    _getVisualPv() {
        const host = this.template.querySelector('.dg-visual-host');
        return host && host.querySelector('.dg-pv');
    }

    _pointerDragMove(e) {
        const d = this._pointerDrag;
        if (!d) {
            return;
        }
        if (!d.started) {
            if (Math.abs(e.clientX - d.startX) + Math.abs(e.clientY - d.startY) < 7) {
                return;
            }
            d.started = true;
            const g = document.createElement('div');
            g.className = 'dg-drag-ghost';
            g.textContent = d.label;
            document.body.appendChild(g);
            d.ghost = g;
        }
        d.ghost.style.left = e.clientX + 14 + 'px';
        d.ghost.style.top = e.clientY + 10 + 'px';
        // Any surface, not just the body — dragging into the running header has to
        // show where it will land, exactly as it does on the page.
        const over = this._surfaceAtPoint(e.clientX, e.clientY);
        for (const surface of this._allSurfaces()) {
            if (surface === over) {
                this._showDropMarker(e, surface);
            } else {
                this._hideDropMarker(surface);
            }
        }
        e.preventDefault();
    }

    _pointerDragUp(e) {
        const d = this._pointerDrag;
        this._pointerDrag = null;
        document.removeEventListener('mousemove', this._onPointerDragMove, true);
        document.removeEventListener('mouseup', this._onPointerDragUp, true);
        if (!d || !d.started) {
            return; // plain click — the chip's onclick inserts at the caret
        }
        if (d.ghost) {
            d.ghost.remove();
        }
        // The drag consumed this gesture — swallow the click that follows a
        // mouseup back over the chip, or it would double-insert.
        this._suppressChipClick = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this._suppressChipClick = false;
        }, 250);
        const pv = this._getVisualPv();
        if (!pv) {
            return;
        }
        this._hideDropMarker(pv);
        const r = pv.getBoundingClientRect();
        const over = e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
        if (!over) {
            return;
        }
        // Document-context DOM insertion silently no-ops under LWS, so this
        // capture-phase listener only STAGES the drop; the pv's own mouseup
        // listener (proven context — see renderedCallback) performs it. The
        // timeout is a safety net if that listener never fires.
        this._pendingDropInsert = { snippet: d.snippet, x: e.clientX, y: e.clientY };
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this._performPendingDropInsert(), 250);
    }

    /** Executes a staged chip drop: caret to the drop point, then the same
     *  insert the chip's click handler uses. Idempotent — first caller wins. */
    _performPendingDropInsert() {
        const drop = this._pendingDropInsert;
        if (!drop) {
            return;
        }
        this._pendingDropInsert = null;
        // Drop into whatever was under the pointer — body, header or footer.
        const pv = this._surfaceAtPoint(drop.x, drop.y) || this._getVisualPv();
        if (!pv) {
            return;
        }
        try {
            let range = null;
            if (document.caretRangeFromPoint) {
                range = document.caretRangeFromPoint(drop.x, drop.y);
            } else if (document.caretPositionFromPoint) {
                const pos = document.caretPositionFromPoint(drop.x, drop.y);
                if (pos) {
                    range = document.createRange();
                    range.setStart(pos.offsetNode, pos.offset);
                }
            }
            // _isInCanvas, not pv.contains — contains() is unreliable under the LWS
            // namespace sandbox and has broken four separate features.
            if (range && this._isInCanvas(range.startContainer, pv)) {
                range.collapse(true);
                const s = window.getSelection();
                s.removeAllRanges();
                s.addRange(range);
                pv.focus();
            }
        } catch (err) {
            /* caret placement best-effort — insert falls back to append */
        }
        this._insertIntoVisualPage(drop.snippet);
    }

    /**
     * A drag ghost that shows WHAT is being placed.
     *
     * Without setDragImage the browser drags a translucent snapshot of the chip
     * you grabbed — which, for a rail of near-identical chips, says nothing
     * about what will land. The ghost is built to look like the thing being
     * inserted: a pill for a tag, a framed thumbnail for an image, both with a
     * dashed outline that reads as "not placed yet".
     *
     * It must be IN the document when setDragImage is called — a detached node
     * is silently ignored and you are back to the default. Parked off-screen and
     * removed on a timer, since dragend does not reliably fire when the drop
     * lands outside the window.
     */
    _setDragGhost(event, label, imgUrl) {
        if (!event.dataTransfer || !event.dataTransfer.setDragImage) {
            return;
        }
        try {
            const doc = document;
            const ghost = doc.createElement('div');
            ghost.style.cssText =
                'position:fixed;top:-1000px;left:-1000px;z-index:-1;' +
                'display:inline-flex;align-items:center;gap:6px;' +
                'padding:4px 9px;border:1.5px dashed #7c3aed;border-radius:9px;' +
                'background:#f6f3ff;color:#3b2a6b;' +
                'font:12px/1.2 Helvetica,Arial,sans-serif;white-space:nowrap;' +
                'box-shadow:0 2px 6px rgba(60,40,120,0.18);';
            if (imgUrl) {
                const thumb = doc.createElement('img');
                thumb.src = imgUrl;
                thumb.style.cssText = 'width:26px;height:26px;object-fit:cover;border-radius:3px;';
                ghost.appendChild(thumb);
            }
            const text = doc.createElement('span');
            // Long tags would otherwise produce a ghost wider than the page.
            text.textContent = label.length > 42 ? label.slice(0, 40) + '…' : label;
            ghost.appendChild(text);
            doc.body.appendChild(ghost);
            // Offset so the ghost sits just below-right of the cursor rather
            // than under it, keeping the drop point visible while dragging.
            event.dataTransfer.setDragImage(ghost, -12, -8);
            this._dragGhostEl = ghost;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                if (ghost.parentNode) {
                    ghost.parentNode.removeChild(ghost);
                }
                if (this._dragGhostEl === ghost) {
                    this._dragGhostEl = null;
                }
            }, 1000);
        } catch (e) {
            // A missing ghost is cosmetic — never let it stop the drag itself.
            const noop = e && e.message; // NOPMD
        }
    }

    handleTagDragStart(event) {
        const snippet = event.currentTarget.dataset.snippet;
        this._dragSnippet = snippet || null;
        if (snippet && event.dataTransfer) {
            try {
                event.dataTransfer.setData('text/plain', snippet);
                event.dataTransfer.effectAllowed = 'copy';
            } catch (e) {
                /* dataTransfer best-effort */
            }
            this._setDragGhost(event, snippet, null);
        }
    }

    handleImageDragStart(event) {
        const { url, name } = event.currentTarget.dataset;
        const snippet = url ? '<img src="' + url + '" alt="' + (name || 'image') + '" style="width: 180px" />' : null;
        this._dragSnippet = snippet;
        if (snippet && event.dataTransfer) {
            try {
                event.dataTransfer.setData('text/plain', snippet);
                event.dataTransfer.effectAllowed = 'copy';
            } catch (e) {
                /* dataTransfer best-effort */
            }
            // The image itself, not its markup — dragging a picture should look
            // like dragging that picture.
            this._setDragGhost(event, name || 'image', url);
        }
    }

    /** Splice text into the code textarea at the cursor (or before </body>). */
    _insertAtEditorCursor(text) {
        const ta = this.template.querySelector('.dg-html-body-editor');
        if (!ta) {
            return false;
        }
        let start = typeof ta.selectionStart === 'number' ? ta.selectionStart : ta.value.length;
        let end = typeof ta.selectionEnd === 'number' ? ta.selectionEnd : start;
        if (start === end && (start === 0 || start === ta.value.length)) {
            const bodyClose = ta.value.search(/<\/body\s*>/i);
            if (bodyClose > -1) {
                start = bodyClose;
                end = bodyClose;
            }
        }
        ta.value = ta.value.slice(0, start) + text + ta.value.slice(end);
        const pos = start + text.length;
        try {
            ta.focus();
            ta.setSelectionRange(pos, pos);
        } catch (e) {
            /* focus/selection is best-effort */
        }
        this.htmlEditorDirty = true;
        return true;
    }

    // --- Images panel (Add Image without knowing shepherd URLs) ---
    get imagePanelToggleLabel() {
        return this.showImagePanel ? 'Hide Images' : 'Add Image';
    }

    get hasTemplateImages() {
        return (this.templateImages || []).length > 0;
    }

    async toggleImagePanel() {
        this.showImagePanel = !this.showImagePanel;
        if (this.showImagePanel) {
            await this._loadTemplateImages();
        }
    }

    async _loadTemplateImages() {
        this.isLoadingTemplateImages = true;
        try {
            this.templateImages = (await listHtmlTemplateImages({ templateId: this.editTemplateId })) || [];
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Could not load images', msg, 'error');
            this.templateImages = [];
        } finally {
            this.isLoadingTemplateImages = false;
        }
    }

    triggerInsertImagePicker() {
        const input = this.template.querySelector('.dg-insert-image-input');
        if (input) {
            input.click();
        }
    }

    async handleInsertImageSelected(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) {
            return;
        }
        // SVG excluded on purpose — the PDF engine silently drops it.
        if (!/\.(png|jpe?g|gif|bmp)$/i.test(file.name)) {
            this.showToast(
                'Unsupported image',
                'Use .png, .jpg, .gif, or .bmp — SVG does not render in PDF output.',
                'error'
            );
            event.target.value = '';
            return;
        }
        this.isUploadingInsertImage = true;
        try {
            const buffer = await file.arrayBuffer();
            const result = await saveHtmlTemplateImage({
                templateId: this.editTemplateId,
                fileName: file.name,
                base64Content: bytesToBase64(new Uint8Array(buffer))
            });
            this._insertImageSnippet(result.url, result.fileName);
            await this._loadTemplateImages();
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Image upload failed', msg, 'error');
        } finally {
            this.isUploadingInsertImage = false;
            event.target.value = '';
        }
    }

    handleInsertExistingImage(event) {
        const { url, name } = event.currentTarget.dataset;
        this._insertImageSnippet(url, name);
    }

    /** Drop a ready-made, PDF-safe <img> tag at the editor cursor. */
    _insertImageSnippet(url, name) {
        const snippet = '<img src="' + url + '" alt="' + (name || 'image') + '" style="width: 180px" />';
        // Visual mode: insert into the editable rendered page directly.
        if (this.showHtmlBodyVisual) {
            this._insertIntoVisualPage('<p>' + snippet + '</p>');
            this.showToast(
                'Image inserted',
                'Added at the end of the document — cut/paste it where you want it, or fine-tune in Code.',
                'success'
            );
            return;
        }
        if (this._insertAtEditorCursor(snippet)) {
            this.showToast(
                'Image inserted',
                'A PDF-safe <img> tag was placed at your cursor — adjust the width, then click "Apply Editor HTML".',
                'success'
            );
        }
    }

    async handleApplyHtmlBody() {
        // Serialize the CURRENT view non-destructively — Apply must never kick
        // the author out of Visual mode.
        const text = (this._currentDraftHtml() || '').trim();
        if (!text) {
            this.showToast('Nothing to apply', 'Paste or edit HTML in the editor first.', 'warning');
            return;
        }
        this.isApplyingHtmlBody = true;
        try {
            const base = (this.uploadedFileName || 'template.html').replace(/\.(html?|zip)$/i, '');
            await this._processAndSaveHtmlBody(this.editTemplateId, text, base + '.html', null, 'editor');
            this.htmlEditorDirty = false;
            if (this.showHtmlBodyVisual) {
                // Staged text is the new baseline: Source view and the
                // visual round-trip both work from what was just staged.
                this._visualOriginalCode = text;
                const ta = this.template.querySelector('.dg-html-body-editor');
                if (ta) {
                    ta.value = text;
                }
            }
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || String(err);
            this.showToast('Apply failed', msg, 'error');
        } finally {
            this.isApplyingHtmlBody = false;
        }
    }

    downloadTemplate() {
        if (this.currentFileId) {
            this[NavigationMixin.Navigate](
                {
                    type: 'standard__webPage',
                    attributes: {
                        url: `/sfc/servlet.shepherd/document/download/${this.currentFileId}`
                    }
                },
                false
            );
        }
    }

    resetForm() {
        this.uploadedFileName = '';
        this.uploadedContentVersionId = null;
        this.uploadedPdfAcroFormSnapshot = null;
        this.uploadedPdfAcroFormSnapshotJson = null;
        this._resetEditFileUploadWidget();
        this.currentWizardStep = '1';
        this.newTemplateName = '';
        this.newTemplateApiName = '';
        this._newApiNameEdited = false;
        this.newTemplateCategory = '';
        // Excel leaves Output Format = 'Native'; without this reset the next
        // wizard open shows Type=Excel with a forced-invalid 'PDF' format.
        // Default path is "I Have an Existing File" — most admins arrive with
        // a document in hand; the design/AI/scratch cards sit right beside it.
        this.newAuthoringMode = 'file';
        this.newStarterKey = 'report';
        this._logoFile = null;
        this.newTemplateLogoName = '';
        this.isAutoCreating = false;
        this.showAdvancedOptions = false;
        this.newTemplateLogoChoice = 'none';
        this.newTemplateType = 'Word';
        this.newTemplateDesc = '';
        this.newTemplateQuery = '';
        this.newTemplateOutputFormat = 'PDF';
        this.newTemplatePageOrientation = 'Portrait';
        this.newTemplatePageSize = 'Letter';
        this.newTemplatePageMargins = 'Default';
        this.newTemplateCustomMargins = '';
        this.newTemplateObject = 'Account';
        this.createdTemplateId = null;
        this.isCreating = true;
        this._editContext = false;
        this.useApexProvider = false;
        this.dataSourceMode = 'record';
        this._clearApexProviderState();
        this.queryTreeNodes = [];
        this.builderTab = 'fields';
        this.builderSearchTerm = '';
        this.newTemplateSampleRecordId = '';
        this.sampleRecordData = null;
        this._allFields = [];
        this._allChildren = [];
        this._allParents = [];
        return refreshApex(this.wiredTemplatesResult);
    }

    // mode is optional — 'sticky' keeps error detail on screen long enough to read
    // and copy (used by the #236 create-failure path, where the message names a field).
    showToast(title, message, variant, mode) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant,
                mode: mode || 'dismissable'
            })
        );
    }

    // ===== Watermark / background image tab =====

    get editTemplateOutputIsPdf() {
        return this.editTemplateOutputFormat === 'PDF';
    }

    get watermarkPreviewUrl() {
        return this.editTemplateWatermarkCvId
            ? '/sfc/servlet.shepherd/version/download/' + this.editTemplateWatermarkCvId
            : null;
    }

    // Watermark wash: opacity is baked into the PNG's pixels client-side
    // before upload — the PDF engine (Flying Saucer) has no CSS opacity, so
    // pre-multiplied alpha is the only thing that renders seamlessly.
    watermarkOpacityPct = '30';

    get watermarkOpacityOptions() {
        return [
            { label: 'Light wash (15%)', value: '15' },
            { label: 'Medium wash (30%)', value: '30' },
            { label: 'Strong (50%)', value: '50' },
            { label: 'Original image (100%)', value: '100' }
        ].map((o) => ({ ...o, selected: o.value === this.watermarkOpacityPct }));
    }

    handleWatermarkOpacityChange(event) {
        this.watermarkOpacityPct = event.currentTarget.value;
    }

    /** Redraws the image at the chosen opacity on a canvas → PNG base64.
     *  100% skips the canvas so the original bytes upload untouched. */
    async _bakeWatermarkOpacity(file, pct) {
        const readAsBase64 = (blobOrFile) =>
            new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => {
                    const dataUrl = reader.result;
                    const commaIdx = dataUrl.indexOf(',');
                    resolve(commaIdx > -1 ? dataUrl.substring(commaIdx + 1) : null);
                };
                reader.onerror = () => reject(new Error('FileReader failed'));
                reader.readAsDataURL(blobOrFile);
            });
        if (pct >= 100) {
            return { base64: await readAsBase64(file), fileName: file.name };
        }
        const url = URL.createObjectURL(file);
        try {
            const img = new Image();
            await new Promise((resolve, reject) => {
                img.onload = resolve;
                img.onerror = () => reject(new Error('Could not read the image'));
                img.src = url;
            });
            const canvas = document.createElement('canvas');
            canvas.width = img.naturalWidth || img.width;
            canvas.height = img.naturalHeight || img.height;
            const ctx = canvas.getContext('2d');
            ctx.globalAlpha = pct / 100;
            ctx.drawImage(img, 0, 0);
            const dataUrl = canvas.toDataURL('image/png');
            const commaIdx = dataUrl.indexOf(',');
            return {
                base64: dataUrl.substring(commaIdx + 1),
                fileName: file.name.replace(/\.[^.]+$/, '') + '.png'
            };
        } finally {
            URL.revokeObjectURL(url);
        }
    }

    async handleWatermarkFileSelected(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) {
            return;
        }
        if (!file.type || !file.type.startsWith('image/')) {
            this.showToast('Unsupported file', 'Please choose an image file (PNG, JPEG, GIF).', 'error');
            event.target.value = '';
            return;
        }
        const active = (this.versions || []).find((v) => v[F.VerIsActive]);
        if (!active) {
            this.showToast(
                'No active version',
                'Save the template first so a version exists, then upload the watermark.',
                'warning'
            );
            event.target.value = '';
            return;
        }
        this.isUploadingWatermark = true;
        try {
            const pct = parseInt(this.watermarkOpacityPct, 10) || 100;
            const baked = await this._bakeWatermarkOpacity(file, pct);
            const newCvId = await saveWatermarkImage({
                versionId: active.Id,
                fileName: baked.fileName,
                base64Data: baked.base64
            });
            this.editTemplateWatermarkCvId = newCvId;
            this.showToast('Success', 'Watermark uploaded.', 'success');
        } catch (err) {
            const msg =
                err && err.body && err.body.message ? err.body.message : (err && err.message) || 'Upload failed';
            this.showToast('Watermark upload failed', msg, 'error');
        } finally {
            this.isUploadingWatermark = false;
            event.target.value = '';
        }
    }

    async handleClearWatermark() {
        const active = (this.versions || []).find((v) => v[F.VerIsActive]);
        if (!active) {
            return;
        }
        this.isUploadingWatermark = true;
        try {
            await clearWatermarkImage({ versionId: active.Id });
            this.editTemplateWatermarkCvId = null;
            this.showToast('Removed', 'Watermark cleared.', 'success');
        } catch (err) {
            const msg = err && err.body && err.body.message ? err.body.message : (err && err.message) || 'Clear failed';
            this.showToast('Clear failed', msg, 'error');
        } finally {
            this.isUploadingWatermark = false;
        }
    }

    // ─── Chart pipeline helpers ────────────────────────────────────────────
    // Inlined here (rather than imported from c/docGenUtils) for the same
    // reason docGenRunner inlines them — cross-bundle export resolution can
    // serve a stale module proxy after the util gains a new export.

    _rasterizeSvgToPng(svgString, width, height, scale = 4) {
        return new Promise((resolve, reject) => {
            const blob = new Blob([svgString], { type: 'image/svg+xml' });
            const url = URL.createObjectURL(blob);
            const img = new Image();
            img.onload = () => {
                try {
                    const canvas = document.createElement('canvas');
                    canvas.width = width * scale;
                    canvas.height = height * scale;
                    const ctx = canvas.getContext('2d');
                    ctx.imageSmoothingEnabled = true;
                    ctx.imageSmoothingQuality = 'high';
                    ctx.fillStyle = '#ffffff';
                    ctx.fillRect(0, 0, canvas.width, canvas.height);
                    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                    URL.revokeObjectURL(url);
                    resolve(canvas.toDataURL('image/png').split(',')[1]);
                } catch (err) {
                    URL.revokeObjectURL(url);
                    reject(err);
                }
            };
            img.onerror = (err) => {
                URL.revokeObjectURL(url);
                reject(err instanceof Error ? err : new Error('SVG image load failed'));
            };
            img.src = url;
        });
    }

    async _prepareChartsForAdmin(templateId, recordId) {
        // Try the client-side path first, exactly as the runner does. Generate
        // Sample is what an author judges a template by, so it has to behave
        // like real generation — on the Apex path alone it cannot render a
        // chart over a large child list or a non-groupable field, and the
        // author would be shown an empty chart for a template that works
        // perfectly for end users.
        try {
            const ChartCtor = await this._ensureChartJsForAdmin();
            if (!ChartCtor) {
                console.warn('Portwood admin: Chart.js did not expose window.Chart; using the Apex chart path.');
            }
            if (ChartCtor) {
                const clientResult = await prepareChartsClientSide({ templateId, recordId, ChartCtor });
                if (clientResult) {
                    return clientResult;
                }
            }
        } catch (e) {
            console.warn('Portwood admin: client-side chart path failed; using Apex chart path', e);
        }

        try {
            const requests = await prepareChartImages({ templateId, recordId });
            if (!Array.isArray(requests) || requests.length === 0) {
                return { map: {}, cvIds: [] };
            }
            const map = {};
            const cvIds = [];
            for (const req of requests) {
                try {
                    // eslint-disable-next-line no-await-in-loop
                    const pngBase64 = await this._rasterizeSvgToPng(req.svgString, req.width, req.height);
                    // eslint-disable-next-line no-await-in-loop
                    const cvId = await uploadChartImage({
                        recordId,
                        signature: req.signature,
                        base64Png: pngBase64
                    });
                    if (cvId) {
                        map[req.signature] = cvId + '|' + req.width + 'x' + req.height;
                        cvIds.push(cvId);
                    }
                } catch (chartErr) {
                    console.warn('Portwood admin: chart prep failed for signature ' + req.signature, chartErr);
                }
            }
            return { map, cvIds };
        } catch (e) {
            console.warn('Portwood admin: prepareChartImages failed; charts will text-fallback', e);
            return { map: {}, cvIds: [] };
        }
    }

    async _ensureChartJsForAdmin() {
        if (window.Chart) {
            return window.Chart;
        }
        await loadScript(this, CHARTJS_RESOURCE);
        return window.Chart;
    }

    async _cleanupChartsForAdmin(cvIds) {
        if (!Array.isArray(cvIds) || cvIds.length === 0) {
            return;
        }
        try {
            await deleteChartImages({ cvIds });
        } catch (cleanupErr) {
            console.warn('Portwood admin: chart CV cleanup failed', cleanupErr);
        }
    }
}
