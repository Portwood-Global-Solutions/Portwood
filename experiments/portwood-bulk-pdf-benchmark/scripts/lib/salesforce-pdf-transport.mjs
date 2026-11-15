import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { request } from 'node:https';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { Transform } from 'node:stream';

const versionIdPattern = /^068[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/;
const restPath = '/services/data/v68.0/sobjects/ContentVersion';

export async function salesforceConnection(aliasOrUsername, agentOptions) {
  // Use the same authenticated connection as sf api request; no credential enters the browser.
  const executable = realpathSync(execFileSync('which', ['sf'], { encoding: 'utf8' }).trim());
  const require = createRequire(resolve(executable, '..', '..', 'package.json'));
  const { Org } = require('@salesforce/core');
  const { ProxyAgent } = require('proxy-agent');
  const org = await Org.create({ aliasOrUsername });
  await org.refreshAuth();
  const { instanceUrl, accessToken } = org.getConnection().getConnectionOptions();
  const origin = new URL(instanceUrl);
  assert.equal(origin.protocol, 'https:');
  assert.ok(accessToken);
  return { origin, accessToken, agent: new ProxyAgent(agentOptions) };
}

export function streamAudit(expectedBytes, algorithm, expectedDigest) {
  const hash = createHash(algorithm);
  let total = 0;
  let largest = 0;
  let digest;
  const stream = new Transform({
    transform(bytes, _, next) {
      total += bytes.length;
      largest = Math.max(largest, bytes.length);
      if (total > expectedBytes) {
        next(new Error('Response exceeded its expected byte count.'));
        return;
      }
      hash.update(bytes);
      next(null, bytes);
    },
    flush(next) {
      if (total !== expectedBytes) {
        next(new Error('Stream ended before its expected byte count.'));
        return;
      }
      digest = hash.digest('hex');
      next(expectedDigest && digest !== expectedDigest ? new Error('Chunk checksum mismatch.') : null);
    },
  });
  return { stream, result: () => ({ sha: digest, bytes: total, largest }) };
}

function send(connection, path, options, onResponse) {
  return request(new URL(path, connection.origin), {
    ...options,
    agent: connection.agent,
    headers: {
      ...options.headers,
      authorization: `Bearer ${connection.accessToken}`,
      'accept-encoding': 'identity',
    },
  }, onResponse);
}

export async function downloadPart(connection, id, signal) {
  assert.match(id, versionIdPattern);
  const source = await new Promise((resolve, reject) => {
    const req = send(connection, `${restPath}/${id}/VersionData`, { signal }, resolve);
    req.on('error', reject);
    req.end();
  });
  if (source.statusCode !== 200) {
    source.resume();
    throw new Error(`Salesforce chunk download returned HTTP ${source.statusCode}.`);
  }
  return source;
}
