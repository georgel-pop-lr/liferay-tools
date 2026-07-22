# LfrPulls

List open pull requests on the Brian CI mirror repo (or any repo you point it
at), showing only yours by default or all of them.

## Commands

- `lfrPulls` (alias `lfrp`) — list open PRs. Yours by default; `all` shows every
  open PR.
- `lfrPulls week [days]` — your pulls closed in the last `days` (default 7), as
  PR / SENDER / STATUS / TITLE, where STATUS is `MERGED` or `REJECTED`.
- `lfrPulls stats [mine|all] [months]` — per-month counts of PRs sent, merged,
  and rejected, with a TOTAL row. Yours by default; months default to 12.

```bash
lfrPulls              # open PRs from your fork or opened by you
lfrPulls all          # every open PR on the repo
lfrPulls week         # your pulls closed in the last 7 days, with status
lfrPulls week 14      # ...in the last 14 days
lfrPulls stats        # your PRs per month, last 12 months
lfrPulls stats all 6  # whole-repo PRs per month, last 6 months
lfrPulls --help
```

Each list row is the PR number, the source fork owner or author (`sender`), the
`AHEAD` count, and the title. `AHEAD` is how many open pulls are older (lower
number) than this one, i.e. roughly how many are in front of it in the merge
queue, so a small number means yours is close to being merged. The list ends
with a `Last active:` footer showing when the repo last processed a pull (merged
or rejected) and how long ago, so you can tell whether Brian is active right now.

## Statistics

`stats mine` counts the PRs you opened directly on the repo, by month:

- `SENT` — PRs you created that month.
- `MERGED` — of those closed that month, the ones whose exact title is a commit
  on the master ref (Brian merged that pull in).
- `REJECTED` — closed that month whose title is NOT on master (just closed).

The `TOTAL` row sums each column. A row's `SENT` need not equal
`MERGED + REJECTED`: some PRs are still open, and merged/rejected are counted by
close month while sent is counted by create month.

`stats all` shows only `SENT` and `CLOSED` for the whole repo (it cannot
title-match every PR).

### Why title-matching, not the GitHub merge flag

On the mirror your PRs are always closed, never GitHub-merged (the integration
to master is done under the CI bot's account, and the commits are rebased so
their SHAs change). So neither the GitHub merge flag nor commit-SHA reachability
identifies your merges. Instead, `stats mine` and `week` decide merged vs
rejected by matching each PR's exact title against the commit subjects on
`LFR_PULLS_MASTER_REF` (default `brian/master`). Matching the whole title, not
just the ticket, means a superseded resend of a ticket whose other work merged
still counts as rejected. Keep the ref fetched (e.g. `lfrGitUpdateMaster`).

Limitation: if Brian reworded the commit subject, or a pull's work landed under
a different subject, title-matching undercounts merges (shows rejected). Recent
work matches well; older months may read low on `MERGED`.

## How "yours" works

A PR on the mirror is either forwarded by the CI bot or opened directly:

- **Forwarded** — the author is the bot, and the head branch encodes the source
  fork owner as `...-sender-<owner>`. `lfrPulls` matches that owner against your
  fork (`LFR_PULLS_MINE_ORG`).
- **Direct** — the author is you, with a plain head branch. `lfrPulls` matches
  the author against your login (`LFR_PULLS_USER`).

A PR counts as yours if either matches.

## Config

Per-user settings live in `lfr-pulls.local.conf` (gitignored). Copy the example
and edit it:

```bash
cp lfr-pulls.local.conf.example lfr-pulls.local.conf
```

- `LFR_PULLS_REPO` — repo to list (default `brianchandotcom/liferay-portal`).
- `LFR_PULLS_MINE_ORG` — your fork owner (defaults to `LFR_GIT_FORK_ORG`). Use
  your team fork org, or your GitHub login if you forward from a personal fork.
- `LFR_PULLS_USER` — your GitHub login (defaults to the `gh`-authed user).
- `LFR_PULLS_MASTER_REPO` — local clone to grep for merges (defaults to the
  current repo). Set it so `stats` works from any directory.
- `LFR_PULLS_MASTER_REF` — master ref to grep (default `brian/master`).
