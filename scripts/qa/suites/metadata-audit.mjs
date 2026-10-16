/**
 * METADATA AUDIT — the things no functional test ever notices.
 *
 * A field can exist, be written by Apex, be covered by unit tests, and still be
 * invisible to the admin who needs it, because nobody put it on the page layout
 * or granted it on the permission set. Those defects survive every other kind of
 * testing and are only found by a customer asking "where is that setting?".
 *
 * This suite reads the repo's own metadata — no org required — and checks:
 *
 *   - every custom field is on its object's page layout (or explicitly waived)
 *   - every custom field is granted on DocGen_Admin
 *   - every object with fields has a layout at all
 *   - LWCs exposed to admins are surfaced somewhere (tab or app page)
 *   - fields carry a description (an admin-facing help string)
 *
 * WAIVERS: some fields genuinely should not be on a layout — internal snapshots,
 * long-text config blobs edited through a purpose-built UI. Those are listed
 * explicitly below with a REASON, so the waiver is a decision on the record
 * rather than a silent gap. Anything not waived and not on a layout is a finding.
 */
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { check, skip, suiteResult, SEVERITY } from '../lib/report.mjs';
// Shared with record-pages — see lib/field-policy.mjs for why.
import { visibilityWaiver, isForbidden, LAYOUT_FORBIDDEN as SHARED_FORBIDDEN } from '../lib/field-policy.mjs';

const ROOT = new URL('../../../force-app/main/default/', import.meta.url).pathname;

/**
 * Fields deliberately absent from a page layout, with the reason. Keyed
 * Object.Field. Review this list when a field moves UI — a stale waiver hides a
 * real gap.
 */
const LAYOUT_WAIVERS = {
    // Edited through the Designer / Template editor, not as a raw field. Putting a
    // 100KB HTML blob on a layout is worse than leaving it off.
    'DocGen_Template__c.Header_Html__c': 'edited in the Designer header band',
    'DocGen_Template__c.Footer_Html__c': 'edited in the Designer footer band',
    'DocGen_Template__c.Query_Config__c': 'edited by the visual query builder',
    'DocGen_Template__c.Form_Fields_Config__c': 'edited by the Signer Inputs tab',
    'DocGen_Template__c.Specific_Record_Ids__c': 'set by the sharing panel',
    'DocGen_Template__c.Record_Filter__c': 'set by the filter builder',
    // Platform events have no layouts at all.
    DocGen_Signature_PDF__e: 'platform event',
    DocGen_Guest_Render__e: 'platform event',
    DocGen_Field_Writeback__e: 'platform event',
    // Custom metadata type — laid out by its own MDT UI.
    DocGen_Button__mdt: 'custom metadata type'
};

/**
 * Fields that must NEVER be on a layout — secrets and internal snapshots. Putting
 * a token or a PIN hash on a page is a security defect, not a convenience.
 */
const LAYOUT_FORBIDDEN = new Set([
    'DocGen_Signature_Request__c.Secure_Token__c',
    'DocGen_Signature_Request__c.Signature_Data__c',
    'DocGen_Signature_Request__c.Snapshot_Hash__c',
    'DocGen_Signature_Request__c.Render_Data_Snapshot__c',
    'DocGen_Signature_Request__c.Frozen_Document_CV_Id__c',
    'DocGen_Signer__c.Secure_Token__c',
    'DocGen_Signer__c.PIN_Hash__c',
    'DocGen_Signer__c.Field_Data_Json__c',
    'DocGen_Job__c.Data_Cache_CV__c',
    'DocGen_Job__c.Giant_Query_Config__c'
]);

/** Objects whose records are only ever managed through a purpose-built UI. */
const NO_LAYOUT_EXPECTED = new Set([
    'DocGen_Signature_PDF__e',
    'DocGen_Guest_Render__e',
    'DocGen_Field_Writeback__e',
    'DocGen_Button__mdt',
    'DocGen_Settings__c', // hierarchy custom setting — no page layout
    'Product2' // standard object we only extend
]);

/** Objects that are Hierarchy/List custom settings, detected from their XML. */
const CUSTOM_SETTINGS = new Set();

function xmlValues(xml, tag) {
    const out = [];
    const re = new RegExp(`<${tag}\\s*>([^<]*)</${tag}\\s*>`, 'g');
    let m;
    while ((m = re.exec(xml)) !== null) out.push(m[1].trim());
    return out;
}

export async function run() {
    const checks = [];
    const objectsDir = join(ROOT, 'objects');
    if (!existsSync(objectsDir)) {
        return suiteResult('metadata-audit', 'Metadata', [
            skip('metadata present', 'no objects directory found', SEVERITY.BLOCKER)
        ]);
    }

    // --- index the layouts once ------------------------------------------------
    const layoutsDir = join(ROOT, 'layouts');
    const layoutFieldsByObject = {};
    if (existsSync(layoutsDir)) {
        for (const f of readdirSync(layoutsDir)) {
            const obj = f.split('-')[0];
            const xml = readFileSync(join(layoutsDir, f), 'utf8');
            layoutFieldsByObject[obj] = (layoutFieldsByObject[obj] || []).concat(xmlValues(xml, 'field'));
        }
    }

    // --- index the admin permission set ---------------------------------------
    const permPath = join(ROOT, 'permissionsets', 'DocGen_Admin.permissionset-meta.xml');
    let adminFields = new Set();
    if (existsSync(permPath)) {
        const xml = readFileSync(permPath, 'utf8');
        adminFields = new Set(xmlValues(xml, 'field'));
    } else {
        checks.push(skip('DocGen_Admin permission set present', 'file not found', SEVERITY.BLOCKER));
    }

    const objects = readdirSync(objectsDir).filter((o) => existsSync(join(objectsDir, o, 'fields')));

    // Custom settings behave differently for both layouts and field permissions.
    for (const obj of objects) {
        const objMeta = join(objectsDir, obj, `${obj}.object-meta.xml`);
        if (existsSync(objMeta) && /<customSettingsType>/.test(readFileSync(objMeta, 'utf8'))) {
            CUSTOM_SETTINGS.add(obj);
            NO_LAYOUT_EXPECTED.add(obj);
        }
    }

    for (const obj of objects) {
        const fieldFiles = readdirSync(join(objectsDir, obj, 'fields'));
        const fields = fieldFiles.map((f) => f.replace('.field-meta.xml', ''));
        const onLayout = new Set(layoutFieldsByObject[obj] || []);

        // Does the object have a layout at all?
        if (!NO_LAYOUT_EXPECTED.has(obj)) {
            checks.push(
                check(
                    `${obj} has a page layout`,
                    (layoutFieldsByObject[obj] || []).length > 0,
                    (layoutFieldsByObject[obj] || []).length ? '' : 'no layout file references this object',
                    SEVERITY.MAJOR
                )
            );
        }

        for (const field of fields) {
            const key = `${obj}.${field}`;
            const objWaived = LAYOUT_WAIVERS[obj];
            const waived = LAYOUT_WAIVERS[key] || objWaived || visibilityWaiver(obj, field);

            // A secret on a page layout is a defect in the OTHER direction.
            if (isForbidden(obj, field) || LAYOUT_FORBIDDEN.has(key)) {
                checks.push(
                    check(
                        `${key} is kept OFF the page layout`,
                        !onLayout.has(field),
                        onLayout.has(field) ? 'a token, hash or internal snapshot is exposed on a page layout' : '',
                        SEVERITY.BLOCKER
                    )
                );
                continue;
            }

            // --- on the layout? ---
            if (!NO_LAYOUT_EXPECTED.has(obj) && !waived) {
                checks.push(
                    check(
                        `${obj}.${field} is on the page layout`,
                        onLayout.has(field),
                        onLayout.has(field)
                            ? ''
                            : `field exists but no layout shows it — an admin cannot see or set it. Add to layouts/${obj}-*.layout-meta.xml, or waive it in metadata-audit.mjs with a reason.`,
                        SEVERITY.MAJOR
                    )
                );
            }

            // --- granted to admins? ---
            // Formula/auto-number/system fields cannot be granted, so read the type.
            const fieldXml = readFileSync(join(objectsDir, obj, 'fields', `${field}.field-meta.xml`), 'utf8');
            const type = (xmlValues(fieldXml, 'type')[0] || '').trim();
            const isFormula = /<formula>/.test(fieldXml);
            const isRequired = /<required>true<\/required>/.test(fieldXml);
            // MasterDetail is implicitly readable and CANNOT be granted on a
            // permission set — flagging it is a false positive, and a report that
            // cries wolf gets ignored, which is worse than no report.
            const grantable =
                !isFormula && type !== 'AutoNumber' && type !== 'Summary' && type !== 'MasterDetail' && !isRequired;
            // Hierarchy custom settings are not granted through field permissions.
            const isCustomSetting = CUSTOM_SETTINGS.has(obj);
            if (grantable && !isCustomSetting && obj.endsWith('__c') && adminFields.size) {
                const granted = adminFields.has(`${obj}.${field}`);
                checks.push(
                    check(
                        `${obj}.${field} is granted on DocGen_Admin`,
                        granted,
                        granted
                            ? ''
                            : `not in DocGen_Admin.permissionset-meta.xml — admins get "insufficient access" on any UI that writes it`,
                        SEVERITY.MAJOR
                    )
                );
            }

            // --- described? ---
            const described = /<description\s*>/.test(fieldXml) || /<inlineHelpText\s*>/.test(fieldXml);
            checks.push(
                check(
                    `${obj}.${field} has a description or help text`,
                    described,
                    described ? '' : 'no <description> or <inlineHelpText> — the admin has no idea what it does',
                    SEVERITY.MINOR
                )
            );
        }
    }

    // --- LWCs that admins are meant to reach ----------------------------------
    const lwcDir = join(ROOT, 'lwc');
    const tabsDir = join(ROOT, 'tabs');
    if (existsSync(lwcDir)) {
        const tabXml = existsSync(tabsDir)
            ? readdirSync(tabsDir)
                  .map((f) => readFileSync(join(tabsDir, f), 'utf8'))
                  .join('\n')
            : '';
        for (const c of readdirSync(lwcDir)) {
            const metaPath = join(lwcDir, c, `${c}.js-meta.xml`);
            if (!existsSync(metaPath)) continue;
            const meta = readFileSync(metaPath, 'utf8');
            const exposed = /<isExposed>true<\/isExposed>/.test(meta);
            if (!exposed) continue;
            const targets = xmlValues(meta, 'target');
            checks.push(
                check(
                    `${c} is exposed and declares at least one target`,
                    targets.length > 0,
                    targets.length
                        ? targets.join(', ')
                        : 'isExposed=true but no <target> — it cannot be placed anywhere',
                    SEVERITY.MAJOR
                )
            );
            // An app-page component with no tab is unreachable unless an admin
            // hand-builds a page for it.
            if (targets.includes('lightning__AppPage')) {
                const reachable = tabXml.includes(c) || tabXml.length === 0;
                checks.push(
                    check(
                        `${c} (app page) is reachable from a tab`,
                        reachable,
                        reachable ? '' : 'no tab references it — reachable only via a hand-built Lightning page',
                        SEVERITY.MINOR
                    )
                );
            }
        }
    }

    return suiteResult('metadata-audit', 'Metadata', checks);
}
