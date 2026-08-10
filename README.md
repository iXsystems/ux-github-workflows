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

| Repo | `check-ticket` | `check-member` | `prepare` |
|---|---|---|---|
| `truenas/webui` | adopted | migrating (`main.yml`) | migrating |
| `iXsystems/truenas-ui-components` | adopted | n/a — no self-hosted runner | migrating |
| `truenas-connect/ui` | adopted | migrating (`main.yaml`) | migrating |

**Automatic PR review is deliberately not here yet.** Each repo keeps its own
`claude.yml` while that work is in flight; revisit sharing it once those changes
have settled.

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
