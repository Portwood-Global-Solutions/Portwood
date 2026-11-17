import { Org } from '@salesforce/core';
import { readFileSync } from 'node:fs';
import { inspect, plan } from './portwood.mjs';

const operations = new Map([
    ['assets', 'asset'],
    ['fonts', 'font'],
    ['snippets', 'snippet'],
    ['brands', 'brand'],
    ['emailTemplates', 'email'],
    ['templates', 'template'],
    ['settings', 'settings']
]);
const maxPayload = 1500000;

async function rest(connection, inventory, endpoint, payload) {
    const namespace = inventory.namespace ? inventory.namespace.slice(0, -2) + '/' : '';
    const url = '/services/apexrest/' + namespace + 'portwood/migration/v1/' + endpoint;
    const request = {
        method: payload === undefined ? 'GET' : 'POST',
        url,
        headers: { Accept: 'application/json' }
    };
    if (payload !== undefined) {
        request.headers['Content-Type'] = 'application/json';
        request.body = JSON.stringify(payload);
    }
    try {
        return await connection.request(request);
    } catch (error) {
        throw new Error(error.message || 'Salesforce request failed for ' + endpoint + '.');
    }
}

function mapOrDeferBrand(payload, requested, sourceBrands, target) {
    if (!payload.brandId) return null;
    if (requested) {
        if (!target.records.brands?.some((brand) => brand.id === requested)) {
            throw new Error('The mapped destination brand is not readable.');
        }
        payload.brandId = requested;
        return null;
    }
    if (!sourceBrands.has(payload.brandId)) {
        throw new Error('Select the source brand for migration or provide a destination brand ID.');
    }
    return payload.brandId;
}

function templatePayload(bundle, requested) {
    const template = bundle.template;
    if (template.Test_Record_Id__c && !Object.hasOwn(requested, 'testRecordId')) {
        throw new Error('Map the template sample record explicitly, or set testRecordId to null.');
    }
    if (template.Specific_Record_Ids__c && !requested.specificRecordIds) {
        throw new Error('Map the template record allowlist to prevent widening access.');
    }
    if (template.Required_Permission_Sets__c && !requested.requiredPermissionSets) {
        throw new Error('Map the required permission sets to prevent changing the template audience.');
    }
    if (template.Record_Filter__c && !requested.recordFilter) {
        throw new Error('Review and map the record filter for the destination org.');
    }
    if (requested.requiredPermissionSets) template.Required_Permission_Sets__c = requested.requiredPermissionSets;
    if (requested.recordFilter) template.Record_Filter__c = requested.recordFilter;
    if (Object.hasOwn(requested, 'testRecordId')) template.Test_Record_Id__c = requested.testRecordId;
    if (requested.specificRecordIds) template.Specific_Record_Ids__c = requested.specificRecordIds;
    return bundle;
}

function applyMappings(resource, payload, item, mappings, selectedBrands, target) {
    if (resource === 'font') {
        if (mappings.fonts?.[item.key]?.hostingRightsConfirmed !== true) {
            throw new Error('Confirm the destination hosting and embedding rights for this font in the mappings.');
        }
        return null;
    }
    if (resource === 'settings') {
        if (mappings.settings?.replace !== true) {
            throw new Error('Set settings.replace to true to apply org-wide signing settings.');
        }
        const targetKeys = {
            Experience_Site_Url__c: 'signingSiteUrl',
            Signature_OWA_Id__c: 'owaId',
            Signature_Email_Logo_Url__c: 'logoUrl'
        };
        for (const [field, key] of Object.entries(targetKeys)) {
            if (payload[field] && !Object.hasOwn(mappings.settings, key)) {
                throw new Error('Map settings.' + key + ' to a target value or null.');
            }
            if (Object.hasOwn(mappings.settings, key)) payload[field] = mappings.settings[key];
        }
        // The settings controller applies the same default as the UI.
        payload.Signature_Reminder_Hours__c ||= 24;
        return null;
    }
    if (resource === 'template') {
        const requested = mappings.templates?.[item.key] || {};
        templatePayload(payload, requested);
        return mapOrDeferBrand(payload, requested.brandId, selectedBrands, target);
    }
    if (resource === 'brand' || resource === 'email') {
        const requested =
            resource === 'brand' ? mappings.brands?.[item.key] || {} : mappings.emailTemplates?.[item.key] || {};
        if (resource === 'brand' && payload.owaId && !requested.owaId) {
            throw new Error('Map the org-wide sender address to the destination org.');
        }
        if (requested.owaId) payload.owaId = requested.owaId;
        if (payload.logoUrl && !Object.hasOwn(requested, 'logoUrl')) {
            throw new Error('Map the organization-specific logo URL explicitly, or set logoUrl to null.');
        }
        if (Object.hasOwn(requested, 'logoUrl')) payload.logoUrl = requested.logoUrl;
        return mapOrDeferBrand(payload, requested.brandId, selectedBrands, target);
    }
    return null;
}

function stableJson(value) {
    if (Array.isArray(value)) return value.map(stableJson);
    if (value === null || typeof value !== 'object') return value;
    return Object.fromEntries(
        Object.keys(value)
            .sort()
            .map((key) => [key, stableJson(value[key])])
    );
}

function equivalent(resource, source, target) {
    if (resource === 'font') {
        const exact = ({ status, ...metadata }) => metadata;
        return equivalent('asset', exact(source), exact(target));
    }
    if (resource !== 'template') return JSON.stringify(stableJson(source)) === JSON.stringify(stableJson(target));
    if (source.assets?.length || target.assets?.length) return false;
    const templateContent = (bundle) => ({
        template: bundle.template,
        brandId: bundle.brandId,
        extension: bundle.templateFile.fileExtension,
        body: bundle.templateFile.base64,
        savedQueries: (bundle.savedQueries || []).map((query) => JSON.stringify(stableJson(query))).sort()
    });
    return JSON.stringify(stableJson(templateContent(source))) === JSON.stringify(stableJson(templateContent(target)));
}

function assertVisibleDependencies(resource, payload, selected, target) {
    const text = [];
    if (resource === 'template') {
        text.push(payload.template.Header_Html__c, payload.template.Footer_Html__c);
        if (['html', 'htm'].includes(payload.templateFile.fileExtension?.toLowerCase())) {
            text.push(Buffer.from(payload.templateFile.base64, 'base64').toString('utf8'));
        }
    } else if (resource === 'snippet') {
        text.push(payload.html);
    } else if (resource === 'email') {
        text.push(payload.bodyHtml);
    }
    if (payload.logoAssetKey) text.push('{%asset:' + payload.logoAssetKey + '}');
    const keys = text.join(' ').matchAll(/\{%\s*(asset|snippet|font):([a-z0-9_-]+)(?::([^}]+))?\}/gi);
    for (const [, tag, rawKey, revision] of keys) {
        const key = rawKey.toLowerCase();
        if (tag.toLowerCase() === 'font') {
            const fontKey = (font) =>
                revision
                    ? font.Revision_Key?.startsWith(revision.trim().toLowerCase())
                    : font.API_Name?.toLowerCase() === key;
            if (target.records.fonts?.some((font) => fontKey(font) && font.Status === 'Verified')) continue;
            if (
                selected.some(
                    (row) =>
                        row.kind === 'fonts' &&
                        (revision
                            ? row.fontRevision?.startsWith(revision.trim().toLowerCase())
                            : row.key?.toLowerCase() === key)
                )
            )
                continue;
            throw new Error('Missing approved destination font dependency ' + key + '.');
        }
        const kind = tag.toLowerCase() === 'snippet' ? 'snippets' : 'assets';
        const typeMatches = (type) => (kind === 'snippets' ? type === 'HTMLSnippet' : type === 'Image' || type == null);
        if (
            target.records.assets?.some(
                (asset) =>
                    asset.Asset_Key?.toLowerCase() === key && asset.Is_Active !== false && typeMatches(asset.Asset_Type)
            )
        )
            continue;
        if (
            selected.some(
                (row) =>
                    row.kind === kind &&
                    row.key?.toLowerCase() === key &&
                    row.active !== false &&
                    typeMatches(row.assetType)
            )
        )
            continue;
        throw new Error('Missing destination dependency ' + key + '.');
    }
}

function fontReady(sourceStatus, targetStatus) {
    if (sourceStatus === 'Staged') return true;
    if (sourceStatus === 'Published') return ['Published', 'Verified'].includes(targetStatus);
    return sourceStatus === targetStatus;
}

export async function migrate({ sourceOrg, targetOrg, dryRun, mappingsPath, kinds, conflict = 'stop' }) {
    const mappings = mappingsPath ? JSON.parse(readFileSync(mappingsPath, 'utf8')) : {};
    const source = inspect(sourceOrg);
    const target = inspect(targetOrg);
    if (source.orgId === target.orgId) throw new Error('Source and target resolve to the same Salesforce org.');
    const report = plan(source, target);
    const fontAssets = new Set((source.records.fonts || []).map((font) => font.Asset));
    const selected = report.items.filter((item) => !kinds?.length || kinds.includes(item.kind));
    const fontAssetRows = selected.filter((item) => item.kind === 'assets' && item.assetType === 'Font');
    if (dryRun) return { ...report, items: selected, applySupportedKinds: [...operations.keys()] };
    if (!source.isSandbox || !target.isSandbox) {
        throw new Error('This draft migration can apply changes only between Salesforce sandbox or scratch orgs.');
    }
    const selectedAssetIds = new Set(
        selected
            .filter((item) => item.kind === 'fonts')
            .map((item) => source.records.fonts.find((font) => font.id === item.sourceId)?.Asset)
    );
    for (const asset of fontAssetRows) {
        if (!fontAssets.has(asset.sourceId) || !selectedAssetIds.has(asset.sourceId)) {
            throw new Error('Select the font revisions associated with ' + asset.name + '.');
        }
    }
    const unknown = selected.filter((item) => !operations.has(item.kind));
    if (unknown.length) {
        throw new Error(
            'Apply is unavailable for these selected resources: ' +
                [...new Set(unknown.map((item) => item.kind))].join(', ') +
                '.'
        );
    }

    const sourceSession = await Org.create({ aliasOrUsername: sourceOrg });
    const targetSession = await Org.create({ aliasOrUsername: targetOrg });
    if (
        sourceSession.getOrgId().slice(0, 15) !== source.orgId.slice(0, 15) ||
        targetSession.getOrgId().slice(0, 15) !== target.orgId.slice(0, 15)
    ) {
        throw new Error('Salesforce org identity changed during migration planning.');
    }
    const sourceConnection = sourceSession.getConnection();
    const targetConnection = targetSession.getConnection();
    const from = await rest(sourceConnection, source, 'capabilities');
    const to = await rest(targetConnection, target, 'capabilities');
    if (from.schemaVersion !== 1 || to.schemaVersion !== 1)
        throw new Error('Matching migration API version is required.');
    const selectedSettings = selected.some((item) => item.kind === 'settings');
    if (
        selectedSettings &&
        source.records.settings?.some((row) => row.AI_Provider_Class || row.AI_Prompt_Template) &&
        mappings.settings?.leaveAiUnchanged !== true
    ) {
        throw new Error(
            'AI settings are not transferred. Set settings.leaveAiUnchanged to true to continue with signing settings.'
        );
    }
    const prepared = [];
    const brandTargets = new Map();
    const selectedBrands = new Set(selected.filter((item) => item.kind === 'brands').map((item) => item.sourceId));
    const order = [...operations.keys()];
    for (const item of selected
        .filter((item) => !fontAssetRows.includes(item))
        .sort((a, b) => order.indexOf(a.kind) - order.indexOf(b.kind))) {
        const resource = operations.get(item.kind);
        if (!from.resources.includes(resource) || !to.resources.includes(resource)) {
            throw new Error('Both migration endpoints must support ' + resource + '.');
        }
        if (!['create', 'conflict', 'manual-mapping'].includes(item.status)) {
            throw new Error(item.kind + ' ' + item.name + ' needs attention: ' + item.status + '.');
        }
        let payload;
        try {
            payload = await rest(
                sourceConnection,
                source,
                resource === 'settings' ? resource : resource + '/' + encodeURIComponent(item.sourceId)
            );
            const brandSourceId = applyMappings(resource, payload, item, mappings, selectedBrands, target);
            assertVisibleDependencies(resource, payload, selected, target);
            if (brandSourceId && brandTargets.has(brandSourceId)) {
                payload.brandId = brandTargets.get(brandSourceId);
            } else if (brandSourceId && item.status === 'conflict') {
                throw new Error('Cannot reuse an existing resource before mapping its sending brand.');
            }
            if (Buffer.byteLength(JSON.stringify(payload)) > maxPayload)
                throw new Error('Resource exceeds the migration payload limit.');
            if (resource === 'settings') {
                const existing = await rest(targetConnection, target, resource);
                prepared.push({
                    item,
                    resource,
                    payload,
                    outcome: equivalent(resource, payload, existing) ? 'reused' : 'create'
                });
            } else if (item.status === 'conflict') {
                const existing = await rest(
                    targetConnection,
                    target,
                    resource + '/' + encodeURIComponent(item.targetIds[0])
                );
                if (equivalent(resource, payload, existing)) {
                    const needsApproval = resource === 'font' && !fontReady(payload.status, existing.status);
                    prepared.push({ item, resource, outcome: needsApproval ? 'requires-font-approval' : 'reused' });
                    if (resource === 'brand') brandTargets.set(item.sourceId, item.targetIds[0]);
                } else if (conflict === 'skip') {
                    prepared.push({ item, resource, outcome: 'skipped-conflict' });
                } else {
                    throw new Error('Destination already has a different resource with this key.');
                }
            } else {
                prepared.push({ item, resource, payload, brandSourceId, outcome: 'create' });
            }
        } catch (error) {
            throw new Error(item.kind + ' ' + item.name + ': ' + error.message);
        }
    }
    const skippedBrands = new Set(
        prepared
            .filter(({ resource, outcome }) => resource === 'brand' && outcome === 'skipped-conflict')
            .map(({ item }) => item.sourceId)
    );
    if (prepared.some(({ brandSourceId }) => skippedBrands.has(brandSourceId))) {
        throw new Error(
            'A selected resource needs a skipped source brand. Provide an explicit destination brand mapping.'
        );
    }

    const completed = fontAssetRows.map((item) => ({ ...item, outcome: 'handled-through-font-revisions' }));
    let approvalRequired = prepared.some(({ outcome }) => outcome === 'requires-font-approval');

    for (const { item, resource, payload, brandSourceId, outcome } of prepared) {
        if (outcome !== 'create') {
            completed.push({ ...item, outcome });
            continue;
        }
        let created;
        try {
            if (brandSourceId) {
                const destinationBrand = brandTargets.get(brandSourceId);
                if (!destinationBrand) throw new Error('A source brand requires an explicit destination mapping.');
                payload.brandId = destinationBrand;
            }
            if (resource === 'template' && approvalRequired) {
                completed.push({ ...item, outcome: 'deferred-for-font-approval' });
                continue;
            }
            const request = resource === 'font' ? { ...payload, hostingRightsConfirmed: true } : payload;
            created = await rest(targetConnection, target, resource, request);
            if (!created.id) throw new Error('Destination did not return a new resource ID.');
            const saved = await rest(
                targetConnection,
                target,
                resource === 'settings' ? resource : resource + '/' + encodeURIComponent(created.id)
            );
            const correctKey = {
                template: () => saved.template?.API_Name__c === item.key,
                snippet: () => saved.assetKey === item.key,
                asset: () => saved.assetKey === item.key,
                brand: () => saved.name === item.key,
                email: () => saved.type === payload.type && saved.brandId === payload.brandId,
                settings: () => true,
                font: () => saved.revisionKey === payload.revisionKey
            };
            if (!correctKey[resource]()) throw new Error('Destination did not retain the stable key.');
            if ((resource !== 'template' || !payload.assets?.length) && !equivalent(resource, payload, saved)) {
                throw new Error('Destination contents differ from the migration payload.');
            }
            if (resource === 'brand') brandTargets.set(item.sourceId, created.id);
            const needsApproval = resource === 'font' && !fontReady(payload.status, saved.status);
            if (needsApproval) approvalRequired = true;
            completed.push({
                ...item,
                outcome: needsApproval ? 'requires-font-approval' : 'created',
                targetIds: [created.id]
            });
        } catch (error) {
            completed.push({
                ...item,
                outcome: created ? 'verification-failed' : 'failed',
                targetIds: created?.id ? [created.id] : [],
                error: error.message
            });
            return { ...report, complete: false, items: completed };
        }
    }
    return { ...report, complete: !approvalRequired, items: completed };
}
