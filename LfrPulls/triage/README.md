# lfrPullsTriage

This tool assigns a reviewer to each open pull request that has no reviewer.
It works on a Liferay team repository. The default repository is
`liferay-page-management/liferay-portal`. In this team, the reviewer is the
pull `assignee`, not a requested reviewer.

`triage.py` does all the steps. It has two modes:

- The plan mode reads GitHub, Jira, and the master clone. It prints a report and
  writes `plan.json`. It writes nothing on GitHub or Jira.
- The apply mode reads `plan.json`, checks each pull again, and does the writes.
  `lfrPullsTriage` runs it only after you answer `y`. Before that, you can
  keep, change (`--reviewer PULL=LOGIN`), or skip (`--skip PULL`) each pull.
  At the prompt, `s` skips the pull and goes to the next one.

`lfrPullsTriage -h` has the procedure and the arguments. This file tells how
the script selects a reviewer.

The tool comes from a teammate (`my-review-triage`). This copy has these
changes: the script, the plan and apply modes, the fixes in "Changes from the
original" below, and STE text.

## Files

| File | Content |
|---|---|
| `triage.py` | The plan mode and the apply mode. |
| `../lfr-pulls-triage.sh` | `lfrPullsTriage`: the plan, the questions for each pull, and the apply after a `y`. |
| `config.local.yaml` | The reviewers of each role (backend, frontend), the upstream repository, the master clone, and the Jira account of each reviewer. |
| `availability.local.yaml` | The reviewers that are not available, with a date or a date range. |

## Which pulls get a reviewer

A pull gets a reviewer only if all these conditions are true:

- The pull is open and is not a draft.
- The pull has no assignee, or only the author is the assignee.
- The pull does not have one of these labels: Ready to merge, On hold, Changes
  needed, Review in progress, Wrong Team.

The script compares a label by its words only. It ignores the emoji, the case,
and the spaces. Thus `🔍 Frontend review needed` and `Frontend review needed`
are the same label.

The pool of a role comes from `config.local.yaml`. The script removes the author of
the pull and each reviewer in `availability.local.yaml` from the pool.

## Step 1. The weight of the real code

The script compares the pull branch with `upstream/master` through the GitHub
compare API. It does not use the base of the team repository. The team
repository is often behind upstream, so its diff can include upstream commits
that the author did not write. If the fork of the author is not available, the
script uses the file list of the pull, and the report says "may be inflated".

The script ignores these files:

- Files with `@generated` in the added lines, or in the first 20 lines of the
  file on upstream master.
- Lock files, `package.json`, `CHANGELOG.md`, `Language_*.properties`, files
  under `__generated__` or `.releng`.
- Images, fonts, Jest snapshots, and Poshi files (`macro`, `path`, `testcase`).

The weight is the sum of the added lines and the deleted lines of the remaining
files. If no file remains, the weight is 1 and the pull is "trivial". If the pull
has no commit that upstream does not have, the report shows it under "No New
Work vs Upstream".

## Step 2. The scope

The scope is backend, frontend, or mixed. A mixed pull gets one reviewer of each
role.

1. The script uses the scope labels first: `Backend review needed` and
   `Frontend review needed`.
2. If the pull has no scope label, the script finds the scope from the files.
   - Backend: `java`, `jsp`, `jspf`, `xml`, `properties`, `bnd`, `gradle`,
     `groovy`, `sql`, `ftl`, `vm`, `tld`, `xsd`, and `packageinfo`.
   - Frontend: `ts`, `tsx`, `js`, `jsx`, `mjs`, `cjs`, `scss`, and `css`.
   - Playwright tests and the other files count in the weight, but not in the
     scope.
3. The backend share decides the confidence. A share of 80% or more on one side
   is high. A share from 70% to 80% is medium. Other shares are mixed, with low
   confidence.
4. If the confidence is equal to or more than `--label-confidence`, the plan
   adds the label. If it is lower, the report shows the pull under "Needs Manual
   Triage".

## Step 3. A pull that replaces an earlier pull

The script does this step before the score. A pull replaces an earlier pull in
these cases:

- The title or the body has "supersedes", "replaces", "continuation of",
  "follow-up to", or "Previous pull:", then `#N` or the URL of a pull in the same
  repository.
- The branch ends with `-v2` (or a higher number) or `-redate`, and a closed pull
  of the same author on the earlier branch has the same Jira key.

The script finds the team reviewer with the most reviews and review comments on
the earlier pull. If nobody reviewed it, the script uses its assignee. If that
reviewer is in the pool, the script selects that reviewer, and the reviewer
keeps the context.

## Step 4. The score

The script calculates a score for each reviewer in the pool. The lowest score
wins.

	score = load_norm - EXPERTISE_WEIGHT * expertise

**Load.** The script calculates the load over the last 7 days:

- Each pull that the reviewer reviewed in the window counts with its weight.
  A review is a GitHub review that the reviewer submitted in the window. A
  closed pull counts too, because no pull of the team fork is merged there: it
  closes after `ci:forward`, or when a new pull replaces it.
- A pull that the reviewer superseded counts as a review too. The reviewer made
  the small changes in a new pull instead of review comments. The new pull is
  created in the window, and its title or body says "Supersedes #N" (or a verb
  of `SUPERSEDE_VERBS`) for a pull of another author.
- The weight of one pull in the load is `--weight-cap` (default 1000) or less.
  Without the cap, one review of a very big pull made almost all the load of a
  reviewer: #19267 had a weight of 4255.
- Each open pull that is assigned to the reviewer counts with less weight each
  day. The factor is `e^(-days/3)`, and the days start at the last "assigned"
  event of the reviewer. Thus a pull that waits for many days adds almost no
  load, and a fast reviewer does not get more work than a slow reviewer.
  If the reviewer also reviewed the pull in the window, the pull counts only as
  completed, not two times.
- The script divides the load by the median load of the role (`load_norm`). A
  value of 1.0 is the typical load. The median prevents a large change of the
  scale when one reviewer has a very high load.

The report also shows the velocity: the completed reviews divided by the open
pulls. The velocity does not change the selection.

**Expertise.** The expertise is a value from 0 to 1. It has two signals, 50% each:

- Blame. The script runs `git blame` on the changed hunks, at the merge base of
  the pull, in the master clone. The merge base is the commit that the hunk line
  numbers come from. It blames files with 5 or more changed lines. It finds the
  reviewer of a line from the commit email. It reads the commit emails of each
  reviewer from GitHub and keeps them for 30 days in
  `~/.cache/pr-review-triage/emails.json`.
- Story. The script reads the Jira ticket of the title, its parent, and the other
  children of the parent. A story hit is a team pull of one of these tickets
  where the reviewer is the assignee.

**Ties.** If two scores are 0.05 or less apart, the lower load wins.

**Balance in one plan.** After each selection, the script adds the weight of the
pull to the load of the reviewer. Thus one plan does not give many pulls to the
same reviewer.

## Step 5. The comment

The script selects the reason in this order:

1. The pull replaces an earlier pull that the reviewer reviewed.
2. The pull is trivial: most of it is generated code.
3. The reviewer changed the same lines before (blame). The comment links the
   file line and the commit.
4. The reviewer reviewed a pull of the same story.
5. Both blame and story.
6. The load rotation of the role.

The script does not write a reason that it did not find. Each comment starts with
an `@` mention of the reviewer.

## Step 6. Apply

Apply mode does these steps for each assignment in the plan:

1. It reads the pull again. It skips the pull if the pull is closed, if the head
   commit changed, or if a reviewer outside the plan is assigned now.
2. It assigns the reviewer, adds the planned label, and posts the comment.
3. For each Jira key in the title, it assigns the ticket to the reviewer, but
   only if the status is In Review. It does not change the status.

`--print-only` shows these writes and does not do them.

After the apply, `lfrPullsTriage` asks about each pull that you assigned to
yourself: "Create a worktree with its branch? [y/N]". It asks only if GitHub
shows you as the assignee, because the apply can skip a pull. A `y` runs
`lfrWorktreePull` on the pull. That command fetches the head of the pull into a
local branch with the name of the pull branch, checks the head SHA, and runs
`lfrWorktree` (see `../../LfrRepos/README.md`).

## The report

The report has these sections:

- Assigned, with the comment of each assignment
- Supersede detected
- Needs Manual Triage
- No Eligible Reviewer
- No New Work vs Upstream
- Excluded by label
- Updated Load Per Reviewer, with the load before and after, and the velocity
- Notes: for example, a reviewer without a commit email or a failed Jira lookup

## Fit mode

`triage.py --fit LOGIN --pulls N,N` prints one line for each pull: the number,
a tab, and the fit of LOGIN as the reviewer. It uses the same scope, blame,
story, and load as the plan, and it writes nothing on GitHub or Jira. The values
are `best`, `good`, `ok`, `no-role`, and `?`. `lfrPulls` shows them in the FIT
column of the team fork, and `../README.md` tells what each value means.

The fit mode gives the pulls in the same order as the plan, oldest first, and
adds each pick to the load. Thus `best` is the pull that the plan gives to
LOGIN. If one result is missing in the cache, it scores all the pulls again.

LOGIN stays in the pool also if `availability.local.yaml` marks LOGIN as not
available, because LOGIN asks the question. The results stay in
`~/.cache/pr-review-triage/fit.json` for 12 hours, or until the head of the
pull changes.

## Changes from the original

- The weight did not count the frontend source (`ts`, `tsx`, `js`, `jsx`,
  `scss`, `css`). On #19233, a pull with only the frontend label, the old filter
  gave weight 396 and scope backend. The new filter gives weight 1058 and scope
  mixed.
- The Jira search used `/rest/api/3/search`, which returns `410 Gone`. The script
  uses `/rest/api/3/search/jql`.
- Blame ran on `HEAD` of the local clone, but the hunk line numbers come from the
  merge base. The script blames the merge base, and the plan mode does no
  `git pull`.
- The dry run could add a label. The plan mode writes nothing.
- The original expected the label `🔎 Frontend review needed`. The team label is
  `🔍 Frontend review needed`. The script compares the words only.
- The original did not say how to find the reviewer of a blamed line. The script
  uses the commit emails of each reviewer.
- New: `--explain`, the apply checks, the Jira assignment, the "Review in
  progress" and "Wrong Team" exclusions, "Previous pull:" as a supersede signal.

## Known limits

- The script does not know about an assignment that a person makes by hand after
  the plan. Run the plan again to include it.
- The last author of a line is not always the expert of the code.
- If a reviewer is on holiday and `availability.local.yaml` does not say so, the script
  can select that reviewer.
- If GitHub does not link a commit email to the account of a reviewer, blame does
  not find that reviewer. The report notes it.
- The story signal counts only the assignees of the team pulls, not the reviews.
