# lfr-pulls.sh - list open pull requests along the road a change travels.
#
# Source this from your shell rc (normally via the root lfrTools.sh). It defines:
#     lfrPulls           the four queues a pull of yours passes through, and
#                        the rejections off the first of them
#     lfrPulls stats     per-month counts of PRs sent, merged, and rejected
#     lfrPulls rejected  the pulls sent back that never landed, and why
#
# A change is reviewed on its team's own liferay-portal fork, then ci:forward
# sends it to the Brian CI mirror to be merged, so bare `lfrPulls` shows all
# three queues at once: yours on the mirror, your team's fork, and your own fork
# (where teammates open the pulls waiting on your review). A backport skips that
# road and is opened on the EE repo, which is the fourth section.
#
# A PR on the mirror repo is either forwarded by the CI bot (author is the bot,
# head branch encodes the source fork owner as `...-sender-<owner>`) or opened
# directly (author is you, plain head branch). "Yours" matches either: a
# forwarded PR from your fork (LFR_PULLS_MINE_ORG, default your own login), or
# a direct PR authored by you (LFR_PULLS_USER, default the gh-authenticated user).
#
# Per-user settings live in lfr-pulls.local.conf next to this file. It is
# gitignored. Copy lfr-pulls.local.conf.example to lfr-pulls.local.conf.

_lfrPullsDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "${_lfrPullsDir}/lfr-pulls.local.conf" ] && . "${_lfrPullsDir}/lfr-pulls.local.conf"

: "${LFR_PULLS_REPO:=brianchandotcom/liferay-portal}"
: "${LFR_PULLS_MASTER_REF:=brian/master}"
: "${LFR_PULLS_UPSTREAM_REPO:=liferay/liferay-portal}"
: "${LFR_PULLS_TEAM:=${LFR_GIT_FORK_ORG:-${LFR_PULLS_MINE_ORG:-}}}"
: "${LFR_PULLS_FORK_REPO:=${LFR_PULLS_REPO##*/}}"

# The stand-in for your own login in a person argument, resolved to the real
# login only when a listing needs it, so no command pays a gh call to say mine.
: "${LFR_PULLS_AUTHOR_ME:=::me::}"

# Where a backport goes. A backport pull is opened straight on the EE repo
# rather than travelling the fork-then-mirror road the other three sections
# follow, so it gets a section of its own.
: "${LFR_PULLS_EE_REPO:=liferay/liferay-portal-ee}"

# The product teams that own code in .github/CODEOWNERS. Each is a real GitHub
# account owning a liferay-portal fork, and that fork is where the team reviews
# a change before ci:forward sends it to the mirror. `lfrPulls teams` re-reads
# CODEOWNERS from your local clone and reports anything this list is missing.
_LFR_PULLS_TEAMS="liferay-ac liferay-appsec liferay-bpm liferay-commerce liferay-content-management liferay-core-infra liferay-database-infra liferay-devtools liferay-frontend liferay-headless liferay-page-management liferay-platform-experience liferay-release liferay-search liferay-site-management"

_lfrPullsHelp() {
	cat <<-'EOF'
		lfrPulls - list open pull requests along the road a change travels.

		Usage (each command has a short form and an alias):
		  lfrPulls                         the four queues, in order: yours on the
		                                   mirror, your team's fork (narrowed, see
		                                   below), your own fork (teammates waiting
		                                   on your review), and your backports on
		                                   the EE repo. Under the mirror's own
		                                   section comes the other half of what it
		                                   has to say: your rejections off it that
		                                   never landed
		  lfrPulls [mine|all]              the mirror alone (yours, or every PR)
		  lfrPulls ee [mine|all|<login>]  (lfrpe)
		                                   backports on liferay/liferay-portal-ee,
		                                   yours by default
		  lfrPulls <team|user|owner/repo> [mine|all|<login>]  (lfrpf)
		                                   open PRs on that fork, e.g.
		                                   lfrPulls liferay-frontend, lfrPulls
		                                   headless, lfrPulls experience, or any
		                                   GitHub username. All of them by
		                                   default; a second word keeps one
		                                   person's, either mine or any login, so
		                                   lfrPulls page-management achaparro
		                                   asks the same question about somebody
		                                   else. A first word with a slash is a
		                                   whole repo, which is how any other
		                                   one is reached: lfrPulls
		                                   liferay/liferay-portal-ee mariuo.
		                                   With no slash the repo is
		                                   liferay-portal
		  lfrPulls teams  (lfrpteams)      the product teams and their open counts
		  lfrPulls ticket <LPD-12345>  (t, lfrpt)
		                                   every pull ever opened for that ticket,
		                                   oldest first, then what the ticket has
		                                   landed on the master ref. A bare ticket
		                                   works too: lfrPulls LPD-12345
		  lfrPulls rejected [days|all] [<login>]  (rej, r, lfrpr)
		                                   your pulls closed on the mirror without
		                                   being merged, whose ticket has still not
		                                   landed on the master ref, so the work is
		                                   owed: PR / CLOSED / TRIES / RESENT / WHY
		                                   / TITLE. Days default 30, and `all`
		                                   drops the window
		  lfrPulls week [days] [<login>]  (w, lfrpw)
		                                   your pulls closed in the last days
		                                   (default 7), forwarded or direct:
		                                   PR / SENDER / STATUS / TITLE
		  lfrPulls stats [mine|all|<login>] [months]  (s, lfrps)
		                                   per-month counts of PRs sent, merged, and
		                                   rejected for you (mine); sent and closed
		                                   for the whole repo (all); months default 12

		mine matches PRs forwarded from your fork or opened by you, and it means
		the same in week and stats; all shows every PR. The AHEAD column is how many open pulls are older (lower
		number), i.e. roughly how many are in front of it in the merge queue, so
		a small number means yours is close. The list ends with when the repo was
		last active (the most recent pull merged or rejected) and how long ago.

		STATUS is read off the pull itself, not off one team's labels, since every
		fork keeps its own vocabulary. Worst news first:
		  CONFLICT    GitHub reports it CONFLICTING, or a conflict label is on it
		  DRAFT       opened as a draft
		  CHANGES     changes requested and still owed, by review or by label.
		              A push answers the review half: GitHub keeps its own
		              CHANGES_REQUESTED until that reviewer reviews again, so
		              the word is kept only while the changes-requested review
		              still points at the head commit. A label stands until
		              somebody takes it off
		  CHECK-FAIL  carries pr-check - failure
		  ON-HOLD     on hold, blocked, or waiting for something (waiting_for_dev)
		  NO-CHECK    no pr-check label at all, so no pr-check result was ever
		              published on it and it cannot be forwarded. Ranked under
		              the four above because each of those is fixed by pushing
		              new commits, which invalidates a pr-check against the old
		              head; the pull falls through to here once that is done.
		              Never on the EE repo, where backports run no pr-check
		  READY       approved, ready to merge, ready to forward, QA passed
		  IN-REVIEW   review in progress, or somebody is assigned to it
		  REVIEW      review needed and nobody has taken it
		  FORWARDED   ci:forward is on it, so it is on its way to the mirror
		  TEST-FAIL   a ci:test batch is red and nothing above applies. Ranked
		              here because a backport nearly always has one red batch
		  OPEN        none of the above

		ON YOU says what the pull needs from you, and nothing else. Every
		value but "-" is an action of yours:
		  you          a pull of yours is CONFLICT / CHANGES / CHECK-FAIL /
		               NO-CHECK / TEST-FAIL / ON-HOLD, so it is yours to fix.
		               Yours is decided by who sent it, never by who authored
		               it, so a forwarded pull on the mirror still counts
		  ask          a pull of yours is conflicting and somebody else is
		               already reviewing it. Yours to rebase, but a force push
		               under a review in progress destroys that review, so ask
		               the person in ASSIGNEE first
		  on-review    the review is on you: you are the assignee or the
		               requested reviewer, or somebody opened it on your own
		               fork and nobody has taken it, which is a review request
		               to you by construction
		  need-review  somebody else wrote it, review needed, nobody has taken
		               it, conflicting or not: free for you to take. Never on
		               an on-hold pull, which CONFLICT would otherwise hide
		               the hold on and offer as takeable
		  -            nothing for you to do, which includes a pull of yours
		               that is healthy or waiting on a reviewer, and any pull
		               somebody else is reviewing
		What another person owes a pull is not in this column. STATUS says
		IN-REVIEW, ASSIGNEE names them, and the census below counts them.
		need-review only fires on a queue of your own (your fork, your team
		fork, the mirror, the EE repo), because an unclaimed pull is only
		yours to pick up on a queue you belong to. On a fork of another team
		it stays "-", unless the review was requested from you by name.

		Under each table, the count line ends in the census of every open pull
		the section holds, not only the rows it printed, with the same over
		ON YOU and over the labels themselves under it:
		  5 of 14 open pull(s): 4 CONFLICT, 3 CHANGES, 3 NO-CHECK, 3 IN-REVIEW.
		  on you: 1 you, 3 need-review.
		  labels: 10 Backend review needed | 3 Changes needed | 1 On hold
		STATUS keeps the worst word per pull, so the labels line is the one
		that shows everything: a conflicting pull that is also on hold and
		waiting for a backend review counts once in STATUS and three times
		there. A pull carrying no workflow label counts as untriaged. The
		labels line prints only in stats and with -d, alongside the LABELS
		column, since on the team fork it counts every teammate's pulls.

		Anywhere mine is accepted a GitHub login works in its place, and the
		whole question is then asked about that person: lfrPulls stats nikki-pru
		gives their month table and their four queues, lfrPulls week 30
		nikki-pru their closed pulls, lfrPulls <team> <login> one fork of
		theirs, lfrPulls ee <login> their backports. ON YOU keeps answering for
		you, so it still says what a pull of theirs needs from you. The one
		exception is the mirror-alone form, where a bare word already names a
		fork: lfrPulls <login> lists that person's fork, and their mirror pulls
		come from lfrPulls stats <login>.

		The team fork is the one queue carrying everybody, so bare lfrPulls keeps
		only what concerns you: the pulls you wrote, the ones ON YOU speaks for,
		and the ones with no workflow label at all, which is itself the finding
		since nobody has triaged them. The count line still gives the section
		total ("3 of 9 open pull(s)"), and lfrPulls <team> lists all of them.

		Teams are the accounts that own code in .github/CODEOWNERS. Name one in
		full (liferay-frontend), without the prefix (frontend), or by any unique
		part of it (experience, page, headless); a name matching no team is used
		as a GitHub username, so lfrPulls <someone> lists their fork.
		  liferay-ac                   liferay-headless
		  liferay-appsec               liferay-page-management
		  liferay-bpm                  liferay-platform-experience
		  liferay-commerce             liferay-release
		  liferay-content-management   liferay-search
		  liferay-core-infra           liferay-site-management
		  liferay-database-infra
		  liferay-devtools
		  liferay-frontend
		lfrPulls teams prints the same list with each team's open pull count.

		ticket shows STATE as GitHub has it (OPEN or CLOSED) and does not label any
		pull merged: Brian's merge rewrites the commits, so only a subject can be
		matched, and a ticket's resends all carry the same title, which would mark
		every one of them merged. The footer answers it instead, listing the
		ticket's commits on LFR_PULLS_UPSTREAM_REPO, found by GitHub's commit
		search; their date tells you which resend landed. When the search fails it
		reads the local master ref instead, and says so with the ref tip.

		stats (mine) counts the PRs you sent, forwarded or opened directly, by
		month:
		  SENT      PRs you created that month
		  MERGED    of those closed that month, the ones whose exact title is a
		            commit of yours on LFR_PULLS_UPSTREAM_REPO (Brian merged it in)
		  REJECTED  closed that month whose title is NOT on master (just closed)
		A pull is merged only if its own title landed, so a superseded resend of a
		ticket whose other work merged still counts as rejected. The subjects come
		off the local master ref, fetched first, since a year of titles is more
		GitHub commit searches than its rate limit allows. week asks GitHub
		instead, falling back to the ref. stats all cannot title-match every
		PR, so it shows only sent and closed for the whole repo. stats then prints
		the same four queues in full, adding each pull's age and its own labels,
		and stats all widens the mirror section to every open pull as well.

		rejected answers one question: what did Brian send back that you have not
		got in yet. A pull is rejected when it was closed and the last comment
		posted at or before the close was not "Merged. Thank you." and was not a
		ci:close of your own; that comment is the reason, so the #number links
		straight to it rather than to the pull, and WHY carries its first line. Pipe
		the output, or set LFR_PULLS_LINKS=off, and the URL comes back as a COMMENT
		column instead, since an escape nobody can see is worse than a wide table.

		It sits directly under the mirror's open pulls, since both are the same repo:
		what Brian is holding, then what he sent back. It is not a queue, so it is
		not one of the four, and it is left out of lfrPulls all, where "rejected"
		over the whole repo says nothing about anybody.

		Only the newest rejection per ticket is a row, because that is the one on
		you: TRIES says how many times the ticket has been sent back, and RESENT
		names the open pull already answering it, so a rejection still to answer is
		a row with "-" there. A ticket whose work has since landed on the master ref
		drops out of the listing entirely, which is what "still not landed" means;
		landing is asked of GitHub's commit search on LFR_PULLS_UPSTREAM_REPO, only
		from the oldest rejection in hand, so a ticket that landed something before
		this pull was sent back still counts as owed. When the search fails the
		local master ref answers instead, and the section says so.

		Config (lfr-pulls.local.conf):
		  LFR_PULLS_REPO         repo to list (default brianchandotcom/liferay-portal)
		  LFR_PULLS_MINE_ORG     the owner in the -sender-<owner> of a pull you
		                         forwarded, so your own fork (default your login)
		  LFR_PULLS_USER         your GitHub login (default the gh-authed user)
		  LFR_PULLS_TEAM         your team's account (default LFR_GIT_FORK_ORG)
		  LFR_PULLS_FORK_REPO    the repo an owner with no slash means (default
		                         liferay-portal, the name in LFR_PULLS_REPO)
		  LFR_PULLS_EE_REPO      backports repo (default liferay/liferay-portal-ee)
		  LFR_PULLS_UPSTREAM_REPO  repo whose commit search says what landed
		                         (default liferay/liferay-portal)
		  LFR_PULLS_MASTER_REPO  local clone stats greps, and the others when
		                         that search fails (default: cwd repo)
		  LFR_PULLS_MASTER_REF   master ref to grep (default brian/master)
		  LFR_PULLS_LINKS        on|off|auto (default auto): make each #number a
		                         clickable link on a terminal, plain when piped
		  LFR_PULLS_REJECTED_DAYS  how far back rejected looks, and the rejected
		                         section of bare lfrPulls with it (default 30)
	EOF
}

# Count PRs matching a GitHub search query via the search API (exact total, no
# result fetch).
_lfrPullsCount() {
	gh api graphql \
		-f searchQuery="${1}" \
		-f query='query($searchQuery:String!){ search(query:$searchQuery, type:ISSUE, first:0){ issueCount } }' \
		--jq '.data.search.issueCount' 2>/dev/null
}

# Resolve a local clone to grep for master landings: LFR_PULLS_MASTER_REPO, else
# the current repo. Echoes its path; errors if the master ref is missing. $1 names
# the calling command for the error messages (default stats).
_lfrPullsMasterDir() {
	local command="${1:-stats}"
	local dir="${LFR_PULLS_MASTER_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
	if [ -z "${dir}" ]; then
		echo "lfrPulls ${command}: run from a liferay-portal clone, or set LFR_PULLS_MASTER_REPO." >&2
		return 1
	fi
	if ! git -C "${dir}" rev-parse --verify -q "${LFR_PULLS_MASTER_REF}" >/dev/null 2>&1; then
		echo "lfrPulls ${command}: ref ${LFR_PULLS_MASTER_REF} not found in ${dir}; set LFR_PULLS_MASTER_REF/REPO." >&2
		return 1
	fi
	printf '%s\n' "${dir}"
}

# Render the month table and TOTAL row from three associative arrays keyed by
# YYYY-MM, over the newest `months` months.
_lfrPullsStatsTable() {
	local months="${1}"; shift
	local -n _sent="${1}" _merged="${2}" _rejected="${3}"
	local rows="" tS=0 tM=0 tR=0 i mon s m r
	for ((i = 0; i < months; i++)); do
		mon="$(date -d "$(date +%Y-%m-01) -${i} month" +%Y-%m)"
		s="${_sent[${mon}]:-0}"; m="${_merged[${mon}]:-0}"; r="${_rejected[${mon}]:-0}"
		rows="${rows}${mon}	${s}	${m}	${r}
"
		tS=$((tS + s)); tM=$((tM + m)); tR=$((tR + r))
	done
	printf 'MONTH\tSENT\tMERGED\tREJECTED\n%sTOTAL\t%s\t%s\t%s\n' \
		"${rows}" "${tS}" "${tM}" "${tR}" | column -t -s $'\t'
}

# Your per-month PR stats, deciding merged/rejected by whether each PR's exact
# title landed on LFR_PULLS_MASTER_REF (same signal as `lfrPulls week`).
#
# Off the local ref rather than GitHub's commit search, because a year of titles
# means one search per forwarded ticket, 38 of them on 2026-09-24, past the 30 a
# minute allowed. The ref is fetched first so it cannot be stale; a failed fetch
# still counts, off the ref as it is, and the footer's tip says how old that is.
_lfrPullsStatsMine() {
	local months="${1}" person="${2}" dir
	dir="$(_lfrPullsMasterDir)" || return 1
	git -C "${dir}" fetch --no-tags -q "${LFR_PULLS_MASTER_REF%%/*}" "${LFR_PULLS_MASTER_REF#*/}" 2>/dev/null ||
		echo "lfrPulls stats: could not fetch ${LFR_PULLS_MASTER_REF}; counting off it as it is." >&2

	local windowStart sinceDate json
	windowStart="$(date -d "$(date +%Y-%m-01) -$((months - 1)) month" +%Y-%m)"
	# Buffer a month before the window so a pull closed early in it whose merge
	# commit is dated slightly later is still matched.
	sinceDate="$(date -d "${windowStart}-01 -1 month" +%Y-%m-%d)"
	echo "Counting PRs by ${person} on ${LFR_PULLS_REPO}, matching titles against ${LFR_PULLS_MASTER_REF}..." >&2
	json="$(_lfrPullsMirrorPersonJson "${person}" all \
		number,title,state,headRefName,createdAt,closedAt)" || return 1

	local -A masterSubjects=()
	_lfrPullsLoadMasterSubjects "${dir}" "${sinceDate}" masterSubjects "${json}"

	local -A sent=() merged=() rejected=()
	local mon
	while IFS= read -r mon; do
		[[ -n "${mon}" && ! "${mon}" < "${windowStart}" ]] && sent["${mon}"]=$((${sent["${mon}"]:-0} + 1))
	done < <(printf '%s' "${json}" | jq -r '.[].createdAt[:7]')

	local cmon title
	while IFS=$'\t' read -r cmon title; do
		[[ -z "${cmon}" || "${cmon}" < "${windowStart}" ]] && continue
		if [ -n "${masterSubjects[${title}]:-}" ]; then
			merged["${cmon}"]=$((${merged["${cmon}"]:-0} + 1))
		else
			rejected["${cmon}"]=$((${rejected["${cmon}"]:-0} + 1))
		fi
	done < <(printf '%s' "${json}" | jq -r '.[] | select(.closedAt) | "\(.closedAt[:7])\t\(.title)"')

	_lfrPullsStatsTable "${months}" sent merged rejected
	printf '(%s tip: %s. Merged = the pull title appears on that ref.)\n' \
		"${LFR_PULLS_MASTER_REF}" \
		"$(git -C "${dir}" log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M' "${LFR_PULLS_MASTER_REF}" 2>/dev/null)" >&2
}

# Whole-repo per-month stats. Merged vs rejected is not determinable repo-wide on
# the mirror (the GitHub merge flag is ~0; real merges land on master and would
# need a per-PR title match, which does not scale to every PR), so this shows
# only sent (created) and closed, both exact from the search API.
_lfrPullsStatsAll() {
	local months="${1}" base="repo:${LFR_PULLS_REPO} is:pr"
	echo "Counting all PRs on ${LFR_PULLS_REPO} (sent and closed; merged vs rejected is mine-only)..." >&2

	local rows="" tSent=0 tClosed=0 i start next end mon sent closed
	for ((i = 0; i < months; i++)); do
		start="$(date -d "$(date +%Y-%m-01) -${i} month" +%Y-%m-01)"
		next="$(date -d "${start} +1 month" +%Y-%m-01)"
		end="$(date -d "${next} -1 day" +%Y-%m-%d)"
		mon="${start:0:7}"
		sent="$(_lfrPullsCount "${base} created:${start}..${end}")"
		closed="$(_lfrPullsCount "${base} closed:${start}..${end}")"
		rows="${rows}${mon}	${sent:-0}	${closed:-0}
"
		tSent=$((tSent + ${sent:-0}))
		tClosed=$((tClosed + ${closed:-0}))
	done

	printf 'MONTH\tSENT\tCLOSED\n%sTOTAL\t%s\t%s\n' "${rows}" "${tSent}" "${tClosed}" |
		column -t -s $'\t'
}

# Per-month counts of PRs sent, merged, and rejected. Yours by default (merged =
# ticket on the master ref); `all` counts the whole repo by GitHub merge state.
# An optional number sets how many months back to show (default 12).
_lfrPullsStats() {
	local scope="mine" months=12 a
	for a in "$@"; do
		case "${a}" in
		mine | -m | --mine) scope="mine" ;;
		all | -a | --all) scope="all" ;;
		-h | --help) _lfrPullsHelp; return 0 ;;
		'') ;;
		*[!0-9]*) scope="${a#@}" ;;
		*) months="${a}" ;;
		esac
	done

	if [ "${scope}" = "all" ]; then
		_lfrPullsStatsAll "${months}"
	else
		local person="${scope}"
		if [ "${person}" = "mine" ]; then
			person="$(_lfrPullsMineUser stats)" || return 1
		fi
		_lfrPullsStatsMine "${months}" "${person}" || return 1
	fi

	# What the months table cannot say: where each pull open right now is stuck.
	# Same queues bare lfrPulls shows, with the age and the labels added, and
	# widened to the whole mirror when the counts above were for the whole repo.
	_lfrPullsDashboard detail "${scope}"
}

# Print "<sha>\t<committer date>\t<subject>" for every commit on
# LFR_PULLS_UPSTREAM_REPO matching the search qualifiers $1 and committed from
# $2 through $3 (YYYY-MM-DD), newest first. This is what every landing check
# asks first, so the answer never depends on how recently a local clone was
# fetched. The mirror itself cannot answer: it is a fork, and GitHub indexes no
# commits in a fork (LPD-101584 returned 0 there and 12 on
# liferay/liferay-portal, 2026-09-24).
#
# GitHub serves at most 1000 results per search, so a range holding more is
# split in half and each half asked on its own. Returns 1 on the first failed
# call, rate limit included, so the caller falls back to the local ref rather
# than trusting half an answer.
_lfrPullsSearchCommits() {
	local qualifiers="${1}" from="${2}" to="${3}" jqItems out total pages page
	jqItems='.items[] | "\(.sha)\t\(.commit.committer.date[:10])\t\(.commit.message | split("\n")[0])"'
	out="$(gh api -X GET search/commits \
		-f q="repo:${LFR_PULLS_UPSTREAM_REPO} ${qualifiers} committer-date:${from}..${to}" \
		-f sort=committer-date -f order=desc -f per_page=100 -f page=1 \
		--jq ".total_count, (${jqItems})" 2>/dev/null)" || return 1
	total="$(printf '%s\n' "${out}" | head -1)"

	if [ "${total:-0}" -gt 1000 ] && [ "${from}" != "${to}" ]; then
		local days mid
		days=$(( ($(date -u -d "${to}" +%s) - $(date -u -d "${from}" +%s)) / 86400 ))
		mid="$(date -u -d "${from} +$((days / 2)) days" +%Y-%m-%d)"
		_lfrPullsSearchCommits "${qualifiers}" "$(date -u -d "${mid} +1 day" +%Y-%m-%d)" "${to}" || return 1
		_lfrPullsSearchCommits "${qualifiers}" "${from}" "${mid}" || return 1
		return 0
	fi

	printf '%s\n' "${out}" | tail -n +2 | grep .
	[ "${total:-0}" -gt 1000 ] && total=1000
	pages=$(( (${total:-0} + 99) / 100 ))
	for ((page = 2; page <= pages; page++)); do
		gh api -X GET search/commits \
			-f q="repo:${LFR_PULLS_UPSTREAM_REPO} ${qualifiers} committer-date:${from}..${to}" \
			-f sort=committer-date -f order=desc -f per_page=100 -f page="${page}" \
			--jq "${jqItems}" 2>/dev/null || return 1
	done
	return 0
}

# Load into the associative array named $3 the subjects of commits on
# LFR_PULLS_UPSTREAM_REPO since $2 that are the exact title of a pull in the
# JSON $4, the same answer _lfrPullsLoadMasterSubjects gives off a clone.
#
# One author search on $1 answers most titles at once. It cannot answer a pull
# $1 forwarded with a teammate's commits in it, which is a real share: four of
# the 59 merged in `stats 12` on 2026-09-24. So each ticket still unmatched gets
# a search of its own. That is a handful over a week and 38 over a year, which
# is why stats reads a fetched clone instead and only week comes here.
#
# Returns 1 when a search fails; the caller then asks the local ref and says so
# on stderr.
_lfrPullsLoadUpstreamSubjects() {
	local -n _upstreamSubjects="${3}"
	local titles subjects unmatched key s today
	titles="$(printf '%s' "${4}" | jq -r '.[].title | select(. != "")' | sort -u)"
	[ -z "${titles}" ] && return 0
	today="$(date -u +%Y-%m-%d)"
	subjects="$(_lfrPullsSearchCommits "author:${1}" "${2}" "${today}")" || return 1
	unmatched="$(printf '%s\n' "${titles}" |
		grep -vFxf <(printf '%s\n' "${subjects}" | cut -f3 | grep .))"
	while IFS= read -r key; do
		[ -z "${key}" ] && continue
		subjects="${subjects}
$(_lfrPullsSearchCommits "${key}" "${2}" "${today}")" || return 1
	done < <(printf '%s\n' "${unmatched}" | grep -oiE '^[A-Za-z]+[- ][0-9]+' | sort -u)
	while IFS= read -r s; do
		[ -n "${s}" ] && _upstreamSubjects["${s}"]=1
	done < <(printf '%s\n' "${subjects}" | cut -f3 | grep -Fxf <(printf '%s\n' "${titles}"))
}

# The landed subjects for week: GitHub first, the local ref when the
# search fails, and a note on stderr saying which one answered when it was not
# GitHub. $1 person, $2 since, $3 the array, $4 the pulls JSON, $5 the command.
_lfrPullsLoadLandedSubjects() {
	local -n _landedSubjects="${3}"
	_lfrPullsLoadUpstreamSubjects "${1}" "${2}" "${3}" "${4}" && return 0
	_landedSubjects=()
	local dir
	if dir="$(_lfrPullsMasterDir "${5}")"; then
		_lfrPullsLoadMasterSubjects "${dir}" "${2}" "${3}" "${4}"
		printf '(GitHub commit search failed: merged is read off the local %s, as fresh as its last fetch, tip %s.)\n' \
			"${LFR_PULLS_MASTER_REF}" \
			"$(git -C "${dir}" log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M' "${LFR_PULLS_MASTER_REF}" 2>/dev/null)" >&2
		return 0
	fi
	return 1
}

# Load the subjects of commits on the master ref (in clone $1, since date $2)
# into the associative array named $3, keeping only those that are the exact
# title of a pull in the JSON $4. A pull merged in when its title is one of
# these subjects; loading them once avoids a full-history scan per title.
#
# Narrowing to the titles asked about is what makes that cheap, and the ratio is
# why: the ref carries around 80,000 subjects over a year, while a listing asks
# about a few hundred titles and matches a few dozen. Handing all 80,000 to bash
# costs 7.7s in array assignments alone, more than the two GitHub fetches
# together; letting grep drop the lines that cannot match first costs 0.01s.
_lfrPullsLoadMasterSubjects() {
	local -n _subjects="${3}"
	local titles s
	# An empty pattern line matches every subject, which would load all 80,000
	# again, so a pull with no title is dropped rather than passed to grep.
	titles="$(printf '%s' "${4}" | jq -r '.[].title | select(. != "")' | sort -u)"
	[ -z "${titles}" ] && return 0
	while IFS= read -r s; do
		[ -n "${s}" ] && _subjects["${s}"]=1
	done < <(git -C "${1}" log "${LFR_PULLS_MASTER_REF}" --since="${2}" --format='%s' 2>/dev/null |
		grep -Fxf <(printf '%s\n' "${titles}"))
}

# List your pulls closed in the last <days> (default 7), as PR / SENDER / STATUS
# / TITLE, where STATUS is MERGED (ticket on the master ref) or REJECTED.
_lfrPullsWeek() {
	local days=7 person="" a
	for a in "$@"; do
		case "${a}" in
		-h | --help) _lfrPullsHelp; return 0 ;;
		'') ;;
		*[!0-9]*) person="${a#@}" ;;
		*) days="${a}" ;;
		esac
	done

	local since json rows sender title status
	if [ -z "${person}" ]; then
		person="$(_lfrPullsMineUser week)" || return 1
	fi
	since="$(date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ)"

	json="$(_lfrPullsMirrorPersonJson "${person}" closed \
		number,title,headRefName,author,closedAt)" || return 1

	# The pulls come first: their titles are what narrows the subject scan.
	local -A masterSubjects=()
	_lfrPullsLoadLandedSubjects "${person}" "$(date -d "${days} days ago -1 month" +%Y-%m-%d)" \
		masterSubjects "${json}" week || return 1

	rows=""
	while IFS=$'\t' read -r num sender title; do
		[ -z "${num}" ] && continue
		if [ -n "${masterSubjects[${title}]:-}" ]; then
			status="MERGED"
		else
			status="REJECTED"
		fi
		rows="${rows}${num}	${sender}	${status}	${title}
"
	done < <(printf '%s' "${json}" | jq -r --arg since "${since}" \
		'[.[] | select(.closedAt >= $since)] | sort_by(.closedAt) | reverse | .[] |
			"#\(.number)\t\(if (.headRefName | test("-sender-")) then (.headRefName | sub(".*-sender-"; "")) else .author.login end)\t\(.title)"' 2>/dev/null)

	if [ -z "${rows}" ]; then
		echo "No pulls by ${person} closed in the last ${days} day(s) on ${LFR_PULLS_REPO}."
		return 0
	fi
	printf 'PR\tSENDER\tSTATUS\tTITLE\n%s' "${rows}" | column -t -s $'\t' |
		_lfrPullsLinkify "${LFR_PULLS_REPO}"
}

# The outcome a closed pull ended on, and the comment that carries it.
#
# Brian comments and closes in the same action, so the word on a pull is its
# last comment posted at or before closedAt. Checked over the 25 most recently
# closed pulls of mine on the mirror, where it separated every one of them:
# "Merged. Thank you." from brianchandotcom, a "@<you> ..." review note from
# him, the CI bot's merge-conflict close, and a ci:close of your own. A pull
# whose last comment predates its close was closed with no word at all, which
# is NO-WORD and still counts as work of yours that never landed.
#
# This is a stronger merge signal than matching the title against the master
# ref, which is what week and stats use: it is the closer's own statement
# rather than an inference, so a superseded resend of a ticket whose other work
# merged is not read as merged. It is not swapped in there because those two
# count over a year of pulls and would pay the comments field on every one.
_LFR_PULLS_REJECTED_JQ='
	def sender:
		if (.headRefName | test("-sender-")) then (.headRefName | sub(".*-sender-"; "")) else .author.login end;
	def closingComment:
		.closedAt as $closedAt |
		[ (.comments // [])[] | select(.createdAt <= $closedAt) ] | last;
	def outcome:
		closingComment as $comment |
		($comment.body // "") as $body |
		($comment.author.login // "") as $author |
		if $comment == null then "NO-WORD"
		elif $body | test("^Merged\\. Thank you\\.") then "MERGED"
		elif $body | test("^\\s*ci:close") then "SELF"
		elif $body | test("merge conflict and has been closed"; "i") then "CONFLICT"
		elif ($author == $me) or ($author == sender) then "SELF"
		else "REJECTED" end;
	# The first line of the rejection worth reading. The @-mention Brian opens
	# with goes, and so do the fence lines of a code block, which would
	# otherwise be the whole column. Tabs go too: the table is tab separated
	# and a quoted line of Java is nothing but tabs.
	def why:
		(closingComment.body // "") | gsub("\r"; "") | gsub("\t"; " ") |
		gsub("@[A-Za-z0-9_-]+"; "") | split("\n") |
		map(gsub("^ +| +$"; "")) |
		map(select(. != "" and ((test("^`{3,}")) | not))) |
		(.[0] // "-");
	# The ticket a pull is for, which is what decides whether its work landed:
	# a resend carries a new number and often a new title, but never a new
	# ticket. A pull with no key in its title is its own group, so two of them
	# are never folded together.
	def ticketKey:
		((.title // "") |
			(capture("^(?<key>[A-Za-z]+[- ][0-9]+)") | .key | ascii_upcase | gsub(" "; "-"))) //
		"#\(.number)";
'

# One person's closed pulls on the mirror, carrying their comments, as one JSON
# array over the fields $3. Both ways a pull reaches the mirror, same as
# _lfrPullsMirrorPersonJson, but fetched at once rather than one after the
# other because the comments field roughly triples what each call brings back.
#
# Bounded by `updated:` and filtered on closedAt by the caller, never by
# `closed:`, which is wrong on this repo. Measured 2026-09-21 against the
# unbounded listing: closed:>=2026-06-01 returned 34 of the 48 pulls that
# actually closed in that window, and closed:>=2026-08-01 returned 0 of 6.
# updated: returned exactly the 6 over 30 days and a complete superset (81 for
# 48) over four months, since closing a pull updates it.
_lfrPullsClosedPersonJson() {
	local person="${1}" since="${2}" fields="${3}" senderOwner dir authored forwarded
	senderOwner="$(_lfrPullsSenderOwner "${person}")"

	dir="$(mktemp -d -t lfr-pulls-closed.XXXXXXXX 2>/dev/null)" || return 1
	(
		gh pr list --repo "${LFR_PULLS_REPO}" --state closed --limit 500 \
			--search "author:${person} updated:>=${since}" --json "${fields}" \
			>"${dir}/authored" 2>/dev/null &
		gh pr list --repo "${LFR_PULLS_REPO}" --state closed --limit 500 \
			--search "mentions:${person} updated:>=${since}" --json "${fields}" \
			>"${dir}/forwarded" 2>/dev/null &
		wait
	)

	# Empty is how a failed fetch arrives; a person with nothing closed in the
	# window still gets "[]" from both, so an empty file is never a real answer.
	if [ ! -s "${dir}/authored" ] || [ ! -s "${dir}/forwarded" ]; then
		rm -rf "${dir}"
		echo "lfrPulls rejected: could not list closed pulls on ${LFR_PULLS_REPO}." >&2
		return 1
	fi
	authored="$(cat "${dir}/authored")"
	forwarded="$(cat "${dir}/forwarded")"
	rm -rf "${dir}"

	# On stdin rather than as --argjson for the same reason the open listing
	# does it: two fetches of a prolific person run past ARG_MAX together.
	printf '%s\n%s\n' "${authored}" "${forwarded}" |
		jq -s --arg senderOwner "${senderOwner}" \
			'.[0] + [.[1][] | select(.headRefName | test("-sender-" + $senderOwner + "$"))] |
				unique_by(.number)'
}

# Load into the associative array named $3 the ticket keys, out of the newline
# list $4, that have a commit on the master ref since $2 in the clone $1.
# Narrowed to the keys asked about for the same reason _lfrPullsLoadMasterSubjects
# narrows to the titles: the ref carries tens of thousands of subjects a year
# and a handful of them can match.
#
# Matched on the subject's own prefix, not by a full-text grep, so a commit that
# merely mentions another ticket is not read as that ticket landing.
_lfrPullsLoadMasterTickets() {
	local -n _landed="${3}"
	local keys="${4}" key
	[ -z "${keys}" ] && return 0
	while IFS= read -r key; do
		[ -n "${key}" ] && _landed["${key}"]=1
	done < <(git -C "${1}" log "${LFR_PULLS_MASTER_REF}" --since="${2}" --format='%s' 2>/dev/null |
		grep -oiE '^[A-Za-z]+[- ][0-9]+' |
		tr '[:lower:] ' '[:upper:]-' |
		grep -Fxf <(printf '%s\n' "${keys}") | sort -u)
}

# Load into the associative array named $2 the ticket keys, out of the newline
# list $3, that have a commit on LFR_PULLS_UPSTREAM_REPO since $1, one search
# per key (see _lfrPullsSearchCommits).
#
# Matched on the subject's own prefix, the same as _lfrPullsLoadMasterTickets.
# Returns 1 on the first failed call, so the caller falls back to the local ref.
_lfrPullsLoadUpstreamTickets() {
	local -n _upstreamLanded="${2}"
	local key subjects
	while IFS= read -r key; do
		case "${key}" in "" | "#"*) continue ;; esac
		subjects="$(_lfrPullsSearchCommits "${key}" "${1}" "$(date -u +%Y-%m-%d)")" || return 1
		printf '%s\n' "${subjects}" | cut -f3 | grep -oiE '^[A-Za-z]+[- ][0-9]+' |
			tr '[:lower:] ' '[:upper:]-' | grep -Fxq "${key}" && _upstreamLanded["${key}"]=1
	done <<<"${3}"
	return 0
}

# The pulls that came back off the road: closed on the mirror without being
# merged, and whose ticket has still not landed on the master ref, so the work
# is owed. Newest first. $1 whose pulls, $2 how many days back.
#
# One row per ticket, the newest rejection, because that is the one that is on
# you; TRIES says how many times the ticket has been sent back, which is what
# an older row would have carried. RESENT names the open pull already answering
# it, so a rejection still to answer is a row with "-" there.
#
# Its own fetch rather than a job in the open prefetch: this is the only listing
# on the closed side, and its two calls already run together, so folding it in
# would buy the dashboard a second or so at the cost of coupling the two.
_lfrPullsRejectedSection() {
	local person="${1}" days="${2}"
	local me="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}" senderMe
	senderMe="$(_lfrPullsSenderOwner "${me}" "${me}")"

	printf '\n%s rejected pulls (%s, last %s day(s), still not landed on %s)\n' \
		"${LFR_PULLS_REPO}" "${person}" "${days}" "${LFR_PULLS_UPSTREAM_REPO}"

	local since sinceTs json
	since="$(date -u -d "${days} days ago" +%Y-%m-%d)"
	sinceTs="$(date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ)"
	json="$(_lfrPullsClosedPersonJson "${person}" "${since}" \
		number,title,headRefName,author,closedAt,comments)" || return 1

	# Every closed pull in the window that was neither merged nor closed by its
	# own sender, before the master ref has its say.
	local candidates
	candidates="$(printf '%s' "${json}" | jq -c --arg me "${me}" --arg sinceTs "${sinceTs}" \
		"${_LFR_PULLS_REJECTED_JQ}"'
		[ .[] | select((.closedAt // "") >= $sinceTs) |
			{ number, title, closedAt, key: ticketKey, outcome: outcome,
				why: why, url: (closingComment.url // "") } |
			select(.outcome != "MERGED" and .outcome != "SELF") ]')"

	local closedCount
	closedCount="$(printf '%s' "${json}" | jq --arg sinceTs "${sinceTs}" \
		'[.[] | select((.closedAt // "") >= $sinceTs)] | length')"

	if [ "$(printf '%s' "${candidates}" | jq 'length')" -eq 0 ]; then
		printf '  none of the %s closed pull(s).\n' "${closedCount}"
		return 0
	fi

	# The landing check is what "still not landed" means, so a failed search
	# falls back to the local ref, and a missing clone or ref widens the section
	# rather than failing it, saying so either way.
	#
	# Asked from the oldest rejection in hand, not from the start of the window,
	# because the question is whether anything landed AFTER the rejection: a
	# ticket with several pulls can have landed other work before this one was
	# sent back, and that is still work owed.
	local dir landedJson='{}' landedNote="" landedSince keys
	landedSince="$(printf '%s' "${candidates}" |
		jq -r 'map(.closedAt) | min | .[:10]')"
	keys="$(printf '%s' "${candidates}" | jq -r '.[].key' | sort -u)"
	local -A landed=()
	if ! _lfrPullsLoadUpstreamTickets "${landedSince:-${since}}" landed "${keys}"; then
		landed=()
		if dir="$(_lfrPullsMasterDir rejected 2>/dev/null)"; then
			_lfrPullsLoadMasterTickets "${dir}" "${landedSince:-${since}}" landed "${keys}"
			landedNote="  (GitHub commit search failed: checked against the local ${LFR_PULLS_MASTER_REF}, as fresh as its last fetch)"
		else
			landedNote="  (GitHub commit search failed and no ${LFR_PULLS_MASTER_REF} to check against: every rejection is listed, landed or not)"
		fi
	fi

	# An object, not an array: a lookup has to read its key off the candidate,
	# and `$landed | index(.key)` would evaluate .key against $landed itself,
	# which is what `$landed[.key]` gets right.
	[ "${#landed[@]}" -gt 0 ] && landedJson="$(printf '%s\n' "${!landed[@]}" |
		jq -sRc 'split("\n") | map(select(. != "")) |
			map({ key: ., value: true }) | from_entries')"

	# Which of these tickets already has an open pull of yours on the mirror.
	# Served from the dashboard's prefetch when it ran, so no call of its own
	# there.
	local resentJson='{}' openJson
	openJson="$(_lfrPullsOpenJson "${LFR_PULLS_REPO}")"
	[ -n "${openJson}" ] && resentJson="$(printf '%s' "${openJson}" |
		jq -c --arg me "${me}" --arg senderMe "${senderMe}" \
			"${_LFR_PULLS_REJECTED_JQ}"'
			[ .[] | select((.author.login == $me) or (sender == $senderMe)) |
				{ key: ticketKey, value: "#\(.number)" } ] | from_entries')"

	local rowsWithUrl
	rowsWithUrl="$(printf '%s' "${candidates}" | jq -r \
		--argjson landed "${landedJson}" --argjson resent "${resentJson}" '
		[ .[] | select($landed[.key] | not) ] |
		group_by(.key) |
		map(sort_by(.closedAt) | { newest: last, tries: length }) |
		sort_by(.newest.closedAt) | reverse | .[] |
		"#\(.newest.number)\t\(.newest.closedAt[:10])\t\(.tries)\t\($resent[.newest.key] // "-")\t\(.newest.why[0:52])\t\(.newest.title[0:52])\t\(.newest.url)"')"

	if [ -z "${rowsWithUrl}" ]; then
		printf '  none of the %s closed pull(s): every rejection has landed since.\n' "${closedCount}"
		return 0
	fi

	# The URL rides as the last field so the same rows can serve both renderings:
	# it becomes the link on the #number on a terminal, and a column of its own
	# when links are off, where an OSC 8 escape would take the URL away with it.
	local rows tickets resent
	if _lfrPullsLinksOn; then
		rows="$(printf '%s\n' "${rowsWithUrl}" | cut -f1-6)"
		printf 'PR\tCLOSED\tTRIES\tRESENT\tWHY\tTITLE\n%s\n' "${rows}" |
			column -t -s $'\t' | sed 's/^/  /' |
			_lfrPullsLinkifyUrls "$(printf '%s\n' "${rowsWithUrl}" | cut -f1,7 | sed 's/^#//')"
	else
		printf 'PR\tCLOSED\tTRIES\tRESENT\tWHY\tTITLE\tCOMMENT\n%s\n' "${rowsWithUrl}" |
			column -t -s $'\t' | sed 's/^/  /'
	fi

	tickets="$(printf '%s\n' "${rowsWithUrl}" | grep -c .)"
	resent="$(printf '%s\n' "${rowsWithUrl}" | awk -F'\t' '$4 != "-"' | grep -c .)"
	printf '  %s of %s closed pull(s) rejected and not landed, over %s ticket(s), %s already resent.\n' \
		"$(printf '%s' "${candidates}" | jq --argjson landed "${landedJson}" \
			'[.[] | select($landed[.key] | not)] | length')" \
		"${closedCount}" "${tickets}" "${resent}"
	[ -n "${landedNote}" ] && printf '%s\n' "${landedNote}"
	return 0
}

# Your rejected pulls that never landed. A number sets how many days back
# (default 30), `all` drops the window, and a login asks about somebody else.
_lfrPullsRejected() {
	local days="${LFR_PULLS_REJECTED_DAYS:-30}" person="" a
	for a in "$@"; do
		case "${a}" in
		-h | --help) _lfrPullsHelp; return 0 ;;
		all | -a | --all) days=3650 ;;
		mine | -m | --mine) person="" ;;
		'') ;;
		*[!0-9]*) person="${a#@}" ;;
		*) days="${a}" ;;
		esac
	done

	if [ -z "${person}" ]; then
		person="$(_lfrPullsMineUser rejected)" || return 1
	fi
	_lfrPullsRejectedSection "${person}" "${days}"
}

# Every pull ever opened on the mirror for one ticket, oldest first, then what that
# ticket has landed on the master ref.
#
# Deliberately no per-pull MERGED column: Brian's merge rewrites the commits (a
# pull's `eee3690` lands as `b13f864`), so only the subject can be matched, and a
# ticket's resends all carry the same title, which would mark every one of them
# merged. What is answerable is whether the ticket landed at all, so that goes in
# the footer, where the newest landed commit tells you which resend Brian took.
_lfrPullsTicket() {
	local ticket="" a
	for a in "$@"; do
		case "${a}" in
		-h | --help) _lfrPullsHelp; return 0 ;;
		[A-Za-z]*-[0-9]*) ticket="${a^^}" ;;
		*) echo "lfrPulls ticket: unknown argument '${a}' (want a ticket like LPD-12345)." >&2; return 1 ;;
		esac
	done

	if [ -z "${ticket}" ]; then
		echo "lfrPulls ticket: pass a ticket, e.g. lfrPulls ticket LPD-12345." >&2
		return 1
	fi

	echo "Searching ${LFR_PULLS_REPO} for ${ticket}..." >&2

	local json
	json="$(gh pr list --repo "${LFR_PULLS_REPO}" --search "${ticket} in:title" \
		--state all --limit 200 \
		--json number,title,state,headRefName,author,createdAt,closedAt,url)" || return 1

	local rows
	rows="$(printf '%s' "${json}" | jq -r \
		'sort_by(.createdAt) | .[] |
			"#\(.number)\t\(if (.headRefName | test("-sender-")) then (.headRefName | sub(".*-sender-"; "")) else .author.login end)\t\(.state)\t\(.createdAt[:10])\t\(.closedAt[:10] // "-")\t\(.title)"' 2>/dev/null)"

	if [ -z "${rows}" ]; then
		echo "No pull on ${LFR_PULLS_REPO} has ${ticket} in its title."
	else
		printf 'PR\tSENDER\tSTATE\tCREATED\tCLOSED\tTITLE\n%s\n' "${rows}" | column -t -s $'\t' |
			_lfrPullsLinkify "${LFR_PULLS_REPO}"
		printf '\n%s pull(s) for %s: %s open, %s closed.\n' \
			"$(printf '%s' "${json}" | jq 'length')" "${ticket}" \
			"$(printf '%s' "${json}" | jq '[.[] | select(.state == "OPEN")] | length')" \
			"$(printf '%s' "${json}" | jq '[.[] | select(.state != "OPEN")] | length')"
	fi

	# The landing report is a bonus, so a failed search with no clone or ref to
	# fall back on must not fail the listing above.
	#
	# GitHub's title search tokenizes, so it also finds a pull titled "LCD 52771"
	# for LCD-52771. Match the same variants here, or the footer would miss the
	# commits of exactly those pulls.
	local landed count where="${LFR_PULLS_UPSTREAM_REPO}" tip="" dir
	if landed="$(_lfrPullsSearchCommits "${ticket}" 2000-01-01 "$(date -u +%Y-%m-%d)")"; then
		landed="$(printf '%s\n' "${landed}" | grep -iE "${ticket/-/[- ]}" |
			awk -F'\t' -v OFS='\t' '{ print substr($1, 1, 13), $2, $3 }')"
	else
		dir="$(_lfrPullsMasterDir ticket)" || return 0
		where="the local ${LFR_PULLS_MASTER_REF} (GitHub commit search failed)"
		tip="$(git -C "${dir}" log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M' "${LFR_PULLS_MASTER_REF}")"
		landed="$(git -C "${dir}" log "${LFR_PULLS_MASTER_REF}" --grep="${ticket/-/[- ]}" \
			--regexp-ignore-case --format='%h	%cd	%s' --date=format:'%Y-%m-%d' 2>/dev/null)"
	fi
	count="$(printf '%s\n' "${landed}" | grep -c .)"

	if [ "${count}" -eq 0 ]; then
		printf '%s on %s: nothing landed yet%s.\n' "${ticket}" "${where}" \
			"${tip:+ (ref tip ${tip})}"
		return 0
	fi

	printf '%s on %s: %s commit(s) landed, newest first.\n' \
		"${ticket}" "${where}" "${count}"
	printf '%s\n' "${landed}" | head -5 | column -t -s $'\t' | sed 's/^/  /'
	[ "${count}" -gt 5 ] && printf '  ... %s more\n' "$((count - 5))"

	return 0
}

_lfrPullsAgo() {
	local ts="${1}" diff d h m rel
	diff=$(( $(date +%s) - $(date -d "${ts}" +%s) ))
	[ "${diff}" -lt 0 ] && diff=0
	d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
	if [ "${d}" -gt 0 ]; then rel="${d}d ${h}h ${m}m"
	elif [ "${h}" -gt 0 ]; then rel="${h}h ${m}m"
	else rel="${m}m"; fi
	printf '%s, %s ago' "$(date -d "${ts}" '+%Y-%m-%d %H:%M')" "${rel}"
}

# Echo the most recently closed PR on the repo (any outcome) as
# "#num<TAB>closedAt<TAB>title". gh sorts by creation, so fetch a batch and pick
# the latest closedAt.
_lfrPullsLastClosed() {
	gh pr list --repo "${LFR_PULLS_REPO}" --state closed --limit 60 \
		--json number,title,closedAt 2>/dev/null |
		jq -r 'map(select(.closedAt)) | sort_by(.closedAt) | reverse | .[0] // empty |
			"#\(.number)\t\(.closedAt)\t\(.title)"'
}

# Print a footer showing when the repo last processed a pull (merged or
# rejected), so you can tell if Brian is active right now.
_lfrPullsLastActiveLine() {
	local lastClosed num ts title
	lastClosed="$(_lfrPullsLastClosed)"
	[ -z "${lastClosed}" ] && { echo "Last active: no closed pulls on ${LFR_PULLS_REPO}."; return 0; }
	IFS=$'\t' read -r num ts title <<<"${lastClosed}"
	printf 'Last active: %s (%s %.55s)\n' "$(_lfrPullsAgo "${ts}")" "${num}" "${title}"
}

# Echo your GitHub login, from the config or from gh. $1 names the calling
# command for the error message.
_lfrPullsMineUser() {
	local mineUser="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}"
	if [ -z "${mineUser}" ]; then
		echo "lfrPulls ${1}: set LFR_PULLS_USER in ${_lfrPullsDir}/lfr-pulls.local.conf." >&2
		return 1
	fi
	printf '%s\n' "${mineUser}"
}

# The owner that appears in the -sender-<owner> of a pull $1 forwarded. It is
# their login, except for you, where a forward from an org fork carries the org
# instead: LFR_PULLS_MINE_ORG. Pass your login as $2 to save the gh call.
_lfrPullsSenderOwner() {
	local person="${1}" me="${2:-}"
	[ -z "${me}" ] && me="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}"
	if [ "${person}" = "${me}" ]; then
		printf '%s\n' "${LFR_PULLS_MINE_ORG:-${person}}"
	else
		printf '%s\n' "${person}"
	fi
}

# One person's pulls on the mirror, both ways a pull gets there, as one JSON
# array carrying the fields $3, over the state $2 (default all).
#
# A pull they opened directly is theirs by author, which gh filters server-side.
# A forwarded pull is authored by the CI bot, so it is theirs by the
# -sender-<owner> its head branch carries, and no search qualifier indexes that
# branch (head: wants the exact name). The forwarder does @-mention the sender in
# the body, so mentions: narrows the fetch to a few hundred pulls and the branch
# suffix then decides exactly. Verified on 6 of Georgel's forwarded pulls sampled
# across 2026-01 to 2026-09: every one was in the mentions: set.
#
# Filtering by author alone is what used to hide every forwarded pull from week
# and stats, so always come through here rather than passing --author yourself.
_lfrPullsMirrorPersonJson() {
	local person="${1}" state="${2:-all}" fields="${3}" senderOwner authored forwarded
	senderOwner="$(_lfrPullsSenderOwner "${person}")"

	authored="$(gh pr list --repo "${LFR_PULLS_REPO}" --author "${person}" \
		--state "${state}" --limit 500 --json "${fields}")" || return 1
	forwarded="$(gh pr list --repo "${LFR_PULLS_REPO}" --search "mentions:${person}" \
		--state "${state}" --limit 500 --json "${fields}")" || return 1

	# Both blobs go in on stdin, not as --argjson: a prolific person's two
	# fetches together run past ARG_MAX and jq dies with "Argument list too
	# long".
	printf '%s\n%s\n' "${authored}" "${forwarded}" |
		jq -s --arg senderOwner "${senderOwner}" \
			'.[0] + [.[1][] | select(.headRefName | test("-sender-" + $senderOwner + "$"))] |
				unique_by(.number)'
}

# Resolve a word to a fork owner: a team's full account (liferay-frontend), the
# same without the prefix (frontend), or any unique part of one (experience).
# A word matching no team is echoed unchanged, so a GitHub username works too.
_lfrPullsResolveOwner() {
	local input="${1}" want t
	want="${input,,}"
	want="${want#@}"
	want="${want// /-}"
	want="${want//_/-}"

	local -a hits=()
	for t in ${_LFR_PULLS_TEAMS}; do
		if [ "${t}" = "${want}" ] || [ "${t}" = "liferay-${want}" ]; then
			printf '%s\n' "${t}"
			return 0
		fi
		[[ "${t}" == *"${want}"* ]] && hits+=("${t}")
	done

	case "${#hits[@]}" in
	0) printf '%s\n' "${input}" ;;
	1) printf '%s\n' "${hits[0]}" ;;
	*) echo "lfrPulls: '${input}' matches ${#hits[@]} teams: ${hits[*]}" >&2; return 1 ;;
	esac
}

# jq prelude shared by every listing: the STATUS word, the sender of a forwarded
# pull, and the labels worth reading. STATUS comes from the pull's own mergeable
# state, review decision, and labels rather than from one team's vocabulary,
# because each fork names its labels differently (Page Management writes
# "🛠 Changes needed" where Core Infra writes "Merge Conflicts"). Worst news wins.
_LFR_PULLS_JQ='
	def allLabels: [.labels[].name];
	# The labels a reader wants, minus the CI bookkeeping. Emoji are stripped
	# because column(1) counts them one cell wide and a terminal draws them two,
	# which knocks every column after LABELS out of line.
	def workflowLabels:
		allLabels | map(select(test("^ci:test|^ci:forward|^pr-check|^:arrow") | not)) |
		map(gsub("[^ -~]"; "") | sub("^ +"; "") | sub(" +$"; "")) | map(select(. != ""));
	# Whether the pull is waiting for a reviewer nobody has become yet. Its own
	# predicate, not read off the status word, because NO-CHECK outranks REVIEW
	# and collapses it: onYou still has to see the review to offer it to you.
	# Never on the mirror: a pull gets there only once its team reviewed it,
	# and the "review needed" labels it carries were copied over by the
	# forward from the team fork, so they no longer ask anybody for anything.
	def reviewNeeded:
		($repoOwner != $mirrorOwner) and
		((allLabels | any(test("review needed|ready to review"; "i"))) or
		(.reviewDecision == "REVIEW_REQUIRED") or ((.reviewRequests | length) > 0));
	# Its own predicate for the same reason: CONFLICT outranks ON-HOLD in the
	# status word and swallows it, and an on-hold pull is not free for anybody
	# to pick up however takeable the rest of it looks.
	def onHold: allLabels | any(test("on hold|blocked|waiting[ _-]for"; "i"));
	# Whether a changes-requested review has been answered by a push. GitHub
	# keeps reviewDecision at CHANGES_REQUESTED until that same reviewer
	# reviews again: new commits never clear it, and neither does a COMMENTED
	# review from them. So the field alone says "changes requested" long after
	# the author has done them, which reads as an action of yours that is not
	# one. The head moving is the answer: every changes-requested review
	# carries the commit it was made against, so a pull whose reviews all point
	# at a commit that is no longer the head has been pushed to since. Empty
	# reviews, or no head, means unanswered, which keeps a pull with more
	# reviews than the API returned on the old behavior rather than clearing it
	# wrongly.
	def changesAddressed:
		(.headRefOid // "") as $head |
		[ (.reviews // [])[] | select(.state == "CHANGES_REQUESTED") ] as $changesRequested |
		($head != "") and (($changesRequested | length) > 0) and
		(($changesRequested | any(.commit.oid == $head)) | not);
	def status:
		allLabels as $l |
		if (.mergeable == "CONFLICTING") or ($l | any(test("conflict"; "i"))) then "CONFLICT"
		elif .isDraft then "DRAFT"
		# The label is a statement somebody made by hand and stands until they
		# take it off; reviewDecision is machinery, and changesAddressed tells
		# a pull still owing the work from one already pushed.
		elif ((.reviewDecision == "CHANGES_REQUESTED") and ((changesAddressed) | not)) or
			($l | any(test("changes needed"; "i"))) then "CHANGES"
		elif $l | any(. == "pr-check - failure") then "CHECK-FAIL"
		elif onHold then "ON-HOLD"
		# Ranked here, under CONFLICT / DRAFT / CHANGES, because every one of
		# those is fixed by pushing new commits, which invalidates a pr-check
		# against the old head: asking for one first would be wasted work. Once
		# the rebase lands the pull falls through to here. Not on the EE repo,
		# where pr-check is no part of the backport flow (44 of its 46 open
		# pulls carry no such label), so $prChecked turns this off there.
		elif ($prChecked == "true") and (($l | any(test("^pr-check"))) | not)
			then "NO-CHECK"
		elif (.reviewDecision == "APPROVED") or
			($l | any(test("ready to merge|ready to forward|dev approved|passed review|qa passed"; "i"))) then "READY"
		elif ($l | any(test("review in progress"; "i"))) or ((.assignees | length) > 0) then "IN-REVIEW"
		elif reviewNeeded then "REVIEW"
		elif $l | any(. == "ci:forward") then "FORWARDED"
		# Last, not next to CHECK-FAIL: a backport all but always has some batch
		# red (43 of the 44 open EE pulls did), so ranking it high says nothing.
		elif $l | any(test("^ci:test.* - failure")) then "TEST-FAIL"
		else "OPEN" end;
	def sender:
		if (.headRefName | test("-sender-")) then (.headRefName | sub(".*-sender-"; "")) else .author.login end;
	# Whether the pull is yours. Never .author.login alone: the CI bot authors
	# every pull it forwards, so on the mirror your own work reads as another
	# person and drops out of ON YOU and off the dashboard.
	def isMine: (.author.login == $me) or (sender == $senderMe);
	def assignee: (.assignees | map(.login) | join(",")) | if . == "" then "-" else . end;
	# What this pull needs from you, and nothing else: every value but "-" is
	# an action of yours. What somebody else owes it is not reported here, it
	# is reported by STATUS (IN-REVIEW), by ASSIGNEE, and by the census under
	# the table, which is where a pull waiting on another person belongs.
	#   a pull of yours came back with something to fix -> "you". Decided by
	#     who sent it, never by who authored it, so a forwarded pull on the
	#     mirror is still yours
	#   your own pull conflicting, somebody else already reviewing it -> "ask":
	#     yours to rebase, but a force push under a review in progress destroys
	#     that review, so ask the person in ASSIGNEE first
	#   any other pull of yours -> "-". Healthy, or waiting on a reviewer who
	#     has not turned up, which is somebody to chase and not an action
	#   you are the assignee or the requested reviewer -> "on-review", the
	#     review is on you. Also a pull somebody opened on your own fork and
	#     nobody has taken, which is a review request to you by construction
	#   review needed and nobody assigned -> "need-review", free for you to
	#     take. Conflicting counts too: CONFLICT outranks REVIEW in the status
	#     word and would otherwise swallow the only half of that pull which is
	#     takeable. The rebase belongs to whoever wrote it, the review does not
	#   on hold, whatever else it is -> "-". The same swallowing works the
	#     other way round for ON-HOLD, which CONFLICT also outranks: an
	#     on-hold pull would arrive as CONFLICT and be offered as takeable,
	#     when its author has asked for it to be left alone
	#
	# need-review only on a queue of your own ($yours: your fork, your team
	# fork, the mirror, the EE repo), because an unclaimed pull is only yours
	# to pick up on a queue you belong to. On a fork of another team it stays
	# "-", unless the review was requested from you by name.
	def onYou:
		([.assignees[].login] + [.reviewRequests[] | (.login // .slug // "")]) as $owners |
		status as $status |
		# Assignees only, not review requests: a request sitting on the team
		# account means nobody has taken it, and there is no one person to ask.
		(.assignees | map(select(.login != $me)) | length > 0) as $claimedByOther |
		((.assignees | length) == 0) as $unclaimed |
		if isMine then
			(if ($yours == "true") and ($status == "CONFLICT") and $claimedByOther
				then "ask"
			elif ([ "CONFLICT", "CHANGES", "CHECK-FAIL", "NO-CHECK", "TEST-FAIL", "ON-HOLD" ] | any(. == $status))
				then "you"
			else "-" end)
		elif ($owners | any(. == $me)) then "on-review"
		elif ($repoOwner == $me) and $unclaimed then "on-review"
		elif ($yours == "true") and $unclaimed and (onHold | not) and
			(($status == "REVIEW") or
				(([ "CONFLICT", "NO-CHECK" ] | any(. == $status)) and reviewNeeded))
			then "need-review"
		else "-" end;
	# The marker _lfrPullsPaint colours a row by.
	def paint: if isMine or (onYou != "-") then "A" else "." end;
	def age: ((now - (.createdAt | fromdate)) / 86400 | floor | tostring) + "d";
	# The words in the order they are ranked in, so a census reads worst news
	# first and keeps the same shape between runs, where sorting by count would
	# reshuffle it every time a pull moves.
	def statusOrder: [ "CONFLICT", "DRAFT", "CHANGES", "CHECK-FAIL", "ON-HOLD",
		"NO-CHECK", "READY", "IN-REVIEW", "REVIEW", "FORWARDED", "TEST-FAIL",
		"OPEN" ];
	def onYouOrder: [ "you", "ask", "need-review", "on-review" ];
	# The labels themselves, which STATUS cannot report: it keeps the worst
	# word per pull, so a conflicting pull that is also on hold and waiting for
	# a backend review is counted once and its other two labels are never
	# printed. A pull appears here once per label it carries, so these sum past
	# the section total, and a pull carrying none counts as untriaged.
	def labelWords:
		[ .[] | workflowLabels[] ] +
		[ .[] | select((workflowLabels | length) == 0) | "untriaged" ];
	# "4 CONFLICT, 3 CHANGES, ...". Any word $order does not list still counts,
	# sorted after the ones it does, so a value added to status or onYou without
	# being added here is under-reported in position only, never dropped.
	def census($order; $words):
		($words | group_by(.) | map({ (.[0]): length }) | add // {}) as $counts |
		(($order | map(select($counts[.]))) + (($counts | keys) - $order | sort)) as $keys |
		[ $keys[] | "\($counts[.]) \(.)" ] | join(", ");
	# The same, for words with no ranking to follow: most first, then by name
	# so a tie does not reshuffle between runs.
	def censusByCount($words):
		[ $words | group_by(.)[] | { word: .[0], n: length } ] |
		sort_by([ -.n, .word ]) | map("\(.n) \(.word)") | join(" | ");
	# Whether a pull is worth a place on the dashboard, which shows your own
	# queues and drops what belongs to somebody else. Three ways in:
	#   it is yours, sent either way, so it stays however healthy it looks
	#   ON YOU says something, so it is waiting on you or free for you to take
	#   it carries no workflow label at all, which is itself the finding: nobody
	#     has triaged it, so it is sitting on the fork with no state
	def relevant:
		isMine or (onYou != "-") or ((workflowLabels | length) == 0);
'

# Colour each row of an open-pulls table by what it is to you, then drop the
# marker column that says so: "A" for a pull of yours or one whose ON YOU
# asks something of you, bright white, and "." for the rest, light grey, so
# what concerns you is what stands out. "H" marks the header, left alone. The marker rides as the first column so column(1) lays the table out
# without counting any escape, and it is cut back off here as "X  ", one
# character and the two spaces column(1) puts after it. Colour follows the
# same rule as the links: a terminal by default, LFR_PULLS_COLOR to force it
# either way, and NO_COLOR honoured. The caller decides that and passes "true"
# as $1, because this runs mid-pipe, where [ -t 1 ] sees the pipe and never
# the terminal.
_lfrPullsPaint() {
	local on="${1:-false}"

	awk -v on="${on}" '{
		marker = substr($0, 1, 1)
		rest = substr($0, 4)
		if ((on == "true") && (marker == "A")) {
			print "  \033[1;38;5;231m" rest "\033[0m"
		}
		else if ((on == "true") && (marker == ".")) {
			print "  \033[38;5;250m" rest "\033[0m"
		}
		else {
			print "  " rest
		}
	}'
}

_lfrPullsColorOn() {
	[ -n "${NO_COLOR:-}" ] && [ "${LFR_PULLS_COLOR:-auto}" != "on" ] && return 1

	case "${LFR_PULLS_COLOR:-auto}" in
	off) return 1 ;;
	on) return 0 ;;
	*) [ -t 1 ] ;;
	esac
}

# Make each row's #<number> a clickable link to its pull. The URL rides in an
# OSC 8 escape and the visible text stays "#12345", so no column grows and
# `column -t` cannot be thrown off: this runs AFTER the table is laid out, for
# the same reason the emoji are stripped from LABELS.
#
# On a terminal by default, never when the output is piped or redirected, since
# a file full of escapes is worse than no links. LFR_PULLS_LINKS forces it
# either way: `on` even when piped, `off` never.
_lfrPullsLinkify() {
	local repo="${1}" esc

	_lfrPullsLinksOn || { cat; return; }

	esc=$'\033'
	sed -E "s|^([[:space:]]*(${esc}\\[[0-9;]*m)?)#([0-9]+)|\1${esc}]8;;https://github.com/${repo}/pull/\3${esc}\\\\#\3${esc}]8;;${esc}\\\\|"
}

# Whether a #number should be rendered as an OSC 8 link at all: on a terminal
# by default, never when the output is piped or redirected, and forced either
# way by LFR_PULLS_LINKS. Its own predicate because a listing that has a URL
# per row (the rejected one) prints that URL as a column instead when the
# answer is no, rather than losing it inside an escape nobody will see.
_lfrPullsLinksOn() {
	case "${LFR_PULLS_LINKS:-auto}" in
	off) return 1 ;;
	on) return 0 ;;
	*) [ -t 1 ] ;;
	esac
}

# The same OSC 8 rewrite, but each #number goes to its own URL rather than to
# the pull it names. $1 is the map, one "number<TAB>url" per line, and a number
# missing from it is left as plain text. Runs AFTER column -t for the reason
# _lfrPullsLinkify does: the escape is bytes the layout must not count.
_lfrPullsLinkifyUrls() {
	local map="${1}" esc script number url

	_lfrPullsLinksOn || { cat; return; }

	esc=$'\033'
	script=""
	while IFS=$'\t' read -r number url; do
		[ -z "${number}" ] || [ -z "${url}" ] && continue
		script="${script}s|^([[:space:]]*)#${number}\\b|\\1${esc}]8;;${url}${esc}\\\\#${number}${esc}]8;;${esc}\\\\|;"
	done <<<"${map}"

	[ -z "${script}" ] && { cat; return; }
	sed -E "${script}"
}

# The open pulls on a repo, with everything STATUS is derived from. headRefOid
# and reviews ride along for changesAddressed, which needs the commit each
# changes-requested review was made against; they cost one field each on the
# same call, not a second request.
_lfrPullsOpenJsonFetch() {
	gh pr list --repo "${1}" --state open --limit 200 \
		--json number,title,headRefName,author,isDraft,mergeable,reviewDecision,assignees,reviewRequests,labels,createdAt,headRefOid,reviews 2>/dev/null
}

# Declared here and left empty for good: the copy that ever holds anything is a
# `local -A` of the same name inside _lfrPullsDashboard, which shadows this one
# for that call. What this declaration buys is the subscript. Without it the
# lookup below reads an undeclared, therefore indexed, array, and bash evaluates
# `owner/repo` as arithmetic and fails with "division by 0" on every command that
# does not prefetch.
declare -A _lfrPullsOpenCache=()

# The open pulls on a repo, served from _lfrPullsOpenCache when the caller
# prefetched that repo, else fetched now. A repo missing from the cache is
# fetched here, so a listing is never quietly left out when its parallel fetch
# failed; it just pays for a retry.
#
# The cache being that `local`, which bash's dynamic scoping makes visible down
# here, is the point: it lives exactly as long as the one command that filled it,
# so nothing can serve it to a later command, and an interrupt takes it away with
# the stack rather than leaving it behind.
_lfrPullsOpenJson() {
	if [ -n "${_lfrPullsOpenCache[${1}]:-}" ]; then
		printf '%s\n' "${_lfrPullsOpenCache[${1}]}"
		return 0
	fi
	_lfrPullsOpenJsonFetch "${1}"
}

# Fetch the open pulls of every repo in "$@" at once, into the associative array
# named $1. Each is an independent listing on a different repo, and a dashboard
# spends nearly all its time waiting on them one after another (0.8s + 1.5s +
# 0.6s + 1.9s), so together they cost the slowest instead of the sum.
#
# A background job is a subshell and cannot assign to the array, hence the temp
# files. The backgrounding sits inside a subshell of its own for two reasons: an
# interactive shell announces every async command ("[1] 806366") and its
# completion, which would litter the tables, and a bare `wait` there would also
# wait on whatever jobs you already had running.
_lfrPullsPrefetchOpen() {
	local -n _cache="${1}"
	shift

	local dir repo file
	dir="$(mktemp -d -t lfr-pulls-open.XXXXXXXX 2>/dev/null)" || return 0

	(
		for repo in "$@"; do
			_lfrPullsOpenJsonFetch "${repo}" >"${dir}/${repo//\//_}" &
		done
		wait
	)

	for repo in "$@"; do
		file="${dir}/${repo//\//_}"
		# Empty is how a failed fetch arrives. Leaving it out of the cache is
		# what hands that repo back to _lfrPullsOpenJson to retry.
		[ -s "${file}" ] && _cache["${repo}"]="$(cat "${file}")"
	done

	rm -rf "${dir}"
}

# The census a section prints under its table: how many of its open pulls sit
# in each STATUS, then how many are on you, then how many carry each
# label. Counted over every open pull the section fetched rather than the rows
# its filter kept, because "5 of 14" is only worth reading next to what the
# other 9 are doing. Three lines out, any of which can come back empty.
_lfrPullsCensus() {
	printf '%s' "${1}" | jq -r --arg me "${2}" --arg senderMe "${3}" \
		--arg repoOwner "${4}" --arg yours "${5}" --arg prChecked "${6}" \
		--arg mirrorOwner "${LFR_PULLS_REPO%%/*}" \
		"${_LFR_PULLS_JQ}"' census(statusOrder; [.[] | status]),
			census(onYouOrder; [.[] | onYou | select(. != "-")]),
			censusByCount(labelWords)'
}

# The count line closing a section, with that census on it: "5 of 14 open
# pull(s): 4 CONFLICT, 3 CHANGES, ...", then "on you: 1 you, 3 need-review"
# and, with `detail` as $9, "labels: ..." under it. $1 rows kept, $2 open in
# total, the rest what the census needs. The labels line is detail only because
# on the team fork it counts every teammate's pulls, which buries the two lines
# above it in the plain view.
_lfrPullsCountLine() {
	local kept="${1}" total="${2}" detail="${9:-}" census statusCensus onYouCensus labelCensus
	census="$(_lfrPullsCensus "${3}" "${4}" "${5}" "${6}" "${7}" "${8}")"
	statusCensus="$(printf '%s\n' "${census}" | sed -n 1p)"
	onYouCensus="$(printf '%s\n' "${census}" | sed -n 2p)"
	labelCensus="$(printf '%s\n' "${census}" | sed -n 3p)"

	if [ "${kept}" -eq 0 ]; then
		printf '  none of the %s open pull(s)%s.\n' "${total}" "${statusCensus:+: ${statusCensus}}"
	else
		printf '  %s of %s open pull(s)%s.\n' "${kept}" "${total}" "${statusCensus:+: ${statusCensus}}"
	fi
	[ -n "${onYouCensus}" ] && printf '  on you: %s.\n' "${onYouCensus}"
	[ -n "${detail}" ] && [ -n "${labelCensus}" ] && printf '  labels: %s\n' "${labelCensus}"
	return 0
}

# Print one fork's open pulls under <heading>, newest first, keeping only what
# the jq expression <filter> selects. `detail` as $4 adds the age and the pull's
# own labels; without it the table stays PR / AUTHOR / STATUS / ASSIGNEE / TITLE.
_lfrPullsForkSection() {
	local repo="${1}" filter="${2}" heading="${3}" detail="${4:-}" json rows total header row
	local me="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}" yours="false"
	local prChecked="true" senderMe color="false"
	_lfrPullsColorOn && color="true"
	senderMe="$(_lfrPullsSenderOwner "${me}" "${me}")"
	case "${repo}" in
	"${me}"/* | "${LFR_PULLS_TEAM:-${LFR_GIT_FORK_ORG:-::none::}}"/* | "${LFR_PULLS_EE_REPO}" | "${LFR_PULLS_REPO}") yours="true" ;;
	esac
	[ "${repo}" = "${LFR_PULLS_EE_REPO}" ] && prChecked="false"

	printf '\n%s\n' "${heading}"

	json="$(_lfrPullsOpenJson "${repo}")"
	if [ -z "${json}" ]; then
		printf '  (no such repo, or it has no pulls: %s)\n' "${repo}"
		return 0
	fi
	total="$(printf '%s' "${json}" | jq 'length')"

	if [ -n "${detail}" ]; then
		header='H\tPR\tAUTHOR\tSTATUS\tON YOU\tASSIGNEE\tAGE\tLABELS\tTITLE'
		row='"\(paint)\t#\(.number)\t\(.author.login)\t\(status)\t\(onYou)\t\(assignee)\t\(age)\t\((workflowLabels | join(" | ")) | if . == "" then "-" else . end)\t\(.title[0:60])"'
	else
		header='H\tPR\tAUTHOR\tSTATUS\tON YOU\tASSIGNEE\tTITLE'
		row='"\(paint)\t#\(.number)\t\(.author.login)\t\(status)\t\(onYou)\t\(assignee)\t\(.title[0:60])"'
	fi

	rows="$(printf '%s' "${json}" | jq -r --arg me "${me}" --arg senderMe "${senderMe}" \
		--arg repoOwner "${repo%%/*}" --arg yours "${yours}" \
		--arg prChecked "${prChecked}" --arg mirrorOwner "${LFR_PULLS_REPO%%/*}" \
		"${_LFR_PULLS_JQ} ${filter} | sort_by(.number) | reverse | .[] | ${row}")"

	if [ -z "${rows}" ]; then
		if [ "${total}" -eq 0 ]; then
			printf '  no open pulls.\n'
		else
			_lfrPullsCountLine 0 "${total}" "${json}" "${me}" "${senderMe}" \
				"${repo%%/*}" "${yours}" "${prChecked}" "${detail}"
		fi
		return 0
	fi
	printf "${header}"'\n%s\n' "${rows}" | column -t -s $'\t' | _lfrPullsPaint "${color}" |
		_lfrPullsLinkify "${repo}"
	_lfrPullsCountLine "$(printf '%s\n' "${rows}" | grep -c .)" "${total}" \
		"${json}" "${me}" "${senderMe}" "${repo%%/*}" "${yours}" "${prChecked}" \
		"${detail}"
}

# Print the mirror's open pulls: the same STATUS as a fork, plus AHEAD, which
# only means something here because the mirror is the merge queue.
_lfrPullsMirrorSection() {
	local mode="${1}" detail="${2:-}" filter='.' json rows header row
	local me="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}"
	local senderMe color="false"
	_lfrPullsColorOn && color="true"
	senderMe="$(_lfrPullsSenderOwner "${me}" "${me}")"

	# A pull is one person's when they authored it directly or when the bot
	# forwarded it from their fork, which the head branch records as
	# -sender-<owner>.
	local person="" senderOwner=""
	if [ "${mode}" = "mine" ]; then
		person="${me}"
	elif [ "${mode}" != "all" ]; then
		person="${mode}"
	fi
	[ -n "${person}" ] && senderOwner="$(_lfrPullsSenderOwner "${person}" "${me}")"

	if [ -n "${person}" ]; then
		filter="[.[] | select((.headRefName | test(\"-sender-${senderOwner}$\")) or (.author.login == \"${person}\"))]"
	elif [ "${mode}" != "all" ]; then
		echo "lfrPulls: set LFR_PULLS_USER in ${_lfrPullsDir}/lfr-pulls.local.conf, or pass 'all'." >&2
		return 1
	fi

	json="$(_lfrPullsOpenJson "${LFR_PULLS_REPO}")" || return 1

	if [ -n "${detail}" ]; then
		header='H\tPR\tSENDER\tAHEAD\tSTATUS\tON YOU\tAGE\tLABELS\tTITLE'
		row='"\(paint)\t#\($n)\t\(sender)\t\($nums | map(select(. < $n)) | length)\t\(status)\t\(onYou)\t\(age)\t\((workflowLabels | join(" | ")) | if . == "" then "-" else . end)\t\(.title[0:60])"'
	else
		header='H\tPR\tSENDER\tAHEAD\tSTATUS\tON YOU\tTITLE'
		row='"\(paint)\t#\($n)\t\(sender)\t\($nums | map(select(. < $n)) | length)\t\(status)\t\(onYou)\t\(.title[0:60])"'
	fi

	# AHEAD = how many open PRs are older (lower number), so roughly how many are
	# in front of it in the merge queue; a low number means it is close.
	rows="$(printf '%s' "${json}" | jq -r --arg me "${me}" --arg senderMe "${senderMe}" \
		--arg repoOwner "${LFR_PULLS_REPO%%/*}" --arg yours "true" \
		--arg prChecked "true" --arg mirrorOwner "${LFR_PULLS_REPO%%/*}" "${_LFR_PULLS_JQ}
		(map(.number) | sort) as \$nums |
		${filter} | sort_by(.number) | .[] | (.number) as \$n | ${row}")" || return 1

	local total
	total="$(printf '%s' "${json}" | jq 'length')"

	printf '\n%s open pulls (%s)\n' "${LFR_PULLS_REPO}" "${mode}"
	if [ -z "${rows}" ]; then
		_lfrPullsCountLine 0 "${total}" "${json}" "${me}" "${senderMe}" \
			"${LFR_PULLS_REPO%%/*}" true true "${detail}"
	else
		printf "${header}"'\n%s\n' "${rows}" | column -t -s $'\t' | _lfrPullsPaint "${color}" |
			_lfrPullsLinkify "${LFR_PULLS_REPO}"
		_lfrPullsCountLine "$(printf '%s\n' "${rows}" | grep -c .)" "${total}" \
			"${json}" "${me}" "${senderMe}" "${LFR_PULLS_REPO%%/*}" true true \
			"${detail}"
	fi
	printf '  %s\n' "$(_lfrPullsLastActiveLine)"
}

# One fork's open pulls: `lfrPulls liferay-frontend`, `lfrPulls headless`, or a
# GitHub username. All of them by default; a second word keeps one person's,
# either `mine` or any login, so `lfrPulls page-management achaparro` asks the
# same question about somebody else.
#
# A first word carrying a slash is taken as a whole owner/repo and used as it
# stands, which is how any other repo is reached: `lfrPulls
# liferay/liferay-portal-ee mariuo`. Without a slash it is an owner, and the
# repo is LFR_PULLS_FORK_REPO, because a bare word cannot be told apart from a
# team or a login.
_lfrPullsFork() {
	local repo="" author="" detail="" a
	for a in "$@"; do
		case "${a}" in
		mine | -m | --mine) author="${LFR_PULLS_AUTHOR_ME}" ;;
		all | -a | --all) author="" ;;
		detail | -d | --detail) detail="detail" ;;
		-h | --help) _lfrPullsHelp; return 0 ;;
		*)
			if [ -z "${repo}" ]; then
				case "${a}" in
				*/*) repo="${a}" ;;
				*) repo="$(_lfrPullsResolveOwner "${a}")/${LFR_PULLS_FORK_REPO}" || return 1 ;;
				esac
			elif [ -z "${author}" ]; then
				author="${a#@}"
			else
				echo "lfrPulls: unknown argument '${a}' (want a team or user, then a login, mine, or all)." >&2
				return 1
			fi
			;;
		esac
	done

	if [ -z "${repo}" ]; then
		echo "lfrPulls team: pass a team, a GitHub user, or an owner/repo, e.g. lfrPulls liferay-frontend. See lfrPulls teams." >&2
		return 1
	fi

	local filter='.' scope="all"
	if [ "${author}" = "${LFR_PULLS_AUTHOR_ME}" ]; then
		author="$(_lfrPullsMineUser fork)" || return 1
	fi
	if [ -n "${author}" ]; then
		filter="[.[] | select(.author.login == \"${author}\")]"
		scope="${author}"
	fi

	_lfrPullsForkSection "${repo}" "${filter}" \
		"${repo} open pulls (${scope})" "${detail}"
}

# The product teams, with how many pulls each has open on its fork right now.
# The names come from the list in this file; when a local clone is reachable it
# is checked against .github/CODEOWNERS, which is where the list came from.
_lfrPullsTeams() {
	local dir t rows="" count

	echo "Counting each team's open pulls..." >&2
	for t in ${_LFR_PULLS_TEAMS}; do
		count="$(_lfrPullsCount "repo:${t}/${LFR_PULLS_FORK_REPO} is:pr is:open")"
		rows="${rows}${t}	${t#liferay-}	${count:-?}
"
	done
	printf 'TEAM\tSHORT NAME\tOPEN\n%s' "${rows}" | column -t -s $'\t'

	printf '\nName a team in full, without the prefix, or by any unique part of it:\n'
	printf '  lfrPulls liferay-frontend, lfrPulls frontend, lfrPulls experience\n'
	printf 'A name matching no team is used as a GitHub username.\n'

	# Read off GitHub so a stale clone cannot hide a new team, and off the local
	# ref only when that fails.
	local codeowners where="${LFR_PULLS_UPSTREAM_REPO}"
	if ! codeowners="$(gh api -H 'Accept: application/vnd.github.raw' \
		"repos/${LFR_PULLS_UPSTREAM_REPO}/contents/.github/CODEOWNERS" 2>/dev/null)"; then
		dir="$(_lfrPullsMasterDir teams 2>/dev/null)" || return 0
		codeowners="$(git -C "${dir}" show "${LFR_PULLS_MASTER_REF}:.github/CODEOWNERS" 2>/dev/null)"
		where="${LFR_PULLS_MASTER_REF}"
	fi

	local known=" ${_LFR_PULLS_TEAMS//[$'\n\t']/ } "
	local -a missing=()
	while IFS= read -r t; do
		[[ "${known}" == *" ${t} "* ]] || missing+=("${t}")
	done < <(printf '%s\n' "${codeowners}" | grep -oE '@[A-Za-z0-9_-]+' | tr -d '@' | sort -u)

	[ "${#missing[@]}" -gt 0 ] &&
		printf '\nCODEOWNERS on %s also owns code as: %s. Add them to _LFR_PULLS_TEAMS.\n' \
			"${where}" "${missing[*]}"
	return 0
}

# Your backports on the EE repo. Yours by default, since everybody's backports
# share that one repo; `all` shows the rest.
_lfrPullsEE() {
	local author="${LFR_PULLS_AUTHOR_ME}" detail="" a
	for a in "$@"; do
		case "${a}" in
		mine | -m | --mine) author="${LFR_PULLS_AUTHOR_ME}" ;;
		all | -a | --all) author="" ;;
		detail | -d | --detail) detail="detail" ;;
		'') ;;
		-h | --help) _lfrPullsHelp; return 0 ;;
		*) author="${a#@}" ;;
		esac
	done

	local filter='.' scope="all"
	if [ "${author}" = "${LFR_PULLS_AUTHOR_ME}" ]; then
		author="$(_lfrPullsMineUser ee)" || return 1
	fi
	if [ -n "${author}" ]; then
		filter="[.[] | select(.author.login == \"${author}\")]"
		scope="${author}"
	fi

	_lfrPullsForkSection "${LFR_PULLS_EE_REPO}" "${filter}" \
		"${LFR_PULLS_EE_REPO} open pulls, backports (${scope})" "${detail}"
}

# The four queues a change of yours passes through, in the order it travels:
# the mirror it is waiting to be merged on, your team's fork where it was
# reviewed, your own fork where teammates are waiting on you, and the EE repo,
# which a backport goes to instead of travelling that road.
#
# The mirror answers twice, so its rejections come directly under its open
# pulls rather than at the end: both are the same repo, one saying what Brian
# is holding and the other what he sent back.
_lfrPullsDashboard() {
	local detail="${1:-}" mirrorMode="${2:-mine}" person="" forkUser

	case "${mirrorMode}" in
	mine | all) ;;
	*) person="${mirrorMode}" ;;
	esac

	# Resolved here, not at source time: LfrGit's conf can load after this file,
	# and LFR_GIT_FORK_ORG is where the team fork comes from.
	local team="${LFR_PULLS_TEAM:-${LFR_GIT_FORK_ORG:-}}"
	forkUser="${person:-${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}}"

	# Every listing the sections below ask for, named before the first one
	# prints, which is what lets them all be fetched at once. The conditions are
	# the same ones that decide whether each section runs.
	local openRepos=("${LFR_PULLS_REPO}")
	[ -n "${team}" ] && openRepos+=("${team}/${LFR_PULLS_FORK_REPO}")
	[ -n "${forkUser}" ] && [ "${forkUser}" != "${team}" ] &&
		openRepos+=("${forkUser}/${LFR_PULLS_FORK_REPO}")
	[ -n "${LFR_PULLS_EE_REPO}" ] && openRepos+=("${LFR_PULLS_EE_REPO}")

	local -A _lfrPullsOpenCache=()
	_lfrPullsPrefetchOpen _lfrPullsOpenCache "${openRepos[@]}"

	_lfrPullsMirrorSection "${mirrorMode}" "${detail}" || return 1

	# Straight under the mirror's open pulls, because it is the same repo
	# answering the other half of the question: what Brian is holding, then
	# what he sent back. Not a queue, so it is not one of the four, and only a
	# rejection whose ticket has still not landed is printed, which makes it
	# work owed and nothing else. Skipped on `all`, where "rejected" over the
	# whole repo is every pull Brian ever turned down and says nothing about
	# anybody.
	[ "${mirrorMode}" != "all" ] &&
		_lfrPullsRejectedSection "${forkUser}" "${LFR_PULLS_REJECTED_DAYS:-30}"

	# The team fork is the one queue that carries everybody, so on `mine` it is
	# narrowed to what concerns you: your own pulls, the ones ON YOU speaks for,
	# and the untriaged ones. The count line still gives the section total, and
	# `all` widens it back to every pull.
	local teamFilter='.' teamScope="yours, plus reviews and untriaged"
	if [ "${mirrorMode}" = "all" ]; then
		teamScope="all"
	elif [ -n "${person}" ]; then
		teamFilter="[.[] | select(.author.login == \"${person}\")]"
		teamScope="${person}"
	else
		teamFilter='[.[] | select(relevant)]'
	fi

	if [ -n "${team}" ]; then
		_lfrPullsForkSection "${team}/${LFR_PULLS_FORK_REPO}" "${teamFilter}" \
			"${team}/${LFR_PULLS_FORK_REPO} open pulls (your team: ${teamScope})" "${detail}"
	fi

	if [ -n "${forkUser}" ] && [ "${forkUser}" != "${team}" ]; then
		local forkHeading="on your fork"
		[ -n "${person}" ] && forkHeading="on the fork of ${person}"
		_lfrPullsForkSection "${forkUser}/${LFR_PULLS_FORK_REPO}" '.' \
			"${forkUser}/${LFR_PULLS_FORK_REPO} open pulls (${forkHeading})" "${detail}"
	fi

	[ -n "${LFR_PULLS_EE_REPO}" ] && _lfrPullsEE "${mirrorMode}" "${detail}"
	return 0
}

# With no argument, the three queues a pull travels through. `mine` or `all`
# narrows it to the mirror alone; a team or a GitHub user names one fork.
lfrPulls() {
	case "${1:-}" in
	stats | st | s) shift; _lfrPullsStats "$@"; return ;;
	week | recent | w) shift; _lfrPullsWeek "$@"; return ;;
	rejected | rej | r) shift; _lfrPullsRejected "$@"; return ;;
	ticket | t) shift; _lfrPullsTicket "$@"; return ;;
	teams) shift; _lfrPullsTeams "$@"; return ;;
	ee | backport | backports) shift; _lfrPullsEE "$@"; return ;;
	team | fork | f) shift; _lfrPullsFork "$@"; return ;;
	[A-Za-z]*-[0-9]*) _lfrPullsTicket "$@"; return ;;
	'') _lfrPullsDashboard; return ;;
	esac

	local mode="" a
	for a in "$@"; do
		case "${a}" in
		mine | -m | --mine) mode="mine" ;;
		all | -a | --all) mode="all" ;;
		-h | --help) _lfrPullsHelp; return 0 ;;
		*) _lfrPullsFork "$@"; return ;;
		esac
	done

	_lfrPullsMirrorSection "${mode}"
}

# Short aliases.
lfrp() { lfrPulls "$@"; }
lfrpw() { lfrPulls week "$@"; }
lfrpr() { lfrPulls rejected "$@"; }
lfrps() { lfrPulls stats "$@"; }
lfrpt() { lfrPulls ticket "$@"; }
lfrpf() { lfrPulls team "$@"; }
lfrpteams() { lfrPulls teams "$@"; }
lfrpe() { lfrPulls ee "$@"; }
