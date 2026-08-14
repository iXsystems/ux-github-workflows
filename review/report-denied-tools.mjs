/**
 * List the tool calls the reviewer attempted and was denied.
 *
 * Reads the action's `execution_file` conversation log and emits a notice per
 * permission-denied tool call, so `--allowedTools` in claude-review.yml is
 * tuned on evidence instead of guesswork. Informational only: always exits 0,
 * and a missing or unreadable log is reported, not failed on.
 */

import { readFileSync } from 'node:fs';

const file = process.env.EXECUTION_FILE?.trim();

const bail = (message) => {
  console.log(message);
  process.exit(0);
};

if (!file) bail('No execution file from the review step; nothing to report.');

let messages;
try {
  const raw = readFileSync(file, 'utf8');
  // The file is a JSON array of stream messages; fall back to NDJSON in case
  // a future action version writes one message per line instead.
  try {
    messages = JSON.parse(raw);
  } catch {
    messages = raw.split('\n').filter(Boolean).map((line) => JSON.parse(line));
  }
  if (!Array.isArray(messages)) throw new Error('not a message array');
} catch (error) {
  bail(`Could not read execution file '${file}': ${error.message}`);
}

/** tool_use_id -> {name, input}, so a denial can name what was asked for. */
const requests = new Map();
for (const m of messages) {
  for (const block of m?.message?.content ?? []) {
    if (block?.type === 'tool_use') requests.set(block.id, block);
  }
}

const textOf = (content) =>
  typeof content === 'string'
    ? content
    : (content ?? []).map((c) => c?.text ?? '').join(' ');

const DENIED = /permission|approv|granted|not allowed|denied/i;

const denials = [];
for (const m of messages) {
  for (const block of m?.message?.content ?? []) {
    if (block?.type !== 'tool_result' || !block.is_error) continue;
    if (!DENIED.test(textOf(block.content))) continue;
    const req = requests.get(block.tool_use_id);
    if (req) denials.push(req);
  }
}

if (denials.length === 0) bail('The reviewer was not denied any tool calls.');

/** Model-written text; same escapes as check-review-threshold.mjs. */
const escapeData = (value) =>
  String(value).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');

for (const { name, input } of denials) {
  const detail = name === 'Bash' ? input?.command : JSON.stringify(input);
  console.log(`::notice::reviewer was denied ${escapeData(`${name}: ${String(detail).slice(0, 300)}`)}`);
}
console.log(
  `${denials.length} denied tool call(s). Recurring ones are candidates for ` +
  '--allowedTools in claude-review.yml; one-offs are the allowlist working.'
);
