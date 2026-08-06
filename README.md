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
    uses: iXsystems/ux-github-workflows/.github/workflows/check-ticket.yml@v1
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

This one is **policy, not just plumbing.** Only `truenas/webui` requires tickets
today; `iXsystems/truenas-ui-components` deliberately treats the ticket prefix
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
would pick up unreviewed changes on every push to every consumer at once.
