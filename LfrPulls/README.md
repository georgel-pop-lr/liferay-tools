# LfrPulls

Follow a change along the road it travels. Every team reviews its own pulls on
its own liferay-portal fork, and `ci:forward` then sends them to the Brian CI
mirror to be merged, so bare `lfrPulls` shows all three queues at once: yours on
the mirror, your team's fork narrowed to what concerns you, and your own fork,
where teammates open the pulls waiting on your review. Beyond that, list any team's or any user's fork, look up
every pull ever opened for one ticket, and count what you have sent, merged, and
had rejected per month.

## Commands

- `lfrPulls` (alias `lfrp`) — the three queues, in the order a change travels
  them: the mirror (yours), your team's fork (`LFR_PULLS_TEAM`), and your own
  fork. The team fork is the one carrying everybody, so it is narrowed to the
  pulls you wrote, the ones `ON YOU` speaks for, and the ones with no workflow
  label at all, since an untriaged pull is itself worth seeing. The count line
  still gives the section total, and `lfrPulls <team>` lists every one.
Anywhere `mine` is accepted a GitHub login works in its place and asks the same
question about that person: `lfrPulls stats nikki-pru`,
`lfrPulls week 30 nikki-pru`, `lfrPulls page-management achaparro`,
`lfrPulls ee mariuo`. `ON YOU` keeps answering for you, so it still says what a
pull of theirs needs from you. The one exception is `lfrPulls [mine|all]`, where
a bare word already names a fork: `lfrPulls <login>` lists that person's fork,
and their mirror pulls come from `lfrPulls stats <login>`.

- `lfrPulls [mine|all]` — the mirror alone. Yours by default (`mine`); `all`
  shows every open PR. `-m`/`--mine` and `-a`/`--all` work too.
- `lfrPulls <team|user|owner/repo> [mine|all|<login>]` (also
  `lfrPulls team ...`, alias `lfrpf`) — the open pulls on one fork, all of them
  by default. A second word keeps one person's: `mine`, or any login, so
  `lfrPulls page-management achaparro` asks the same question about somebody
  else. A first word carrying a slash is a whole `owner/repo` and is used as it
  stands, which is how any other repo is reached
  (`lfrPulls liferay/liferay-portal-ee mariuo`). The slash is never required:
  without one the word is an owner and the repo is `liferay-portal`
  (`LFR_PULLS_FORK_REPO`), since a bare word cannot be told apart from a team or
  a login. Name a team in full (`liferay-frontend`), without the prefix
  (`frontend`), or by any unique part of it (`experience`, `page`, `headless`);
  a name matching no team is used as a GitHub username, so `lfrPulls achaparro`
  lists their fork.
- `lfrPulls ee [mine|all|<login>]` (alias `lfrpe`) — backports on
  `liferay/liferay-portal-ee`, yours by default since everybody's backports share
  that one repo.
- `lfrPulls teams` (alias `lfrpteams`) — the product teams with each one's open
  pull count.
- `lfrPulls ticket <TICKET>` (`t`, alias `lfrpt`) — every pull ever opened for one
  ticket, oldest first, then what that ticket has landed on the master ref. A bare
  ticket is the same thing: `lfrPulls LPD-12345`.
- `lfrPulls week [days] [<login>]` (`w` or `recent`, alias `lfrpw`) — your pulls
  closed in the last `days` (default 7, reading at most 200 closed PRs), as
  PR / SENDER / STATUS / TITLE, where STATUS is `MERGED` or `REJECTED`.
- `lfrPulls stats [mine|all|<login>] [months]` (`s` or `st`, alias `lfrps`) —
  per-month counts of PRs sent, merged, and rejected, with a TOTAL row. Yours by
  default, or one person's when you name a login;
  months default to 12 (reading at most your last 500 PRs).

```bash
lfrPulls               # the mirror (yours), your team's fork (narrowed), your own fork
lfrPulls mine          # the mirror alone, PRs from your fork or opened by you
lfrPulls all           # every open PR on the mirror
lfrPulls frontend      # every open PR on liferay-frontend/liferay-portal
lfrPulls headless mine # ...only the ones you opened there
lfrPulls page-management achaparro       # ...only one person's
lfrPulls liferay/liferay-portal-ee mariuo # another repo, spelled with a slash
lfrPulls achaparro     # a person's fork, same columns
lfrPulls ee            # your backports on liferay/liferay-portal-ee
lfrPulls ee all        # everybody's
lfrPulls ee mariuo     # one person's
lfrPulls teams         # the teams, with each one's open count
lfrPulls LPD-75909     # every pull for that ticket, and what landed
lfrpt LPD-75909        # same, via the alias
lfrPulls week          # your pulls closed in the last 7 days, with status
lfrPulls week 14       # ...in the last 14 days
lfrPulls week 30 nikki-pru # ...somebody else's
lfrPulls stats         # your PRs per month, last 12 months
lfrPulls stats all 6   # whole-repo PRs per month, last 6 months
lfrPulls stats nikki-pru   # their month table, then their four queues
lfrPulls --help
```

Each row of the mirror list is the PR number, the source fork owner or author
(`sender`), the `AHEAD` count, the `STATUS`, and the title. `AHEAD` is how many
open pulls are older (lower number) than this one, i.e. roughly how many are in
front of it in the merge queue, so a small number means yours is close to being
merged. The list ends with a `Last active:` footer showing when the repo last
processed a pull (merged or rejected) and how long ago, so you can tell whether
Brian is active right now. A fork list drops `AHEAD`, which only means something
on the merge queue, and carries `ASSIGNEE` instead.

## STATUS

`STATUS` is read off the pull itself, from GitHub's `mergeable`, its review
decision, its assignees, and its labels. It is deliberately not a lookup of one
team's label names, because every fork keeps its own vocabulary: Page Management
writes `🛠 Changes needed` and `⚠️ Merge conflict` where Core Infra writes
`Merge Conflicts` and Frontend writes `🛑 Missing Tests`. The two labels that do
mean the same thing everywhere, `pr-check - failure` and `ci:forward`, are read
by name. Worst news wins:

| STATUS | meaning |
| --- | --- |
| `CONFLICT` | GitHub reports it `CONFLICTING`, or a conflict label is on it |
| `DRAFT` | opened as a draft |
| `CHANGES` | changes requested, by review or by label |
| `CHECK-FAIL` | carries `pr-check - failure` |
| `ON-HOLD` | on hold, blocked, or waiting for something |
| `READY` | approved, ready to merge, ready to forward, QA passed |
| `IN-REVIEW` | review in progress, or somebody is assigned to it |
| `REVIEW` | review needed or requested, and nobody has taken it |
| `FORWARDED` | `ci:forward` is on it, so it is on its way to the mirror |
| `TEST-FAIL` | a `ci:test` batch is red and nothing above applies |
| `OPEN` | none of the above |

`TEST-FAIL` sits at the bottom on purpose. Ranked next to `CHECK-FAIL` it swamped
everything: 43 of the 44 open EE backports carry some red `ci:test` batch, so the
column read `TEST-FAIL` 41 times out of 44. Demoted, the same list reads 22
`ON-HOLD`, 20 `IN-REVIEW`, 2 `CONFLICT`.

## ON YOU

`ON YOU` answers the only question a dashboard is for: is this waiting on me.

| value | meaning |
| --- | --- |
| `you` | you are the assignee or the requested reviewer; a pull of yours came back `CONFLICT`, `CHANGES`, `CHECK-FAIL`, `TEST-FAIL` or `ON-HOLD`; somebody opened it on your own fork, which is a review request by construction; or it is conflicting with nobody assigned, so it goes nowhere until someone picks it up |
| `ask` | a pull **of yours** is conflicting and somebody else is already reviewing it. Yours to rebase, but a force push under a review in progress destroys that review, so ask the person in `ASSIGNEE` first. A conflicting pull you neither wrote nor were assigned is not yours to touch, and reads `-` |
| `review` | review needed and nobody has taken it, so it is free for you |
| `-` | nothing for you to do |

`ask` and `review` and the unclaimed half of `you` only fire on a queue of your
own: your fork, your team's fork, the mirror, the EE repo. You review unassigned
pulls from your own team, not from other teams, so on another team's fork an
unclaimed pull stays `-`. The one exception is a review requested from you
personally, which shows `you` wherever it is, because that is the case where
another team did ask.

`ask` is decided on assignees alone, never on review requests. A request sitting
on the team account (`liferay-page-management`) means nobody has taken it and
there is no one person to ask, so such a pull of yours reads `you`, not `ask`.

## Teams

A team is a real GitHub account that owns code in `.github/CODEOWNERS`, and it
owns the fork where that team reviews. They are not GitHub organizations and not
GitHub teams, so there is no membership to query; the list lives in
`_LFR_PULLS_TEAMS` in `lfr-pulls.sh`, and `lfrPulls teams` re-reads CODEOWNERS
from your local clone and names anything the list is missing.

`liferay-ac`, `liferay-appsec`, `liferay-bpm`, `liferay-commerce`,
`liferay-content-management`, `liferay-core-infra`, `liferay-database-infra`,
`liferay-devtools`, `liferay-frontend`, `liferay-headless`,
`liferay-page-management`, `liferay-platform-experience`, `liferay-release`,
`liferay-search`, `liferay-site-management`.

Note that most people forward from a personal fork rather than the team account,
so the mirror's `SENDER` is usually a person and cannot be read as a team.

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

After the month table, `stats` prints the same three queues bare `lfrPulls`
shows, in full (following the login when you named one): each pull's age and its own workflow labels alongside the
`STATUS`. `stats all` also widens the team fork section back to every pull. The compact list answers "where is it stuck"; the detailed one answers
"how long has it been stuck and what does the team's own label say".

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
  fork (`LFR_PULLS_MINE_ORG`, your own login by default).
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
- `LFR_PULLS_MINE_ORG` — the owner in the `-sender-<owner>` of a pull you
  forwarded, so your own fork. Defaults to your login, which is what a personal
  fork carries; set it only if you forward from an org fork.
- `LFR_PULLS_TEAM` — your team's account, whose fork is the second section
  (defaults to `LFR_GIT_FORK_ORG` from LfrGit, which already holds it).
- `LFR_PULLS_USER` — your GitHub login (defaults to the `gh`-authed user).
- `LFR_PULLS_FORK_REPO` — the repo an owner with no slash means (defaults to
  `liferay-portal`, the name part of `LFR_PULLS_REPO`). Pass `owner/repo` to a
  listing to override it once.
- `LFR_PULLS_EE_REPO` — where backports go (default
  `liferay/liferay-portal-ee`), the fourth section and `lfrPulls ee`.
- `LFR_PULLS_MASTER_REPO` — local clone to grep for merges (defaults to the
  current repo). Set it so `stats mine`, `week`, and `ticket`'s landing footer
  work from any directory (`stats all` needs no clone).
- `LFR_PULLS_LINKS` — `on`, `off`, or `auto` (default). Each `#number` is a
  clickable link to its pull, carried in an OSC 8 escape so the visible text
  stays `#12345` and no column grows. On a terminal by default, plain whenever
  the output is piped or redirected; `on` forces it through a pipe, `off`
  disables it. Click or ctrl-click the number.
- `LFR_PULLS_MASTER_REF` — master ref to grep (default `brian/master`), used by
  the same three.
