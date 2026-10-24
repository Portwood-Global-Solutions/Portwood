#!/usr/bin/env node
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const [base = 'origin/main', head = 'HEAD'] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync('docs/knowledgebase/guide.json', 'utf8'));
const changed = execFileSync('git', ['diff', '--name-only', base, head], { encoding: 'utf8' })
    .trim()
    .split('\n')
    .filter(Boolean);
const affected = config.articles.filter((a) =>
    a.sources.some((source) => changed.some((file) => file === source || file.startsWith(source + '/')))
);
console.log(`Guide review for ${base}…${head}`);
console.log(
    affected.length
        ? affected
              .map(
                  (a) =>
                      `- [ ] ${a.title}\n      docs/knowledgebase/articles/${a.slug}.md (last reviewed ${a.review.version})`
              )
              .join('\n')
        : 'No mapped product files changed. Review new features for new articles.'
);
console.log('\nAlso review CHANGELOG.md for new capabilities, removed paths, and screenshots that need recapturing.');
