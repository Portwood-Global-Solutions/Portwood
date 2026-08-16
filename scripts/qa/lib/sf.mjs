/**
 * Salesforce CLI helpers.
 *
 * Every suite that talks to an org goes through here, so retry/timeout/parsing
 * behaviour is decided once. The CLI is chatty and occasionally flaky (the
 * ETIMEDOUT on a Soap endpoint is real and transient), so reads retry.
 */
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const exec = promisify(execFile);

const BIG = 64 * 1024 * 1024; // Apex debug logs are large; never truncate them.

async function sf(args, { timeout = 900000, retries = 1 } = {}) {
    let lastErr;
    for (let attempt = 0; attempt <= retries; attempt++) {
        try {
            const { stdout } = await exec('sf', args, { maxBuffer: BIG, timeout });
            return stdout;
        } catch (e) {
            lastErr = e;
            // stdout is still useful on a non-zero exit — apex run returns non-zero
            // when the script itself printed a failure, which is a RESULT not an error.
            if (e.stdout && e.stdout.length) return e.stdout;
            if (attempt < retries) await new Promise((r) => setTimeout(r, 3000));
        }
    }
    throw lastErr;
}

export async function orgFrontDoorUrl(org) {
    const raw = await sf(['org', 'open', '--target-org', org, '--url-only', '--json'], { retries: 2 });
    return JSON.parse(raw).result.url;
}

/**
 * The package namespace prefix to put in front of a tab or field API name in THIS
 * org — `portwoodglobal__`, or '' for a source-deployed one.
 *
 * Hardcoding the prefix makes a suite navigate to "Page doesn't exist" in every org
 * scripts/qa/setup-org.sh produces, since that script creates the org --no-namespace
 * so the e2e Apex compiles. ui-smoke.mjs learned this and resolves the prefix; the
 * ui-* suites did not, so they failed on their first mount check against the standard
 * QA org and every check behind it went unrun — a regression guard that cannot run is
 * indistinguishable from one that passes.
 *
 * Three shapes, and the org's own namespace does not distinguish them:
 *   source-deployed, no namespace     -> ''
 *   namespaced scratch org            -> portwoodglobal__
 *   SUBSCRIBER org, package INSTALLED -> portwoodglobal__
 * The install case reports namespace: null from `org display`, because a subscriber
 * org receives the namespace rather than owning it — so ask which packages are
 * installed too, or the install case comes out exactly backwards.
 */
export async function nsPrefix(org) {
    const json = async (argv) => {
        try {
            return JSON.parse(await sf(argv, { retries: 0 })).result;
        } catch {
            return null;
        }
    };
    const own = ((await json(['org', 'display', '--target-org', org, '--json'])) || {}).namespace || null;
    if (own) {
        return `${own}__`;
    }
    const installed = (await json(['package', 'installed', 'list', '--target-org', org, '--json'])) || [];
    const pkg = (Array.isArray(installed) ? installed : []).find(
        (p) => String(p.SubscriberPackageNamespace || '').length > 0
    );
    return pkg ? `${pkg.SubscriberPackageNamespace}__` : '';
}

/** Run a block of anonymous Apex; returns the raw log. */
export async function runAnonymous(org, apexSource, opts = {}) {
    const dir = mkdtempSync(join(tmpdir(), 'dgqa-'));
    const file = join(dir, 'run.apex');
    writeFileSync(file, apexSource, 'utf8');
    return sf(['apex', 'run', '--target-org', org, '-f', file], opts);
}

/** Run an anonymous Apex FILE that already exists (the scripts/e2e-*.apex set). */
export async function runAnonymousFile(org, path, opts = {}) {
    return sf(['apex', 'run', '--target-org', org, '-f', path], opts);
}

/**
 * Pull DEBUG lines a script emitted. Anonymous Apex has no return channel, so
 * every suite that needs data out of an org prints `KEY=value` and reads it here.
 */
export function debugLines(log) {
    const out = [];
    for (const line of String(log || '').split('\n')) {
        const m = /\|USER_DEBUG\|\[\d+\]\|[A-Z]+\|([\s\S]*)$/.exec(line);
        if (m) out.push(m[1]);
    }
    return out;
}

/** Values printed as `KEY=value` by an anonymous Apex probe. */
export function debugMap(log) {
    const map = {};
    for (const line of debugLines(log)) {
        const m = /^([A-Z0-9_]+)=([\s\S]*)$/.exec(line.trim());
        if (m) map[m[1]] = m[2];
    }
    return map;
}

export async function soql(org, query, { tooling = false } = {}) {
    const args = ['data', 'query', '--target-org', org, '-q', query, '--json'];
    if (tooling) {
        args.push('--use-tooling-api');
    }
    const raw = await sf(args, { retries: 2 });
    try {
        return JSON.parse(raw).result.records || [];
    } catch (e) {
        return [];
    }
}

/**
 * Run Apex tests. Pass classNames to scope the run, or nothing for RunLocalTests.
 *
 * RunLocalTests is the default because enumerating every test class as a
 * --class-names flag builds a command line the CLI rejects outright — 43 flags
 * was enough — and it is what the release checklist runs anyway.
 */
export async function runApexTests(org, classNames, { timeout = 3600000, coverage = false } = {}) {
    // human, not json, when coverage is on: the JSON payload for a full
    // RunLocalTests WITH --code-coverage is big enough to exhaust the CLI's own
    // node heap ("Last few GCs ... JavaScript heap out of memory"). The numbers
    // are read back from the Tooling API instead — see apexCoverage().
    const format = coverage ? 'human' : 'json';
    const args = ['apex', 'run', 'test', '--target-org', org, '--wait', '60', '--result-format', format];
    if (coverage) {
        args.push('--code-coverage');
    }
    if (classNames && classNames.length && classNames.length <= 20) {
        for (const c of classNames) args.push('--class-names', c);
    } else {
        args.push('--test-level', 'RunLocalTests');
    }
    const raw = await sf(args, { timeout });
    if (format === 'human') {
        return { summary: null, tests: [], coverage: [], human: raw };
    }
    const jsonStart = raw.indexOf('{');
    if (jsonStart === -1) return { summary: null, tests: [] };
    try {
        const parsed = JSON.parse(raw.slice(jsonStart));
        const r = parsed.result || parsed;
        return {
            summary: r.summary || null,
            tests: r.tests || [],
            // Real per-class coverage beats guessing from test-class NAMES, which
            // reports a class covered by a shared test file (DocGenMiscTests) as
            // untested. See apex-unit.mjs.
            coverage: r.coverage && r.coverage.coverage ? r.coverage.coverage : []
        };
    } catch (e) {
        return { summary: null, tests: [], raw };
    }
}

export { sf };

/**
 * Per-class coverage, read from the Tooling API after a run.
 *
 * ApexCodeCoverageAggregate is populated by any test run that collected
 * coverage, and the payload is a few hundred rows rather than the megabytes the
 * CLI's own --code-coverage JSON produces.
 */
export async function apexCoverage(org) {
    const rows = await soql(
        org,
        'SELECT ApexClassOrTrigger.Name, NumLinesCovered, NumLinesUncovered FROM ApexCodeCoverageAggregate',
        { tooling: true }
    );
    return rows
        .map((r) => {
            const total = (r.NumLinesCovered || 0) + (r.NumLinesUncovered || 0);
            return {
                name: r.ApexClassOrTrigger ? r.ApexClassOrTrigger.Name : null,
                covered: r.NumLinesCovered || 0,
                total,
                percent: total ? Math.round((r.NumLinesCovered / total) * 100) : null
            };
        })
        .filter((r) => r.name);
}

/** Outcome + per-class failures from a human-format test run. */
export function parseHumanTestRun(text) {
    const out = { outcome: null, ran: null, passRate: null, failures: [] };
    const m = /Outcome\s+(\w+)/.exec(text || '');
    if (m) out.outcome = m[1];
    const r = /Tests Ran\s+(\d+)/.exec(text || '');
    if (r) out.ran = Number(r[1]);
    const p = /Pass Rate\s+([\d.]+)%/.exec(text || '');
    if (p) out.passRate = Number(p[1]);
    for (const line of String(text || '').split('\n')) {
        const f = /^\s*(\S+\.\S+)\s+Fail\s+(.*)$/.exec(line);
        if (f) out.failures.push({ test: f[1], message: f[2].trim().slice(0, 200) });
    }
    return out;
}
