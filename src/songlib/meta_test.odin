package songlib

import "core:strings"
import "core:testing"

@(test)
test_parse_meta_full :: proc(t: ^testing.T) {
	text := `artist Black Sabbath
albumartist Black Sabbath
album Master of Reality (2009 Remastered Version)
title Sweet Leaf
track 1
disc 1
year 2009
source /home/tom/Music/01 - Sweet Leaf.flac
`
	m := parse_meta(text)
	testing.expect_value(t, m.artist, "Black Sabbath")
	testing.expect_value(t, m.album, "Master of Reality (2009 Remastered Version)")
	testing.expect_value(t, m.title, "Sweet Leaf")
	testing.expect_value(t, m.track, 1)
	testing.expect_value(t, m.disc, 1)
	testing.expect_value(t, m.year, 2009)
	testing.expect_value(t, m.source, "/home/tom/Music/01 - Sweet Leaf.flac")
}

@(test)
test_parse_meta_tolerates_junk :: proc(t: ^testing.T) {
	// blank lines, unknown keys, a bare key with no value, and a non-numeric
	// track must all be skipped without disturbing the fields that are valid.
	m := parse_meta("\n\nlyrics whatever\nartist A\nalbum\ntrack xx\ntitle T\n")
	testing.expect_value(t, m.artist, "A")
	testing.expect_value(t, m.title, "T")
	testing.expect_value(t, m.album, "")
	testing.expect_value(t, m.track, 0)
}

@(test)
test_parse_meta_empty :: proc(t: ^testing.T) {
	m := parse_meta("")
	testing.expect_value(t, m.artist, "")
	testing.expect_value(t, group_artist(m), UNKNOWN_ARTIST)
	testing.expect_value(t, group_album(m), UNKNOWN_ALBUM)
	testing.expect_value(t, display_title(m, "some-slug"), "some-slug")
}

@(test)
test_group_artist_prefers_albumartist :: proc(t: ^testing.T) {
	// A "feat." track must file under the album artist, or it splits the album.
	m := Meta {
		artist      = "Black Sabbath feat. Someone",
		albumartist = "Black Sabbath",
	}
	testing.expect_value(t, group_artist(m), "Black Sabbath")
	// ...but with no albumartist tag, the track artist is all we have.
	testing.expect_value(t, group_artist(Meta{artist = "Solo"}), "Solo")
}

@(test)
test_less_fold_is_case_insensitive :: proc(t: ^testing.T) {
	testing.expect(t, less_fold("abba", "Beatles"))
	testing.expect(t, !less_fold("Beatles", "abba"))
	testing.expect(t, less_fold("Air", "airborne")) // prefix sorts first
	testing.expect(t, !less_fold("Same", "same")) // equal ignoring case
}

@(test)
test_meta_less_orders_by_artist_album_track :: proc(t: ^testing.T) {
	a := Meta{albumartist = "Black Sabbath", album = "Master of Reality", track = 1}
	b := Meta{albumartist = "Black Sabbath", album = "Master of Reality", track = 2}
	c := Meta{albumartist = "Black Sabbath", album = "Paranoid", track = 1}
	d := Meta{albumartist = "Led Zeppelin", album = "IV", track = 1}

	testing.expect(t, meta_less(a, b, "", ""), "track 1 before track 2")
	testing.expect(t, !meta_less(b, a, "", ""))
	testing.expect(t, meta_less(b, c, "", ""), "album orders before track")
	testing.expect(t, meta_less(c, d, "", ""), "artist orders before album")
}

@(test)
test_meta_less_disc_beats_track :: proc(t: ^testing.T) {
	// disc 1 track 9 must precede disc 2 track 1.
	a := Meta{album = "X", disc = 1, track = 9}
	b := Meta{album = "X", disc = 2, track = 1}
	testing.expect(t, meta_less(a, b, "", ""))
	testing.expect(t, !meta_less(b, a, "", ""))
}

@(test)
test_meta_less_untagged_falls_back_to_slug :: proc(t: ^testing.T) {
	// No titles: ordering must still be deterministic via the folder slugs.
	a, b := Meta{}, Meta{}
	testing.expect(t, meta_less(a, b, "aaa", "bbb"))
	testing.expect(t, !meta_less(b, a, "bbb", "aaa"))
}

@(test)
test_unique_slug_disambiguates_same_filename :: proc(t: ^testing.T) {
	// The bug this exists for: identical file names in different albums used to
	// collapse onto one library folder, losing a song.
	a, b: [128]u8
	sa := unique_slug("/m/Artist/Album A/01 Intro.mp3", a[:])
	sb := unique_slug("/m/Artist/Album B/01 Intro.mp3", b[:])
	testing.expect(t, sa != sb, "same filename in different albums must not collide")
	testing.expect(t, strings.has_prefix(sa, "01-intro-"), "readable stem is kept")
	testing.expect_value(t, len(sa), len("01-intro-") + SLUG_HASH_HEX)
}

@(test)
test_unique_slug_is_stable :: proc(t: ^testing.T) {
	// Stability is what makes the already-imported check work across runs.
	a, b: [128]u8
	testing.expect_value(
		t,
		unique_slug("/m/x/01 Song.flac", a[:]),
		unique_slug("/m/x/01 Song.flac", b[:]),
	)
}

@(test)
test_unique_slug_handles_small_buffer :: proc(t: ^testing.T) {
	tiny: [4]u8
	testing.expect_value(t, unique_slug("/m/x/song.flac", tiny[:]), "")
	// A tight buffer must still fit, and must still carry the full hash —
	// truncating the hash instead of the stem would reintroduce collisions.
	small: [11]u8
	got := unique_slug("/m/x/song.flac", small[:])
	testing.expect(t, len(got) <= len(small), "must not overrun the buffer")
	testing.expect(t, len(got) > SLUG_HASH_HEX, "hash is preserved, stem is what gets squeezed")
	testing.expect_value(t, got[len(got) - SLUG_HASH_HEX - 1], '-')
}
