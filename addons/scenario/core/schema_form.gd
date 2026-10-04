@tool
extends RefCounted
## Turns a model schema (model_schema_get's normalised "parameters" array) into
## form fields, validates values, and builds the model_run payload.
##
## Field types: prompt, text, enum, number, integer, boolean, multi (a list
## of allowed values), file (one asset id), files (a list of asset ids).

const _INTEGER_HINTS := ["seed", "num", "count", "steps", "face"]


static func fields_from_schema(schema: Dictionary, restrict: Dictionary = {}) -> Array:
	var fields: Array = []
	var parameters: Variant = schema.get("parameters", [])
	if not parameters is Array:
		return fields
	for parameter in parameters:
		if not parameter is Dictionary or not parameter.has("name"):
			continue
		var field := _field(parameter)
		if restrict.has(field["name"]) and field["type"] in ["enum", "multi"]:
			var allowed: Array = restrict[field["name"]]
			field["options"] = field["options"].filter(func(o: Variant) -> bool: return o in allowed)
			if not field["default"] in field["options"] and not field["options"].is_empty() and field["type"] == "enum":
				field["default"] = field["options"][0]
		fields.append(field)
	# The prompt goes first, then required fields, then the rest in schema order.
	var ordered: Array = []
	for pass_index in 3:
		for field in fields:
			var rank := 0 if field["type"] == "prompt" else (1 if field["required"] else 2)
			if rank == pass_index:
				ordered.append(field)
	return ordered


static func _field(p: Dictionary) -> Dictionary:
	var name := str(p["name"])
	var raw_type := str(p.get("type", "string"))
	var options: Array = p.get("allowed_values", []) if p.get("allowed_values") is Array else []
	var field := {
		"name": name,
		"label": humanize(name),
		"description": str(p.get("description", "")),
		"required": bool(p.get("required", false)),
		"default": p.get("default"),
		"min": p.get("min"),
		"max": p.get("max"),
		"step": p.get("step"),
		"options": options,
		"kind": str(p.get("kind", "")),
		"max_items": int(p.get("max_length", 0)) if raw_type.ends_with("array") else 0,
		"max_length": int(p.get("max_length", 0)) if raw_type == "string" else 0,
		"cost_impact": bool(p.get("cost_impact", false)),
		"type": "text",
	}
	match raw_type:
		"string":
			if bool(p.get("prompt", false)) or name == "prompt":
				field["type"] = "prompt"
			elif not options.is_empty():
				field["type"] = "enum"
		"number", "integer":
			if not options.is_empty():
				field["type"] = "enum"
			elif raw_type == "integer" or _looks_integer(name, p):
				field["type"] = "integer"
			else:
				field["type"] = "number"
		"boolean":
			field["type"] = "boolean"
		"string_array":
			field["type"] = "multi"
		"file":
			field["type"] = "file"
		"file_array":
			field["type"] = "files"
		_:
			field["type"] = "text"
	return field


static func _looks_integer(name: String, p: Dictionary) -> bool:
	var step: Variant = p.get("step")
	if step != null:
		return float(step) == floorf(float(step)) and float(step) >= 1.0
	var lower := name.to_lower()
	for hint in _INTEGER_HINTS:
		if lower.contains(hint):
			return true
	return false


## camelCase or snake_case to "Sentence case".
static func humanize(name: String) -> String:
	var words: PackedStringArray = []
	var current := ""
	for i in name.length():
		var c := name[i]
		if c == "_" or c == "-":
			if not current.is_empty():
				words.append(current)
			current = ""
		elif c == c.to_upper() and c != c.to_lower() and not current.is_empty() \
				and current[current.length() - 1] == current[current.length() - 1].to_lower():
			words.append(current)
			current = c
		else:
			current += c
	if not current.is_empty():
		words.append(current)
	var text := " ".join(words).to_lower()
	return text.substr(0, 1).to_upper() + text.substr(1) if not text.is_empty() else name


## Starting values: schema defaults, then lane presets on top.
static func initial_values(fields: Array, presets: Dictionary = {}) -> Dictionary:
	var values := {}
	for field in fields:
		var name: String = field["name"]
		if presets.has(name):
			values[name] = presets[name]
		elif field["default"] != null:
			values[name] = field["default"]
	return values


## Problems that block a price check, as short sentences. Empty means valid.
static func validate(fields: Array, values: Dictionary) -> PackedStringArray:
	var problems: PackedStringArray = []
	for field in fields:
		var value: Variant = values.get(field["name"])
		if field["required"] and _is_empty(value):
			problems.append("%s is required." % field["label"])
			continue
		if _is_empty(value):
			continue
		match field["type"]:
			"number", "integer":
				if not (value is int or value is float):
					problems.append("%s must be a number." % field["label"])
				elif field["min"] != null and float(value) < float(field["min"]):
					problems.append("%s must be at least %s." % [field["label"], number_text(field["min"])])
				elif field["max"] != null and float(value) > float(field["max"]):
					problems.append("%s must be at most %s." % [field["label"], number_text(field["max"])])
			"enum":
				if not field["options"].is_empty() and not _in_options(value, field["options"]):
					problems.append("%s has an unsupported value." % field["label"])
			"prompt", "text":
				if field["max_length"] > 0 and str(value).length() > field["max_length"]:
					problems.append("%s is longer than %d characters." % [field["label"], field["max_length"]])
			"files", "multi":
				if field["max_items"] > 0 and value is Array and value.size() > field["max_items"]:
					problems.append("%s takes at most %d items." % [field["label"], field["max_items"]])
	return problems


## The model_run "parameters": known fields only, empty values dropped,
## integers sent as ints and lists as arrays.
static func payload(fields: Array, values: Dictionary) -> Dictionary:
	var out := {}
	for field in fields:
		var name: String = field["name"]
		if not values.has(name) or _is_empty(values[name]):
			continue
		var value: Variant = values[name]
		match field["type"]:
			"integer":
				out[name] = int(value)
			"number":
				out[name] = float(value)
			"boolean":
				out[name] = bool(value)
			"files", "multi":
				out[name] = Array(value) if value is Array or value is PackedStringArray else [value]
			"prompt", "text":
				out[name] = str(value).strip_edges()
			_:
				out[name] = value
	return out


## 2048.0 as "2048", 0.6 as "0.6".
static func number_text(value: Variant) -> String:
	var number := float(value)
	return str(int(number)) if number == floorf(number) and absf(number) < 9.0e15 else str(number)


static func _is_empty(value: Variant) -> bool:
	if value == null:
		return true
	if value is String:
		return value.strip_edges().is_empty()
	if value is Array or value is PackedStringArray or value is Dictionary:
		return value.is_empty()
	return false


static func _in_options(value: Variant, options: Array) -> bool:
	for option in options:
		if typeof(option) == typeof(value) and option == value:
			return true
		if (option is int or option is float) and (value is int or value is float) and float(option) == float(value):
			return true
	return false
