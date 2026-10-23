#!/usr/bin/env node
/**
 * Designer UI smoke test.
 *
 * WHY THIS EXISTS
 * ---------------
 * A toolbar rewrite shipped that measured perfectly — one row, 9 clusters, 38px tall —
 * and was completely broken: every popover opened inside a clipping container and was
 * invisible, and the menu toggles never fired. Measuring layout is not testing. This
 * script drives every control the way a person would and asserts the document actually
 * changed, so that class of regression cannot ship again.
 *
 * It also clears Lightning's IndexedDB component cache before testing. Lightning served
 * stale bundles during manual verification and silently invalidated two separate runs;
 * any check that skips this step can pass against code that is no longer deployed.
 *
 * USAGE
 *   node scripts/ui-smoke.mjs --org docgen-verify [--template "Verify — Designer"] [--headed]
 *
 * EXIT CODE
 *   0 = every control behaved; non-zero = at least one did not (details printed).
 */

import { execFileSync } from 'node:child_process';
import { chromium } from 'playwright';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const args = process.argv.slice(2);
const argVal = (name, fallback = null) => {
    const i = args.indexOf(name);
    return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
};
const ORG = argVal('--org', 'docgen-verify');
const TEMPLATE_HINT = argVal('--template', 'Verify');
const HEADED = args.includes('--headed');

const results = [];
const record = (name, ok, detail = '') => {
    results.push({ name, ok, detail });
    process.stdout.write(`${ok ? '  PASS' : '  FAIL'}  ${name}${detail ? ` — ${detail}` : ''}\n`);
};

function frontDoorUrl(org) {
    // shell: true — on Windows, execFileSync spawns 'sf' directly and never
    // consults PATHEXT, so it can't find the sf.cmd/sf.ps1 shim npm installs;
    // only a real shell resolves it. Confirmed needed on this machine.
    const raw = execFileSync('sf', ['org', 'open', '--target-org', org, '--url-only', '--json'], {
        encoding: 'utf8',
        shell: true
    });
    return JSON.parse(raw).result.url;
}

/**
 * The Template Manager tab carries the package namespace prefix in a packaged or
 * namespaced org, and no prefix in a source-deployed one. Hardcoding the prefix
 * made this script navigate to "Page doesn't exist" in every org
 * scripts/qa/setup-org.sh produces — that script creates the org --no-namespace so
 * the e2e Apex compiles — and then time out for 30s waiting on a tab that could
 * never appear. The designer's only regression guard was therefore unrunnable
 * against the standard QA org, which is how a class of dead interactions ships
 * unnoticed. Resolve the prefix from the org instead of assuming it.
 */
function tabPath(org) {
    // Three shapes, and org namespace alone does not distinguish them:
    //   source-deployed, no namespace   -> DocGen_Template_Manager
    //   namespaced scratch org          -> portwoodglobal__DocGen_Template_Manager
    //   SUBSCRIBER org, package INSTALLED -> portwoodglobal__DocGen_Template_Manager
    //     ...but `sf org display` reports namespace: null there, because a subscriber
    //     org does not OWN the namespace, it receives it from the package. Reading only
    //     the org namespace therefore gets the install case exactly backwards, so also
    //     ask which packages are installed.
    const run = (argv) => {
        try {
            return JSON.parse(
                execFileSync('sf', argv, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], shell: true })
            ).result;
        } catch {
            return null;
        }
    };
    const own = (run(['org', 'display', '--target-org', org, '--json']) || {}).namespace || null;
    if (own) return `/lightning/n/${own}__DocGen_Template_Manager`;

    const installed = run(['package', 'installed', 'list', '--target-org', org, '--json']) || [];
    const pkg = (Array.isArray(installed) ? installed : []).find(
        (p) => String(p.SubscriberPackageNamespace || '').length > 0
    );
    if (pkg) return `/lightning/n/${pkg.SubscriberPackageNamespace}__DocGen_Template_Manager`;

    return '/lightning/n/DocGen_Template_Manager';
}

/**
 * Piercing query: the Designer lives inside LWC shadow roots, so a plain
 * document.querySelector never finds it.
 */
const PIERCE = `
  const __dgFind = (sel, all) => {
    const hit = [];
    const walk = (root) => {
      if (root.querySelectorAll) {
        for (const el of root.querySelectorAll(sel)) { hit.push(el); if (!all && hit.length) return true; }
      }
      for (const el of (root.querySelectorAll ? root.querySelectorAll('*') : [])) {
        if (el.shadowRoot && walk(el.shadowRoot)) return true;
      }
      return false;
    };
    walk(document);
    return all ? hit : (hit[0] || null);
  };`;

/**
 * page.evaluate(string) evaluates its argument as an EXPRESSION, so a bare function
 * declaration is a SyntaxError. Everything gets wrapped in an IIFE that returns the
 * body's value.
 */
const inPage = (body) => `(() => {${PIERCE}\n return (() => {${body}})(); })()`;

/**
 * Opens the Tags rail and waits until chips are actually on screen.
 *
 * A single click-then-wait was flaky: handlePanelToggle toggles, the rail can already
 * be open or closed depending on what the previous block did, and one fixed 700ms wait
 * sometimes lost the race. That produced runs reporting "no chip available to insert" —
 * a precondition failure wearing the costume of a real regression, which is the fastest
 * way to teach someone to ignore this suite. Poll instead: only click when the chips
 * are absent, then give the render a chance, up to `tries` times.
 */
async function ensureTagRail(page, inPageFn, tries = 6) {
    for (let i = 0; i < tries; i++) {
        const seen = await page.evaluate(
            inPageFn(
                `return { chips: !!__dgFind('.dg-tag-chip[data-snippet]'), btn: !!__dgFind('[data-panel="tags"]') };`
            )
        );
        if (seen.chips) return true;
        if (!seen.btn) return false;
        await page.evaluate(inPageFn(`const b = __dgFind('[data-panel="tags"]'); if (b) b.click(); return true;`));
        await page.waitForTimeout(600);
    }
    return await page.evaluate(inPageFn(`return !!__dgFind('.dg-tag-chip[data-snippet]');`));
}

async function main() {
    console.log(`\nDesigner UI smoke — org: ${ORG}\n`);
    const url = frontDoorUrl(ORG);
    const browser = await chromium.launch({ headless: !HEADED });
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    const page = await ctx.newPage();
    const consoleErrors = [];
    page.on('console', (m) => {
        if (m.type() === 'error') consoleErrors.push(m.text());
    });
    page.on('pageerror', (e) => consoleErrors.push('pageerror: ' + e.message));

    try {
        await page.goto(url, { waitUntil: 'domcontentloaded' });
        await page.waitForTimeout(4000);

        // --- Lightning cache bust -------------------------------------------------
        // Without this the browser can run a bundle that is no longer deployed.
        await page.evaluate(async () => {
            try {
                localStorage.clear();
                sessionStorage.clear();
            } catch (e) {
                /* storage may be blocked */
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
        });

        const base = new URL(url).origin.replace('.my.salesforce.com', '.lightning.force.com');
        await page.goto(`${base}${tabPath(ORG)}?smoke=${Date.now()}`, {
            waitUntil: 'domcontentloaded'
        });
        await page.waitForTimeout(6000);

        // --- Open the Designer on a template -------------------------------------
        await page.locator('[role="tab"]:has-text("Your Templates")').first().click();
        await page.waitForTimeout(2500);
        const row = page.locator(`tr:has-text("${TEMPLATE_HINT}")`).first();
        await row.locator('button[aria-haspopup="true"]').first().click();
        await page.waitForTimeout(800);
        await page.locator('[role="menuitem"]:has-text("Design")').first().click();
        await page.waitForTimeout(6000);

        const ready = await page.evaluate(
            inPage(`return { bar: !!__dgFind('.dg-format-bar'), pv: !!__dgFind('.dg-pv') };`)
        );
        record('designer opens (toolbar + canvas present)', ready.bar && ready.pv, JSON.stringify(ready));
        if (!ready.bar || !ready.pv) throw new Error('Designer did not open — aborting');

        // --- 1. Every toolbar control changes the document ------------------------
        const controlReport = await page.evaluate(
            inPage(`
      const bar = __dgFind('.dg-format-bar');
      const pv = __dgFind('.dg-pv');
      const out = [];
      // Full reset per control. Reusing whatever block survived the previous command
      // makes results order-dependent — the bullet-list test replaces the <p> with a
      // <ul>, so the ordered-list test that follows was operating on a different
      // element entirely. Each control now starts from an identical document.
      //
      // The baseline is deliberately CONTRARY (red, bold, Times, highlighted) so
      // commands whose result is already the current state still have something to
      // change. Alignment is the exception: it is seeded opposite to whichever
      // alignment is under test, since "centre" on centred text is a legitimate no-op.
      const seed = (label) => {
        pv.focus();
        const style = pv.querySelector('style');
        while (pv.firstChild) pv.removeChild(pv.firstChild);
        if (style) pv.appendChild(style);
        const p = document.createElement('p');
        p.style.textAlign = /center|centre/i.test(label) ? 'left'
                          : /right/i.test(label) ? 'left'
                          : /left/i.test(label) ? 'center'
                          : 'center';
        p.innerHTML = '<span style="color:#e01e1e;font-family:Times,serif;font-weight:bold;background-color:#fff3a3">smoke probe text</span>';
        pv.appendChild(p);
        const r = document.createRange();
        r.selectNodeContents(p);
        const s = window.getSelection();
        s.removeAllRanges(); s.addRange(r);
        return p;
      };
      const label0 = (b) => (b.textContent || b.title || b.dataset.cmd || b.dataset.taction || '?').trim();
      const clickable = [...bar.querySelectorAll('button')].filter(b => {
        const t = (b.textContent || '').trim();
        // undo/redo have no stable effect on a fresh doc; zoom is a view control.
        void t;
        // Undo/redo cannot be asserted after a programmatic DOM reset — the browser's
        // undo stack does not track our manual DOM writes. Zoom is a view control.
        // Menu triggers open chrome rather than mutating the document; they have
        // their own popover assertions. Leaving them in this loop also left their
        // menus OPEN, which then toggled shut under the later tests.
        if (b.getAttribute('aria-haspopup') === 'true' || b.dataset.menu) return false;
        // View controls (zoom, focus mode) change what you SEE, never the document.
        if (b.dataset.viewctl) return false;
        return b.dataset.cmd !== 'undo' && b.dataset.cmd !== 'redo' && !b.dataset.zstep && !b.dataset.szstep;
      });
      for (const b of clickable) {
        seed(label0(b));
        const before = pv.innerHTML;
        let opensMenu = !!b.dataset.menu;
        b.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        b.click();
        const after = pv.innerHTML;
        const label = (b.textContent || b.title || b.dataset.cmd || b.dataset.taction || '?').trim().slice(0, 22);
        out.push({
          label,
          kind: opensMenu ? 'menu' : (b.dataset.taction ? 'table' : 'format'),
          changed: before !== after,
          menuKey: b.dataset.menu || null
        });
      }
      return { total: clickable.length, controls: out };`)
        );

        for (const c of controlReport.controls) {
            if (c.kind === 'menu') continue; // asserted separately below
            if (c.kind === 'table') continue; // needs a table context; covered in table section
            record(`toolbar: ${c.label}`, c.changed, c.changed ? '' : 'clicking it changed nothing');
        }

        // --- 3. Header / footer surfaces get the same treatment as the body -------
        for (const which of ['header', 'footer']) {
            const r = await page.evaluate(
                inPage(`
        const which = '${which}';
        const band = __dgFind('.dg-chrome-band_' + which);
        if (!band) return { ok:false, why:'band not rendered' };
        if (band.getAttribute('contenteditable') !== 'true') return { ok:false, why:'band not editable' };
        const bar = __dgFind('.dg-format-bar');
        const bold = [...bar.querySelectorAll('button')].find(b => (b.textContent||'').trim() === 'B');
        if (!bold) return { ok:false, why:'no bold button' };
        band.focus();
        let p = band.querySelector('p, div, span') || band;
        if (!p.textContent.trim()) p.textContent = 'band probe';
        const r2 = document.createRange();
        r2.selectNodeContents(p);
        const s = window.getSelection();
        s.removeAllRanges(); s.addRange(r2);
        const before = band.innerHTML;
        bold.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        bold.click();
        return { ok: band.innerHTML !== before, why: band.innerHTML !== before ? '' : 'bold did not affect the band' };`)
            );
            record(`surface parity: bold works in ${which}`, r.ok, r.why);
        }

        // --- 4. Zoom scales the whole sheet, including the bands ------------------
        const zoomReport = await page.evaluate(
            inPage(`
      const bar = __dgFind('.dg-format-bar');
      const sel = [...bar.querySelectorAll('select')].find(s => /%/.test(s.options[s.selectedIndex] ? s.options[s.selectedIndex].text : ''));
      if (!sel) return { supported:false, why:'no zoom select found' };
      const pv = __dgFind('.dg-pv');
      const hdr = __dgFind('.dg-chrome-band_header');
      const before = { pv: pv.getBoundingClientRect().width, hdr: hdr ? hdr.getBoundingClientRect().width : null };
      sel.value = '1.5';
      sel.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
      const after = { pv: pv.getBoundingClientRect().width, hdr: hdr ? hdr.getBoundingClientRect().width : null };
      return {
        supported: true,
        bodyScaled: after.pv > before.pv * 1.2,
        headerScaled: after.hdr != null ? after.hdr > before.hdr * 1.2 : null,
        before, after
      };`)
        );
        if (zoomReport.supported) {
            record(
                'zoom: body scales',
                !!zoomReport.bodyScaled,
                JSON.stringify(zoomReport.before) + ' -> ' + JSON.stringify(zoomReport.after)
            );
            record(
                'zoom: header scales with the sheet',
                zoomReport.headerScaled === true,
                zoomReport.headerScaled === null ? 'no header band' : 'header must scale with the page'
            );
        } else {
            record('zoom: control present', false, zoomReport.why);
        }

        // --- 4b. Contextual table row: hidden outside a table, functional inside --
        // Density comes from hiding ~45 controls until they are relevant. That is only
        // an improvement if they reliably COME BACK, so assert both halves.
        const tableCtx = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const bar = () => __dgFind('.dg-format-bar');
      const countTableBtns = () => bar().querySelectorAll('[data-taction]').length;
      const style = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (style) pv.appendChild(style);

      // Caret in a plain paragraph -> table tools should be absent.
      const p = document.createElement('p');
      p.textContent = 'outside any table';
      pv.appendChild(p);
      pv.focus();
      let r = document.createRange(); r.selectNodeContents(p);
      let s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      document.dispatchEvent(new Event('selectionchange'));
      return new Promise((resolve) => setTimeout(() => {
        const hiddenOutside = countTableBtns() === 0;

        // Caret inside a table cell -> table tools should appear and work.
        const tbl = document.createElement('table');
        tbl.innerHTML = '<tr><td>cell one</td><td>cell two</td></tr>';
        pv.appendChild(tbl);
        const td = tbl.querySelector('td');
        const r2 = document.createRange(); r2.selectNodeContents(td);
        const s2 = window.getSelection(); s2.removeAllRanges(); s2.addRange(r2);
        document.dispatchEvent(new Event('selectionchange'));
        setTimeout(() => {
          const shownInside = countTableBtns() > 0;
          let rowAdded = false;
          const addRow = bar().querySelector('[data-taction="rowAfter"]');
          if (addRow) {
            const before = tbl.rows.length;
            addRow.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
            addRow.click();
            rowAdded = tbl.rows.length === before + 1;
          }
          resolve({ hiddenOutside, shownInside, rowAdded, btnCount: countTableBtns() });
        }, 400);
      }, 400));`)
        );
        record(
            'table tools hidden outside a table',
            tableCtx.hiddenOutside,
            `${tableCtx.btnCount} table buttons visible`
        );
        record('table tools appear inside a table', tableCtx.shownInside, '');
        record('table tools work when shown (+ Row)', tableCtx.rowAdded, '');

        // Confluence-style seam inserts: a + on the boundary where the new column/row
        // lands. Assert they exist, are not ghost click targets, and actually insert.
        const seams = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const wrap = __dgFind('.dg-canvas-wrap');
      const tbl = pv.querySelector('table');
      if (!tbl) return { ok:false, why:'no table in canvas' };
      // Dispatch on a CELL, not the canvas: _updateTableOverlay resolves the table
      // from event.target, and a synthetic event on pv has target === pv, which is
      // not inside any table.
      const cell0 = tbl.querySelector('td, th') || tbl;
      const r = cell0.getBoundingClientRect();
      cell0.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true,
        clientX: Math.round(r.left + 5), clientY: Math.round(r.top + 5)}));
      return new Promise((resolve) => setTimeout(() => {
        const all = __dgFind('.dg-tbl-seam', true) || [];
        if (!all.length) return resolve({ ok:false, why:'no seams rendered' });
        // Ghost-target contract.
        let ghost = null;
        for (const el of all) {
          const cs = getComputedStyle(el);
          if (parseFloat(cs.opacity) < 0.02 && cs.pointerEvents !== 'none') { ghost = 'seam at opacity 0 still clickable'; break; }
        }
        if (ghost) return resolve({ ok:false, why:ghost });
        // Functional: a column seam must add a column.
        const colSeam = all.find(e => e.dataset.axis === 'col');
        if (!colSeam) return resolve({ ok:false, why:'no column seam' });
        const before = tbl.rows[0].children.length;
        colSeam.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        colSeam.click();
        setTimeout(() => {
          const after = tbl.rows[0].children.length;
          resolve({ ok: after === before + 1, why: after === before + 1 ? '' : ('columns ' + before + ' -> ' + after), count: all.length });
        }, 250);
      }, 500));`)
        );
        record('table seams: render, no ghost targets, insert a column', seams.ok, seams.why);

        // Block gutter handle: appears for the hovered block, inserts, and reorders.
        const blocks = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const style = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (style) pv.appendChild(style);
      const a = document.createElement('p'); a.textContent = 'AAA'; pv.appendChild(a);
      const b = document.createElement('p'); b.textContent = 'BBB'; pv.appendChild(b);
      const r = a.getBoundingClientRect();
      a.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true,
        clientX: Math.round(r.left + 10), clientY: Math.round(r.top + 5)}));
      return new Promise((resolve) => setTimeout(() => {
        const h = __dgFind('.dg-blk-handle');
        if (!h) return resolve({ ok:false, why:'handle did not appear' });
        const cs = getComputedStyle(h);
        if (parseFloat(cs.opacity) < 0.02 && cs.pointerEvents !== 'none') {
          return resolve({ ok:false, why:'ghost click target' });
        }
        const btns = [...h.querySelectorAll('button')];
        const down = btns.find(x => x.dataset.dir === 'down');
        if (!down) return resolve({ ok:false, why:'no move control' });
        const orderBefore = [...pv.querySelectorAll('p')].map(p => p.textContent).join(',');
        down.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        down.click();
        setTimeout(() => {
          const orderAfter = [...pv.querySelectorAll('p')].map(p => p.textContent).join(',');
          resolve({ ok: orderBefore === 'AAA,BBB' && orderAfter === 'BBB,AAA',
                    why: orderBefore + ' -> ' + orderAfter });
        }, 250);
      }, 500));`)
        );
        record('block handle: appears and reorders blocks', blocks.ok, blocks.why);

        // Word-style grid picker: 4x3 must produce a 4-column, 4-row table (3 body
        // rows + header) that does NOT overhang the sheet.
        const grid = await page.evaluate(
            inPage(`
      const bar = __dgFind('.dg-format-bar');
      const pv = __dgFind('.dg-pv');
      const style = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (style) pv.appendChild(style);
      const p = document.createElement('p'); p.textContent = 'anchor'; pv.appendChild(p);
      pv.focus();
      const rr = document.createRange(); rr.selectNodeContents(p); rr.collapse(false);
      const ss = window.getSelection(); ss.removeAllRanges(); ss.addRange(rr);

      const trigger = [...bar.querySelectorAll('button')].find(b => /Table/.test(b.textContent||''));
      if (!trigger) return { ok:false, why:'grid trigger missing' };
      // LWC re-renders ASYNCHRONOUSLY, so a synchronous re-check after click always
      // sees the old DOM. Click, WAIT, then decide whether a second click is needed
      // (a previous test may have left the menu open, making the first click a close).
      const clickTrigger = () => {
        trigger.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        trigger.click();
      };
      clickTrigger();
      return new Promise((resolve) => setTimeout(() => {
        if (!__dgFind('.dg-grid-menu')) {
          clickTrigger();
        }
        setTimeout(() => {
        const menu = __dgFind('.dg-grid-menu');
        if (!menu) return resolve({ ok:false, why:'grid did not open' });
        const cs = getComputedStyle(menu);
        if (cs.position !== 'fixed') return resolve({ ok:false, why:'grid not fixed: ' + cs.position });
        const cell = menu.querySelector('[data-r="3"][data-c="4"]');
        if (!cell) return resolve({ ok:false, why:'no 4x3 cell' });
        cell.dispatchEvent(new MouseEvent('mouseenter', {bubbles:true, composed:true}));
        cell.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        cell.click();
        setTimeout(() => {
          const t = pv.querySelector('table');
          if (!t) return resolve({ ok:false, why:'no table inserted' });
          const cols = t.rows[0] ? t.rows[0].children.length : 0;
          const rows = t.rows.length;
          // Must not overhang the sheet.
          const pcs = getComputedStyle(pv);
          const contentW = pv.getBoundingClientRect().width
            - (parseFloat(pcs.paddingLeft)||0) - (parseFloat(pcs.paddingRight)||0);
          const overhang = t.getBoundingClientRect().width > contentW + 1;
          resolve({ ok: cols === 4 && rows === 4 && !overhang,
                    why: 'cols=' + cols + ' rows=' + rows + ' overhang=' + overhang });
        }, 300);
        }, 450);
      }, 450));`)
        );
        record('insert-table grid: 4x3 picker inserts and fits the page', grid.ok, grid.why);

        // Tables must never extend past the canvas, including after edits that grow
        // them (adding columns is the common way this happens).
        const overflow = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const t = pv.querySelector('table');
      if (!t) return { ok:false, why:'no table to test' };
      const bar = __dgFind('.dg-format-bar');
      // Put the caret in the table so the contextual tools appear.
      const td = t.querySelector('td, th');
      const r = document.createRange(); r.selectNodeContents(td);
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      document.dispatchEvent(new Event('selectionchange'));
      return new Promise((resolve) => setTimeout(() => {
        const addCol = bar.querySelector('[data-taction="colAfter"]');
        if (!addCol) return resolve({ ok:false, why:'no add-column control' });
        // Add several columns — enough to overhang without a clamp.
        for (let i = 0; i < 6; i++) {
          addCol.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
          addCol.click();
        }
        setTimeout(() => {
          const pcs = getComputedStyle(pv);
          const contentW = pv.getBoundingClientRect().width
            - (parseFloat(pcs.paddingLeft)||0) - (parseFloat(pcs.paddingRight)||0);
          const w = t.getBoundingClientRect().width;
          resolve({ ok: w <= contentW + 1, why: 'table ' + Math.round(w) + 'px vs content ' + Math.round(contentW) + 'px' });
        }, 350);
      }, 400));`)
        );
        record('table never extends past the canvas after adding columns', overflow.ok, overflow.why);

        // Cell-selection highlight must not linger.
        const stale = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const t = pv.querySelector('table');
      if (!t) return { ok:false, why:'no table' };
      const cells = [...t.querySelectorAll('td, th')];
      // Mark cells the way a drag-select does, then click elsewhere to clear.
      cells.slice(0, 3).forEach(c => { c.setAttribute('data-dg-selcell','1'); c.style.boxShadow = 'inset 0 0 0 2px #7c3aed'; });
      const p = document.createElement('p'); p.textContent = 'outside'; pv.appendChild(p);
      p.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
      p.dispatchEvent(new MouseEvent('click', {bubbles:true, composed:true, cancelable:true}));
      return new Promise((resolve) => setTimeout(() => {
        const left = pv.querySelectorAll('[data-dg-selcell]').length;
        resolve({ ok: left === 0, why: left + ' cells still marked selected' });
      }, 350));`)
        );
        record('cell selection highlight does not hang', stale.ok, stale.why);

        // --- 4c. Selection bubble: appears, is unclipped, and actually formats ----
        // The bubble is position: fixed precisely so no ancestor can clip it. Assert
        // that property directly rather than trusting the CSS — this is the same
        // class of check that would have caught the overflow regression.
        const bubble = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const style = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (style) pv.appendChild(style);
      const p = document.createElement('p');
      p.textContent = 'select me for the bubble';
      pv.appendChild(p);
      pv.focus();
      const r = document.createRange(); r.selectNodeContents(p);
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      document.dispatchEvent(new Event('selectionchange'));
      return new Promise((resolve) => setTimeout(() => {
        const el = __dgFind('.dg-sel-bubble');
        if (!el) return resolve({ appeared:false });
        const br = el.getBoundingClientRect();
        const cs = getComputedStyle(el);
        // No clipping ancestor may be smaller than the bubble.
        let clipper = null, node = el.parentElement;
        while (node && !clipper) {
          const ncs = getComputedStyle(node);
          if ((ncs.overflowX !== 'visible' || ncs.overflowY !== 'visible')) {
            const nr = node.getBoundingClientRect();
            if (nr.height < br.height - 1 || nr.width < br.width - 1) {
              clipper = (typeof node.className === 'string' && node.className ? node.className.split(' ')[0] : node.tagName)
                        + ' overflow:' + ncs.overflowX + '/' + ncs.overflowY;
            }
          }
          node = node.parentElement;
        }
        // Centre must be hit-testable.
        const cx = Math.round(br.left + br.width/2), cy = Math.round(br.top + br.height/2);
        let top = document.elementFromPoint(cx, cy), guard = 0;
        while (top && top.shadowRoot && guard++ < 10) {
          const inner = top.shadowRoot.elementFromPoint(cx, cy);
          if (!inner || inner === top) break;
          top = inner;
        }
        // Does it actually format?
        const bold = [...el.querySelectorAll('button')].find(b => (b.textContent||'').trim() === 'B');
        let formatted = false;
        if (bold) {
          const before = pv.innerHTML;
          bold.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
          bold.click();
          formatted = pv.innerHTML !== before;
        }
        // Must sit above the selection, not on top of it.
        const selRect = r.getBoundingClientRect();
        resolve({
          appeared: true,
          fixed: cs.position === 'fixed',
          onScreen: br.top >= 0 && br.left >= 0 && br.width > 20 && br.height > 10,
          hitTestable: !!(top && el.contains(top)),
          clipper,
          coversSelection: br.bottom > selRect.top + 2 && br.top < selRect.bottom - 2,
          formatted
        });
      }, 500));`)
        );
        record('bubble: appears on text selection', !!bubble.appeared, '');
        if (bubble.appeared) {
            record('bubble: position fixed (uncippable)', !!bubble.fixed, 'must be fixed, got ' + bubble.fixed);
            record('bubble: on screen with real size', !!bubble.onScreen, '');
            record('bubble: no clipping ancestor', !bubble.clipper, bubble.clipper || '');
            record('bubble: centre is hit-testable', !!bubble.hitTestable, '');
            record('bubble: does not cover the selection', !bubble.coversSelection, '');
            record('bubble: bold actually formats', !!bubble.formatted, '');
        }

        // --- 4c-2. Toolbar popovers: open, unclipped, hit-testable, functional ----
        // The exact thing that broke the editor before. Every trigger is opened and
        // its popover checked for the properties CSS review cannot see.
        for (const menuKey of ['textColor', 'highlight', 'font']) {
            const r = await page.evaluate(
                inPage(`
        const key = '${menuKey}';
        const bar = __dgFind('.dg-format-bar');
        const pv = __dgFind('.dg-pv');
        const trigger = bar.querySelector('[data-menu="' + key + '"]');
        if (!trigger) return { ok:false, why:'trigger missing' };

        // Seed a selection so the command has something to act on.
        const style = pv.querySelector('style');
        while (pv.firstChild) pv.removeChild(pv.firstChild);
        if (style) pv.appendChild(style);
        const p = document.createElement('p');
        // Background included so a "no highlight" choice is a real change rather
        // than a legitimate no-op on unhighlighted text.
        p.innerHTML = '<span style="color:#111;font-family:Times,serif;background-color:#ffe9a8">popover probe</span>';
        pv.appendChild(p);
        pv.focus();
        const sr = document.createRange(); sr.selectNodeContents(p);
        const s = window.getSelection(); s.removeAllRanges(); s.addRange(sr);

        trigger.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        trigger.click();
        return new Promise((resolve) => setTimeout(() => {
          const menu = __dgFind('.dg-fmt-menu');
          if (!menu) return resolve({ ok:false, why:'menu did not open' });
          const mr = menu.getBoundingClientRect();
          const cs = getComputedStyle(menu);
          if (mr.width < 8 || mr.height < 8) return resolve({ ok:false, why:'menu has no size' });
          if (cs.position !== 'fixed') return resolve({ ok:false, why:'not position:fixed, got ' + cs.position });

          // Clipping ancestor check.
          let clipper = null, node = menu.parentElement;
          while (node && !clipper) {
            const ncs = getComputedStyle(node);
            if (ncs.overflowX !== 'visible' || ncs.overflowY !== 'visible') {
              const nr = node.getBoundingClientRect();
              if (nr.height < mr.height - 1 || nr.width < mr.width - 1) {
                clipper = (typeof node.className === 'string' && node.className ? node.className.split(' ')[0] : node.tagName)
                          + ' overflow:' + ncs.overflowX + '/' + ncs.overflowY;
              }
            }
            node = node.parentElement;
          }
          if (clipper) return resolve({ ok:false, why:'clipped by ' + clipper });

          // Centre hit-test.
          const cx = Math.round(mr.left + mr.width/2), cy = Math.round(mr.top + mr.height/2);
          let top = document.elementFromPoint(cx, cy), guard = 0;
          while (top && top.shadowRoot && guard++ < 10) {
            const inner = top.shadowRoot.elementFromPoint(cx, cy);
            if (!inner || inner === top) break;
            top = inner;
          }
          if (!(top && menu.contains(top))) return resolve({ ok:false, why:'centre not hit-testable' });

          // On screen.
          if (mr.left < 0 || mr.top < 0 || mr.right > innerWidth + 1 || mr.bottom > innerHeight + 1) {
            return resolve({ ok:false, why:'off screen' });
          }

          // A choice inside it must actually format.
          const choice = menu.querySelector('.dg-fmt-swatch, .dg-fmt-menu-item');
          if (!choice) return resolve({ ok:false, why:'no choices inside' });
          const before = pv.innerHTML;
          choice.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
          choice.click();
          setTimeout(() => {
            resolve({ ok: pv.innerHTML !== before, why: pv.innerHTML !== before ? '' : 'choice did not format' });
          }, 200);
        }, 350));`)
            );
            record(`popover ${menuKey}: opens, unclipped, hit-testable, formats`, r.ok, r.why);
        }

        // --- 4c-3. Header/footer must BE the sheet, not panels above and below ----
        // "Part of the canvas" is measurable: same width as the page, horizontally
        // aligned with it, and no visible gap between band and page.
        const sheet = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const hdr = __dgFind('.dg-chrome-band_header');
      const ftr = __dgFind('.dg-chrome-band_footer');
      const sheetEl = __dgFind('.dg-sheet');
      if (!hdr || !ftr) return { ok:false, why:'bands missing' };
      if (!sheetEl) return { ok:false, why:'no .dg-sheet wrapper' };
      if (!(sheetEl.contains(pv) && sheetEl.contains(hdr) && sheetEl.contains(ftr))) {
        return { ok:false, why:'bands and page are not in the same sheet' };
      }
      const p = pv.getBoundingClientRect();
      const h = hdr.getBoundingClientRect();
      const f = ftr.getBoundingClientRect();
      const widthMatch = Math.abs(h.width - p.width) <= 2 && Math.abs(f.width - p.width) <= 2;
      const leftMatch = Math.abs(h.left - p.left) <= 2 && Math.abs(f.left - p.left) <= 2;
      // Flush: the header's bottom edge should meet the page's top edge.
      const gapTop = p.top - h.bottom;
      const gapBottom = f.top - p.bottom;
      const flush = Math.abs(gapTop) <= 3 && Math.abs(gapBottom) <= 3;
      return {
        ok: widthMatch && leftMatch && flush,
        why: 'w ' + Math.round(h.width) + '/' + Math.round(p.width) +
             ' left ' + Math.round(h.left) + '/' + Math.round(p.left) +
             ' gaps ' + Math.round(gapTop) + ',' + Math.round(gapBottom)
      };`)
        );
        record('header/footer are part of the sheet (width, alignment, flush)', sheet.ok, sheet.why);

        // --- 4c-4. Ghost preview, fit-width, focus mode --------------------------
        const extras = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const bar = __dgFind('.dg-format-bar');
      const style = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (style) pv.appendChild(style);
      const t = document.createElement('table');
      t.innerHTML = '<tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr>';
      pv.appendChild(t);
      const cell0 = t.querySelector('td');
      const cr = cell0.getBoundingClientRect();
      cell0.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true,
        clientX: Math.round(cr.left+5), clientY: Math.round(cr.top+5)}));
      return new Promise((resolve) => setTimeout(() => {
        const out = {};
        // Ghost on seam hover.
        const seam = (__dgFind('.dg-tbl-seam', true) || [])[0];
        if (!seam) { out.ghost = 'no seam'; }
        else {
          seam.dispatchEvent(new MouseEvent('mouseenter', {bubbles:true, composed:true}));
        }
        setTimeout(() => {
          const g = __dgFind('.dg-tbl-ghost');
          if (g) {
            const gr = g.getBoundingClientRect();
            const gcs = getComputedStyle(g);
            out.ghost = (gr.width > 4 && gr.height > 4 && gcs.pointerEvents === 'none') ? 'ok'
                        : ('bad size/pointer-events: ' + Math.round(gr.width) + 'x' + Math.round(gr.height) + ' pe=' + gcs.pointerEvents);
          } else if (!out.ghost) { out.ghost = 'ghost did not appear'; }

          // Fit width should widen the page toward the column.
          const sel = [...bar.querySelectorAll('select')].find(s2 => [...s2.options].some(o => o.value === 'fit'));
          if (!sel) { out.fit = 'no fit option'; }
          else {
            const before = pv.getBoundingClientRect().width;
            sel.value = 'fit';
            sel.dispatchEvent(new Event('change', {bubbles:true, composed:true}));
            setTimeout(() => {
              const after = pv.getBoundingClientRect().width;
              const col = __dgFind('.dg-designer-canvas-col');
              const colW = col ? col.getBoundingClientRect().width : 0;
              out.fit = (after >= before && after <= colW + 2) ? 'ok'
                        : ('page ' + Math.round(before) + '->' + Math.round(after) + ' col ' + Math.round(colW));

              // Focus mode should hide the setup rows.
              const focusBtn = bar.querySelector('[data-viewctl="focus"]');
              if (!focusBtn) { out.focus = 'no focus button'; resolve(out); return; }
              const chromeRow = __dgFind('.dg-designer-toolbar');
              const visBefore = chromeRow ? chromeRow.getBoundingClientRect().height > 0 : false;
              focusBtn.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
              focusBtn.click();
              setTimeout(() => {
                const row2 = __dgFind('.dg-designer-toolbar');
                const visAfter = row2 ? row2.getBoundingClientRect().height > 0 : false;
                out.focus = (visBefore && !visAfter) ? 'ok' : ('visible before=' + visBefore + ' after=' + visAfter);
                // restore
                const fb = __dgFind('[data-viewctl="focus"]');
                if (fb) { fb.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true})); fb.click(); }
                resolve(out);
              }, 400);
            }, 400);
          }
        }, 300);
      }, 500));`)
        );
        record('table +/- shows a ghost of what it will add/remove', extras.ghost === 'ok', extras.ghost || '');
        record('zoom: Fit width fills the column', extras.fit === 'ok', extras.fit || '');
        record('focus mode hides the setup chrome', extras.focus === 'ok', extras.focus || '');

        // --- 4c-5. Highlight residue, backspace floor, backtick menu -------------
        const hygiene = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const style = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (style) pv.appendChild(style);
      const a = document.createElement('p'); a.textContent = 'block one'; pv.appendChild(a);
      const b = document.createElement('p'); b.textContent = 'block two'; pv.appendChild(b);
      const t = document.createElement('table');
      t.innerHTML = '<tr><td>c1</td><td>c2</td></tr>';
      pv.appendChild(t);
      pv.focus();
      const put = (el) => {
        const r = document.createRange(); r.selectNodeContents(el); r.collapse(true);
        const s2 = window.getSelection(); s2.removeAllRanges(); s2.addRange(r);
        document.dispatchEvent(new Event('selectionchange'));
      };
      // Walk block -> block -> cell -> cell; only ONE region may stay highlighted.
      put(a);
      return new Promise((resolve) => setTimeout(() => {
        put(b);
        setTimeout(() => {
          const cells = t.querySelectorAll('td');
          put(cells[0]);
          setTimeout(() => {
            put(cells[1]);
            setTimeout(() => {
              const painted = pv.querySelectorAll('[data-dg-paint]').length;
              const out = { painted };

              // Backtick must open the insert menu.
              const p3 = document.createElement('p'); pv.appendChild(p3);
              const tn = document.createTextNode('\u0060');
              p3.appendChild(tn);
              const r3 = document.createRange();
              r3.setStart(tn, 1); r3.collapse(true);
              const s3 = window.getSelection(); s3.removeAllRanges(); s3.addRange(r3);
              pv.dispatchEvent(new Event('input', {bubbles:true}));
              setTimeout(() => {
                out.slash = !!__dgFind('.dg-slash-menu') || !!__dgFind('[class*="slash"]');
                resolve(out);
              }, 400);
            }, 300);
          }, 300);
        }, 300);
      }, 300));`)
        );
        record(
            'only one region highlighted after moving block->block->cell->cell',
            hygiene.painted <= 1,
            hygiene.painted + ' regions painted'
        );
        record('backtick opens the insert menu', !!hygiene.slash, '');

        // --- 4d. Invisible chrome must never intercept clicks --------------------
        // opacity: 0 does NOT remove an element from hit-testing. Any overlay left at
        // pointer-events: auto while invisible becomes a dead zone over the document.
        const ghosts = await page.evaluate(
            inPage(`
      const offenders = [];
      const check = (sel) => {
        for (const el of (__dgFind(sel, true) || [])) {
          const cs = getComputedStyle(el);
          const invisible = parseFloat(cs.opacity) < 0.02 || cs.visibility === 'hidden';
          if (invisible && cs.pointerEvents !== 'none') {
            const r = el.getBoundingClientRect();
            if (r.width > 2 && r.height > 2) {
              offenders.push(sel + ' @' + Math.round(r.left) + ',' + Math.round(r.top));
            }
          }
        }
      };
      check('.dg-tbl-handle');
      check('.dg-drop-marker');
      check('.dg-sel-bubble');
      return { offenders };`)
        );
        record(
            'no invisible chrome intercepts clicks',
            ghosts.offenders.length === 0,
            ghosts.offenders.slice(0, 3).join(', ')
        );

        // Clicking the page must always land on the page, never on hidden chrome.
        const canvasClickable = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const r = pv.getBoundingClientRect();
      // The toolbar is sticky and CORRECTLY covers the top of the canvas once the
      // page scrolls under it, so probe strictly below its bottom edge — otherwise
      // this asserts a bug that isn't one.
      const bar = __dgFind('.dg-format-bar');
      const barBottom = bar ? bar.getBoundingClientRect().bottom : 0;
      const top0 = Math.max(r.top, barBottom) + 24;
      const pts = [[r.left + r.width/2, top0], [r.left + 40, top0 + 80], [r.right - 40, top0 + 160]];
      const bad = [];
      for (const [x, y] of pts) {
        let top = document.elementFromPoint(Math.round(x), Math.round(y)), guard = 0;
        while (top && top.shadowRoot && guard++ < 10) {
          const inner = top.shadowRoot.elementFromPoint(Math.round(x), Math.round(y));
          if (!inner || inner === top) break;
          top = inner;
        }
        if (!(top && (top === pv || pv.contains(top)))) {
          bad.push(Math.round(x)+','+Math.round(y)+' -> ' + (top ? (top.className || top.tagName) : 'null'));
        }
      }
      return { bad };`)
        );
        record('canvas click points reach the page', canvasClickable.bad.length === 0, canvasClickable.bad.join(' | '));

        // --- 4e. Undo stack (DESIGNER_PLAN_V2 step 1) ----------------------------
        //
        // Every table and block edit is direct DOM surgery the browser's native undo
        // history never saw, so Ctrl+Z used to step straight past them. Each case
        // asserts on SERIALIZED HTML EQUALITY, not element counts: a restore that
        // gets the row count right and the content wrong is still a broken undo.
        const undoReport = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const bar = __dgFind('.dg-format-bar');
      const out = {};
      const reset = () => {
        const style = pv.querySelector('style');
        while (pv.firstChild) pv.removeChild(pv.firstChild);
        if (style) pv.appendChild(style);
        const p = document.createElement('p'); p.textContent = 'AAA'; pv.appendChild(p);
        const q = document.createElement('p'); q.textContent = 'BBB'; pv.appendChild(q);
        const t = document.createElement('table');
        t.innerHTML = '<tr><td>c1</td><td>c2</td></tr><tr><td>c3</td><td>c4</td></tr>';
        pv.appendChild(t);
        pv.focus();
        return t;
      };
      const caretIn = (el) => {
        const r = document.createRange(); r.selectNodeContents(el); r.collapse(true);
        const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
        document.dispatchEvent(new Event('selectionchange'));
      };
      const press = (extra) => {
        pv.dispatchEvent(new KeyboardEvent('keydown', Object.assign(
          { key: 'z', ctrlKey: true, bubbles: true, composed: true, cancelable: true }, extra || {})));
      };
      const tbtn = (action) => bar.querySelector('[data-taction="' + action + '"]');
      // Compare the DOCUMENT, not the byte-for-byte serialization.
      //
      // Raw innerHTML equality reports differences that are not differences.
      // Re-parsing a fragment reorders attributes (LWC re-stamps its lwc-xxxxx
      // style-scoping attribute, so 'style lwc-x' comes back as 'lwc-x style'),
      // and the caret highlight is editor chrome — data-dg-paint plus a purple
      // inline style on whichever block the cursor is in — that the undo stack
      // deliberately excludes, so the comparison must exclude it too.
      //
      // canon() walks the parsed tree and emits tag + SORTED attributes + text.
      // Still serialized-HTML equality (every element, attribute and character of
      // text has to match), just insensitive to ordering the browser owns and to
      // chrome the editor owns. Element counts alone would not catch a restore
      // that got the shape right and the content wrong; this does.
      const canon = (html) => {
        const tpl = document.createElement('template');
        tpl.innerHTML = html;
        const out = [];
        const walk = (node) => {
          for (const n of node.childNodes) {
            if (n.nodeType === 3) {
              const t = n.nodeValue.replace(/\\s+/g, ' ');
              if (t.trim()) out.push('#' + t.trim());
              continue;
            }
            if (n.nodeType !== 1) continue;
            // The four properties _paintActiveBlock writes. outline-offset carries
            // no colour, so filtering by the purple alone left it behind and made a
            // correctly-restored cell compare unequal.
            const PAINT_PROPS = /^(background-color|box-shadow|outline|outline-offset)$/;
            const painted = n.hasAttribute('data-dg-paint');
            const attrs = [];
            for (const a of n.attributes) {
              if (/^lwc-/.test(a.name) || a.name === 'data-dg-paint') continue;
              if (a.name === 'style') {
                const decls = a.value.split(';').map(s => s.trim()).filter(Boolean)
                  .filter(s => {
                    if (/124, 58, 237|#7c3aed/.test(s)) return false;
                    return !(painted && PAINT_PROPS.test(s.split(':')[0].trim()));
                  }).sort();
                if (!decls.length) continue;
                attrs.push('style=' + decls.join(';'));
              } else {
                attrs.push(a.name + '=' + a.value);
              }
            }
            attrs.sort();
            out.push('<' + n.tagName + (attrs.length ? ' ' + attrs.join(' ') : '') + '>');
            walk(n);
            out.push('</' + n.tagName + '>');
          }
        };
        walk(tpl.content);
        return out.join('');
      };
      const same = (a, b) => canon(a) === canon(b);
      const diffAt = (a, b) => {
        const x = canon(a), y = canon(b);
        let i = 0;
        while (i < x.length && i < y.length && x[i] === y[i]) i++;
        return 'at ' + i + ': ' + JSON.stringify(x.slice(i, i + 90)) + ' vs ' + JSON.stringify(y.slice(i, i + 90));
      };
      const click = (b) => {
        b.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        b.click();
      };
      const step = (ms) => new Promise((r) => setTimeout(r, ms));

      return (async () => {
        // --- table row insert -------------------------------------------------
        let t = reset();
        caretIn(t.querySelector('td'));
        await step(400);
        let before = pv.innerHTML;
        let btn = tbtn('rowAfter');
        if (!btn) { out.rowInsert = 'no rowAfter button'; }
        else {
          click(btn);
          await step(250);
          const mutated = !same(pv.innerHTML, before);
          press();
          await step(300);
          out.rowInsert = !mutated ? 'the edit itself did nothing'
                        : (same(pv.innerHTML, before) ? 'ok' : 'undo did not restore the document ' + diffAt(pv.innerHTML, before));
        }

        // --- table row delete -------------------------------------------------
        t = reset();
        caretIn(t.rows[1].cells[0]);
        await step(400);
        before = pv.innerHTML;
        btn = tbtn('rowDel');
        if (!btn) { out.rowDelete = 'no rowDel button'; }
        else {
          click(btn);
          await step(250);
          const mutated = !same(pv.innerHTML, before);
          press();
          await step(300);
          out.rowDelete = !mutated ? 'the edit itself did nothing'
                        : (same(pv.innerHTML, before) ? 'ok' : 'undo did not restore the document ' + diffAt(pv.innerHTML, before));
        }

        // --- block move -------------------------------------------------------
        reset();
        const first = pv.querySelector('p');
        const fr = first.getBoundingClientRect();
        first.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true,
          clientX: Math.round(fr.left + 10), clientY: Math.round(fr.top + 5)}));
        await step(500);
        const handle = __dgFind('.dg-blk-handle');
        const down = handle && [...handle.querySelectorAll('button')].find(x => x.dataset.dir === 'down');
        if (!down) { out.blockMove = 'no block move control'; }
        else {
          before = pv.innerHTML;
          click(down);
          await step(300);
          const mutated = !same(pv.innerHTML, before);
          press();
          await step(300);
          out.blockMove = !mutated ? 'the move itself did nothing'
                        : (same(pv.innerHTML, before) ? 'ok' : 'undo did not restore block order');
        }

        // --- redo re-applies what undo took back ------------------------------
        t = reset();
        caretIn(t.querySelector('td'));
        await step(400);
        before = pv.innerHTML;
        btn = tbtn('rowAfter');
        if (!btn) { out.redo = 'no rowAfter button'; }
        else {
          click(btn);
          await step(250);
          const afterEdit = pv.innerHTML;
          press();
          await step(300);
          const undone = same(pv.innerHTML, before);
          const redoBtn = bar.querySelector('[data-cmd="redo"]');
          const redoArmed = redoBtn ? !redoBtn.disabled : 'no redo button';
          press({ shiftKey: true });
          await step(300);
          out.redo = !undone ? 'undo did not restore first'
                   : (same(pv.innerHTML, afterEdit) ? 'ok'
                      : ('redo diff ' + diffAt(pv.innerHTML, afterEdit)));
        }

        // --- undo covers the header band too ----------------------------------
        const band = __dgFind('.dg-chrome-band_header');
        if (!band) { out.band = 'no header band'; }
        else {
          const t2 = reset();
          caretIn(t2.querySelector('td'));
          await step(300);
          const bandBefore = band.innerHTML;
          const b2 = tbtn('rowAfter');
          if (!b2) { out.band = 'no rowAfter button'; }
          else {
            // Change the header, then make a body edit, then undo: the band must
            // come back with the body, since one snapshot covers all surfaces.
            band.focus();
            band.dispatchEvent(new InputEvent('beforeinput', {bubbles:true, composed:true, inputType:'insertText', data:'X'}));
            band.textContent = 'HEADER PROBE';
            band.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
            await step(300);
            const bandEdited = band.innerHTML;
            press();
            await step(400);
            out.band = (!same(bandEdited, bandBefore) && same(band.innerHTML, bandBefore))
                     ? 'ok'
                     : ('band diff ' + diffAt(band.innerHTML, bandBefore));
          }
        }

        // --- the buttons reflect whether there is anything to undo -------------
        const undoBtn = bar.querySelector('[data-cmd="undo"]');
        out.buttonState = undoBtn ? (undoBtn.disabled === false ? 'ok' : 'undo button still disabled after edits')
                                  : 'no undo button';
        return out;
      })();`)
        );
        record(
            'undo: table row insert restores the document exactly',
            undoReport.rowInsert === 'ok',
            undoReport.rowInsert
        );
        record(
            'undo: table row delete restores the document exactly',
            undoReport.rowDelete === 'ok',
            undoReport.rowDelete
        );
        record('undo: block move restores block order', undoReport.blockMove === 'ok', undoReport.blockMove);
        record('undo: redo re-applies the undone edit', undoReport.redo === 'ok', undoReport.redo);
        record('undo: one step covers the header band too', undoReport.band === 'ok', undoReport.band);
        record(
            'undo: toolbar button enables once there is history',
            undoReport.buttonState === 'ok',
            undoReport.buttonState
        );

        // --- 4f. Regions: one source document (DESIGNER_PLAN_V2 step 2) ---------
        //
        // Header, body and footer are marked regions of the template's own HTML for
        // the AUTHOR, and three separate fields for the RENDERER. These drive the
        // real UI — type in the band, click Source, click Visual — because the
        // helpers are module-private and testing them directly would prove only
        // that two pure functions agree with each other.
        const regionReport = await page.evaluate(
            inPage(`
      const out = {};
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      const modeBtn = (label) => {
        const seg = __dgFind('.dg-mode-seg');
        return seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === label) : null;
      };
      const ta = () => __dgFind('.dg-html-body-editor');

      return (async () => {
        const pv = __dgFind('.dg-pv');
        const band = __dgFind('.dg-chrome-band_header');
        const foot = __dgFind('.dg-chrome-band_footer');
        if (!band || !modeBtn('Source') || !modeBtn('Visual')) {
          out.setup = 'missing band or mode buttons';
          return out;
        }
        out.setup = 'ok';

        // Known content in all three surfaces.
        const style = pv.querySelector('style');
        while (pv.firstChild) pv.removeChild(pv.firstChild);
        if (style) pv.appendChild(style);
        const p = document.createElement('p');
        p.textContent = 'BODYPROBE1234';
        pv.appendChild(p);
        pv.dispatchEvent(new Event('input', {bubbles:true, composed:true}));

        band.focus();
        band.textContent = 'HEADERPROBE1234';
        band.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
        if (foot) {
          foot.focus();
          foot.textContent = 'FOOTERPROBE1234';
          foot.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
        }
        await step(400);

        // --- Source view shows the WHOLE document -----------------------------
        modeBtn('Source').click();
        await step(900);
        const src = (ta() && ta().value) || '';
        out.sourceHasHeaderRegion = /data-dg-region="header"/.test(src) && src.indexOf('HEADERPROBE1234') !== -1;
        out.sourceHasBodyRegion = /data-dg-region="body"/.test(src) && src.indexOf('BODYPROBE1234') !== -1;
        out.sourceHasFooterRegion = !foot || (/data-dg-region="footer"/.test(src) && src.indexOf('FOOTERPROBE1234') !== -1);

        // --- Round-trip back to Visual ----------------------------------------
        modeBtn('Visual').click();
        await step(1600);
        const pv2 = __dgFind('.dg-pv');
        const band2 = __dgFind('.dg-chrome-band_header');
        const foot2 = __dgFind('.dg-chrome-band_footer');
        const bodyHtml = pv2 ? pv2.innerHTML : '';
        out.headerSurvived = !!band2 && band2.textContent.indexOf('HEADERPROBE1234') !== -1;
        out.bodySurvived = bodyHtml.indexOf('BODYPROBE1234') !== -1;
        out.footerSurvived = !foot2 || foot2.textContent.indexOf('FOOTERPROBE1234') !== -1;
        // The canvas is the BODY. Chrome in it would print twice.
        out.headerNotInBody = bodyHtml.indexOf('HEADERPROBE1234') === -1;
        // No marker may survive into what reaches the renderer.
        out.noMarkerInCanvas = bodyHtml.indexOf('data-dg-region') === -1;

        // --- Legacy template: no markers, header must NOT be blanked ----------
        // This is the backwards-compatibility guarantee. Asserted, not assumed.
        modeBtn('Source').click();
        await step(900);
        const t2 = ta();
        if (!t2) { out.legacy = 'no source editor'; return out; }
        t2.value = '<!DOCTYPE html><html><head><style>@page { size: Letter portrait; }</style></head>'
                 + '<body><p>LEGACYBODY9999</p></body></html>';
        t2.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
        await step(300);
        modeBtn('Visual').click();
        await step(1600);
        const pv3 = __dgFind('.dg-pv');
        const band3 = __dgFind('.dg-chrome-band_header');
        out.legacy = (pv3 && pv3.innerHTML.indexOf('LEGACYBODY9999') !== -1)
          ? (band3 && band3.textContent.indexOf('HEADERPROBE1234') !== -1
              ? 'ok'
              : 'an unmarked document blanked the header')
          : 'unmarked document did not load into the canvas';
        return out;
      })();`)
        );
        if (regionReport.setup !== 'ok') {
            record('regions: designer exposes bands + mode buttons', false, regionReport.setup);
        } else {
            record(
                'regions: Source view shows the header as a marked region',
                !!regionReport.sourceHasHeaderRegion,
                'header region + content must appear in the one source document'
            );
            record('regions: Source view shows the body as a marked region', !!regionReport.sourceHasBodyRegion, '');
            record(
                'regions: Source view shows the footer as a marked region',
                !!regionReport.sourceHasFooterRegion,
                ''
            );
            record('regions: round-trip preserves the header', !!regionReport.headerSurvived, '');
            record('regions: round-trip preserves the body', !!regionReport.bodySurvived, '');
            record('regions: round-trip preserves the footer', !!regionReport.footerSurvived, '');
            record(
                'regions: header does not leak into the body canvas',
                !!regionReport.headerNotInBody,
                'chrome in the body would print twice'
            );
            record(
                'regions: no data-dg-region marker reaches the renderer',
                !!regionReport.noMarkerInCanvas,
                'same discipline as .dg-drop-marker / data-dg-paint'
            );
            record(
                'regions: a legacy template with no markers still loads and keeps its header',
                regionReport.legacy === 'ok',
                regionReport.legacy
            );
        }

        // --- 4g. Preview from the model (DESIGNER_PLAN_V2 step 5) ---------------
        //
        // The body used to be read from the live canvas while the header and footer
        // were read from the template FIELDS — two reads at two moments of state
        // kept in step by an input listener. A header edit that had not yet fired
        // its input event was simply missing from what was previewed and saved.
        //
        // Driven by editing the band and deliberately NOT dispatching input, which
        // is the exact state that used to be lost. If the model is read from the
        // live surfaces the edit is there; if it is read from the fields it is not.
        const modelReport = await page.evaluate(
            inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      const modeBtn = (label) => {
        const seg = __dgFind('.dg-mode-seg');
        return seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === label) : null;
      };
      return (async () => {
        // Start from Visual so there are bands to read.
        if (!__dgFind('.dg-chrome-band_header') && modeBtn('Visual')) {
          modeBtn('Visual').click();
          await step(1600);
        }
        const band = __dgFind('.dg-chrome-band_header');
        if (!band || !modeBtn('Source')) return { ok:false, why:'no band or mode buttons' };
        band.focus();
        band.textContent = 'UNSYNCED9876';   // no input event on purpose
        await step(200);
        modeBtn('Source').click();
        await step(900);
        const ta = __dgFind('.dg-html-body-editor');
        const src = (ta && ta.value) || '';
        return { ok: src.indexOf('UNSYNCED9876') !== -1,
                 why: src.indexOf('UNSYNCED9876') !== -1 ? '' : 'a header edit with no input event never reached the model' };
      })();`)
        );
        record(
            'model: chrome is read from the live surfaces, not the last synced field',
            modelReport.ok,
            modelReport.why
        );

        // --- 4h. Inserts land in the surface that owns the caret ----------------
        //
        // _insertIntoVisualPage hardcoded the body canvas, so with the caret in a
        // running header the containment test failed for every candidate range —
        // the caret was in the band, the test asked about the body — and the insert
        // fell through to appending at the END OF THE BODY. Tags and images could
        // not be put into a header at all, which rules out every header that is
        // more than a line of static text.
        const insertReport = await page.evaluate(
            inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      const modeBtn = (label) => {
        const seg = __dgFind('.dg-mode-seg');
        return seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === label) : null;
      };
      const out = {};
      return (async () => {
        // The preceding probe leaves the designer in Source mode, where there are
        // no bands at all — come back to Visual before asserting on them.
        if (!__dgFind('.dg-pv') && modeBtn('Visual')) {
          modeBtn('Visual').click();
          await step(1800);
        }
        const bar = __dgFind('.dg-format-bar');
        const pv = __dgFind('.dg-pv');
        const band = __dgFind('.dg-chrome-band_header');
        if (!band || !pv) return { setup: 'no band or canvas' };
        out.setup = 'ok';

        // Clean body so an append is unmistakable.
        const style = pv.querySelector('style');
        while (pv.firstChild) pv.removeChild(pv.firstChild);
        if (style) pv.appendChild(style);
        const p = document.createElement('p'); p.textContent = 'BODY ONLY';
        pv.appendChild(p);
        band.textContent = 'HDR';

        // Caret into the header band.
        band.focus();
        const r = document.createRange();
        r.selectNodeContents(band); r.collapse(false);
        const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
        document.dispatchEvent(new Event('selectionchange'));
        await step(500);

        // The contextual header row must appear — that is the consolidation.
        out.chromeRow = !!bar.querySelector('[data-tok="pagexy"]');

        // Insert a page counter; it must land in the BAND, not the body.
        const bodyBefore = pv.innerHTML;
        const tok = bar.querySelector('[data-tok="pagexy"]');
        if (!tok) return Object.assign(out, { landed: 'no page-counter control in the toolbar' });
        tok.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        tok.click();
        await step(500);
        const inBand = band.textContent.indexOf('PageNumber') !== -1 || band.querySelector('[data-dg-tag]');
        const bodyGrew = pv.innerHTML !== bodyBefore;
        out.landed = inBand && !bodyGrew ? 'ok'
                   : ('inBand=' + !!inBand + ' bodyChanged=' + bodyGrew);

        // And with the caret back in the BODY, an insert must still go to the body.
        const p2 = pv.querySelector('p');
        const r2 = document.createRange(); r2.selectNodeContents(p2); r2.collapse(false);
        const s2 = window.getSelection(); s2.removeAllRanges(); s2.addRange(r2);
        document.dispatchEvent(new Event('selectionchange'));
        await step(500);
        out.chromeRowHidden = !bar.querySelector('[data-tok="pagexy"]');
        return out;
      })();`)
        );
        if (insertReport.setup !== 'ok') {
            record('insert: designer exposes band + canvas', false, insertReport.setup);
        } else {
            record(
                'header tools appear in the toolbar when the caret is in a band',
                !!insertReport.chromeRow,
                'page counters must be contextual, not in a separate panel'
            );
            record(
                'insert lands in the header band, not the bottom of the body',
                insertReport.landed === 'ok',
                insertReport.landed
            );
            record(
                'header tools hide again when the caret returns to the body',
                !!insertReport.chromeRowHidden,
                'page counters are meaningless in the body'
            );
        }

        // --- 4i. Three reported defects --------------------------------------
        //
        // (1) The table +/- seams vanished as you moved towards them: they sit
        //     OUTSIDE the table edge, and the overlay was dropped the instant the
        //     pointer left the table, so the target disappeared mid-approach.
        // (2) A running header showed asset merge tags as text pills instead of the
        //     image — the imagify pass walked the body canvas only.
        // (3) A tall header at zoom overlapped the page and rendered behind it:
        //     transform: scale() reserves no layout space, and the reservation was
        //     computed once at zoom-change time, not when the band later grew.
        const defects = await page.evaluate(
            inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      const modeBtn = (label) => {
        const seg = __dgFind('.dg-mode-seg');
        return seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === label) : null;
      };
      const out = {};
      return (async () => {
        if (!__dgFind('.dg-pv') && modeBtn('Visual')) { modeBtn('Visual').click(); await step(1800); }
        const pv = __dgFind('.dg-pv');
        const band = __dgFind('.dg-chrome-band_header');
        const bar = __dgFind('.dg-format-bar');
        if (!pv || !band) return { setup: 'no canvas or band' };
        out.setup = 'ok';

        // --- (1) seams survive the trip from the table to the seam ------------
        const style = pv.querySelector('style');
        while (pv.firstChild) pv.removeChild(pv.firstChild);
        if (style) pv.appendChild(style);
        const t = document.createElement('table');
        t.innerHTML = '<tr><td>c1</td><td>c2</td></tr><tr><td>c3</td><td>c4</td></tr>';
        pv.appendChild(t);
        await step(300);
        const cell = t.querySelector('td');
        const cr = cell.getBoundingClientRect();
        cell.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true,
          clientX: Math.round(cr.left + 6), clientY: Math.round(cr.top + 6)}));
        await step(600);
        const seams = __dgFind('.dg-tbl-seam', true) || [];
        if (!seams.length) { out.seamAlive = 'no seams rendered'; }
        else {
          // Move the pointer to just OUTSIDE the table, where the seams live. The
          // canvas still gets the mousemove, and the overlay must survive it.
          const tr = t.getBoundingClientRect();
          pv.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true,
            clientX: Math.round(tr.left - 6), clientY: Math.round(tr.top - 6)}));
          await step(400);
          const still = (__dgFind('.dg-tbl-seam', true) || []).length;
          out.seamAlive = still > 0 ? 'ok' : 'seams vanished when the pointer left the table';
        }

        // --- (2) an asset placed in the header renders as an image ------------
        // The real workflow: caret in the header, click an asset in the rail.
        {
          band.textContent = 'LOGO HERE ';
          band.focus();
          const rr = document.createRange();
          rr.selectNodeContents(band); rr.collapse(false);
          const ss = window.getSelection(); ss.removeAllRanges(); ss.addRange(rr);
          document.dispatchEvent(new Event('selectionchange'));
          await step(400);
          const imgBtn = __dgFind('[data-panel="images"]');
          if (!imgBtn) { out.headerImage = 'skip: no images panel'; }
          else {
            imgBtn.click();
            await step(1800);
            const thumb = __dgFind('.dg-image-thumb');
            if (!thumb) { out.headerImage = 'skip: no assets in this org'; imgBtn.click(); }
            else {
              const tag = thumb.dataset.snippet;
              thumb.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
              thumb.click();
              await step(1200);
              const b2 = __dgFind('.dg-chrome-band_header');
              out.headerImage = b2 && b2.querySelector('img') ? 'ok'
                : ('asset stayed a text pill in the header (' + tag + '); band=' + (b2 ? b2.innerHTML.slice(0,120) : 'gone'));
              const close = __dgFind('[data-panel="images"]');
              if (close) close.click();
              await step(400);
            }
          }
        }

        // --- (3) a tall header at zoom must not overlap the page --------------
        // Find by the OPTION LIST, not the current selection — an earlier probe
        // leaves this on "Fit width", which has no % in its label.
        const sel = [...bar.querySelectorAll('select')].find(s => [...s.options].some(o => /%/.test(o.text)));
        if (!sel) { out.zoomOverlap = 'no zoom control'; }
        else {
          sel.value = '1.5';
          sel.dispatchEvent(new Event('change', {bubbles:true, composed:true}));
          await step(500);
          band.innerHTML = '';
          for (let i = 0; i < 8; i++) {
            const p = document.createElement('p');
            p.textContent = 'Header line ' + (i+1) + ' — a tall multi-line running header.';
            band.appendChild(p);
          }
          band.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
          await step(1200);
          const b = band.getBoundingClientRect();
          const p2 = __dgFind('.dg-pv').getBoundingClientRect();
          const gap = Math.round(p2.top - b.bottom);
          out.zoomOverlap = gap >= -1 ? 'ok' : ('header overlaps the page by ' + (-gap) + 'px at 150%');
          sel.value = '1';
          sel.dispatchEvent(new Event('change', {bubbles:true, composed:true}));
          await step(300);
        }
        return out;
      })();`)
        );
        if (defects.setup !== 'ok') {
            record('defects: designer exposes canvas + band', false, defects.setup);
        } else {
            record('table seams survive the pointer leaving the table', defects.seamAlive === 'ok', defects.seamAlive);
            if (String(defects.headerImage).startsWith('skip')) {
                console.log(`  SKIP  header renders asset tags as images — ${defects.headerImage}`);
            } else {
                record(
                    'header renders asset tags as images, not text pills',
                    defects.headerImage === 'ok',
                    defects.headerImage
                );
            }
            record(
                'a tall header at zoom does not overlap the page',
                defects.zoomOverlap === 'ok',
                defects.zoomOverlap
            );
        }

        // --- 4j. Resizing an image in the header must not duplicate it ----------
        //
        // The image resize/move handlers were wired to the body canvas only, so a
        // corner drag in a band fell through to the browser's NATIVE image drag
        // inside a contenteditable — which COPIES the image. Every attempted resize
        // left another logo behind.
        const resizeReport = await page.evaluate(
            inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      const modeBtn = (label) => {
        const seg = __dgFind('.dg-mode-seg');
        return seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === label) : null;
      };
      return (async () => {
        if (!__dgFind('.dg-pv') && modeBtn('Visual')) { modeBtn('Visual').click(); await step(1800); }
        const band = __dgFind('.dg-chrome-band_header');
        if (!band) return { ok:false, why:'no header band' };

        // Put one asset image in the header via the rail (the real route).
        band.textContent = '';
        band.focus();
        const r0 = document.createRange(); r0.selectNodeContents(band); r0.collapse(false);
        const s0 = window.getSelection(); s0.removeAllRanges(); s0.addRange(r0);
        document.dispatchEvent(new Event('selectionchange'));
        await step(300);
        const imgBtn = __dgFind('[data-panel="images"]');
        if (!imgBtn) return { ok:false, why:'no images panel' };
        imgBtn.click(); await step(1600);
        const thumb = __dgFind('.dg-image-thumb');
        if (!thumb) { imgBtn.click(); return { ok:true, why:'skip: no assets' , skipped:true }; }
        thumb.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        thumb.click();
        await step(1000);
        const close = __dgFind('[data-panel="images"]'); if (close) close.click();
        await step(400);

        const b2 = __dgFind('.dg-chrome-band_header');
        const before = b2.querySelectorAll('img').length;
        if (before !== 1) return { ok:false, why:'expected exactly 1 image after insert, got ' + before };

        // Drag the bottom-right corner, the way a resize happens.
        const img = b2.querySelector('img');
        const rect = img.getBoundingClientRect();
        const cx = Math.round(rect.right - 3), cy = Math.round(rect.bottom - 3);
        img.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:cx, clientY:cy}));
        img.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true, clientX:cx, clientY:cy}));
        for (let i = 1; i <= 5; i++) {
          document.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true, clientX:cx + i*10, clientY:cy}));
        }
        document.dispatchEvent(new MouseEvent('mouseup', {bubbles:true, composed:true}));
        await step(600);

        const b3 = __dgFind('.dg-chrome-band_header');
        const after = b3.querySelectorAll('img').length;
        const w = Math.round(b3.querySelector('img').getBoundingClientRect().width);
        return { ok: after === 1, why: after === 1 ? ('resized to ' + w + 'px, still 1 image')
                                                  : ('resize duplicated the image: ' + before + ' -> ' + after) };
      })();`)
        );
        if (resizeReport.skipped) {
            console.log(`  SKIP  resizing a header image does not duplicate it — ${resizeReport.why}`);
        } else {
            record('resizing a header image does not duplicate it', !!resizeReport.ok, resizeReport.why);
        }

        // --- 4k. Enter = line break, Shift+Enter = paragraph --------------------
        //
        // contenteditable's Enter creates a <p>, which carries the template's
        // paragraph margin — so address blocks, signature blocks and multi-line
        // headers all came out double-spaced. In a document template the tight line
        // is the common case, so the two keys are deliberately swapped.
        //
        // Driven with REAL key presses, not synthetic KeyboardEvents: a synthetic
        // event never triggers the browser's own editing action, so the Shift+Enter
        // half — whose whole contract is "we leave it to the browser" — cannot be
        // observed any other way.
        const seedPara = inPage(`
      const pv = __dgFind('.dg-pv');
      if (!pv) return false;
      const style = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (style) pv.appendChild(style);
      const p = document.createElement('p');
      p.textContent = 'line one';
      pv.appendChild(p);
      pv.focus();
      const r = document.createRange();
      r.selectNodeContents(p); r.collapse(false);
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      document.dispatchEvent(new Event('selectionchange'));
      return true;`);
        const readPara = inPage(`
      const pv = __dgFind('.dg-pv');
      return { blocks: pv.querySelectorAll('p, div').length, brInP: !!pv.querySelector('p br') };`);

        let enterOk = { seeded: false };
        try {
            enterOk.seeded = await page.evaluate(seedPara);
            if (enterOk.seeded) {
                await page.waitForTimeout(400);
                await page.keyboard.press('Enter');
                await page.waitForTimeout(500);
                const afterEnter = await page.evaluate(readPara);
                enterOk.br = afterEnter.brInP && afterEnter.blocks === 1;
                enterOk.brDetail = JSON.stringify(afterEnter);

                await page.evaluate(seedPara);
                await page.waitForTimeout(400);
                await page.keyboard.press('Shift+Enter');
                await page.waitForTimeout(500);
                const afterShift = await page.evaluate(readPara);
                enterOk.para = afterShift.blocks > 1;
                enterOk.paraDetail = JSON.stringify(afterShift);
            }
        } catch (e) {
            enterOk.err = e.message;
        }
        if (!enterOk.seeded) {
            record('Enter/Shift+Enter behaviour', false, enterOk.err || 'could not seed the canvas');
        } else {
            record('Enter inserts a line break, staying in the paragraph', !!enterOk.br, enterOk.brDetail);
            record('Shift+Enter starts a new paragraph', !!enterOk.para, enterOk.paraDetail);
        }

        // A list must keep "Enter = next item" — the browser owns that.
        const listEnter = await page.evaluate(
            inPage(`
      const pv = __dgFind('.dg-pv');
      const style = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (style) pv.appendChild(style);
      const ul = document.createElement('ul');
      ul.innerHTML = '<li>first</li>';
      pv.appendChild(ul);
      pv.focus();
      const li = ul.querySelector('li');
      const r = document.createRange(); r.selectNodeContents(li); r.collapse(false);
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      document.dispatchEvent(new Event('selectionchange'));
      return true;`)
        );
        if (listEnter) {
            await page.waitForTimeout(400);
            await page.keyboard.press('Enter');
            await page.waitForTimeout(500);
            const listAfter = await page.evaluate(
                inPage(`
      const ul = __dgFind('.dg-pv').querySelector('ul');
      return { items: ul ? ul.querySelectorAll('li').length : 0, brs: ul ? ul.querySelectorAll('br').length : -1 };`)
            );
            record(
                'Enter in a list makes the next item, not a line break',
                listAfter.items > 1,
                JSON.stringify(listAfter)
            );
        }

        // --- 4l. The insert menu opens in the running header too ----------------
        //
        // _maybeOpenSlashMenu was always surface-aware, but only the body canvas
        // ever called it — so the ` / [ menu could not be opened in a band at all.
        const bandSlash = await page.evaluate(
            inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      const modeBtn = (label) => {
        const seg = __dgFind('.dg-mode-seg');
        return seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === label) : null;
      };
      return (async () => {
        if (!__dgFind('.dg-chrome-band_header') && modeBtn('Visual')) { modeBtn('Visual').click(); await step(1800); }
        const band = __dgFind('.dg-chrome-band_header');
        if (!band) return { ok:false, why:'no header band' };
        band.textContent = '';
        band.focus();
        const tn = document.createTextNode('\\u0060');
        band.appendChild(tn);
        const r = document.createRange();
        r.setStart(tn, 1); r.collapse(true);
        const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
        band.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
        await step(600);
        const menu = __dgFind('.dg-slash-menu') || __dgFind('[class*="slash"]');
        return { ok: !!menu, why: menu ? '' : 'backtick in the header opened nothing' };
      })();`)
        );
        record('backtick opens the insert menu in the running header', !!bandSlash.ok, bandSlash.why);

        // --- 4m. The header behaves exactly like the body -----------------------
        //
        // Interactions were written against the body canvas, and the bands got
        // whichever ones somebody remembered. _wireSurfaceInteractions now applies
        // one list to every surface; these assert the ones that were missing.
        const parity = await page.evaluate(
            inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      const modeBtn = (label) => {
        const seg = __dgFind('.dg-mode-seg');
        return seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === label) : null;
      };
      return (async () => {
        if (!__dgFind('.dg-chrome-band_header') && modeBtn('Visual')) { modeBtn('Visual').click(); await step(1800); }
        const band = __dgFind('.dg-chrome-band_header');
        const bar = __dgFind('.dg-format-bar');
        if (!band) return { setup:'no header band' };
        const out = { setup:'ok' };

        // A table in the header, the same as one in the body.
        band.innerHTML = '<table><tr><td>h1</td><td>h2</td></tr></table>';
        band.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
        await step(400);
        const cell = band.querySelector('td');

        // Right-click must open the contextual menu.
        const cr = cell.getBoundingClientRect();
        cell.dispatchEvent(new MouseEvent('contextmenu', {bubbles:true, composed:true, cancelable:true,
          clientX: Math.round(cr.left + 8), clientY: Math.round(cr.top + 8)}));
        await step(500);
        out.ctx = !!__dgFind('.dg-ctx-menu') || !!__dgFind('[class*="dg-ctx"]');
        // Close it again.
        band.dispatchEvent(new MouseEvent('click', {bubbles:true, composed:true}));
        await step(300);

        // Caret in the header cell -> table tools appear and operate on THAT table.
        const r = document.createRange(); r.selectNodeContents(cell); r.collapse(true);
        const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
        document.dispatchEvent(new Event('selectionchange'));
        await step(500);
        const addRow = bar.querySelector('[data-taction="rowAfter"]');
        out.tools = !!addRow;
        if (addRow) {
          const before = band.querySelectorAll('tr').length;
          addRow.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
          addRow.click();
          await step(400);
          const after = __dgFind('.dg-chrome-band_header').querySelectorAll('tr').length;
          out.rowAdded = after === before + 1;
          out.rowDetail = before + ' -> ' + after;
        }

        // Table handles must track the pointer over a header table too.
        const c2 = __dgFind('.dg-chrome-band_header').querySelector('td');
        const c2r = c2.getBoundingClientRect();
        c2.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true,
          clientX: Math.round(c2r.left + 6), clientY: Math.round(c2r.top + 6)}));
        await step(600);
        out.handles = ((__dgFind('.dg-tbl-seam', true) || []).length > 0) ||
                      ((__dgFind('.dg-tbl-handle', true) || []).length > 0);
        return out;
      })();`)
        );
        if (parity.setup !== 'ok') {
            record('header/body parity harness', false, parity.setup);
        } else {
            record('right-click opens the context menu in the header', !!parity.ctx, '');
            record('table tools appear for a table in the header', !!parity.tools, '');
            record('table tools operate on the header table', !!parity.rowAdded, parity.rowDetail || '');
            record('table handles track the pointer over a header table', !!parity.handles, '');
        }

        // --- 4n. Tab walks table cells and grows the table ----------------------
        //
        // Without this Tab moved FOCUS out of the editor: the caret was lost and the
        // author had to click back in for every cell. Real key presses, because a
        // synthetic Tab neither moves focus nor proves we suppressed it.
        const tabSeed = inPage(`
      const pv = __dgFind('.dg-pv');
      if (!pv) return false;
      const style = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (style) pv.appendChild(style);
      const t = document.createElement('table');
      t.innerHTML = '<tr><td>a1</td><td>a2</td></tr><tr><td>b1</td><td>b2</td></tr>';
      pv.appendChild(t);
      pv.focus();
      const first = t.querySelector('td');
      const r = document.createRange(); r.selectNodeContents(first); r.collapse(true);
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      document.dispatchEvent(new Event('selectionchange'));
      return true;`);
        const cellAt = inPage(`
      const pv = __dgFind('.dg-pv');
      const t = pv.querySelector('table');
      let txt = '';
      try {
        const s = window.getSelection();
        const n = s && s.rangeCount ? s.getRangeAt(0).startContainer : null;
        const el = n && n.nodeType === 3 ? n.parentElement : n;
        const td = el && el.closest ? el.closest('td, th') : null;
        txt = td ? (td.textContent || '').trim() : '';
      } catch (e) { txt = 'ERR'; }
      return { cell: txt, rows: t ? t.rows.length : 0 };`);

        const tabSeeded = await page.evaluate(tabSeed);
        if (!tabSeeded) {
            record('Tab moves between table cells', false, 'could not seed a table');
        } else {
            await page.waitForTimeout(500);
            await page.keyboard.press('Tab');
            await page.waitForTimeout(400);
            const afterTab = await page.evaluate(cellAt);
            record('Tab moves to the next cell', afterTab.cell === 'a2', 'landed in ' + JSON.stringify(afterTab));

            await page.keyboard.press('Shift+Tab');
            await page.waitForTimeout(400);
            const afterShift = await page.evaluate(cellAt);
            record('Shift+Tab moves back a cell', afterShift.cell === 'a1', 'landed in ' + JSON.stringify(afterShift));

            // Walk to the last cell, then one more Tab must grow the table.
            await page.keyboard.press('Tab');
            await page.keyboard.press('Tab');
            await page.keyboard.press('Tab');
            await page.waitForTimeout(400);
            const atLast = await page.evaluate(cellAt);
            await page.keyboard.press('Tab');
            await page.waitForTimeout(600);
            const grown = await page.evaluate(cellAt);
            record(
                'Tab in the last cell adds a row and lands in it',
                grown.rows === atLast.rows + 1,
                'rows ' + atLast.rows + ' -> ' + grown.rows + ' (from cell ' + atLast.cell + ')'
            );
        }

        // --- 4o. Menus reach the front, and handles work in every band ----------
        //
        // .dg-format-bar carried a backdrop-filter, which makes an element a
        // CONTAINING BLOCK for position: fixed descendants and a stacking context.
        // Every popover in that bar is position: fixed, so they were re-anchored to
        // the toolbar and their z-index capped at the bar's — the insert-table grid
        // fell behind the page and its bottom rows could not be clicked, making a
        // 1-column table impossible to pick.
        const frontReport = await page.evaluate(
            inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      return (async () => {
        const bar = __dgFind('.dg-format-bar');
        const out = {};
        // No ancestor of a toolbar popover may create a fixed-positioning
        // containing block. This is the rule, not just this one symptom.
        const cs = getComputedStyle(bar);
        out.barClean = cs.backdropFilter === 'none' && cs.filter === 'none' && cs.transform === 'none';
        out.barDetail = 'backdrop=' + cs.backdropFilter + ' filter=' + cs.filter + ' transform=' + cs.transform;

        const btn = [...bar.querySelectorAll('button')].find(b => /Table/.test(b.textContent||''));
        if (!btn) return Object.assign(out, { grid: 'no table button' });
        btn.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        btn.click();
        await step(700);
        const cells = __dgFind('.dg-grid-cell', true) || [];
        if (!cells.length) return Object.assign(out, { grid: 'grid did not open' });
        // EVERY cell must be clickable — the bottom-left one is what a 1-column
        // table needs, and it was the first to be lost.
        let blocked = null;
        for (const c of cells) {
          const r = c.getBoundingClientRect();
          const x = Math.round(r.left + r.width/2), y = Math.round(r.top + r.height/2);
          let top = document.elementFromPoint(x, y), guard = 0;
          while (top && top.shadowRoot && guard++ < 10) {
            const inner = top.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === top) break;
            top = inner;
          }
          if (top !== c) { blocked = 'cell ' + c.dataset.r + 'x' + c.dataset.c + ' covered by ' + (top ? (top.className || top.tagName) : 'null'); break; }
        }
        out.grid = blocked || 'ok';
        // Close it again.
        btn.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        btn.click();
        await step(300);
        return out;
      })();`)
        );
        record(
            'toolbar creates no fixed-positioning containing block',
            !!frontReport.barClean,
            frontReport.barDetail || ''
        );
        record('every insert-table grid cell is clickable', frontReport.grid === 'ok', frontReport.grid || '');

        // Table handles must stay reachable while the pointer is over a BAND.
        // Driven with a REAL pointer: the visibility gate is a CSS :hover rule, and
        // :hover does not respond to synthetic mouse events, so a dispatched
        // mousemove reports every handle as invisible whether or not it is.
        const bandSeeded = await page.evaluate(
            inPage(`
      const band = __dgFind('.dg-chrome-band_header');
      if (!band) return null;
      band.innerHTML = '<table><tr><td>h1</td><td>h2</td></tr></table>';
      band.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
      // Earlier probes scroll the page; the band can be off-screen by now, and a
      // real pointer move to a stale coordinate lands on nothing.
      band.scrollIntoView({ block: 'center' });
      return true;`)
        );
        if (!bandSeeded) {
            record('table handles are visible and clickable over a header table', false, 'no header band');
        } else {
            await page.waitForTimeout(600);
            const pt = await page.evaluate(
                inPage(`
      const band = __dgFind('.dg-chrome-band_header');
      const cell = band && band.querySelector('td');
      if (!cell) return null;
      const c = cell.getBoundingClientRect();
      return { x: Math.round(c.left + c.width / 2), y: Math.round(c.top + c.height / 2) };`)
            );
            if (pt) {
                await page.mouse.move(pt.x, pt.y);
                await page.mouse.move(pt.x + 2, pt.y + 1);
            }
            await page.waitForTimeout(700);
            const bandHandles = await page.evaluate(
                inPage(`
      const seams = __dgFind('.dg-tbl-seam', true) || [];
      const handles = __dgFind('.dg-tbl-handle', true) || [];
      const all = seams.concat(handles);
      if (!all.length) return { ok:false, why:'no handles rendered for a header table' };
      const live = all.filter(el => {
        const cs = getComputedStyle(el);
        return parseFloat(cs.opacity) > 0.02 && cs.pointerEvents !== 'none';
      });
      const paper = __dgFind('.dg-sheet-paper');
      const band = __dgFind('.dg-chrome-band_header');
      const br = band ? band.getBoundingClientRect() : null;
      const at = br ? document.elementFromPoint(Math.round(br.left + br.width/2), Math.round(br.top + br.height/2)) : null;
      const one = all[0];
      const ocs = one ? getComputedStyle(one) : null;
      return { ok: live.length > 0,
               why: live.length ? (live.length + '/' + all.length + ' interactive')
                                : (all.length + ' rendered but all invisible/unclickable'
                                   + ' | paperHover=' + (paper ? paper.matches(':hover') : 'no paper')
                                   + ' | bandHover=' + (band ? band.matches(':hover') : 'no band')
                                   + ' | elementAtBand=' + (at ? (at.className || at.tagName) : 'null')
                                   + ' | seam0 opacity=' + (ocs ? ocs.opacity : '?') + ' pe=' + (ocs ? ocs.pointerEvents : '?')) };`)
            );
            record('table handles are visible and clickable over a header table', !!bandHandles.ok, bandHandles.why);
        }

        // --- 4p. An author's cell fill STAYS ------------------------------------
        //
        // Chrome is drawn with inline styles on the same nodes the author edits, so
        // it can only coexist under two rules: never write a property the author can
        // write, and never snapshot/restore a whole style attribute. Both were
        // broken. The caret highlight tinted background-color and restored the style
        // attribute it captured on arrival — so a fill applied while the caret was in
        // the cell (click cell, click swatch: the normal order) lived exactly as long
        // as the caret stayed there.
        //
        // Driven through the REAL toolbar control, not by setting style directly.
        const fillReport = await page.evaluate(
            inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      const modeBtn = (label) => {
        const seg = __dgFind('.dg-mode-seg');
        return seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === label) : null;
      };
      const norm = (c) => (c || '').split(' ').join('');
      return (async () => {
        if (!__dgFind('.dg-pv') && modeBtn('Visual')) { modeBtn('Visual').click(); await step(1800); }
        const pv = __dgFind('.dg-pv');
        const bar = __dgFind('.dg-format-bar');
        if (!pv) return { setup:'no canvas' };
        const out = { setup:'ok' };

        const style = pv.querySelector('style');
        while (pv.firstChild) pv.removeChild(pv.firstChild);
        if (style) pv.appendChild(style);
        const t = document.createElement('table');
        t.innerHTML = '<tr><td>c1</td><td>c2</td></tr><tr><td>c3</td><td>c4</td></tr>';
        pv.appendChild(t);
        const cell = t.querySelector('td');

        // Caret INTO the cell first — the order that used to lose the fill.
        pv.focus();
        const r = document.createRange(); r.selectNodeContents(cell); r.collapse(false);
        const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
        document.dispatchEvent(new Event('selectionchange'));
        await step(500);

        // Apply the fill through the real control.
        const swatch = [...bar.querySelectorAll('[data-taction="cellFill"][data-value]')]
          .find(b => /^#/.test(b.dataset.value || ''));
        if (!swatch) return Object.assign(out, { applied: 'no cellFill swatch in the toolbar' });
        // Canonicalise through the browser: the swatch value is hex, but the DOM
        // reports rgb(). Comparing the two forms directly is how the first version of
        // this assertion reported a failure while the product was working.
        const probe = document.createElement('div');
        probe.style.background = swatch.dataset.value;
        const wantRaw = probe.style.backgroundColor;
        const want = norm(wantRaw);
        swatch.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        swatch.click();
        await step(500);
        const live = () => __dgFind('.dg-pv').querySelector('td');
        out.applied = norm(live().style.background || live().style.backgroundColor).indexOf(want) !== -1
          ? 'ok' : ('swatch ' + want + ' produced ' + live().style.cssText);

        // Now everything that used to erase it: hover the row, type, move the caret.
        const cr = live().getBoundingClientRect();
        live().dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true,
          clientX: Math.round(cr.left + 6), clientY: Math.round(cr.top + 6)}));
        await step(400);
        pv.dispatchEvent(new InputEvent('beforeinput', {bubbles:true, composed:true, inputType:'insertText', data:'x'}));
        pv.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
        await step(400);
        const other = __dgFind('.dg-pv').querySelectorAll('td')[3];
        const r2 = document.createRange(); r2.selectNodeContents(other); r2.collapse(false);
        const s2 = window.getSelection(); s2.removeAllRanges(); s2.addRange(r2);
        document.dispatchEvent(new Event('selectionchange'));
        pv.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, composed:true,
          clientX: Math.round(cr.left + 6), clientY: Math.round(cr.bottom + 400)}));
        await step(800);
        const after = norm(live().style.background || live().style.backgroundColor);
        out.stayed = after.indexOf(want) !== -1 ? 'ok' : ('fill became ' + JSON.stringify(after));

        // And it must survive the trip to SAVED html, with no chrome alongside it.
        const seg = __dgFind('.dg-mode-seg');
        const src = seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === 'Source') : null;
        if (!src) return Object.assign(out, { saved: 'no source toggle' });
        src.click();
        await step(1200);
        const ta = __dgFind('.dg-html-body-editor');
        const html = (ta && ta.value) || '';
        out.saved = (norm(html).indexOf(want) !== -1 || html.indexOf(swatch.dataset.value) !== -1)
          ? 'ok' : ('fill ' + wantRaw + ' missing from the serialized body');
        out.noChrome = !/data-dg-paint|data-dg-selcell/.test(html)
          ? 'ok' : 'editor chrome leaked into the serialized body';
        const vis = seg ? [...seg.querySelectorAll('button')].find(b => (b.textContent||'').trim() === 'Visual') : null;
        if (vis) { vis.click(); await step(1600); }
        return out;
      })();`)
        );
        if (fillReport.setup !== 'ok') {
            record('cell fill harness', false, fillReport.setup);
        } else {
            record('the fill swatch applies a fill', fillReport.applied === 'ok', fillReport.applied);
            // MULTI-CELL fill: drag-select a rectangle, then fill it. Covered separately
            // because the single-cell path passed while this was completely broken —
            // _pushUndo snapshotted, the snapshot cleared the selection, and the fill
            // landed on one cell.
            const multiFill = await page.evaluate(
                inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      const norm = (c) => (c || '').split(' ').join('');
      return (async () => {
        const pv = __dgFind('.dg-pv');
        const bar = __dgFind('.dg-format-bar');
        if (!pv) return { setup:'no canvas' };
        const style = pv.querySelector('style');
        while (pv.firstChild) pv.removeChild(pv.firstChild);
        if (style) pv.appendChild(style);
        const t = document.createElement('table');
        t.innerHTML = '<tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr>';
        pv.appendChild(t);
        await step(300);
        const cells = [...t.querySelectorAll('td')];
        const at = (el) => { const r = el.getBoundingClientRect();
          return { clientX: Math.round(r.left + r.width/2), clientY: Math.round(r.top + r.height/2) }; };

        // Drag-select all four cells.
        pv.focus();
        cells[0].dispatchEvent(new MouseEvent('mousedown', Object.assign({bubbles:true, composed:true, cancelable:true}, at(cells[0]))));
        // buttons: 1 — _cellSelMove requires a held button, and a synthetic
        // MouseEvent reports buttons: 0 unless it is asked for.
        cells[1].dispatchEvent(new MouseEvent('mousemove', Object.assign({bubbles:true, composed:true, buttons:1}, at(cells[1]))));
        cells[3].dispatchEvent(new MouseEvent('mousemove', Object.assign({bubbles:true, composed:true, buttons:1}, at(cells[3]))));
        document.dispatchEvent(new MouseEvent('mouseup', {bubbles:true, composed:true}));
        await step(500);
        const selected = t.querySelectorAll('[data-dg-selcell]').length;
        if (selected < 4) return { setup:'ok', selected, filled: 'only ' + selected + ' cells got selected' };

        const swatch = [...bar.querySelectorAll('[data-taction="cellFill"][data-value]')]
          .find(b => /^#/.test(b.dataset.value || ''));
        if (!swatch) return { setup:'ok', selected, filled: 'no coloured swatch' };
        const probe = document.createElement('div');
        probe.style.background = swatch.dataset.value;
        const want = norm(probe.style.backgroundColor);
        swatch.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, composed:true, cancelable:true}));
        swatch.click();
        await step(600);
        const live = [...__dgFind('.dg-pv').querySelectorAll('td')];
        const got = live.filter(c => norm(c.style.background || c.style.backgroundColor).indexOf(want) !== -1).length;
        return { setup:'ok', selected, filled: got === 4 ? 'ok' : (got + '/4 cells took the fill') };
      })();`)
            );
            record(
                'fill applies to every cell in a multi-cell selection',
                multiFill.filled === 'ok',
                multiFill.filled || multiFill.setup
            );

            record(
                'the fill STAYS through hover, typing and caret moves',
                fillReport.stayed === 'ok',
                fillReport.stayed
            );
            record('the fill survives into the serialized body', fillReport.saved === 'ok', fillReport.saved);
            record(
                'no editor chrome leaks into the serialized body',
                fillReport.noChrome === 'ok',
                fillReport.noChrome
            );
        }

        // --- 4q. The Designer tab can open a template on its own ----------------
        //
        // Landing on the Designer with nothing open used to be a dead end: it named
        // two other tabs and left you to go there. Run LAST, because it closes the
        // template every other assertion depends on.
        // Reload the app so the Designer tab starts with nothing open — the state a
        // person actually arrives in.
        await page.goto(`${base}${tabPath(ORG)}?empty=${Date.now()}`, {
            waitUntil: 'domcontentloaded'
        });
        await page.waitForTimeout(7000);
        await page.locator('[role="tab"]:has-text("Designer")').first().click();
        await page.waitForTimeout(3000);
        const emptyState = await page.evaluate(
            inPage(`
      const list = __dgFind('.dg-designer-open-list');
      const items = __dgFind('.dg-designer-open-item', true) || [];
      return { list: !!list, count: items.length, first: items[0] ? (items[0].textContent || '').trim() : '' };`)
        );
        record(
            'Designer tab offers templates to open when none is loaded',
            emptyState.list && emptyState.count > 0,
            JSON.stringify(emptyState)
        );

        // SCALE: the rendered list must stay bounded no matter how many templates
        // the org has, and search must be able to reach one that is not shown.
        const scale = await page.evaluate(
            inPage(`
      const step = (ms) => new Promise((r) => setTimeout(r, ms));
      return (async () => {
        const items = () => (__dgFind('.dg-designer-open-item', true) || []).length;
        const foot = () => { const el = __dgFind('.dg-designer-open-count'); return el ? el.textContent.trim() : ''; };
        const out = { rendered: items(), summary: foot() };
        // Whatever the org holds, the DOM must not be one node per template.
        out.bounded = out.rendered <= 8;
        const input = __dgFind('.dg-designer-open-search__input');
        if (!input) return Object.assign(out, { search: 'no search box' });
        // A query that cannot match anything must empty the list, not the page.
        input.value = 'zzz-no-such-template-zzz';
        input.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
        await step(500);
        out.search = items() === 0 ? 'ok' : (items() + ' items survived a no-match query');
        out.emptySummary = foot();
        // And clearing it brings the list back.
        input.value = '';
        input.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
        await step(500);
        out.restored = items() > 0;
        return out;
      })();`)
        );
        record(
            'template list stays bounded regardless of org size',
            !!scale.bounded,
            scale.rendered + ' rendered · ' + scale.summary
        );
        record('template search filters the list', scale.search === 'ok', scale.search);
        record('clearing the search restores the list', !!scale.restored, '');
        if (emptyState.count > 0) {
            // SEARCH for it first. The picker renders at most 8 templates, ordered by
            // most-recently-modified, so in an org with a handful of newer templates the
            // one this suite is built around silently drops off the list — and every
            // assertion after it then tests whatever happened to be first instead. That
            // is how a whole run reports "no chip available" as if it were a regression.
            await page.evaluate(
                inPage(
                    `
      const input = __dgFind('.dg-designer-open-search__input');
      if (input) {
        input.value = ` +
                        JSON.stringify(TEMPLATE_HINT) +
                        `;
        input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
      }
      return true;`
                )
            );
            await page.waitForTimeout(1500);
            await page.evaluate(
                inPage(
                    `
      // Pick by NAME, not items[0]. The Designer list now also offers Canvas
      // templates, which open the canvas editor instead of the flow designer — so
      // whichever template happened to be most-recently-modified silently decided
      // what this whole suite was testing.
      const items = __dgFind('.dg-designer-open-item', true) || [];
      const hint = ` +
                        JSON.stringify(TEMPLATE_HINT) +
                        `;
      const match = items.find((i) => (i.textContent || '').indexOf(hint) !== -1) || items[0];
      if (!match) return false;
      match.click();
      return true;`
                )
            );
            await page.waitForTimeout(8000);
            const opened = await page.evaluate(
                inPage(`return { pv: !!__dgFind('.dg-pv'), bar: !!__dgFind('.dg-format-bar') };`)
            );
            record(
                'clicking a template on the Designer tab opens it for editing',
                opened.pv && opened.bar,
                JSON.stringify(opened)
            );
        }

        // --- 4b. Dragging a tag chip onto the page ------------------------------
        // The one interaction with no coverage until now, and the one most likely to
        // rot silently: HTML5 drag-and-drop does not survive LWS, so chip drag is
        // hand-rolled from raw mouse events (mousedown arms, >7px starts, a ghost
        // follows the cursor, mouseup over the page inserts at the drop caret). None of
        // that is exercised by clicking, so every other check here can pass while
        // dragging is completely dead — which is exactly what a user reported.
        {
            const seedCanvas = inPage(`
      const pv = __dgFind('.dg-pv');
      if (!pv) return false;
      const keep = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (keep) pv.appendChild(keep);
      const p = document.createElement('p');
      p.textContent = 'DROP TARGET LINE';
      pv.appendChild(p);
      return true;`);

            // The chips live in the Tags rail panel, which is closed by default —
            // open it first or every drag assertion below reports a missing chip
            // rather than a broken drag.
            const openTagPanel = inPage(`
      // Idempotent on purpose: handlePanelToggle TOGGLES, so a second blind click
      // closes the rail and the next assertion reports "no chip" instead of testing
      // anything. Only click when the chips are not already on screen.
      if (__dgFind('.dg-tag-chip[data-snippet]')) return 'already-open';
      const btn = __dgFind('[data-panel="tags"]');
      if (!btn) return false;
      btn.click();
      return true;`);

            const geometry = inPage(`
      const chip = __dgFind('.dg-tag-chip[data-snippet]');
      const pv = __dgFind('.dg-pv');
      if (!chip || !pv) return null;
      const c = chip.getBoundingClientRect();
      const p = pv.getBoundingClientRect();
      return {
        snippet: chip.getAttribute('data-snippet'),
        chipX: c.left + c.width / 2, chipY: c.top + c.height / 2,
        pvX: p.left + Math.min(120, p.width / 2), pvY: p.top + 30
      };`);

            const readCanvas = (snippet) =>
                inPage(
                    `
      const pv = __dgFind('.dg-pv');
      const html = pv ? pv.innerHTML : '';
      const needle = ` +
                        JSON.stringify(snippet) +
                        `;
      return {
        landed: html.indexOf(needle) !== -1,
        ghostLeft: !!__dgFind('.dg-drag-ghost'),
        markerLeft: !!__dgFind('.dg-drop-marker'),
        zoneLeft: !!__dgFind('.dg-drop-zone')
      };`
                );

            let drag = {};
            try {
                drag.seeded = await page.evaluate(seedCanvas);
                drag.panel = await ensureTagRail(page, inPage);
                const geo = await page.evaluate(geometry);
                if (!geo) {
                    record(
                        'chip drag: a draggable tag chip is present',
                        false,
                        'no .dg-tag-chip[data-snippet] in the rail'
                    );
                } else {
                    record('chip drag: a draggable tag chip is present', true, geo.snippet);
                    // A real mouse gesture, not a synthetic event: the 7px threshold and
                    // the document-level capture listeners only respond to genuine moves.
                    await page.mouse.move(geo.chipX, geo.chipY);
                    await page.mouse.down();
                    await page.mouse.move(geo.chipX + 20, geo.chipY + 10, { steps: 5 });
                    await page.mouse.move(geo.pvX, geo.pvY, { steps: 12 });
                    await page.waitForTimeout(250);
                    const midFlight = await page.evaluate(
                        inPage(`
      const zone = __dgFind('.dg-drop-zone');
      const shown = zone && zone.style.display !== 'none';
      const r = shown ? zone.getBoundingClientRect() : null;
      return {
        ghost: !!__dgFind('.dg-drag-ghost'),
        caret: !!__dgFind('.dg-drop-marker:not(.dg-drop-zone)'),
        zoneShown: !!shown,
        zoneHasArea: !!(r && r.width > 4 && r.height > 4),
        // The box must answer to .dg-drop-marker too — that is the single class the
        // four serialization strippers key on.
        zoneStripsAsChrome: !!(zone && zone.classList.contains('dg-drop-marker'))
      };`)
                    );
                    record('chip drag: a ghost follows the cursor mid-drag', !!midFlight.ghost);
                    record('chip drag: an insertion caret tracks the pointer', !!midFlight.caret);
                    record(
                        'chip drag: a landing box outlines the receiving block',
                        !!midFlight.zoneShown && !!midFlight.zoneHasArea,
                        JSON.stringify(midFlight)
                    );
                    record(
                        'chip drag: the landing box is strippable as editor chrome',
                        !!midFlight.zoneStripsAsChrome,
                        'must carry dg-drop-marker or it leaks into the saved template'
                    );
                    await page.mouse.up();
                    await page.waitForTimeout(800);

                    const after = await page.evaluate(readCanvas(geo.snippet));
                    record('chip drag: the snippet lands in the page', !!after.landed, JSON.stringify(after));
                    record('chip drag: the ghost is cleaned up', !after.ghostLeft);
                    record('chip drag: no drop marker is left behind', !after.markerLeft);
                    record('chip drag: no landing box is left behind', !after.zoneLeft);
                }
            } catch (e) {
                record('chip drag onto the page', false, e.message);
            }

            // A mousedown with no movement must still behave as a plain click-insert —
            // arming the drag must not swallow the click.
            try {
                await page.evaluate(seedCanvas);
                await ensureTagRail(page, inPage);
                const geo2 = await page.evaluate(geometry);
                if (!geo2) {
                    // Never let this fall through silently — a check that quietly does
                    // not run looks identical to a check that passed.
                    record('chip click (no drag) still inserts', false, 'tag rail had no chip to click');
                } else {
                    await page.mouse.move(geo2.chipX, geo2.chipY);
                    await page.mouse.down();
                    await page.mouse.up();
                    await page.waitForTimeout(700);
                    const after2 = await page.evaluate(readCanvas(geo2.snippet));
                    record('chip click (no drag) still inserts', !!after2.landed, JSON.stringify(after2));
                }
            } catch (e) {
                record('chip click (no drag) still inserts', false, e.message);
            }
        }

        // --- 4c. Where the caret lands after an insert ---------------------------
        // Range.insertNode leaves the range BEFORE the content it inserted, so without
        // an explicit park the caret sits to the LEFT of a freshly inserted merge tag
        // and the next keystroke types in front of it. Typing is the only honest test:
        // reading the range says where the caret claims to be, not where text goes.
        {
            const seedOne = inPage(`
      const pv = __dgFind('.dg-pv');
      if (!pv) return false;
      const keep = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (keep) pv.appendChild(keep);
      const p = document.createElement('p');
      p.textContent = 'HEAD ';
      pv.appendChild(p);
      const r = document.createRange();
      r.selectNodeContents(p); r.collapse(false);
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      pv.focus();
      document.dispatchEvent(new Event('selectionchange'));
      return true;`);

            const openTags = inPage(`
      if (__dgFind('.dg-tag-chip[data-snippet]')) return 'already-open';
      const btn = __dgFind('[data-panel="tags"]');
      if (!btn) return false;
      btn.click();
      return true;`);

            const clickFirstChip = inPage(`
      const chip = __dgFind('.dg-tag-chip[data-snippet]');
      if (!chip) return null;
      const snip = chip.getAttribute('data-snippet');
      chip.click();
      return snip;`);

            try {
                await page.evaluate(seedOne);
                await ensureTagRail(page, inPage);
                const snip = await page.evaluate(clickFirstChip);
                if (!snip) {
                    record('insert: caret lands after the tag', false, 'no chip available to insert');
                } else {
                    await page.waitForTimeout(900);
                    await page.keyboard.type('XYZ');
                    await page.waitForTimeout(500);
                    const text = await page.evaluate(
                        inPage(`const pv = __dgFind('.dg-pv'); return pv ? pv.textContent : '';`)
                    );
                    // The typed marker must appear AFTER the tag text, not before it.
                    const tagAt = text.indexOf(snip.replace(/[{}]/g, ''));
                    const typedAt = text.indexOf('XYZ');
                    record(
                        'insert: caret lands after the tag, not before it',
                        tagAt !== -1 && typedAt !== -1 && typedAt > tagAt,
                        JSON.stringify({ tagAt, typedAt, text: text.slice(0, 80) })
                    );
                }
            } catch (e) {
                record('insert: caret lands after the tag, not before it', false, e.message);
            }

            // Two inserts in a row must read left-to-right. A stale remembered caret
            // sends the second insert back to where the first started, which silently
            // reverses their order.
            try {
                await page.evaluate(seedOne);
                await ensureTagRail(page, inPage);
                const order = await page.evaluate(
                    inPage(`
      const chips = __dgFind('.dg-tag-chip[data-snippet]', true);
      if (!chips || chips.length < 2) return null;
      return [chips[0].getAttribute('data-snippet'), chips[1].getAttribute('data-snippet')];`)
                );
                if (!order) {
                    record('insert: two inserts keep their order', false, 'need two distinct chips');
                } else {
                    await page.evaluate(
                        inPage(`const c = __dgFind('.dg-tag-chip[data-snippet]', true); c[0].click(); return true;`)
                    );
                    await page.waitForTimeout(900);
                    await page.evaluate(
                        inPage(`const c = __dgFind('.dg-tag-chip[data-snippet]', true); c[1].click(); return true;`)
                    );
                    await page.waitForTimeout(900);
                    const text2 = await page.evaluate(
                        inPage(`const pv = __dgFind('.dg-pv'); return pv ? pv.textContent : '';`)
                    );
                    const a = text2.indexOf(order[0].replace(/[{}]/g, ''));
                    const b = text2.indexOf(order[1].replace(/[{}]/g, ''));
                    record(
                        'insert: two inserts keep their order',
                        a !== -1 && b !== -1 && b > a,
                        JSON.stringify({ first: order[0], second: order[1], a, b })
                    );
                }
            } catch (e) {
                record('insert: two inserts keep their order', false, e.message);
            }
        }

        // --- 4d. "/" must reach the canvas, not Lightning's global search ---------
        // Lightning binds "/" as a global search hotkey on window capture. This broke
        // once and nobody noticed, because the recovery that was supposed to catch it
        // keyed off event.relatedTarget — which is null on focusout across trees, so
        // the condition was false every single time and the whole mechanism was dead
        // code. A silently-disabled workaround is exactly what a regression guard is
        // for, so this asserts the OBSERVABLE outcome: the slash lands in the document
        // and focus stays put.
        {
            try {
                const seeded = await page.evaluate(
                    inPage(`
      const pv = __dgFind('.dg-pv');
      if (!pv) return false;
      const keep = pv.querySelector('style');
      while (pv.firstChild) pv.removeChild(pv.firstChild);
      if (keep) pv.appendChild(keep);
      const p = document.createElement('p');
      p.textContent = 'SLASHTEST ';
      pv.appendChild(p);
      pv.focus();
      const r = document.createRange();
      r.selectNodeContents(p); r.collapse(false);
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      document.dispatchEvent(new Event('selectionchange'));
      return true;`)
                );
                if (!seeded) {
                    record('"/" reaches the canvas instead of global search', false, 'could not seed the canvas');
                } else {
                    await page.waitForTimeout(500);
                    await page.keyboard.press('/');
                    // Generous: the recovery path is asynchronous by design.
                    await page.waitForTimeout(1800);
                    const after = await page.evaluate(
                        inPage(`
      const pv = __dgFind('.dg-pv');
      const ae = document.activeElement;
      const cls = String((ae && ae.className) || '');
      return {
        text: pv ? (pv.textContent || '') : '',
        focusInSearch: cls.indexOf('saInput') !== -1 || cls.indexOf('slds-lookup__search-input') !== -1
      };`)
                    );
                    record(
                        '"/" reaches the canvas instead of global search',
                        after.text.indexOf('/') !== -1,
                        JSON.stringify({ text: after.text.slice(0, 40), focusInSearch: after.focusInSearch })
                    );
                    record('"/" does not leave focus in global search', !after.focusInSearch);
                }
            } catch (e) {
                record('"/" reaches the canvas instead of global search', false, e.message);
            }
        }

        // --- 4e. #322 — a header/footer insert that never fires 'input' must still
        // survive Save. _syncBandToRecord (which unpillifies a band back into
        // editTemplateHeaderHtml/FooterHtml) used to be wired ONLY to the band's
        // native 'input' listener. A chip click inserts via Range.insertNode, which
        // the DOM spec does not fire 'input' for, so the tag was visibly added to
        // the canvas, "Save as New Version" reported success, and the persisted
        // Header_Html__c silently kept its PRE-insert value — proven against a real
        // saved record with scripts/qa's SOQL, not DOM state, which is what let it
        // ship unnoticed. This check is the regression guard for that fix.
        {
            const soqlHeader = () => {
                try {
                    // shell: true for the sf.cmd/sf.ps1 resolution reason noted on
                    // frontDoorUrl above. With shell: true, Node concatenates args
                    // rather than quoting each one, so the query — which has spaces —
                    // is wrapped in its own quotes here rather than relying on the
                    // array boundary.
                    const q =
                        "SELECT Id, Header_Html__c FROM DocGen_Template__c WHERE Name = 'Verify — Designer (pill-dense)'";
                    const raw = execFileSync('sf', ['data', 'query', '--target-org', ORG, '-q', `"${q}"`, '--json'], {
                        encoding: 'utf8',
                        shell: true
                    });
                    const rec = (JSON.parse(raw).result || {}).records || [];
                    return rec[0] || null;
                } catch (e) {
                    return null;
                }
            };

            let before = null;
            try {
                before = soqlHeader();
                if (!before) {
                    record(
                        'header persistence: chip insert (no keystroke) survives Save',
                        false,
                        'could not read the fixture record via SOQL'
                    );
                } else {
                    const focusHeader = inPage(`
            const b = __dgFind('.dg-chrome-band_header');
            if (!b) return false;
            b.focus();
            return true;`);
                    const clickFirstChipIn = inPage(`
            const chip = __dgFind('.dg-tag-chip[data-snippet]');
            if (!chip) return null;
            const snip = chip.getAttribute('data-snippet');
            chip.click();
            return snip;`);

                    const focused = await page.evaluate(focusHeader);
                    await ensureTagRail(page, inPage);
                    const snippet = focused ? await page.evaluate(clickFirstChipIn) : null;

                    if (!snippet) {
                        record(
                            'header persistence: chip insert (no keystroke) survives Save',
                            false,
                            'could not focus the header band or find a chip to insert'
                        );
                    } else {
                        await page.waitForTimeout(600);
                        const saveBtn = page.locator('button:has-text("Save as New Version")').first();
                        if (!(await saveBtn.count())) {
                            record(
                                'header persistence: chip insert (no keystroke) survives Save',
                                false,
                                'no "Save as New Version" button found'
                            );
                        } else {
                            await saveBtn.click();
                            await page.waitForTimeout(4000);
                            const after = soqlHeader();
                            const persisted = (after && after.Header_Html__c) || '';
                            record(
                                'header persistence: chip insert (no keystroke) survives Save',
                                persisted.indexOf(snippet) !== -1,
                                `snippet=${snippet}; persisted=${persisted.slice(0, 160)}`
                            );
                            record(
                                'header persistence: no editor pill markup leaks into saved source',
                                persisted.indexOf('data-dg-tag') === -1,
                                persisted.slice(0, 160)
                            );
                        }
                    }
                }
            } catch (e) {
                record('header persistence: chip insert (no keystroke) survives Save', false, e.message);
            } finally {
                // Restore the fixture so repeated runs of this suite stay idempotent —
                // this is the one check here that mutates a real saved record. Goes
                // through anonymous Apex rather than `sf data record update --values`:
                // the captured HTML routinely carries its own double quotes (style="…"),
                // and --values plus shell: true has no reliable way to nest those inside
                // the outer quoting a Windows shell needs for a value containing spaces.
                // An Apex string literal only has to escape \ and ', which Apex itself
                // then round-trips exactly — no shell involved at all.
                if (before && typeof before.Header_Html__c === 'string') {
                    try {
                        const escaped = before.Header_Html__c.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
                        const dir = mkdtempSync(join(tmpdir(), 'dgqa-'));
                        const file = join(dir, 'restore.apex');
                        writeFileSync(
                            file,
                            `DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c WHERE Id = '${before.Id}' LIMIT 1];\nt.Header_Html__c = '${escaped}';\nupdate t;\n`,
                            'utf8'
                        );
                        execFileSync('sf', ['apex', 'run', '--target-org', ORG, '-f', file], {
                            encoding: 'utf8',
                            shell: true
                        });
                    } catch (e) {
                        console.log('  [warning] could not restore the fixture header — ' + e.message);
                    }
                }
            }
        }

        // --- 5. No console errors while driving the UI ---------------------------
        record(
            'no console errors during interaction',
            consoleErrors.length === 0,
            consoleErrors.slice(0, 3).join(' | ')
        );
    } catch (err) {
        record('smoke run completed', false, err.message);
    } finally {
        await browser.close();
    }

    const failed = results.filter((r) => !r.ok);
    console.log(`\n${results.length - failed.length}/${results.length} checks passed\n`);
    if (failed.length) {
        console.log('FAILURES:');
        for (const f of failed) console.log(`  - ${f.name}${f.detail ? `: ${f.detail}` : ''}`);
        process.exit(1);
    }
    process.exit(0);
}

main();
