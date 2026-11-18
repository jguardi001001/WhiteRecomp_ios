// Every string a player can read, in every language: a Catalog holds texts by key and language. No state of its own outside the Catalog a program makes.
//
//   cat: iv_i18n.Catalog
//   iv_i18n.init(&cat, "en")                        // the first language is the default: what every other one falls back to
//   iv_i18n.load_text(&cat, strings_file)           // "@languages" line, then a key on a line and its texts under it (see the file format below)
//   iv_i18n.load_text_static(&cat, #load("strings.txt", string))   // the same without copying: the catalog points into the embedded text
//   iv_i18n.set_language(&cat, "ja")
//   label := iv_i18n.get(&cat, "title.button.play")
//   msg   := iv_i18n.format(&cat, "inventory.count", {"n", 3})       // "You have {n} {n|item|items}"
//
// Keys are dotted paths ("title.button.play"). The default language has them all; another language only needs the keys it translates, `get` falls
// back to the default text for the rest (a missing key is never a crash, and a language can be translated a bit at a time), and to the key itself
// when nobody has it (so a missing string shows up on screen as its own name). `missing` and `coverage` say what a language still lacks.
//
// Languages are named by a code ("en", "pt-BR": any string, matched as written); there is no fixed list, a program (or a strings file) adds them.
//
// Furigana: a language flagged `ruby` writes its texts with readings in double braces, "漢{{かん}}字{{じ}}". With `show_ruby` on, `get` gives the text
// as it is (iv_text draws the readings small above the letters); off, the braces and what is in them are taken out.
//
// Text format of a strings file (iv_datafile's lines). The file keeps a running state, so that nothing is said twice: a line "@languages en de es" says
// which languages the columns are, a line with a key says which key the lines below it are for, and each of those is one line of text, the first
// for the first language, the next for the next, and so on until the next key. A text line starts with a tab (the text is all after it, tabs and all):
//
//   @languages en de es
//   title.button.play
//   	Play
//   	Spielen
//   	Jugar
//   title.button.quit
//   	Quit
//   -
//   	Salir
//   title.button.back
//   	Back
//
// A line that is only "-" is a language with no text for this key (`get` falls back to the default); the languages after the last text are left out
// (here "back" is English only). An empty text is a line with only the tab. Lines that start with # are notes, and so are empty ones. Texts are raw,
// there are no escape codes: a text may not hold a line break. A key may not start with @ or # and cannot be "-". A new "@languages" line changes the
// columns for the keys below it. load_text reads it; save_text writes it (keys sorted, the languages in the catalog's order).
package iv_i18n

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import data "../iv_datafile"

Language :: struct {
	code: string, // "en"
	name: string, // for a menu ("English", "日本語"); the code if none was given
	ruby: bool, // its texts carry readings in {{ }}
}

Catalog :: struct {
	languages:  [dynamic]Language,
	keys:       [dynamic]Key, // every key any language has, in the order they came: the position of a key is its number
	slots:      []u32, // the index of the keys: 0 is empty, else the number of a key plus one; a power of two long, at most half full
	texts:      [dynamic]Texts, // one per language, same order
	current:    int, // the language `get` reads
	show_ruby:  bool, // readings are shown (only for languages that have `ruby`)
	stripped:   map[string]string, // the texts of the current language with the readings taken out (made when first asked for)
	allocator:  runtime.Allocator,
}

// A new catalog whose default language is `default_code`.
init :: proc(c: ^Catalog, default_code := "en", allocator := context.allocator) {
	c.allocator = allocator
	c.languages = make([dynamic]Language, allocator)
	c.keys = make([dynamic]Key, allocator)
	c.texts = make([dynamic]Texts, allocator)
	c.stripped = make(map[string]string, allocator)
	c.show_ruby = true
	add_language(c, default_code)
}

destroy :: proc(c: ^Catalog) {
	for &t in c.texts {
		for x in t.list {
			if x.owned {
				delete(x.text, c.allocator)
			}
		}
		delete(t.list)
	}
	delete(c.texts)
	for k in c.keys {
		if k.owned {
			delete(k.key, c.allocator)
		}
	}
	delete(c.keys)
	delete(c.slots, c.allocator)
	for l in c.languages {
		delete(l.code, c.allocator)
		delete(l.name, c.allocator)
	}
	delete(c.languages)
	clear_stripped(c)
	delete(c.stripped)
	c^ = {}
}

// ---- keys and texts -----------------------------------------------------------------------------------------------------------------
//
// Every key is kept once, in one list with one index (a flat array of slots: open addressing, linear probing, holding the number of a key), whatever
// the number of languages. A language is just a list of texts with the number of a key as the position in it, so reading a string of a file is storing
// at a position: no hashing, no search and no growing index per language. A text that a language does not have is a gap in its list (or past its end).
// Nothing has to own its key or text: ones that were read from a text that outlives the catalog (load_text_static: an embedded file) are views into it
// and are never copied or freed; the ones `set` makes are copies the catalog frees when they are replaced, removed or it is destroyed. A key that
// every language has lost stays in the list (the index needs it) until the catalog is destroyed; `set` brings it back.

Key :: struct {
	key:   string,
	hash:  u32,
	owned: bool, // allocated by the catalog (the key of a text that was read from a static one is a view)
}

Text :: struct {
	text:  string,
	owned: bool,
	live:  bool, // false: the language has no text of this key
}

Texts :: struct {
	list: [dynamic]Text, // by the number of the key (may be shorter than the list of keys)
	live: int, // how many of them are texts
}

@(private)
hash_key :: proc(s: string) -> u32 { // FNV-1a
	h: u32 = 2166136261
	for i in 0 ..< len(s) {
		h = (h ~ u32(s[i])) * 16777619
	}
	return h ~ (h >> 15)
}

// The number of this key, -1 if no language ever had it.
@(private)
keys_find :: proc(c: ^Catalog, key: string, h: u32) -> int {
	if len(c.slots) == 0 {
		return -1
	}
	mask := u32(len(c.slots) - 1)
	i := h & mask
	for {
		s := c.slots[i]
		if s == 0 {
			return -1
		}
		k := &c.keys[s - 1]
		if k.hash == h && k.key == key {
			return int(s - 1)
		}
		i = (i + 1) & mask
	}
}

@(private)
find_key :: proc(c: ^Catalog, key: string) -> int {
	return keys_find(c, key, hash_key(key))
}

// The number of this key; it is added if it is new (`copy`: store a copy of the key; false: store the view as it is, it must outlive the catalog).
@(private)
keys_intern :: proc(c: ^Catalog, key: string, h: u32, copy: bool) -> int {
	if id := keys_find(c, key, h); id >= 0 {
		return id
	}
	if want := (len(c.keys) + 1) * 2; want > len(c.slots) { // the index is rebuilt from the list: the hashes are kept, nothing is hashed again
		n := max(16, len(c.slots))
		for n < want {
			n *= 2
		}
		delete(c.slots, c.allocator)
		c.slots = make([]u32, n, c.allocator)
		mask := u32(n - 1)
		for k, id in c.keys {
			i := k.hash & mask
			for c.slots[i] != 0 {
				i = (i + 1) & mask
			}
			c.slots[i] = u32(id + 1)
		}
	}
	append(&c.keys, Key{key = strings.clone(key, c.allocator) if copy else key, hash = h, owned = copy})
	mask := u32(len(c.slots) - 1)
	i := h & mask
	for c.slots[i] != 0 {
		i = (i + 1) & mask
	}
	c.slots[i] = u32(len(c.keys))
	return len(c.keys) - 1
}

// The text of a key (by its number) in a language (by its index); ok = false if it has none.
@(private)
text_get :: proc(c: ^Catalog, li, id: int) -> (text: string, ok: bool) {
	list := &c.texts[li].list
	if id < 0 || id >= len(list) {
		return "", false
	}
	x := &list[id]
	return x.text, x.live
}

// Sets the text of a key in a language. `copy`: store a copy; false: store the view as it is (it must outlive the catalog). The text it had is freed
// if it was a copy.
@(private)
text_put :: proc(c: ^Catalog, li, id: int, text: string, copy: bool) {
	t := &c.texts[li]
	for len(t.list) <= id {
		append(&t.list, Text{})
	}
	x := &t.list[id]
	fresh := strings.clone(text, c.allocator) if copy else text // (before the old one is freed: `text` may be a view into it)
	if x.owned {
		delete(x.text, c.allocator)
	}
	if !x.live {
		t.live += 1
	}
	x^ = Text {
		text  = fresh,
		owned = copy,
		live  = true,
	}
}

@(private)
text_remove :: proc(c: ^Catalog, li, id: int) {
	t := &c.texts[li]
	if id < 0 || id >= len(t.list) || !t.list[id].live {
		return
	}
	x := &t.list[id]
	if x.owned {
		delete(x.text, c.allocator)
	}
	x^ = {}
	t.live -= 1
}

@(private)
clear_stripped :: proc(c: ^Catalog) {
	for k, v in c.stripped {
		delete(k, c.allocator)
		delete(v, c.allocator)
	}
	clear(&c.stripped)
}

// ---- languages ----------------------------------------------------------------------------------------------------------------------

// Adds a language (or finds the one with this code) and returns its index. The first one added is the default.
add_language :: proc(c: ^Catalog, code: string, name := "", ruby := false) -> int {
	if i := language_index(c, code); i >= 0 {
		if name != "" {
			delete(c.languages[i].name, c.allocator)
			c.languages[i].name = strings.clone(name, c.allocator)
		}
		c.languages[i].ruby = c.languages[i].ruby || ruby
		return i
	}
	append(&c.languages, Language{code = strings.clone(code, c.allocator), name = strings.clone(name if name != "" else code, c.allocator), ruby = ruby})
	append(&c.texts, Texts{list = make([dynamic]Text, c.allocator)})
	return len(c.languages) - 1
}

// The index of the language with this code, -1 if there is none.
language_index :: proc(c: ^Catalog, code: string) -> int {
	for l, i in c.languages {
		if l.code == code {
			return i
		}
	}
	return -1
}

// The code of the language `get` reads.
current_code :: proc(c: ^Catalog) -> string {
	return c.languages[c.current].code
}

// Chooses the language of every later `get`. false (and nothing changes) if there is no language with this code.
set_language :: proc(c: ^Catalog, code: string) -> bool {
	i := language_index(c, code)
	if i < 0 {
		return false
	}
	if i != c.current {
		c.current = i
		clear_stripped(c)
	}
	return true
}

// Shows or hides the readings of the languages that have them.
set_show_ruby :: proc(c: ^Catalog, on: bool) {
	if c.show_ruby != on {
		c.show_ruby = on
		clear_stripped(c)
	}
}

// Are readings to be shown now (the current language has them and they are on)?
ruby_active :: proc(c: ^Catalog) -> bool {
	return c.show_ruby && c.languages[c.current].ruby
}

// ---- texts --------------------------------------------------------------------------------------------------------------------------

// Sets the text of `key` in one language (added if it is new). The key and the text are copied.
set :: proc(c: ^Catalog, code, key, text: string) {
	li := add_language(c, code)
	text_put(c, li, keys_intern(c, key, hash_key(key), true), text, true) // (a key that is there stays: only the text is replaced)
	if li == c.current {
		clear_stripped(c)
	}
}

// Sets the text of `key` in every language (what an edit does by default: the others show the same until someone translates).
set_all :: proc(c: ^Catalog, key, text: string) {
	for l in c.languages {
		set(c, l.code, key, text)
	}
}

// The text of `key` in exactly this language (ok = it has one).
get_in :: proc(c: ^Catalog, code, key: string) -> (string, bool) {
	i := language_index(c, code)
	if i < 0 {
		return "", false
	}
	return text_get(c, i, find_key(c, key))
}

// The text of `key` in this language, else the default language's, else "".
get_or_default :: proc(c: ^Catalog, code, key: string) -> string {
	if v, ok := get_in(c, code, key); ok {
		return v
	}
	v, _ := get_in(c, c.languages[0].code, key)
	return v
}

// The text of `key` in the current language; the default language's if it has none; the key itself if nobody has it. The result is the catalog's own
// (valid until the text is changed or removed): do not delete it.
get :: proc(c: ^Catalog, key: string) -> string {
	id := find_key(c, key)
	if id < 0 {
		return key
	}
	if v, ok := text_get(c, c.current, id); ok {
		return shown(c, key, v)
	}
	if c.current != 0 {
		if v, ok := text_get(c, 0, id); ok {
			return v
		}
	}
	return key
}

// `get` as a cstring (for C code). It lives in the temp allocator, so it is only good until the end of the frame.
get_cstring :: proc(c: ^Catalog, key: string) -> cstring {
	return strings.clone_to_cstring(get(c, key), context.temp_allocator)
}

// Is there a string of this key (in the default language)?
has :: proc(c: ^Catalog, key: string) -> bool {
	_, ok := text_get(c, 0, find_key(c, key))
	return ok
}

@(private)
shown :: proc(c: ^Catalog, key, text: string) -> string {
	if c.show_ruby || !c.languages[c.current].ruby || !strings.contains(text, "{{") {
		return text
	}
	if v, ok := c.stripped[key]; ok {
		return v
	}
	v := strip_ruby(text, c.allocator)
	c.stripped[strings.clone(key, c.allocator)] = v
	return v
}

// `text` without its readings: every "{{" up to the next "}}" is left out. A new string (the caller deletes it).
strip_ruby :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(text) {
		if text[i] == '{' && i + 1 < len(text) && text[i + 1] == '{' {
			end := strings.index(text[i:], "}}")
			if end >= 0 {
				i += end + 2
				continue
			}
		}
		strings.write_byte(&b, text[i])
		i += 1
	}
	return strings.to_string(b)
}

// Takes the key out of every language.
remove :: proc(c: ^Catalog, key: string) {
	if id := find_key(c, key); id >= 0 {
		for li in 0 ..< len(c.texts) {
			text_remove(c, li, id)
		}
	}
	clear_stripped(c)
}

// Gives every language's text of `old` to `new` and takes `old` away.
rename :: proc(c: ^Catalog, old, new: string) {
	if old == new {
		return
	}
	id := find_key(c, old)
	if id < 0 {
		return
	}
	for l, i in c.languages {
		if v, ok := text_get(c, i, id); ok {
			set(c, l.code, new, v)
		}
	}
	remove(c, old)
}

// The keys of the default language's strings that start with `prefix` and end with `suffix`, sorted (for the lists an editor offers).
keys_like :: proc(c: ^Catalog, prefix := "", suffix := "") -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for k, id in c.keys {
		if _, ok := text_get(c, 0, id); ok && strings.has_prefix(k.key, prefix) && strings.has_suffix(k.key, suffix) {
			append(&out, k.key)
		}
	}
	slice.sort(out[:])
	return out[:]
}

// Every text of every language (for a font: which characters the program shows).
all_texts :: proc(c: ^Catalog, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for t in c.texts {
		for x in t.list {
			if x.live {
				append(&out, x.text)
			}
		}
	}
	return out[:]
}

// ---- what a translation lacks --------------------------------------------------------------------------------------------------

// The keys the default language has and this one does not, sorted.
missing :: proc(c: ^Catalog, code: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	i := language_index(c, code)
	if i < 0 {
		return out[:]
	}
	for k, id in c.keys {
		if _, in_default := text_get(c, 0, id); !in_default {
			continue
		}
		if _, has_it := text_get(c, i, id); !has_it {
			append(&out, k.key)
		}
	}
	slice.sort(out[:])
	return out[:]
}

// How much of the default language's strings this one has, 0 to 1 (1 for the default language itself and for an empty catalog).
coverage :: proc(c: ^Catalog, code: string) -> f32 {
	i := language_index(c, code)
	if i < 0 {
		return 0
	}
	total := c.texts[0].live
	if total == 0 {
		return 1
	}
	have := 0
	for _, id in c.keys {
		if _, in_default := text_get(c, 0, id); !in_default {
			continue
		}
		if _, has_it := text_get(c, i, id); has_it {
			have += 1
		}
	}
	return f32(have) / f32(total)
}

// ---- texts with numbers in them ------------------------------------------------------------------------------------------------

// A value for a {name} of a text.
Arg :: struct {
	name:  string,
	value: any,
}

// The text of `key` with its placeholders filled in (the result is in the temp allocator). Placeholders:
//   {name}                   the value of the argument called `name`
//   {name|one|other}         "one" when the value is 1 (or -1), else "other" (so "{n} {n|item|items}")
//   {name|zero|one|other}    "zero" when the value is 0
//   {{ and }} are left alone (they mark readings); a "{" with no placeholder of that name stays as it is.
// A language has its own word order and its own plural forms: write the text per language, with the placeholders where that language wants them.
format :: proc(c: ^Catalog, key: string, args: ..Arg) -> string {
	return format_text(get(c, key), ..args)
}

// The same for a text that did not come from a catalog.
format_text :: proc(text: string, args: ..Arg) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		ch := text[i]
		if ch == '{' && i + 1 < len(text) && text[i + 1] == '{' { // a reading: copy it as it is
			end := strings.index(text[i:], "}}")
			if end >= 0 {
				strings.write_string(&b, text[i:i + end + 2])
				i += end + 2
				continue
			}
		}
		if ch == '{' {
			end := strings.index_byte(text[i:], '}')
			if end > 0 {
				if out, ok := placeholder(text[i + 1:i + end], args); ok {
					strings.write_string(&b, out)
					i += end + 1
					continue
				}
			}
		}
		strings.write_byte(&b, ch)
		i += 1
	}
	return strings.to_string(b)
}

@(private)
placeholder :: proc(body: string, args: []Arg) -> (out: string, ok: bool) {
	parts := strings.split(body, "|", context.temp_allocator)
	name := parts[0]
	for a in args {
		if a.name != name {
			continue
		}
		if len(parts) == 1 {
			return fmt.tprint(a.value), true
		}
		n, is_num := as_number(a.value)
		if !is_num {
			return "", false
		}
		forms := parts[1:]
		switch {
		case len(forms) >= 3 && n == 0:
			return forms[0], true
		case len(forms) >= 3:
			return forms[1] if n == 1 || n == -1 else forms[2], true
		case len(forms) == 2:
			return forms[0] if n == 1 || n == -1 else forms[1], true
		}
		return forms[0], true
	}
	return "", false
}

@(private)
as_number :: proc(v: any) -> (f64, bool) {
	switch x in v {
	case int:
		return f64(x), true
	case i8:
		return f64(x), true
	case i16:
		return f64(x), true
	case i32:
		return f64(x), true
	case i64:
		return f64(x), true
	case u8:
		return f64(x), true
	case u16:
		return f64(x), true
	case u32:
		return f64(x), true
	case u64:
		return f64(x), true
	case uint:
		return f64(x), true
	case f32:
		return f64(x), true
	case f64:
		return x, true
	}
	return 0, false
}

// ---- the strings file ----------------------------------------------------------------------------------------------------------------

// Reads the text of a strings file into the catalog (a language that is new is added). Returns how many strings it set. Every key and text is copied:
// the text may be thrown away afterwards.
load_text :: proc(c: ^Catalog, text: string) -> int {
	return load_lines(c, text, false)
}

// The same, without copying: the keys and the texts are views into `text`, which must stay alive and unchanged as long as the catalog does (an
// embedded file, `#load`, does). Nothing is copied. The catalog never frees what it does not own: `set`, `remove` and `rename` work on such a
// catalog as on any other (what they add is copied).
load_text_static :: proc(c: ^Catalog, text: string) -> int {
	return load_lines(c, text, true)
}

// The next line of `rest` that is not empty and does not start with # (a note), with its line break (\n or \r\n) taken off; `rest` is left with what
// follows it. The same as iv_datafile.next_line(&rest, false), but one pass over the bytes (the lines of a strings file are short, so looking for the
// end of a line one byte at a time is cheaper than a call to a search, and nothing is looked at twice).
@(private)
next_text_line :: #force_inline proc(rest: ^string) -> (line: string, ok: bool) {
	s := rest^
	for len(s) > 0 {
		end := strings.index_byte(s, '\n')
		line = s
		if end >= 0 {
			line = s[:end]
			s = s[end + 1:]
		} else {
			s = ""
		}
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if len(line) > 0 && line[0] != '#' {
			rest^ = s
			return line, true
		}
	}
	rest^ = ""
	return "", false
}

@(private)
load_lines :: proc(c: ^Catalog, text: string, keep: bool) -> int {
	n := 0
	rest := text
	// The running state: the languages of the columns (the catalog's index of each, from the last @languages line), the key stated last, and
	// which column the next text line of that key is for.
	cols := make([dynamic]int, context.temp_allocator)
	key: string
	id := -1 // the number of the key: found when its first text comes (a key with no text is not added)
	col := 0
	for line in next_text_line(&rest) { // (never an empty line)
		switch {
		case line[0] == '\t': // the text of the key in the language of the next column
			if col < len(cols) && len(key) > 0 {
				if id < 0 {
					id = keys_intern(c, key, hash_key(key), !keep)
				}
				text_put(c, cols[col], id, line[1:], !keep)
				n += 1
			}
			col += 1
		case strings.trim_space(line) == "-": // no text in the language of the next column
			col += 1
		case line[0] == '@': // a line that sets the state
			words := line
			if word, _ := data.next_word(&words); word == "@languages" {
				clear(&cols)
				for code in data.next_word(&words) {
					append(&cols, add_language(c, code))
				}
				key = ""
				id = -1
				col = 0
			}
		case: // a key
			key = strings.trim_space(line)
			id = -1
			col = 0
		}
	}
	clear_stripped(c)
	return n
}

// The strings file: every key, in every language that has it, sorted by key. A new string (the caller deletes it).
save_text :: proc(c: ^Catalog, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# Every string, in every language (the first one has them all; a missing one falls back to it). @languages gives the order of the columns; a key on a line is followed by its texts, one line for each language in that order, each starting with a tab ('-' alone: none in that language; the languages after the last one that has a text are left out). Texts are raw: no escape codes.\n")
	Ref :: struct {
		key: string,
		id:  int,
	}
	refs := make([dynamic]Ref, context.temp_allocator) // the keys that some language has a text of
	for k, id in c.keys {
		for li in 0 ..< len(c.texts) {
			if _, ok := text_get(c, li, id); ok {
				append(&refs, Ref{k.key, id})
				break
			}
		}
	}
	slice.sort_by(refs[:], proc(a, b: Ref) -> bool {return a.key < b.key})
	strings.write_string(&b, "@languages")
	for l in c.languages {
		strings.write_byte(&b, ' ')
		strings.write_string(&b, l.code)
	}
	strings.write_byte(&b, '\n')
	for r in refs {
		last := -1 // the last language that has the key: the ones after it are left out
		for i in 0 ..< len(c.texts) {
			if _, ok := text_get(c, i, r.id); ok {
				last = i
			}
		}
		strings.write_string(&b, r.key)
		strings.write_byte(&b, '\n')
		for i in 0 ..= last {
			if v, ok := text_get(c, i, r.id); ok {
				strings.write_byte(&b, '\t')
				strings.write_string(&b, v)
				strings.write_byte(&b, '\n')
			} else {
				strings.write_string(&b, "-\n")
			}
		}
	}
	return strings.to_string(b)
}

// How many characters (runes) the longest text has: handy for sizing a box that must fit every language.
longest_text :: proc(c: ^Catalog, key: string) -> int {
	n := 0
	id := find_key(c, key)
	for li in 0 ..< len(c.texts) {
		if v, ok := text_get(c, li, id); ok {
			n = max(n, utf8.rune_count_in_string(v))
		}
	}
	return n
}
