# lfr-code-view.sh — read the code of a change without copying hashes around.
#
# Source this from your shell rc (normally via the root lfrTools.sh). It defines:
#     lfrCodeView   pick a commit (or your local changes) from a picker and diff it
#
# The picker lists your local changes, the whole branch against its base, and one
# line per commit the branch adds (up to 50), previewing each entry's diffstat.
# Picking one runs `git show` / `git diff` in your pager; from there the left arrow
# (or b) comes back to the list, on the same entry, and q ends it. So one
# lfrCodeView reads through a whole change, diff by diff.
#
# With -a it lists a ticket's commits across every ref instead (the copy on
# master, the backports on release branches). The ticket defaults to the one in
# the current branch name (LPD-12345-foo -> LPD-12345).

_lfrCodeViewHelp() {
	cat <<-'EOF'
		lfrCodeView — view the code of a change from a picker (short alias lfrcv).

		Usage:
		  lfrCodeView               the current branch: local changes + commits
		  lfrCodeView -a [ticket]   that ticket's commits on every ref instead,
		                            so the master copy and the release-branch
		                            backports too (ticket defaults to the one in
		                            the branch name, LPD-12345-fix -> LPD-12345)

		The picker lists, leaving out what does not apply, and previews the
		highlighted entry's diffstat:

		  local  uncommitted   git diff HEAD, then each untracked file
		  branch vs <base>     git diff <base>...HEAD, all the branch adds
		  <sha> <date> <sub>   git show <sha>, one line per commit, 50 at most

		A toolbar of the keys sits on the bottom line of both views, and the arrows
		drive the whole thing:

		  in the list   up/down move    right or enter view    left or esc quit
		  in a diff     left or b back to the list    q quit

		So it loops through as many diffs as you want until you close it. Going back
		works inside the diff itself (left and b are rebound in the pager), no need
		to leave it first, and the list reopens on the entry you just read rather
		than at the top, so walking a branch commit by commit is left, down, right.
		Nothing is written: no index, stash, or checkout.

		That rebinding needs less 582 or newer, which is the pager unless you set
		GIT_PAGER or PAGER; with another pager the same choice is asked once it
		exits. The list keys are fzf's; without fzf it is a numbered menu you
		answer with a number, and only the diff keys apply.

		The branch listing has no ticket filter on purpose: every commit on top of
		the base is the change. The ticket only matters for -a.

		LFR_CODE_VIEW_BASE overrides the ref the branch is compared against
		(default: LFR_WORKTREE_BASE, then upstream/master, origin/master, master,
		origin/main, main). Keep it fetched, e.g. with lfrGitUpdateMaster.
	EOF
}

# Echo the first base ref that exists, to compare the branch against.
_lfrCodeViewBase() {
	local ref

	for ref in "${LFR_CODE_VIEW_BASE:-}" "${LFR_WORKTREE_BASE:-}" upstream/master \
		origin/master master origin/main main; do
		[ -n "${ref}" ] || continue
		git rev-parse --verify -q "${ref}" >/dev/null 2>&1 && { printf '%s\n' "${ref}"; return 0; }
	done

	return 1
}

# Emit one "commit:<sha>\t<label>" picker line per commit, newest first, for the
# git log arguments given.
_lfrCodeViewCommits() {
	git log --max-count=50 --format=$'commit:%H\t%h  %cd  %s' --date=format:'%Y-%m-%d' "$@"
}

# Echo the path of a lesskey file that rebinds b and the left arrow to "quit with
# status 98" (the code of b itself), so either one sends us back to the list from
# inside a diff while q still just quits. Written once per machine, in source form,
# which less reads from LESSKEYIN since 582. Fails when the pager is not less, when
# less is older than that, or when the file cannot be written; the caller then asks
# after the pager exits instead.
_lfrCodeViewKeys() {
	local pager="${GIT_PAGER:-${PAGER:-less}}" version file

	case "${pager%% *}" in *less) ;; *) return 1 ;; esac

	version="$(less --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
	[ -n "${version}" ] && [ "${version}" -ge 582 ] || return 1

	# \kl is lesskey's name for the left arrow, which resolves to the terminfo
	# sequence (ESC O D, since less puts the keypad in transmit mode); ESC [ D is the
	# same key on a terminal that did not switch, so bind both. Rebinding it costs
	# only left horizontal scrolling, which diffs (wrapped by default) do not use,
	# and ESC-( still does that. Rewritten every time, so an older file from a
	# previous version cannot linger.
	file="${TMPDIR:-/tmp}/lfr-code-view.${USER:-user}.lesskey"
	printf '#command\nb quit b\n\\kl quit b\n\\e[D quit b\n' >"${file}" 2>/dev/null || return 1

	printf '%s\n' "${file}"
}

# Ask, once a diff is closed, whether to go back to the list. Succeeds on b (or
# Enter) so the caller loops, fails on anything else so it leaves. Only needed for
# pagers we cannot bind b in (see _lfrCodeViewKeys).
_lfrCodeViewAgain() {
	local key rest

	[ -t 0 ] || return 1

	printf '\n[<- or b] back to the list   [q] quit > ' >&2
	read -rsn1 key

	# An arrow arrives as ESC plus two more bytes, so pick those up before deciding;
	# a bare Esc (nothing follows) stays a quit.
	if [ "${key}" = $'\e' ]; then
		read -rsn2 -t 0.2 rest
		key="${key}${rest}"
	fi

	printf '\n' >&2

	case "${key}" in
	b | B | '' | $'\e[D' | $'\eOD') return 0 ;;
	*) return 1 ;;
	esac
}

# Write one entry's diff to stdout, colored, for the pager to page. "local" is
# everything uncommitted: the tracked changes, then each untracked file as a diff
# against nothing (git diff HEAD cannot see those). $1 is the picker value, $2 the
# base ref.
_lfrCodeViewDiff() {
	local value="${1}" base="${2}" file

	case "${value}" in
	commit:*) git show --color=always --patch --stat "${value#commit:}" ;;
	range) git diff --color=always --patch --stat "${base}...HEAD" ;;
	local)
		git diff --color=always --patch --stat HEAD

		while IFS= read -r file; do
			git diff --color=always --no-index --patch --stat /dev/null "${file}"
		done < <(git ls-files --others --exclude-standard)
		;;
	*) return 1 ;;
	esac
}

# Page one entry's diff, with the keys on the pager's bottom line. Returns 0 to
# stay in the loop (b), 1 to leave (q).
_lfrCodeViewPage() {
	local value="${1}" base="${2}" keys
	local toolbar='  <- or b  back to the list     q  quit     ?pB%pB\%..'

	if keys="$(_lfrCodeViewKeys)"; then
		# No -F: a diff that fits one screen must still wait, or there is nowhere to
		# press b. No -X either, so the diff is cleared and the list comes back clean.
		_lfrCodeViewDiff "${value}" "${base}" |
			LESSKEYIN="${keys}" less -R -P"${toolbar}"

		[ "${PIPESTATUS[1]}" = "98" ] && return 0
		return 1
	fi

	_lfrCodeViewDiff "${value}" "${base}" | eval "${GIT_PAGER:-${PAGER:-less -FRX}}"

	_lfrCodeViewAgain
}

lfrCodeView() {
	local allRefs=0 ticket="" arg

	while [ "$#" -gt 0 ]; do
		arg="${1}"
		case "${arg}" in
		-h | --help) _lfrCodeViewHelp; return 0 ;;
		-a | --all) allRefs=1 ;;
		-*) echo "lfrCodeView: unknown option '${arg}' (see lfrCodeView -h)." >&2; return 1 ;;
		*) ticket="${arg^^}" ;;
		esac
		shift
	done

	local branch
	branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || {
		echo "lfrCodeView: not a git repository." >&2
		return 1
	}

	local base="" entries="" count

	if [ "${allRefs}" = "1" ]; then
		[[ -z "${ticket}" && "${branch}" =~ ([A-Za-z]+-[0-9]+) ]] && ticket="${BASH_REMATCH[1]^^}"

		if [ -z "${ticket}" ]; then
			echo "lfrCodeView: -a needs a ticket (none in the branch name '${branch}')." >&2
			return 1
		fi

		entries="$(_lfrCodeViewCommits --all --grep="${ticket}" --regexp-ignore-case)"

		if [ -z "${entries}" ]; then
			echo "lfrCodeView: no commit names ${ticket} on any ref (fetch first?)." >&2
			return 1
		fi
	else
		base="$(_lfrCodeViewBase)" || {
			echo "lfrCodeView: no base ref found; set LFR_CODE_VIEW_BASE." >&2
			return 1
		}

		# Every commit the branch adds is the change under review, so no ticket and
		# no grep: the range says it.
		local commits
		commits="$(_lfrCodeViewCommits "${base}..HEAD")"
		count="$(git status --porcelain | grep -c .)"

		[ "${count}" -gt 0 ] &&
			entries="$(printf 'local\t%-7s %-19s %s' "local" "uncommitted" "${count} file(s), untracked included")"

		if [ -n "${commits}" ]; then
			entries="$(printf '%s\nrange\t%-7s %-19s %s\n%s' "${entries}" "branch" "vs ${base}" \
				"$(printf '%s\n' "${commits}" | grep -c .) commit(s) on top of it" "${commits}")"
		fi

		# grep drops the blank line left when the worktree is clean.
		entries="$(printf '%s\n' "${entries}" | grep .)"

		if [ -z "${entries}" ]; then
			echo "lfrCodeView: nothing to view; ${branch} is clean and matches ${base}."
			return 0
		fi
	fi

	# fzf runs the preview in a plain shell, where none of the functions above
	# exist, so it gets its own dispatch over the highlighted value in {1}.
	local preview
	preview="$(
		cat <<-EOF
			value={1}
			case "\${value}" in
			commit:*) git show --color=always --stat "\${value#commit:}" ;;
			local) git status --short ;;
			range) git diff --color=always --stat "${base:-HEAD}...HEAD" ;;
			esac
		EOF
	)"

	# One diff after another until you say stop: pick, read it, back for the list
	# again (reopened on the same entry, so going back never loses your place),
	# quit to leave.
	local value last=""
	while true; do
		value="$(printf '%s\n' "${entries}" | _lfrPick 'view> ' '' "${preview}" \
			'up down move    right or enter view    left or esc quit    in a diff: left or b back, q quit' \
			"${last}")" || break

		last="${value}"

		_lfrCodeViewPage "${value}" "${base}" || break
	done

	return 0
}

# Short alias.
lfrcv() { lfrCodeView "$@"; }
