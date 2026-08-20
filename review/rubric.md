# Severity and reporting

`claude-review.yml` appends this file to the calling repository's own
review prompt, after it. That split is deliberate: the repo's file says what to
look for in *its* code, and this one says how to grade and report whatever the
review finds.

It lives next to the gate that reads the result — `check-review-threshold.mjs`
fails the job at MEDIUM and above, and `schema.json` fixes the four severity
names. A repo that carried its own copy of this could drift from either, and
the drift would show up as a check that passes or fails for reasons nobody
wrote down. Change these rules here and every consumer moves together.

## Severity

Assign every finding a severity. Work down this list; the first `yes` sets it.
Do not revise a severity upward because the finding feels serious, or because
the list looks short.

1. Can you name a concrete input, sequence, or environment under which this
   produces a wrong result, throws, or fails to build?
     - on a path a caller would normally take          -> BLOCKER
     - only under specific conditions                  -> HIGH

2. Does the *executable* change assert something untrue? A type that
   contradicts what the value can be; a public API, CLI, protocol, or test
   guarantee nothing enforces; a test that cannot fail or that certifies the
   wrong walk.
   Comments, commit messages, internal docs, and CI annotation text that
   disagree with the code beside them are not this. They are LOW. A sentence
   a compiler never saw does not hold a merge.         -> MEDIUM

3. Does it leave a *mechanism* that will silently stop working the next time
   someone does an ordinary thing to this repo — a regeneration, a dependency
   bump, a routine refactor?
   A stale comment that might mislead a future editor is not this. A CI step
   that still fails the job but with a worse error message is not this.
                                                       -> MEDIUM

4. Otherwise                                           -> LOW

**If you cannot state the failing input for 1, or quote the untrue executable
claim for 2 or 3, the finding is LOW.** A comment is not that claim. Severity
requires the specific thing that makes it severe, not a description of the
risk.

Pre-existing product behaviour that a test or coverage PR merely discovered
is not a finding on that PR. File an issue.

A finding whose only harm is "a future reader might remove a nearby guard"
is LOW. The guard is still there.

Reporting no findings is a valid and useful result. Do not manufacture a
finding, or raise one's severity, to demonstrate thoroughness.

## Saying the severity out loud

Every finding you write states its severity, in the comment as well as in the
structured output. In the comment, open it with the level in bold caps, then
the finding (in the structured output the `severity` field already carries it,
so `summary` stays plain — it is rendered into a CI annotation that is already
prefixed with the level):

> **MEDIUM** — `TestParseFlag` asserts that an empty argument errors;
> `parseFlag` returns a default and nil. The test certifies the wrong walk.

That applies to inline comments and to the top-level comment alike. A reader
should be able to tell a BLOCKER from a LOW without inferring it from how
strongly the sentence is worded, and without cross-referencing the CI
annotations to find out.

Two things follow from it:

- **Say the level even when it is LOW.** An unlabelled finding reads as more
  serious than a labelled LOW, which is the opposite of what you want.
- **The label and the structured output must agree.** They are the same
  judgement written twice, and the gate keys off one of them. If you find
  yourself wanting to write a different level in the prose, the rubric decides
  and both change together.

## The opening line must agree with the findings under it

**The check fails on any finding at MEDIUM or above.** So whether the set is
blocking is not a matter of tone — it is decided, and you already decided it
when you assigned the severities.

Open with the count by level, and nothing softer:

> Three findings: one MEDIUM, two LOW.

Do not write "none blocking", "all minor", "nothing serious" or "non-blocking"
over a set containing a MEDIUM, HIGH or BLOCKER. That sentence is a claim about
the gate, it is checkable, and it will be checked — a summary saying nothing
blocks above a red check tells the reader the check is broken when it is
working exactly as specified.

The reverse matters too. Do not hedge a genuinely clean review into sounding
qualified: if there are no findings, or only LOW ones, say so plainly, because
that is the result that lets someone merge.

## Machine-readable summary

Return your findings as structured output matching the JSON schema this run was
started with — severity, file, line, and a one-line summary with no markdown.
The severity enum is enforced by the schema, so it can only be one of the four
above.

Include every finding, LOW ones too. An empty array is valid and expected on a
clean change; it is not a sign the review failed.

The structured output is what tooling reads and the comment is what a human
reads, so they differ in form — prose and reasoning there, one flat line here.
They must not differ in content: every finding appears in both, at the same
severity. A finding that only appears in the comment does not reach the gate.
