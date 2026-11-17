#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

const scopes = [
    [
        'templates',
        'Template',
        [
            'API_Name',
            'Base_Object_API',
            'Brand',
            'Test_Record_Id',
            'Specific_Record_Ids',
            'Required_Permission_Sets',
            'Record_Filter'
        ]
    ],
    ['assets', 'Asset', ['Asset_Key', 'Asset_Type']],
    ['fonts', 'Font_Face', ['API_Name', 'Asset', 'Revision_Key', 'Status']],
    ['brands', 'Brand', ['Logo_Asset_Key', 'OWA_Id']],
    ['emailTemplates', 'Email_Template', ['Type', 'Brand', 'Logo_Asset_Key']],
    ['settings', 'Settings', ['Experience_Site_Url', 'Signature_OWA_Id', 'AI_Provider_Class', 'AI_Prompt_Template']]
];

function salesforce(org, args) {
    let response;
    try {
        response = JSON.parse(
            execFileSync('sf', [...args, '--target-org', org, '--json'], {
                encoding: 'utf8',
                maxBuffer: 64 * 1024 * 1024,
                stdio: ['ignore', 'pipe', 'pipe']
            })
        );
    } catch (error) {
        try {
            response = JSON.parse(error.stdout);
        } catch {
            throw new Error(
                'Salesforce CLI request failed. Confirm sf is installed and the org alias is authenticated.'
            );
        }
    }
    if (response.status !== 0) throw new Error(response.message || 'Salesforce CLI request failed.');
    return response.result;
}

function inspect(org) {
    const response = salesforce(org, ['sobject', 'list', '--sobject', 'custom']);
    const objects = Array.isArray(response) ? response : response.sobjects;
    if (!Array.isArray(objects)) throw new Error('Unexpected Salesforce object list.');
    const prefix = objects.includes('portwoodglobal__DocGen_Template__c')
        ? 'portwoodglobal__'
        : objects.includes('DocGen_Template__c')
          ? ''
          : null;
    if (prefix === null) throw new Error('No supported Portwood template object found in ' + org + '.');
    const records = {};
    const unavailableFields = {};
    for (const [key, object, fields] of scopes) {
        const apiName = prefix + 'DocGen_' + object + '__c';
        if (!objects.includes(apiName)) {
            records[key] = null;
            continue;
        }
        const describe = salesforce(org, ['sobject', 'describe', '--sobject', apiName]);
        const available = new Set(describe.fields.map((f) => f.name));
        const selected = fields.filter((field) => available.has(prefix + field + '__c'));
        const missing = fields.filter((field) => !selected.includes(field));
        if (missing.length) unavailableFields[key] = missing;
        const columns = ['Id', 'Name', ...selected.map((field) => prefix + field + '__c')];
        const result = salesforce(org, [
            'data',
            'query',
            '--query',
            'SELECT ' + columns.join(', ') + ' FROM ' + apiName + ' ORDER BY Id'
        ]);
        if (result.totalSize !== result.records.length) throw new Error('Incomplete inventory for ' + apiName + '.');
        if (!result.done) throw new Error('Incomplete inventory for ' + apiName + '.');
        records[key] = result.records.map((row) =>
            Object.fromEntries([
                ['id', row.Id],
                ['name', row.Name],
                ...selected.map((field) => [field, row[prefix + field + '__c']])
            ])
        );
    }
    const orgRecord = salesforce(org, ['data', 'query', '--query', 'SELECT Id, IsSandbox FROM Organization LIMIT 1'])
        .records[0];
    return {
        schemaVersion: 1,
        kind: 'portwood-configuration-inventory',
        orgId: orgRecord.Id,
        isSandbox: orgRecord.IsSandbox,
        namespace: prefix,
        unavailableFields,
        records
    };
}

function identity(kind, row, brands) {
    switch (kind) {
        case 'templates':
        case 'fonts':
            return row.API_Name;
        case 'assets':
            return row.Asset_Key;
        case 'brands':
            return row.name;
        case 'emailTemplates':
            return row.Type && (!row.Brand || brands.get(row.Brand))
                ? JSON.stringify([row.Type, row.Brand ? brands.get(row.Brand) : null])
                : null;
        default:
            return null;
    }
}

function index(rows, key) {
    const result = new Map();
    for (const row of rows || []) {
        const identity = key(row);
        if (!identity) continue;
        const normalized = identity.trim().toLowerCase();
        const group = result.get(normalized) || [];
        group.push(row);
        result.set(normalized, group);
    }
    return result;
}

function dependencies(row, kind, inventory, brands) {
    const warnings = [];
    const assets = inventory.records.assets;
    if (row.Brand && !brands.has(row.Brand)) warnings.push('Sending brand is missing from this inventory.');
    if (row.Asset && !assets?.some((asset) => asset.id === row.Asset))
        warnings.push('Font asset is missing from this inventory.');
    if (row.Logo_Asset_Key && !assets?.some((asset) => asset.Asset_Key === row.Logo_Asset_Key)) {
        warnings.push('Logo asset is missing from this inventory.');
    }
    if (row.OWA_Id || row.Signature_OWA_Id)
        warnings.push('Map the org-wide email address to a verified target sender.');
    if (row.Experience_Site_Url) warnings.push('Map the signing-site URL to the target org.');
    if (row.Test_Record_Id || row.Specific_Record_Ids) warnings.push('Map sample and allowlisted record IDs.');
    if (row.Required_Permission_Sets) warnings.push('Check target permission-set API names.');
    if (row.Record_Filter) warnings.push('Review the record filter on the target object.');
    if (row.AI_Provider_Class || row.AI_Prompt_Template)
        warnings.push('Verify the target Agentforce provider and prompt template.');
    if (kind === 'templates')
        warnings.push('Check query/schema compatibility and dependencies inside the template bundle.');
    return warnings;
}

export function plan(source, target) {
    const sourceBrands = new Map((source.records.brands || []).map((row) => [row.id, row.name]));
    const targetBrands = new Map((target.records.brands || []).map((row) => [row.id, row.name]));
    const items = [];
    const inventories = [];
    for (const [kind] of scopes) {
        const sourceRows = source.records[kind];
        const targetRows = target.records[kind];
        if (!Array.isArray(sourceRows) || !Array.isArray(targetRows)) {
            inventories.push({
                kind,
                sourceAvailable: Array.isArray(sourceRows),
                targetAvailable: Array.isArray(targetRows)
            });
        }
        const sourceIndex = index(sourceRows, (row) => identity(kind, row, sourceBrands));
        const targetIndex = index(targetRows, (row) => identity(kind, row, targetBrands));
        for (const row of sourceRows || []) {
            const key = identity(kind, row, sourceBrands);
            const normalized = key?.trim().toLowerCase();
            const matches = normalized ? targetIndex.get(normalized) || [] : [];
            let status = 'create';
            if (kind === 'settings') status = 'manual-mapping';
            else if (!targetRows) status = 'target-resource-unavailable';
            else if (!normalized) status = 'missing-key';
            else if (sourceIndex.get(normalized).length > 1 || matches.length > 1) status = 'ambiguous-key';
            else if (matches.length === 1) status = 'conflict';
            items.push({
                kind: kind === 'assets' && row.Asset_Type === 'HTMLSnippet' ? 'snippets' : kind,
                sourceId: row.id,
                name: row.name,
                key,
                status,
                targetIds: matches.map((match) => match.id),
                warnings: dependencies(row, kind, source, sourceBrands)
            });
        }
    }
    return {
        schemaVersion: 1,
        kind: 'portwood-configuration-plan',
        sourceOrg: source.orgId,
        targetOrg: target.orgId,
        inventories,
        unavailableFields: { source: source.unavailableFields || {}, target: target.unavailableFields || {} },
        items
    };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    const [command, ...args] = process.argv.slice(2);
    try {
        const { values } = parseArgs({
            args,
            options: { org: { type: 'string' }, source: { type: 'string' }, target: { type: 'string' } }
        });
        if (command === 'inventory' && values.org && !values.source && !values.target) {
            console.log(JSON.stringify(inspect(values.org), null, 2));
        } else if (command === 'plan' && values.source && values.target && !values.org) {
            const source = JSON.parse(readFileSync(values.source, 'utf8'));
            if (source.schemaVersion !== 1 || source.kind !== 'portwood-configuration-inventory' || !source.records) {
                throw new Error('Source must be a Portwood configuration inventory (schema version 1).');
            }
            const target = inspect(values.target);
            if (source.orgId === target.orgId) throw new Error('Source and target resolve to the same Salesforce org.');
            console.log(JSON.stringify(plan(source, target), null, 2));
        } else {
            throw new Error(
                'Usage: portwood.mjs inventory --org <alias> | plan --source <inventory.json> --target <alias>'
            );
        }
    } catch (error) {
        console.error(error.message);
        process.exitCode = 1;
    }
}
