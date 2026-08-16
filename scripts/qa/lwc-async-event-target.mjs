// LWC async-handler audit — no event handler may read its event after an await.
//
// Pure Node, no org needed:  node scripts/qa/lwc-async-event-target.mjs
//
// WHY THIS EXISTS
// ---------------
// An event object is only dependable for the SYNCHRONOUS part of a handler. Once the
// handler awaits, the framework has already returned from the dispatch, and reading
// `event.target` back can yield null — the write is simply lost. No error, no warning.
//
// That is how #309 shipped. A file input's `change` handler reset `event.target.value`
// in a `finally` that ran after two awaits, so the reset never landed. An input that
// keeps its old value fires NO change event when the author picks the SAME path again,
// which made re-uploading an edited template under its original name a silent no-op —
// the save then reused the PREVIOUS body while the panel said "Ready to Save". Renaming
// the file worked first time, which is what made it look like anything but a bug.
//
// Three handlers in docGenAdmin had the shape; one of them was the reported one. The
// fix is to bind the element to a const BEFORE the first await and use that. This audit
// keeps the pattern from coming back — it deploys clean and lints clean either way, so
// nothing else catches it.
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// fileURLToPath, not URL.pathname — a checkout under a path with a space in it
// percent-encodes and then fails to resolve.
const HERE = dirname(fileURLToPath(import.meta.url));
const LWC_DIR = join(HERE, '..', '..', 'force-app', 'main', 'default', 'lwc');

/**
 * Splits a class body into its methods by brace depth, returning the ones declared
 * `async`. Deliberately shallow: this audits a coding pattern, it does not need a
 * parser, and a missed exotic declaration is a false negative rather than noise.
 */
function asyncMethods(lines) {
    const out = [];
    for (let i = 0; i < lines.length; i++) {
        const m = /^(\s*)async\s+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)\s*\{/.exec(lines[i]);
        if (!m) {
            continue;
        }
        const [, indent, name, params] = m;
        const param = (params.split(',')[0] || '').trim();
        if (!param || !/^[A-Za-z_$][\w$]*$/.test(param)) {
            continue;
        }
        // Close on the first line that returns to the declaration's indent with a `}`.
        let end = lines.length - 1;
        for (let j = i + 1; j < lines.length; j++) {
            if (lines[j] === indent + '}') {
                end = j;
                break;
            }
        }
        out.push({ name, param, start: i, end });
    }
    return out;
}

/**
 * Blanks out comments so prose about awaits doesn't read as code. Line-accurate:
 * every line stays in place so reported numbers match the file.
 */
function stripComments(lines) {
    let inBlock = false;
    return lines.map((raw) => {
        let line = raw;
        if (inBlock) {
            const close = line.indexOf('*/');
            if (close === -1) {
                return '';
            }
            line = ' '.repeat(close + 2) + line.slice(close + 2);
            inBlock = false;
        }
        const open = line.indexOf('/*');
        if (open !== -1 && line.indexOf('*/', open) === -1) {
            inBlock = true;
            line = line.slice(0, open);
        }
        const slash = line.indexOf('//');
        return slash === -1 ? line : line.slice(0, slash);
    });
}

function auditFile(file) {
    const raw = readFileSync(file, 'utf8').split('\n');
    const lines = stripComments(raw);
    const findings = [];
    for (const method of asyncMethods(lines)) {
        // The read is only unsafe once the awaited STATEMENT has finished. Arguments to
        // the awaited call — `await f(event.currentTarget.dataset)` wrapped across
        // lines — are evaluated before the suspension, so they are perfectly safe and
        // must not be flagged. Walk to the end of the await's statement by paren depth.
        let boundary = -1;
        for (let i = method.start + 1; i <= method.end && boundary === -1; i++) {
            if (!/\bawait\s/.test(lines[i])) {
                continue;
            }
            let depth = 0;
            for (let j = i; j <= method.end; j++) {
                for (const ch of lines[j]) {
                    if (ch === '(' || ch === '[') {
                        depth++;
                    } else if (ch === ')' || ch === ']') {
                        depth--;
                    }
                }
                if (depth <= 0) {
                    boundary = j;
                    break;
                }
            }
            if (boundary === -1) {
                boundary = method.end;
            }
        }
        if (boundary === -1) {
            continue;
        }
        const re = new RegExp('\\b' + method.param + '\\.(currentTarget|target)\\b');
        for (let i = boundary + 1; i <= method.end; i++) {
            if (re.test(lines[i])) {
                findings.push({
                    method: method.name,
                    line: i + 1,
                    awaitLine: boundary + 1,
                    text: raw[i].trim()
                });
            }
        }
    }
    return findings;
}

function jsFilesUnder(dir) {
    const out = [];
    if (!existsSync(dir)) {
        return out;
    }
    for (const entry of readdirSync(dir)) {
        const full = join(dir, entry);
        if (statSync(full).isDirectory()) {
            out.push(...jsFilesUnder(full));
        } else if (entry.endsWith('.js')) {
            out.push(full);
        }
    }
    return out;
}

let total = 0;
for (const file of jsFilesUnder(LWC_DIR).sort()) {
    const findings = auditFile(file);
    if (!findings.length) {
        continue;
    }
    const rel = file.slice(LWC_DIR.length + 1);
    for (const f of findings) {
        total++;
        process.stdout.write(
            `  FAIL  ${rel}:${f.line}  ${f.method}() reads ${f.text} after the await on line ${f.awaitLine}\n`
        );
    }
}

if (total === 0) {
    process.stdout.write('  PASS  no async handler reads its event after an await\n');
    process.exit(0);
}
process.stdout.write(
    `\n${total} post-await event read(s). Bind the element to a const before the first await ` +
        `and use that — see _clearFileInput in docGenAdmin (#309).\n`
);
process.exit(1);
