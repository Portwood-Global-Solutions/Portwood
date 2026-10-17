// Explicit target required. Native review stays in Assets; this never auto-approves fonts.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const args = process.argv.slice(2),
    index = args.indexOf('--target-org');
if (index < 0 || !args[index + 1])
    throw Error(
        'Usage: node scripts/fonts/setup-demo.mjs --target-org SCRATCH_ALIAS [--manifest JSON] [--create-template] [--create-html-template] [--create-designer-template]'
    );
const org = args[index + 1],
    root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const manifestIndex = args.indexOf('--manifest');
if (manifestIndex >= 0 && !args[manifestIndex + 1]) throw Error('--manifest requires a JSON file path.');
const manifestPath =
    manifestIndex >= 0
        ? path.resolve(args[manifestIndex + 1])
        : new URL(
              args.includes('--create-designer-template') ? './designer-manifest.json' : './demo-manifest.json',
              import.meta.url
          );
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const dir = mkdtempSync(path.join(tmpdir(), 'portwood-font-demo-'));
const literal = (s) =>
    "'" + String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\r/g, '\\r').replace(/\n/g, '\\n') + "'";
function apex(source) {
    const file = path.join(dir, 'step.apex');
    writeFileSync(file, source);
    const raw = execFileSync('sf', ['apex', 'run', '--target-org', org, '--file', file, '--json'], {
        cwd: root,
        encoding: 'utf8',
        maxBuffer: 5 * 1024 * 1024,
        stdio: ['ignore', 'pipe', 'pipe']
    });
    const result = JSON.parse(raw);
    if (!result.result?.success) throw Error(result.result?.exceptionMessage || result.message);
    const row = result.result.logs.split('\n').find((l) => l.includes('|DEBUG|FONT_DEMO_RESULT:'));
    return row ? JSON.parse(row.split('FONT_DEMO_RESULT:')[1]) : null;
}
try {
    apex(
        "System.assert([SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox, 'Demo fonts may only be seeded in a development org.');"
    );
    const waitForJob = async (job) => {
        for (let attempt = 0; attempt < 90; attempt++) {
            const result = apex(
                `System.debug('FONT_DEMO_RESULT:'+JSON.serialize(DocGenFontController.getFontJobStatus(${literal(job)})));`
            );
            if (result.error) throw Error(result.error);
            if (result.status === 'Completed') return;
            await new Promise((resolve) => setTimeout(resolve, 2000));
        }
        throw Error('Font job is still running. Check Salesforce Apex Jobs before retrying.');
    };
    for (const f of manifest) {
        let state =
            apex(`List<DocGen_Font_Face__c> rows=[SELECT Status__c,Proof_CV_Id__c,Source_Checksum__c FROM DocGen_Font_Face__c WHERE Revision_Key__c=${literal(f.key)} LIMIT 1];
System.debug('FONT_DEMO_RESULT:'+JSON.serialize(rows.isEmpty()?null:new Map<String,Object>{'status'=>rows[0].Status__c,'proof'=>rows[0].Proof_CV_Id__c,'pinned'=>rows[0].Source_Checksum__c!=null}));`);
        if (!state) {
            const fixture = path.join(root, 'scripts/fonts', f.fixture);
            const body = path.join(dir, 'font-upload.json');
            writeFileSync(
                body,
                JSON.stringify({
                    Title: f.file,
                    PathOnClient: f.file,
                    VersionData: readFileSync(path.join(fixture, f.file)).toString('base64')
                })
            );
            const upload = JSON.parse(
                execFileSync(
                    'sf',
                    [
                        'api',
                        'request',
                        'rest',
                        '/services/data/v67.0/sobjects/ContentVersion',
                        '--target-org',
                        org,
                        '--method',
                        'POST',
                        '--body',
                        '@' + body
                    ],
                    { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
                )
            );
            if (!upload.success) throw Error('Demo font File upload failed: ' + JSON.stringify(upload));
            const license = readFileSync(path.join(fixture, 'LICENSE.txt'), 'utf8');
            const job =
                apex(`ContentVersion cv=[SELECT ContentDocumentId FROM ContentVersion WHERE Id=${literal(upload.id)} LIMIT 1];
System.debug('FONT_DEMO_RESULT:'+JSON.serialize(DocGenFontController.importUploadedFont(cv.ContentDocumentId,${literal(f.fontKey)},${literal(license)},true)));`);
            await waitForJob(job);
            state = { status: 'Staged' };
        }
        if (state.status === 'Staged' || (state.status === 'Published' && !state.proof) || !state.pinned) {
            const job = apex(
                `System.debug('FONT_DEMO_RESULT:'+JSON.serialize(DocGenFontController.startFontProof(${literal(f.key)})));`
            );
            await waitForJob(job);
        }
        state = apex(`DocGen_Font_Face__c f=DocGenFontController.load(${literal(f.key)});
DocGenFontController.ensureFontPreview(${literal(f.key)});
System.debug('FONT_DEMO_RESULT:'+JSON.serialize(new Map<String,Object>{'status'=>f.Status__c,'proof'=>f.Proof_CV_Id__c}));`);
        console.log(f.file, state.status, state.proof || '');
    }
    if (args.includes('--create-template')) {
        const html = readFileSync(path.join(root, 'docs/examples/CustomFontsShowcase.html'), 'utf8');
        const result =
            apex(`for(String key:new List<String>{${manifest.map((f) => literal(f.key)).join(',')}}) if(DocGenFontController.load(key).Status__c!='Verified')throw new DocGenException('Review and approve every native specimen in Assets before creating the demo template.');
List<DocGen_Template__c> prior=[SELECT Id FROM DocGen_Template__c WHERE Name='Custom Fonts - Brand Showcase' LIMIT 1];
Id templateId;
if(prior.isEmpty()){
DocGen_Template__c t=new DocGen_Template__c(Name='Custom Fonts - Brand Showcase',Type__c='Canvas',Base_Object_API__c='Account',Query_Config__c='Name',Output_Format__c='PDF',Category__c='Font demo',Document_Title_Format__c='Portwood Custom Fonts - {Name}');insert t;
insert new DocGen_Template_Version__c(Template__c=t.Id,Is_Active__c=true,Type__c='Canvas',Base_Object_API__c='Account',Query_Config__c='Name',Output_Format__c='PDF');
DocGenController.saveAndPublishHtmlBody(t.Id,'font-showcase.html',${literal(html)},true);templateId=t.Id;
}else templateId=prior[0].Id;
System.debug('FONT_DEMO_RESULT:'+JSON.serialize(templateId));`);
        console.log('Demo template:', result);
    }
    if (args.includes('--create-html-template')) {
        const html = readFileSync(path.join(root, 'docs/examples/HtmlFontTagsShowcase.html'), 'utf8');
        const result =
            apex(`for(String key:new List<String>{${manifest.map((f) => literal(f.key)).join(',')}}) if(DocGenFontController.load(key).Status__c!='Verified')throw new DocGenException('Review and approve every native specimen in Assets before creating the demo template.');
List<DocGen_Template__c> prior=[SELECT Id FROM DocGen_Template__c WHERE Name='HTML Fonts - Merge Tag Showcase' LIMIT 1];
Id templateId;
if(prior.isEmpty()){
DocGen_Template__c t=new DocGen_Template__c(Name='HTML Fonts - Merge Tag Showcase',Type__c='HTML',Base_Object_API__c='Account',Query_Config__c='Name',Output_Format__c='PDF',Category__c='Font demo',Document_Title_Format__c='HTML Font Tags - {Name}');insert t;
DocGenController.saveAndPublishHtmlBody(t.Id,'html-font-tags.html',${literal(html)},true);templateId=t.Id;
}else templateId=prior[0].Id;
System.debug('FONT_DEMO_RESULT:'+JSON.serialize(templateId));`);
        console.log('HTML font-tag demo template:', result);
    }
    if (args.includes('--create-designer-template')) {
        const html = readFileSync(path.join(root, 'docs/examples/DesignerFontCollection.html'), 'utf8');
        const result =
            apex(`for(String key:new List<String>{${manifest.map((f) => literal(f.key)).join(',')}}) if(DocGenFontController.load(key).Status__c!='Verified')throw new DocGenException('Review and approve every native specimen in Assets before creating the demo template.');
List<DocGen_Template__c> prior=[SELECT Id FROM DocGen_Template__c WHERE Name='Designer Fonts - Test Collection' LIMIT 1];
Id templateId;
if(prior.isEmpty()){
DocGen_Template__c t=new DocGen_Template__c(Name='Designer Fonts - Test Collection',Type__c='HTML',Base_Object_API__c='Account',Query_Config__c='Name',Output_Format__c='PDF',Category__c='Font demo',Is_Active__c=false,Document_Title_Format__c='Designer Fonts - {Name}');insert t;
DocGenController.saveAndPublishHtmlBody(t.Id,'designer-font-collection.html',${literal(html)},true);templateId=t.Id;
}else templateId=prior[0].Id;
System.debug('FONT_DEMO_RESULT:'+JSON.serialize(templateId));`);
        console.log('Designer font collection template:', result);
    }
    console.log(
        'Open Portwood > Assets > Fonts to review specimens. Existing verified revisions and templates are preserved.'
    );
} finally {
    rmSync(dir, { recursive: true, force: true });
}
