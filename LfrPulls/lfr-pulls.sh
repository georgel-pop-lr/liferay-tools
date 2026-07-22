# lfr-pulls.sh — list open pull requests on the Brian CI mirror repo.
#
# Source this from your shell rc (normally via the root lfrTools.sh). It defines:
#     lfrPulls        list open PRs on the mirror repo; yours by default, or all
#     lfrPulls stats  per-month counts of PRs sent, merged, and rejected
#
# A PR on the mirror repo is either forwarded by the CI bot (author is the bot,
# head branch encodes the source fork owner as `...-sender-<owner>`) or opened
# directly (author is you, plain head branch). "Yours" matches either: a
# forwarded PR from your fork (LFR_PULLS_MINE_ORG, default LFR_GIT_FORK_ORG), or
# a direct PR authored by you (LFR_PULLS_USER, default the gh-authenticated user).
#
# Per-user settings live in lfr-pulls.local.conf next to this file. It is
# gitignored. Copy lfr-pulls.local.conf.example to lfr-pulls.local.conf.

_lfrPullsDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "${_lfrPullsDir}/lfr-pulls.local.conf" ] && . "${_lfrPullsDir}/lfr-pulls.local.conf"

: "${LFR_PULLS_REPO:=brianchandotcom/liferay-portal}"
: "${LFR_PULLS_MASTER_REF:=brian/master}"

_lfrPullsHelp() {
	cat <<-'EOF'
		lfrPulls — list open pull requests on the mirror repo.

		Usage (each command has a short form and an alias):
		  lfrPulls [mine|all]              list open PRs (yours by default)
		  lfrPulls week [days]  (w, lfrpw) your pulls closed in the last days
		                                   (default 7): PR / SENDER / STATUS / TITLE
		  lfrPulls stats [mine|all] [months]  (s, lfrps)
		                                   per-month counts of PRs sent, merged, and
		                                   rejected for you (mine); sent and closed
		                                   for the whole repo (all); months default 12

		mine matches PRs forwarded from your fork or opened by you; all shows
		every PR. The AHEAD column is how many open pulls are older (lower
		number), i.e. roughly how many are in front of it in the merge queue, so
		a small number means yours is close. The list ends with when the repo was
		last active (the most recent pull merged or rejected) and how long ago.

		stats (mine) counts the PRs you opened directly, by month:
		  SENT      PRs you created that month
		  MERGED    of those closed that month, the ones whose exact title is a
		            commit on the master ref (Brian merged that pull in)
		  REJECTED  closed that month whose title is NOT on master (just closed)
		A pull is merged only if its own title landed, so a superseded resend of a
		ticket whose other work merged still counts as rejected. Keep the master
		ref fetched (e.g. lfrGitUpdateMaster). stats all cannot title-match every
		PR, so it shows only sent and closed for the whole repo.

		Config (lfr-pulls.local.conf):
		  LFR_PULLS_REPO         repo to list (default brianchandotcom/liferay-portal)
		  LFR_PULLS_MINE_ORG     your fork owner (default LFR_GIT_FORK_ORG)
		  LFR_PULLS_USER         your GitHub login (default the gh-authed user)
		  LFR_PULLS_MASTER_REPO  local clone to grep for merges (default: cwd repo)
		  LFR_PULLS_MASTER_REF   master ref to grep (default brian/master)
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
# the current repo. Echoes its path; errors if the master ref is missing.
_lfrPullsMasterDir() {
	local dir="${LFR_PULLS_MASTER_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
	if [ -z "${dir}" ]; then
		echo "lfrPulls stats: run from a liferay-portal clone, or set LFR_PULLS_MASTER_REPO." >&2
		return 1
	fi
	if ! git -C "${dir}" rev-parse --verify -q "${LFR_PULLS_MASTER_REF}" >/dev/null 2>&1; then
		echo "lfrPulls stats: ref ${LFR_PULLS_MASTER_REF} not found in ${dir}; set LFR_PULLS_MASTER_REF/REPO." >&2
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
	local months="${1}" mineUser="${2}" dir
	dir="$(_lfrPullsMasterDir)" || return 1

	local windowStart sinceDate json
	windowStart="$(date -d "$(date +%Y-%m-01) -$((months - 1)) month" +%Y-%m)"
	# Buffer a month before the window so a pull closed early in it whose merge
	# commit is dated slightly later is still matched.
	sinceDate="$(date -d "${windowStart}-01 -1 month" +%Y-%m-%d)"
	echo "Counting your PRs on ${LFR_PULLS_REPO}, matching titles against ${LFR_PULLS_MASTER_REF}..." >&2
	json="$(gh pr list --repo "${LFR_PULLS_REPO}" --author "${mineUser}" \
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
		'' | *[!0-9]*) echo "lfrPulls stats: unknown argument '${a}' (want mine|all|<months>)." >&2; return 1 ;;
		*) months="${a}" ;;
		esac
	done

	if [ "${scope}" = "all" ]; then
		_lfrPullsStatsAll "${months}"
		return
	fi

	local mineUser="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}"
	if [ -z "${mineUser}" ]; then
		echo "lfrPulls stats: set LFR_PULLS_USER in ${_lfrPullsDir}/lfr-pulls.local.conf, or pass 'all'." >&2
		return 1
	fi
	_lfrPullsStatsMine "${months}" "${mineUser}"
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
	local days=7 a
	for a in "$@"; do
		case "${a}" in
		-h | --help) _lfrPullsHelp; return 0 ;;
		'' | *[!0-9]*) echo "lfrPulls week: unknown argument '${a}' (want <days>)." >&2; return 1 ;;
		*) days="${a}" ;;
		esac
	done

	local mineUser dir since json rows sender title status
	mineUser="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}"
	if [ -z "${mineUser}" ]; then
		echo "lfrPulls week: set LFR_PULLS_USER in ${_lfrPullsDir}/lfr-pulls.local.conf." >&2
		return 1
	fi
	dir="$(_lfrPullsMasterDir)" || return 1
	since="$(date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ)"

	local -A masterSubjects=()
	_lfrPullsLoadMasterSubjects "${dir}" "$(date -d "${days} days ago -1 month" +%Y-%m-%d)" masterSubjects

	json="$(gh pr list --repo "${LFR_PULLS_REPO}" --author "${mineUser}" \
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
		echo "No pulls of yours closed in the last ${days} day(s) on ${LFR_PULLS_REPO}."
		return 0
	fi
	printf 'PR\tSENDER\tSTATUS\tTITLE\n%s' "${rows}" | column -t -s $'\t'
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

# List open PRs on LFR_PULLS_REPO. With no argument (or `mine`) it shows only the
# PRs forwarded from your fork; `all` shows every open PR.
lfrPulls() {
	case "${1:-}" in
	stats | st | s) shift; _lfrPullsStats "$@"; return ;;
	week | recent | w) shift; _lfrPullsWeek "$@"; return ;;
	esac

	local mode="mine" a
	for a in "$@"; do
		case "${a}" in
		mine | -m | --mine) mode="mine" ;;
		all | -a | --all) mode="all" ;;
		-h | --help) _lfrPullsHelp; return 0 ;;
		*) echo "lfrPulls: unknown argument '${a}' (want mine|all)." >&2; return 1 ;;
		esac
	done

	local filter='.'
	if [ "${mode}" = "mine" ]; then
		local mineOrg="${LFR_PULLS_MINE_ORG:-${LFR_GIT_FORK_ORG:-}}"
		local mineUser="${LFR_PULLS_USER:-$(gh api user --jq '.login' 2>/dev/null)}"
		if [ -z "${mineOrg}" ] && [ -z "${mineUser}" ]; then
			echo "lfrPulls: set LFR_PULLS_MINE_ORG or LFR_PULLS_USER in ${_lfrPullsDir}/lfr-pulls.local.conf, or pass 'all'." >&2
			return 1
		fi
		filter="[.[] | select((.headRefName | test(\"-sender-${mineOrg}$\")) or (.author.login == \"${mineUser}\"))]"
	fi

	local json
	json="$(gh pr list --repo "${LFR_PULLS_REPO}" --state open --limit 200 \
		--json number,title,headRefName,url,author)" || return 1

	# AHEAD = how many open PRs are older (lower number), so roughly how many are
	# in front of it in the merge queue; a low number means it is close.
	local rows
	rows="$(printf '%s' "${json}" | jq -r "
		(map(.number) | sort) as \$nums |
		${filter} | sort_by(.number) | .[] | (.number) as \$n |
		\"#\(\$n)\t\(if (.headRefName | test(\"-sender-\")) then (.headRefName | sub(\".*-sender-\"; \"\")) else .author.login end)\t\(\$nums | map(select(. < \$n)) | length)\t\(.title)\"")" || return 1

	if [ -z "${rows}" ]; then
		echo "No ${mode} open pull requests on ${LFR_PULLS_REPO}."
		_lfrPullsLastActiveLine
		return 0
	fi

	printf 'PR\tSENDER\tAHEAD\tTITLE\n%s\n' "${rows}" | column -t -s $'\t'
	printf '\n%s of %s open pull(s) on %s are shown.\n' \
		"$(printf '%s\n' "${rows}" | grep -c .)" \
		"$(printf '%s' "${json}" | jq 'length')" "${LFR_PULLS_REPO}"
	_lfrPullsLastActiveLine
}

# Short aliases.
lfrp() { lfrPulls "$@"; }
lfrpw() { lfrPulls week "$@"; }
lfrps() { lfrPulls stats "$@"; }
