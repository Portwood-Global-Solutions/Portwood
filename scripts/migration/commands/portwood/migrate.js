import { Command, Flags } from '@oclif/core';
import { migrate } from '../../migrate.mjs';

export default class PortwoodMigrate extends Command {
    static description = 'Plan or apply a cross-org Portwood configuration migration.';
    static flags = {
        'source-org': Flags.string({ required: true, description: 'Authenticated source Salesforce org alias' }),
        'target-org': Flags.string({ required: true, description: 'Authenticated target Salesforce org alias' }),
        'dry-run': Flags.boolean({ description: 'Plan without creating any records' }),
        mappings: Flags.string({ description: 'Path to target-org mappings JSON' }),
        only: Flags.string({
            multiple: true,
            options: ['templates', 'snippets', 'assets', 'brands', 'emailTemplates', 'settings', 'fonts'],
            description: 'Restrict apply to the specified configuration kind'
        }),
        conflict: Flags.string({
            options: ['stop', 'skip'],
            default: 'stop',
            description: 'Policy for a different resource with the same key'
        })
    };

    async run() {
        const { flags } = await this.parse(PortwoodMigrate);
        const report = await migrate({
            sourceOrg: flags['source-org'],
            targetOrg: flags['target-org'],
            dryRun: flags['dry-run'],
            mappingsPath: flags.mappings,
            kinds: flags.only,
            conflict: flags.conflict
        });
        this.log(JSON.stringify(report, null, 2));
        if (report.complete === false) this.exit(1);
    }
}
