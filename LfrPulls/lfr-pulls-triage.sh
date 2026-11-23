# lfr-pulls-triage.sh - give a reviewer to each open pull of the team fork
# that has none.
#
# Source this from your shell rc (normally via the root lfrTools.sh). It defines:
#     lfrPullsTriage     plan the reviewers, let you keep, change, or skip each
#                        one, then apply after a y
#     lfrptr             short alias of lfrPullsTriage
#
# triage/triage.py does the work. Its README.md tells how it selects a
# reviewer. The reviewers and their Jira accounts are in
# triage/config.local.yaml, and the reviewers who are out are in
# triage/availability.local.yaml. Both are gitignored, because they name
# people. Copy each .example to start.

_lfrPullsTriageDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/triage"

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

	local -a applyArgs=()
	local -a logins
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
		"" | y | Y | "${reviewer}") kept=$((kept + 1)) ;;
		s | S | skip | n | N) applyArgs+=(--skip "${number}"); echo "  skipped" ;;
		*) applyArgs+=(--reviewer "${number}=${choice}"); kept=$((kept + 1)) ;;
		esac
	done < <(jq -r '.assigned[] | [.number, .reviewer, .reason, .url, .title,
		([.candidates // [] | .[] | "\(.login):\(.score)"] | join(","))] | @tsv' "${plan}")

	if [ "${kept}" -eq 0 ]; then
		echo "You did not accept any pull. Nothing to apply."
		return 0
	fi

	echo
	python3 "${script}" --apply "${plan}" --print-only "${applyArgs[@]}" || return 1

	echo
	read -r -p "Apply? [y/N] " answer < /dev/tty

	case "${answer}" in
	y | Y) python3 "${script}" --apply "${plan}" "${applyArgs[@]}" ;;
	*) echo "Nothing was written." ;;
	esac
}

lfrPullsTriage() { _lfrPullsTriage "$@"; }

# Short alias.
lfrptr() { lfrPullsTriage "$@"; }
