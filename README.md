# ux-github-workflows

Shared CI workflows for the TrueNAS Angular front-ends:

| Repo | Org |
|---|---|
| [`truenas/webui`](https://github.com/truenas/webui) | truenas |
| [`iXsystems/truenas-ui-components`](https://github.com/iXsystems/truenas-ui-components) | iXsystems |
| `truenas-connect/ui` | truenas-connect |

## This repository must stay public

The three consumers live in three different GitHub organisations, and there is
no single enterprise account spanning them. Reusable workflows in a **private**
repo cannot be called across orgs at all; **internal** requires a shared
enterprise. Public is the only option that works for all three, and public
reusable workflows can be called from private repos, so `truenas-connect/ui`
is covered.

Consequence: **nothing secret goes in this repo.** Secrets stay in each
consumer repo and are passed in by name at the call site.

## Workflows

### `check-ticket.yml`

Fails a PR whose title does not reference an uppercase `NAS-nnnnn` ticket. No
inputs, no secrets — the same rule for every repo that opts in.

```yaml
on:
  pull_request:
    types: [opened, edited, reopened, synchronize]

jobs:
  check-ticket:
    uses: iXsystems/ux-github-workflows/.github/workflows/check-ticket.yml@v1
```

Callers own their `on:` trigger — a reusable workflow has no say in what
triggers its caller.

This is a **policy**, not just plumbing: only `truenas/webui` requires tickets
today. `iXsystems/truenas-ui-components` deliberately treats the ticket prefix
as optional (see its `pr-title.yml`), and `truenas-connect/ui` has no PR-title
check at all. Adopt it only where the team has agreed to require tickets.

## Adoption status

| Repo | `check-ticket.yml` |
|---|---|
| `truenas/webui` | migrating (first adopter) |
| `iXsystems/truenas-ui-components` | n/a — tickets optional there |
| `truenas-connect/ui` | n/a — no PR-title check |

## Releasing

Callers pin `@v1`, so a change reaches them only when the tag moves:

```bash
git tag -f v1 && git push -f origin v1
```

Land the change on `master`, verify it against the first adopter's next PR, then
move the tag. For a breaking input change, cut `v2` and migrate callers one at a
time instead.

Tags are the release surface here, not branches — a caller pinned to `@master`
would pick up unreviewed changes on every push to three repos at once.
