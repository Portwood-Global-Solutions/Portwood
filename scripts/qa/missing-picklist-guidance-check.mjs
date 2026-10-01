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

const TYPE_VALUE_HISTORY = { HTML: '1.66.0', Excel: '2.30.0', PDF: '3.03.0', Canvas: '3.54.0' };

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
        `This org's Type picklist is missing: ${all.map((v) => `${v} (added in v${TYPE_VALUE_HISTORY[v]})`).join(', ')}. ` +
        'That means the package upgrade did not fully apply its schema — a restricted ' +
        'picklist value never reaches an org that was already installed before that value ' +
        'existed, and no later upgrade brings it. ' +
        `Add the missing values to ${fields.join(' AND ')} in Setup — ` +
        (fields.length > 1
            ? 'BOTH fields are needed, because saving writes the type to the template and to its version. '
            : '') +
        'Until then those template types cannot be created.';
    return { has, message, fields };
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
    ok(g.message.includes('BOTH fields are needed'), 'and says explicitly that both are needed');
    ok(g.message.includes('Canvas (added in v3.54.0)'), 'and names the value with the version that introduced it');
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

console.log('\na fully upgraded org stays quiet');
{
    const g = guidance(FULL, FULL);
    ok(!g.has, 'no warning when both picklists are complete');
}

console.log('\nolder gaps still reported, and de-duplicated across the two fields');
{
    const g = guidance(['Word', 'PowerPoint', 'Excel'], ['Word', 'PowerPoint', 'Excel', 'HTML']);
    ok(g.message.includes('PDF (added in v3.03.0)'), 'PDF is reported');
    ok(g.message.includes('HTML (added in v1.66.0)'), 'HTML is reported');
    ok((g.message.match(/PDF \(added/g) || []).length === 1, 'and each value is listed once, not once per field');
}

console.log('\nwires not resolved yet must not raise a false alarm');
{
    ok(!guidance(null, null).has, 'null picklists (still loading) are silent');
    ok(!guidance([], []).has, 'empty picklists are silent');
}

console.log(fail ? `\n${fail} FAILED` : '\npicklist guidance OK');
process.exit(fail ? 1 : 0);
