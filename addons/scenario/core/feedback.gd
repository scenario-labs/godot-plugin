@tool
extends RefCounted
## Feedback from the dock: a 1 to 5 rating, a message and an optional reply
## address. Nothing is sent until the person presses Send, whether or not usage
## data is shared. The request shape is a contract with
## tools/site_proxy/middleware.ts.

const Usage := preload("res://addons/scenario/core/usage.gd")

const MAX_MESSAGE := 4000
const MAX_EMAIL := 254

## Kept until a send succeeds, so trying again is the same submission.
var submission_id := ""


## What is wrong with the form, or "".
static func problem(rating: int, message: String, email: String) -> String:
	if rating < 1 or rating > 5:
		return "Choose a rating from 1 to 5."
	if message.length() > MAX_MESSAGE:
		return "Shorten the message to %d characters." % MAX_MESSAGE
	email = email.strip_edges()
	if not email.is_empty() and (email.length() > MAX_EMAIL or not _looks_like_email(email)):
		return "Check the email address, or leave it empty."
	return ""


## install_id: the usage install ID while sharing is on, else "" (left out).
func payload(rating: int, message: String, email: String, install_id: String = "") -> Dictionary:
	if submission_id.is_empty():
		submission_id = Usage.new_id()
	var body := {"submission_id": submission_id, "context": Usage.context(), "rating": rating, "message": message.strip_edges()}
	if not email.strip_edges().is_empty():
		body["email"] = email.strip_edges()
	if not install_id.is_empty():
		body["install_id"] = install_id
	return body


## The next feedback is a new submission.
func sent() -> void:
	submission_id = ""


static func _looks_like_email(email: String) -> bool:
	var at := email.find("@")
	if at < 1 or at != email.rfind("@") or email.contains(" "):
		return false
	var domain := email.substr(at + 1)
	var dot := domain.rfind(".")
	return dot > 0 and domain.length() - dot > 2
