"""Read an authorized Salesforce scratch session without logging credentials."""

import json
import subprocess
from urllib.parse import urlsplit


def cli_result(*command):
    result = subprocess.run(['sf', *command, '--json'], capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError('Salesforce CLI could not read the authorized scratch session.')
    try:
        return json.loads(result.stdout)['result']
    except (ValueError, KeyError, TypeError):
        raise RuntimeError('Salesforce CLI did not return scratch session metadata.') from None


def org_auth(alias):
    details = cli_result('org', 'display', '--target-org', alias)
    base = details.get('instanceUrl', '')
    instance = urlsplit(base)
    if (instance.scheme != 'https' or not instance.hostname or instance.username or instance.password
            or not instance.hostname.endswith('.scratch.my.salesforce.com')):
        raise ValueError('Choose an authorized Salesforce scratch org.')
    token = details.get('accessToken')
    if not token or token.startswith('['):
        token = cli_result('org', 'auth', 'show-access-token', '--target-org', alias).get('accessToken')
    if not token or token.startswith('['):
        raise RuntimeError('Authorize the scratch org in the Salesforce CLI and retry.')
    return base.rstrip('/'), token
