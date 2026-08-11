# ux-github-workflows

Shared GitHub Actions workflows for UX team repositories.

Any repo the UX team owns can call these — there is nothing framework-specific
here. Current consumers:

| Repo | Org |
|---|---|
| [`truenas/webui`](https://github.com/truenas/webui) | truenas |
| [`iXsystems/truenas-ui-components`](https://github.com/iXsystems/truenas-ui-components) | iXsystems |
| `truenas-connect/ui` | truenas-connect |

## This repository must stay public

Consumers live in different GitHub organisations, and no single enterprise
account spans them. Reusable workflows in a **private** repo cannot be called
across orgs at all; **internal** requires a shared enterprise. Public is the
only option that works everywhere, and public reusable workflows can be called
from private repos, so private consumers such as `truenas-connect/ui` are
covered.

Consequence: **nothing secret goes in this repo.** Secrets stay in each
consumer repo and are passed in by name at the call site.

## Workflows

### `check-ticket.yml`

Fails a PR whose title does not reference a Jira ticket.

```yaml
on:
  pull_request:
    types: [opened, edited, reopened, synchronize]

jobs:
  check-ticket:
    uses: iXsystems/ux-github-workflows/.github/workflows/check-ticket.yml@master
    with:
      ticket-prefixes: TNC   # optional; defaults to NAS
```

| Input | Default | Notes |
|---|---|---|
| `ticket-prefixes` | `NAS` | Comma-separated Jira project keys. `NAS,TNC` accepts either. |

The match is case-sensitive: bugclerk only links the Jira ticket for an
uppercase key, so `nas-12345` fails with a message saying so.

Callers own their `on:` trigger — a reusable workflow has no say in what
triggers its caller.

This one is **policy, not just plumbing** — it makes a ticket mandatory. All
three consumers have since agreed to that, but a fourth repo should adopt it
only once its team has. Note that `iXsystems/truenas-ui-components` requires a
ticket *and* a Conventional Commits title; the latter stays in its own local
`pr-title.yml`, since it is the only repo running semantic-release.

### `check-member.yml`

Reports whether the PR author has write access to the calling repo, as an
`is_member` output:

```yaml
jobs:
  check-member:
    if: github.event_name == 'pull_request'
    permissions:
      contents: read
    uses: iXsystems/ux-github-workflows/.github/workflows/check-member.yml@master

  test-ux-team:
    needs: [check-member]
    if: needs.check-member.outputs.is_member == 'true'
    runs-on: self-hosted
    # ...
```

| Output | Notes |
|---|---|
| `is_member` | `'true'` / `'false'` — a string, not a boolean. Compare with `== 'true'` |

`main.yml` in `truenas/webui` and `truenas-connect/ui` calls it to route tests
to the self-hosted runner. Those were three separate copies of the same script
before this existed — two workflow files plus one inlined directly in
`truenas-connect/ui`'s `main.yaml`.

Only meaningful on `pull_request` events: it reads
`context.payload.pull_request`, and reports `'false'` on any event that has no
PR payload rather than failing. Guarding the job with
`if: github.event_name == 'pull_request'` is still worth doing to skip a
pointless runner — but then the downstream job needs `always()` (or
`!cancelled()`) plus an explicit `!= 'true'`, so the skip does not cascade into
it. See `truenas/webui`'s `main.yml` for the worked example.

If the permission lookup fails it falls back to `author_association`, which is
deliberately permissive. It decides where tests run; it must not be
load-bearing for anything that gates a merge.

### `claude-review.yml` and `claude-review-gated.yml`

Automatic PR review, in two variants. **Pick one per repo.** They are published
side by side so the newer one can be trialled without giving up the one people
already know, not so that both run on the same PR — see the warning below.

| | `claude-review.yml` | `claude-review-gated.yml` |
|---|---|---|
| Output | one sticky comment | inline comments + one edited-in-place summary |
| Result | advisory; the job passes either way | fails at MEDIUM and above |
| Severities | whatever the prompt asks for | fixed enum, enforced by a JSON schema |
| Knows what it said last round | no | yes — prior threads and their resolved state |
| Marks its own comment stale | no | yes, while a new review is in flight |
| Mode | tag mode (`track_progress`) | agent mode |

Both take the same call shape:

```yaml
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  claude-review:
    uses: iXsystems/ux-github-workflows/.github/workflows/claude-review-gated.yml@master
    permissions:
      contents: read
      issues: write
      pull-requests: write
      id-token: write
    secrets:
      anthropic-api-key: ${{ secrets.CLAUDE_API_KEY }}
```

| Input | Default | Notes |
|---|---|---|
| `model` | `claude-opus-5` | Passed through `claude_args` |
| `prompt-file` | `.claude/review-prompt.md` | The repo's own guidelines |
| `require-write-access` | `true` | Calls `check-member.yml`. Keep it on — it is what stops a drive-by PR spending tokens |
| `skip-label` | `skip-claude` | |
| `timeout-minutes` | `20` | |
| `fetch-depth` | `10` | Must cover the PR range |
| `tooling-ref` | `master` | `claude-review-gated.yml` only; see below |

The secret is named, not inherited, because the repos call it different things
(`CLAUDE_API_KEY` vs `CLAUDE_TOKEN`). The `anthropics/claude-code-action`
version is hardcoded rather than an input: `uses:` does not evaluate
expressions, and a configurable version is how the consumers ended up on
v1.0.182, v1.0.154 and v1.0.134 in the first place. Both files pin the same
version; bump there and every caller moves.

**Do not run both on one PR.** Both post as `github-actions[bot]`, and the
gated one's `gh pr comment --edit-last` edits the last comment *that bot*
wrote — which, with the other workflow also running, may be its sticky comment.
Their `concurrency` groups are distinct, so nothing cancels anything; the
collision is over the comment, not the runner.

#### What the gated variant adds, and what it needs from the repo

The review's structured output is scored by `review/check-review-threshold.mjs`
against `review/schema.json`: **MEDIUM, HIGH and BLOCKER fail the job**, LOW does
not, and a review that produced no parseable output fails too — a reviewer that
crashed must not read as a reviewer that found nothing. Findings are emitted as
workflow annotations, so they land on the diff in the Files tab.

Whether a failed job blocks a merge is branch protection, set per repo. That is
the reversible half of the decision, and adopting this workflow does not make it
for you. There is deliberately no override label: bypassing a red check is
something branch protection already gates on permission and records against a
person. (`skip-label` is the exception, and it skips the whole review rather
than a finding — restrict who can apply it.)

The severity rubric that assigns those levels is `review/rubric.md`, here rather
than in each repo, because the gate and the schema are here: three copies of the
rubric would drift from the thing scoring them. The workflow appends it to the
caller's `prompt-file`, so a repo's own file should say what to look for in
*its* code and leave grading alone. A repo migrating a prompt that already
carries a rubric — `truenas/api-client-ts` does — should delete that half.

`tooling-ref` exists because the schema, rubric and scripts have to be checked
out into the caller's workspace at run time, and a reusable workflow cannot see
which ref it was itself called at. (`github.job_workflow_sha` is exactly that,
but actionlint 1.7.7 does not know the property and fails the file, and this
repo's CI runs actionlint.) It defaults to `master`, which matches every current
caller. A caller pinning this workflow to a tag must pin `tooling-ref` to the
same tag, or it gets `master`'s tooling against a pinned workflow.

Everything the run generates, and the tooling checkout itself, goes in
`.claude-review/` in the workspace, added to `.git/info/exclude` so it stays out
of `git status` and out of the review.

## Actions

### `.github/actions/prepare`

A **composite action**, not a reusable workflow: it runs as a step inside an
existing job, so the caller keeps its own `runs-on`, `permissions` and checkout.
Reusable workflows cannot do that — they bring their own job.

```yaml
steps:
  - uses: actions/checkout@v4          # required first; this installs into the workspace
  - uses: iXsystems/ux-github-workflows/.github/actions/prepare@master
    with:
      cache-jest: 'true'               # optional
```

| Input | Default | Notes |
|---|---|---|
| `node-version` | `24.13.1` | Pinned, not floating |
| `cache-jest` | `'false'` | Caches `.jest/cache`; only useful where Jest runs |
| `yarn-cache` | `'false'` | Caches Yarn's global cache folder |

Inputs are strings — every composite-action input is. Compare with `== 'true'`.

**Step order is load-bearing.** `actions/setup-node` runs *before*
`corepack enable`, because Corepack writes its shims into the active Node
installation's bin directory: enable it first and then let setup-node swap in a
different Node, and `yarn` goes missing. That is also why setup-node's own
`cache: 'yarn'` is not used — it shells out to `yarn` before Corepack has run,
and would either fail or silently cache Yarn 1's directory for a Yarn 4 repo.
The `yarn-cache` input resolves the folder with `yarn config get cacheFolder`
after Corepack instead.

This replaced identical local copies in `truenas/webui` and `truenas-connect/ui`
and six inline repetitions in `iXsystems/truenas-ui-components`'s `ci-cd.yml`,
which had drifted to a floating `'24'` against the others' pinned `24.13.1`.

## Adoption status

| Repo | `check-ticket` | `check-member` | `prepare` | review |
|---|---|---|---|---|
| `truenas/webui` | adopted | migrating (`main.yml`) | migrating | own `claude.yml` |
| `iXsystems/truenas-ui-components` | adopted | n/a — no self-hosted runner | migrating | own `claude.yml` |
| `truenas-connect/ui` | adopted | migrating (`main.yaml`) | migrating | own `claude.yml` |
| `truenas/api-client-ts` | n/a | n/a — has its own `check-team.yml` | n/a | own `claude.yml`, the source of the gated variant |

No repo calls the shared review workflows yet — they are published here first so
that migrating a consumer is a small PR in that consumer, reviewable on its own.
Each repo's local `claude.yml` keeps working until it is replaced.

Two of those local files are already duplicates of something here:
`api-client-ts`'s `check-team.yml` is byte-identical to `check-member.yml` apart
from `name:`, and `truenas-ui-components`'s `check-member.yml` is the same file
again. Whichever review workflow a repo adopts, that copy goes with it.

## Releasing

Callers reference `@master`, so **anything landing on `master` is live in every
consumer immediately** — there is no per-repo review gate between a change here
and three repos' CI running it.

That puts the whole burden on the PR into this repo:

- Treat a change to a job `name:` as breaking. Consumers match
  `"<caller job id> / <this name>"` in branch protection, so a rename silently
  stops a required check reporting, with no PR in their repo to explain it.
- Same for removing or renaming an input, or tightening a default.
- Verify against one consumer's next real PR before assuming it is fine
  everywhere; the consumers differ in trigger, secret names and permissions.
- `review/` ships the same way. It is checked out at `tooling-ref`, which
  defaults to `master`, so an edit to the rubric changes how every gated
  review grades on its next run — including whether a finding fails a build.

If that becomes too sharp an edge, the alternative is tagging: cut `v1`, move
callers to `@v1`, and release with `git tag -f v1 && git push -f origin v1`.
That was the original intent, but with only three consumers and one team it was
judged more ceremony than it buys.
