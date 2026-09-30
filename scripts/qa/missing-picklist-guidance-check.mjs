/**
 * Designer — the missing-Type-picklist warning names EVERY field that needs a value.
 *
 *   node scripts/qa/missing-picklist-guidance-check.mjs
 *
 * Issue #303. imax-vaughn upgraded to v3.56, found the `Canvas` type absent,
 * followed the warning exactly — "add the missing values to the Portwood
 * Template > Type field in Setup" — and STILL could not save:
 *
 *   "Type: bad value for restricted picklist field: Canvas"
 *
 * Saving writes Type__c on DocGen_Template__c AND on DocGen_Template_Version__c.
 * Both are restricted picklists carrying the same value set, verified against a
 * fresh org:
 *
 *   DocGen_Template__c.Type__c         restricted=true  (Word … Canvas)
 *   DocGen_Template_Version__c.Type__c restricted=true  (Word … Canvas)
 *
 * The warning only ever read the first one, so an admin could do exactly what it
 * said and hit the field it did not mention. Dave measured the propagation rule
 * in ca57070: a restricted picklist value never reaches an org installed before
 * that value existed, and no later upgrade brings it — so either field can be
 * short, independently, depending on when that org was installed.
 *
 * This asserts the guidance, which is the whole fix: Apex cannot add a picklist
 * value (the Apex Metadata API exposes only CustomMetadata and Layout), so
 * telling the admin precisely what to do is all the product can do.
 */

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

const TYPE_VALUE_HISTORY = {
    Word: '1.0',
    PowerPoint: '1.0',
    Excel: '1.5x',
    HTML: '1.61.0',
    PDF: '3.03.0',
    Canvas: '3.54.0'
};

/** Mirrors the docGenAdmin getters. */
function guidance(orgTemplateValues, orgVersionValues) {
    const missingOn = (vals) =>
        !vals || !vals.length ? [] : Object.keys(TYPE_VALUE_HISTORY).filter((v) => !vals.includes(v));
    const onTemplate = missingOn(orgTemplateValues);
    const onVersion = missingOn(orgVersionValues);
    const has = onTemplate.length > 0 || onVersion.length > 0;
    const all = Array.from(new Set([...onTemplate, ...onVersion]));
    const fields = [];
    if (onTemplate.length) fields.push('Portwood Template > Type');
    if (onVersion.length) fields.push('Portwood Template Version > Type');
    const message =
        `Missing Type picklist value: ${all.join(', ')}. ` +
        `${all.includes('Canvas') ? 'Canvas must be active on ' : 'Add or activate the missing value on '}` +
        `${fields.join(' and ')}. ` +
        'Open the field link below, add or activate the value in Picklist Values, then click Re-check.';
    return { has, message, fields };
}

/** Mirrors createTemplate's restricted-picklist preflight. */
function preflightCreate(templateType, orgTemplateValues, orgVersionValues) {
    const fields = [];
    if (orgTemplateValues && orgTemplateValues.length && !orgTemplateValues.includes(templateType)) {
        fields.push('Portwood Template > Type');
    }
    if (orgVersionValues && orgVersionValues.length && !orgVersionValues.includes(templateType)) {
        fields.push('Portwood Template Version > Type');
    }
    if (!fields.length) return null;

    const versionSuffix = TYPE_VALUE_HISTORY[templateType] ? ` (added in v${TYPE_VALUE_HISTORY[templateType]})` : '';
    const fieldText = fields.join(fields.length > 1 ? ' AND ' : '');
    return (
        `This org cannot create "${templateType}" templates because ` +
        `"${templateType}"${versionSuffix} is missing from ${fieldText}. ` +
        'Add or reactivate that picklist value in Setup, then click Re-check.'
    );
}

const FULL = ['Word', 'PowerPoint', 'Excel', 'HTML', 'PDF', 'Canvas'];
const NO_CANVAS = ['Word', 'PowerPoint', 'Excel', 'HTML', 'PDF'];

console.log('\nthe reported case: Canvas missing from BOTH picklists');
{
    const g = guidance(NO_CANVAS, NO_CANVAS);
    ok(g.has, 'the warning fires');
    ok(g.fields.length === 2, 'and names both fields');
    ok(g.message.includes('Portwood Template > Type'), 'names the template field');
    ok(g.message.includes('Portwood Template Version > Type'), 'names the version field');
    ok(g.message.includes('Canvas must be active on'), 'says Canvas must be active');
    ok(g.message.includes('Open the field link below'), 'gives the short admin action');
}

console.log('\nthe reported case, halfway fixed — this is where imax-vaughn got stuck');
{
    // They added Canvas to the template object, as the old message told them to.
    const g = guidance(FULL, NO_CANVAS);
    ok(g.has, 'the warning STILL fires after fixing only the template field');
    ok(g.fields.length === 1, 'and now names exactly one remaining field');
    ok(g.message.includes('Portwood Template Version > Type'), 'the version field — the one the old message never mentioned');
    ok(!g.message.includes('Portwood Template > Type in Setup'), 'and no longer points at the field already fixed');
}

console.log('\nthe reverse asymmetry is handled too');
{
    const g = guidance(NO_CANVAS, FULL);
    ok(g.has, 'warns when only the template field is short');
    ok(g.fields.length === 1 && g.fields[0] === 'Portwood Template > Type', 'and names just that one');
}

console.log('\ncreate preflight blocks Canvas with the exact object that is missing it');
{
    const versionOnly = preflightCreate('Canvas', FULL, NO_CANVAS);
    ok(!!versionOnly, 'blocks before the version insert can fail generically');
    ok(versionOnly.includes('Portwood Template Version > Type'), 'names the version field when only it is missing Canvas');
    ok(!versionOnly.includes('Portwood Template > Type AND'), 'does not blame the template field after it is fixed');

    const templateOnly = preflightCreate('Canvas', NO_CANVAS, FULL);
    ok(!!templateOnly, 'also blocks when only the template field is missing Canvas');
    ok(templateOnly.includes('Portwood Template > Type'), 'names the template field');
    ok(!templateOnly.includes('Portwood Template Version > Type'), 'does not blame the version field when it is complete');

    const both = preflightCreate('Canvas', NO_CANVAS, NO_CANVAS);
    ok(!!both, 'blocks when both fields are missing Canvas');
    ok(both.includes('Portwood Template > Type AND Portwood Template Version > Type'), 'names both fields together');
    ok(both.includes('"Canvas" (added in v3.54.0)'), 'names Canvas with the release that introduced it');
}

console.log('\na fully upgraded org stays quiet');
{
    const g = guidance(FULL, FULL);
    ok(!g.has, 'no warning when both picklists are complete');
}

console.log('\nolder gaps still reported, and de-duplicated across the two fields');
{
    const g = guidance(['Word', 'PowerPoint', 'Excel'], ['Word', 'PowerPoint', 'Excel', 'HTML']);
    ok(g.message.includes('PDF'), 'PDF is reported');
    ok(g.message.includes('HTML'), 'HTML is reported');
    ok((g.message.match(/PDF/g) || []).length === 1, 'and each value is listed once, not once per field');
}

console.log('\nwires not resolved yet must not raise a false alarm');
{
    ok(!guidance(null, null).has, 'null picklists (still loading) are silent');
    ok(!guidance([], []).has, 'empty picklists are silent');
}

console.log(fail ? `\n${fail} FAILED` : '\npicklist guidance OK');
process.exit(fail ? 1 : 0);
