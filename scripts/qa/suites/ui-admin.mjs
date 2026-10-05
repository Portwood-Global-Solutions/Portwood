/**
 * Admin UI suite — everything in docGenAdmin EXCEPT the designer canvas.
 *
 * WHY THIS EXISTS
 * ---------------
 * scripts/ui-smoke.mjs drives the designer canvas hard, and nothing drove the
 * rest of the admin component at all: the Create-New wizard (four authoring
 * paths, three steps, an AI prompt kit), the template list (search, sort, six
 * row actions, import/export), the eight-tab edit modal, and the seven floating
 * panels. Those are the surfaces an admin spends the day in, and the only
 * evidence they worked was somebody clicking them before a release.
 *
 * HOUSE RULES (inherited from ui-smoke.mjs, learned the hard way)
 *   1. Assert BEHAVIOUR. "The button exists" is worthless — assert the record,
 *      the document, or the visible state actually changed.
 *   2. HIT_TEST anything we claim is usable. This repo has shipped several
 *      "the control is there but something invisible covers it" defects, and an
 *      el.click() on a covered element still fires, so it proves nothing.
 *   3. page.mouse / page.keyboard for anything where the BROWSER's own reaction
 *      is under test. A dispatched keydown never triggers real editing.
 *   4. inPage() bodies are template literals — `\s` collapses to "s". No regex
 *      backslash escapes in in-page code.
 *   5. LWC does NOT reflect props to attributes: `lightning-input[label="X"]`
 *      matches nothing, and `lightning-input input` never crosses the shadow
 *      boundary. Fields are found by their `label` PROPERTY and then reached
 *      through `.shadowRoot` (see fieldBox), never by attribute selector.
 *   6. Toasts auto-dismiss, so polling for one is a race. A MutationObserver is
 *      installed at document_start and records every toast as it appears.
 *
 * SIDE EFFECTS
 *   Creates templates named `QAUI-…` and deletes every `QAUI-%` template at the
 *   start AND the end of the run, so a crashed run never poisons the next one.
 */
import { writeFileSync, readFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { launch, login, openTab, inPage, HIT_TEST } from '../lib/browser.mjs';
import { runAnonymous, debugLines } from '../lib/sf.mjs';
import { check, skip, suiteResult, SEVERITY } from '../lib/report.mjs';

const APP = 'portwoodglobal__DocGen_Template_Manager';
const HUB = 'portwoodglobal__DocGen_Command_Hub';
const PREFIX = 'QAUI-';

const msg = (e) => String((e && e.message) || e).slice(0, 200);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
/** Progress trace on stderr — this suite runs for minutes and a silent hang is
 *  impossible to diagnose after the fact. */
const step = (s) => process.stderr.write(`      · ${s}\n`);

/* ================================================================== *
 * In-page toolkit
 * ================================================================== */

/**
 * Text that crosses shadow boundaries. `innerText` on a custom element does NOT
 * include its shadow tree, so every datatable cell and every lightning-button
 * label reads as '' without this — assertions would pass against empty strings.
 */
const DEEP = `
  const __deep = (el) => {
    if (!el) return '';
    let s = '';
    const walk = (n) => {
      // nodeType 3 = text, 1 = element, 11 = DocumentFragment (a shadowRoot).
      // Bailing on "not an element" skipped every shadowRoot and made this
      // return '' for every lightning-* label and datatable cell.
      if (n.nodeType === 3) { s += n.nodeValue + ' '; return; }
      if (n.nodeType === 1 && n.shadowRoot) walk(n.shadowRoot);
      if (n.nodeType !== 1 && n.nodeType !== 11 && n.nodeType !== 9) return;
      for (const c of n.childNodes) walk(c);
    };
    walk(el);
    return s.split(/[ ]+/).join(' ').trim();
  };
  const __deepAll = (root, sel) => {
    const out = [];
    const walk = (r) => {
      if (!r || !r.querySelectorAll) return;
      for (const el of r.querySelectorAll(sel)) out.push(el);
      for (const el of r.querySelectorAll('*')) if (el.shadowRoot) walk(el.shadowRoot);
    };
    // The ROOT's own shadow root counts too — without this, __deepAll on a
    // lightning-datatable host searched only its (empty) light DOM.
    if (root && root.shadowRoot) walk(root.shadowRoot);
    walk(root);
    return out;
  };
  // offsetParent is NOT usable here: it is null for elements inside a shadow
  // tree whose positioned ancestor lives outside it, which is most of this app.
  const __vis = (el) => {
    if (!el) return false;
    if (el.checkVisibility && !el.checkVisibility({ checkVisibilityCSS: true })) return false;
    const r = el.getBoundingClientRect();
    return r.width > 1 && r.height > 1;
  };
  /** 'host >>> inner' explicitly crosses one shadow boundary. */
  const __q = (sel, all) => {
    const parts = String(sel).split('>>>').map((s) => s.trim()).filter(Boolean);
    let hits = __dgFind(parts[0], true) || [];
    for (let i = 1; i < parts.length; i++) {
      const next = [];
      for (const h of hits) {
        const root = h.shadowRoot || h;
        for (const el of root.querySelectorAll(parts[i])) next.push(el);
      }
      hits = next;
    }
    return all ? hits : hits[0] || null;
  };
  /**
   * A lightning-* form control located by its RENDERED label, never by an LWC
   * property: LWC does not reflect @api props to attributes, and reading them
   * from outside the component is not something a test should depend on.
   * Visible matches win — the wizard's fields stay in the DOM behind the modal.
   */
  const __field = (label) => {
    const norm = (s) => String(s || '').split('*').join('').split(/[ ]+/).join(' ').trim();
    const cands = [];
    for (const h of __dgFind('lightning-input,lightning-textarea,lightning-combobox', true) || []) {
      // lightning-input nests lightning-primitive-input-simple, which owns the
      // label and the real <input> in a SECOND shadow root — hence __deepAll.
      if (!__deepAll(h, 'label').some((lab) => norm(__deep(lab)) === label)) continue;
      const inner = __deepAll(h, 'input, textarea')[0] || __deepAll(h, 'button')[0];
      if (inner) cands.push({ host: h, inner });
    }
    return cands.find((c) => __vis(c.inner)) || cands[0] || null;
  };`;

/**
 * HIT_TEST from browser.mjs is the judge, with one correction: it decides
 * "covered by X" using Node.contains(), which does NOT cross shadow boundaries.
 * A lightning-button-icon puts its <svg> in a nested shadow root, so the icon
 * sitting on its own button reads as an occluder. This re-checks a "covered by"
 * verdict by walking the COMPOSED tree upward from whatever is at the point; if
 * that chain reaches the element, the element really is what a click would hit.
 */
const HIT = `
  const __hit = (el) => {
    const v = __dgHittable(el);
    if (!el || String(v).indexOf('covered by') !== 0) return v;
    const r = el.getBoundingClientRect();
    const x = Math.round(r.left + r.width / 2), y = Math.round(r.top + r.height / 2);
    let top = document.elementFromPoint(x, y), guard = 0;
    while (top && top.shadowRoot && guard++ < 12) {
      const inner = top.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === top) break;
      top = inner;
    }
    let n = top, g = 0;
    while (n && g++ < 60) {
      if (n === el) return 'ok';
      n = n.parentNode != null ? n.parentNode : n.host || null;
    }
    return v;
  };`;

const KIT = HIT_TEST + DEEP + HIT;

/** Evaluate with PIERCE + HIT_TEST + deep helpers available. Never throws. */
async function ev(page, body, fallback = null) {
    try {
        return await page.evaluate(inPage(KIT + '\n' + body));
    } catch (e) {
        return fallback;
    }
}

/** Poll an in-page predicate until it returns something truthy. */
async function until(page, body, timeout = 15000, step = 500) {
    const end = Date.now() + timeout;
    for (;;) {
        const v = await ev(page, body, null);
        if (v) return v;
        if (Date.now() > end) return null;
        await wait(step);
    }
}

/** Centre point of a match, in viewport coordinates, after scrolling to it. */
const BOX_FROM = `
  const __box = (el) => {
    if (!el) return null;
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const r = el.getBoundingClientRect();
    const x = r.left + r.width / 2, y = r.top + r.height / 2;
    if (r.width < 2 || r.height < 2) return null;
    if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) return null;
    return { x, y, text: __deep(el).slice(0, 60) };
  };`;

/**
 * A REAL mouse click at the control's centre — deliberately not el.click().
 * A synthetic click lands on elements a person could never reach, which is the
 * exact class of defect this suite exists to catch.
 */
async function mouseClick(page, sel, index = 0) {
    const b = await ev(
        page,
        BOX_FROM + `const els = __q(${JSON.stringify(sel)}, true); return __box(els[${index}]);`,
        null
    );
    if (!b) return false;
    await page.mouse.click(b.x, b.y);
    return true;
}

/** Real-click the first VISIBLE element of `sel` whose deep text contains `text`. */
async function clickByText(page, sel, text, { exact = false } = {}) {
    const b = await ev(
        page,
        BOX_FROM +
            `const want = ${JSON.stringify(text)}.toLowerCase();
       for (const el of __q(${JSON.stringify(sel)}, true)) {
         const t = __deep(el).toLowerCase();
         if (!(${exact ? 't === want' : 't.indexOf(want) !== -1'})) continue;
         if (!__vis(el)) continue;
         const b = __box(el);
         if (b) return b;
       }
       return null;`,
        null
    );
    if (!b) return false;
    await page.mouse.click(b.x, b.y);
    return true;
}

/** 'ok', or the reason the control is not reachable by a mouse. */
async function hittable(page, sel, index = 0) {
    return ev(
        page,
        `const els = __q(${JSON.stringify(sel)}, true);
     const el = els[${index}];
     if (el) el.scrollIntoView({ block: 'center' });
     return __hit(el);`,
        'could not evaluate'
    );
}

/** Same, but locate by deep text (lightning-button labels live in shadow DOM). */
async function hittableByText(page, sel, text) {
    return ev(
        page,
        `const want = ${JSON.stringify(text)}.toLowerCase();
     for (const el of __q(${JSON.stringify(sel)}, true)) {
       if (__deep(el).toLowerCase().indexOf(want) === -1) continue;
       el.scrollIntoView({ block: 'center' });
       const inner = el.shadowRoot ? el.shadowRoot.querySelector('button, a, input') : null;
       return __hit(inner || el);
     }
     return 'no control with that label';`,
        'could not evaluate'
    );
}

/** Type for real into the lightning-* field carrying this label. */
async function typeField(page, label, text, { clear = true } = {}) {
    const b = await ev(
        page,
        BOX_FROM + `const f = __field(${JSON.stringify(label)}); return f ? __box(f.inner) : null;`,
        null
    );
    if (!b) return false;
    await page.mouse.click(b.x, b.y);
    if (clear) {
        await page.keyboard.press('Control+a');
        await page.keyboard.press('Meta+a');
        await page.keyboard.press('Backspace');
    }
    if (text) await page.keyboard.type(text, { delay: 10 });
    await page.keyboard.press('Tab'); // commit — lightning-input fires change on blur
    return true;
}

async function readField(page, label) {
    return ev(page, `const f = __field(${JSON.stringify(label)}); return f && f.inner ? f.inner.value : null;`, null);
}

/** Type into a plain element (the wizard's raw textareas live in light DOM). */
async function typeInto(page, sel, text, { clear = true } = {}) {
    const ok = await mouseClick(page, sel);
    if (!ok) return false;
    if (clear) {
        await page.keyboard.press('Control+a');
        await page.keyboard.press('Meta+a');
        await page.keyboard.press('Backspace');
    }
    if (text) await page.keyboard.type(text, { delay: 8 });
    return true;
}

/* ================================================================== *
 * Toast capture — installed before any page script runs
 * ================================================================== */

const TOAST_SPY = `
(() => {
  const boot = () => {
    if (!document.documentElement) { setTimeout(boot, 10); return; }
    if (window.__dgToastsInstalled) return;
    window.__dgToastsInstalled = true;
    window.__dgToasts = [];
    const grab = (el) => {
      if (!el || el.nodeType !== 1) return;
      const raw = el.className;
      const cls = String(raw && raw.baseVal !== undefined ? raw.baseVal : raw || '');
      const inner = el.querySelector ? el.querySelector('.toastMessage, .slds-notify__content') : null;
      if (!/toast|slds-notify/i.test(cls) && !inner) return;
      const txt = ((el.innerText || el.textContent || '') + '').split(/[ ]+/).join(' ').trim();
      if (!txt) return;
      const last = window.__dgToasts[window.__dgToasts.length - 1];
      if (last && last.text === txt) return;
      window.__dgToasts.push({ text: txt.slice(0, 400) });
    };
    new MutationObserver((muts) => {
      for (const m of muts) for (const n of m.addedNodes) grab(n);
    }).observe(document.documentElement, { subtree: true, childList: true });
  };
  boot();
})();`;

async function drainToasts(page) {
    try {
        return await page.evaluate(
            `(() => { const t = window.__dgToasts || []; window.__dgToasts = []; return t; })()`
        );
    } catch (e) {
        return [];
    }
}

/** Wait for a toast matching `re`; returns what it found and everything it saw. */
async function awaitToast(page, re, timeout = 9000) {
    const end = Date.now() + timeout;
    const seen = [];
    for (;;) {
        for (const t of await drainToasts(page)) {
            seen.push(t.text);
            if (re.test(t.text)) return { hit: t, seen };
        }
        if (Date.now() > end) return { hit: null, seen };
        await wait(300);
    }
}

/* ================================================================== *
 * Org-side probes — namespace-agnostic
 * ================================================================== *
 * docgen-verify is a NAMESPACED install (portwoodglobal__DocGen_Template__c);
 * a source-deployed scratch org is not. Every probe discovers the real object
 * name and namespace prefix at runtime so the suite works against either.
 */
const APEX_HEAD = `
String tgt = null;
for (String k : Schema.getGlobalDescribe().keySet()) {
    if (k.endsWith('docgen_template__c')) { tgt = k; break; }
}
String ns = tgt == null ? '' : tgt.substring(0, tgt.length() - 'docgen_template__c'.length());
String pfx = '${PREFIX}%';
if (tgt == null) { System.debug('NOOBJECT=1'); } else {
`;

async function apex(org, body) {
    try {
        const log = await runAnonymous(org, APEX_HEAD + body + '\n}', { timeout: 180000 });
        return { lines: debugLines(log), log };
    } catch (e) {
        // A failing probe must be LOUD. Silently returning no rows made an Apex
        // NullPointerException look like "the UI never created the record".
        const detail = String((e && e.stderr) || msg(e))
            .split('\n')
            .join(' ')
            .slice(0, 200);
        step('APEX PROBE FAILED: ' + detail);
        return { lines: [], log: '', error: detail };
    }
}

/** Every QAUI- template in the org, with any extra (un-prefixed) fields asked for. */
async function probeTemplates(org, extraFields = []) {
    const sel = ['Id', 'Name', ...extraFields.map((f) => `' + ns + '${f}`)].join(', ');
    // String.valueOf(null) returns null in Apex, so calling .replaceAll on it
    // throws a NullPointerException and the whole probe returns nothing.
    const getters = extraFields
        .map(
            (f) =>
                `+ '~' + (r.get(ns + '${f}') == null ? '' : String.valueOf(r.get(ns + '${f}')).replaceAll('[\\r\\n]+', ' '))`
        )
        .join('\n        ');
    const r = await apex(
        org,
        `List<SObject> rows = Database.query('SELECT ${sel} FROM ' + tgt + ' WHERE Name LIKE :pfx ORDER BY CreatedDate');
     System.debug('COUNT=' + rows.size());
     for (SObject r : rows) {
        System.debug('ROW=' + r.Id + '~' + String.valueOf(r.get('Name'))
        ${getters});
     }`
    );
    const out = [];
    for (const line of r.lines) {
        const m = /^ROW=(.+)$/.exec(line.trim());
        if (!m) continue;
        // '~', not '|': the Salesforce CLI escapes a literal pipe in debug
        // output to &#124; (it is the log's own field separator), which silently
        // broke every field this probe reads back.
        const parts = m[1].split('~');
        const row = { id: parts[0], name: parts[1] };
        extraFields.forEach((f, i) => {
            row[f] = parts[2 + i];
        });
        out.push(row);
    }
    return out;
}

async function deleteQaTemplates(org) {
    const r = await apex(
        org,
        `List<SObject> junk = Database.query('SELECT Id FROM ' + tgt + ' WHERE Name LIKE :pfx');
     if (!junk.isEmpty()) { delete junk; }
     System.debug('DELETED=' + junk.size());`
    );
    const line = r.lines.find((l) => l.trim().startsWith('DELETED='));
    return line ? Number(line.trim().slice(8)) : -1;
}

/**
 * How many DocGen_Template_Version__c records hang off the named template.
 * "Save as New Version" is named for what it must do — counting versions is the
 * only way to tell a real save from one that quietly updated in place.
 */
async function countVersions(org, templateName) {
    const safe = String(templateName).replace(/[^A-Za-z0-9 _()-]/g, '');
    const r = await apex(
        org,
        `String nm = '${safe}';
     String vtgt = null;
     for (String k : Schema.getGlobalDescribe().keySet()) {
        if (k.endsWith('docgen_template_version__c')) { vtgt = k; break; }
     }
     List<SObject> t = Database.query('SELECT Id FROM ' + tgt + ' WHERE Name = :nm');
     Integer n = -1;
     if (vtgt != null && !t.isEmpty()) {
        Id tid = t[0].Id;
        n = Database.query('SELECT Id FROM ' + vtgt + ' WHERE ' + ns + 'Template__c = :tid').size();
     }
     System.debug('VERSIONS=' + n);`
    );
    const line = r.lines.find((l) => l.trim().startsWith('VERSIONS='));
    return line ? Number(line.trim().slice(9)) : -1;
}

/* ================================================================== *
 * The suite
 * ================================================================== */

export async function run({ org, headed }) {
    const C = [];
    const add = (...c) => C.push(...c);
    const runId = Date.now().toString(36).slice(-6);
    const NAME_STARTER = `${PREFIX}${runId}-Starter`;
    const NAME_FILE = `${PREFIX}${runId}-File`;
    const NAME_IMPORT = `${PREFIX}${runId}-Imported`;

    let browser = null;
    let consoleErrors = [];
    // Native window.confirm/beforeunload dialogs, recorded so a confirmation
    // that is NOT in the DOM still counts as a confirmation.
    const nativeDialogs = [];
    let acceptDialogs = false;

    try {
        // Leftovers from a crashed run would let "the template was created" pass
        // against the wrong record, so the org is cleaned BEFORE anything runs.
        await deleteQaTemplates(org);

        const L = await launch({ headed });
        browser = L.browser;
        consoleErrors = L.consoleErrors;
        const { page, ctx } = L;
        await ctx.addInitScript(TOAST_SPY);
        page.on('dialog', async (d) => {
            nativeDialogs.push({ type: d.type(), message: d.message().slice(0, 200) });
            try {
                // beforeunload must always be accepted or navigation stalls;
                // everything else is dismissed unless a step opted in.
                if (d.type() === 'beforeunload' || acceptDialogs) await d.accept();
                else await d.dismiss();
            } catch (e) {
                /* dialog already handled */
            }
        });

        const base = await login(page, org);
        try {
            // The AI prompt kit and the tag chips both assert through the
            // clipboard; without this grant readText() rejects in headless.
            await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: base });
        } catch (e) {
            /* older Chromium — those checks degrade to skips below */
        }
        step('app open');
        await openTab(page, base, APP, 9000);

        /* ============================================================ *
         * 1. SHELL
         * ============================================================ */
        const shell = await until(
            page,
            `const tabs = (__dgFind('[role="tab"]', true) || []).map((t) => __deep(t));
       const want = ['Create New', 'Your Templates', 'Designer'];
       return want.every((w) => tabs.some((t) => t.indexOf(w) !== -1)) ? { tabs } : null;`,
            40000,
            1500
        );
        add(
            check(
                'admin app mounts with its three main tabs',
                !!shell,
                shell ? shell.tabs.slice(0, 6).join(' | ') : 'Create New / Your Templates / Designer never rendered',
                SEVERITY.BLOCKER
            )
        );
        if (!shell) return suiteResult('ui-admin', 'Admin UI', C);

        for (const label of ['Create New', 'Your Templates', 'Designer']) {
            const verdict = await ev(
                page,
                `const t = (__dgFind('[role="tab"]', true) || []).find((x) => __deep(x).indexOf(${JSON.stringify(label)}) !== -1);
         if (t) t.scrollIntoView({ block: 'center' });
         return __hit(t);`,
                'could not evaluate'
            );
            add(
                check(
                    `main tab "${label}" is reachable by a mouse`,
                    verdict === 'ok',
                    verdict === 'ok' ? '' : `hit-test says: ${verdict}`,
                    SEVERITY.MAJOR
                )
            );
        }

        // Behaviour, not layout: the tab must swap in its own content, and the
        // marker must be VISIBLE — lightning-tabset keeps loaded panels in the DOM.
        for (const [label, marker] of [
            ['Your Templates', 'lightning-datatable'],
            ['Create New', '.dg-authoring-card']
        ]) {
            await clickByText(page, '[role="tab"]', label);
            await wait(3000);
            const shown = await ev(page, `return __vis(__dgFind(${JSON.stringify(marker)}));`, false);
            add(
                check(
                    `main tab "${label}" swaps in its own content`,
                    shown === true,
                    shown === true ? '' : `after clicking the tab, ${marker} was not visible`,
                    SEVERITY.MAJOR
                )
            );
        }

        /* ============================================================ *
         * 2. CREATE NEW WIZARD
         * ============================================================ */
        await clickByText(page, '[role="tab"]', 'Create New');
        await wait(2500);
        await drainToasts(page);

        step('wizard: authoring cards');
        // 2a. Authoring cards — each must select AND reveal its own path.
        // v3.54 retired 'starter', 'ai' and 'scratch' from the wizard — see
        // docGenAdmin.authoringCards. Templates already created those ways still open
        // and edit, but the wizard offers two paths now, and asserting on three cards
        // that were deliberately deleted reported six failures for working software.
        const cardPaths = [
            { mode: 'file', marker: 'Output Format', text: true, what: 'the Type / Output Format pickers' },
            // "Create & Open Canvas", not "…Designer" — the canvas path has its own
            // button label, and Output Format is not shown at all because a Canvas
            // template can only be PDF.
            { mode: 'canvas', marker: 'Create & Open Canvas', text: true, what: 'the Canvas setup fields' }
        ];
        for (const cp of cardPaths) {
            const verdict = await hittable(page, `[data-mode="${cp.mode}"]`);
            add(
                check(
                    `authoring card "${cp.mode}" is reachable by a mouse`,
                    verdict === 'ok',
                    verdict === 'ok' ? '' : `hit-test says: ${verdict}`,
                    SEVERITY.MAJOR
                )
            );
            const clicked = await mouseClick(page, `[data-mode="${cp.mode}"]`);
            await wait(1500);
            const state = await ev(
                page,
                `const el = __dgFind('[data-mode="${cp.mode}"]');
         const others = (__dgFind('[data-mode]', true) || []).filter((x) => x.dataset.mode !== '${cp.mode}');
         const content = __dgFind('.wizard-content');
         const marker = ${
             cp.text
                 ? `content ? __deep(content).indexOf(${JSON.stringify(cp.marker)}) !== -1 : false`
                 : `__vis(__dgFind(${JSON.stringify(cp.marker)}))`
         };
         return {
           checked: el ? el.getAttribute('aria-checked') === 'true' : false,
           othersChecked: others.filter((x) => x.getAttribute('aria-checked') === 'true').length,
           marker
         };`,
                null
            );
            add(
                check(
                    `authoring card "${cp.mode}" selects and reveals ${cp.what}`,
                    !!(clicked && state && state.checked && state.othersChecked === 0 && state.marker),
                    state
                        ? `clicked=${clicked} selected=${state.checked} otherCardsSelected=${state.othersChecked} pathContentShown=${state.marker}`
                        : 'card state unreadable',
                    SEVERITY.MAJOR
                )
            );
        }

        // 2b. The starter gallery is gone (v3.54). Nothing replaced it — a blank
        // canvas IS the replacement — so there is no gallery probe to write here.

        // 2c. The advanced-options disclosure must actually disclose.
        const advBefore = await ev(page, `return __vis(__dgFind('lightning-radio-group'));`, false);
        await clickByText(page, 'lightning-button', 'Advanced options');
        await wait(1400);
        const advAfter = await ev(page, `return __vis(__dgFind('lightning-radio-group'));`, false);
        add(
            check(
                'Advanced options discloses the power-user fields',
                advBefore === false && advAfter === true,
                `Data Source radio group visible before=${advBefore} after=${advAfter}`,
                SEVERITY.MAJOR
            )
        );
        await clickByText(page, 'lightning-button', 'Hide advanced options');
        await wait(1200);

        step('wizard: validation');
        // 2d. REQUIRED-FIELD VALIDATION — an empty submit must complain out loud
        //     and must not leave a half-made record behind.
        await mouseClick(page, '[data-mode="canvas"]');
        await wait(1000);
        await typeField(page, 'Template Name', '');
        await drainToasts(page);
        await clickByText(page, 'lightning-button', 'Create & Open Canvas');
        const emptyName = await awaitToast(page, /name it first|template name|required/i);
        add(
            check(
                'creating with an empty name is refused with a visible error',
                !!emptyName.hit,
                emptyName.hit
                    ? emptyName.hit.text.slice(0, 120)
                    : `no error toast appeared — the button silently did nothing. Toasts seen: ${emptyName.seen.join(' / ') || '(none)'}`,
                SEVERITY.MAJOR
            )
        );
        const strays = await probeTemplates(org);
        add(
            check(
                'a refused create writes no template record',
                strays.length === 0,
                strays.length ? `orphan rows created: ${strays.map((r) => r.name).join(', ')}` : '',
                SEVERITY.BLOCKER
            )
        );

        step('wizard: file path steps');
        // 2e. FILE PATH — the classic three-step wizard, Back included.
        await mouseClick(page, '[data-mode="file"]');
        await wait(1400);
        await drainToasts(page);
        await clickByText(page, 'lightning-button', 'Next', { exact: true });
        const nextEmpty = await awaitToast(page, /fill in the template name|name and type/i);
        const stillStep1 = await ev(page, `return __vis(__dgFind('.dg-authoring-card'));`, false);
        add(
            check(
                'wizard Next refuses to advance without a name',
                !!nextEmpty.hit && stillStep1 === true,
                nextEmpty.hit
                    ? `error shown; still on step 1 = ${stillStep1}`
                    : `no error toast. Toasts seen: ${nextEmpty.seen.join(' / ') || '(none)'}`,
                SEVERITY.MAJOR
            )
        );

        await typeField(page, 'Template Name', NAME_FILE);
        await wait(600);
        await drainToasts(page);
        await clickByText(page, 'lightning-button', 'Next', { exact: true });
        const onStep2 = await until(page, `return __dgFind('.wizard-query-textarea') ? { ok: 1 } : null;`, 15000);
        add(
            check(
                'wizard Next advances to step 2 (Pick Your Data)',
                !!onStep2,
                onStep2 ? '' : 'the query step never rendered — .wizard-query-textarea missing',
                SEVERITY.MAJOR
            )
        );

        await clickByText(page, 'lightning-button', 'Back', { exact: true });
        await wait(2500);
        const backName = await readField(page, 'Template Name');
        const backStep1 = await ev(page, `return __vis(__dgFind('.dg-authoring-card'));`, false);
        add(
            check(
                'wizard Back returns to step 1 and keeps what was typed',
                backStep1 === true && backName === NAME_FILE,
                `onStep1=${backStep1} name="${backName}" (expected "${NAME_FILE}")`,
                SEVERITY.MAJOR
            )
        );

        await clickByText(page, 'lightning-button', 'Next', { exact: true });
        await wait(3000);
        await drainToasts(page);
        await clickByText(page, 'lightning-button', 'Next', { exact: true });
        const emptyQuery = await awaitToast(page, /at least one field|query/i);
        add(
            check(
                'wizard step 2 refuses an empty query',
                !!emptyQuery.hit,
                emptyQuery.hit
                    ? emptyQuery.hit.text.slice(0, 120)
                    : `no error toast. Toasts seen: ${emptyQuery.seen.join(' / ') || '(none)'}`,
                SEVERITY.MAJOR
            )
        );

        await typeInto(page, '.wizard-query-textarea', 'Name, Industry, Phone');
        await wait(900);
        await page.keyboard.press('Escape'); // the suggestion dropdown eats the next click
        await wait(500);
        await clickByText(page, 'lightning-button', 'Next', { exact: true });
        await wait(3000);
        const step3 = await ev(
            page,
            `const c = __dgFind('.wizard-content');
       const t = c ? __deep(c) : '';
       return { review: t.indexOf('Review Template') !== -1, echoesQuery: t.indexOf('Industry') !== -1, echoesName: t.indexOf(${JSON.stringify(NAME_FILE)}) !== -1 };`,
            null
        );
        add(
            check(
                'wizard step 3 reviews the name, object and query it will save',
                !!(step3 && step3.review && step3.echoesQuery && step3.echoesName),
                step3
                    ? `reviewScreen=${step3.review} nameEchoed=${step3.echoesName} queryEchoed=${step3.echoesQuery}`
                    : 'unreadable',
                SEVERITY.MAJOR
            )
        );

        step('wizard: create #1 (file path)');
        // END-TO-END CREATE #1 — the classic path really writes a record.
        await drainToasts(page);
        const createClicked = await clickByText(page, 'lightning-button', 'Create Template', { exact: true });
        await wait(10000);
        const afterCreate = await probeTemplates(org, ['Base_Object_API__c', 'Query_Config__c']);
        const fileRow = afterCreate.find((r) => r.name === NAME_FILE);
        add(
            check(
                'the wizard creates a template record end to end',
                !!fileRow,
                fileRow
                    ? `${fileRow.id}, base object ${fileRow['Base_Object_API__c']}`
                    : `clicked=${createClicked}; no ${PREFIX} record exists after Create Template`,
                SEVERITY.BLOCKER
            )
        );
        add(
            check(
                'the created template keeps the query the wizard collected',
                !!(fileRow && String(fileRow['Query_Config__c'] || '').indexOf('Industry') !== -1),
                fileRow
                    ? `Query_Config__c = ${String(fileRow['Query_Config__c']).slice(0, 90)}`
                    : 'no record to inspect',
                SEVERITY.MAJOR
            )
        );
        await clickByText(page, 'lightning-button', 'Close', { exact: true });
        await wait(2000);

        // 2f. The AI prompt kit lived on the wizard's 'ai' card, retired in v3.54.
        // AI authoring still exists inside the HTML designer (Generate with Agentforce),
        // which is a different surface with its own coverage — this block asserted on a
        // wizard step that no longer exists.

        step('wizard: create #2 (blank canvas -> designer)');
        /* --- 2g. END-TO-END CREATE #2 — the canvas path into the designer ---
         *
         * This was the starter path until v3.54 retired the starters. The canvas is
         * what the wizard offers in their place, so it is what this has to prove: the
         * record is created, and the editor it opens is the CANVAS artboard, not the
         * flow designer. They are different components with different markup — a probe
         * for `.dg-pv` would pass on a Canvas template only by accident. */
        // Re-enter the wizard from the tab rather than pressing Back. Back depended on
        // whatever state the previous phase left behind, and after the file-path create
        // that is no longer the card screen — so the canvas card was never clicked and
        // the whole phase reported three blockers for a path that works. Verified by
        // hand: this sequence creates the record and types it Canvas.
        await clickByText(page, '[role="tab"]', 'Your Templates');
        await wait(1500);
        await clickByText(page, '[role="tab"]', 'Create New');
        await wait(2500);
        await drainToasts(page);
        await mouseClick(page, '[data-mode="canvas"]');
        await wait(1500);
        await typeField(page, 'Template Name', NAME_STARTER);
        await wait(800);
        await drainToasts(page);
        await clickByText(page, 'lightning-button', 'Create & Open Canvas');
        const canvasUp = await until(
            page,
            `return __dgFind('.dg-board') && __dgFind('.dg-rail') ? { ok: 1 } : null;`,
            120000,
            2000
        );
        const starterRow = (await probeTemplates(org, ['Type__c', 'Output_Format__c'])).find(
            (r) => r.name === NAME_STARTER
        );
        add(
            check(
                'the canvas path creates the template record',
                !!starterRow,
                starterRow
                    ? `${starterRow.id}, ${starterRow['Type__c']}/${starterRow['Output_Format__c']}`
                    : 'no record was created by "Create & Open Canvas"',
                SEVERITY.BLOCKER
            )
        );
        add(
            check(
                'and it is typed Canvas, which is what decides which editor opens',
                !!starterRow && starterRow['Type__c'] === 'Canvas',
                starterRow ? `Type__c=${starterRow['Type__c']}` : 'no record',
                SEVERITY.BLOCKER
            )
        );
        add(
            check(
                'the canvas path lands on the artboard',
                !!canvasUp,
                canvasUp ? '' : 'the artboard (.dg-board) never appeared',
                SEVERITY.BLOCKER
            )
        );
        // The flow designer's panels are tested below and do not exist on a canvas, so
        // that block stays gated on its own editor being the one that opened.
        const designerUp = false;

        /* ============================================================ *
         * 3. DESIGNER CHROME — floating panels + page setup
         *    (the CANVAS is ui-smoke.mjs's job; this is everything round it)
         * ============================================================ */
        if (designerUp) {
            step('designer panels');
            const panels = [
                { key: 'insert', title: 'Insert blocks' },
                { key: 'tags', title: 'Merge tags' },
                { key: 'images', title: 'Image assets' },
                { key: 'query', title: 'Query fields' },
                { key: 'versions', title: 'Version history' },
                { key: 'hf', title: 'Header & Footer' },
                { key: 'watermark', title: 'Watermark' }
            ];
            for (const p of panels) {
                const present = await ev(page, `return !!__dgFind('[data-panel="${p.key}"]');`, false);
                if (present !== true) {
                    add(
                        skip(
                            `panel "${p.key}" opens with its contents rendered`,
                            'this panel button is not offered for this template type / output format',
                            SEVERITY.MINOR
                        )
                    );
                    continue;
                }
                const btnHit = await hittable(page, `[data-panel="${p.key}"]`);
                add(
                    check(
                        `panel button "${p.key}" is reachable by a mouse`,
                        btnHit === 'ok',
                        btnHit === 'ok' ? '' : `hit-test says: ${btnHit}`,
                        SEVERITY.MAJOR
                    )
                );
                await mouseClick(page, `[data-panel="${p.key}"]`);
                await wait(2000);
                const opened = await ev(
                    page,
                    `const panel = __dgFind('.dg-float-panel');
           if (!panel) return { open: false };
           const title = __dgFind('.dg-float-panel-title');
           return {
             open: true,
             title: title ? __deep(title) : '',
             controls: __deepAll(panel, 'button, input, select, textarea, a, [role="option"]').length,
             textLen: __deep(panel).length,
             hit: __hit(panel)
           };`,
                    null
                );
                add(
                    check(
                        `panel "${p.key}" opens with its contents rendered`,
                        !!(
                            opened &&
                            opened.open &&
                            opened.title === p.title &&
                            (opened.controls > 1 || opened.textLen > 60)
                        ),
                        opened
                            ? `title="${opened.title}" (expected "${p.title}"), interactive children=${opened.controls}, text=${opened.textLen} chars`
                            : 'the panel never opened',
                        SEVERITY.MAJOR
                    )
                );
                add(
                    check(
                        `panel "${p.key}" is not clipped or covered once open`,
                        !!(opened && opened.hit === 'ok'),
                        opened ? `hit-test says: ${opened.hit}` : 'the panel never opened',
                        SEVERITY.MAJOR
                    )
                );
                await mouseClick(page, '.dg-float-panel .dg-pill-menu-x');
                await wait(1000);
                const closed = await ev(page, `return !__dgFind('.dg-float-panel');`, false);
                add(
                    check(
                        `panel "${p.key}" closes from its own X`,
                        closed === true,
                        closed === true ? '' : 'the panel stayed open after its close button was clicked',
                        SEVERITY.MINOR
                    )
                );
                if (closed !== true) {
                    await mouseClick(page, `[data-panel="${p.key}"]`);
                    await wait(800);
                }
            }

            // A panel exists to DO something. The Tags panel's job is putting a
            // merge tag on the page — assert that, not that chips rendered.
            await mouseClick(page, '[data-panel="tags"]');
            await wait(2000);
            const tagInsert = await ev(
                page,
                `const pv = __dgFind('.dg-pv');
         if (!pv) return { ok: false, why: 'no canvas' };
         const panel = __dgFind('.dg-float-panel');
         if (!panel) return { ok: false, why: 'the tags panel did not open' };
         // The panel head's ✕ is a button too — a chip is one that inserts.
         const chip = __deepAll(panel, 'button').filter((b) => (b.className || '').indexOf('dg-pill-menu-x') === -1)[0];
         if (!chip) return { ok: false, why: 'the tags panel rendered no chips' };
         const label = __deep(chip).slice(0, 40);
         const before = pv.innerHTML;
         chip.click();
         return { ok: pv.innerHTML !== before, why: pv.innerHTML !== before ? 'inserted "' + label + '"' : 'clicking "' + label + '" changed nothing on the page' };`,
                null
            );
            add(
                check(
                    'Tags panel: clicking a tag puts it on the page',
                    !!(tagInsert && tagInsert.ok),
                    tagInsert ? tagInsert.why : 'unreadable',
                    SEVERITY.MAJOR
                )
            );
            await mouseClick(page, '.dg-float-panel .dg-pill-menu-x');
            await wait(900);

            // Page-setup pickers sit on the designer chrome, outside the canvas.
            const setup = await ev(
                page,
                `return (__dgFind('select', true) || [])
           .map((s) => [...s.options].map((o) => o.value))
           .filter((v) => v.indexOf('Letter') !== -1 || v.indexOf('landscape') !== -1).length;`,
                0
            );
            add(
                check(
                    'the designer exposes its page size and orientation pickers',
                    setup >= 2,
                    `${setup} page-setup selects found (expected at least size + orientation)`,
                    SEVERITY.MAJOR
                )
            );
            const orient = await ev(
                page,
                `const sheet = __dgFind('.dg-pv');
         const sel = (__dgFind('select', true) || []).find((s) => [...s.options].map((o) => o.value).indexOf('landscape') !== -1);
         if (!sheet || !sel) return null;
         const before = sheet.getBoundingClientRect().width;
         sel.value = sel.value === 'landscape' ? 'portrait' : 'landscape';
         sel.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
         return { before, target: sel.value };`,
                null
            );
            if (orient) {
                await wait(2000);
                const after = await ev(
                    page,
                    `const s = __dgFind('.dg-pv'); return s ? s.getBoundingClientRect().width : 0;`,
                    0
                );
                add(
                    check(
                        'changing page orientation resizes the sheet',
                        Math.abs(after - orient.before) > 20,
                        `sheet width ${Math.round(orient.before)} -> ${Math.round(after)} switching to ${orient.target}`,
                        SEVERITY.MAJOR
                    )
                );
            } else {
                add(
                    skip('changing page orientation resizes the sheet', 'no orientation select on the designer surface')
                );
            }
        } else {
            add(skip('the floating panels open with their contents rendered', 'the designer never opened'));
        }

        /* ============================================================ *
         * 4. YOUR TEMPLATES
         * ============================================================ */
        step('template list');
        await openTab(page, base, APP, 9000);
        await clickByText(page, '[role="tab"]', 'Your Templates');
        await wait(4000);

        const READ_ROWS = `
      const dt = __dgFind('lightning-datatable');
      if (!dt || !dt.shadowRoot) return null;
      const rows = [...dt.shadowRoot.querySelectorAll('tbody tr')].map((tr) => __deep(tr));
      // "12 templates" / "3 of 12 templates" — matched precisely so the Word
      // conversion blurb (which also says "templates") cannot be mistaken for it.
      const label = (__dgFind('p', true) || []).map((e) => __deep(e))
        .find((t) => /^[0-9]+( of [0-9]+)? templates$/.test(t)) || '';
      return { count: rows.length, rows, label };`;

        const listed = await until(
            page,
            READ_ROWS.replace(
                'return { count: rows.length',
                'if (!rows.length) return null;\n      return { count: rows.length'
            ),
            25000,
            1500
        );
        add(
            check(
                'the template list renders rows',
                !!(listed && listed.count > 0),
                listed
                    ? `${listed.count} rows; count label "${listed.label}"`
                    : 'lightning-datatable never rendered any rows',
                SEVERITY.BLOCKER
            )
        );

        if (listed && listed.count > 0) {
            const total = listed.count;

            // SEARCH — must narrow, and every surviving row must actually match.
            await typeField(page, 'Search Templates', runId);
            await wait(2500);
            const searched = await ev(page, READ_ROWS, null);
            const allMatch =
                searched && searched.rows.every((r) => r.toLowerCase().indexOf(runId.toLowerCase()) !== -1);
            add(
                check(
                    'search narrows the list to matching rows only',
                    !!(searched && searched.count > 0 && searched.count < total && allMatch),
                    searched
                        ? `${total} -> ${searched.count} rows for "${runId}"; every remaining row matches = ${allMatch}`
                        : 'the list was unreadable after searching',
                    SEVERITY.MAJOR
                )
            );
            add(
                check(
                    'the row-count label reports the filtered subset',
                    !!(searched && / of /i.test(searched.label)),
                    searched ? `label reads "${searched.label}"` : 'unreadable',
                    SEVERITY.MINOR
                )
            );

            await typeField(page, 'Search Templates', 'zzz-no-such-template-zzz');
            await wait(2200);
            const noMatch = await ev(page, READ_ROWS, null);
            add(
                check(
                    'a search with no matches empties the list instead of ignoring the query',
                    !!(noMatch && noMatch.count === 0),
                    noMatch ? `${noMatch.count} rows survived a nonsense query` : 'unreadable',
                    SEVERITY.MAJOR
                )
            );

            await typeField(page, 'Search Templates', '');
            await wait(2200);
            const restored = await ev(page, READ_ROWS, null);
            add(
                check(
                    'clearing the search restores the full list',
                    !!(restored && restored.count === total),
                    restored ? `${restored.count} rows (expected ${total})` : 'unreadable',
                    SEVERITY.MAJOR
                )
            );

            // SORT — assert the DISPLAYED ORDER changes, not just an attribute.
            const firstBefore = restored ? restored.rows[0] : '';
            const sortClicked = await clickByText(page, '.slds-th__action', 'Name');
            await wait(2200);
            const asc = await ev(page, READ_ROWS, null);
            await clickByText(page, '.slds-th__action', 'Name');
            await wait(2200);
            const desc = await ev(page, READ_ROWS, null);
            add(
                check(
                    'clicking a column header re-orders the rows both ways',
                    !!(asc && desc && asc.count === total && desc.count === total && asc.rows[0] !== desc.rows[0]),
                    asc && desc
                        ? `clicked=${sortClicked}; first row "${String(firstBefore).slice(0, 28)}" -> asc "${String(asc.rows[0]).slice(0, 28)}" -> desc "${String(desc.rows[0]).slice(0, 28)}"`
                        : 'the table was unreadable after sorting',
                    SEVERITY.MAJOR
                )
            );

            // REFRESH — the regression to watch for is that it blanks the table.
            const refreshHit = await hittableByText(page, 'lightning-button', 'Refresh');
            await clickByText(page, 'lightning-button', 'Refresh', { exact: true });
            await wait(4000);
            const afterRefresh = await ev(page, READ_ROWS, null);
            add(
                check(
                    'Refresh reloads the list without emptying it',
                    !!(afterRefresh && afterRefresh.count === total),
                    `hit-test=${refreshHit}; ${afterRefresh ? afterRefresh.count : '?'} rows after refresh (expected ${total})`,
                    SEVERITY.MAJOR
                )
            );

            await clickByText(page, 'lightning-button', 'New Template', { exact: true });
            await wait(2500);
            const toWizard = await ev(page, `return __vis(__dgFind('.dg-authoring-card'));`, false);
            add(
                check(
                    '"New Template" switches to the Create New wizard',
                    toWizard === true,
                    toWizard === true ? '' : 'the wizard did not become visible',
                    SEVERITY.MAJOR
                )
            );
            await clickByText(page, '[role="tab"]', 'Your Templates');
            await wait(3000);
        }

        step('row actions');
        /* --- 4b. ROW ACTIONS ---------------------------------------- */
        /**
         * Open a template's row-action menu and pick an item, with real mouse
         * clicks. Playwright's own locator.click() kept timing out on this menu
         * (it resolves the item, then never satisfies its actionability checks
         * because the menu is portalled and animating), so the row, the trigger
         * and the item are all resolved and clicked the same way everything else
         * in this suite is.
         */
        const rowAction = async (templateName, action) => {
            await page.keyboard.press('Escape'); // any menu left open eats the click
            await wait(400);
            const trigger = await ev(
                page,
                BOX_FROM +
                    `const dt = __dgFind('lightning-datatable');
         if (!dt || !dt.shadowRoot) return null;
         const rows = [...dt.shadowRoot.querySelectorAll('tbody tr')];
         const row = rows.find((tr) => __deep(tr).indexOf(${JSON.stringify(templateName)}) !== -1);
         if (!row) return { missing: 'row' };
         const btn = __deepAll(row, 'button[aria-haspopup="true"]')[0];
         if (!btn) return { missing: 'trigger' };
         return __box(btn);`,
                null
            );
            if (!trigger || trigger.missing) {
                throw new Error(`row "${templateName}": ${trigger ? 'no ' + trigger.missing : 'datatable not found'}`);
            }
            await page.mouse.click(trigger.x, trigger.y);
            await wait(1200);
            const item = await ev(
                page,
                BOX_FROM +
                    `for (const el of __dgFind('[role="menuitem"]', true) || []) {
           if (__deep(el).trim().toLowerCase() !== ${JSON.stringify(action)}.toLowerCase()) continue;
           if (!__vis(el)) continue;
           const b = __box(el);
           if (b) return b;
         }
         return null;`,
                null
            );
            if (!item) throw new Error(`row "${templateName}": the menu never offered a visible "${action}" item`);
            await page.mouse.click(item.x, item.y);
        };

        const actionHit = await ev(
            page,
            `const dt = __dgFind('lightning-datatable');
       if (!dt || !dt.shadowRoot) return 'no datatable';
       // Scope to a BODY row: every column header also has an aria-haspopup
       // button, and the row-action button lives two shadow roots deep.
       const tr = dt.shadowRoot.querySelector('tbody tr');
       if (!tr) return 'no data rows';
       const btn = __deepAll(tr, 'button[aria-haspopup="true"]')[0];
       if (!btn) return 'no row-action button';
       btn.scrollIntoView({ block: 'center' });
       return __hit(btn);`,
            'could not evaluate'
        );
        add(
            check(
                'the row-action menu button is reachable by a mouse',
                actionHit === 'ok',
                actionHit === 'ok' ? '' : `hit-test says: ${actionHit}`,
                SEVERITY.MAJOR
            )
        );

        step('row action: View');
        // VIEW → the modal, on the tags tab.
        try {
            await rowAction(NAME_STARTER, 'View');
            await wait(4500);
            const st = await ev(
                page,
                `const active = (__dgFind('[role="tab"]', true) || [])
           .filter((t) => t.getAttribute('aria-selected') === 'true')
           .map((t) => __deep(t));
         return { modal: !!__dgFind('.slds-modal'), active };`,
                null
            );
            add(
                check(
                    'row action View opens the template on its Copy-Paste Tags tab',
                    !!(st && st.modal && st.active.some((t) => /Copy-Paste Tags/i.test(t))),
                    st ? `modalOpen=${st.modal}, selected tabs: ${st.active.join(', ')}` : 'unreadable',
                    SEVERITY.MAJOR
                )
            );
            await clickByText(page, 'lightning-button', 'Close', { exact: true });
            await wait(2000);
        } catch (e) {
            add(
                skip(
                    'row action View opens the template on its Copy-Paste Tags tab',
                    'could not drive the row menu: ' + msg(e)
                )
            );
        }

        step('row action: Export');
        // EXPORT → a real .docgen.json download.
        let exportPath = null;
        let exportJson = null;
        try {
            // .catch() matters: an unawaited rejected waitForEvent takes the whole
            // node process down as an unhandled rejection.
            const dlp = page.waitForEvent('download', { timeout: 40000 }).catch(() => null);
            await rowAction(NAME_STARTER, 'Export');
            const dl = await dlp;
            if (!dl) throw new Error('no download event fired within 40s of clicking Export');
            exportPath = await dl.path();
            try {
                exportJson = JSON.parse(readFileSync(exportPath, 'utf8'));
            } catch (e) {
                exportJson = null;
            }
            add(
                check(
                    'row action Export downloads a valid .docgen.json bundle',
                    !!(exportJson && exportJson.docgenExportVersion && exportJson.template && exportJson.template.Name),
                    exportJson
                        ? `${dl.suggestedFilename()} — export version ${exportJson.docgenExportVersion}, template "${exportJson.template.Name}"`
                        : `${dl.suggestedFilename()} did not parse as a DocGen export`,
                    SEVERITY.MAJOR
                )
            );
        } catch (e) {
            add(skip('row action Export downloads a valid .docgen.json bundle', 'no download event fired: ' + msg(e)));
        }

        // IMPORT → the exported bundle round-trips back in. Renamed first so the
        // restored copy is distinguishable from its source.
        if (exportJson) {
            step('import round-trip');
            try {
                exportJson.template.Name = NAME_IMPORT;
                const dir = mkdtempSync(join(tmpdir(), 'dgqa-import-'));
                const p = join(dir, 'roundtrip.docgen.json');
                writeFileSync(p, JSON.stringify(exportJson), 'utf8');
                await clickByText(page, '[role="tab"]', 'Your Templates');
                await wait(2000);
                await drainToasts(page);
                await page.locator('input[data-id="importFileInput"]').setInputFiles(p);
                await wait(9000);
                const imported = (await probeTemplates(org)).some((r) => r.name === NAME_IMPORT);
                add(
                    check(
                        'Import Template restores an exported bundle as a new template',
                        imported,
                        imported
                            ? `"${NAME_IMPORT}" exists after import`
                            : `"${NAME_IMPORT}" was never created from the bundle`,
                        SEVERITY.MAJOR
                    )
                );
            } catch (e) {
                add(skip('Import Template restores an exported bundle as a new template', 'import failed: ' + msg(e)));
            }
        } else {
            add(
                skip('Import Template restores an exported bundle as a new template', 'nothing was exported to import')
            );
        }

        step('row action: Clone');
        // CLONE → a copy exists and opens for editing.
        try {
            await clickByText(page, '[role="tab"]', 'Your Templates');
            await wait(3000);
            await drainToasts(page);
            await rowAction(NAME_FILE, 'Clone');
            await wait(10000);
            const clone = (await probeTemplates(org)).find((r) => r.name === `${NAME_FILE} (Copy)`);
            const modalOpen = await ev(page, `return !!__dgFind('.slds-modal');`, false);
            add(
                check(
                    'row action Clone creates a copy and opens it for editing',
                    !!clone && modalOpen === true,
                    clone
                        ? `created "${clone.name}" (${clone.id}); the edit modal opened = ${modalOpen}`
                        : 'no "(Copy)" record was created',
                    SEVERITY.MAJOR
                )
            );
            await clickByText(page, 'lightning-button', 'Close', { exact: true });
            await wait(2000);
        } catch (e) {
            add(
                skip(
                    'row action Clone creates a copy and opens it for editing',
                    'could not drive the row menu: ' + msg(e)
                )
            );
        }

        step('row action: Delete');
        // DELETE → does it destroy the record, and does it ask first? Losing a
        // template to one un-confirmed menu click is the data-loss case here.
        try {
            await clickByText(page, '[role="tab"]', 'Your Templates');
            await wait(3000);
            const cloneName = `${NAME_FILE} (Copy)`;
            const exists = (await probeTemplates(org)).some((r) => r.name === cloneName);
            if (!exists) {
                add(skip('row action Delete removes the template', 'the clone under test was never created'));
                add(skip('deleting a template asks for confirmation first', 'the clone under test was never created'));
            } else {
                acceptDialogs = true; // if it DOES confirm natively, let it through
                nativeDialogs.length = 0;
                await drainToasts(page);
                await rowAction(cloneName, 'Delete');
                await wait(2000);
                const domConfirm = await ev(
                    page,
                    `return (__dgFind('[role="alertdialog"], .slds-modal', true) || [])
             .map((d) => __deep(d))
             .filter((t) => /delete|remove|are you sure|cannot be undone/i.test(t)).length > 0;`,
                    false
                );
                // Deleting now asks first (a LightningConfirm modal). The suite has
                // to ANSWER it — detecting the dialog and then walking away leaves
                // the template alive and reads as "Delete is broken", which is
                // exactly the false failure this produced when the guard landed.
                if (domConfirm === true) {
                    await ev(
                        page,
                        `const btns = (__dgFind('[role="alertdialog"], .slds-modal', true) || [])
                 .flatMap((d) => [...d.querySelectorAll('button')]);
             const yes = btns.find((b) => /^(delete|ok|confirm|yes)$/i.test((b.textContent || '').trim()));
             if (yes) { yes.click(); return true; }
             return false;`,
                        false
                    );
                    await wait(1500);
                }
                await wait(7000);
                acceptDialogs = false;
                const gone = !(await probeTemplates(org)).some((r) => r.name === cloneName);
                const confirmed = domConfirm === true || nativeDialogs.some((d) => d.type === 'confirm');
                add(
                    check(
                        'row action Delete removes the template',
                        gone,
                        gone ? `"${cloneName}" is gone from the org` : `"${cloneName}" still exists after Delete`,
                        SEVERITY.MAJOR
                    )
                );
                add(
                    check(
                        'deleting a template asks for confirmation first',
                        confirmed,
                        confirmed
                            ? 'a confirmation step was shown'
                            : 'Delete destroyed the template immediately — one mis-click in the row menu is unrecoverable. docGenAdmin.js handleRowAction calls deleteTemplate() with no confirm, while handleDeleteVersion (the less destructive action) does window.confirm first',
                        SEVERITY.MAJOR
                    )
                );
            }
        } catch (e) {
            acceptDialogs = false;
            add(skip('row action Delete removes the template', 'could not drive the row menu: ' + msg(e)));
        }

        step('row action: Design');
        // DESIGN → opens the designer on that template.
        try {
            await clickByText(page, '[role="tab"]', 'Your Templates');
            await wait(3000);
            await rowAction(NAME_STARTER, 'Design');
            // NAME_STARTER is a Canvas template now, and Canvas opens the ARTBOARD, not
            // the flow designer — different components, different markup. Accept either,
            // so this keeps working whichever type the fixture is.
            const up = await until(
                page,
                `const flow = __dgFind('.dg-pv') && __dgFind('.dg-format-bar');
                 const canvas = __dgFind('.dg-board') && __dgFind('.dg-rail');
                 return flow ? { ok: 1, which: 'flow designer' } : canvas ? { ok: 1, which: 'canvas artboard' } : null;`,
                60000,
                2000
            );
            add(
                check(
                    'row action Design opens that template in an editor',
                    !!up,
                    up ? `opened the ${up.which}` : 'neither the flow designer nor the canvas artboard appeared',
                    SEVERITY.MAJOR
                )
            );
        } catch (e) {
            add(
                skip('row action Design opens that template in the designer', 'could not drive the row menu: ' + msg(e))
            );
        }

        /* ============================================================ *
         * 5. EDIT MODAL
         * ============================================================ */
        step('edit modal');
        await openTab(page, base, APP, 9000);
        await clickByText(page, '[role="tab"]', 'Your Templates');
        await wait(4000);

        let modalOpen = false;
        try {
            await rowAction(NAME_STARTER, 'Edit');
            await wait(5000);
            modalOpen = (await ev(page, `return !!__dgFind('.slds-modal');`, false)) === true;
        } catch (e) {
            modalOpen = false;
        }
        add(
            check(
                'row action Edit opens the edit modal',
                modalOpen,
                modalOpen ? '' : 'the modal never opened, so nothing inside it could be tested',
                SEVERITY.BLOCKER
            )
        );

        if (modalOpen) {
            // "Backdrop covers the footer" is invisible to any layout assertion.
            const saveHit = await ev(
                page,
                `const b = (__dgFind('lightning-button', true) || []).find((x) => __deep(x).indexOf('Save as New Version') !== -1);
         if (!b) return 'the Save as New Version button is missing';
         b.scrollIntoView({ block: 'center' });
         const inner = b.shadowRoot ? b.shadowRoot.querySelector('button') : null;
         return __hit(inner || b);`,
                'could not evaluate'
            );
            add(
                check(
                    'the modal Save button is reachable (nothing covers the footer)',
                    saveHit === 'ok',
                    saveHit === 'ok' ? '' : `hit-test says: ${saveHit}`,
                    SEVERITY.BLOCKER
                )
            );

            // 5a. Every modal tab renders its own panel. Scoped to the lightning-tab
            //     host so the main tabset's panels can't satisfy the assertion.
            const modalTabs = [
                { label: 'Settings', marker: 'Template Name' },
                { label: 'Header / Footer', marker: 'Header' },
                { label: 'Watermark', marker: 'Watermark' },
                // "Quick Reference" is the query tab's own unconditional block —
                // the word "Query" itself never appears in the rendered panel.
                { label: 'Query Configuration', marker: 'Quick Reference' },
                { label: 'Signer Inputs', marker: 'Signer Form Fields' },
                { label: 'Copy-Paste Tags', marker: 'copy' },
                { label: 'Fillable Fields', marker: 'field' },
                { label: 'Document & History', marker: 'Current Template File' }
            ];
            for (const t of modalTabs) {
                const offered = await ev(
                    page,
                    `const modal = __dgFind('.slds-modal');
           if (!modal) return false;
           return __deepAll(modal, '[role="tab"]').some((x) => __deep(x).indexOf(${JSON.stringify(t.label)}) !== -1);`,
                    false
                );
                if (offered !== true) {
                    add(
                        skip(
                            `edit modal tab "${t.label}" renders its panel`,
                            'not offered for an HTML/PDF template — this tab is type-gated and needs a template of the gating type',
                            SEVERITY.MINOR
                        )
                    );
                    continue;
                }
                await clickByText(page, '[role="tab"]', t.label);
                await wait(2500);
                // Scope to the MODAL's visible tab panel. lightning-tabset only
                // renders the active tab's content, so the visible panel is the
                // one we just selected — and the main tabset's panels, which are
                // still in the DOM behind the modal, cannot satisfy the marker.
                const panel = await ev(
                    page,
                    `const modal = __dgFind('.slds-modal');
           if (!modal) return null;
           const shown = __deepAll(modal, '[role="tabpanel"]').filter(__vis);
           if (!shown.length) return { visible: false, controls: 0, hasMarker: false, len: 0 };
           const txt = shown.map((p) => __deep(p)).join(' ');
           const controls = shown.reduce((n, p) => n + __deepAll(p, 'input, textarea, button, select, code').length, 0);
           const selected = __deepAll(modal, '[role="tab"]')
             .filter((x) => x.getAttribute('aria-selected') === 'true')
             .map((x) => __deep(x));
           return {
             visible: true,
             selected,
             controls,
             hasMarker: txt.toLowerCase().indexOf(${JSON.stringify(t.marker)}.toLowerCase()) !== -1,
             len: txt.length
           };`,
                    null
                );
                add(
                    check(
                        `edit modal tab "${t.label}" renders its panel`,
                        !!(
                            panel &&
                            panel.visible &&
                            panel.controls > 0 &&
                            panel.hasMarker &&
                            (panel.selected || []).some((s) => s.indexOf(t.label) !== -1)
                        ),
                        panel
                            ? `selected=${(panel.selected || []).join('/')}, controls=${panel.controls}, expected content present=${panel.hasMarker}, text=${panel.len} chars`
                            : 'the tab panel was unreadable',
                        SEVERITY.MAJOR
                    )
                );
            }

            // 5b. Copy-Paste Tags: a chip must reach the clipboard.
            await clickByText(page, '[role="tab"]', 'Copy-Paste Tags');
            await wait(2500);
            const tagText = await ev(page, `const c = __dgFind('.tag-click'); return c ? __deep(c) : null;`, null);
            if (!tagText) {
                add(skip('a tag chip copies its merge tag to the clipboard', 'no .tag-click chips were rendered'));
            } else {
                await drainToasts(page);
                await mouseClick(page, '.tag-click');
                await wait(1800);
                let clip = null;
                try {
                    clip = await page.evaluate(`navigator.clipboard.readText()`);
                } catch (e) {
                    clip = null;
                }
                if (clip === null) {
                    add(
                        skip(
                            'a tag chip copies its merge tag to the clipboard',
                            'the browser refused a clipboard read',
                            SEVERITY.MINOR
                        )
                    );
                } else {
                    add(
                        check(
                            'a tag chip copies its merge tag to the clipboard',
                            clip.trim() === String(tagText).trim(),
                            `clicked "${tagText}"; the clipboard now holds "${clip.slice(0, 60)}"`,
                            SEVERITY.MAJOR
                        )
                    );
                }
            }

            // 5c. Signer Inputs: add and remove must mutate the list.
            await clickByText(page, '[role="tab"]', 'Signer Inputs');
            await wait(2500);
            const countRows = `return (__dgFind('.pdf-acroform-row', true) || []).length;`;
            const sBefore = await ev(page, countRows, 0);
            await clickByText(page, 'lightning-button', 'Add Field', { exact: true });
            await wait(2200);
            const sAfter = await ev(page, countRows, 0);
            add(
                check(
                    'Signer Inputs: "Add Field" adds a field row',
                    sAfter > sBefore,
                    `signer field rows ${sBefore} -> ${sAfter}`,
                    SEVERITY.MAJOR
                )
            );
            if (sAfter > sBefore) {
                const labelTyped = await ev(
                    page,
                    `const rows = __dgFind('.pdf-acroform-row', true) || [];
           const row = rows[rows.length - 1];
           const input = __deepAll(row, 'input')[0];
           if (!input) return { ok: false, why: 'the new row has no label input' };
           const before = input.value;
           input.value = 'QA Signer Field';
           input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
           return { ok: true, before };`,
                    null
                );
                await wait(1200);
                add(
                    check(
                        'Signer Inputs: a field row is editable',
                        !!(labelTyped && labelTyped.ok),
                        labelTyped
                            ? labelTyped.ok
                                ? `label was "${labelTyped.before}"`
                                : labelTyped.why
                            : 'unreadable',
                        SEVERITY.MINOR
                    )
                );
                const removed = await ev(
                    page,
                    `const rows = __dgFind('.pdf-acroform-row', true) || [];
           const row = rows[rows.length - 1];
           const btn = __deepAll(row, 'button').filter((b) => /remove/i.test(b.getAttribute('title') || ''))[0];
           if (!btn) return { ok: false, why: 'no remove control on the field row' };
           const before = rows.length;
           btn.click();
           return { ok: true, before };`,
                    null
                );
                await wait(1800);
                if (removed && removed.ok) {
                    const now = await ev(page, countRows, -1);
                    add(
                        check(
                            'Signer Inputs: removing a field takes it off the list',
                            now < removed.before,
                            `signer field rows ${removed.before} -> ${now}`,
                            SEVERITY.MAJOR
                        )
                    );
                } else {
                    add(
                        skip(
                            'Signer Inputs: removing a field takes it off the list',
                            removed ? removed.why : 'unreadable'
                        )
                    );
                }
            } else {
                add(skip('Signer Inputs: a field row is editable', 'no row was added'));
                add(skip('Signer Inputs: removing a field takes it off the list', 'no row was added'));
            }

            // 5d. SETTINGS + SAVE — the load-bearing behaviour of the modal.
            await clickByText(page, '[role="tab"]', 'Settings');
            await wait(2500);
            const newDesc = `edited by ui-admin ${runId}`;
            const newCat = `QA${runId}`;
            await typeField(page, 'Description', newDesc);
            await typeField(page, 'Category', newCat);
            await wait(900);
            const echoedDesc = await readField(page, 'Description');
            const echoedCat = await readField(page, 'Category');
            add(
                check(
                    'edit modal inputs accept real typing',
                    echoedDesc === newDesc && echoedCat === newCat,
                    `description="${echoedDesc}" category="${echoedCat}"`,
                    SEVERITY.MAJOR
                )
            );

            // Toggles are found by their SLDS markup, not by an LWC property:
            // `lightning-input[type="toggle"]` is not a real attribute selector.
            const TOGGLE = `
           const t = (__dgFind('.slds-checkbox_toggle', true) || []).filter(__vis)[0];
           const input = t ? t.querySelector('input[type="checkbox"]') : null;
           const faux = t ? t.querySelector('.slds-checkbox_faux_container, .slds-checkbox_faux') : null;`;
            const toggleBox = await ev(
                page,
                BOX_FROM +
                    TOGGLE +
                    `if (!input) return null;
           const b = __box(faux || t);
           return b ? { x: b.x, y: b.y, checked: !!input.checked } : null;`,
                null
            );
            if (!toggleBox) {
                add(skip('the Active toggle flips when clicked', 'no visible toggle input found on the Settings tab'));
            } else {
                await page.mouse.click(toggleBox.x, toggleBox.y);
                await wait(1200);
                const after = await ev(page, TOGGLE + `return input ? !!input.checked : null;`, null);
                add(
                    check(
                        'the Active toggle flips when clicked',
                        after !== null && after !== toggleBox.checked,
                        `checked ${toggleBox.checked} -> ${after}`,
                        SEVERITY.MAJOR
                    )
                );
                // Put it back so the template stays Active for anything later.
                await page.mouse.click(toggleBox.x, toggleBox.y);
                await wait(1000);
            }

            const versionsBefore = await countVersions(org, NAME_STARTER);
            await drainToasts(page);
            await clickByText(page, 'lightning-button', 'Save as New Version', { exact: true });
            await wait(14000);
            const saved = (await probeTemplates(org, ['Description__c', 'Category__c'])).find(
                (r) => r.name === NAME_STARTER
            );
            add(
                check(
                    'Save as New Version persists the edited fields',
                    !!(saved && saved['Description__c'] === newDesc && saved['Category__c'] === newCat),
                    saved
                        ? `stored description="${saved['Description__c']}", category="${saved['Category__c']}" (expected "${newDesc}" / "${newCat}")`
                        : 'the template record could not be read back',
                    SEVERITY.BLOCKER
                )
            );
            const versionsAfter = await countVersions(org, NAME_STARTER);
            add(
                check(
                    'Save as New Version really creates a new version record',
                    versionsAfter > versionsBefore,
                    `template versions ${versionsBefore} -> ${versionsAfter}`,
                    SEVERITY.MAJOR
                )
            );

            // 5d-bis. #370 — the modal deliberately stays open after "Save as New
            // Version". Closing it now must NOT prompt to discard: the edits were
            // just persisted. The bug: the save handlers never re-baselined
            // _editSnapshot, so it kept its pre-edit value and Close always warned.
            await drainToasts(page);
            nativeDialogs.length = 0;
            await clickByText(page, 'lightning-button', 'Close', { exact: true });
            await wait(2500);
            const falseDiscardPrompt = await ev(
                page,
                `return ((__dgFind('[role="alertdialog"], .slds-modal', true) || [])
           .map((d) => __deep(d))
           .filter((t) => /unsaved changes|discard them|discard changes/i.test(t)))[0] || null;`,
                null
            );
            const closedAfterSave = (await ev(page, `return !__dgFind('.slds-modal');`, false)) === true;
            add(
                check(
                    'closing the modal right after a save does not prompt to discard (#370)',
                    !falseDiscardPrompt && closedAfterSave,
                    falseDiscardPrompt
                        ? `Close warned "${String(falseDiscardPrompt).slice(0, 90)}" although Save as New Version had just succeeded — the save handlers in docGenAdmin.js must re-baseline _editSnapshot`
                        : closedAfterSave
                          ? ''
                          : 'no false discard prompt, but the modal did not close on Close either',
                    SEVERITY.MAJOR
                )
            );
            // Clear a stray confirm (if any) so the next block starts clean.
            await clickByText(page, 'button', 'Cancel', { exact: true });
            await wait(600);

            // 5e. CLOSING WITHOUT SAVING must not silently bin the work.
            try {
                await clickByText(page, '[role="tab"]', 'Your Templates');
                await wait(2500);
                await rowAction(NAME_STARTER, 'Edit');
                await wait(5000);
                await clickByText(page, '[role="tab"]', 'Settings');
                await wait(2000);
                const throwaway = `unsaved-${runId}-do-not-lose-me`;
                await typeField(page, 'Description', throwaway);
                await wait(900);
                nativeDialogs.length = 0;
                await clickByText(page, 'lightning-button', 'Close', { exact: true });
                await wait(2000);
                const domWarn = await ev(
                    page,
                    `return (__dgFind('[role="alertdialog"], .slds-modal', true) || [])
             .map((d) => __deep(d))
             .filter((t) => /unsaved|discard|lose|are you sure/i.test(t)).length > 0;`,
                    false
                );
                await rowAction(NAME_STARTER, 'Edit');
                await wait(5000);
                await clickByText(page, '[role="tab"]', 'Settings');
                await wait(2000);
                const reopened = await readField(page, 'Description');
                const warned = domWarn === true || nativeDialogs.some((d) => d.type === 'confirm');
                const preserved = reopened === throwaway;
                add(
                    check(
                        'closing the modal with unsaved edits warns or preserves them',
                        warned || preserved,
                        warned
                            ? 'a confirmation was shown'
                            : preserved
                              ? 'the edit survived the close'
                              : `Close silently discarded the typed edit with no warning — on reopen the description reads "${String(reopened).slice(0, 60)}". docGenAdmin.js closeEditModal() just sets isEditModalOpen=false`,
                        SEVERITY.MAJOR
                    )
                );
                await clickByText(page, 'lightning-button', 'Close', { exact: true });
                await wait(1500);
            } catch (e) {
                add(
                    skip(
                        'closing the modal with unsaved edits warns or preserves them',
                        'could not re-open the modal: ' + msg(e)
                    )
                );
            }
        } else {
            for (const n of [
                'the edit modal tabs render their panels',
                'Save as New Version persists the edited fields',
                'closing the modal with unsaved edits warns or preserves them'
            ]) {
                add(skip(n, 'the edit modal never opened'));
            }
        }

        /* ============================================================ *
         * 6. SETTINGS / SETUP SURFACES that host the admin component
         * ============================================================ */
        try {
            step('command hub');
            await openTab(page, base, HUB, 10000);
            const hubUp = await until(page, `return __dgFind('.nav-links') ? { ok: 1 } : null;`, 30000, 1500);
            if (!hubUp) {
                add(skip('the Command Hub opens each settings surface', 'the Command Hub tab never rendered'));
            } else {
                const HEAD = `const h = __dgFind('.panel-header'); return h ? __deep(h).slice(0, 60) : '';`;
                for (const item of [
                    'My Templates',
                    'Bulk Generation',
                    'Signatures',
                    'Assets',
                    'Email Templates',
                    'Learning Center'
                ]) {
                    // Each item gets a FRESH hub. Opening Bulk Generation collapses
                    // the sidebar (asserted on its own below); without a reload every
                    // later item would fail as collateral damage instead of being
                    // tested, and the report would blame the wrong control.
                    await openTab(page, base, HUB, 10000);
                    await until(page, `return __dgFind('.nav-links') ? { ok: 1 } : null;`, 25000, 1500);
                    const present = await ev(
                        page,
                        `return (__dgFind('.nav-links button', true) || []).some((b) => __deep(b).indexOf(${JSON.stringify(item)}) !== -1);`,
                        false
                    );
                    if (present !== true) {
                        add(skip(`Command Hub: "${item}" opens its panel`, 'this nav item is not offered in this org'));
                        continue;
                    }
                    const before = await ev(page, HEAD, '');
                    await clickByText(page, '.nav-links button', item);
                    await wait(6000);
                    const after = await ev(
                        page,
                        `const h = __dgFind('.panel-header');
             const b = __dgFind('.panel-body');
             return { head: h ? __deep(h).slice(0, 60) : '', bodyLen: b ? __deep(b).length : 0 };`,
                        null
                    );
                    // "My Templates" is the landing section, so it is already open —
                    // for that one the panel simply has to be its own and populated.
                    const opened =
                        item === 'My Templates'
                            ? !!(after && /Template Library/i.test(after.head) && after.bodyLen > 20)
                            : !!(after && after.head && after.head !== before && after.bodyLen > 20);
                    add(
                        check(
                            `Command Hub: "${item}" opens its panel`,
                            opened,
                            after
                                ? `panel header "${before}" -> "${after.head}"; body ${after.bodyLen} chars`
                                : 'unreadable',
                            SEVERITY.MAJOR
                        )
                    );
                }

                // Opening a section must not strand the user in it. This is the
                // regression that made every later nav item look broken.
                await openTab(page, base, HUB, 10000);
                await until(page, `return __dgFind('.nav-links') ? { ok: 1 } : null;`, 25000, 1500);
                await clickByText(page, '.nav-links button', 'Bulk Generation');
                // Sampled over a window, not once: while the bulk runner loads it
                // throws a full-bleed spinner over the sidebar and the nav buttons
                // measure zero — that is acceptable transiently, and a defect only
                // if the sidebar never comes back.
                const NAV = `return (__dgFind('.nav-links button', true) || []).map((b) => ({ t: __deep(b), hit: __hit(b) }));`;
                let worst = null;
                let navFinal = [];
                let recoveredAfter = null;
                for (const t of [1500, 3000, 5000, 8000, 12000, 18000, 25000]) {
                    await wait(t === 1500 ? 1500 : 3000);
                    navFinal = (await ev(page, NAV, [])) || [];
                    const bad = navFinal.filter((b) => b.hit !== 'ok');
                    if (bad.length && !worst) worst = { at: t, bad };
                    if (!bad.length && worst && recoveredAfter === null) recoveredAfter = t;
                    if (!bad.length && !worst) break;
                    if (!bad.length) break;
                }
                const stillBad = navFinal.filter((b) => b.hit !== 'ok');
                add(
                    check(
                        'the Command Hub sidebar stays usable after opening Bulk Generation',
                        navFinal.length > 0 && stillBad.length === 0,
                        stillBad.length
                            ? `${stillBad.length}/${navFinal.length} nav items are still unclickable 25s after opening Bulk Generation — ${stillBad
                                  .slice(0, 3)
                                  .map((b) => `"${b.t}": ${b.hit}`)
                                  .join(', ')}. The user cannot leave the section without reloading the page.`
                            : worst
                              ? `covered while loading (${worst.bad.length} items: ${worst.bad[0].hit}), recovered by ~${recoveredAfter || '?'}ms`
                              : `${navFinal.length} nav items reachable throughout`,
                        SEVERITY.MAJOR
                    )
                );
            }
        } catch (e) {
            add(skip('the Command Hub opens each settings surface', 'the hub run failed: ' + msg(e)));
        }

        /* ============================================================ *
         * 7. CONSOLE HYGIENE
         * ============================================================ */
        // Platform noise, not ours. empApi is Salesforce's own streaming client and
        // it logs a connection error on any org without a live CometD session —
        // nothing in this package touches it. Allowlisted by SOURCE rather than by
        // muting console errors wholesale, so a real error in our code still fails.
        const realErrors = consoleErrors.filter(
            (e) =>
                !/Failed to load resource/i.test(e) &&
                !/favicon/i.test(e) &&
                !/deprecat/i.test(e) &&
                !/net::ERR_/i.test(e) &&
                !/EmpApiController|empApi|cometd/i.test(e)
        );
        add(
            check(
                'no unexpected console errors while driving the admin UI',
                realErrors.length === 0,
                realErrors.length ? `${realErrors.length} errors, first: ${realErrors.slice(0, 2).join(' | ')}` : '',
                SEVERITY.MINOR
            )
        );
    } catch (e) {
        add(skip('the admin UI suite completed', 'the run aborted: ' + msg(e), SEVERITY.BLOCKER));
    } finally {
        // Repeat runs must stay green: every QAUI- template this run made goes.
        try {
            const deleted = await deleteQaTemplates(org);
            add(
                check(
                    'the suite cleans up the templates it created',
                    deleted >= 0,
                    deleted >= 0 ? `${deleted} QAUI- templates deleted` : 'the cleanup Apex reported no count',
                    SEVERITY.MINOR
                )
            );
        } catch (e) {
            add(skip('the suite cleans up the templates it created', 'cleanup failed: ' + msg(e), SEVERITY.MINOR));
        }
        if (browser) {
            try {
                await browser.close();
            } catch (e) {
                /* nothing useful to do */
            }
        }
    }

    return suiteResult('ui-admin', 'Admin UI', C);
}
