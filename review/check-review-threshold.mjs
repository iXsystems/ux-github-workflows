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

const BLOCKING = new Set(['BLOCKER', 'HIGH', 'MEDIUM']);

const raw = process.env.FINDINGS?.trim();

/** Anything that is not a clean, parseable result is a failure, never a pass. */
if (!raw) {
  console.log('::error::the review produced no structured output');
  console.log(
    'A review that reports nothing must not read as a review that found nothing. ' +
    'Check the review step above — it usually means the run failed or was cut short.'
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
  const where = [f.file && `file=${f.file}`, f.line && `line=${f.line}`].filter(Boolean).join(',');
  console.log(`::${level} ${where}::${f.severity}: ${f.summary}`);
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
