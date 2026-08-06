# LfrPulls

List open pull requests on the Brian CI mirror repo (or any repo you point it
at), showing only yours by default or all of them, look up every pull ever opened
for one ticket, and count what you have sent, merged, and had rejected per month.

## Commands

- `lfrPulls [mine|all]` (alias `lfrp`) — list open PRs. Yours by default
  (`mine`); `all` shows every open PR. `-m`/`--mine` and `-a`/`--all` work too.
- `lfrPulls ticket <TICKET>` (`t`, alias `lfrpt`) — every pull ever opened for one
  ticket, oldest first, then what that ticket has landed on the master ref. A bare
  ticket is the same thing: `lfrPulls LPD-12345`.
- `lfrPulls week [days]` (`w` or `recent`, alias `lfrpw`) — your pulls closed in
  the last `days` (default 7, reading at most 200 closed PRs), as
  PR / SENDER / STATUS / TITLE, where STATUS is `MERGED` or `REJECTED`.
- `lfrPulls stats [mine|all] [months]` (`s` or `st`, alias `lfrps`) — per-month
  counts of PRs sent, merged, and rejected, with a TOTAL row. Yours by default;
  months default to 12 (reading at most your last 500 PRs).

```bash
lfrPulls               # open PRs from your fork or opened by you
lfrPulls all           # every open PR on the repo
lfrPulls LPD-75909     # every pull for that ticket, and what landed
lfrpt LPD-75909        # same, via the alias
lfrPulls week          # your pulls closed in the last 7 days, with status
lfrPulls week 14       # ...in the last 14 days
lfrPulls stats         # your PRs per month, last 12 months
lfrPulls stats all 6   # whole-repo PRs per month, last 6 months
lfrPulls --help
```

Each row of the open list is the PR number, the source fork owner or author
(`sender`), the `AHEAD` count, and the title. `AHEAD` is how many open pulls are
older (lower number) than this one, i.e. roughly how many are in front of it in
the merge queue, so a small number means yours is close to being merged. The list
ends with a `Last active:` footer showing when the repo last processed a pull
(merged or rejected) and how long ago, so you can tell whether Brian is active
right now.

## One ticket's pulls

`lfrPulls ticket` searches the repo for pulls with the ticket in the title (any
state, up to 200) and prints PR / SENDER / STATE / CREATED / CLOSED / TITLE oldest
first, so a ticket's resend history reads top to bottom. `STATE` is what GitHub
reports, `OPEN` or `CLOSED`, and the footer counts each.

It deliberately does **not** label a pull merged. Brian's merge rebases, so a
pull's commits land under different SHAs (`eee3690` became `b13f864` on
LPD-99386), which leaves the subject as the only thing to match, and a ticket's
resends all carry the same title, so every one of them would come out "merged".
What is answerable is whether the ticket landed at all, which is the footer:

```
18 pull(s) for LPD-75909: 0 open, 18 closed.
LPD-75909 on brian/master: 10 commit(s) landed, newest first.
  d9e362488888f  2026-07-29  LPD-75909 Easy to read
  ...
```

The dates tell you which resend Brian took. When nothing matches, the footer
prints the ref's tip date too, so you can see whether the ticket really has not
landed or your mirror is just behind (`lfrGitUpdateMaster`).

The search is GitHub's title search, which tokenizes, so `LCD-52771` also finds a
pull titled `LCD 52771 2`. That is wanted (those are the same ticket's pulls,
titled sloppily), and the footer's `git log --grep` accepts the same variants, so
both halves of the output agree.

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

The open list counts a PR as yours if either matches. `week` and `stats mine`
are narrower: they query GitHub by author only (`LFR_PULLS_USER`), so pulls
forwarded by the CI bot from your fork do not appear in them, and their SENDER
column can only ever show your own login.

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
  current repo). Set it so `stats mine`, `week`, and `ticket`'s landing footer
  work from any directory (`stats all` needs no clone).
- `LFR_PULLS_MASTER_REF` — master ref to grep (default `brian/master`), used by
  the same three.
