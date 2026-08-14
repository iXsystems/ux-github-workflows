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
four consumers have agreed to that, but a fifth repo should adopt it only once
its team has. `truenas/api-client-ts` adopted it with `ticket-prefixes: TNC`
knowing what it costs: only 9 of its previous 30 merged PRs carried a ticket,
so this is a change in how that repo works, not a formalisation of what it
already did.

Two repos require a ticket *and* a Conventional Commits title. That second
check is `pr-title.yml`, below — it is a separate concern (semantic-release
reads the title) and a separate workflow.

### `pr-title.yml`

Requires a Conventional Commits PR title, optionally prefixed with
`<anything> / ` segments — `NAS-141240 / 27.0.0-BETA.1 / feat(x): y` and plain
`fix: y` both pass. No inputs.

```yaml
on:
  pull_request_target:
    types: [opened, edited, synchronize]

jobs:
  pr-title:
    permissions:
      pull-requests: read
    uses: iXsystems/ux-github-workflows/.github/workflows/pr-title.yml@master
```

This is only worth running where a squash merge feeds the PR title to
semantic-release as the commit subject — `iXsystems/truenas-ui-components` and
`truenas/api-client-ts` today. It is a *release* gate wearing a style gate's
clothes.

**The caller's `.releaserc.json` has to agree with the pattern**, or a title
this accepts parses over there as a different type and the merge publishes
nothing. That failure is a release that did not happen, which nobody notices.
Keep `parserOpts.headerPattern` equal to:

```
^(?:[^:]+ / )?(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(?:\(([^)]+)\))?!?: (.+)$
```

and `breakingHeaderPattern` to the same with `!:` for `!?:`.

The optional prefix is `[^:]+`, not `.+`, and that is the substantive
difference between the two copies this replaced. A greedy `.+ / ` swallows the
real type: in `fix: adjust a / b: c` it matches `fix: adjust a / ` and leaves
`b`. `truenas-ui-components` had the greedy one in both its gate and its
`.releaserc.json`; adopting this converged it on the strict pattern. Checked
against the last 40 merged titles in both repos, nothing changes but that case.

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

### `claude-review.yml`

Automatic PR review, and the only one published here. It replaces the inline
`claude.yml` each consumer grew its own copy of:

| | inline `claude.yml` (what consumers had) | `claude-review.yml` |
|---|---|---|
| Output | one sticky comment | inline comments + one edited-in-place summary |
| Result | advisory; the job passes either way | fails at MEDIUM and above |
| Severities | whatever the prompt asks for | fixed enum, enforced by a JSON schema |
| Knows what it said last round | no | yes — prior threads and their resolved state |
| Marks its own comment stale | no | yes, while a new review is in flight |
| Mode | tag mode (`track_progress`) | agent mode |
| Action version | drifted to three different pins | one, bumped here for everyone |

There is deliberately one of these, not a choice of two. If it turns out to be
wrong, change it here and every caller moves together; reverting is what git
history is for, not a second workflow kept alive in case.

The call shape:

```yaml
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  claude-review:
    uses: iXsystems/ux-github-workflows/.github/workflows/claude-review.yml@master
    permissions:
      contents: read
      issues: write
      pull-requests: write
    secrets:
      anthropic-api-key: ${{ secrets.CLAUDE_API_KEY }}
```

No `id-token: write`: nothing here mints an OIDC token, because the workflow
passes `github_token` explicitly and that skips the exchange the OIDC token was
for — see below. The review job's own `permissions:` block does not ask for it
either, so granting it in a caller has no effect on the token the job runs with.

| Input | Default | Notes |
|---|---|---|
| `model` | `claude-opus-5` | Passed through `claude_args` |
| `prompt-file` | `.claude/review-prompt.md` | The repo's own guidelines |
| `require-write-access` | `true` | Calls `check-member.yml`. Keep it on — it is what stops a drive-by PR spending tokens |
| `skip-label` | `skip-claude` | |
| `timeout-minutes` | `20` | |
| `fetch-depth` | `10` | Must cover the PR range |
| `extra-allowed-tools` | `''` | Comma-separated permission rules appended to the reviewer's `--allowedTools`, e.g. `Bash(go vet:*)`. Empty by default on purpose: anything that executes repo code runs PR-controlled code next to the job's write token, so each repo opts in as its own recorded decision |
| `tooling-ref` | `master` | Ref this repo's `review/` assets come from; see below |

The secret is named, not inherited, because the repos call it different things
(`CLAUDE_API_KEY` vs `CLAUDE_TOKEN`). The `anthropics/claude-code-action`
version is hardcoded rather than an input: `uses:` does not evaluate
expressions, and a configurable version is how the consumers ended up on
v1.0.182, v1.0.154 and v1.0.134 in the first place. Bump it here and every
caller moves.

**A repo must not keep its own inline review running alongside this.** Both
post as `github-actions[bot]`, and this one's `gh pr comment --edit-last` edits
the last comment *that bot* wrote — which, with an inline review also running,
may be its sticky comment. The `concurrency` groups are distinct, so nothing
cancels anything; the collision is over the comment, not the runner. Migrating
means replacing `claude.yml`'s contents, not adding a second workflow file.

#### What this needs from the repo

The review's structured output is scored by `review/check-review-threshold.mjs`
against `review/schema.json`: **MEDIUM, HIGH and BLOCKER fail the job**, LOW does
not, and a review that produced no parseable output fails too — a reviewer that
crashed must not read as a reviewer that found nothing. Findings are emitted as
workflow annotations, so they land on the diff in the Files tab.

**Why this passes `github_token` explicitly.** Left unset, the action exchanges
its OIDC token for an Anthropic GitHub App token, and that exchange refuses when
the calling workflow differs from the version on the default branch:

```
Workflow validation failed. The workflow file must exist and have identical
content to the version on the repository's default branch.
```

It is a reasonable guard on Anthropic's own credentials — a PR should not mint
an app token for a workflow nobody has merged — but it applies to the *token
exchange*, not to reviewing. The effect was that the PR adopting this workflow
could never be reviewed by it: the action skipped, the step went green in about
four seconds, and the gate below fails closed on empty output, so every
migration PR in every repo showed a red `Automatic PR review`.

Passing `github_token: ${{ github.token }}` makes `setupGitHubToken` return
early, so the exchange never happens. GitHub has already scoped that token to
the job's `permissions:` block, which is where the equivalent restriction
belongs. The costs: comments come from `github-actions[bot]` rather than the
Claude app, and on a `pull_request` from a fork `GITHUB_TOKEN` is read-only, so
posting would fail — `require-write-access` skips those anyway, leaving only a
write-access author working from a fork as the real gap.

Whether a failed job blocks a merge is branch protection, set per repo. That is
the reversible half of the decision, and adopting this workflow does not make it
for you. There is deliberately no override label: bypassing a red check is
something branch protection already gates on permission and records against a
person. (`skip-label` is the exception, and it skips the whole review rather
than a finding — restrict who can apply it.)

Worth knowing before marking `Automatic PR review` required: **a skipped job
satisfies a required status check.** So every path that skips the review — the
label, a non-member author, the write-access gate failing — reports green, and
the check says "reviewed" about a PR nobody reviewed. The first two are the
intended behaviour. The third was not, so a failed `check-member` now starts the
review job and fails it in its first step instead of leaving it to skip; that
costs a runner start and no API tokens. `check-member` answers `'false'` on a
permission lookup it cannot make, so reaching that step means the job itself
died — runner or action infrastructure, and a re-run.

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

`prompt-file` is copied there too, and the prompt points the reviewer at the
copy rather than at the caller's path. `claude-code-action` moves `.claude/`
aside to `.claude-pr/.claude/` before the reviewer starts, so the default
`.claude/review-prompt.md` — and anything else under `.claude/` — is not there
to be read by the time it matters. That failure is silent: the reviewer is the
only thing that expands `{{file:...}}`, and a path resolving to nothing looks
the same as a guidelines file with nothing to say, so the run costs a full
review that reads as one with guidelines. `.claude-review/` is outside the
directory the action relocates. A caller can keep its file wherever it likes.

The relocation has a second half the copy does not fix: the tracked files under
`.claude/` are now missing from the worktree, so `git diff` and `git status` —
which the reviewer runs to orient itself — report a deletion the pull request
does not make. The prompt says so, since nothing in the repo the reviewer is
looking at could tell it otherwise, and a finding raised on that phantom
deletion at MEDIUM or above would fail the gate over work nobody did.

CI checks that the `{{file:.claude-review/...}}` paths in the prompt agree with
the steps that write them. Those files do not exist until a run creates them, so
existence is not checkable here, but a reference and its producer are two
unrelated string literals and renaming one alone is silent at run time — which
is how the `prompt-file` reference stayed wrong for the whole life of the
workflow with no run reporting it.

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

| Repo | `check-ticket` | `pr-title` | `check-member` | `prepare` | review |
|---|---|---|---|---|---|
| `truenas/webui` | adopted | n/a — no semantic-release | migrating (`main.yml`) | migrating | own `claude.yml` |
| `iXsystems/truenas-ui-components` | adopted | migrating | n/a — no self-hosted runner | migrating | migrating (#175) |
| `truenas-connect/ui` | adopted | n/a — no semantic-release | migrating (`main.yaml`) | migrating | migrating (#370) |
| `truenas/api-client-ts` | migrating | migrating | via the review | migrating | migrating (#33) |
| `iXsystems/ux-github-workflows` (this repo) | adopted (`pr-ticket.yml`) | n/a — no semantic-release | self-test in `ci.yml` | n/a | adopted (`claude-review-self.yml`) |

This repo calls three of its own workflows, by relative path rather than
`@master`, so a change to any of them is executed on the pull request that makes
it instead of on a consumer's next one: `pr-ticket.yml` runs `check-ticket.yml`,
`ci.yml`'s `self-test` job runs `check-member.yml`, and
`claude-review-self.yml` runs `claude-review.yml`. `pr-ticket.yml` is a
separate file from `ci.yml` because the ticket check needs the `edited` trigger
and the rest of CI does not want it.

`claude-review-self.yml` is this repo's own adoption of the review, and differs
from a consumer's copy in two lines. The `uses:` is the local path, so a pull
request changing the review workflow is reviewed by the version it proposes.
`tooling-ref` is set to `${{ github.sha }}` rather than left at `master`, so the
rubric, schema and `review/*.mjs` come from that pull request too — otherwise a
change to the rubric would run under the new workflow and be graded by the old
rules. The guidelines it points the reviewer at are in
`.claude/review-prompt.md`, the default path.

`github.sha` and not the head SHA, because it has to be the commit the workflow
itself was loaded from. On `pull_request` that is the merge ref, where both the
relative `uses:` and the review job's `actions/checkout` resolve. Pinning the
tooling to the branch tip instead splits the two: the branch lacks whatever
reached `master` after it was cut, so a `claude-review.yml` from the merge ref
can call a `review/` script that is not in the tree the tooling came from, and
the step dies on `MODULE_NOT_FOUND`. The `review-assets` job does not catch it —
it checks that the workflow and `review/` agree inside a single tree, and two
commits is the case it cannot see.

The cost of calling it locally is that a pull request which breaks the review
workflow breaks its own review, and the failure looks like a review finding
until you read the job log. That is the same trade `self-test` already makes,
and it is the cheaper direction: the alternative is a consumer's CI finding out.
On a fork's pull request the workflow comes from the merge ref, as on any other
pull request — the fork's code merged into `master`. What a fork run does not
get is secrets, so the review step fails for want of an API key rather than
running fork-authored workflow code with one, and `require-write-access` stops
a non-writer's pull request before that point.

`api-client-ts` is the repo the review came from. Each consumer migrates by
replacing its own `claude.yml` with a call to this one — a small PR in that
repo, reviewable on its own, rather than something this repo can do to them.
`webui` has not been started.

Those PRs are reviewed by the workflow they install, which is only true because
this one passes `github_token` — see above. Nothing is required in branch
protection in these repos today, so a finding does not block a merge either.

`truenas-ui-components` has a local `check-member.yml`, which is where the one
here came from. It has since drifted: the copy there is the version from before
the missing-`pull_request`-payload guard, so it still throws on a non-PR event
rather than answering `false`. Its migration (#175) deletes it — the shared
review calls the shared gate, so the copy has nothing left to do.

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
