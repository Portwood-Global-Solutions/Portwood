// Local QA transport using the installed Salesforce CLI SDK. Auth stays in memory.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';
// Resolve the already-installed CLI instead of pinning one developer's Homebrew version.
const executable = realpathSync(
    execFileSync(process.platform === 'win32' ? 'where' : 'which', ['sf'], { encoding: 'utf8' })
        .trim()
        .split(/\r?\n/)[0]
);
let directory = path.dirname(executable);
let cliPackage = process.env.SF_CLI_PACKAGE_JSON;
for (let level = 0; !cliPackage && level < 6; level++) {
    cliPackage = [
        path.join(directory, 'lib/node_modules/@salesforce/cli/package.json'),
        path.join(directory, 'node_modules/@salesforce/cli/package.json')
    ].find(existsSync);
    directory = path.dirname(directory);
}
if (!cliPackage)
    throw Error('Could not locate the installed Salesforce CLI. Set SF_CLI_PACKAGE_JSON to its package.json.');
const expectedOrg = process.argv[3] || process.env.PORTWOOD_QA_ORG_ID;
if (!expectedOrg) throw Error('Set PORTWOOD_QA_ORG_ID to the explicitly authorized development org Id.');
const require = createRequire(cliPackage);
const { Org } = require('@salesforce/core');
const { ExecuteService } = require('@salesforce/apex-node');
const org = await Org.create({ aliasOrUsername: process.argv[2] });
if (org.getOrgId().slice(0, 15) !== expectedOrg.slice(0, 15)) throw Error('Development-org scope check failed.');
const connection = org.getConnection('67.0');
const scope = await connection.query('SELECT IsSandbox FROM Organization LIMIT 1');
if (!scope.records[0]?.IsSandbox) throw Error('Font stress tools require a development org.');
const execute = new ExecuteService(connection);
for await (const line of createInterface({ input: process.stdin, crlfDelay: Infinity })) {
    try {
        const input = JSON.parse(line);
        let result;
        if (input.op === 'apex') {
            result = await execute.executeAnonymous({ apexCode: input.source });
        } else {
            const response = await fetch(connection.instanceUrl + input.path, {
                method: input.method || 'GET',
                headers: {
                    Authorization: 'Bearer ' + connection.getConnectionOptions().accessToken,
                    'Content-Type': 'application/json'
                },
                body: input.body === undefined ? undefined : JSON.stringify(input.body)
            });
            if (!response.ok) throw Error('Salesforce HTTP ' + response.status + ': ' + (await response.text()));
            result =
                input.op === 'download'
                    ? { base64: Buffer.from(await response.arrayBuffer()).toString('base64') }
                    : response.status === 204
                      ? null
                      : await response.json();
        }
        process.stdout.write(JSON.stringify({ ok: true, result }) + '\n');
    } catch (error) {
        process.stdout.write(JSON.stringify({ ok: false, error: error.message }) + '\n');
    }
}
