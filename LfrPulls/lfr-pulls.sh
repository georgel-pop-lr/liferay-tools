# lfr-pulls.sh — list open pull requests along the road a change travels.
#
# Source this from your shell rc (normally via the root lfrTools.sh). It defines:
#     lfrPulls        the four queues a pull of yours passes through
#     lfrPulls stats  per-month counts of PRs sent, merged, and rejected
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
		lfrPulls — list open pull requests along the road a change travels.

		Usage (each command has a short form and an alias):
		  lfrPulls                         the four queues, in order: yours on the
		                                   mirror, your team's fork (narrowed, see
		                                   below), your own fork (teammates waiting
		                                   on your review), and your backports on
		                                   the EE repo
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
		  lfrPulls week [days] [<login>]  (w, lfrpw)
		                                   your pulls closed in the last days
		                                   (default 7): PR / SENDER / STATUS / TITLE
		  lfrPulls stats [mine|all|<login>] [months]  (s, lfrps)
		                                   per-month counts of PRs sent, merged, and
		                                   rejected for you (mine); sent and closed
		                                   for the whole repo (all); months default 12

		mine matches PRs forwarded from your fork or opened by you; all shows
		every PR. The AHEAD column is how many open pulls are older (lower
		number), i.e. roughly how many are in front of it in the merge queue, so
		a small number means yours is close. The list ends with when the repo was
		last active (the most recent pull merged or rejected) and how long ago.

		STATUS is read off the pull itself, not off one team's labels, since every
		fork keeps its own vocabulary. Worst news first:
		  CONFLICT    GitHub reports it CONFLICTING, or a conflict label is on it
		  DRAFT       opened as a draft
		  CHANGES     changes requested, by review or by label
		  CHECK-FAIL  carries pr-check - failure
		  ON-HOLD     on hold, blocked, or waiting for something (waiting_for_dev)
		  READY       approved, ready to merge, ready to forward, QA passed
		  IN-REVIEW   review in progress, or somebody is assigned to it
		  REVIEW      review needed and nobody has taken it
		  FORWARDED   ci:forward is on it, so it is on its way to the mirror
		  TEST-FAIL   a ci:test batch is red and nothing above applies. Ranked
		              here because a backport nearly always has one red batch
		  OPEN        none of the above

		ON YOU says whether the next move is yours. It reads:
		  you     you are the assignee or the requested reviewer; a pull of yours
		          came back CONFLICT / CHANGES / CHECK-FAIL / TEST-FAIL / ON-HOLD;
		          somebody opened it on your own fork, which is a review request
		          by construction; or it is conflicting with nobody assigned, so
		          it is going nowhere until someone picks it up
		  ask     a pull of yours is conflicting and somebody else is already
		          reviewing it. Yours to rebase, but a force push under a review
		          in progress destroys that review, so ask the person in
		          ASSIGNEE first
		  review  review needed and nobody has taken it, so it is free for you
		  -       nothing for you to do
		The last three only fire on a queue of your own (your fork, your team
		fork, the mirror, the EE repo). On a fork of another team an unclaimed
		pull is not yours to pick up, so it stays "-". A pull of yours that
		another person is reviewing is not on you.

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
		ticket's commits on the master ref; their date tells you which resend
		landed, and "nothing landed yet" with the ref tip tells you the ref may
		just be stale (lfrGitUpdateMaster).

		stats (mine) counts the PRs you opened directly, by month:
		  SENT      PRs you created that month
		  MERGED    of those closed that month, the ones whose exact title is a
		            commit on the master ref (Brian merged that pull in)
		  REJECTED  closed that month whose title is NOT on master (just closed)
		A pull is merged only if its own title landed, so a superseded resend of a
		ticket whose other work merged still counts as rejected. Keep the master
		ref fetched (e.g. lfrGitUpdateMaster). stats all cannot title-match every
		PR, so it shows only sent and closed for the whole repo. stats then prints
		the same four queues in full, adding each pull's age and its own labels,
		and stats all widens the mirror section to every open pull as well.

		Config (lfr-pulls.local.conf):
		  LFR_PULLS_REPO         repo to list (default brianchandotcom/liferay-portal)
		  LFR_PULLS_MINE_ORG     the owner in the -sender-<owner> of a pull you
		                         forwarded, so your own fork (default your login)
		  LFR_PULLS_USER         your GitHub login (default the gh-authed user)
		  LFR_PULLS_TEAM         your team's account (default LFR_GIT_FORK_ORG)
		  LFR_PULLS_FORK_REPO    the repo an owner with no slash means (default
		                         liferay-portal, the name in LFR_PULLS_REPO)
		  LFR_PULLS_EE_REPO      backports repo (default liferay/liferay-portal-ee)
		  LFR_PULLS_MASTER_REPO  local clone to grep for merges (default: cwd repo)
		  LFR_PULLS_MASTER_REF   master ref to grep (default brian/master)
		  LFR_PULLS_LINKS        on|off|auto (default auto): make each #number a
		                         clickable link on a terminal, plain when piped
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
_lfrPullsStatsMine() {
	local months="${1}" person="${2}" dir
	dir="$(_lfrPullsMasterDir)" || return 1

	local windowStart sinceDate json
	windowStart="$(date -d "$(date +%Y-%m-01) -$((months - 1)) month" +%Y-%m)"
	# Buffer a month before the window so a pull closed early in it whose merge
	# commit is dated slightly later is still matched.
	sinceDate="$(date -d "${windowStart}-01 -1 month" +%Y-%m-%d)"
	echo "Counting PRs by ${person} on ${LFR_PULLS_REPO}, matching titles against ${LFR_PULLS_MASTER_REF}..." >&2
	json="$(gh pr list --repo "${LFR_PULLS_REPO}" --author "${person}" \
		--state all --limit 500 --json number,title,state,createdAt,closedAt)" || return 1

	local -A masterSubjects=()
	_lfrPullsLoadMasterSubjects "${dir}" "${sinceDate}" masterSubjects

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

# Load the subjects of commits on the master ref (in clone $1, since date $2)
# into the associative array named $3. A pull merged in when its exact title is
# one of these subjects; loading them once avoids a full-history scan per title.
_lfrPullsLoadMasterSubjects() {
	local -n _subjects="${3}"
	local s
	while IFS= read -r s; do
		[ -n "${s}" ] && _subjects["${s}"]=1
	done < <(git -C "${1}" log "${LFR_PULLS_MASTER_REF}" --since="${2}" --format='%s' 2>/dev/null)
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

	local dir since json rows sender title status
	if [ -z "${person}" ]; then
		person="$(_lfrPullsMineUser week)" || return 1
	fi
	dir="$(_lfrPullsMasterDir)" || return 1
	since="$(date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ)"

	local -A masterSubjects=()
	_lfrPullsLoadMasterSubjects "${dir}" "$(date -d "${days} days ago -1 month" +%Y-%m-%d)" masterSubjects

	json="$(gh pr list --repo "${LFR_PULLS_REPO}" --author "${person}" \
		--state closed --limit 200 --json number,title,headRefName,author,closedAt)" || return 1

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

	# The landing report is a bonus, so a missing clone or ref must not fail the
	# listing above.
	local dir
	dir="$(_lfrPullsMasterDir ticket)" || return 0

	# GitHub's title search tokenizes, so it also finds a pull titled "LCD 52771"
	# for LCD-52771. Match the same variants here, or the footer would miss the
	# commits of exactly those pulls.
	local landed count
	landed="$(git -C "${dir}" log "${LFR_PULLS_MASTER_REF}" --grep="${ticket/-/[- ]}" \
		--regexp-ignore-case --format='%h	%cd	%s' --date=format:'%Y-%m-%d' 2>/dev/null)"
	count="$(printf '%s\n' "${landed}" | grep -c .)"

	if [ "${count}" -eq 0 ]; then
		printf '%s on %s: nothing landed yet (ref tip %s).\n' "${ticket}" "${LFR_PULLS_MASTER_REF}" \
			"$(git -C "${dir}" log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M' "${LFR_PULLS_MASTER_REF}")"
		return 0
	fi

	printf '%s on %s: %s commit(s) landed, newest first.\n' \
		"${ticket}" "${LFR_PULLS_MASTER_REF}" "${count}"
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
	def status:
		allLabels as $l |
		if (.mergeable == "CONFLICTING") or ($l | any(test("conflict"; "i"))) then "CONFLICT"
		elif .isDraft then "DRAFT"
		elif (.reviewDecision == "CHANGES_REQUESTED") or ($l | any(test("changes needed"; "i"))) then "CHANGES"
		elif $l | any(. == "pr-check - failure") then "CHECK-FAIL"
		elif $l | any(test("on hold|blocked|waiting[ _-]for"; "i")) then "ON-HOLD"
		elif (.reviewDecision == "APPROVED") or
			($l | any(test("ready to merge|ready to forward|dev approved|passed review|qa passed"; "i"))) then "READY"
		elif ($l | any(test("review in progress"; "i"))) or ((.assignees | length) > 0) then "IN-REVIEW"
		elif ($l | any(test("review needed|ready to review"; "i"))) or
			(.reviewDecision == "REVIEW_REQUIRED") or ((.reviewRequests | length) > 0) then "REVIEW"
		elif $l | any(. == "ci:forward") then "FORWARDED"
		# Last, not next to CHECK-FAIL: a backport all but always has some batch
		# red (43 of the 44 open EE pulls did), so ranking it high says nothing.
		elif $l | any(test("^ci:test.* - failure")) then "TEST-FAIL"
		else "OPEN" end;
	def sender:
		if (.headRefName | test("-sender-")) then (.headRefName | sub(".*-sender-"; "")) else .author.login end;
	def assignee: (.assignees | map(.login) | join(",")) | if . == "" then "-" else . end;
	# Whether the next move is yours. It is when you are the assignee or the
	# requested reviewer, when a pull of yours came back with something to fix,
	# or when somebody opened it on your own fork, which is a review request by
	# construction. A pull of yours that another person is reviewing is not.
	#
	# Three more only on a queue of your own ($yours: your fork, your team fork,
	# the mirror, the EE repo), because an unclaimed pull is only yours to pick
	# up on a queue you belong to. On a fork of another team they stay "-".
	#   your own pull conflicting, somebody else already reviewing it -> "ask":
	#     yours to rebase, but a force push under a review in progress destroys
	#     that review, so ask the person in ASSIGNEE first. Only your own pull:
	#     one you neither wrote nor were assigned is not yours to touch
	#   conflicting and nobody assigned  -> "you", it is going nowhere otherwise
	#   review needed and nobody assigned -> "review", free for you to take
	def onYou:
		([.assignees[].login] + [.reviewRequests[] | (.login // .slug // "")]) as $owners |
		status as $status |
		# Assignees only, not review requests: a request sitting on the team
		# account means nobody has taken it, and there is no one person to ask.
		(.assignees | map(select(.login != $me)) | length > 0) as $claimedByOther |
		((.assignees | length) == 0) as $unclaimed |
		if ($yours == "true") and ($status == "CONFLICT") and $claimedByOther and
			(.author.login == $me) then "ask"
		elif ($owners | any(. == $me)) then "you"
		elif (.author.login == $me) then
			(if ([ "CONFLICT", "CHANGES", "CHECK-FAIL", "TEST-FAIL", "ON-HOLD" ] | any(. == $status))
				then "you" else "-" end)
		elif ($repoOwner == $me) then "you"
		elif ($yours == "true") and $unclaimed and ($status == "CONFLICT") then "you"
		elif ($yours == "true") and $unclaimed and ($status == "REVIEW") then "review"
		else "-" end;
	def age: ((now - (.createdAt | fromdate)) / 86400 | floor | tostring) + "d";
	# Whether a pull is worth a place on the dashboard, which shows your own
	# queues and drops what belongs to somebody else. Three ways in:
	#   you wrote it, so it is yours however healthy it looks
	#   ON YOU says something, so it is waiting on you or free for you to take
	#   it carries no workflow label at all, which is itself the finding: nobody
	#     has triaged it, so it is sitting on the fork with no state
	def relevant:
		(.author.login == $me) or (onYou != "-") or ((workflowLabels | length) == 0);
'

# Make each row's #<number> a clickable link to its pull. The URL rides in an
# OSC 8 escape and the visible text stays "#12345", so no column grows and
# `column -t` cannot be thrown off: this runs AFTER the table is laid out, for
# the same reason the emoji are stripped from LABELS.
#
# On a terminal by default, never when the output is piped or redirected, since
# a file full of escapes is worse than no links. LFR_PULLS_LINKS forces it
# either way: `on` even when piped, `off` never.
_lfrPullsLinkify() {
	local repo="${1}" links="${LFR_PULLS_LINKS:-auto}" esc

	case "${links}" in
	off) cat; return ;;
	on) ;;
	*) if [ ! -t 1 ]; then cat; return; fi ;;
	esac

	esc=$'\033'
	sed -E "s|^([[:space:]]*)#([0-9]+)|\1${esc}]8;;https://github.com/${repo}/pull/\2${esc}\\\\#\2${esc}]8;;${esc}\\\\|"
}

# The open pulls on a repo, with everything STATUS is derived from.
_lfrPullsOpenJson() {
	gh pr list --repo "${1}" --state open --limit 200 \
		--json number,title,headRefName,author,isDraft,mergeable,reviewDecision,assignees,reviewRequests,labels,createdAt 2>/dev/null
}

# Print one fork's open pulls under <heading>, newest first, keeping only what
# the jq expression <filter> selects. `detail` as $4 adds the age and the pull's
# own labels; without it the table stays PR / AUTHOR / STATUS / ASSIGNEE / TITLE.
_lfrPullsForkSection() {
	local repo="${1}" filter="${2}" heading="${3}" detail="${4:-}" json rows total header row
	local me="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}" yours="false"
	case "${repo}" in
	"${me}"/* | "${LFR_PULLS_TEAM:-${LFR_GIT_FORK_ORG:-::none::}}"/* | "${LFR_PULLS_EE_REPO}" | "${LFR_PULLS_REPO}") yours="true" ;;
	esac

	printf '\n%s\n' "${heading}"

	json="$(_lfrPullsOpenJson "${repo}")"
	if [ -z "${json}" ]; then
		printf '  (no such repo, or it has no pulls: %s)\n' "${repo}"
		return 0
	fi
	total="$(printf '%s' "${json}" | jq 'length')"

	if [ -n "${detail}" ]; then
		header='PR\tAUTHOR\tSTATUS\tON YOU\tASSIGNEE\tAGE\tLABELS\tTITLE'
		row='"#\(.number)\t\(.author.login)\t\(status)\t\(onYou)\t\(assignee)\t\(age)\t\((workflowLabels | join(", ")) | if . == "" then "-" else . end)\t\(.title[0:60])"'
	else
		header='PR\tAUTHOR\tSTATUS\tON YOU\tASSIGNEE\tTITLE'
		row='"#\(.number)\t\(.author.login)\t\(status)\t\(onYou)\t\(assignee)\t\(.title[0:60])"'
	fi

	rows="$(printf '%s' "${json}" | jq -r --arg me "${me}" --arg repoOwner "${repo%%/*}" --arg yours "${yours}" \
		"${_LFR_PULLS_JQ} ${filter} | sort_by(.number) | reverse | .[] | ${row}")"

	if [ -z "${rows}" ]; then
		if [ "${total}" -eq 0 ]; then
			printf '  no open pulls.\n'
		else
			printf '  none of the %s open pull(s).\n' "${total}"
		fi
		return 0
	fi
	printf "${header}"'\n%s\n' "${rows}" | column -t -s $'\t' | sed 's/^/  /' |
		_lfrPullsLinkify "${repo}"
	printf '  %s of %s open pull(s).\n' "$(printf '%s\n' "${rows}" | grep -c .)" "${total}"
}

# Print the mirror's open pulls: the same STATUS as a fork, plus AHEAD, which
# only means something here because the mirror is the merge queue.
_lfrPullsMirrorSection() {
	local mode="${1}" detail="${2:-}" filter='.' json rows header row
	local me="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}"

	# A pull is one person's when they authored it directly or when the bot
	# forwarded it from their fork, which the head branch records as
	# -sender-<owner>. For you the sender owner can be overridden, since a
	# forward from an org fork carries the org: LFR_PULLS_MINE_ORG. For anybody
	# else it is their login.
	local person="" senderOwner=""
	if [ "${mode}" = "mine" ]; then
		person="${me}"
		senderOwner="${LFR_PULLS_MINE_ORG:-${me}}"
	elif [ "${mode}" != "all" ]; then
		person="${mode}"
		senderOwner="${mode}"
	fi

	if [ -n "${person}" ]; then
		filter="[.[] | select((.headRefName | test(\"-sender-${senderOwner}$\")) or (.author.login == \"${person}\"))]"
	elif [ "${mode}" != "all" ]; then
		echo "lfrPulls: set LFR_PULLS_USER in ${_lfrPullsDir}/lfr-pulls.local.conf, or pass 'all'." >&2
		return 1
	fi

	json="$(_lfrPullsOpenJson "${LFR_PULLS_REPO}")" || return 1

	if [ -n "${detail}" ]; then
		header='PR\tSENDER\tAHEAD\tSTATUS\tON YOU\tAGE\tLABELS\tTITLE'
		row='"#\($n)\t\(sender)\t\($nums | map(select(. < $n)) | length)\t\(status)\t\(onYou)\t\(age)\t\((workflowLabels | join(", ")) | if . == "" then "-" else . end)\t\(.title[0:60])"'
	else
		header='PR\tSENDER\tAHEAD\tSTATUS\tON YOU\tTITLE'
		row='"#\($n)\t\(sender)\t\($nums | map(select(. < $n)) | length)\t\(status)\t\(onYou)\t\(.title[0:60])"'
	fi

	# AHEAD = how many open PRs are older (lower number), so roughly how many are
	# in front of it in the merge queue; a low number means it is close.
	rows="$(printf '%s' "${json}" | jq -r --arg me "${me}" --arg repoOwner "${LFR_PULLS_REPO%%/*}" --arg yours "true" "${_LFR_PULLS_JQ}
		(map(.number) | sort) as \$nums |
		${filter} | sort_by(.number) | .[] | (.number) as \$n | ${row}")" || return 1

	local total
	total="$(printf '%s' "${json}" | jq 'length')"

	printf '\n%s open pulls (%s)\n' "${LFR_PULLS_REPO}" "${mode}"
	if [ -z "${rows}" ]; then
		printf '  none of the %s open pull(s).\n' "${total}"
	else
		printf "${header}"'\n%s\n' "${rows}" | column -t -s $'\t' | sed 's/^/  /' |
			_lfrPullsLinkify "${LFR_PULLS_REPO}"
		printf '  %s of %s open pull(s).\n' "$(printf '%s\n' "${rows}" | grep -c .)" "${total}"
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

	dir="$(_lfrPullsMasterDir teams 2>/dev/null)" || return 0

	local known=" ${_LFR_PULLS_TEAMS//[$'\n\t']/ } "
	local -a missing=()
	while IFS= read -r t; do
		[[ "${known}" == *" ${t} "* ]] || missing+=("${t}")
	done < <(git -C "${dir}" show "${LFR_PULLS_MASTER_REF}:.github/CODEOWNERS" 2>/dev/null |
		grep -oE '@[A-Za-z0-9_-]+' | tr -d '@' | sort -u)

	[ "${#missing[@]}" -gt 0 ] &&
		printf '\nCODEOWNERS on %s also owns code as: %s. Add them to _LFR_PULLS_TEAMS.\n' \
			"${LFR_PULLS_MASTER_REF}" "${missing[*]}"
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
_lfrPullsDashboard() {
	local detail="${1:-}" mirrorMode="${2:-mine}" person="" forkUser

	case "${mirrorMode}" in
	mine | all) ;;
	*) person="${mirrorMode}" ;;
	esac

	_lfrPullsMirrorSection "${mirrorMode}" "${detail}" || return 1

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

	# Resolved here, not at source time: LfrGit's conf can load after this file,
	# and LFR_GIT_FORK_ORG is where the team fork comes from.
	local team="${LFR_PULLS_TEAM:-${LFR_GIT_FORK_ORG:-}}"
	if [ -n "${team}" ]; then
		_lfrPullsForkSection "${team}/${LFR_PULLS_FORK_REPO}" "${teamFilter}" \
			"${team}/${LFR_PULLS_FORK_REPO} open pulls (your team: ${teamScope})" "${detail}"
	fi

	forkUser="${person:-${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}}"
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
lfrps() { lfrPulls stats "$@"; }
lfrpt() { lfrPulls ticket "$@"; }
lfrpf() { lfrPulls team "$@"; }
lfrpteams() { lfrPulls teams "$@"; }
lfrpe() { lfrPulls ee "$@"; }
