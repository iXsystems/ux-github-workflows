#!/usr/bin/env node
//
// Fails if any `inputs.<name>` reference resolves to an input that is not
// declared in the same file.
//
// This exists because of a real failure. The `prepare` action once had an
// optional install toggle; the input was removed and `if: inputs.install ==
// 'true'` was left behind on the step. GitHub resolves an undeclared input to
// the empty string rather than erroring, so the condition quietly became false,
// the install step was skipped, and the job reported a green "Install" that had
// installed nothing. It surfaced two repos away, as a webui build failing on a
// missing node_modules.
//
// actionlint does not cover this case: it checks workflow files, not the
// `action.yml` of a composite action — which is exactly where the bug was.

const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

function targets() {
  const found = [];
  const workflows = '.github/workflows';
  if (fs.existsSync(workflows)) {
    for (const f of fs.readdirSync(workflows)) {
      if (/\.ya?ml$/.test(f)) found.push(path.join(workflows, f));
    }
  }
  const actions = '.github/actions';
  if (fs.existsSync(actions)) {
    for (const dir of fs.readdirSync(actions)) {
      for (const name of ['action.yml', 'action.yaml']) {
        const p = path.join(actions, dir, name);
        if (fs.existsSync(p)) found.push(p);
      }
    }
  }
  return found.sort();
}

function declaredInputs(doc) {
  // YAML 1.1 parses a bare `on:` key as the boolean true, so a workflow's
  // trigger block lands on doc[true] rather than doc.on.
  const on = doc[true] || doc.on || {};
  const sources = [
    doc.inputs, // composite action
    on.workflow_call && on.workflow_call.inputs,
    on.workflow_dispatch && on.workflow_dispatch.inputs,
  ];
  return new Set(sources.filter(Boolean).flatMap((s) => Object.keys(s)));
}

function referencedInputs(raw) {
  // Drop whole-line comments first, so prose describing a removed input is not
  // mistaken for a live reference. Only full-line comments are stripped — a `#`
  // mid-line may be inside a string.
  const code = raw
    .split('\n')
    .filter((line) => !/^\s*#/.test(line))
    .join('\n');
  return new Set([...code.matchAll(/inputs\.([A-Za-z0-9_-]+)/g)].map((m) => m[1]));
}

let failures = 0;

for (const file of targets()) {
  const raw = fs.readFileSync(file, 'utf8');

  let doc;
  try {
    doc = yaml.load(raw);
  } catch (error) {
    console.log(`FAIL ${file}\n       unparseable YAML: ${error.message}`);
    failures++;
    continue;
  }

  const declared = declaredInputs(doc);
  const referenced = referencedInputs(raw);
  const undeclared = [...referenced].filter((name) => !declared.has(name));
  const unused = [...declared].filter((name) => !referenced.has(name));

  if (undeclared.length) {
    failures++;
    console.log(`FAIL ${file}`);
    for (const name of undeclared) {
      console.log(`       references \`inputs.${name}\`, which is not declared.`);
      console.log('       GitHub resolves this to an empty string — it will not error at runtime,');
      console.log('       it will silently evaluate as falsy. Declare the input or drop the reference.');
    }
  } else {
    console.log(`ok   ${file}`);
  }

  // Not a failure: an input can be a deliberate escape hatch no caller uses yet.
  // Still worth surfacing, since an unused input is also how the above starts.
  for (const name of unused) {
    console.log(`     note: \`${name}\` is declared but never referenced in this file.`);
  }
}

if (failures) {
  console.log(`\n${failures} file(s) reference undeclared inputs.`);
  process.exit(1);
}

console.log('\nAll input references resolve.');
