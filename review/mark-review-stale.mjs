/**
 * Mark the existing review summary as stale before a new review starts.
 *
 * One sticky comment edited in place is easier to read than one per round, but
 * it buys that with a window: from the moment a push lands until the new review
 * finishes, the comment describes code that is no longer there while looking
 * exactly as current as it did a minute earlier.
 *
 * Which way that misleads depends on luck. A stale "one BLOCKER" over a push
 * that fixed it is merely annoying. A stale "nothing blocking" over a push that
 * broke something is the direction worth spending a step on.
 *
 * The banner is removed by `check-review-threshold.mjs`, which rewrites the
 * whole comment body when the review finishes. So if the run is cancelled or
 * dies, the banner stays — which is correct, because the comment really is
 * describing an older commit.
 */

import { MARKER, api, listIssueComments, findSummaryComment } from './github.mjs';

/**
 * The banner is delimited by its own comments rather than matched by shape.
 *
 * The previous version counted newlines to find where it ended, and got the
 * count wrong: the emitter produced two and the stripper wanted three, so the
 * strip was a no-op and every cancelled round stacked another banner. Worse,
 * it passed a test — because I hand-wrote the fixture to match the regex
 * instead of generating it. Delimiters cannot drift from the thing they
 * delimit, and `buildBanner`/`stripBanner` now share them.
 */
const OPEN = '<!-- stale-banner -->';
const CLOSE = '<!-- /stale-banner -->';
const BANNER_BLOCK = new RegExp(`^${OPEN}[\\s\\S]*?${CLOSE}\\n*`);

const buildBanner = (reviewed, head) =>
  [
    OPEN,
    '> [!WARNING]',
    `> **Superseded.** This describes \`${reviewed.slice(0, 7)}\`. The branch is now`,
    `> at \`${head.slice(0, 7)}\` and a review of it is running — findings below may`,
    '> already be fixed, and problems introduced by the newer commits are not here yet.',
    CLOSE,
    '',
    '',
  ].join('\n');

const stripBanner = (body) => body.replace(BANNER_BLOCK, '');

const number = Number(process.env.PR_NUMBER);
const head = process.env.HEAD_SHA;

try {
  if (!process.env.GH_TOKEN || !process.env.GITHUB_REPOSITORY || !Number.isInteger(number) || !head) {
    throw new Error('missing GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER or HEAD_SHA');
  }

  const summary = findSummaryComment(await listIssueComments(number));

  if (!summary) {
    console.log('No previous review summary to mark; nothing to do.');
  } else {
    // Strip any banner a previous run left before deciding, rather than
    // treating its presence as "already handled". A cancelled review leaves one
    // behind, and the next push would then keep a banner naming a commit two
    // pushes old — a staleness notice that is itself stale.
    const stripped = stripBanner(summary.body);

    // Re-matched against the stripped body, so it can miss where the test on the
    // raw body passed. Say which comment, rather than throwing a bare TypeError
    // into the catch below and reporting it as the reason nothing was marked.
    const reviewed = MARKER.exec(stripped)?.[1];
    if (!reviewed) throw new Error(`no reviewed-sha marker left in comment ${summary.id}`);

    if (head.startsWith(reviewed) || reviewed.startsWith(head.slice(0, 7))) {
      console.log(`Summary already describes ${head.slice(0, 7)}; not marking.`);
    } else {
      await api(`/issues/comments/${summary.id}`, {
        method: 'PATCH',
        body: JSON.stringify({ body: buildBanner(reviewed, head) + stripped }),
      });
      console.log(`Marked the summary for ${reviewed.slice(0, 7)} as superseded by ${head.slice(0, 7)}.`);
    }
  }
} catch (error) {
  // Cosmetic. A review that runs with an unmarked stale comment is a great deal
  // better than a review that does not run.
  console.log(`::warning::could not mark the previous review stale: ${error.message}`);
}
