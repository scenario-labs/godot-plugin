@tool
extends RefCounted
## The project each job row is followed in. With an API key every call goes to
## the key's project. Under a sign-in, each call names the row's project; rows
## sent with a key carry none, and a key belongs to one project, so they are
## looked up in the projects the account can open (free reads) and followed
## there once found. The others are set aside. Under a key, rows sent while
## signed in are set aside until a sign-in: their project may not be the key's.

const Errors := preload("res://addons/scenario/core/errors.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")

const NOTE := "Sent with an API key to a project this account cannot open. Connect that key again to follow it, or dismiss it."
const SIGNED_IN_NOTE := "Sent while signed in with Scenario, to a project an API key cannot be told to use. Sign in again to follow it, or dismiss it."


## A row this connection cannot follow: under a sign-in, one sent with a key
## that locate() has not found; under a key, one sent while signed in.
static func is_set_aside(row: Dictionary, oauth: bool) -> bool:
	if oauth:
		return Ledger.needs_project(row)
	return not str(row.get("project_id", "")).is_empty() and Ledger.needs_scenario(row)


## What the dock shows on a set-aside row: [label, note].
static func aside_text(oauth: bool) -> Array:
	return ["Sent with an API key", NOTE] if oauth else ["Sent while signed in", SIGNED_IN_NOTE]


## The scope a row's calls go to: {} with an API key.
static func of(row: Dictionary, oauth: bool) -> Dictionary:
	if not oauth or str(row.get("project_id", "")).is_empty():
		return {}
	return {"team_id": str(row.get("team_id", "")), "project_id": str(row["project_id"])}


## The scopes to list unresolved rows in: {project_id ("" with an API key): scope}.
## Under a sign-in, rows sent with a key are left out: their project is unknown.
static func of_unresolved(rows: Array, oauth: bool) -> Dictionary:
	var scopes := {}
	for row in rows:
		var scope := of(row, oauth)
		if not (oauth and scope.is_empty()):
			scopes[str(scope.get("project_id", ""))] = scope
	return scopes


## Lists the jobs of each project unresolved rows of ledger were sent to and
## links the ones that match. Returns how many were linked, or -1 when the
## session changed meanwhile (is_current is false).
static func reconcile(client, ledger, oauth: bool, now: float, is_current: Callable) -> int:
	var linked := 0
	var scopes := of_unresolved(ledger.unresolved(), oauth)
	for project_id in scopes:
		var result: Dictionary = await client.list_jobs(50, scopes[project_id])
		if not is_current.call():
			return -1
		if result["ok"]:
			linked += ledger.reconcile(result["value"], now, project_id)
	return linked


## Looks each unlocated row of ledger up in teams' projects. Returns how many
## were found, or -1 when the session changed meanwhile (is_current is false).
## A row not found stays set aside; the dock shows NOTE on it, not saved, so
## the note goes once the key is connected again.
static func locate(client, ledger, teams: Array, now: float, is_current: Callable) -> int:
	var found := 0
	for row in ledger.unlocated():
		for project in _projects(teams):
			var result: Dictionary = await client.get_job(row["job_id"], project)
			if not is_current.call():
				return -1
			if result["ok"]:
				ledger.set_scope(row["local_id"], project["team_id"], project["project_id"], now)
				found += 1
				break
			if result["error"]["kind"] in Errors.RETRYABLE_KINDS:
				break  # asked again at the next teams load
	return found


static func _projects(teams: Array) -> Array:
	var out: Array = []
	for team in teams:
		for project in team.get("projects", []):
			out.append({"team_id": str(team["id"]), "project_id": str(project["id"])})
	return out
