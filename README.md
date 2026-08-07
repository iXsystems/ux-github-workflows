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

### `claude-review.yml`

Automatic Claude PR review, gated on the PR author having write access.

```yaml
jobs:
  claude-review:
    uses: iXsystems/ux-github-workflows/.github/workflows/claude-review.yml@master
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
| `model` | `claude-opus-5` | |
| `prompt-file` | `.claude/review-prompt.md` | Repo-relative; the file stays in the consumer repo |
| `require-write-access` | `true` | Keep on for public repos |
| `skip-label` | `skip-claude` | |
| `timeout-minutes` | `20` | |
| `fetch-depth` | `10` | |
| `additional-permissions` | `''` | Extra reviewer capabilities, e.g. `gh pr list, gh pr view, gh api --method GET`. Opt-in per repo |

The API key is an explicit named secret rather than `secrets: inherit`, because
consumers name it differently (`CLAUDE_API_KEY` vs `CLAUDE_TOKEN`).

The `anthropics/claude-code-action` version is **hardcoded**, not an input:
`uses:` does not evaluate expressions, and making it configurable is what let
the consumers drift to v1.0.182 / v1.0.154 / v1.0.134 in the first place.

The member gate is inlined here rather than kept as its own reusable workflow.
A relative `uses:` inside a reusable workflow resolves against the *caller's*
repo, not this one, so splitting it would mean every consumer either hosting a
copy of the gate or this file hard-coding its own `iXsystems/…@ref` — one file
is simpler than either.

## Adoption status

| Repo | `check-ticket.yml` | `claude-review.yml` |
|---|---|---|
| `truenas/webui` | adopted | migrating |
| `iXsystems/truenas-ui-components` | adopted | migrating |
| `truenas-connect/ui` | migrating | migrating |

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

If that becomes too sharp an edge, the alternative is tagging: cut `v1`, move
callers to `@v1`, and release with `git tag -f v1 && git push -f origin v1`.
That was the original intent, but with only three consumers and one team it was
judged more ceremony than it buys.
