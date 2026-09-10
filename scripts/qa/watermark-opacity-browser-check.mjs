/**
 * Watermark opacity, end to end in a real browser (#313).
 *
 *   node scripts/qa/watermark-opacity-browser-check.mjs [--org docgen-verify] [--headed]
 *
 * The unit tests cover the Apex; the pure-node check covers the file-name
 * contract. Neither runs the actual designer flow — the canvas bake, the toast,
 * the dropdown seeding after a reload. This does:
 *
 *   1. upload a watermark at 30%   -> baked watermark-p30.png, ONE source,
 *                                     stored PNG pixels ~30% opaque
 *   2. change the strength to 50%  -> re-baked watermark-p50.png, no CV pile-up,
 *                                     stored PNG now ~50% opaque
 *   3. reload the page, reopen     -> the dropdown reads 50%, not the default
 *   4. change to 15%               -> re-baked from the ORIGINAL: ~15% opaque,
 *                                     NOT 15% of the 50% wash
 *
 * The uploaded source is a fully opaque red PNG, so a correct bake leaves every
 * stored pixel at alpha ~= round(255 * pct/100). The stored bytes are pulled
 * back through anonymous Apex and the PNG is decoded in Node (no canvas, no CORS).
 *
 * Still manual on a namespaced install: atob/Blob/createObjectURL under
 * Lightning Web Security.
 */
import { writeFileSync, mkdtempSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { inflateSync, deflateSync } from 'node:zlib';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright';
import { inPage } from './lib/browser.mjs';

/** Own launcher so --headed can add slowMo for a watchable demo. */
async function launch({ headed = false } = {}) {
    const browser = await chromium.launch({ headless: !headed, slowMo: headed ? 400 : 0 });
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await ctx.newPage();
    return { browser, page };
}

const arg = (name, def) => {
    const i = process.argv.indexOf(name);
    return i > -1 ? process.argv[i + 1] : def;
};
const ORG = arg('--org', 'docgen-verify');
const HEADED = process.argv.includes('--headed');
const NAME = 'QAWM-opacity-' + Date.now();
let APP = 'DocGen_Template_Manager';

// The QA lib spawns `sf` with execFile, which does not resolve `sf.cmd` on
// native Windows. This check calls the CLI itself, cross-platform.
const CLI = (s) => execSync(s, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
function runAnonymous(org, apex) {
    const dir = mkdtempSync(join(tmpdir(), 'qawm-apex-'));
    const f = join(dir, 'run.apex');
    writeFileSync(f, apex, 'utf8');
    try {
        return CLI(`sf apex run --target-org ${org} -f "${f}"`);
    } catch (e) {
        return String(e.stdout || '') + String(e.stderr || '');
    }
}
function soql(org, q) {
    try {
        const raw = CLI(`sf data query --target-org ${org} --json -q "${q.replace(/"/g, '\\"')}"`);
        return JSON.parse(raw).result.records || [];
    } catch (e) {
        return [];
    }
}
function debugMap(log) {
    const map = {};
    for (const line of String(log || '').split('\n')) {
        const m = /\|USER_DEBUG\|\[\d+\]\|[A-Z]+\|([A-Z0-9_]+)=([\s\S]*)$/.exec(line);
        if (m) map[m[1]] = m[2].trim();
    }
    return map;
}
function frontDoorUrl(org) {
    return JSON.parse(CLI(`sf org open --target-org ${org} --url-only --json`)).result.url;
}
/** The Template Manager tab api name — prefixed only in a namespaced/installed org. */
function tabApiName(org) {
    let ns = null;
    try {
        ns = JSON.parse(CLI(`sf org display --target-org ${org} --json`)).result.namespace || null;
    } catch (e) {
        /* ignore */
    }
    if (!ns) {
        try {
            const inst = JSON.parse(CLI(`sf package installed list --target-org ${org} --json`)).result || [];
            const pkg = inst.find((p) => String(p.SubscriberPackageNamespace || '').length > 0);
            if (pkg) ns = pkg.SubscriberPackageNamespace;
        } catch (e) {
            /* ignore */
        }
    }
    return (ns ? ns + '__' : '') + 'DocGen_Template_Manager';
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

// CRC32 + a minimal PNG encoder — so the source is a KNOWN fully-opaque image
// (alpha 255 everywhere) and the expected baked alpha is unambiguous.
const CRC_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
        let c = n;
        for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        t[n] = c >>> 0;
    }
    return t;
})();
const crc32 = (buf) => {
    let c = 0xffffffff;
    for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
};
const pngChunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
};
/** Solid RGBA PNG, `size` x `size`, colour `[r,g,b,a]`. */
function makeSolidPng(size, [r, g, b, a]) {
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(size, 0);
    ihdr.writeUInt32BE(size, 4);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type RGBA
    const stride = size * 4;
    const raw = Buffer.alloc(size * (stride + 1));
    for (let y = 0; y < size; y++) {
        raw[y * (stride + 1)] = 0; // filter: none
        for (let x = 0; x < size; x++) {
            const o = y * (stride + 1) + 1 + x * 4;
            raw[o] = r;
            raw[o + 1] = g;
            raw[o + 2] = b;
            raw[o + 3] = a;
        }
    }
    return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        pngChunk('IHDR', ihdr),
        pngChunk('IDAT', deflateSync(raw)),
        pngChunk('IEND', Buffer.alloc(0))
    ]);
}

const DEEP = `
  const __deep = (el) => {
    if (!el) return '';
    let s = '';
    const walk = (n) => {
      if (n.nodeType === 3) { s += n.nodeValue + ' '; return; }
      if (n.nodeType === 1 && n.shadowRoot) walk(n.shadowRoot);
      if (n.nodeType !== 1 && n.nodeType !== 11 && n.nodeType !== 9) return;
      for (const c of n.childNodes) walk(c);
    };
    walk(el);
    return s.split(/[ ]+/).join(' ').trim();
  };
  const __all = (sel) => {
    const hit = [];
    const walk = (root) => {
      if (root.querySelectorAll) for (const el of root.querySelectorAll(sel)) hit.push(el);
      for (const el of (root.querySelectorAll ? root.querySelectorAll('*') : []))
        if (el.shadowRoot) walk(el.shadowRoot);
    };
    walk(document);
    return hit;
  };
  const __vis = (el) => {
    if (!el) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && parseFloat(cs.opacity || '1') > 0.02;
  };`;

async function login(page, org) {
    const url = frontDoorUrl(org);
    await page.goto(url, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(4000);
    await page
        .evaluate(async () => {
            try {
                localStorage.clear();
                sessionStorage.clear();
            } catch (e) {
                /* blocked */
            }
            if (indexedDB.databases) {
                const dbs = await indexedDB.databases();
                await Promise.all(
                    dbs.map(
                        (d) =>
                            new Promise((res) => {
                                const r = indexedDB.deleteDatabase(d.name);
                                r.onsuccess = r.onerror = r.onblocked = () => res();
                            })
                    )
                );
            }
        })
        .catch(() => {});
    return new URL(url).origin.replace('.my.salesforce.com', '.lightning.force.com');
}
async function openTab(page, base, apiName, waitMs = 6000) {
    await page.goto(`${base}/lightning/n/${apiName}?qa=${Date.now()}`, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(waitMs);
}

const ev = (page, body, fb = null) => page.evaluate(inPage(DEEP + '\n' + body)).catch(() => fb);

const box = (page, body) =>
    ev(
        page,
        `const el = (() => {${body}})();
     if (!el) return null;
     el.scrollIntoView({ block: 'center', inline: 'center' });
     const r = el.getBoundingClientRect();
     return { x: r.left + r.width / 2, y: r.top + r.height / 2 };`
    );

async function clickText(page, sel, text) {
    const b = await box(
        page,
        `for (const el of __all(${JSON.stringify(sel)}))
       if (__vis(el) && __deep(el).toLowerCase().includes(${JSON.stringify(text.toLowerCase())})) return el;
     return null;`
    );
    if (!b) return false;
    await page.mouse.click(b.x, b.y);
    return true;
}

async function openEditModalOnWatermarkTab(page, base) {
    await openTab(page, base, APP, 9000);
    await clickText(page, '[role="tab"]', 'Your Templates');
    await wait(4000);
    // Narrow the list to our template if there is a search box.
    const typedSearch = await ev(
        page,
        `const inp = __all('input[type="search"], lightning-input input').find(__vis);
     if (!inp) return false;
     inp.focus(); inp.value = ${JSON.stringify(NAME)};
     inp.dispatchEvent(new Event('input', { bubbles: true }));
     inp.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Enter' }));
     return true;`
    );
    await wait(typedSearch ? 3500 : 0);
    const rowsSeen = await ev(
        page,
        `const dt = __all('lightning-datatable')[0];
     if (!dt || !dt.shadowRoot) return { dt: false };
     const rows = [...dt.shadowRoot.querySelectorAll('tbody tr')];
     return { dt: true, count: rows.length, mine: rows.some((r) => __deep(r).includes(${JSON.stringify(NAME)})) };`,
        { dt: false }
    );
    if (!rowsSeen.dt || !rowsSeen.mine) {
        await page.screenshot({ path: join(tmpdir(), 'qawm-nolist.png') }).catch(() => {});
        throw new Error(`template not in list — ${JSON.stringify(rowsSeen)} (search box used: ${typedSearch})`);
    }
    // Row menu -> Edit
    const trig = await box(
        page,
        `const deepQ = (root, sel, out) => {
       if (root.querySelectorAll) for (const el of root.querySelectorAll(sel)) out.push(el);
       for (const el of (root.querySelectorAll ? root.querySelectorAll('*') : []))
         if (el.shadowRoot) deepQ(el.shadowRoot, sel, out);
       return out;
     };
     const dt = __all('lightning-datatable')[0];
     if (!dt || !dt.shadowRoot) return null;
     const row = [...dt.shadowRoot.querySelectorAll('tbody tr')].find((tr) => __deep(tr).includes(${JSON.stringify(NAME)}));
     if (!row) return null;
     return deepQ(row, 'button[aria-haspopup="true"], button.slds-button_icon-x-small, lightning-button-menu button', [])[0] || null;`
    );
    if (!trig) throw new Error('row menu trigger not found for ' + NAME);
    await page.mouse.click(trig.x, trig.y);
    await wait(1200);
    if (!(await clickText(page, '[role="menuitem"]', 'edit'))) throw new Error('Edit menu item not found');
    await wait(5000);
    if (!(await clickText(page, '[role="tab"]', 'Watermark'))) throw new Error('Watermark tab not found');
    await wait(2500);
}

async function washedFileName(versionId) {
    const rows = await soql(
        ORG,
        `SELECT PathOnClient FROM ContentVersion WHERE Title = 'docgen_watermark_${versionId}' AND IsLatest = true ORDER BY CreatedDate DESC`
    );
    return rows.length ? rows[0].PathOnClient : null;
}
async function washedCount(versionId) {
    const rows = await soql(
        ORG,
        `SELECT Id FROM ContentVersion WHERE Title = 'docgen_watermark_${versionId}' AND IsLatest = true`
    );
    return rows.length;
}
async function sourceCount(versionId) {
    const rows = await soql(
        ORG,
        `SELECT Id FROM ContentVersion WHERE Title = 'docgen_watermark_src_${versionId}' AND IsLatest = true`
    );
    return rows.length;
}
async function pollWashed(versionId, want, timeout = 25000) {
    const end = Date.now() + timeout;
    for (;;) {
        if ((await washedFileName(versionId)) === want) return true;
        if (Date.now() > end) return false;
        await wait(1500);
    }
}
/** Pull the stored BAKED watermark PNG bytes for a version (base64) via Apex. */
function storedWatermarkPngB64(versionId) {
    const log = runAnonymous(
        ORG,
        `Id cv = [SELECT Watermark_Image_CV_Id__c FROM DocGen_Template_Version__c WHERE Id = '${versionId}'].Watermark_Image_CV_Id__c;
Blob b = [SELECT VersionData FROM ContentVersion WHERE Id = :cv].VersionData;
System.debug('B64=' + EncodingUtil.base64Encode(b));`
    );
    return debugMap(log).B64 || null;
}
/** Pull the retained UNBAKED source PNG bytes for a version (base64) via Apex. */
function storedSourcePngB64(versionId) {
    const log = runAnonymous(
        ORG,
        `Blob b = [SELECT VersionData FROM ContentVersion WHERE Title = 'docgen_watermark_src_${versionId}' AND IsLatest = true ORDER BY CreatedDate DESC LIMIT 1].VersionData;
System.debug('B64=' + EncodingUtil.base64Encode(b));`
    );
    return debugMap(log).B64 || null;
}
/**
 * Mean alpha (0-255) of a small RGBA PNG's pixels, decoded in Node — no canvas,
 * no CORS. The source is a fully opaque red PNG, so after `ctx.globalAlpha =
 * pct/100` every stored pixel carries alpha ~= round(255 * pct/100).
 */
function meanAlphaOfPng(b64) {
    const buf = Buffer.from(b64, 'base64');
    let p = 8; // skip signature
    let w = 0;
    let h = 0;
    let colorType = 0;
    const idat = [];
    while (p < buf.length) {
        const len = buf.readUInt32BE(p);
        const type = buf.toString('ascii', p + 4, p + 8);
        const data = buf.subarray(p + 8, p + 8 + len);
        if (type === 'IHDR') {
            w = data.readUInt32BE(0);
            h = data.readUInt32BE(4);
            colorType = data[9];
        } else if (type === 'IDAT') {
            idat.push(data);
        } else if (type === 'IEND') {
            break;
        }
        p += 12 + len;
    }
    if (colorType !== 6) throw new Error('expected RGBA PNG (colorType 6), got ' + colorType);
    const raw = inflateSync(Buffer.concat(idat));
    const bpp = 4;
    const stride = w * bpp;
    const out = Buffer.alloc(h * stride);
    const pa = (r, c) => (r < 0 || c < 0 ? 0 : out[r * stride + c]);
    for (let y = 0; y < h; y++) {
        const filter = raw[y * (stride + 1)];
        const rowIn = raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
        for (let x = 0; x < stride; x++) {
            const a = x >= bpp ? out[y * stride + x - bpp] : 0;
            const b = pa(y - 1, x);
            const cc = x >= bpp ? pa(y - 1, x - bpp) : 0;
            let v = rowIn[x];
            if (filter === 1) v += a;
            else if (filter === 2) v += b;
            else if (filter === 3) v += (a + b) >> 1;
            else if (filter === 4) {
                const pp = a + b - cc;
                const pa1 = Math.abs(pp - a);
                const pb = Math.abs(pp - b);
                const pc = Math.abs(pp - cc);
                v += pa1 <= pb && pa1 <= pc ? a : pb <= pc ? b : cc;
            }
            out[y * stride + x] = v & 0xff;
        }
    }
    let sum = 0;
    let n = 0;
    for (let i = 3; i < out.length; i += 4) {
        sum += out[i];
        n++;
    }
    return n ? Math.round(sum / n) : 0;
}
const safeAlpha = (b64) => {
    if (!b64) return -1;
    try {
        return meanAlphaOfPng(b64);
    } catch (e) {
        return -1;
    }
};
const bakedAlpha = (versionId) => safeAlpha(storedWatermarkPngB64(versionId));
const sourceAlpha = (versionId) => safeAlpha(storedSourcePngB64(versionId));
/** got is within tol of (base * pct/100) — the alpha a correct bake produces. */
const nearPct = (got, base, pct, tol = 14) => Math.abs(got - (base * pct) / 100) <= tol;

async function main() {
    // ---- setup -------------------------------------------------------------
    const setup = await runAnonymous(
        ORG,
        `DocGen_Template__c t = new DocGen_Template__c(Name = '${NAME}', Base_Object_API__c = 'Account', Type__c = 'Word', Output_Format__c = 'PDF', Query_Config__c = 'Name', Category__c = 'QA');
insert t;
DocGen_Template_Version__c v = new DocGen_Template_Version__c(Template__c = t.Id, Is_Active__c = true, Type__c = 'Word', Base_Object_API__c = 'Account', Query_Config__c = 'Name', Category__c = 'QA');
insert v;
System.debug('TID=' + t.Id);
System.debug('VID=' + v.Id);`
    );
    const { TID, VID } = debugMap(setup);
    if (!VID) throw new Error('setup did not return a version id:\n' + setup);
    console.log(`\ntemplate ${TID}  version ${VID}\n`);

    const dir = mkdtempSync(join(tmpdir(), 'qawm-'));
    const png = join(dir, 'wm.png');
    // A fully opaque (alpha 255) 8x8 red square, so a correct bake at N% leaves
    // the stored pixels at alpha ~= 255 * N/100 with nothing to explain away.
    writeFileSync(png, makeSolidPng(8, [220, 40, 40, 255]));

    APP = tabApiName(ORG);
    console.log(`app tab: ${APP}\n`);

    const beat = HEADED ? (m) => (console.log('\n>>> ' + m), wait(2500)) : () => Promise.resolve();

    const { browser, page } = await launch({ headed: HEADED });
    try {
        const base = await login(page, ORG);

        // ---- 1. upload at 30% ---------------------------------------------
        await beat('Open the template on its Watermark tab');
        await openEditModalOnWatermarkTab(page, base);
        await beat('Upload a watermark image with the strength dropdown on 30%');
        await page.locator('input[data-id="watermarkFileInput"]').setInputFiles(png);
        const uploaded = await pollWashed(VID, 'watermark-p30.png');
        ok(uploaded, `upload at 30% stores a baked image named watermark-p30.png (got ${await washedFileName(VID)})`);
        ok(
            (await sourceCount(VID)) === 1,
            `the unbaked original is retained (source CV count = ${await sourceCount(VID)})`
        );
        const src = sourceAlpha(VID);
        ok(src >= 245, `the retained original is stored UNBAKED (source alpha ${src}/255)`);
        const a30 = bakedAlpha(VID);
        ok(
            nearPct(a30, src, 30),
            `the stored image's pixels are baked to 30% (alpha ${a30}/255, expected ~${Math.round((src * 30) / 100)})`
        );

        // ---- 2. change to 50% -------------------------------------------
        await beat('Now change the strength to 50% — the bug: this used to do nothing');
        await page
            .locator('.slds-modal select')
            .filter({ hasText: 'wash' })
            .first()
            .selectOption('50')
            .catch(async () => {
                // fallback: first dg-page-select inside the modal
                await page.locator('.slds-modal select.dg-page-select').first().selectOption('50');
            });
        const rebaked = await pollWashed(VID, 'watermark-p50.png');
        ok(rebaked, `changing the strength to 50% re-bakes the image (got ${await washedFileName(VID)})`);
        ok(
            (await washedCount(VID)) === 1 && (await sourceCount(VID)) === 1,
            `no ContentVersion pile-up after the change (baked=${await washedCount(VID)}, source=${await sourceCount(VID)})`
        );
        const a50 = bakedAlpha(VID);
        ok(
            nearPct(a50, src, 50),
            `the stored image is now baked to 50% (alpha ${a50}/255, expected ~${Math.round((src * 50) / 100)})`
        );
        ok(
            sourceAlpha(VID) >= 245,
            `the retained original is STILL unbaked, not re-washed (source alpha ${sourceAlpha(VID)})`
        );
        ok(a50 > a30 + 15, `50% is visibly more opaque than the earlier 30% (${a50} vs ${a30})`);

        // ---- 3. reload, reopen -----------------------------------------
        await beat('Reload the whole page and reopen the tab — dropdown should still say 50%');
        const seeded = await (async () => {
            await openEditModalOnWatermarkTab(page, base);
            return ev(
                page,
                `const s = __all('.slds-modal select.dg-page-select').filter(__vis)[0] ||
                  __all('select.dg-page-select').filter(__vis)[0];
         return s ? s.value : null;`
            );
        })();
        ok(seeded === '50', `after a page reload the strength control reads 50%, not the default (got ${seeded})`);

        // ---- 4. change to 15% — must bake from the ORIGINAL ------------
        await beat('Change it again to 15% — the post-reload path that threw a TypeError on PR #357');
        await page.locator('.slds-modal select.dg-page-select').first().selectOption('15');
        const rebaked15 = await pollWashed(VID, 'watermark-p15.png');
        ok(rebaked15, `a second change (15%) re-bakes again (got ${await washedFileName(VID)})`);
        ok(
            (await washedCount(VID)) === 1 && (await sourceCount(VID)) === 1,
            `still exactly one baked image and one source after two changes`
        );
        const a15 = bakedAlpha(VID);
        ok(
            nearPct(a15, src, 15),
            `the stored image is baked to 15% (alpha ${a15}/255, expected ~${Math.round((src * 15) / 100)})`
        );
        // Compounded (15% of the stored 50% wash) would be ~0.15*a50; from the
        // original it is ~0.15*src. src is ~1.7x a50, so the two are far apart.
        ok(
            Math.abs(a15 - (src * 15) / 100) < Math.abs(a15 - (a50 * 15) / 100),
            `15% baked from the ORIGINAL (~${Math.round((src * 15) / 100)}), not compounded onto the 50% wash (~${Math.round((a50 * 15) / 100)}); got ${a15}`
        );
        await beat('Done — all assertions passed');
    } finally {
        if (HEADED) await wait(4000);
        await browser.close();
        try {
            runAnonymous(ORG, `delete [SELECT Id FROM DocGen_Template__c WHERE Name = '${NAME}'];`);
        } catch (e) {
            /* leave the QAWM- template for manual cleanup */
        }
    }

    console.log(fail ? `\n${fail} FAILED` : '\nwatermark opacity works end to end');
    process.exit(fail ? 1 : 0);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
