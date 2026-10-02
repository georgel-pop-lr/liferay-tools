# LfrPulls

Follow a change along the road it travels. Every team reviews its own pulls on
its own liferay-portal fork, and `ci:forward` then sends them to the Brian CI
mirror to be merged, so bare `lfrPulls` shows all three queues at once: yours on
the mirror, your team's fork narrowed to what concerns you, and your own fork,
where teammates open the pulls waiting on your review. Beyond that, list any team's or any user's fork, look up
every pull ever opened for one ticket, count what you have sent, merged, and
had rejected per month, and list the rejections you still owe a resend.

## Commands

- `lfrPulls` (alias `lfrp`) - the four queues, in the order a change travels
  them: the mirror (yours), your team's fork (`LFR_PULLS_TEAM`), your own fork,
  and your backports on the EE repo. The team fork is the one carrying
  everybody, so it is narrowed to the pulls you wrote, the ones `ON YOU` speaks
  for, and the ones with no workflow label at all, since an untriaged pull is
  itself worth seeing. The count line still gives the section total, and
  `lfrPulls <team>` lists every one. Directly under the mirror's own section
  comes the other half of what that repo has to say: the pulls Brian sent back
  that never landed, which is work you owe. See
  [Rejected pulls](#rejected-pulls).
Anywhere `mine` is accepted a GitHub login works in its place and asks the same
question about that person: `lfrPulls stats nikki-pru`,
`lfrPulls week 30 nikki-pru`, `lfrPulls page-management achaparro`,
`lfrPulls ee mariuo`. `ON YOU` keeps answering for you, so it still says what a
pull of theirs needs from you. The one exception is `lfrPulls [mine|all]`, where
a bare word already names a fork: `lfrPulls <login>` lists that person's fork,
and their mirror pulls come from `lfrPulls stats <login>`.

- `lfrPulls [mine|all]` - the mirror alone. Yours by default (`mine`); `all`
  shows every open PR. `-m`/`--mine` and `-a`/`--all` work too.
- `lfrPulls <team|user|owner/repo> [mine|all|<login>]` (also
  `lfrPulls team ...`, alias `lfrpf`) - the open pulls on one fork, all of them
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
- `lfrPulls ee [mine|all|<login>]` (alias `lfrpe`) - backports on
  `liferay/liferay-portal-ee`, yours by default since everybody's backports share
  that one repo.
- `lfrPulls teams` (alias `lfrpteams`) - the product teams with each one's open
  pull count.
- `lfrPulls ticket <TICKET>` (`t`, alias `lfrpt`) - every pull ever opened for one
  ticket, oldest first, then what that ticket has landed on `liferay/liferay-portal`. A bare
  ticket is the same thing: `lfrPulls LPD-12345`.
- `lfrPulls week [days] [<login>]` (`w` or `recent`, alias `lfrpw`) - your pulls
  closed in the last `days` (default 7, reading at most 200 closed PRs), as
  PR / SENDER / STATUS / TITLE, where STATUS is `MERGED` or `REJECTED`.
- `lfrPulls stats [mine|all|<login>] [months]` (`s` or `st`, alias `lfrps`) -
  per-month counts of PRs sent, merged, and rejected, with a TOTAL row. Yours by
  default, or one person's when you name a login;
  months default to 12 (reading at most your last 500 PRs).
- `lfrPulls rejected [days|all] [<login>]` (`rej` or `r`, alias `lfrpr`) - the
  pulls Brian sent back that never landed, as
  PR / CLOSED / TRIES / RESENT / WHY / TITLE. Days default 30
  (`LFR_PULLS_REJECTED_DAYS`), and `all` drops the window. The `#number` links
  to the rejection comment rather than to the pull. See
  [Rejected pulls](#rejected-pulls).

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
lfrPulls rejected      # what Brian sent back in the last 30 days and you owe
lfrPulls rejected 90   # ...in the last 90 days
lfrPulls rejected all  # ...ever, which is slow: it reads every closed pull
lfrpr                  # same, via the alias
LFR_PULLS_LINKS=off lfrPulls rejected  # a COMMENT column of URLs instead of links
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
`Merge Conflicts` and Frontend writes `🛑 Missing Tests`. The labels that do mean
the same thing everywhere, the `pr-check` family and `ci:forward`, are read by
name. Worst news wins:

| STATUS | meaning |
| --- | --- |
| `CONFLICT` | GitHub reports it `CONFLICTING`, or a conflict label is on it |
| `DRAFT` | opened as a draft |
| `CHANGES` | changes requested and still owed, by review or by label |
| `CHECK-FAIL` | carries `pr-check - failure` |
| `ON-HOLD` | on hold, blocked, or waiting for something |
| `NO-CHECK` | carries no `pr-check` label at all, so no result was ever published and it cannot be forwarded. Never on the EE repo |
| `READY` | approved, ready to merge, ready to forward, QA passed |
| `IN-REVIEW` | review in progress, or somebody is assigned to it |
| `REVIEW` | review needed or requested, and nobody has taken it |
| `FORWARDED` | `ci:forward` is on it, so it is on its way to the mirror |
| `TEST-FAIL` | a `ci:test` batch is red and nothing above applies |
| `OPEN` | none of the above |

`CHANGES` is the one word a push can take back. GitHub keeps
`reviewDecision` at `CHANGES_REQUESTED` until that same reviewer reviews again:
new commits never clear it, and neither does a `COMMENTED` review from them, so
the field goes on saying "changes requested" hours after the author has done
them and pushed. Each changes-requested review carries the commit it was made
against, so the head having moved past every one of them is the proof that the
author answered, and the pull falls through to whatever it is now (usually
`NO-CHECK`, since the push invalidated its pr-check, or `IN-REVIEW` while the
reviewer comes back to it). The label half is left alone: a person put it there
by hand and it stands until somebody takes it off. A pull with more reviews than
the API returns in one page keeps the old reading, unanswered, rather than being
cleared on missing evidence.

`NO-CHECK` sits under `CONFLICT`, `DRAFT` and `CHANGES` rather than above them,
because each of those three is fixed by pushing new commits, and that push
invalidates any pr-check taken against the old head. Asking for a pr-check first
would be asking for work that is about to be thrown away, so the conflict is the
only thing the column says; the pull falls through to `NO-CHECK` on the next run
once the rebase lands. `CHECK-FAIL` outranks it for the plainer reason that a
failure is a published result and this is the absence of one.

The EE repo is exempt through the `$prChecked` argument, since pr-check is no
part of the backport flow there: 44 of its 46 open pulls carry no such label, so
the word would say nothing. The two that do carry `pr-check - skipped`.

`TEST-FAIL` sits at the bottom on purpose. Ranked next to `CHECK-FAIL` it swamped
everything: 43 of the 44 open EE backports carry some red `ci:test` batch, so the
column read `TEST-FAIL` 41 times out of 44. Demoted, the same list reads 22
`ON-HOLD`, 20 `IN-REVIEW`, 2 `CONFLICT`.

## ON YOU

`ON YOU` answers the only question a dashboard is for: what does this pull need
from me. Every value but `-` is an action of yours. What another person owes a
pull is not in this column at all: `STATUS` says `IN-REVIEW`, `ASSIGNEE` names
them, and the census below counts them.

| value | meaning |
| --- | --- |
| `you` | a pull of yours is `CONFLICT`, `CHANGES`, `CHECK-FAIL`, `NO-CHECK`, `TEST-FAIL` or `ON-HOLD`, so it is yours to fix. A pull of yours is decided by who sent it, not by who authored it, so a forwarded one on the mirror still counts |
| `ask` | a pull **of yours** is conflicting and somebody else is already reviewing it. Yours to rebase, but a force push under a review in progress destroys that review, so ask the person in `ASSIGNEE` first |
| `on-review` | the review is on you: you are the assignee or the requested reviewer, or somebody opened it on your own fork and nobody has taken it, which is a review request to you by construction |
| `need-review` | somebody else wrote it, a review is needed and nobody has taken it, conflicting or not: free for you to take. Conflicting counts because the rebase belongs to whoever wrote it and the review does not, and `CONFLICT` outranks `REVIEW` in `STATUS`, so the takeable half would otherwise be swallowed. An on-hold pull never does, for the same swallowing read the other way: `CONFLICT` outranks `ON-HOLD` too, and a pull whose author asked for it to be left alone is not takeable |
| `-` | nothing for you to do. A pull of yours that is healthy, or waiting on a reviewer who has not turned up (somebody to chase, not an action), and any pull somebody else is reviewing |

`need-review` only fires on a queue of your own: your fork, your team's fork,
the mirror, the EE repo. You review unassigned pulls from your own team, not
from other teams, so on another team's fork an unclaimed pull stays `-`, unless
the review was requested from you by name, which shows `on-review` wherever it
is.

`ask` is decided on assignees alone, never on review requests. A request sitting
on the team account (`liferay-page-management`) means nobody has taken it and
there is no one person to ask, so such a pull of yours reads `you`, not `ask`.

## The census under each table

Every section closes on the count of the rows it printed out of the pulls it
fetched, and that count carries the breakdown behind it, with `ON YOU` and the
labels themselves under it:

```
  5 of 14 open pull(s): 4 CONFLICT, 3 CHANGES, 3 NO-CHECK, 3 IN-REVIEW, 1 REVIEW.
  on you: 1 you, 3 need-review.
  labels: 10 Backend review needed | 3 Changes needed | 1 On hold | 1 Ready to merge
```

All three count every open pull the section fetched, not only the rows its
filter kept, which is the point: the dashboard shows you 5 of the team's 14,
and the census is what says whether the 9 it hid are healthy. The first two are
ordered by the ranking their words are ranked in rather than by count, so the
worst news reads first and the line keeps its shape between runs; `on you`
leaves out `-`.

The labels line is the one that shows everything. `STATUS` keeps the worst word
per pull, so a conflicting pull that is also on hold and waiting for a backend
review is counted once there and three times here, which is what makes it easy
to see what a section is actually missing. Labels have no ranking to follow, so
this line is ordered by count and then by name, and a pull carrying no workflow
label counts as `untriaged`. The counts sum past the section total on purpose,
since a pull carries as many labels as it carries. It prints only with the
LABELS column, in `lfrPulls stats` and with `-d`: on the team fork it counts
every teammate's pulls, which buries the two lines above it in the plain view.

It is free: both are computed from the listing already fetched, so no section
makes an extra call for it.

A per-month `CONFLICT` or `NO-CHECK` column is not the same thing and is not
available. GitHub keeps no history of a pull's mergeable state or of when a
label was on it, and `mergeable` is computed live, so for a pull closed in
March there is nothing to count. The census answers the same question for the
pulls that are open now, which is where a conflict can still be acted on.

## Teams

A team is a real GitHub account that owns code in `.github/CODEOWNERS`, and it
owns the fork where that team reviews. They are not GitHub organizations and not
GitHub teams, so there is no membership to query; the list lives in
`_LFR_PULLS_TEAMS` in `lfr-pulls.sh`, and `lfrPulls teams` re-reads CODEOWNERS
from `liferay/liferay-portal` on GitHub (your local clone when that fails) and
names anything the list is missing.

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

The dates tell you which resend Brian took. The commits come from GitHub's
commit search on `LFR_PULLS_UPSTREAM_REPO` (default `liferay/liferay-portal`),
so no local clone has to be fetched. The mirror itself cannot be searched: it is
a fork, and GitHub indexes no commits in a fork. When the search fails the footer
reads the local master ref instead, says so, and prints its tip date.

The search is GitHub's title search, which tokenizes, so `LCD-52771` also finds a
pull titled `LCD 52771 2`. That is wanted (those are the same ticket's pulls,
titled sloppily), and the footer's `git log --grep` accepts the same variants, so
both halves of the output agree.

## Statistics

`stats mine` counts the PRs you sent, forwarded or opened directly, by month:

- `SENT` - PRs you created that month.
- `MERGED` - of those closed that month, the ones whose exact title is a commit
  on the master ref (Brian merged that pull in).
- `REJECTED` - closed that month whose title is NOT on master (just closed).

The `TOTAL` row sums each column. A row's `SENT` need not equal
`MERGED + REJECTED`: some PRs are still open, and merged/rejected are counted by
close month while sent is counted by create month.

`stats all` shows only `SENT` and `CLOSED` for the whole repo (it cannot
title-match every PR).

After the month table, `stats` prints the same three queues bare `lfrPulls`
shows, in full (following the login when you named one): each pull's age and its own workflow labels alongside the
`STATUS`, and under each table the census that says how many pulls sit in each
`STATUS` and whose move is next. `stats all` also widens the team fork section back to every pull. The compact list answers "where is it stuck"; the detailed one answers
"how long has it been stuck and what does the team's own label say".

### Why title-matching, not the GitHub merge flag

On the mirror your PRs are always closed, never GitHub-merged (the integration
to master is done under the CI bot's account, and the commits are rebased so
their SHAs change). So neither the GitHub merge flag nor commit-SHA reachability
identifies your merges. Instead, `stats mine` and `week` decide merged vs
rejected by matching each PR's exact title against commit subjects. Matching the
whole title, not just the ticket, means a superseded resend of a ticket whose
other work merged still counts as rejected.

`week` takes the subjects from GitHub's commit search: one search on your
commits, then one per ticket still unmatched, since a pull you forwarded can
carry a teammate's commits. It falls back to the local ref when a search fails.
`stats mine` reads `LFR_PULLS_MASTER_REF` (default `brian/master`) in the local
clone instead, fetching it first: a year of titles is around 40 searches, more
than the 30 a minute GitHub allows.

Limitation: if Brian reworded the commit subject, or a pull's work landed under
a different subject, title-matching undercounts merges (shows rejected). It is
not a corner case. Brian merges a branch's own commits, not one squashed commit
named after the pull, so a pull of more than one commit often puts no commit
named after its title on the ref at all: of the 15 pulls of mine closed in the
30 days to 2026-09-21, `week` called 11 `REJECTED`, and 3 of those carry a
"Merged. Thank you." from Brian (`#180766`, `#181746` and `#181869`). `#181746`
is the shape of it: its 13 `LPD-104558` commits all landed, each under its own
subject, and none of them is the pull's title. Counting the closing comment
instead gives 7 merged and 8 rejected over the same 15, which is what
`lfrPulls rejected` uses.

## Rejected pulls

`lfrPulls rejected` answers one question: what did Brian send back that you have
not got in yet.

A pull counts as rejected when it was closed and the last comment posted at or
before the close was neither "Merged. Thank you." nor a `ci:close` of your own.
That comment is the reason, so the `#number` links straight to it instead of to
the pull, and `WHY` carries its first line. Pipe the output, or set
`LFR_PULLS_LINKS=off`, and the URL comes back as a `COMMENT` column instead,
since an escape nobody can see is worse than a wide table.

Only the newest rejection per ticket is a row, because that is the one on you:

- `TRIES` - how many times the ticket has been sent back, which is what an older
  row would have carried.
- `RESENT` - the open pull already answering it, so a rejection still to answer
  is a row with `-` there.

A ticket whose work has since landed on `liferay/liferay-portal` drops out
entirely, which is what "still not landed" means. It is asked of GitHub's commit
search, one search per ticket, only from the oldest rejection in hand, so a
ticket that landed something *before* this pull was sent back still counts as
owed. When a search fails, the rate limit included, the section checks the local
master ref instead and says so on the count line; without one it lists every
rejection.

Bare `lfrPulls` prints this directly under the mirror's open pulls, over the
same 30 days, because both are the same repo answering the two halves of one
question: what Brian is holding, then what he sent back. It is not a queue, so
it is not one of the four, and it is skipped on `lfrPulls all`, where
"rejected" over the whole repo is every pull Brian ever turned down and says
nothing about anybody.

The window is bounded with GitHub's `updated:` qualifier and the close date is
filtered here, never with `closed:`, which is wrong on this repo. Measured
2026-09-21 against the unbounded listing: `closed:>=2026-06-01` returned 34 of
the 48 pulls that actually closed in that window, and `closed:>=2026-08-01`
returned 0 of 6. `updated:` returned exactly the 6 over 30 days and a complete
superset (81 for 48) over four months, since closing a pull updates it.

## How "yours" works

A PR on the mirror is either forwarded by the CI bot or opened directly:

- **Forwarded** - the author is the bot, and the head branch encodes the source
  fork owner as `...-sender-<owner>`. `lfrPulls` matches that owner against your
  fork (`LFR_PULLS_MINE_ORG`, your own login by default).
- **Direct** - the author is you, with a plain head branch. `lfrPulls` matches
  the author against your login (`LFR_PULLS_USER`).

Every command counts a PR as yours if either matches: the four listings, `week`,
`stats mine`, and the `ON YOU` column with it, so a forwarded pull of yours that
comes back red says `you` like a direct one.

Matching the forwarded half needs a fetch GitHub cannot filter, since no search
qualifier indexes a head branch (`head:` wants the exact name). The open list has
all 40 open pulls in hand anyway, so it filters them locally. `week` and `stats`
would have to page over months of the mirror to do that, so they lean on the
mention instead: the forwarder writes `@<sender>` into the pull body, so
`mentions:<login>` narrows the fetch to a few hundred pulls, and the
`-sender-<owner>` suffix then decides exactly which of them are that person's.
Sampled across 2026-01 to 2026-09, every forwarded pull of Georgel's was in its
`mentions:` set.

Until 2026-09-04 these two queried by author alone, which hid every forwarded
pull: `week 21` showed 1 pull instead of 6, and `stats mine 6` counted 53 sent
where the real number was 97.

## Config

Per-user settings live in `lfr-pulls.local.conf` (gitignored). Copy the example
and edit it:

```bash
cp lfr-pulls.local.conf.example lfr-pulls.local.conf
```

- `LFR_PULLS_REPO` - repo to list (default `brianchandotcom/liferay-portal`).
- `LFR_PULLS_MINE_ORG` - the owner in the `-sender-<owner>` of a pull you
  forwarded, so your own fork. Defaults to your login, which is what a personal
  fork carries; set it only if you forward from an org fork.
- `LFR_PULLS_TEAM` - your team's account, whose fork is the second section
  (defaults to `LFR_GIT_FORK_ORG` from LfrGit, which already holds it).
- `LFR_PULLS_USER` - your GitHub login (defaults to the `gh`-authed user).
- `LFR_PULLS_FORK_REPO` - the repo an owner with no slash means (defaults to
  `liferay-portal`, the name part of `LFR_PULLS_REPO`). Pass `owner/repo` to a
  listing to override it once.
- `LFR_PULLS_EE_REPO` - where backports go (default
  `liferay/liferay-portal-ee`), the fourth section and `lfrPulls ee`.
- `LFR_PULLS_UPSTREAM_REPO` - the repo whose GitHub commit search says what
  landed (default `liferay/liferay-portal`), for `rejected`, `week`, `ticket`'s
  landing footer, and `teams`' CODEOWNERS.
- `LFR_PULLS_MASTER_REPO` - local clone to grep for merges (defaults to the
  current repo). `stats mine` needs it; the others use it only when the GitHub
  search fails. Set it so they work from any directory.
- `LFR_PULLS_LINKS` - `on`, `off`, or `auto` (default). Each `#number` is a
  clickable link to its pull, carried in an OSC 8 escape so the visible text
  stays `#12345` and no column grows. On a terminal by default, plain whenever
  the output is piped or redirected; `on` forces it through a pipe, `off`
  disables it. Click or ctrl-click the number. In `rejected` the number links
  to the rejection comment, and `off` prints those URLs as a `COMMENT` column
  rather than dropping them.
- `LFR_PULLS_COLOR` - `on`, `off`, or `auto` (default). In the open-pulls
  tables a pull of yours, or one whose `ON YOU` asks something of you, is
  bright white, and every other row is light grey. Same rule as the links: a
  terminal by default, plain when piped, and `NO_COLOR` turns it off unless
  this says `on`.
- `LFR_PULLS_REJECTED_DAYS` - how far back `rejected` looks, and the fifth
  section of bare `lfrPulls` with it (default 30).
- `LFR_PULLS_MASTER_REF` - master ref to grep (default `brian/master`), which
  `stats mine` fetches before counting.
