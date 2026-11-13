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
## What the submission is tied to: "email", "install" or "". A retry that changes
## it is a new submission, so an address and the install ID never share one.
var _carries := ""


## What is wrong with the form, or "".
static func problem(rating: int, message: String, email: String) -> String:
	if rating < 1 or rating > 5:
		return "Choose a rating from 1 to 5."
	# Counted in UTF-16 units, as the relay counts them.
	if message.strip_edges().to_utf16_buffer().size() / 2 > MAX_MESSAGE:
		return "Shorten the message to %d characters." % MAX_MESSAGE
	email = email.strip_edges()
	if not email.is_empty() and (email.to_utf16_buffer().size() / 2 > MAX_EMAIL or not _looks_like_email(email)):
		return "Check the email address, or leave it empty."
	return ""


## install_id: the usage install ID while sharing is on, else "" (left out). It is
## also left out when an email is given, so no address is ever tied to usage data.
func payload(rating: int, message: String, email: String, install_id: String = "") -> Dictionary:
	var carries := "email" if not email.strip_edges().is_empty() else ("install" if not install_id.is_empty() else "")
	if submission_id.is_empty() or carries != _carries:
		submission_id = Usage.new_id()
		_carries = carries
	var body := {"submission_id": submission_id, "context": Usage.context(), "rating": rating, "message": message.strip_edges()}
	if carries == "email":
		body["email"] = email.strip_edges()
	elif carries == "install":
		body["install_id"] = install_id
	return body


## The next feedback is a new submission.
func sent() -> void:
	submission_id = ""


## The relay's pattern (tools/site_proxy/middleware.ts EMAIL).
static func _looks_like_email(email: String) -> bool:
	var pattern := RegEx.create_from_string("^[^\\s@]{1,64}@[^\\s@]{1,190}\\.[^\\s@]{2,}$")
	return pattern.search(email) != null
