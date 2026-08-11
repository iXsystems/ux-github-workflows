/**
 * The GitHub calls the review tooling shares.
 *
 * Two scripts need to find the same comment: `mark-review-stale.mjs` banners it
 * before a review, `check-review-threshold.mjs` rewrites it after. What counts
 * as "the summary comment" therefore has to be one definition rather than two
 * that agree today — that divergence is a bug we have already had once, when the
 * lookup matched on the marker alone and any comment quoting it could win.
 */

/**
 * Written by the gate at the end of the summary, invisible in rendered
 * markdown. It records which commit the summary describes, so a later run can
 * mark it superseded rather than leaving a reader to assume a comment written
 * four commits ago still applies.
 */
export const MARKER = /<!--\s*reviewed-sha:\s*([0-9a-f]{7,40})\s*-->/;

export const markerFor = (sha) => `<!-- reviewed-sha: ${sha} -->`;

export const api = async (path, init) => {
  const res = await fetch(`https://api.github.com/repos/${process.env.GITHUB_REPOSITORY}${path}`, {
    // A hung connection is the failure a catch cannot absorb: it would sit
    // there burning the job's timeout to save a comment.
    signal: AbortSignal.timeout(15_000),
    ...init,
    headers: {
      authorization: `bearer ${process.env.GH_TOKEN}`,
      accept: 'application/vnd.github+json',
      'content-type': 'application/json',
      ...init?.headers,
    },
  });
  if (!res.ok) throw new Error(`${init?.method ?? 'GET'} ${path} -> HTTP ${res.status}`);
  return res.json();
};

/**
 * Oldest-first and paginated: a summary past comment 100 was being reported as
 * "no previous summary", which silently disabled the whole stale-marking step on
 * any busy PR. Walk until a page comes back short.
 */
export const listIssueComments = async (number) => {
  const comments = [];
  for (let page = 1; page <= 10; page++) {
    const batch = await api(`/issues/${number}/comments?per_page=100&page=${page}`);
    comments.push(...batch);
    if (batch.length < 100) break;
  }
  return comments;
};

/**
 * Newest bot-authored comment carrying the marker.
 *
 * Author-filtered because the marker is not proof of authorship: it lives in the
 * body, so anyone quoting the summary — to reply to it, or to argue with it —
 * carries it into their own comment, and being newer would win. The token has
 * `issues: write` over the whole repo, so an edit aimed at the wrong comment
 * succeeds rather than being refused.
 *
 * `type === 'Bot'` rather than a login: the identity the summary is posted under
 * has already moved once, from the Claude app to github-actions[bot], and this
 * should not have to move with it.
 */
export const findSummaryComment = (comments) =>
  [...comments].reverse().find((c) => c.user?.type === 'Bot' && MARKER.test(c.body ?? ''));
