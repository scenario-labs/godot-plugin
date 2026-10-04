extends GutTest

const Quote := preload("res://addons/scenario/core/quote.gd")


func test_canonical_sorts_keys_at_every_level() -> void:
	var a := Quote.canonical({"b": 1, "a": {"y": 2, "x": [3, {"q": 1, "p": 2}]}})
	var b := Quote.canonical({"a": {"x": [3, {"p": 2, "q": 1}], "y": 2}, "b": 1})
	assert_eq(a, b)
	assert_eq(a, "{\"a\":{\"x\":[3,{\"p\":2,\"q\":1}],\"y\":2},\"b\":1}")


func test_whole_floats_become_ints_but_fractions_stay() -> void:
	assert_eq(Quote.canonical({"w": 1024.0, "s": 0.6}), Quote.canonical({"w": 1024, "s": 0.6}))
	assert_ne(Quote.canonical({"s": 0.6}), Quote.canonical({"s": 0.7}))


func test_fingerprint_changes_with_model_scope_or_any_parameter() -> void:
	var base := Quote.fingerprint("m1", {"prompt": "chest", "width": 1024})
	assert_eq(base, Quote.fingerprint("m1", {"width": 1024.0, "prompt": "chest"}))
	assert_ne(base, Quote.fingerprint("m2", {"prompt": "chest", "width": 1024}))
	assert_ne(base, Quote.fingerprint("m1", {"prompt": "chest!", "width": 1024}))
	assert_ne(base, Quote.fingerprint("m1", {"prompt": "chest", "width": 1040}))
	assert_ne(base, Quote.fingerprint("m1", {"prompt": "chest", "width": 1024}, "proj_other"))
	assert_ne(base, Quote.fingerprint("m1", {"prompt": "chest", "width": 1024, "seed": 1}))


func test_quote_is_single_use() -> void:
	var book := Quote.new()
	book.store("fp", 11.0, 0.0, 100.0)
	assert_eq(book.usable("fp", 101.0)["cu"], 11.0)
	assert_eq(book.consume("fp", 101.0)["cu"], 11.0)
	assert_eq(book.consume("fp", 102.0), {})
	assert_eq(book.usable("fp", 102.0), {})


func test_quote_for_another_fingerprint_is_not_usable() -> void:
	var book := Quote.new()
	book.store("fp_a", 2.0, 0.0, 0.0)
	assert_eq(book.usable("fp_b", 1.0), {})


func test_stale_quote_expires() -> void:
	var book := Quote.new()
	book.store("fp", 2.0, 0.0, 0.0)
	assert_eq(book.usable("fp", Quote.MAX_AGE_S + 1.0), {})
	assert_eq(book.consume("fp", Quote.MAX_AGE_S + 1.0), {})
