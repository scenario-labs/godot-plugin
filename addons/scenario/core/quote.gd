@tool
extends RefCounted
## Single-use price quotes bound to the exact request.
##
## Generate is allowed only with a quote whose fingerprint (model, scope and
## canonical parameters) matches the form now. Generating consumes it; any
## edit produces a different fingerprint, so a stale price is never charged.

const MAX_AGE_S := 600.0

var _quotes := {}


## Canonical JSON: keys sorted at every level, whole floats written as ints.
static func canonical(value: Variant) -> String:
	return JSON.stringify(normalize(value), "", true)


static func normalize(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		var ordered := {}
		for key in keys:
			ordered[str(key)] = normalize(value[key])
		return ordered
	if value is Array:
		var items: Array = []
		for item in value:
			items.append(normalize(item))
		return items
	if value is PackedStringArray:
		return normalize(Array(value))
	if value is float and is_finite(value) and absf(value) < 9.0e15 and value == floorf(value):
		return int(value)
	return value


static func fingerprint(model_id: String, parameters: Dictionary, scope: String = "") -> String:
	return ("%s\n%s\n%s" % [model_id, scope, canonical(parameters)]).sha256_text()


func store(fp: String, cu: float, discount: float, now: float) -> void:
	_quotes[fp] = {"fingerprint": fp, "cu": cu, "discount": discount, "at": now}


## The quote for this fingerprint if it is fresh, else {}.
func usable(fp: String, now: float) -> Dictionary:
	var quote: Dictionary = _quotes.get(fp, {})
	if quote.is_empty() or now - float(quote["at"]) > MAX_AGE_S:
		return {}
	return quote


## Takes the quote out (single use). {} when there is none to take.
func consume(fp: String, now: float) -> Dictionary:
	var quote := usable(fp, now)
	_quotes.erase(fp)
	return quote


func clear() -> void:
	_quotes.clear()
