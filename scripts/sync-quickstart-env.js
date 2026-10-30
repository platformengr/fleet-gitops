#!/usr/bin/env node
// Re-embeds bootstrap/<cloud>/env.example into site/quickstart.html so the
// generated env files always use the real variable names.
//   node scripts/sync-quickstart-env.js          rewrite the page
//   node scripts/sync-quickstart-env.js --check  exit 1 if the page is stale (CI)
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const page = path.join(root, 'site/quickstart.html');
const templates = {};
for (const cloud of ['aks', 'eks', 'gke']) {
  templates[cloud] = fs
    .readFileSync(path.join(root, `bootstrap/${cloud}/env.example`), 'utf8')
    .replace(/\n$/, '');
}
const json = JSON.stringify(templates, null, 2).replace(/</g, '\\u003c');

const html = fs.readFileSync(page, 'utf8');
const block = /var ENV_TEMPLATES = \{[\s\S]*?\n\};/;
if (!block.test(html)) throw new Error('ENV_TEMPLATES block not found in site/quickstart.html');
const next = html.replace(block, () => `var ENV_TEMPLATES = ${json};`);

if (process.argv.includes('--check')) {
  if (next !== html) {
    console.error('site/quickstart.html is out of date: run node scripts/sync-quickstart-env.js');
    process.exit(1);
  }
  console.log('quickstart env templates are in sync');
} else {
  fs.writeFileSync(page, next);
  console.log(next === html ? 'already in sync' : 'updated site/quickstart.html');
}
