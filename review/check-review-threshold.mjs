/**
 * Fail the build when the automated review reports anything at or above MEDIUM.
 *
 * Reads the review's structured output — see `review/schema.json` for the shape
 * and `review/rubric.md` for the rubric that assigns severities. Findings are
 * emitted as workflow annotations so a failure lands on the diff in the Files
 * tab rather than only in the log.
 *
 * Whether this actually blocks a merge is a branch-protection setting, not a
 * property of this script: it fails the job either way, and marking the check
 * required is the separate, reversible decision that turns that into a gate.
 *
 * There is deliberately no override label. Bypassing a failed check is
 * something branch protection already gates on permission and records against a
 * person; a label would be a weaker parallel mechanism that anyone with write
 * access could apply, and — being attached to the PR rather than to the finding
 * — would go on suppressing findings from every later push.
 */

import { readFileSync } from 'node:fs';

const BLOCKING = new Set(['BLOCKER', 'HIGH', 'MEDIUM']);

/**
 * Workflow commands are line-oriented, and every field below is written by the
 * model. A newline in a summary ends the annotation and hands what follows to
 * the runner as a fresh line — so a finding whose text happens to contain
 * `::error::`, or `::stop-commands::`, is a finding that writes the log rather
 * than appearing in it. The mundane version of the same bug is more likely:
 * a summary with a line break in it silently loses everything after it.
 *
 * `maxLength: 200` in the schema bounds how much text arrives, not which bytes,
 * and nothing validates the payload against that schema before this script
 * reads it anyway. These are GitHub's own escapes: `%` first, or it would
 * re-escape the escapes.
 */
const escapeData = (value) =>
  String(value).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');

/** Property values additionally end at `:` or `,`, which separate the properties. */
const escapeProperty = (value) => escapeData(value).replace(/:/g, '%3A').replace(/,/g, '%2C');

const raw = process.env.FINDINGS?.trim();

/**
 * When the reviewer died before producing output, the execution log usually
 * names why — a usage-limit or auth API error beats the generic guidance
 * below, which sends the reader hunting through the run for a cause the
 * result entry already states.
 */
const terminalApiError = () => {
  const file = process.env.EXECUTION_FILE?.trim();
  if (!file) return null;
  try {
    const messages = JSON.parse(readFileSync(file, 'utf8'));
    const result = messages.findLast((m) => m?.type === 'result');
    if (result?.terminal_reason === 'api_error' || result?.api_error_status) {
      return String(result.result || `API error (status ${result.api_error_status})`);
    }
  } catch {
    // Unreadable log: fall through to the generic message.
  }
  return null;
};

/** Anything that is not a clean, parseable result is a failure, never a pass. */
if (!raw) {
  const apiError = terminalApiError();
  if (apiError) {
    console.log(`::error::the review never ran — ${escapeData(apiError)}`);
    console.log(
      'The reviewer terminated on an API error before producing output, so there is ' +
      'nothing to score and this fails closed. This is not a finding in the PR: fix ' +
      'the API-side condition (usage limit, expired key, outage) and re-run the job.'
    );
    process.exit(1);
  }
  console.log('::error::the review produced no structured output');
  console.log(
    'A review that reports nothing must not read as a review that found nothing, ' +
    'so this fails rather than passes. Check the review step above.\n' +
    '\n' +
    'If that step SUCCEEDED in a few seconds, it did not review anything — look for:\n' +
    '\n' +
    '  Skipping action due to workflow validation: The workflow file must exist and\n' +
    '  have identical content to the version on the repository\'s default branch.\n' +
    '\n' +
    'That is the OIDC-to-app-token exchange refusing, not the review failing, and ' +
    'the workflow avoids it by passing `github_token` to the action. Seeing it ' +
    'means that input went missing, or a caller is pinned to a ref from before it ' +
    'was added — check the `Automatic PR Review` step for `Using provided ' +
    'GITHUB_TOKEN for authentication`, which is the line that says the exchange ' +
    'was skipped.\n' +
    '\n' +
    'Otherwise the run genuinely failed or was cut short: an expired or missing API ' +
    'key, the job timeout, or a cancelled run.'
  );
  process.exit(1);
}

let findings;
try {
  const parsed = JSON.parse(raw);
  findings = parsed.findings;
  if (!Array.isArray(findings)) throw new Error('no `findings` array');
} catch (error) {
  console.log(`::error::could not read the review's structured output: ${error.message}`);
  process.exit(1);
}

const blocking = findings.filter((f) => BLOCKING.has(f.severity));

for (const f of findings) {
  const level = BLOCKING.has(f.severity) ? 'error' : 'notice';
  const where = [
    f.file && `file=${escapeProperty(f.file)}`,
    f.line && `line=${escapeProperty(f.line)}`,
  ]
    .filter(Boolean)
    .join(',');
  // Appended with its own space, rather than interpolated with one: `file` is
  // required by the schema but not enforced here, and a finding without one
  // would otherwise emit `::error ::…`, a command with a trailing space.
  console.log(`::${level}${where && ` ${where}`}::${escapeData(`${f.severity}: ${f.summary}`)}`);
}

if (blocking.length === 0) {
  console.log(`Review found nothing at or above MEDIUM (${findings.length} finding(s) total).`);
  process.exit(0);
}

console.log(`::error::${blocking.length} finding(s) at or above MEDIUM`);
console.log(
  'Fix them, or say on the PR why a finding was mis-rated — a finding that cannot ' +
  'name its failing input, or quote the claim it calls untrue, should have been LOW.\n' +
  'There is no override label. Overriding a red check is branch protection\'s job, ' +
  'which already restricts who may do it and records that they did.'
);
process.exit(1);
