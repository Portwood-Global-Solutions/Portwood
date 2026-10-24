#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import prettier from 'prettier';
import { apexSurface } from './apex-surface.mjs';
import { markdownTables } from './markdown-tables.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const config = JSON.parse(read('docs/knowledgebase/guide.json'));
const project = JSON.parse(read('sfdx-project.json'));
const packageId = project.packageAliases[config.release.packageAlias];
const errors = [];
const assert = (condition, message) => {
    if (!condition) errors.push(message);
};
assert(
    /^04t\w{12,15}$/.test(packageId || ''),
    'Release packageAlias must resolve to a package version in sfdx-project.json.'
);
const version = config.release.packageAlias.split('@')[1]?.split('-')[0];
const slugs = new Set(config.articles.map((a) => a.slug));
assert(slugs.size === config.articles.length, 'Article slugs must be unique.');
const groupIds = new Set(config.groups.map((g) => g.id));
const allAnchors = new Set([...slugs, ...config.articles.flatMap((a) => a.aliases || [])]);
const files = [];
const surface = apexSurface(root);
const expand = (text) =>
    text
        .replaceAll('{{version}}', version)
        .replaceAll('{{packageId}}', packageId)
        .replaceAll('{{apexSurface}}', surface.markdown);
const articles = config.articles.map((article) => {
    const file = `docs/knowledgebase/articles/${article.slug}.md`;
    assert(fs.existsSync(path.join(root, file)), `${article.slug}: article file is missing.`);
    const sourceText = fs.existsSync(path.join(root, file)) ? read(file).trim() : '';
    const body = expand(sourceText);
    for (const error of markdownTables(body).errors) assert(false, `${file}: ${error}`);
    assert(groupIds.has(article.group), `${article.slug}: unknown group.`);
    assert(/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(article.slug), `${article.slug}: use a stable lowercase slug.`);
    assert(
        article.summary && article.audience && article.minutes > 0,
        `${article.slug}: summary, audience and reading time are required.`
    );
    assert(/^\d+\.\d+\.\d+$/.test(article.review?.version || ''), `${article.slug}: reviewed version is required.`);
    assert(/^\d{4}-\d{2}-\d{2}$/.test(article.review?.date || ''), `${article.slug}: review date is required.`);
    assert(
        ['org-and-source', 'source'].includes(article.review?.method),
        `${article.slug}: specify how this article was verified.`
    );
    assert(article.sources?.length, `${article.slug}: at least one source dependency is required.`);
    for (const source of article.sources || [])
        assert(fs.existsSync(path.join(root, source)), `${article.slug}: missing source ${source}`);
    for (const related of article.related || [])
        assert(slugs.has(related), `${article.slug}: missing related article ${related}`);
    // Fenced examples can contain headings, merge tags and fragment links. Validate prose separately.
    const prose = body.replace(/```[\s\S]*?```/g, '');
    assert(!/^#{1,3} /m.test(prose), `${article.slug}: article subsections must use H4 or below.`);
    assert(!/\{\{(?:version|packageId)\}\}/.test(body), `${article.slug}: unresolved release token.`);
    assert(
        !/04t[A-Za-z0-9]{12,15}/.test(sourceText),
        `${article.slug}: use the release token instead of a hard-coded package version ID.`
    );
    assert(!/\b(TODO|TBD|SCREENSHOT_HERE|PLACEHOLDER)\b/.test(prose), `${article.slug}: unfinished content.`);
    for (const match of prose.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
        const href = match[1];
        const repoPrefix = 'https://github.com/Portwood-Global-Solutions/Portwood/';
        if (href.startsWith(repoPrefix + 'blob/main/') || href.startsWith(repoPrefix + 'tree/main/')) {
            const relative = decodeURIComponent(
                href
                    .replace(repoPrefix, '')
                    .replace(/^(blob|tree)\/main\//, '')
                    .split('#')[0]
            );
            assert(fs.existsSync(path.join(root, relative)), `${article.slug}: missing repository target ${relative}`);
        }
        if (href.startsWith('#'))
            assert(allAnchors.has(href.slice(1)), `${article.slug}: unknown article link ${href}`);
        else if (!/^(https?:|mailto:)/.test(href)) {
            const target = href.split('#')[0];
            assert(fs.existsSync(path.join(root, target)), `${article.slug}: missing linked file ${target}`);
            if (match[0].startsWith('!')) files.push(target);
        }
    }
    return { ...article, file, body };
});
for (const file of fs.readdirSync(path.join(root, 'docs/reference')).filter((file) => file.endsWith('.md')))
    for (const error of markdownTables(read(`docs/reference/${file}`)).errors)
        assert(false, `docs/reference/${file}: ${error}`);
for (const learningPath of config.learningPaths)
    for (const slug of learningPath.articles)
        assert(slugs.has(slug), `Learning path ${learningPath.id}: missing ${slug}`);
const legacy = JSON.parse(read('docs/knowledgebase/legacy-coverage.json'));
for (const section of legacy.sections) {
    assert(slugs.has(section.article), `Legacy section ${section.heading}: destination is missing.`);
    const destination = articles.find((article) => article.slug === section.article);
    for (const anchor of [section.githubAnchor, section.siteAnchor])
        assert(
            destination && (destination.slug === anchor || destination.aliases.includes(anchor)),
            `Legacy section ${section.heading}: ${anchor} must resolve to ${section.article}.`
        );
}
const aliasList = articles.flatMap((a) => a.aliases || []);
assert(aliasList.length === new Set(aliasList).size, 'Legacy anchors must resolve to one article each.');
assert(
    aliasList.every((alias) => !slugs.has(alias)),
    'A legacy anchor cannot replace another article slug.'
);
const captions = JSON.parse(read('docs/knowledgebase/screenshots.json'));
assert(config.home?.image && config.home?.imageAlt, 'The homepage needs an image and alt text in guide.json.');
if (config.home?.image) files.push(config.home.image);
for (const file of new Set(files))
    assert(
        captions.some((s) => s.file === file),
        `Screenshot ${file} needs a provenance entry.`
    );
for (const shot of captions) {
    assert(fs.existsSync(path.join(root, shot.file)), `Missing screenshot ${shot.file}`);
    assert(
        shot.release && shot.capturedOn && shot.description,
        `Screenshot ${shot.file} needs release, date and description.`
    );
}
if (errors.length) {
    console.error(errors.join('\n'));
    process.exit(1);
}
const catalog = {
    schemaVersion: 1,
    product: { name: 'Portwood', version, packageId, packageAlias: config.release.packageAlias },
    home: config.home,
    images: Object.fromEntries(
        captions.map((shot) => {
            const bytes = fs.readFileSync(path.join(root, shot.file));
            assert(bytes.toString('ascii', 1, 4) === 'PNG', `${shot.file}: expected a PNG screenshot.`);
            return [
                shot.file,
                {
                    width: bytes.readUInt32BE(16),
                    height: bytes.readUInt32BE(20),
                    release: shot.release,
                    capturedOn: shot.capturedOn
                }
            ];
        })
    ),
    groups: config.groups,
    learningPaths: config.learningPaths,
    articles
};
const output = [
    '# Portwood Knowledgebase',
    '<!-- Generated by npm run guide:build. Edit docs/knowledgebase/articles and guide.json. -->',
    'Make your first document, build a template, send it for signature, and keep your team moving. Pick the task you want to finish; you do not need to read this guide from beginning to end.',
    `**Current release:** ${version}. [Install in production](https://login.salesforce.com/packaging/installPackage.apexp?p0=${packageId}) · [Install in a sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=${packageId}) · [Open the visual guide](https://portwood.dev/guide)`,
    '## Table of contents',
    ...config.groups.map(
        (g) =>
            `- **${g.title}**\n${articles
                .filter((a) => a.group === g.id)
                .map((a) => `  - [${a.title}](#${a.slug})`)
                .join('\n')}`
    )
];
for (const group of config.groups) {
    output.push(`## ${group.title}`, group.description);
    for (const article of articles.filter((a) => a.group === group.id)) {
        output.push([article.slug, ...(article.aliases || [])].map((id) => `<a id="${id}"></a>`).join('\n'));
        output.push(`### ${article.title}`, article.body);
        output.push(`*${article.audience} · ${article.minutes} min read · Reviewed for ${article.review.version}*`);
        if (article.related?.length)
            output.push(
                `**Next:** ${article.related
                    .map((slug) => {
                        const a = articles.find((a) => a.slug === slug);
                        return `[${a.title}](#${slug})`;
                    })
                    .join(' · ')}`
            );
        output.push('---');
    }
}
const outputs = new Map([
    ['UserGuide.md', output.join('\n\n') + '\n'],
    ['docs/knowledgebase/catalog.json', JSON.stringify(catalog, null, 2) + '\n'],
    ['docs/knowledgebase/apex-surface.json', JSON.stringify(surface.types, null, 2) + '\n']
]);
const check = process.argv.includes('--check');
for (const [file, content] of outputs) {
    const formatted = await prettier.format(content, {
        ...(await prettier.resolveConfig(path.join(root, file))),
        filepath: path.join(root, file)
    });
    if (check)
        assert(
            fs.existsSync(path.join(root, file)) && read(file) === formatted,
            `${file} is out of date. Run npm run guide:build.`
        );
    else fs.writeFileSync(path.join(root, file), formatted);
}
if (errors.length) {
    console.error(errors.join('\n'));
    process.exit(1);
}
console.log(
    `${check ? 'Validated' : 'Built'} ${articles.length} articles, ${config.groups.length} topics, ${new Set(files).size} referenced screenshots for Portwood ${version}.`
);
