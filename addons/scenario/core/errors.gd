@tool
extends RefCounted
## Error kinds and result helpers shared by the Scenario core.
##
## Every core call returns a Dictionary: {"ok": true, "value": ...} or
## {"ok": false, "error": {"kind", "message", "ambiguous", ...}}. GDScript has
## no exceptions, so callers branch on "ok".

const AUTH := "auth"
const FORBIDDEN := "forbidden"
const QUOTA := "quota"
const MODERATED := "moderated"
const RATE_LIMIT := "rate_limit"
const NOT_FOUND := "not_found"
const INVALID := "invalid"
const TRANSPORT := "transport"
const TIMEOUT := "timeout"
const HTTP_5XX := "http_5xx"
const PROTOCOL := "protocol"
const LOCAL := "local"
const ESTIMATE_JOB := "estimate_job"
const SCENARIO := "scenario"

## Failures where Scenario may still have received and run the request.
const AMBIGUOUS_KINDS := [TRANSPORT, TIMEOUT, HTTP_5XX, PROTOCOL]
## Failures worth retrying, for allow-listed reads only.
const RETRYABLE_KINDS := [RATE_LIMIT, TRANSPORT, TIMEOUT, HTTP_5XX]

const _MODERATION_WORDS := ["moderat", "nsfw", "sensitive content", "content policy", "flagged", "safety system"]
const _QUOTA_WORDS := ["insufficient", "not enough credit", "not enough creative", "out of credit", "quota"]
const _AUTH_WORDS := ["unauthorized", "unauthenticated", "invalid api key", "invalid credentials", "authentication"]

const _MESSAGES := {
	AUTH: "Scenario rejected the API key. Check the key and secret in the Scenario dock settings.",
	FORBIDDEN: "This API key is not allowed to do that. Check the key's role in Scenario.",
	QUOTA: "Not enough Creative Units for this run.",
	MODERATED: "Blocked by Scenario's content moderation. Change the prompt or the reference.",
	RATE_LIMIT: "Scenario is limiting requests right now. Try again in a moment.",
	NOT_FOUND: "Scenario could not find that item.",
	INVALID: "Scenario refused the parameters.",
	TRANSPORT: "Could not reach Scenario. Check the connection and try again.",
	TIMEOUT: "Scenario took too long to answer.",
	HTTP_5XX: "Scenario had a server error. Try again in a moment.",
	PROTOCOL: "Scenario returned a response the plugin could not read.",
}
## The same, for a person signed in with their Scenario account.
const _SIGNED_IN_MESSAGES := {
	AUTH: "Scenario refused the sign-in. Sign in again from the Scenario dock.",
	FORBIDDEN: "Your Scenario account is not allowed to do that in this project. Check your role, or pick another project.",
}


static func ok(value: Variant = null) -> Dictionary:
	return {"ok": true, "value": value}


static func fail(kind: String, message: String, extra: Dictionary = {}) -> Dictionary:
	var error := {"kind": kind, "message": message, "ambiguous": false}
	error.merge(extra, true)
	return {"ok": false, "error": error}


static func is_moderated(text: String) -> bool:
	var lower := text.to_lower()
	for word in _MODERATION_WORDS:
		if lower.contains(word):
			return true
	return false


## Kind of a failure from the server's detail text and HTTP status (0 when the
## error came inside a 200 JSON-RPC reply).
static func classify(detail: String, status: int = 0) -> String:
	var lower := detail.to_lower()
	if is_moderated(lower):
		return MODERATED
	match status:
		401:
			return AUTH
		402:
			return QUOTA
		403:
			return FORBIDDEN
		404:
			return NOT_FOUND
		429:
			return RATE_LIMIT
	if status >= 500:
		return HTTP_5XX
	if _has_any(lower, _QUOTA_WORDS):
		return QUOTA
	if status == 400 or status == 422:
		return INVALID
	if _has_any(lower, _AUTH_WORDS):
		return AUTH
	if lower.contains("rate limit") or lower.contains("too many requests"):
		return RATE_LIMIT
	if lower.contains("forbidden") or lower.contains("not allowed"):
		return FORBIDDEN
	return SCENARIO


## A tool error's text as the hosted MCP writes it: a banner with the trace id,
## then "Error: <status> <body>", the body often {"reason": ...}.
## {"detail": the reason, "status": HTTP status or 0, "trace_id": "mcpt_..." or ""}
static func tool_error(text: String) -> Dictionary:
	var trace := RegEx.create_from_string("trace_id: (mcpt_[A-Za-z0-9]+)").search(text)
	var out := {"detail": text.strip_edges(), "status": 0, "trace_id": trace.get_string(1) if trace != null else ""}
	var line := RegEx.create_from_string("(?m)^Error: (?:(\\d{3}) )?(.*)$").search(text)
	if line == null:
		return out
	out["status"] = int(line.get_string(1)) if not line.get_string(1).is_empty() else 0
	out["detail"] = line.get_string(2).strip_edges()
	var json := JSON.new()
	if json.parse(out["detail"]) == OK and json.data is Dictionary:
		for key in ["reason", "message", "error"]:
			if json.data.get(key) is String and not str(json.data[key]).is_empty():
				out["detail"] = json.data[key]
				break
	return out


## User-facing message: the plain explanation, plus the server's detail when it adds something.
## signed_in: the person signed in with their account rather than an API key.
static func message_for(kind: String, detail: String = "", signed_in: bool = false) -> String:
	var base: String = _SIGNED_IN_MESSAGES.get(kind, "") if signed_in else ""
	if base.is_empty():
		base = _MESSAGES.get(kind, "Scenario reported an error.")
	var clean := detail.strip_edges()
	if clean.is_empty() or kind in [TRANSPORT, TIMEOUT]:
		return base
	if clean.length() > 300:
		clean = clean.substr(0, 300) + "..."
	return "%s (%s)" % [base, clean]


static func _has_any(text: String, words: Array) -> bool:
	for word in words:
		if text.contains(word):
			return true
	return false
