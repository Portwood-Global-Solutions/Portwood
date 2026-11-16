import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import { buildCompressedDocx, buildDocx } from '../../force-app/main/default/lwc/docGenRunner/docGenZipWriter.js';
import {
    GiantDocxMedia,
    giantDocxFieldValue,
    giantDocxImageTags,
    wordTextPosition
} from '../../force-app/main/default/lwc/docGenRunner/docGenGiantDocxMedia.js';

// Load the real Runner and ZIP writer. Only Lightning decorators and platform imports are stubbed.
const rawRunner = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenRunner/docGenRunner.js', import.meta.url),
    'utf8'
);
const runnerSource = rawRunner
    .replace(/^import [\s\S]*?;\r?\n/gm, '')
    .replace(/^\s*@wire\([^\n]+\)\s*\n/gm, '\n')
    .replace(/@(api|track)\s+/g, '')
    .replace('export default class', 'return class');
const labels = Object.fromEntries(
    [...rawRunner.matchAll(/^import (LBL_\w+) from /gm)].map((match) => [match[1], match[1]])
);
const platform = {};
const mocks = {
    ...labels,
    LightningElement: class {},
    NavigationMixin: (component) => component,
    TYPE_FIELD: { fieldApiName: 'Type__c' },
    OUT_FMT_FIELD: { fieldApiName: 'Output_Format__c' },
    USER_TIME_ZONE: 'America/Chicago',
    buildCompressedDocx,
    buildDocx,
    GiantDocxMedia,
    giantDocxFieldValue,
    giantDocxImageTags,
    wordTextPosition
};
for (const method of [
    'generateDocumentPartsGiantQuery',
    'generateDocumentPartsGiantQueryMulti',
    'getGiantDocxImage',
    'getSortedChildIds',
    'getChildRecordsByIds',
    'getChildRecordPage',
    'scoutChildCounts'
]) {
    mocks[method] = (...args) => platform[method](...args);
}
const Runner = new Function(...Object.keys(mocks), runnerSource)(...Object.values(mocks));

function runner(outputFormat = 'Native') {
    const component = new Runner();
    component.recordId = 'record';
    component.selectedTemplateId = 'template';
    component._templateData = [{ Id: 'template', Type__c: 'Word', Output_Format__c: outputFormat }];
    component.showToast = () => {};
    component.downloadBase64 = (base64, name, mimeType) => {
        assert.equal(mimeType, 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
        component.download = { zip: Buffer.from(base64, 'base64'), name };
    };
    return component;
}

function zipEntry(zip, path) {
    for (let offset = 0; zip.readUInt32LE(offset) === 0x04034b50; ) {
        const compressedSize = zip.readUInt32LE(offset + 18);
        const nameSize = zip.readUInt16LE(offset + 26);
        const extraSize = zip.readUInt16LE(offset + 28);
        const nameStart = offset + 30;
        const dataStart = nameStart + nameSize + extraSize;
        const dataEnd = dataStart + compressedSize;
        const name = zip.toString('utf8', nameStart, nameStart + nameSize);
        if (name === path) {
            const method = zip.readUInt16LE(offset + 8);
            const data = zip.subarray(dataStart, dataEnd);
            return { method, data: method === 8 ? inflateRawSync(data) : data };
        }
        offset = dataEnd;
    }
    assert.fail('The DOCX is missing ZIP part ' + path);
}

function documentXml(zip) {
    const { method, data } = zipEntry(zip, 'word/document.xml');
    return { method, xml: data.toString('utf8') };
}

const scout = {
    counts: { Beta: 2, Alpha: 504, Small: 1 },
    useGiantPath: { Beta: true, Alpha: true, Small: false },
    childNodes: {
        Alpha: {
            object: 'Contact',
            lookupField: 'AccountId',
            fields: ['Id', 'Name', 'Date__c', 'When__c'],
            parentFields: ['Account.Name'],
            where: "Department = 'Alpha'",
            limit: '502'
        },
        Beta: { object: 'Asset', lookupField: 'AccountId', fields: ['Name'] }
    }
};
const slots = [
    { queryKey: 'Beta', marker: '<!--beta-->', innerXml: '<b>{Name}</b>' },
    {
        queryKey: 'Alpha',
        marker: '<!--alpha-->',
        innerXml: '<a>{Name}|{Date__c:MM/dd/yyyy}|{When__c:MM/dd/yyyy}|{Account.Name}</a>'
    },
    { queryKey: 'Alpha', marker: '<!--repeated-->', innerXml: '<repeat>{Name}</repeat>' }
];
const shell = '<root><!--alpha--><small>already merged</small><!--beta--><!--repeated--></root>';
const sortedIds = Array.from({ length: 504 }, (_, index) => String(504 - index));
const firstValue = "$& $' $` <value>";
let sortedCalls = 0;
const sortedPageSizes = [];
const cursorCalls = [];
platform.scoutChildCounts = async () => scout;
platform.generateDocumentPartsGiantQueryMulti = async (request) => {
    assert.deepEqual(request, {
        templateId: 'template',
        recordId: 'record',
        giantRelationshipNames: ['Beta', 'Alpha']
    });
    return { allXmlParts: { 'word/document.xml': shell }, slots, title: 'Invoice' };
};
platform.generateDocumentPartsGiantQuery = async () =>
    assert.fail('Multi-Word must request a single multi-loop shell.');
platform.getSortedChildIds = async (request) => {
    sortedCalls++;
    assert.deepEqual(request, {
        childObject: 'Contact',
        lookupField: 'AccountId',
        parentId: 'record',
        orderByClause: 'Id ASC',
        whereClause: "Department = 'Alpha'"
    });
    return sortedIds;
};
const getRecords = async ({ childObject, fields, recordIds }) => {
    assert.equal(childObject, 'Contact');
    assert.equal(fields, 'Id, Name, Date__c, When__c, Account.Name');
    sortedPageSizes.push(recordIds.length);
    return recordIds.map((id) => ({
        Id: id,
        Name: id === '504' ? firstValue : id,
        Date__c: '2026-11-01',
        When__c: '2026-11-01T04:15:00.000Z',
        Account: { Name: 'ACME & Sons' }
    }));
};
platform.getChildRecordsByIds = getRecords;
platform.getChildRecordPage = async (request) => {
    assert.equal(request.childObject, 'Asset');
    assert.equal(request.fields, 'Id, Name');
    cursorCalls.push([request.lastCursorId, request.pageSize]);
    if (request.lastCursorId === null) {
        return { records: [{ Id: 'b1', Name: 'First' }], lastId: 'b1', hasMore: true };
    }
    return { records: [{ Id: 'b2', Name: 'Second' }], lastId: 'b2', hasMore: false };
};

const component = runner();
await component.handleGenerate();
assert.equal(component.error, null);
assert.equal(component.download.name, 'Invoice.docx');
const result = documentXml(component.download.zip);
assert.equal(result.method, 8, 'The main XML part must be compressed.');
assert.equal(sortedCalls, 1, 'An alias appearing in two placements should be fetched once.');
assert.deepEqual(sortedPageSizes, [500, 2]);
assert.deepEqual(cursorCalls, [
    [null, 500],
    ['b1', 500]
]);
assert.equal([...result.xml.matchAll(/<a>/g)].length, 502);
assert.equal([...result.xml.matchAll(/<repeat>/g)].length, 502);
const expectedFirst = "<a>$&amp; $' $` &lt;value&gt;|11/01/2026|10/31/2026|ACME &amp; Sons</a>";
assert.ok(result.xml.startsWith('<root>' + expectedFirst + '<a>503|'));
assert.ok(
    result.xml.includes(
        "<a>3|11/01/2026|10/31/2026|ACME &amp; Sons</a><small>already merged</small><b>First</b><b>Second</b><repeat>$&amp; $' $` &lt;value&gt;</repeat>"
    )
);
assert.ok(result.xml.endsWith('<repeat>3</repeat></root>'));
assert.equal(component.showProgressBar, false);
assert.equal(
    component._uint8ArrayToBase64(Buffer.alloc(24 * 1024 + 2, 221)),
    Buffer.alloc(24 * 1024 + 2, 221).toString('base64')
);

const pdf = runner('PDF');
pdf._assembleGiantQueryPdf = async (...args) => assert.deepEqual(args, ['Beta', scout.counts, scout.childNodes.Beta]);
await pdf.handleGenerate();

const originalMulti = platform.generateDocumentPartsGiantQueryMulti;
platform.generateDocumentPartsGiantQueryMulti = async () => ({
    allXmlParts: { 'word/document.xml': '<root><!--beta--></root>' },
    slots: [slots[0]]
});
const unused = runner();
await unused.handleGenerate();
assert.equal(unused.error, null);
assert.equal(documentXml(unused.download.zip).xml, '<root><b>First</b><b>Second</b></root>');
assert.equal(sortedCalls, 1, 'Scout results without a template placement should not fetch rows.');

platform.generateDocumentPartsGiantQueryMulti = async () => ({
    allXmlParts: { 'word/document.xml': shell },
    slots: []
});
const missing = runner();
await missing.handleGenerate();
assert.match(missing.error, /did not return Giant Query loops/);
assert.equal(missing.download, undefined);

platform.generateDocumentPartsGiantQueryMulti = originalMulti;
platform.getChildRecordsByIds = async (request) => (await getRecords(request)).slice(0, -1);
const short = runner();
await short.handleGenerate();
assert.match(short.error, /expected 502 rows and retrieved 500/);
assert.equal(short.download, undefined);

platform.getChildRecordsByIds = getRecords;
platform.getChildRecordPage = async () => ({
    records: ['First', 'Second', 'Added'].map((Name) => ({ Name })),
    hasMore: false
});
const expanded = runner();
await expanded.handleGenerate();
assert.match(expanded.error, /expected 2 rows and retrieved 3/);
assert.equal(expanded.download, undefined);

platform.scoutChildCounts = async () => ({
    ...scout,
    counts: { Beta: 2 },
    useGiantPath: { Beta: true }
});
platform.generateDocumentPartsGiantQueryMulti = async () =>
    assert.fail('Single Word query keeps the legacy shell API.');
platform.generateDocumentPartsGiantQuery = async (request) => {
    assert.deepEqual(request, { templateId: 'template', recordId: 'record', giantRelationshipName: 'Beta' });
    return {
        allXmlParts: { 'word/document.xml': '<root><!--single--></root>' },
        placeholder: '<!--single-->',
        giantLoopBodyXml: '<b>{Name}</b>'
    };
};
platform.getChildRecordPage = async () => ({
    records: [
        { Id: 'b1', Name: 'First' },
        { Id: 'b2', Name: 'Second' }
    ],
    lastId: 'b2',
    hasMore: false
});
const single = runner();
await single.handleGenerate();
assert.equal(single.error, null);
assert.deepEqual(documentXml(single.download.zip), { method: 0, xml: '<root><b>First</b><b>Second</b></root>' });

const logo = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3dAAAAAASUVORK5CYII=';
const versionId = '068000000000001AAA';
const documentId = '069000000000001AAA';
const requestedMedia = [];
platform.scoutChildCounts = async () => ({
    counts: { Beta: 2 },
    useGiantPath: { Beta: true },
    childNodes: { Beta: { ...scout.childNodes.Beta, fields: ['Name', 'Photo__c'] } }
});
platform.getGiantDocxImage = async ({ fileId }) => {
    requestedMedia.push(fileId);
    assert.equal(fileId, documentId);
    return { extension: 'png', contentVersionId: versionId, base64: logo };
};
platform.generateDocumentPartsGiantQuery = async () => ({
    allXmlParts: {
        'word/document.xml': '<w:document xmlns:w="urn:word"><w:body><!--media--></w:body></w:document>',
        '[Content_Types].xml':
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>',
        'word/_rels/document.xml.rels':
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdPortwoodGiantImage1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/template-logo.png"/></Relationships>'
    },
    imageBase64Map: { 'word/media/template-logo.png': logo },
    placeholder: '<!--media-->',
    giantLoopBodyXml: '<w:p><w:r><w:t>{Name} {%Photo__c:80x40}</w:t></w:r></w:p>'
});
platform.getChildRecordPage = async () => ({
    records: [
        { Name: 'One\nTwo & three', Photo__c: '/sfc/servlet.shepherd/document/download/' + documentId },
        { Name: 'Again', Photo__c: versionId }
    ],
    hasMore: false
});
const images = runner();
await images.handleGenerate();
assert.equal(images.error, null);
assert.deepEqual(requestedMedia, [documentId], 'A document and version alias reuse one image.');
const { xml: imageXml } = documentXml(images.download.zip);
assert.deepEqual(
    [...imageXml.matchAll(/<wp:docPr id="(\d+)"/g)].map((match) => match[1]),
    ['1', '2']
);
assert.deepEqual(
    [...imageXml.matchAll(/r:embed="([^"]+)"/g)].map((match) => match[1]),
    ['rIdPortwoodGiantImage2', 'rIdPortwoodGiantImage2']
);
assert.match(imageXml, /<wp:extent cx="762000" cy="381000"\/>/);
assert.match(imageXml, /One<\/w:t><w:br\/><w:t xml:space="preserve">Two &amp; three/);
const imageRelationships = zipEntry(images.download.zip, 'word/_rels/document.xml.rels').data.toString('utf8');
assert.match(imageRelationships, /Id="rIdPortwoodGiantImage1"[^>]+Target="media\/template-logo.png"/);
assert.match(imageRelationships, /Id="rIdPortwoodGiantImage2"[^>]+Target="media\/docgen_giant_image_2.png"/);
assert.deepEqual(
    zipEntry(images.download.zip, 'word/media/docgen_giant_image_2.png').data,
    Buffer.from(logo, 'base64')
);
assert.deepEqual(zipEntry(images.download.zip, 'word/media/template-logo.png').data, Buffer.from(logo, 'base64'));
assert.match(
    zipEntry(images.download.zip, '[Content_Types].xml').data.toString('utf8'),
    /Extension="png" ContentType="image\/png"/
);

platform.getChildRecordPage = async () => ({
    records: [{ Name: 'Remote', Photo__c: 'https://outside.example/image.png' }],
    hasMore: false
});
const rejected = runner();
await rejected.handleGenerate();
assert.match(rejected.error, /must contain a Salesforce File ID/);
assert.equal(rejected.download, undefined);
assert.deepEqual(requestedMedia, [documentId], 'Remote images never reach the Apex file reader.');

const fullParagraphParts = platform.generateDocumentPartsGiantQuery;
platform.generateDocumentPartsGiantQuery = async () => {
    const parts = await fullParagraphParts();
    parts.allXmlParts['word/document.xml'] =
        '<w:document xmlns:w="urn:word"><w:body><w:p><w:r><w:t><!--media--></w:t></w:r></w:p></w:body></w:document>';
    parts.giantLoopBodyXml = '{Name} {%Photo__c:80x40}';
    return parts;
};
platform.getChildRecordPage = async () => ({
    records: [{ Name: 'Inline', Photo__c: documentId }],
    hasMore: false
});
const inlineImages = runner();
await inlineImages.handleGenerate();
assert.equal(inlineImages.error, null);
assert.match(documentXml(inlineImages.download.zip).xml, /<w:t>Inline <\/w:t><w:drawing>/);

console.log(
    'PASS: Giant Query Runner routing, order, alias reuse, pagination, dates, limits, ZIP, native images, and error handling.'
);
