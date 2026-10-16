/**
 * docGenTreeBuilder: V3 nodes the tree cannot edit survive an edit-and-save.
 *
 *   node scripts/qa/tree-builder-passthrough-check.mjs
 *
 * The builder rebuilds its tree from the base object's schema. A V3 node with
 * parentKeyField joins through a lookup on its parent record, a relationship that
 * schema does not list, so the loader used to skip it, and the next edit wrote the
 * config back without it. The node vanished, and its merge tags rendered blank, with
 * no error. The builder now keeps such nodes (and their children) verbatim and
 * re-emits them on every save; `single` round-trips on nodes it can edit.
 *
 * No org, no browser: the component source is loaded with the LWC decorators
 * stripped and the Apex schema calls stubbed.
 */
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const lwc = join(here, '../../force-app/main/default/lwc');
const dir = mkdtempSync(join(tmpdir(), 'treeb-'));

writeFileSync(join(dir, 'docGenUtils.mjs'), readFileSync(join(lwc, 'docGenUtils/docGenUtils.js'), 'utf8'));

let src = readFileSync(join(lwc, 'docGenTreeBuilder/docGenTreeBuilder.js'), 'utf8');
src = src
    .replace(/^import \{[^}]*\} from 'lwc';$/m, 'const { LightningElement } = globalThis.__lwc;')
    .replace(
        /^import (\w+) from '@salesforce\/apex\/DocGenController\.(\w+)';$/gm,
        (m, local, method) => `const ${local} = (args) => globalThis.__apex.${method}(args);`
    )
    .replace("from 'c/docGenUtils';", "from './docGenUtils.mjs';")
    .replace(/^\s*@(api|track)\s*$/gm, '')
    .replace(/@track\s+/g, '');
writeFileSync(join(dir, 'docGenTreeBuilder.mjs'), src);

// Minimal schema: a custom Project__c with an Opportunity lookup and a child item list.
const SCHEMA = {
    Project__c: {
        fields: ['Id', 'Name', 'Opportunity__c'],
        children: [
            {
                value: 'Project_Items__r',
                label: 'Items (Project_Item__c)',
                childObjectApiName: 'Project_Item__c',
                lookupField: 'Project__c'
            }
        ],
        parents: [{ value: 'Opportunity__r', label: 'Opportunity (Opportunity)', targetObject: 'Opportunity' }]
    },
    Project_Item__c: { fields: ['Id', 'Name', 'No__c'], children: [], parents: [] },
    Opportunity: { fields: ['Id', 'Name'], children: [], parents: [] }
};
const schemaOf = (o) => SCHEMA[o] || { fields: [], children: [], parents: [] };
globalThis.__apex = {
    getObjectFields: async ({ objectName }) =>
        schemaOf(objectName).fields.map((f) => ({ value: f, label: f + ' (' + f + ')', type: 'STRING' })),
    getChildRelationships: async ({ objectName }) => schemaOf(objectName).children,
    getParentRelationships: async ({ objectName }) => schemaOf(objectName).parents
};
globalThis.__lwc = {
    LightningElement: class {
        dispatchEvent(e) {
            (this.emitted ||= []).push(e.detail.queryConfig);
        }
    }
};
globalThis.CustomEvent = class {
    constructor(type, init) {
        this.type = type;
        this.detail = init.detail;
    }
};

const { default: DocGenTreeBuilder } = await import(pathToFileURL(join(dir, 'docGenTreeBuilder.mjs')).href);

let pass = 0;
let fail = 0;
const t = (name, ok, detail = '') => {
    if (ok) {
        pass++;
        console.log('  ok  ' + name);
    } else {
        fail++;
        console.log('  FAIL ' + name + (detail ? '  -> ' + detail : ''));
    }
};

const ocr = (id, alias, where) => ({
    id,
    object: 'OpportunityContactRole',
    parentNode: 'n0',
    relationshipName: 'OpportunityContactRoles',
    alias,
    lookupField: 'OpportunityId',
    parentKeyField: 'Opportunity__c',
    single: true,
    fields: ['Id', 'Role'],
    parentFields: ['Contact.Name'],
    where,
    orderBy: 'CreatedDate',
    limit: '1'
});
const CONFIG = {
    v: 3,
    root: 'Project__c',
    nodes: [
        {
            id: 'n0',
            object: 'Project__c',
            parentNode: null,
            lookupField: null,
            relationshipName: null,
            fields: ['Id', 'Name'],
            parentFields: ['Opportunity__r.Name']
        },
        {
            id: 'n1',
            object: 'Project_Item__c',
            parentNode: 'n0',
            relationshipName: 'Project_Items__r',
            lookupField: 'Project__c',
            fields: ['Name', 'No__c'],
            parentFields: [],
            orderBy: 'No__c'
        },
        ocr('n2', 'Primary', 'IsPrimary = true'),
        ocr('n3', 'Architect', "Role = 'Architect'"),
        // A child of a kept node: kept with it, re-parented to its new id.
        {
            id: 'n4',
            object: 'Task',
            parentNode: 'n3',
            relationshipName: 'Tasks',
            lookupField: 'WhoId',
            fields: ['Subject'],
            parentFields: []
        }
    ]
};

async function load(config) {
    const b = new DocGenTreeBuilder();
    b.selectedObject = 'Project__c';
    await new Promise((r) => setTimeout(r, 0));
    while (!b._rootLoaded) await new Promise((r) => setTimeout(r, 0));
    await b._parseIncoming(JSON.stringify(config));
    return b;
}

// The user ticks one more root field: the edit that used to drop the kept nodes.
async function editAndSave(b) {
    b.handleNodeFieldToggle({ stopPropagation() {}, detail: { path: 'root', fieldName: 'Opportunity__c' } });
    const emitted = b.emitted[b.emitted.length - 1];
    try {
        return JSON.parse(emitted);
    } catch (e) {
        // Fell back to V1 SOQL, which cannot hold V3-only nodes: report, don't crash.
        t('save stays V3 when the config needs it', false, emitted);
        return { nodes: [{ parentNode: null, fields: [] }] };
    }
}

const strip = (n) => {
    if (!n) return null;
    const { id, parentNode, ...rest } = n;
    return rest;
};

{
    const b = await load(CONFIG);
    const out = await editAndSave(b);
    const byAlias = (a) => out.nodes.find((n) => n.alias === a);
    const root = out.nodes.find((n) => n.parentNode === null);

    t('edit is applied', root.fields.includes('Opportunity__c'), JSON.stringify(root.fields));
    t('kept nodes survive the save', !!byAlias('Primary') && !!byAlias('Architect'));
    t(
        'kept nodes are byte-for-byte unchanged apart from id/parentNode',
        JSON.stringify(strip(byAlias('Primary'))) === JSON.stringify(strip(CONFIG.nodes[2])) &&
            JSON.stringify(strip(byAlias('Architect'))) === JSON.stringify(strip(CONFIG.nodes[3])),
        JSON.stringify(byAlias('Primary') ?? null)
    );
    t('kept nodes hang off the new root id', byAlias('Primary')?.parentNode === root.id);
    const task = out.nodes.find((n) => n.object === 'Task');
    t(
        'a kept node keeps its own children',
        !!task && task.parentNode === byAlias('Architect')?.id,
        JSON.stringify(task)
    );
    const ids = out.nodes.map((n) => n.id);
    t('node ids stay unique', new Set(ids).size === ids.length, ids.join(','));
    const items = out.nodes.find((n) => n.relationshipName === 'Project_Items__r');
    t('editable child is still emitted normally', !!items && items.orderBy === 'No__c' && items.parentNode === root.id);
    t(
        'builder reports what it kept',
        b.hasKeptNodes && b.keptNodeLabels === 'Primary, Architect, Tasks',
        b.keptNodeLabels
    );

    // Saving the saved config again changes nothing.
    const b2 = await load(out);
    const again = JSON.parse(b2._buildQueryString());
    t('re-loading the saved config is stable', JSON.stringify(again) === JSON.stringify(out));
}

{
    // `single` on a node the tree CAN edit: round-trips, and forces V3 (V1 cannot say it).
    const cfg = { v: 3, root: 'Project__c', nodes: [CONFIG.nodes[0], { ...CONFIG.nodes[1], single: true }] };
    const b = await load(cfg);
    const out = await editAndSave(b);
    const items = out.nodes.find((n) => n.relationshipName === 'Project_Items__r');
    t('single round-trips on an editable node', items && items.single === true, JSON.stringify(items));
}

{
    // No kept nodes, no alias, no single: still the V1 SOQL string it always emitted.
    const cfg = { v: 3, root: 'Project__c', nodes: [CONFIG.nodes[0], CONFIG.nodes[1]] };
    const b = await load(cfg);
    b.handleNodeFieldToggle({ stopPropagation() {}, detail: { path: 'root', fieldName: 'Opportunity__c' } });
    const emitted = b.emitted[b.emitted.length - 1];
    t(
        'plain trees still emit V1',
        !emitted.trim().startsWith('{') && emitted.includes('FROM Project_Items__r'),
        emitted
    );
    t('nothing reported as kept', !b.hasKeptNodes);
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail > 0) {
    process.exit(1);
}
console.log('tree builder pass-through OK');
