# lfr-pulls-triage.sh - give a reviewer to each open pull of the team fork
# that has none.
#
# Source this from your shell rc (normally via the root lfrTools.sh). It defines:
#     lfrPullsTriage     plan the reviewers, let you keep, change, or skip each
#                        one, then apply after a y
#     lfrptr             short alias of lfrPullsTriage
#     lfrPullsTriageWorktree  show or set the worktree offer: ask, on, or off
#     lfrptrw            short alias of lfrPullsTriageWorktree
#
# triage/triage.py does the work. Its README.md tells how it selects a
# reviewer. The reviewers and their Jira accounts are in
# triage/config.local.yaml, and the reviewers who are out are in
# triage/availability.local.yaml. Both are gitignored, because they name
# people. Copy each .example to start.

_lfrPullsTriageDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/triage"
_lfrPullsTriageConf="$(dirname "${_lfrPullsTriageDir}")/lfr-pulls.local.conf"

_lfrPullsTriageHelp() {
	cat <<-'EOF'
		lfrPullsTriage - give a reviewer to each open pull that has none.

		Usage:
		  lfrPullsTriage [plan options]   plan, choose, then apply after a y
		  lfrPullsTriage --explain <pull> print the score of each candidate
		  lfrPullsTriage --plan-only      plan only, ask nothing, write nothing
		  lfrptr                          same as lfrPullsTriage

		The plan reads GitHub, Jira, and the master clone, and writes nothing.
		Then it shows each planned pull with its link and the proposed
		reviewer, and asks "Accept? [Y/s/<login>]". If 2 or more reviewers
		can take the pull, it lists the best candidates with their score
		(lower is better), the proposed one first, and asks for a number:
		  Enter, y  accept the proposed reviewer
		  <number>  select that candidate
		  s, n      skip: do not assign this pull
		  <login>   assign this reviewer instead
		Then it prints each write and asks "Apply? [y/N]". Only a y writes:
		the assignee, the scope label, a comment, and the Jira assignee of
		the ticket that is In Review.

		For each pull that you assign to yourself, it then asks "Create a
		worktree with its branch? [y/N]". A y runs lfrWorktreePull on the
		pull (see lfrWorktreePull -h). LFR_PULLS_TRIAGE_WORKTREE in
		lfr-pulls.local.conf changes this: ask (the default), on (create it
		and do not ask), or off (do not create it). Set it with
		lfrPullsTriageWorktree ask|on|off. The offer needs lfrWorktreePull
		(LfrRepos). If it is not loaded, the offer does not show.

		If the shell is not interactive, it stops after the plan.

		Plan options (see triage.py -h): --repo, --window, --max-prs,
		--expertise-weight, --story-weight, --label-confidence, --load-model.

		Files (gitignored, copy each .example to start):
		  LfrPulls/triage/config.local.yaml        reviewers and Jira accounts
		  LfrPulls/triage/availability.local.yaml  reviewers who are out
	EOF
}

_lfrPullsTriage() {
	local script="${_lfrPullsTriageDir}/triage.py"
	local plan="${XDG_CACHE_HOME:-${HOME}/.cache}/pr-review-triage/plan.json"
	local planOnly="false" a
	local -a planArgs=()

	for a in "$@"; do
		case "${a}" in
		-h | --help) _lfrPullsTriageHelp; return 0 ;;
		--plan-only) planOnly="true" ;;
		--explain) planOnly="true"; planArgs+=("${a}") ;;
		--apply) echo "lfrPullsTriage: --apply is not an option here. Run lfrPullsTriage and answer the prompts." >&2; return 1 ;;
		*) planArgs+=("${a}") ;;
		esac
	done

	if [ ! -r "${_lfrPullsTriageDir}/config.local.yaml" ]; then
		echo "lfrPullsTriage: ${_lfrPullsTriageDir}/config.local.yaml is missing. Copy config.local.yaml.example and fill it in." >&2
		return 1
	fi

	python3 "${script}" "${planArgs[@]}" || return 1

	if [ "${planOnly}" = "true" ] || [ ! -t 0 ]; then
		return 0
	fi

	local count
	count="$(jq '.assigned | length' "${plan}")" || return 1

	if [ "${count}" -eq 0 ]; then
		echo
		echo "Nothing to assign."
		return 0
	fi

	echo
	echo "Accept the proposed reviewer of each pull. Enter or y accepts it, s skips the"
	echo "pull, a number selects another candidate, and a login assigns that person."

	local -a applyArgs=() mine=()
	local -a logins
	local me="${LFR_PULLS_USER:-$(_lfrStep "Read your GitHub user" gh api user --jq '.login' 2>/dev/null)}"
	local number reviewer reason url title candidates answer choice kept=0 i

	while IFS=$'\t' read -r number reviewer reason url title candidates; do
		echo
		echo "${url}"
		echo "  ${title}"
		IFS=',' read -r -a logins <<< "${candidates}"

		if [ "${#logins[@]}" -ge 2 ]; then
			echo "  candidates (lower score is better):"

			for i in "${!logins[@]}"; do
				echo "    $((i + 1))) ${logins[${i}]//:/  score }$([ "${i}" -eq 0 ] && echo "  <- proposed (${reason})")"
			done

			echo "    s) skip, do not assign this pull"
			read -r -p "  Choose [1-${#logins[@]}/s/<login>] (Enter = 1): " answer < /dev/tty
		else
			echo "  proposed reviewer: ${reviewer} (${reason})"
			read -r -p "  Accept? [Y/s/<login>] (s = skip) " answer < /dev/tty
		fi

		choice="${answer}"

		if [[ "${answer}" =~ ^[0-9]+$ ]] && [ "${answer}" -ge 1 ] && [ "${answer}" -le "${#logins[@]}" ]; then
			choice="${logins[$((answer - 1))]%%:*}"
		fi

		case "${choice}" in
		"" | y | Y | "${reviewer}") kept=$((kept + 1)); choice="${reviewer}" ;;
		s | S | skip | n | N) applyArgs+=(--skip "${number}"); echo "  skipped"; continue ;;
		*) applyArgs+=(--reviewer "${number}=${choice}"); kept=$((kept + 1)) ;;
		esac

		[ -n "${me}" ] && [ "${choice}" = "${me}" ] && mine+=("${number}")
	done < <(jq -r '.assigned[] | [.number, .reviewer, .reason, .url, .title,
		([.candidates // [] | .[] | "\(.login):\(.score)"] | join(","))] | @tsv' "${plan}")

	if [ "${kept}" -eq 0 ]; then
		echo "You did not accept any pull. Nothing to apply."
		return 0
	fi

	echo
	_lfrStep "Check the plan" python3 "${script}" --apply "${plan}" --print-only "${applyArgs[@]}" || return 1

	echo
	read -r -p "Apply? [y/N] " answer < /dev/tty

	case "${answer}" in
	y | Y) _lfrStep "Apply the plan on GitHub" python3 "${script}" --apply "${plan}" "${applyArgs[@]}" || return 1 ;;
	*) echo "Nothing was written."; return 0 ;;
	esac

	_lfrPullsTriageOfferWorktrees "$(jq -r '.repo' "${plan}")" "${me}" "${mine[@]}"
}

# Offer a worktree for each pull that you took: _lfrPullsTriageOfferWorktrees
# <repo> <your login> <pull>...
_lfrPullsTriageOfferWorktrees() {
	local repo="${1}" me="${2}" number answer
	shift 2

	# Offer a worktree for each pull that you took. The apply can skip a pull
	# (a new push, or another reviewer), so check the assignee on GitHub first.
	[ -r "${_lfrPullsTriageConf}" ] && . "${_lfrPullsTriageConf}"
	local worktree="${LFR_PULLS_TRIAGE_WORKTREE:-ask}"

	if [ "${worktree}" = "off" ] || [ "$#" -eq 0 ]; then
		return 0
	fi

	if ! declare -F lfrWorktreePull > /dev/null; then
		echo "lfrWorktreePull is not loaded (LfrRepos), so no worktree is offered."
		return 0
	fi

	for number in "$@"; do
		_lfrStep "Read the assignees of #${number}" gh pr view "${number}" --repo "${repo}" --json assignees \
			--jq '.assignees[].login' 2>/dev/null | grep -qx "${me}" || continue
		echo

		if [ "${worktree}" = "on" ]; then
			answer="y"
		else
			read -r -p "You review #${number}. Create a worktree with its branch? [y/N] " answer < /dev/tty
		fi

		case "${answer}" in
		y | Y) (lfrWorktreePull "https://github.com/${repo}/pull/${number}") ;;
		esac
	done
}

lfrPullsTriage() { _lfrPullsTriage "$@"; }

# Show or set LFR_PULLS_TRIAGE_WORKTREE in lfr-pulls.local.conf.
lfrPullsTriageWorktree() {
	local value="${1:-}"

	case "${value}" in
	"")
		[ -r "${_lfrPullsTriageConf}" ] && . "${_lfrPullsTriageConf}"
		echo "LFR_PULLS_TRIAGE_WORKTREE=${LFR_PULLS_TRIAGE_WORKTREE:-ask}"
		return 0
		;;
	-h | --help)
		echo "Usage: lfrPullsTriageWorktree [ask|on|off]"
		echo "  ask  ask for a worktree for each pull that you take (the default)"
		echo "  on   create the worktree and do not ask"
		echo "  off  do not create a worktree"
		echo "  With no value, it prints the current value."
		return 0
		;;
	ask | on | off) ;;
	*) echo "lfrPullsTriageWorktree: use ask, on, or off." >&2; return 1 ;;
	esac

	touch "${_lfrPullsTriageConf}" || return 1

	if grep -q '^LFR_PULLS_TRIAGE_WORKTREE=' "${_lfrPullsTriageConf}"; then
		sed -i "s/^LFR_PULLS_TRIAGE_WORKTREE=.*/LFR_PULLS_TRIAGE_WORKTREE=\"${value}\"/" "${_lfrPullsTriageConf}"
	else
		echo "LFR_PULLS_TRIAGE_WORKTREE=\"${value}\"" >> "${_lfrPullsTriageConf}"
	fi

	LFR_PULLS_TRIAGE_WORKTREE="${value}"
	echo "LFR_PULLS_TRIAGE_WORKTREE=${value} (${_lfrPullsTriageConf})"
}

# Short alias.
lfrptr() { lfrPullsTriage "$@"; }
lfrptrw() { lfrPullsTriageWorktree "$@"; }
