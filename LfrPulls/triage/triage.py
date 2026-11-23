#!/usr/bin/env python3
"""Plan and apply reviewer assignments for the open pulls of a team repository.

Plan mode (the default) reads GitHub, Jira, and the master clone. It writes
nothing on GitHub or Jira. It prints a Markdown report and writes plan.json.

Apply mode (--apply) reads plan.json, checks each pull again, and then assigns
the reviewer, adds the scope label, posts the comment, and assigns the Jira
ticket that is In Review. --reviewer PULL=LOGIN puts a different reviewer on
one pull, and --skip PULL leaves one pull out. lfrPullsTriage asks for both
after the plan.

Examples:
  triage.py
  triage.py --explain 19275
  triage.py --apply ~/.cache/pr-review-triage/plan.json --print-only
  triage.py --apply ~/.cache/pr-review-triage/plan.json --reviewer 19275=some-login --skip 19280
"""

import argparse
import base64
import concurrent.futures
import datetime
import json
import math
import os
import re
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

import yaml

# table.py, the one table build of lfrPulls and lfrPullsTriage, is in LfrPulls.
sys.path.insert(
	0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import table

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(
	os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
	"pr-review-triage")

DEFAULT_REPO = "liferay-page-management/liferay-portal"

EXCLUDED_LABELS = {
	"changesneeded": "Changes needed",
	"onhold": "On hold",
	"readytomerge": "Ready to merge",
	"reviewinprogress": "Review in progress",
	"wrongteam": "Wrong Team",
}
SCOPE_LABELS = {
	"backend": "back",
	"backendreviewneeded": "back",
	"frontend": "front",
	"frontendreviewneeded": "front",
}

NOISE_EXTENSIONS = {
	"bmp", "eot", "gif", "ico", "jpeg", "jpg", "lock", "lockfile", "macro",
	"path", "png", "snap", "svg", "testcase", "ttf", "webp", "woff", "woff2",
}
NOISE_NAMES = {"CHANGELOG.md", "package-lock.json", "package.json", "yarn.lock"}

BACK_EXTENSIONS = {
	"bnd", "ftl", "gradle", "groovy", "java", "jsp", "jspf", "properties", "sql",
	"tld", "vm", "xml", "xsd",
}
FRONT_EXTENSIONS = {"cjs", "css", "js", "jsx", "mjs", "scss", "ts", "tsx"}

CONFIDENCE_RANK = {"high": 3, "medium": 2, "low": 1, "never": 99}

KEY_PATTERN = re.compile(r"\b[A-Z][A-Z0-9]+-\d+\b")
HUNK_PATTERN = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@", re.M)
SUPERSEDE_VERBS = (
	r"(?:supersedes?|supersede of|replaces|continuation of|follow[- ]up to|"
	r"previous pull:?)")

NOW = datetime.datetime.now(datetime.timezone.utc)

notes = []


def norm_label(name):
	return re.sub(r"[^a-z0-9]", "", name.lower())


def parse_time(value):
	return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def gh_get(path, paginate=False):
	command = ["gh", "api", path]

	if paginate:
		command += ["--paginate", "--slurp"]

	result = subprocess.run(command, capture_output=True, text=True)

	if result.returncode != 0:
		raise RuntimeError(f"gh api {path}: {result.stderr.strip()[:200]}")

	data = json.loads(result.stdout)

	if paginate and data and isinstance(data[0], list):
		return [item for page in data for item in page]

	return data


def gh_write(arguments, stdin=None):
	result = subprocess.run(
		["gh", "api"] + arguments, capture_output=True, input=stdin, text=True)

	if result.returncode != 0:
		raise RuntimeError(
			f"gh api {' '.join(arguments)}: {result.stderr.strip()[:300]}")

	return result.stdout


def jira(path, method="GET", body=None):
	user = os.environ.get("JIRA_API_USER")
	token = os.environ.get("JIRA_API_TOKEN")

	if not user or not token:
		raise RuntimeError("JIRA_API_USER and JIRA_API_TOKEN are not set")

	request = urllib.request.Request(
		"https://liferay.atlassian.net/rest/api/3/" + path,
		data=json.dumps(body).encode() if body is not None else None,
		headers={
			"Accept": "application/json",
			"Authorization": "Basic " + base64.b64encode(
				f"{user}:{token}".encode()).decode(),
			"Content-Type": "application/json",
		},
		method=method)

	with urllib.request.urlopen(request, timeout=30) as response:
		content = response.read()

	return json.loads(content) if content else None


class Progress:
	"""Show a spinner, the step, and the time on stderr while the plan runs.

	It writes only when stderr is a terminal, so a pipe or a log gets no
	control characters. It clears its line before the report prints.
	"""

	FRAMES = "|/-\\"

	def __init__(self):
		self._enabled = sys.stderr.isatty()
		self._lock = threading.Lock()
		self._start = time.monotonic()
		self._step = ""
		self._stop = threading.Event()
		self._thread = None

	def __enter__(self):
		if self._enabled:
			self._thread = threading.Thread(target=self._run, daemon=True)
			self._thread.start()

		return self

	def __exit__(self, *exc):
		self.stop()

	def step(self, text):
		with self._lock:
			self._step = text

	def stop(self):
		if self._thread:
			self._stop.set()
			self._thread.join()
			self._thread = None
			sys.stderr.write("\r\033[K")
			sys.stderr.flush()

	def _run(self):
		frame = 0

		while not self._stop.wait(0.15):
			with self._lock:
				step = self._step

			elapsed = int(time.monotonic() - self._start)
			sys.stderr.write(
				f"\r\033[K{self.FRAMES[frame % 4]} {step} ({elapsed}s)")
			sys.stderr.flush()
			frame += 1


def parallel(function, items, workers=8):
	with concurrent.futures.ThreadPoolExecutor(workers) as executor:
		return list(executor.map(function, items))


def cache_read(name, max_days):
	path = os.path.join(CACHE_DIR, name)

	try:
		if (NOW.timestamp() - os.path.getmtime(path)) < max_days * 86400:
			with open(path) as file:
				return json.load(file)
	except (OSError, ValueError):
		pass

	return None


def cache_write(name, data):
	os.makedirs(CACHE_DIR, exist_ok=True)

	with open(os.path.join(CACHE_DIR, name), "w") as file:
		json.dump(data, file)


# Configuration


def load_config(repo):
	with open(os.path.join(TOOL_DIR, "config.local.yaml")) as file:
		config = (yaml.safe_load(file) or {}).get("repos", {}).get(repo)

	if not config:
		sys.exit(f"config.local.yaml has no entry for {repo}")

	config.setdefault("upstream", "liferay/" + repo.split("/")[1])
	config.setdefault("upstream_branch", "master")
	config.setdefault("backend", [])
	config.setdefault("frontend", [])
	config.setdefault("jira", {})
	config["master_clone"] = os.path.expanduser(
		config.get("master_clone", "~/liferay/repos/liferay-portal"))

	return config


def load_unavailable():
	path = os.path.join(TOOL_DIR, "availability.local.yaml")

	if not os.path.exists(path):
		notes.append("availability.local.yaml does not exist, so all reviewers are available.")

		return {}

	with open(path) as file:
		entries = yaml.safe_load(file) or []

	today = NOW.date()
	unavailable = {}

	for entry in entries:
		out = str(entry.get("out", ""))
		start, _, end = out.partition("..")

		try:
			start_date = datetime.date.fromisoformat(start.strip())
			end_date = datetime.date.fromisoformat((end or start).strip())
		except ValueError:
			notes.append(f"availability.local.yaml: the date `{out}` is not valid.")

			continue

		if start_date <= today <= end_date:
			unavailable[entry["user"]] = entry.get("reason", "unavailable")

	return unavailable


# Weight and scope


class Weigher:

	def __init__(self, config, upstream_sha):
		self.clone = config["master_clone"]
		self.upstream = config["upstream"]
		self.upstream_sha = upstream_sha
		self.generated = {}
		self.results = {}

	def _is_generated_at_upstream(self, path):
		if path not in self.generated:
			result = subprocess.run(
				["git", "-C", self.clone, "show",
					f"{self.upstream_sha}:{path}"],
				capture_output=True)
			head = b"\n".join(result.stdout.split(b"\n")[:20]).lower()
			self.generated[path] = (
				result.returncode == 0 and b"@generated" in head)

		return self.generated[path]

	def _is_noise(self, file):
		path = file["filename"]
		name = os.path.basename(path)
		extension = name.rsplit(".", 1)[-1].lower() if "." in name else ""

		if (extension in NOISE_EXTENSIONS or name in NOISE_NAMES or
				re.match(r"Language_.+\.properties$", name) or
				"__generated__" in path or "/.releng/" in path):
			return True

		added = "\n".join(
			line for line in (file.get("patch") or "").split("\n")[:40]
			if line.startswith("+")).lower()

		return "@generated" in added or self._is_generated_at_upstream(path)

	def _compare(self, owner, branch):
		pages = gh_get(
			f"repos/{self.upstream}/compare/{self.upstream_sha}..."
				f"{owner}:{urllib.parse.quote(branch, safe='')}?per_page=100",
			paginate=True)
		files = {}

		for page in pages:
			for file in page.get("files", []):
				files[file["filename"]] = file

		return {
			"ahead_by": pages[0]["ahead_by"],
			"behind_by": pages[0]["behind_by"],
			"files": list(files.values()),
			"merge_base": pages[0]["merge_base_commit"]["sha"],
			"status": pages[0]["status"],
		}

	def weigh(self, repo, number, owner, branch, head_sha):
		key = f"{number}:{head_sha}"

		if key in self.results:
			return self.results[key]

		result = {"inflated": False}

		try:
			if not owner:
				raise RuntimeError("the head repository was deleted")

			result.update(self._compare(owner, branch))
		except RuntimeError:
			files = gh_get(
				f"repos/{repo}/pulls/{number}/files?per_page=100",
				paginate=True)
			result.update({
				"ahead_by": None, "behind_by": None, "files": files,
				"inflated": True, "merge_base": None, "status": "fallback",
			})

		kept = []
		weights = {"back": 0, "front": 0, "neutral": 0}

		for file in result["files"]:
			if self._is_noise(file):
				continue

			changes = file["additions"] + file["deletions"]
			path = file["filename"]
			name = os.path.basename(path)
			extension = name.rsplit(".", 1)[-1].lower() if "." in name else ""

			if path.startswith("modules/test/playwright/"):
				side = "neutral"
			elif extension in FRONT_EXTENSIONS:
				side = "front"
			elif extension in BACK_EXTENSIONS or name == "packageinfo":
				side = "back"
			else:
				side = "neutral"

			weights[side] += changes
			kept.append({
				"changes": changes, "patch": file.get("patch"), "path": path,
				"side": side,
			})

		total = sum(weights.values())
		result.update({
			"kept": kept,
			"trivial": total == 0,
			"weight": max(total, 1),
			"weights": weights,
		})
		del result["files"]

		self.results[key] = result

		return result


def classify(weighed):
	back = weighed["weights"]["back"]
	front = weighed["weights"]["front"]

	if back + front == 0:
		return None, "low", 0.0

	share = back / (back + front)

	if share >= 0.8:
		return "back", "high", share
	if share <= 0.2:
		return "front", "high", share
	if share >= 0.7:
		return "back", "medium", share
	if share <= 0.3:
		return "front", "medium", share

	return "mixed", "low", share


# Load


def compute_loads(
		repo, config, window_days, open_pulls, weigher, roles, weight_cap):
	start = NOW - datetime.timedelta(days=window_days)
	reviewers = set(roles["back"]) | set(roles["front"])
	updated = []
	page = 1

	while True:
		pulls = gh_get(
			f"repos/{repo}/pulls?state=all&sort=updated&direction=desc"
				f"&per_page=100&page={page}")
		updated += [
			pull for pull in pulls if parse_time(pull["updated_at"]) >= start]

		if (len(pulls) < 100 or
				parse_time(pulls[-1]["updated_at"]) < start):
			break

		page += 1

	def reviews_of(pull):
		return gh_get(
			f"repos/{repo}/pulls/{pull['number']}/reviews?per_page=100",
			paginate=True)

	completed = {login: [] for login in reviewers}

	for pull, reviews in zip(updated, parallel(reviews_of, updated)):
		author = pull["user"]["login"]

		for login in {
				review["user"]["login"] for review in reviews
				if review.get("user") and review.get("submitted_at") and
					parse_time(review["submitted_at"]) >= start}:
			if login in reviewers and login != author:
				completed[login].append(pull)

	open_assigned = {login: [] for login in reviewers}

	for pull in open_pulls:
		author = pull["author"]["login"]

		for assignee in pull["assignees"]:
			login = assignee["login"]

			# A pull that the reviewer already reviewed in the window counts
			# as completed only, not two times.
			if login in reviewers and login != author and pull["number"] not in {
					completed_pull["number"]
					for completed_pull in completed[login]}:
				open_assigned[login].append(pull)

	def weigh_rest(pull):
		head = pull["head"]

		return weigher.weigh(
			repo, pull["number"],
			(head.get("repo") or {}).get("owner", {}).get("login"),
			head["ref"], head["sha"])

	def weigh_open(pull):
		return weigher.weigh(
			repo, pull["number"],
			(pull.get("headRepositoryOwner") or {}).get("login"),
			pull["headRefName"], pull["headRefOid"])

	completed_pulls = {
		pull["number"]: pull for pulls in completed.values() for pull in pulls}
	open_numbers = {
		pull["number"]: pull for pulls in open_assigned.values()
		for pull in pulls}
	# One very big pull must not make the full load of a reviewer, so each pull
	# counts with a weight of weight_cap or less.
	weights = dict(zip(
		completed_pulls, (min(item["weight"], weight_cap) for item in parallel(
			weigh_rest, list(completed_pulls.values())))))
	weights.update(zip(
		open_numbers, (min(item["weight"], weight_cap) for item in parallel(
			weigh_open, list(open_numbers.values())))))

	def assigned_days(number):
		events = gh_get(
			f"repos/{repo}/issues/{number}/timeline?per_page=100",
			paginate=True)
		latest = {}

		for event in events:
			if event.get("event") == "assigned" and event.get("assignee"):
				latest[event["assignee"]["login"]] = parse_time(
					event["created_at"])

		return latest

	assigned_at = dict(zip(
		open_numbers, parallel(assigned_days, list(open_numbers))))

	loads = {}

	for login in sorted(reviewers):
		completed_weight = sum(
			weights[pull["number"]] for pull in completed[login])
		decayed = 0.0
		flat = 0.0

		for pull in open_assigned[login]:
			when = assigned_at[pull["number"]].get(login)
			days = max(1, int((NOW - when).total_seconds() // 86400)) \
				if when else 1
			decayed += weights[pull["number"]] * math.exp(-days / 3)
			flat += weights[pull["number"]]

		loads[login] = {
			"completed": completed_weight,
			"completed_count": len(completed[login]),
			"open_count": len(open_assigned[login]),
			"open_decayed": decayed,
			"open_flat": flat,
		}

	return loads


def total_load(load, model):
	if model == "open-flat":
		return load["completed"] + load["open_flat"]
	if model == "completed-only":
		return load["completed"]

	return load["completed"] + load["open_decayed"]


def normalize(totals):
	values = list(totals.values())

	if not values:
		return {}

	median = statistics.median(values)
	positive = [value for value in values if value > 0]
	scale = median if median > 0 else (
		statistics.mean(positive) if positive else 1)

	return {login: value / scale for login, value in totals.items()}


# Expertise


def commit_emails(config, logins):
	cached = cache_read("emails.json", 30) or {}
	missing = [login for login in logins if login not in cached]

	def emails_of(login):
		commits = gh_get(
			f"repos/{config['upstream']}/commits?author={login}&per_page=30")
		emails = {
			commit["commit"]["author"]["email"].lower() for commit in commits}
		emails.add(f"{login.lower()}@users.noreply.github.com")

		return sorted(emails)

	for login, emails in zip(missing, parallel(emails_of, missing)):
		cached[login] = emails

	cache_write("emails.json", cached)

	mapping = {}

	for login in logins:
		if len(cached[login]) == 1:
			notes.append(
				f"No commit email found for `{login}`, so blame cannot "
				"match that reviewer.")

		for email in cached[login]:
			mapping[email] = login

	return mapping


class Blamer:

	def __init__(self, clone, emails):
		self.clone = clone
		self.emails = emails
		self.fetched = False

	def _has_commit(self, sha):
		return subprocess.run(
			["git", "-C", self.clone, "cat-file", "-e", sha + "^{commit}"],
			capture_output=True).returncode == 0

	def blame(self, weighed):
		hits = {}
		sha = weighed.get("merge_base")

		if not sha:
			return hits

		if not self._has_commit(sha) and not self.fetched:
			self.fetched = True
			subprocess.run(
				["git", "-C", self.clone, "fetch", "--no-tags", "--quiet",
					"upstream", "master"],
				capture_output=True)
			notes.append(
				"Fetched `upstream master` into the master clone for blame "
				"(remote refs only, no change to the working tree).")

		if not self._has_commit(sha):
			notes.append(f"Merge base {sha[:10]} is not in the master clone.")

			return hits

		def blame_file(file):
			ranges = []

			for match in HUNK_PATTERN.finditer(file["patch"]):
				count = int(match.group(2) or 1)

				if count:
					ranges += ["-L", f"{match.group(1)},+{count}"]

			if not ranges:
				return ""

			return subprocess.run(
				["git", "-C", self.clone, "blame", "-w", "--line-porcelain"] +
					ranges + [sha, "--", file["path"]],
				capture_output=True, text=True).stdout

		files = [file for file in weighed["kept"]
			if file["changes"] >= 5 and file["patch"]]

		for file, output in zip(files, parallel(blame_file, files)):
			commit = None
			line = None

			for row in output.split("\n"):
				header = re.match(r"^([0-9a-f]{40}) (\d+) ", row)

				if header:
					commit, line = header.group(1), int(header.group(2))
				elif row.startswith("author-mail "):
					email = row[len("author-mail "):].strip("<>").lower()
					login = self.emails.get(email)

					if login:
						hit = hits.setdefault(login, {"lines": 0, "files": {}})
						hit["lines"] += 1
						per_file = hit["files"].setdefault(
							file["path"],
							{"commit": commit, "line": line, "lines": 0})
						per_file["lines"] += 1

		return hits


class StoryFinder:

	def __init__(self, repo):
		self.repo = repo
		self.sets = {}
		self.pulls = {}

	def _children(self, key):
		data = jira(
			"search/jql?" + urllib.parse.urlencode({
				"fields": "key", "jql": f'parent = "{key}"',
				"maxResults": 100}))

		return [issue["key"] for issue in data.get("issues", [])]

	def story_set(self, keys):
		result = set()

		for key in keys:
			if key not in self.sets:
				try:
					issue = jira(f"issue/{key}?fields=parent")
					parent = ((issue.get("fields") or {}).get("parent") or
						{}).get("key")
					story = {key} | set(self._children(key))

					if parent:
						story |= {parent} | set(self._children(parent))

					self.sets[key] = story
				except Exception as exception:
					notes.append(f"Jira lookup of {key} failed: {exception}")
					self.sets[key] = {key}

			result |= self.sets[key]

		return result

	def pulls_of(self, keys):
		missing = sorted(key for key in keys if key not in self.pulls)

		for index in range(0, len(missing), 5):
			batch = missing[index:index + 5]
			query = (
				f"repo:{self.repo} is:pr in:title " +
				" OR ".join(f'"{key}"' for key in batch))
			items = gh_get(
				"search/issues?per_page=100&q=" + urllib.parse.quote(query))

			for key in batch:
				pattern = re.compile(rf"\b{re.escape(key)}\b")
				self.pulls[key] = [
					{
						"assignees": [
							assignee["login"] for assignee in item["assignees"]],
						"author": item["user"]["login"],
						"number": item["number"],
						"title": item["title"],
					}
					for item in items.get("items", [])
					if pattern.search(item["title"])]

		return {key: self.pulls[key] for key in keys}


# Supersede


def find_supersede(repo, pull, reviewers):
	owner, name = repo.split("/")
	text = (pull.get("title") or "") + "\n" + (pull.get("body") or "")
	pattern = re.compile(
		SUPERSEDE_VERBS + r"\s*(?:#(\d+)|https://github\.com/" +
		re.escape(owner) + "/" + re.escape(name) + r"/pull/(\d+))", re.I)
	targets = []

	for match in pattern.finditer(text):
		targets.append(("body", int(match.group(1) or match.group(2))))

	branch = pull["headRefName"]
	match = re.match(r"^(.+?)-(v(\d+)|redate)$", branch)
	head_owner = (pull.get("headRepositoryOwner") or {}).get("login")

	if match and head_owner:
		candidates = [match.group(1)]

		if match.group(3) and int(match.group(3)) > 2:
			candidates.append(f"{match.group(1)}-v{int(match.group(3)) - 1}")

		keys = set(KEY_PATTERN.findall(pull["title"]))

		for candidate in candidates:
			for prior in gh_get(
					f"repos/{repo}/pulls?state=closed&head={head_owner}:"
						f"{urllib.parse.quote(candidate, safe='')}"):
				if keys & set(KEY_PATTERN.findall(prior["title"])):
					targets.append(("branch", prior["number"]))

	for source, number in targets:
		if number == pull["number"]:
			continue

		target = gh_get(f"repos/{repo}/pulls/{number}")
		author = target["user"]["login"]
		engagement = {}

		for review in gh_get(
				f"repos/{repo}/pulls/{number}/reviews?per_page=100",
				paginate=True):
			login = (review.get("user") or {}).get("login")

			if login in reviewers and login != author:
				count, latest = engagement.get(login, (0, ""))
				engagement[login] = (
					count + 1, max(latest, review.get("submitted_at") or ""))

		for comment in gh_get(
				f"repos/{repo}/pulls/{number}/comments?per_page=100",
				paginate=True):
			login = (comment.get("user") or {}).get("login")

			if login in reviewers and login != author:
				count, latest = engagement.get(login, (0, ""))
				engagement[login] = (
					count + 1, max(latest, comment.get("created_at") or ""))

		if not engagement:
			for assignee in target.get("assignees") or []:
				if assignee["login"] in reviewers and \
						assignee["login"] != author:
					engagement[assignee["login"]] = (0, "")

		reviewer = max(
			engagement, key=lambda login: engagement[login],
			default=None)

		return {"number": number, "reviewer": reviewer, "source": source}

	return None


# Comment


def build_comment(pick, upstream):
	login = pick["reviewer"]
	reason = pick["reason"]

	if reason == "supersede":
		text = (
			f"this pull replaces #{pick['supersede']}, and you reviewed "
			f"#{pick['supersede']}. I assigned it to you to keep the context.")
	elif reason == "trivial":
		text = (
			"this is a light review, because most of the pull is generated "
			"code. I assigned it to you to keep the load even.")
	elif reason in ("blame", "blame+story"):
		blame = pick["blame"]
		where = (
			f"[{blame['path']}:{blame['line']}](https://github.com/{upstream}/"
			f"blob/{blame['commit']}/{blame['path']}#L{blame['line']}) "
			f"(commit [{blame['commit'][:10]}](https://github.com/{upstream}/"
			f"commit/{blame['commit']}))")

		if reason == "blame":
			text = (
				"I assigned this review to you because you changed the same "
				f"lines before, in {where}.")
		else:
			story = pick["story"]
			text = (
				"I assigned this review to you because you changed the same "
				f"lines before, in {where}, and you reviewed #{story['number']} "
				f"({story['key']}) of the same story.")
	elif reason == "manual":
		text = "I assigned this review to you."
	elif reason == "story":
		story = pick["story"]
		text = (
			f"I assigned this review to you because you reviewed "
			f"#{story['number']} ({story['key']}) of the same story.")
	else:

		# A rotation pick has no reason to tell, so the pull gets no comment.

		return None

	return f"@{login}, {text} Thanks!"


def find_story_hits(stories, keys, number):
	story_pulls = stories.pulls_of(stories.story_set(keys)) if keys else {}
	story_hits = {}

	for key, pulls in story_pulls.items():
		for story_pull in pulls:
			if story_pull["number"] == number:
				continue

			for login in story_pull["assignees"]:
				if login != story_pull["author"]:
					story_hits.setdefault(login, {})[story_pull["number"]] = key

	return story_hits


def score_pool(args, available, pool, totals, hits, story_hits):
	norms = normalize({login: totals[login] for login in available})
	max_blame = max(
		[hits.get(login, {}).get("lines", 0) for login in pool] + [0])
	max_story = max([len(story_hits.get(login, {})) for login in pool] + [0])
	table = []

	for login in pool:
		blame = hits.get(login, {}).get("lines", 0)
		story = len(story_hits.get(login, {}))
		blame_norm = blame / max_blame if max_blame else 0
		story_norm = story / max_story if max_story else 0
		expertise = ((1 - args.story_weight) * blame_norm +
			args.story_weight * story_norm)
		table.append({
			"blame": blame, "expertise": expertise, "load": totals[login],
			"load_norm": norms[login], "login": login,
			"score": norms[login] - args.expertise_weight * expertise,
			"story": story,
		})

	table.sort(key=lambda row: (row["score"], row["load_norm"], row["login"]))
	best = table[0]
	ties = [row for row in table if row["score"] - best["score"] <= 0.05]
	ties.sort(key=lambda row: (row["load_norm"], row["login"]))

	return table, ties[0]


# Plan


def plan(args):
	with Progress() as progress:
		_plan(args, progress)


def _plan(args, progress):
	progress.step("Read the configuration and the upstream head")
	repo = args.repo
	config = load_config(repo)
	unavailable = load_unavailable()
	roles = {"back": config["backend"], "front": config["frontend"]}
	reviewers = set(roles["back"]) | set(roles["front"])
	upstream_sha = gh_get(
		f"repos/{config['upstream']}/branches/{config['upstream_branch']}"
	)["commit"]["sha"]
	repo_labels = {
		norm_label(label["name"]): label["name"]
		for label in gh_get(f"repos/{repo}/labels?per_page=100", paginate=True)}

	progress.step("Read the open pulls")
	result = subprocess.run(
		["gh", "pr", "list", "--repo", repo, "--state", "open", "--limit",
			"200", "--json",
			"assignees,author,body,createdAt,headRefName,headRefOid,"
			"headRepositoryOwner,isDraft,labels,number,title,url"],
		capture_output=True, check=True, text=True)
	open_pulls = json.loads(result.stdout)

	excluded = []
	candidates = []

	for pull in sorted(open_pulls, key=lambda pull: pull["createdAt"]):
		if pull["isDraft"]:
			continue

		author = pull["author"]["login"]

		if [a for a in pull["assignees"] if a["login"] != author]:
			continue

		labels = [norm_label(label["name"]) for label in pull["labels"]]
		blocked = [EXCLUDED_LABELS[label] for label in labels
			if label in EXCLUDED_LABELS]

		if blocked:
			excluded.append({"labels": blocked, "pull": pull})

			continue

		candidates.append(pull)

	capped = candidates[args.max_prs:]
	candidates = candidates[:args.max_prs]

	if capped:
		notes.append(
			f"{len(capped)} more pulls need a reviewer, but --max-prs is "
			f"{args.max_prs}. Run again after this run.")

	weigher = Weigher(config, upstream_sha)
	progress.step("Compute the review load of each reviewer")
	loads = compute_loads(
		repo, config, args.window, open_pulls, weigher, roles,
		args.weight_cap)
	totals = {
		login: total_load(load, args.load_model)
		for login, load in loads.items()}
	before = dict(totals)
	progress.step("Read the commit emails of the reviewers")
	emails = commit_emails(config, sorted(reviewers))
	blamer = Blamer(config["master_clone"], emails)
	stories = StoryFinder(repo)
	label_names = {
		"back": repo_labels.get("backendreviewneeded"),
		"front": repo_labels.get("frontendreviewneeded"),
	}

	report = {
		"assigned": [], "excluded": excluded, "manual": [], "no_eligible": [],
		"no_new_work": [], "supersede": [],
	}
	explanations = {}

	progress.step(f"Weigh the changes of {len(candidates)} pulls")
	weighed_list = parallel(
		lambda pull: weigher.weigh(
			repo, pull["number"],
			(pull.get("headRepositoryOwner") or {}).get("login"),
			pull["headRefName"], pull["headRefOid"]),
		candidates)

	for index, (pull, weighed) in enumerate(zip(candidates, weighed_list)):
		number = pull["number"]
		author = pull["author"]["login"]
		progress.step(
			f"Score pull #{number} ({index + 1}/{len(candidates)}): "
			"blame, stories, supersede")

		if weighed["ahead_by"] == 0:
			report["no_new_work"].append(pull)

			continue

		labels = {
			SCOPE_LABELS[norm_label(label["name"])]
			for label in pull["labels"]
			if norm_label(label["name"]) in SCOPE_LABELS}
		add_labels = []

		if labels:
			needed = sorted(labels)
		else:
			scope, confidence, share = classify(weighed)

			if (scope is None or CONFIDENCE_RANK[confidence] <
					CONFIDENCE_RANK[args.label_confidence]):
				report["manual"].append({
					"confidence": confidence, "pull": pull, "scope": scope,
					"share": share, "weight": weighed["weight"]})

				continue

			needed = ["back", "front"] if scope == "mixed" else [scope]
			add_labels = [label_names[role] for role in needed
				if label_names[role]]

		supersede = find_supersede(repo, pull, reviewers)

		if supersede:
			report["supersede"].append({"pull": pull, **supersede})

		hits = blamer.blame(weighed) if weighed["merge_base"] else {}
		keys = list(dict.fromkeys(KEY_PATTERN.findall(pull["title"])))
		story_hits = find_story_hits(stories, keys, number)

		explanations[number] = {}

		for role in needed:
			role_name = "backend" if role == "back" else "frontend"
			available = [login for login in roles[role]
				if login not in unavailable]
			pool = [login for login in available if login != author]

			if not pool:
				report["no_eligible"].append({"pull": pull, "role": role_name})

				continue

			table, winner = score_pool(
				args, available, pool, totals, hits, story_hits)
			explanations[number][role_name] = table

			pick = {"reviewer": winner["login"]}

			if (supersede and supersede["reviewer"] in pool):
				pick = {
					"reason": "supersede", "reviewer": supersede["reviewer"],
					"supersede": supersede["number"]}
				supersede["moved"] = supersede["reviewer"] != winner["login"]
			elif weighed["trivial"]:
				pick["reason"] = "trivial"
			else:
				login = winner["login"]
				blame_hit = hits.get(login)
				story_hit = story_hits.get(login)

				if blame_hit:
					path, info = max(
						blame_hit["files"].items(),
						key=lambda item: item[1]["lines"])
					pick["blame"] = {
						"commit": info["commit"], "line": info["line"],
						"path": path}

				if story_hit:
					story_number = sorted(story_hit)[0]
					pick["story"] = {
						"key": story_hit[story_number],
						"number": story_number}

				pick["reason"] = (
					"blame+story" if blame_hit and story_hit else
					"blame" if blame_hit else
					"story" if story_hit else "load")

			pick["comment"] = build_comment(pick, config["upstream"])
			totals[pick["reviewer"]] += min(weighed["weight"], args.weight_cap)

			candidates = [pick["reviewer"]] + [
				row["login"] for row in table
				if row["login"] != pick["reviewer"]][:2]
			scores = {row["login"]: row for row in table}

			report["assigned"].append({
				"add_labels": add_labels,
				"candidates": [
					{
						"blame": scores[login]["blame"],
						"login": login,
						"score": round(scores[login]["score"], 3),
						"story": scores[login]["story"],
					}
					for login in candidates if login in scores],
				"head_sha": pull["headRefOid"],
				"inflated": weighed["inflated"],
				"jira_account": config["jira"].get(pick["reviewer"]),
				"keys": keys,
				"number": number,
				"role": role_name,
				"title": pull["title"],
				"trivial": weighed["trivial"],
				"url": pull["url"],
				"weight": weighed["weight"],
				**pick,
			})
			add_labels = []

	plan_data = {
		"assigned": report["assigned"],
		"created": NOW.isoformat(),
		"repo": repo,
	}
	os.makedirs(os.path.dirname(args.out), exist_ok=True)

	with open(args.out, "w") as file:
		json.dump(plan_data, file, indent="\t")

	progress.stop()
	print_report(
		args, report, loads, before, totals, unavailable, explanations, roles)


def print_table(out, headers, rows):
	for line in table.render(headers, rows):
		out(line)


def print_report(
		args, report, loads, before, after, unavailable, explanations, roles):

	out = print
	out(f"PLAN ONLY. No GitHub or Jira writes made. Plan: `{args.out}`\n")

	out("## Assigned\n")

	if report["assigned"]:
		rows = []

		for item in report["assigned"]:
			weight = str(item["weight"]) + (
				" (trivial)" if item["trivial"] else "") + (
				" (may be inflated)" if item["inflated"] else "")
			labels = (
				f" Adds label {', '.join(item['add_labels'])}."
				if item["add_labels"] else "")
			rows.append([
				item["url"], item["title"][:60], item["role"], weight,
				item["reviewer"], f"{item['reason']}.{labels}"])

		print_table(
			out, ["Pull", "Title", "Scope", "Weight", "Reviewer", "Reason"],
			rows)

		out("\nComments:\n")

		for item in report["assigned"]:
			out(f"- #{item['number']}: {item['comment'] or '(no comment)'}")
	else:
		out("None.")

	sections = [
		("Supersede detected", report["supersede"], lambda item: (
			f"- {item['pull']['url']} replaces #{item['number']} "
			f"(found in the {item['source']}). Reviewer of #{item['number']}: "
			f"{item['reviewer'] or 'none in the team'}. "
			f"Changed the pick: {'yes' if item.get('moved') else 'no'}.")),
		("Needs Manual Triage", report["manual"], lambda item: (
			f"- {item['pull']['url']} {item['pull']['title'][:60]}: "
			f"proposed scope {item['scope'] or 'unknown'}, confidence "
			f"{item['confidence']}, backend share "
			f"{item['share']:.0%}, weight {item['weight']}.")),
		("No Eligible Reviewer", report["no_eligible"], lambda item: (
			f"- {item['pull']['url']}: no available {item['role']} reviewer.")),
		("No New Work vs Upstream", report["no_new_work"], lambda pull: (
			f"- {pull['url']} {pull['title'][:60]}")),
		("Excluded by label", report["excluded"], lambda item: (
			f"- {item['pull']['url']} {item['pull']['title'][:60]}: "
			f"{', '.join(item['labels'])}")),
	]

	for title, items, line in sections:
		out(f"\n## {title}\n")

		if items:
			for item in items:
				out(line(item))
		else:
			out("None.")

	out(f"\n## Updated Load Per Reviewer ({args.window} days, "
		f"{args.load_model})\n")
	rows = []

	for role in ("back", "front"):
		for login in roles[role]:
			load = loads[login]
			velocity = load["completed_count"] / max(1, load["open_count"])
			status = f" ({unavailable[login]})" if login in unavailable else ""
			rows.append([
				f"{role}end", f"{login}{status}", f"{before[login]:.0f}",
				f"{after[login]:.0f}", load["completed_count"],
				load["open_count"], f"{velocity:.1f}"])

	print_table(
		out,
		[
			"Role", "Reviewer", "Before", "After", "Completed", "Open",
			"Velocity"
		],
		rows)

	out("\n## Notes\n")
	out("\n".join(f"- {note}" for note in dict.fromkeys(notes)) or "None.")

	if args.explain:
		out(f"\n## Explain #{args.explain}\n")

		if args.explain not in explanations:
			out("This pull was not scored in this run.")

		for role_name, table in explanations.get(args.explain, {}).items():
			out(f"\n{role_name}:\n")
			print_table(
				out,
				[
					"Reviewer", "Load", "Load norm", "Blame lines",
					"Story pulls", "Expertise", "Score"
				],
				[
					[
						row["login"], f"{row['load']:.0f}",
						f"{row['load_norm']:.2f}", row["blame"], row["story"],
						f"{row['expertise']:.2f}", f"{row['score']:.2f}"
					]
					for row in table
				])


# Apply


def override(plan_data, args, repo):
	reviewers = {}

	for value in args.reviewer:
		number, _, login = value.partition("=")

		if not number.isdigit() or not login:
			sys.exit(f"--reviewer {value}: use PULL=LOGIN, e.g. 19275=some-login.")

		reviewers[int(number)] = login

	skips = set(args.skip)
	numbers = {item["number"] for item in plan_data["assigned"]}

	for number in (set(reviewers) | skips) - numbers:
		sys.exit(f"#{number} is not in the plan.")

	if not reviewers:
		plan_data["assigned"] = [
			item for item in plan_data["assigned"]
			if item["number"] not in skips]

		return

	config = load_config(repo)
	known = set(config["backend"]) | set(config["frontend"])

	for item in plan_data["assigned"]:
		login = reviewers.get(item["number"])

		if not login or login == item["reviewer"]:
			continue

		if login not in known:
			sys.exit(f"--reviewer {item['number']}={login}: {login} is not a "
				"reviewer in config.local.yaml.")

		for key in ("blame", "story", "supersede"):
			item.pop(key, None)

		item["reviewer"] = login
		item["reason"] = "manual"
		item["comment"] = build_comment(item, config["upstream"])
		item["jira_account"] = config["jira"].get(login)

	plan_data["assigned"] = [
		item for item in plan_data["assigned"] if item["number"] not in skips]


def apply(args):
	with open(os.path.expanduser(args.apply)) as file:
		plan_data = json.load(file)

	age = NOW - parse_time(plan_data["created"])

	if age > datetime.timedelta(hours=12):
		sys.exit("The plan is older than 12 hours. Run the plan again.")

	repo = plan_data["repo"]

	override(plan_data, args, repo)

	for item in plan_data["assigned"]:
		number = item["number"]
		pull = gh_get(f"repos/{repo}/pulls/{number}")
		author = pull["user"]["login"]
		assignees = [a["login"] for a in pull["assignees"]]
		others = [login for login in assignees if login != author]

		if pull["state"] != "open" or pull["head"]["sha"] != item["head_sha"]:
			print(f"- #{number}: SKIPPED, the pull changed after the plan.")

			continue

		if item["reviewer"] in assignees:
			print(f"- #{number}: SKIPPED, {item['reviewer']} is already assigned.")

			continue

		planned = {
			other["reviewer"] for other in plan_data["assigned"]
			if other["number"] == number}

		if set(others) - planned:
			print(f"- #{number}: SKIPPED, somebody else is assigned now: "
				f"{', '.join(others)}.")

			continue

		actions = [
			(["-X", "POST", f"repos/{repo}/issues/{number}/assignees", "-f",
				f"assignees[]={item['reviewer']}"], None),
		]

		current = {label["name"] for label in pull["labels"]}

		for label in item["add_labels"]:
			if label not in current:
				actions.append(
					(["-X", "POST", f"repos/{repo}/issues/{number}/labels",
						"-f", f"labels[]={label}"], None))

		if item["comment"]:
			actions.append(
				(["-X", "POST", f"repos/{repo}/issues/{number}/comments",
					"-F", "body=@-"], item["comment"]))

		for arguments, stdin in actions:
			if args.print_only:
				print(f"  would run: gh api {' '.join(arguments)}" + (
					f"  <<< {stdin}" if stdin else ""))
			else:
				gh_write(arguments, stdin)

		print(f"- #{number}: assigned {item['reviewer']}" + (
			" (print only)" if args.print_only else "") + ".")

		account = item.get("jira_account")

		for key in item["keys"]:
			issue = jira(f"issue/{key}?fields=status,assignee")
			status = issue["fields"]["status"]["name"]
			current_account = (issue["fields"].get("assignee") or {}).get(
				"accountId")

			if status.lower() != "in review":
				print(f"  Jira {key}: not changed, the status is {status}.")
			elif not account:
				print(f"  Jira {key}: not changed, config.local.yaml has no Jira "
					f"account for {item['reviewer']}.")
			elif current_account == account:
				print(f"  Jira {key}: already assigned to {item['reviewer']}.")
			elif args.print_only:
				print(f"  Jira {key}: would assign to {item['reviewer']}.")
			else:
				jira(f"issue/{key}/assignee", "PUT", {"accountId": account})
				print(f"  Jira {key}: assigned to {item['reviewer']}.")


# Fit


FIT_TTL = 12 * 3600


def fit(args):
	with Progress() as progress:
		_fit(args, progress)


def _fit(args, progress):
	"""Print "NUMBER<TAB>FIT" for each pull in --pulls.

	FIT says if LOGIN fits as the reviewer of the pull, with the rules of the
	plan: best (the plan picks LOGIN), good (LOGIN has blame or story hits),
	ok (the role of LOGIN matches the scope), no-role (it does not), or ? (the
	scope is not clear). A result stays in the cache for FIT_TTL seconds, or
	until the head of the pull changes.
	"""

	login = args.fit
	repo = args.repo
	cache_path = os.path.join(CACHE_DIR, "fit.json")

	try:
		with open(cache_path) as file:
			cache = json.load(file)
	except (OSError, ValueError):
		cache = {}

	progress.step("Read the open pulls")
	result = subprocess.run(
		["gh", "pr", "list", "--repo", repo, "--state", "open", "--limit",
			"200", "--json",
			"assignees,author,body,createdAt,headRefName,headRefOid,"
			"headRepositoryOwner,isDraft,labels,number,title,url"],
		capture_output=True, check=True, text=True)
	open_pulls = json.loads(result.stdout)
	by_number = {pull["number"]: pull for pull in open_pulls}
	numbers = [number for number in args.pulls if number in by_number]
	now = time.time()

	def cache_key(number):
		return f"{repo}#{number}#{login}"

	def cached(number):
		entry = cache.get(cache_key(number))

		return entry and entry["sha"] == by_number[number]["headRefOid"] and \
			now - entry["time"] < FIT_TTL

	missing = [number for number in numbers if not cached(number)]

	# The plan gives the pulls in order and adds each pick to the load, so a
	# fit depends on the other pulls. If one result is missing, score all again.
	if missing:
		missing = numbers
		fits = _fit_pulls(
			args, progress, login, repo, open_pulls,
			sorted(
				(by_number[number] for number in missing),
				key=lambda pull: pull["createdAt"]))

		for number in missing:
			cache[cache_key(number)] = {
				"fit": fits[number], "sha": by_number[number]["headRefOid"],
				"time": now}

		cache = {
			key: entry for key, entry in cache.items()
			if now - entry["time"] < FIT_TTL}
		os.makedirs(CACHE_DIR, exist_ok=True)

		with open(cache_path, "w") as file:
			json.dump(cache, file, indent="\t")

	progress.stop()

	for number in numbers:
		print(f"{number}\t{cache[cache_key(number)]['fit']}")


def _fit_pulls(args, progress, login, repo, open_pulls, pulls):
	config = load_config(repo)
	unavailable = load_unavailable()
	roles = {"back": config["backend"], "front": config["frontend"]}
	reviewers = set(roles["back"]) | set(roles["front"])
	upstream_sha = gh_get(
		f"repos/{config['upstream']}/branches/{config['upstream_branch']}"
	)["commit"]["sha"]
	weigher = Weigher(config, upstream_sha)
	progress.step("Compute the review load of each reviewer")
	loads = compute_loads(
		repo, config, args.window, open_pulls, weigher, roles,
		args.weight_cap)
	totals = {
		reviewer: total_load(load, args.load_model)
		for reviewer, load in loads.items()}
	progress.step("Read the commit emails of the reviewers")
	blamer = Blamer(
		config["master_clone"], commit_emails(config, sorted(reviewers)))
	stories = StoryFinder(repo)
	progress.step(f"Weigh the changes of {len(pulls)} pulls")
	weighed_list = parallel(
		lambda pull: weigher.weigh(
			repo, pull["number"],
			(pull.get("headRepositoryOwner") or {}).get("login"),
			pull["headRefName"], pull["headRefOid"]),
		pulls)
	fits = {}

	for index, (pull, weighed) in enumerate(zip(pulls, weighed_list)):
		number = pull["number"]
		progress.step(
			f"Score pull #{number} ({index + 1}/{len(pulls)}) for {login}")
		labels = {
			SCOPE_LABELS[norm_label(label["name"])]
			for label in pull["labels"]
			if norm_label(label["name"]) in SCOPE_LABELS}

		if labels:
			needed = sorted(labels)
		else:
			scope = classify(weighed)[0] if weighed["ahead_by"] else None

			if scope is None:
				fits[number] = "?"

				continue

			needed = ["back", "front"] if scope == "mixed" else [scope]

		author = pull["author"]["login"]
		supersede = find_supersede(repo, pull, reviewers)
		hits = blamer.blame(weighed) if weighed["merge_base"] else {}
		keys = list(dict.fromkeys(KEY_PATTERN.findall(pull["title"])))
		story_hits = find_story_hits(stories, keys, number)
		verdict = "no-role"

		# Score each role, also a role that LOGIN does not have, because the
		# pick of each role adds to the load, as in the plan.
		for role in needed:
			available = [
				reviewer for reviewer in roles[role]
				if reviewer not in unavailable or reviewer == login]
			pool = [reviewer for reviewer in available if reviewer != author]

			if not pool:
				continue

			table, winner = score_pool(
				args, available, pool, totals, hits, story_hits)
			pick = winner["login"]

			if supersede and supersede["reviewer"] in pool:
				pick = supersede["reviewer"]

			totals[pick] += min(weighed["weight"], args.weight_cap)
			mine = next(
				(row for row in table if row["login"] == login), None)

			if not mine:
				continue

			if pick == login:
				verdict = "best"
			elif verdict != "best" and (mine["blame"] or mine["story"]):
				verdict = "good"
			elif verdict == "no-role":
				verdict = "ok"

		fits[number] = verdict

	return fits


def main():
	parser = argparse.ArgumentParser(
		description=__doc__,
		formatter_class=argparse.RawDescriptionHelpFormatter)
	parser.add_argument("--apply", metavar="PLAN_JSON")
	parser.add_argument("--dry-run", action="store_true",
		help="accepted for compatibility; plan mode writes nothing anyway")
	parser.add_argument("--expertise-weight", default=0.3, type=float)
	parser.add_argument("--explain", type=int, metavar="PULL_NUMBER")
	parser.add_argument("--fit", metavar="LOGIN",
		help="print if LOGIN fits as the reviewer of each pull in --pulls")
	parser.add_argument("--label-confidence", default="high",
		choices=["high", "medium", "low", "never"])
	parser.add_argument("--load-model", default="completed-and-decayed-open",
		choices=["completed-and-decayed-open", "open-flat", "completed-only"])
	parser.add_argument("--max-prs", default=30, type=int)
	parser.add_argument("--out", default=os.path.join(CACHE_DIR, "plan.json"))
	parser.add_argument("--pulls", default=[],
		type=lambda value: [int(number) for number in value.split(",") if number],
		metavar="N,N", help="with --fit, the pulls to check")
	parser.add_argument("--print-only", action="store_true",
		help="with --apply, print the writes instead of doing them")
	parser.add_argument("--repo", default=DEFAULT_REPO)
	parser.add_argument("--reviewer", action="append", default=[],
		metavar="PULL=LOGIN",
		help="with --apply, assign LOGIN to PULL instead of the planned reviewer")
	parser.add_argument("--skip", action="append", default=[], type=int,
		metavar="PULL", help="with --apply, leave PULL out")
	parser.add_argument("--story-weight", default=0.5, type=float)
	parser.add_argument("--weight-cap", default=1000, type=int,
		help="the maximum weight of one pull in the load (default 1000)")
	parser.add_argument("--window", default=7, metavar="DAYS",
		type=lambda value: int(value.rstrip("d")))
	args = parser.parse_args()

	if args.apply:
		apply(args)
	elif args.fit:
		fit(args)
	else:
		plan(args)


if __name__ == "__main__":
	main()
