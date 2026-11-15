import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { request } from 'node:https';
import { dirname, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { salesforceConnection } from '../lib/salesforce-pdf-transport.mjs';

const year = 2025;
const priceBookName = 'Portwood 2025 Packet Fixtures';
const batchSize = 28;
const { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  options: { range: { type: 'boolean' }, 'target-org': { type: 'string' }, 'org-id': { type: 'string' } },
  allowPositionals: true,
});
assert.ok(values.range && positionals.length === 3, 'Usage: seed-portwood-account-packets.mjs --range FIRST LAST MANIFEST --target-org ALIAS --org-id ID');
const alias = values['target-org'];
assert.match(alias, /^[A-Za-z0-9][A-Za-z0-9-]+$/);
const expectedOrgId = values['org-id'];
assert.match(expectedOrgId, /^00D[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/);
const [firstOrdinal, lastOrdinal] = positionals.map(Number);
assert.ok(Number.isSafeInteger(firstOrdinal) && Number.isSafeInteger(lastOrdinal) &&
  firstOrdinal >= 1 && lastOrdinal >= firstOrdinal && lastOrdinal <= 100_000,
  'Supply inclusive, increasing receipt ordinals from 1 to 100000.');
const count = lastOrdinal - firstOrdinal + 1;
const ordinalWidth = 6;
const cohort = 'PW-BENCH-100K-2025';
const filename = resolve(positionals[2]);
const pad = (value, width) => String(value).padStart(width, '0');
const accountNumber = ordinal => `${cohort}-${pad(ordinal, ordinalWidth)}`;
const giftName = (ordinal, gift) => `PW-PACKET-${pad(ordinal, ordinalWidth)}-G${gift + 1}`;
const addresses = [
  ['Hawthollow Lane', 'Starling Haven', 'ME', '04991'],
  ['Wrenfield Drive', 'New Aldercrest', 'VT', '05991'],
  ['Tumbleash Road', 'Pine Lantern', 'NH', '03991'],
  ['Amberdell Place', 'Birchgrove Falls', 'MA', '01991'],
];
const firstNames = ['Avery', 'Blair', 'Casey', 'Cameron', 'Drew', 'Emerson', 'Harper', 'Jamie',
  'Jules', 'Kendall', 'Lane', 'Morgan', 'Parker', 'Quinn', 'Riley', 'Rowan', 'Sage', 'Taylor'];
const familyNames = ['Bramblewick', 'Cobbleroy', 'Dunegrove', 'Eastfern', 'Foxglade', 'Glasshollow',
  'Hawthornley', 'Ivybriar', 'Kestrelmore', 'Lionbrook', 'Mossbourne', 'Nightingrove', 'Oatmere',
  'Pebblehurst', 'Quillwood', 'Rushden', 'Slatefield', 'Trellisford'];
const middleNames = ['Arden', 'Bailey', 'Briar', 'Brook', 'Clarke', 'Cove', 'Dale', 'Dawson',
  'Ellis', 'Finch', 'Frankie', 'Gale', 'Glenn', 'Gray', 'Hollis', 'Indigo', 'Jude', 'Kit', 'Lake',
  'Lee', 'Lux', 'Marlowe', 'North', 'Oak', 'Perry', 'Rain', 'Reese', 'Ren', 'River', 'Sky', 'Vale'];
const branchNames = ['Aldercrest', 'Bluehaven', 'Cinderglen', 'Dawnmere', 'Elmshade',
  'Fernlane', 'Goldmarsh', 'Hillsworth', 'Ivystone', 'Juniperfall'];
const programs = ['Community Food Program', 'Youth Literacy Fund', 'Winter Assistance Fund', 'Family Resource Center'];
const products = [
  ['Community Pantry Bundle', 25], ['Youth Literacy Kit', 18], ['Winter Relief Pack', 45],
  ['After-School Supply Set', 30], ['Community Meal Voucher', 12], ['Family Resource Kit', 55],
  ['Learning Lab Materials', 65], ['Neighborhood Care Package', 35],
].map(([name, price], index) => ({ name, price, code: `PW-PACKET-ITEM-${pad(index + 1, 2)}` }));

async function salesforceJson(connection, method, path, data) {
  const body = data === undefined ? undefined : JSON.stringify(data);
  return new Promise((resolveResponse, rejectResponse) => {
    const req = request(new URL(path, connection.origin), {
      method,
      agent: connection.agent,
      signal: AbortSignal.timeout(45_000),
      headers: {
        authorization: `Bearer ${connection.accessToken}`,
        ...(method === 'POST' && path.endsWith('/composite/tree/Account') ? {
          'Sforce-Duplicate-Rule-Header': 'allowSave=true; includeRecordDetails=false; runAsCurrentUser=true',
        } : {}),
        ...(body === undefined ? {} : { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }),
      },
    }, async response => {
      try {
        const pieces = [];
        for await (const piece of response) pieces.push(piece);
        const value = JSON.parse(Buffer.concat(pieces));
        if (response.statusCode >= 300 || value.hasErrors) {
          const errors = Array.isArray(value) ? value : (value.results ?? []).flatMap(result => result.errors ?? []);
          const codes = [...new Set(errors.map(error => error.errorCode ?? error.statusCode))].filter(Boolean);
          throw new Error(`Salesforce fixture ${method} ${path.split('?')[0]} failed with HTTP ${response.statusCode} (${codes.join(', ') || 'unknown'}).`);
        }
        resolveResponse(value);
      } catch (error) {
        rejectResponse(error);
      }
    });
    req.on('error', rejectResponse);
    req.end(body);
  });
}

const started = performance.now();
const previous = existsSync(filename) ? JSON.parse(readFileSync(filename, 'utf8')) : null;
const connection = await salesforceConnection(alias, { keepAlive: true, maxSockets: 8 });
try {
  assert.ok(connection.origin.hostname.endsWith('.scratch.my.salesforce.com'), 'Target must use a Salesforce scratch domain.');
  async function query(soql) {
    let path = '/services/data/v68.0/query?q=' + encodeURIComponent(soql);
    const output = [];
    for (;;) {
      const page = await salesforceJson(connection, 'GET', path);
      output.push(...page.records);
      if (page.done) return output;
      assert.match(page.nextRecordsUrl, /^\/services\/data\/v68\.0\/query\/[A-Za-z0-9_-]+$/);
      path = page.nextRecordsUrl;
    }
  }

  async function insertMany(type, records) {
    if (records.length === 0) return;
    const result = await salesforceJson(connection, 'POST', '/services/data/v68.0/composite/sobjects', {
      allOrNone: true,
      records: records.map(record => ({ attributes: { type }, ...record })),
    });
    assert.equal(result.length, records.length);
    const codes = result.flatMap(row => row.errors ?? []).map(error => error.statusCode);
    assert.ok(result.every(row => row.success), `${type} fixture inserts failed: ${[...new Set(codes)].join(', ')}.`);
  }

  const [org] = await query('SELECT Id FROM Organization LIMIT 1');
  const orgId = org?.Id;
  assert.match(orgId ?? '', /^00D[A-Za-z0-9]{15}$/, 'Missing scratch Organization ID.');
  assert.equal(orgId.slice(0, 15), expectedOrgId.slice(0, 15), 'The authenticated scratch org differs from the requested org.');
  if (previous) {
    assert.ok(previous.orgId === orgId && previous.targetOrg === alias && previous.cohort === cohort &&
      previous.firstOrdinal === firstOrdinal && previous.lastOrdinal === lastOrdinal,
      'Existing manifest belongs to a different scratch org or ordinal range. Supply another manifest path.');
  }
  const [[won], [standardBook], limits] = await Promise.all([
    query('SELECT MasterLabel FROM OpportunityStage WHERE IsActive = true AND IsWon = true ORDER BY SortOrder LIMIT 1'),
    query('SELECT Id FROM Pricebook2 WHERE IsStandard = true'),
    salesforceJson(connection, 'GET', '/services/data/v68.0/limits'),
  ]);
  assert.ok(won?.MasterLabel && standardBook?.Id);
  const dataStorageRemainingMB = limits.DataStorageMB.Remaining;
  const filter = field => `${field} LIKE '${cohort}-%' AND ${field} >= '${accountNumber(firstOrdinal)}' AND ${field} <= '${accountNumber(lastOrdinal)}'`;
  async function readAccounts() {
    return query(`SELECT Id, AccountNumber FROM Account WHERE ${filter('AccountNumber')} ORDER BY AccountNumber`);
  }
  const before = await readAccounts();
  if (previous) {
    assert.deepEqual(before.map(account => account.Id), previous.accountIds,
      'Existing manifest pins different Account IDs. Supply another manifest path to reseed a pruned range.');
  }
  const seen = new Set(before.map(account => account.AccountNumber));
  assert.equal(seen.size, before.length, 'Duplicate fixture Account numbers.');
  const missing = Array.from({ length: count }, (_, index) => firstOrdinal + index).filter(ordinal => !seen.has(accountNumber(ordinal)));
  assert.ok(dataStorageRemainingMB >= Math.ceil(missing.length * 7 * 2000 / (1024 * 1024)),
    'Insufficient scratch org data storage for the fixture.');
  const existingPriceBooks = await query(`SELECT Id, IsActive FROM Pricebook2 WHERE Name = '${priceBookName}' AND IsStandard = false`);
  assert.ok(existingPriceBooks.length <= 1);
  if (existingPriceBooks.length === 0) {
    await insertMany('Pricebook2', [{ Name: priceBookName, IsActive: true, Description: cohort }]);
  }
  const [priceBook] = await query(`SELECT Id, IsActive FROM Pricebook2 WHERE Name = '${priceBookName}' AND IsStandard = false`);
  assert.ok(priceBook?.IsActive, 'Dedicated fixture price book is inactive.');

  const productCodes = products.map(product => `'${product.code}'`).join(',');
  async function readProducts() {
    const rows = await query(`SELECT Id, Name, ProductCode, IsActive FROM Product2 WHERE ProductCode IN (${productCodes})`);
    const byCode = new Map(rows.map(row => [row.ProductCode, row]));
    assert.equal(rows.length, byCode.size, 'Duplicate fixture Product2 codes.');
    for (const product of products) {
      const stored = byCode.get(product.code);
      if (stored) assert.ok(stored.IsActive && stored.Name === product.name, 'Unexpected fixture product state.');
    }
    return byCode;
  }
  let storedProducts = await readProducts();
  const missingProducts = products.filter(product => !storedProducts.has(product.code));
  if (missingProducts.length > 0) {
    await insertMany('Product2', missingProducts.map(product => ({ ProductCode: product.code, Name: product.name, IsActive: true })));
    storedProducts = await readProducts();
  }
  assert.equal(storedProducts.size, products.length);
  const productIds = [...storedProducts.values()].map(product => `'${product.Id}'`).join(',');
  const entriesByCode = new Map();
  for (const book of [standardBook, priceBook]) {
    const findEntries = () => query(`SELECT Id, Product2Id, Product2.ProductCode, IsActive, UnitPrice FROM PricebookEntry
      WHERE Pricebook2Id = '${book.Id}' AND Product2Id IN (${productIds})`);
    let entries = await findEntries();
    const present = new Set(entries.map(entry => entry.Product2Id));
    const needed = products.filter(product => !present.has(storedProducts.get(product.code).Id));
    if (needed.length > 0) {
      await insertMany('PricebookEntry', needed.map(product => ({
        Product2Id: storedProducts.get(product.code).Id, Pricebook2Id: book.Id,
        IsActive: true, UnitPrice: product.price, UseStandardPrice: false,
      })));
      entries = await findEntries();
    }
    assert.equal(entries.length, products.length);
    for (const entry of entries) {
      const actualProduct = products.find(product => product.code === entry.Product2.ProductCode);
      assert.ok(entry.IsActive && entry.UnitPrice === actualProduct?.price, 'Unexpected fixture price book entry state.');
      if (book.Id === priceBook.Id) entriesByCode.set(entry.Product2.ProductCode, entry.Id);
    }
  }

  function lineItems(ordinal, gift) {
    return [0, 1].map(item => {
      const product = products[(ordinal * 3 + gift * 2 + item) % products.length];
      const quantity = 1 + ((ordinal * 7 + gift * 3 + item) % 4);
      return {
        attributes: { type: 'OpportunityLineItem', referenceId: `Item${ordinal}_${gift}_${item}` },
        PricebookEntryId: entriesByCode.get(product.code),
        Quantity: quantity,
        UnitPrice: product.price,
        Description: `${product.name} contribution`,
      };
    });
  }

  function giftFields(ordinal, gift) {
    return {
      Name: giftName(ordinal, gift),
      CloseDate: `${year}-${pad((ordinal * 7 + gift * 4) % 12 + 1, 2)}-${pad((ordinal * 13 + gift * 5) % 27 + 1, 2)}`,
      Description: programs[(ordinal + gift) % programs.length],
    };
  }

  function donor(ordinal) {
    const [street, city, state, postalCode] = addresses[ordinal % addresses.length];
    const nameIndex = ordinal - 1;
    const first = firstNames[nameIndex % firstNames.length];
    const familyIndex = Math.floor(nameIndex / firstNames.length);
    const family = familyNames[familyIndex % familyNames.length];
    const middleIndex = Math.floor(familyIndex / familyNames.length);
    const middle = middleNames[middleIndex % middleNames.length];
    const branch = `-${branchNames[Math.floor(middleIndex / middleNames.length)]}`;
    return {
      attributes: { type: 'Account', referenceId: `Account${ordinal}` },
      AccountNumber: accountNumber(ordinal),
      Name: `${first} ${middle} ${family}${branch} Household`,
      BillingStreet: `${200 + ordinal} ${street}`,
      BillingCity: city,
      BillingState: state,
      BillingPostalCode: postalCode,
      BillingCountry: 'United States',
      Opportunities: { records: [0, 1].map(gift => ({
        attributes: { type: 'Opportunity', referenceId: `Gift${ordinal}_${gift}` },
        ...giftFields(ordinal, gift),
        StageName: won.MasterLabel,
        Pricebook2Id: priceBook.Id,
        OpportunityLineItems: { records: lineItems(ordinal, gift) },
      })) },
    };
  }

  const ready = performance.now();
  let next = 0;
  let inserted = 0;
  let requests = 0;
  let nextProgress = 1000;
  let failed;
  const concurrency = Math.min(Math.ceil(missing.length / batchSize), 8);
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (!failed && next < missing.length) {
      const group = missing.slice(next, next + batchSize);
      next += group.length;
      try {
        requests++;
        const result = await salesforceJson(connection, 'POST', '/services/data/v68.0/composite/tree/Account', {
          records: group.map(donor),
        });
        assert.equal(result.results.length, group.length * 7);
        inserted += group.length;
        if (inserted >= nextProgress) {
          console.log(JSON.stringify({ insertedAccounts: inserted, expectedNewAccounts: missing.length }));
          nextProgress += 1000;
        }
      } catch (error) {
        failed = error;
      }
    }
  }));
  if (failed) throw failed;
  assert.equal(inserted, missing.length);
  const writesComplete = performance.now();

  const [accounts, opportunities, items] = await Promise.all([
    readAccounts(),
    query(`SELECT Id, AccountId, Name, Amount, CloseDate, Description, IsWon, Pricebook2Id
      FROM Opportunity WHERE ${filter('Account.AccountNumber')}`),
    query(`SELECT Id, OpportunityId, PricebookEntryId, Product2.Name, Quantity, UnitPrice, TotalPrice, Description
      FROM OpportunityLineItem WHERE ${filter('Opportunity.Account.AccountNumber')}`),
  ]);
  assert.equal(accounts.length, count);
  assert.equal(opportunities.length, count * 2);
  assert.equal(items.length, count * 4);
  function groupBy(rows, field) {
    const grouped = new Map();
    for (const row of rows) {
      const key = row[field];
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key).push(row);
    }
    return grouped;
  }
  const giftsByAccount = groupBy(opportunities, 'AccountId');
  const itemsByGift = groupBy(items, 'OpportunityId');
  const verifiedRecords = accounts.map((account, index) => {
    const ordinal = firstOrdinal + index;
    assert.equal(account.AccountNumber, accountNumber(ordinal));
    const gifts = giftsByAccount.get(account.Id) ?? [];
    assert.equal(gifts.length, 2);
    const opportunitiesForAccount = [0, 1].map(gift => {
      const fields = giftFields(ordinal, gift);
      const stored = gifts.find(record => record.Name === fields.Name);
      assert.ok(stored?.IsWon && stored.CloseDate === fields.CloseDate && stored.Description === fields.Description &&
        stored.Pricebook2Id === priceBook.Id, `Gift fields for account ${ordinal}.`);
      const expected = lineItems(ordinal, gift);
      const actual = itemsByGift.get(stored.Id) ?? [];
      assert.equal(actual.length, expected.length);
      const lineItemIds = expected.map(item => {
        const storedItem = actual.find(row => row.PricebookEntryId === item.PricebookEntryId);
        assert.ok(storedItem && ['Quantity', 'UnitPrice', 'Description'].every(field => item[field] === storedItem[field]) &&
          storedItem.TotalPrice === item.UnitPrice * item.Quantity && storedItem.Product2?.Name &&
          `${storedItem.Product2.Name} contribution` === storedItem.Description, `Line item fields for account ${ordinal}.`);
        return storedItem.Id;
      });
      assert.equal(stored.Amount, actual.reduce((total, row) => total + row.TotalPrice, 0), `Gift amount for account ${ordinal}.`);
      return { opportunityId: stored.Id, lineItemIds };
    });
    return { ordinal, accountId: account.Id, opportunities: opportunitiesForAccount };
  });
  const accountIds = verifiedRecords.map(record => record.accountId);
  if (previous) {
    assert.deepEqual(verifiedRecords, previous.records,
      'Existing manifest pins different Opportunity or Line Item IDs. Supply another manifest path to reseed.');
  }
  const finished = performance.now();
  const summary = {
    schemaVersion: 2,
    source: 'Synthetic standard Salesforce Account, Opportunity, and OpportunityLineItem records',
    targetOrg: alias, orgId, cohort, year,
    firstOrdinal, lastOrdinal, ordinalWidth,
    firstAccountNumber: accountNumber(firstOrdinal), lastAccountNumber: accountNumber(lastOrdinal),
    referenceFields: { account: 'AccountNumber', gift: 'Opportunity.Name', lineItemProduct: 'Product2.Name' },
    priceBookId: priceBook.Id,
    accountCount: count,
    opportunityCount: opportunities.length,
    opportunityLineItemCount: items.length,
    existingAccountCount: before.length,
    insertedAccountCount: inserted,
    compositeWriteRequests: requests,
    dataStorageRemainingMBBefore: dataStorageRemainingMB,
    setupMs: Math.round(ready - started),
    seedMs: Math.round(writesComplete - ready),
    verifyMs: Math.round(finished - writesComplete),
    elapsedMs: Math.round(finished - started),
  };
  mkdirSync(dirname(filename), { recursive: true });
  if (!previous) {
    writeFileSync(filename + '.next', JSON.stringify({ ...summary, accountIds, records: verifiedRecords }, null, 2) + '\n');
    renameSync(filename + '.next', filename);
  }
  console.log(JSON.stringify({ ...summary, manifestFile: filename, firstAccountId: accountIds[0] }));
} finally {
  connection.agent.destroy();
}
