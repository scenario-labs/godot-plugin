@tool
extends RefCounted
## A signed-in Scenario session: the access token (memory only), the refresh
## token (rotated through on_rotate, which saves it), and the team and project
## every call goes to.
##
## One refresh at a time: a call that needs a token while a refresh runs waits
## for it instead of sending a second one, which would spend the rotated token.

## The provider refused refresh_token: the person must sign in again.
signal ended(refresh_token: String)
## A refresh finished (internal: concurrent callers wait on it).
signal refresh_finished

const Errors := preload("res://addons/scenario/core/errors.gd")
const OAuth := preload("res://addons/scenario/core/oauth.gd")

## Refresh when the access token has less than this left.
const MIN_TOKEN_S := 60.0

var oauth: OAuth
## {"access_token", "refresh_token", "expires_at"}; expires_at 0 means unknown.
var tokens := {}
var team_id := ""
var team_name := ""
var project_id := ""
var project_name := ""
## Called with the new refresh token after a rotation: (refresh_token: String) -> void
var on_rotate := Callable()
var _refreshing := false
var _last_refresh := {}


func _init(p_oauth: OAuth, p_tokens: Dictionary) -> void:
	oauth = p_oauth
	tokens = p_tokens.duplicate()


## ok("Bearer ...") with at least min_seconds of validity left, refreshing first if needed.
func authorization(min_seconds: float = MIN_TOKEN_S) -> Dictionary:
	if str(tokens.get("access_token", "")).is_empty() or expires_in() < min_seconds:
		var refreshed: Dictionary = await refresh()
		if not refreshed["ok"]:
			return refreshed
	return Errors.ok("Bearer " + str(tokens["access_token"]))


func expires_in() -> float:
	var at := float(tokens.get("expires_at", 0.0))
	return INF if at <= 0.0 else at - Time.get_unix_time_from_system()


func refresh() -> Dictionary:
	if _refreshing:
		await refresh_finished
		return _last_refresh
	if refresh_token().is_empty():
		return Errors.fail(Errors.AUTH, "Your Scenario session ended. Sign in again.", {"session_ended": true})
	_refreshing = true
	var sent := refresh_token()
	var result: Dictionary = await oauth.refresh(sent)
	if result["ok"]:
		var rotated := str(result["value"]["refresh_token"]) != refresh_token()
		tokens = result["value"]
		if rotated and on_rotate.is_valid():
			on_rotate.call(refresh_token())
	elif result["error"].get("session_ended", false):
		tokens = {}
	_last_refresh = result
	_refreshing = false
	refresh_finished.emit()
	if not result["ok"] and result["error"].get("session_ended", false):
		ended.emit(sent)
	return result


func refresh_token() -> String:
	return str(tokens.get("refresh_token", ""))


func has_project() -> bool:
	return not project_id.is_empty()


## The ids every tool call carries, so it lands in the chosen project.
func workspace() -> Dictionary:
	if not has_project():
		return {}
	return {"team_id": team_id, "project_id": project_id}


func set_workspace(team: Dictionary, project: Dictionary) -> void:
	team_id = str(team.get("id", ""))
	team_name = str(team.get("name", team_id))
	project_id = str(project.get("id", ""))
	project_name = str(project.get("name", project_id))
	if project_id.is_empty():
		team_id = ""
		team_name = ""


func workspace_label() -> String:
	return "%s / %s" % [team_name, project_name] if has_project() else ""
