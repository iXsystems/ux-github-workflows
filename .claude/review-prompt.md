# What to look for in this repository

This repo publishes reusable GitHub Actions workflows and one composite action.
Nothing here runs on its own pull requests except CI — the files are executed in
`truenas/webui`, `truenas/api-client-ts` and `truenas-connect/ui`, which
reference them at `@master`. So anything merged is live in those repos
immediately, and a mistake surfaces as *their* CI breaking, with no pull request
of their own to explain it. Review with that blast radius in mind: the question
is not only "is this correct" but "what does this do to a caller that did not
change anything".

Read `README.md` alongside the diff. It is the contract consumers read, and a
change to an input, a default or a behaviour it documents has to land there too.

## The failure modes this repo actually has

**A silently empty expression.** GitHub resolves an undeclared `inputs.x`,
a missing secret, or a typo'd `needs.job.outputs.y` to the empty string rather
than erroring. The condition becomes falsy, the step skips, and the job is
green. CI's `check-input-refs` job covers the `inputs.*` half of this; the rest
— outputs, `env`, secrets — is yours to catch.

**A skipped job satisfying a required status check.** Anything that lets a job
skip where a caller may have marked it required reports green about work that
never happened. Note which conditions skip a job versus fail it, and whether the
skip is the intended one. `always()` where `!cancelled()` was meant belongs here
too: it pushes work through after someone cancelled the run.

**A gate that fails open.** The review gate, `check-member`, the ticket and
title checks: when the lookup errors, the payload is missing, or the output is
unparseable, the safe answer is the one that does not report "checked". A
reviewer that crashed must not read as a reviewer that found nothing.

**Reusable-workflow semantics that differ from an ordinary workflow.** A
relative `uses:` inside a reusable workflow resolves against the *caller's*
repository, not this one. Secrets are not inherited unless declared or passed.
The caller's `permissions:` block is the ceiling for the whole call. `uses:`
does not evaluate expressions, so a version cannot be an input. Nesting is
capped at four levels.

**Untrusted input reaching a shell.** `${{ github.event.pull_request.title }}`,
branch names, comment bodies and similar interpolate into a `run:` block
verbatim — pass them through `env:` and quote the variable instead. The same
values reaching a `gh` call or a JS template need the same care.

**Shell that keeps going after a failure.** A `run:` block continues past a
failed command unless the exit status reaches the end; a pipeline reports only
its last command. Check that a step which cannot do its job exits non-zero.

**Third-party actions.** Pinned to a version, and the pin moving is a deliberate
part of the change rather than a drive-by.

**`review/*.mjs`.** These run with plain `node` in the *caller's* workspace,
with no install step: Node built-ins and `gh`/`GH_TOKEN` only, no npm imports.
They are also on the path between a review and its verdict, so an unhandled
throw is a failed job in three repos.

## Where to be quiet

The comments in these files are unusually long on purpose — they record why
something is the way it is, often after a failure. Do not report a comment as
verbose. Do report one that no longer describes the code under it.

This repo's style is one way of doing a thing rather than a configurable choice,
and inputs are added when a caller genuinely differs. "This could be an input"
is not a finding on its own.
