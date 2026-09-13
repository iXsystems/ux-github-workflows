/**
 * Score the review's structured output, submit the matching PR review, and
 * fail the job on anything at or above MEDIUM.
 *
 * Shape in `review/schema.json`, severities from `review/rubric.md`. Findings
 * are emitted as workflow annotations so they land on the diff.
 *
 * The review submitted is decided here, never by the reviewer: it has no
 * `gh pr review`, so the review state on the PR cannot disagree with the check.
 *
 *   any finding >= MEDIUM                    REQUEST_CHANGES, job fails
 *   clean, but a human must look             COMMENT naming why, job passes
 *   clean, approve-when-clean off            COMMENT "would approve", job passes
 *   clean, approve-when-clean on             APPROVE, job passes
 *   clean, but GitHub refuses the APPROVE    COMMENT saying so, job passes
 *   no or unparseable output                 nothing submitted, job fails
 *
 * Nothing is submitted on a crashed reviewer on purpose: a changes-requested
 * review from a run that reviewed nothing would need a person to dismiss it.
 *
 * Whether any of this blocks a merge is branch protection, per repo. There is
 * deliberately no override label: bypassing a red check is something branch
 * protection already gates on permission and records against a person.
 */

import { readFileSync } from 'node:fs';

const BLOCKING = new Set(['BLOCKER', 'HIGH', 'MEDIUM']);
// In every review this script posts, so "mine" can mean this workflow's and
// not merely this login's: github-actions[bot] is shared with every other
// workflow that reviews under GITHUB_TOKEN.
const MARKER = '<!-- claude-review-verdict -->';

// Workflow commands are line-oriented and every field is model-written, so a
// newline or `::` in a summary would otherwise write the log rather than
// appear in it. GitHub's own escapes; `%` first.
const escapeData = (value) =>
  String(value).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
const escapeProperty = (value) => escapeData(value).replace(/:/g, '%3A').replace(/,/g, '%2C');

const env = (name) => process.env[name]?.trim() ?? '';
const token = env('GH_TOKEN');
const repo = env('GITHUB_REPOSITORY');
const number = Number(env('PR_NUMBER'));
const head = env('HEAD_SHA');
const approveWhenClean = env('APPROVE_WHEN_CLEAN') === 'true';
const humanReviewPaths = env('HUMAN_REVIEW_PATHS')
  .split('\n')
  .map((p) => p.trim())
  .filter((p) => p && !p.startsWith('#'));
for (const p of humanReviewPaths) {
  if (p.startsWith('!') || p.startsWith('/') || /[[\]{}]/.test(p)) {
    console.log(`::error::human-review-paths: \`${p}\` — negation, a leading slash, brackets and braces are not supported; see the input description.`);
    process.exit(1);
  }
}

const api = async (path, init) => {
  const res = await fetch(`https://api.github.com/repos/${repo}${path}`, {
    signal: AbortSignal.timeout(15_000),
    ...init,
    headers: {
      authorization: `bearer ${token}`,
      accept: 'application/vnd.github+json',
      'content-type': 'application/json',
      ...init?.headers,
    },
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`${init?.method ?? 'GET'} ${path} -> HTTP ${res.status} ${detail.slice(0, 300)}`);
  }
  return res.status === 204 ? null : res.json();
};

const paginate = async (path) => {
  const all = [];
  for (let page = 1; page <= 30; page++) {
    const batch = await api(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
    all.push(...batch);
    if (batch.length < 100) break;
  }
  return all;
};

/** The reviewer's terminal API error, when it died before producing output. */
const terminalApiError = () => {
  const file = env('EXECUTION_FILE');
  if (!file) return null;
  try {
    const messages = JSON.parse(readFileSync(file, 'utf8'));
    const result = messages.findLast((m) => m?.type === 'result');
    if (result?.terminal_reason === 'api_error' || result?.api_error_status) {
      return String(result.result || `API error (status ${result.api_error_status})`);
    }
  } catch {
    // Unreadable log: generic message below.
  }
  return null;
};

/** Anything that is not a clean, parseable result is a failure, never a pass. */
const raw = env('FINDINGS');
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
let humanReview;
try {
  const parsed = JSON.parse(raw);
  findings = parsed.findings;
  if (!Array.isArray(findings)) throw new Error('no `findings` array');
  humanReview = parsed.human_review;
  if (typeof humanReview?.required !== 'boolean') throw new Error('no `human_review.required` boolean');
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
  // `file` is required by the schema but not enforced here; without the guard
  // a finding lacking one emits `::error ::…`.
  console.log(`::${level}${where && ` ${where}`}::${escapeData(`${f.severity}: ${f.summary}`)}`);
}

/**
 * Glob to regex, gitignore rules: `**` crosses directories, `*` and `?` do
 * not; a trailing slash is only a directory marker, and a pattern with no
 * other slash matches at any depth; a match on a directory covers everything
 * beneath it. So `migrations/` and `migrations` are the same pattern, and
 * `db/migrations` is anchored at the root. That is the whole supported
 * syntax; the parse above rejects the rest.
 */
const globToRegExp = (pattern) => {
  const glob = pattern.replace(/\/+$/, '');
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') {
      const slash = glob[i + 2] === '/';
      re += slash ? '(?:.*/)?' : '.*';
      i += slash ? 2 : 1;
    } else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${glob.includes('/') ? '' : '(?:.*/)?'}${re}(?:/.*)?$`);
};

/** Paths the caller listed as always needing a person, matched against the PR's files. */
const pathReasons = async () => {
  if (humanReviewPaths.length === 0) return [];
  const files = await paginate(`/pulls/${number}/files`);
  const names = new Set(files.flatMap((f) => [f.filename, f.previous_filename]).filter(Boolean));
  const reasons = [];
  for (const glob of humanReviewPaths) {
    const re = globToRegExp(glob);
    const hits = [...names].filter((n) => re.test(n));
    if (hits.length) reasons.push(`\`${glob}\` (human-review-paths): ${hits.slice(0, 5).join(', ')}${hits.length > 5 ? ', …' : ''}`);
    else console.log(`human-review-paths: \`${glob}\` matched no file in this PR.`);
  }
  return reasons;
};

/** Returns the review GitHub created, whose `user` is this run's identity. */
const submit = async (event, lines) => {
  const review = await api(`/pulls/${number}/reviews`, {
    method: 'POST',
    body: JSON.stringify({ commit_id: head, event, body: [...lines, '', MARKER].join('\n') }),
  });
  console.log(`Submitted a ${event} review for ${head.slice(0, 7)} as ${review.user?.login}.`);
  return review;
};

/**
 * A COMMENT leaves the identity's earlier REQUEST_CHANGES or APPROVED in
 * force, so on the COMMENT paths both are dismissed: a stale block would
 * hold the merge, and a stale approval would let a change the verdict just
 * said needs a person merge without one. Own reviews are matched on the
 * login of the review just posted plus the body marker — no /user call, and
 * never another workflow's review under the same login.
 *
 * Best effort: the verdict is already on the PR. Dismissal on a protected
 * branch needs admin or a place on the dismiss list, and a refusal must not
 * turn a clean review into a red check.
 */
const dismissOwnStateReviews = async (own) => {
  try {
    const reviews = await paginate(`/pulls/${number}/reviews`);
    const stale = reviews.filter(
      (r) =>
        ['CHANGES_REQUESTED', 'APPROVED'].includes(r.state) &&
        r.id !== own.id &&
        r.user?.login === own.user?.login &&
        (r.body ?? '').includes(MARKER)
    );
    for (const r of stale) {
      await api(`/pulls/${number}/reviews/${r.id}/dismissals`, {
        method: 'PUT',
        body: JSON.stringify({ message: `Superseded by the review of ${head.slice(0, 7)}.` }),
      });
      console.log(`Dismissed ${r.state.toLowerCase().replace('_', '-')} review ${r.id}.`);
    }
  } catch (error) {
    console.log(`::warning::could not dismiss the previous review: ${escapeData(error.message)}`);
    console.log('A changes-requested review still blocks the merge, and an approval still counts, until someone dismisses it. On a protected branch the posting identity must be an admin or on the review-dismissal list.');
  }
};

const approveHint = (error) => {
  if (!/HTTP 422/.test(error.message)) return;
  console.log(
    'HTTP 422 on a review is usually one of two things: the job token is not allowed to ' +
    'approve — enable "Allow GitHub Actions to create and approve pull requests" in the ' +
    'repository or organisation Actions settings — or the owner of the github-token ' +
    'secret authored this PR, which GitHub refuses to let anyone approve or request ' +
    'changes on. Use a machine account or GitHub App rather than a person\'s token.'
  );
};

const counts = ['BLOCKER', 'HIGH', 'MEDIUM', 'LOW']
  .map((s) => [s, findings.filter((f) => f.severity === s).length])
  .filter(([, n]) => n > 0)
  .map(([s, n]) => `${n} ${s}`)
  .join(', ');
const countLine = findings.length ? `${findings.length} finding(s): ${counts}.` : 'No findings.';

try {
  if (!token || !repo || !Number.isInteger(number) || !head) {
    throw new Error('missing GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER or HEAD_SHA');
  }

  if (blocking.length > 0) {
    await submit('REQUEST_CHANGES', [
      `**Changes requested.** ${countLine}`,
      '',
      'Findings at MEDIUM and above are on the lines they are about. Fix them, or say on the PR why one was mis-rated.',
    ]);
  } else {
    const reasons = [
      ...(humanReview.required ? (humanReview.reasons ?? []).map(String) : []),
      ...(await pathReasons()),
    ];
    // On the flag, not the reason count: `required: true` with no reasons is
    // schema-valid and must not approve.
    if (humanReview.required || reasons.length > 0) {
      const own = await submit('COMMENT', [
        `**Needs a human review.** ${countLine}`,
        '',
        'Nothing blocks, but this change is one a person should decide on:',
        '',
        ...(reasons.length ? reasons : ['The reviewer flagged this as needing a person but gave no reason.']).map((r) => `- ${r}`),
      ]);
      await dismissOwnStateReviews(own);
      console.log(`Human review required: ${reasons.length} reason(s).`);
    } else if (!approveWhenClean) {
      const own = await submit('COMMENT', [
        `**Would approve.** ${countLine}`,
        '',
        'Nothing blocks and no human review is needed. Approval is off for this repository (`approve-when-clean`), so this is a comment.',
      ]);
      await dismissOwnStateReviews(own);
    } else {
      // An APPROVE supersedes the identity's earlier REQUEST_CHANGES only if
      // it lands. Refused (the Actions approve setting, a token whose owner
      // authored the PR), fall back to the COMMENT path so the stale block
      // is still cleared and the refusal is on the PR, not only in the log.
      try {
        await submit('APPROVE', [
          `**Approved.** ${countLine}`,
          '',
          'Nothing blocks and no human review is needed.',
        ]);
      } catch (error) {
        console.log(`::warning::could not approve: ${escapeData(error.message)}`);
        approveHint(error);
        const own = await submit('COMMENT', [
          `**Would approve.** ${countLine}`,
          '',
          'Nothing blocks and no human review is needed, but GitHub refused the approval:',
          '',
          `> ${error.message.replace(/\s+/g, ' ').slice(0, 300)}`,
          '',
          'With the job token this needs *Allow GitHub Actions to create and approve pull requests* in the repository\'s Actions settings; otherwise pass a `github-token` from a machine account.',
        ]);
        await dismissOwnStateReviews(own);
      }
    }
  }
} catch (error) {
  // The exit status is the score's, decided above; a review the token could
  // not post is the environment (the Actions approve setting, a token whose
  // owner authored the PR, a narrowed grant) and must not make a clean PR
  // red for good.
  console.log(`::warning::could not submit the review: ${escapeData(error.message)}`);
  console.log('The check still reports the score below; only the PR review is missing.');
  approveHint(error);
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
