/**
 * Whether a comment or review was written by the identity this run posts as.
 *
 * `REVIEW_LOGIN` is set by the workflow: `github-actions[bot]` for the job
 * token, the user's login for a PAT, empty for a GitHub App installation
 * token (`/user` is not available to those), where matching falls back to
 * the author type.
 */
export const isOwn = (user) => {
  const login = process.env.REVIEW_LOGIN;
  return login ? user?.login === login : user?.type === 'Bot';
};
