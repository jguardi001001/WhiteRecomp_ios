package iv_i18n

import "core:testing"

@(private = "file")
sample :: proc() -> Catalog {
	c: Catalog
	init(&c, "en")
	add_language(&c, "ja", "日本語", ruby = true)
	add_language(&c, "de", "Deutsch")
	set(&c, "en", "play", "Play")
	set(&c, "en", "quit", "Quit")
	set(&c, "en", "count", "You have {n} {n|item|items}")
	set(&c, "de", "play", "Spielen")
	set(&c, "ja", "play", "遊{{あそ}}ぶ")
	return c
}

@(test)
falls_back_to_the_default_then_to_the_key :: proc(t: ^testing.T) {
	c := sample()
	defer destroy(&c)
	testing.expect_value(t, get(&c, "play"), "Play")
	testing.expect(t, set_language(&c, "de"))
	testing.expect_value(t, get(&c, "play"), "Spielen")
	testing.expect_value(t, get(&c, "quit"), "Quit") // not translated: the default's
	testing.expect_value(t, get(&c, "nothing.here"), "nothing.here") // nobody has it: its name
	testing.expect(t, !set_language(&c, "xx"))
	testing.expect_value(t, current_code(&c), "de")
	testing.expect(t, has(&c, "quit") && !has(&c, "nothing.here"))
}

@(test)
readings_can_be_shown_or_hidden :: proc(t: ^testing.T) {
	c := sample()
	defer destroy(&c)
	set_language(&c, "ja")
	testing.expect(t, ruby_active(&c))
	testing.expect_value(t, get(&c, "play"), "遊{{あそ}}ぶ")
	set_show_ruby(&c, false)
	testing.expect(t, !ruby_active(&c))
	testing.expect_value(t, get(&c, "play"), "遊ぶ")
	testing.expect_value(t, get(&c, "play"), "遊ぶ") // (the second time from the cache)
	set(&c, "ja", "play", "始{{はじ}}める")
	testing.expect_value(t, get(&c, "play"), "始める") // a changed text is not stale
	set_language(&c, "en")
	set_show_ruby(&c, true)
	testing.expect_value(t, get(&c, "play"), "Play")
}

@(test)
placeholders_and_plurals :: proc(t: ^testing.T) {
	c := sample()
	defer destroy(&c)
	testing.expect_value(t, format(&c, "count", Arg{"n", 1}), "You have 1 item")
	testing.expect_value(t, format(&c, "count", Arg{"n", 5}), "You have 5 items")
	testing.expect_value(t, format(&c, "count", Arg{"n", 0}), "You have 0 items")
	testing.expect_value(t, format_text("{a}-{b} {c}", Arg{"a", "x"}, Arg{"b", 2.5}), "x-2.5 {c}") // an unknown name stays
	testing.expect_value(t, format_text("{n|none|one|many}", Arg{"n", 0}), "none")
	testing.expect_value(t, format_text("{n|none|one|many}", Arg{"n", 1}), "one")
	testing.expect_value(t, format_text("{n|none|one|many}", Arg{"n", 9}), "many")
	testing.expect_value(t, format_text("漢{{かん}}字 {n}", Arg{"n", 3}), "漢{{かん}}字 3") // readings are not placeholders
}

@(test)
edit_rename_remove_and_coverage :: proc(t: ^testing.T) {
	c := sample()
	defer destroy(&c)
	testing.expect_value(t, len(missing(&c, "de")), 2) // count, quit
	testing.expect_value(t, missing(&c, "de")[0], "count")
	testing.expect(t, coverage(&c, "de") > 0.3 && coverage(&c, "de") < 0.4)
	testing.expect_value(t, coverage(&c, "en"), 1)

	rename(&c, "play", "menu.play")
	testing.expect(t, !has(&c, "play") && has(&c, "menu.play"))
	d, ok := get_in(&c, "de", "menu.play")
	testing.expect(t, ok)
	testing.expect_value(t, d, "Spielen")
	set_all(&c, "menu.play", "X")
	testing.expect_value(t, get_or_default(&c, "ja", "menu.play"), "X")
	remove(&c, "menu.play")
	testing.expect_value(t, get(&c, "menu.play"), "menu.play")
	keys := keys_like(&c, "c", "t")
	testing.expect_value(t, len(keys), 1)
	testing.expect_value(t, keys[0], "count")
}

@(test)
strings_file_round_trip :: proc(t: ^testing.T) {
	c := sample()
	defer destroy(&c)
	set(&c, "en", "multi", "two lines and \\slash \\n")
	text := save_text(&c)
	defer delete(text)

	c2: Catalog
	init(&c2, "en")
	defer destroy(&c2)
	n := load_text(&c2, text)
	testing.expect_value(t, n, 6)
	testing.expect_value(t, len(c2.languages), 3) // ja and de were found in the file
	testing.expect_value(t, get_or_default(&c2, "en", "multi"), "two lines and \\slash \\n")
	set_language(&c2, "ja")
	testing.expect_value(t, get(&c2, "play"), "遊{{あそ}}ぶ")
	text2 := save_text(&c2)
	defer delete(text2)
	testing.expect_value(t, len(text2), len(text)) // the same file back (ordering by key and language order may differ only in language order)
}
