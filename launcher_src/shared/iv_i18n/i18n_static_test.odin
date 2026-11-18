package iv_i18n

import "core:fmt"
import "core:strings"
import "core:testing"

// A static load keeps views into the text: no key and no text is copied. Texts are raw (a backslash is a backslash).
@(test)
static_load_points_into_the_text :: proc(t: ^testing.T) {
	text := "# a note\n@languages en de\nplay\n\tPlay\n\tSpielen\nmulti\n\ttwo\\nlines\n"
	c: Catalog
	init(&c, "en")
	defer destroy(&c)
	testing.expect_value(t, load_text_static(&c, text), 3)

	play := get(&c, "play")
	testing.expect_value(t, play, "Play")
	base := uintptr(raw_data(text))
	at := uintptr(raw_data(play))
	testing.expect(t, at >= base && at < base + uintptr(len(text))) // a view into `text`, not a copy

	testing.expect_value(t, get(&c, "multi"), "two\\nlines") // no escape codes: the backslash and the n stay as written
	at = uintptr(raw_data(get(&c, "multi")))
	testing.expect(t, at >= base && at < base + uintptr(len(text)))

	// editing a catalog that holds views: replace, remove, add and bring a removed key back (the views are never freed)
	set(&c, "en", "play", "Start")
	testing.expect_value(t, get(&c, "play"), "Start")
	set(&c, "en", "play", "Go")
	testing.expect_value(t, get(&c, "play"), "Go")
	remove(&c, "play")
	testing.expect_value(t, get(&c, "play"), "play")
	testing.expect(t, !has(&c, "play"))
	set(&c, "en", "play", "Again")
	testing.expect_value(t, get(&c, "play"), "Again")
	set_language(&c, "de")
	testing.expect_value(t, get(&c, "play"), "Spielen")
	remove(&c, "multi")
	testing.expect_value(t, get(&c, "multi"), "multi")
}

// The file's running state: @languages names the columns, a key line starts a key, and each text line below it is the next column's. A text keeps its
// tabs, "-" skips a column, a lone tab is an empty text, a key stated again adds to and replaces in the same key, and what comes before a key or
// before @languages is ignored.
@(test)
running_state_sets_the_columns_and_the_key :: proc(t: ^testing.T) {
	text := "\torphan text\n# note\n@languages en de es\n\nmenu.a\n\tA\n-\n\tA!\nmenu.b\n\tB\tx\nmenu.c\n\t\n\tC-de\nmenu.a\n\tA2\n@languages es en\nmenu.d\n\tD-es\n\tD-en\n"
	c: Catalog
	init(&c, "en")
	defer destroy(&c)
	testing.expect_value(t, load_text_static(&c, text), 8)
	testing.expect_value(t, get_or_default(&c, "en", "menu.a"), "A2") // the later line replaced it
	testing.expect_value(t, get_or_default(&c, "es", "menu.a"), "A!")
	_, has_de := get_in(&c, "de", "menu.a") // the "-": no German text
	testing.expect(t, !has_de)
	testing.expect_value(t, get(&c, "menu.b"), "B\tx") // the text is all after the first tab
	e, has_e := get_in(&c, "en", "menu.c") // a lone tab is an empty text, and that is a text
	testing.expect(t, has_e)
	testing.expect_value(t, e, "")
	testing.expect_value(t, get_or_default(&c, "de", "menu.c"), "C-de")
	testing.expect_value(t, get_or_default(&c, "es", "menu.d"), "D-es") // the columns were changed
	testing.expect_value(t, get_or_default(&c, "en", "menu.d"), "D-en")
	testing.expect(t, !has(&c, "orphan text"))

	// save and load again: the languages once at the top, each key once, the trailing missing ones left out
	out := save_text(&c)
	defer delete(out)
	testing.expect_value(t, strings.count(out, "menu.a\n"), 1)
	testing.expect(t, strings.contains(out, "@languages en de es\n"))
	testing.expect(t, strings.contains(out, "menu.b\n\tB\tx\nmenu.c\n")) // (b is English only)
	testing.expect(t, strings.contains(out, "menu.a\n\tA2\n-\n\tA!\n"))
	c2: Catalog
	init(&c2, "en")
	defer destroy(&c2)
	testing.expect_value(t, load_text(&c2, out), 7) // (the text that was replaced is not there twice)
	testing.expect_value(t, get_or_default(&c2, "es", "menu.a"), "A!")
	testing.expect_value(t, get_or_default(&c2, "en", "menu.b"), "B\tx")
	e2, has_e2 := get_in(&c2, "en", "menu.c")
	testing.expect(t, has_e2 && e2 == "")
}

// A key index that grows (it is rebuilt more than once) keeps every key reachable.
@(test)
many_strings_stay_reachable :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	N :: 3000
	strings.write_string(&b, "@languages en de\n")
	for i in 0 ..< N {
		fmt.sbprintf(&b, "key.%d.name\n\tText %d\n", i, i)
		if i % 3 == 0 {
			fmt.sbprintf(&b, "\tTeXt %d\n", i)
		}
	}
	text := strings.to_string(b)

	c: Catalog
	init(&c, "en")
	defer destroy(&c)
	testing.expect_value(t, load_text_static(&c, text), N + N / 3)
	for i in 0 ..< N {
		testing.expect_value(t, get(&c, fmt.tprintf("key.%d.name", i)), fmt.tprintf("Text %d", i))
	}
	testing.expect_value(t, get(&c, "key.N.name"), "key.N.name")
	testing.expect_value(t, len(keys_like(&c, "key.1", ".name")), 1111)
	testing.expect_value(t, c.texts[0].live, N)
	testing.expect_value(t, len(missing(&c, "de")), N - N / 3)

	set_language(&c, "de")
	testing.expect_value(t, get(&c, "key.3.name"), "TeXt 3")
	testing.expect_value(t, get(&c, "key.4.name"), "Text 4") // not translated: English

	// the same text copied: the same strings, and the text may go
	c2: Catalog
	init(&c2, "en")
	defer destroy(&c2)
	testing.expect_value(t, load_text(&c2, strings.clone(text, context.temp_allocator)), N + N / 3)
	testing.expect_value(t, get(&c2, "key.2999.name"), "Text 2999")
}
