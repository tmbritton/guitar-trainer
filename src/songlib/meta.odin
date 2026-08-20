package songlib

// Pure parsing + ordering for a song's meta.txt (written by assets/separate.py
// from the source file's tags). Line-oriented "key value" text: the key is the
// first token, the value is the rest of the line. Unknown keys are ignored and
// every field is optional, so an old or hand-edited file still loads.
//
// Allocation-free like the rest of songlib: parsed strings are subslices of the
// caller's buffer, which must outlive the Meta.

import "core:strconv"
import "core:strings"

// Shown when a song has no artist/album tag. Grouping treats all such songs as
// one artist/album, which keeps them together rather than scattering them.
UNKNOWN_ARTIST :: "Unknown Artist"
UNKNOWN_ALBUM :: "Unknown Album"

Meta :: struct {
	artist:      string, // track artist
	albumartist: string, // album artist; preferred for grouping (see group_artist)
	album:       string,
	title:       string,
	track:       int, // 0 when untagged — sorts before any real track number
	disc:        int,
	year:        int,
	source:      string, // absolute path of the file this was separated from
}

// parse_meta reads a whole meta.txt. Values keep interior spaces (album titles
// have them); surrounding whitespace is trimmed. A malformed number is left at 0.
parse_meta :: proc(text: string) -> Meta {
	m: Meta
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		s := strings.trim_space(line)
		if len(s) == 0 do continue
		sp := strings.index_byte(s, ' ')
		if sp <= 0 do continue // no key/value separator
		key := s[:sp]
		val := strings.trim_space(s[sp + 1:])
		if len(val) == 0 do continue
		switch key {
		case "artist":
			m.artist = val
		case "albumartist":
			m.albumartist = val
		case "album":
			m.album = val
		case "title":
			m.title = val
		case "source":
			m.source = val
		case "track":
			m.track, _ = strconv.parse_int(val)
		case "disc":
			m.disc, _ = strconv.parse_int(val)
		case "year":
			m.year, _ = strconv.parse_int(val)
		}
	}
	return m
}

// group_artist is the name the library groups under: the album artist when
// present, else the track artist. Preferring albumartist keeps a compilation or
// a "feat." track filed under the album's artist instead of splitting the album.
group_artist :: proc(m: Meta) -> string {
	if len(m.albumartist) > 0 do return m.albumartist
	if len(m.artist) > 0 do return m.artist
	return UNKNOWN_ARTIST
}

group_album :: proc(m: Meta) -> string {
	if len(m.album) > 0 do return m.album
	return UNKNOWN_ALBUM
}

// display_title is the song's row label; `fallback` (the folder slug) is used
// when the source file carried no title tag.
display_title :: proc(m: Meta, fallback: string) -> string {
	if len(m.title) > 0 do return m.title
	return fallback
}

// less_fold is a case-insensitive ASCII ordering, so "black sabbath" and
// "Black Sabbath" sort together instead of splitting on case.
less_fold :: proc(a, b: string) -> bool {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		ca, cb := lower(a[i]), lower(b[i])
		if ca != cb do return ca < cb
	}
	return len(a) < len(b)
}

@(private = "file")
lower :: proc(c: u8) -> u8 {
	return c + 'a' - 'A' if c >= 'A' && c <= 'Z' else c
}

// meta_less orders songs for the library: artist, album, disc, track, then title
// as a tiebreak so untagged songs (track 0) still land in a stable order.
meta_less :: proc(a, b: Meta, fa, fb: string) -> bool {
	aa, ba := group_artist(a), group_artist(b)
	if !strings.equal_fold(aa, ba) do return less_fold(aa, ba)
	al, bl := group_album(a), group_album(b)
	if !strings.equal_fold(al, bl) do return less_fold(al, bl)
	if a.disc != b.disc do return a.disc < b.disc
	if a.track != b.track do return a.track < b.track
	return less_fold(display_title(a, fa), display_title(b, fb))
}
