package songlib

import "core:testing"

// ---- parse_line: one line of separate.py's stdout ----

@(test)
parse_progress_line :: proc(t: ^testing.T) {
	m := parse_line("PROGRESS 42")
	testing.expect_value(t, m.kind, Kind.Progress)
	testing.expect_value(t, m.pct, 42)
}

@(test)
parse_progress_clamps_and_tolerates_whitespace :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_line("  PROGRESS   7  ").pct, 7)
	testing.expect_value(t, parse_line("PROGRESS 150").pct, 100) // clamp high
	testing.expect_value(t, parse_line("PROGRESS -3").pct, 0) // clamp low
}

@(test)
parse_progress_nonnumeric_is_unknown :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_line("PROGRESS abc").kind, Kind.Unknown)
}

@(test)
parse_done_carries_path :: proc(t: ^testing.T) {
	m := parse_line("DONE /tmp/library/song")
	testing.expect_value(t, m.kind, Kind.Done)
	testing.expect_value(t, m.text, "/tmp/library/song")
}

@(test)
parse_error_carries_message :: proc(t: ^testing.T) {
	m := parse_line("ERROR demucs not installed")
	testing.expect_value(t, m.kind, Kind.Error)
	testing.expect_value(t, m.text, "demucs not installed")
}

@(test)
parse_garbage_is_unknown :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_line("loading model...").kind, Kind.Unknown)
	testing.expect_value(t, parse_line("").kind, Kind.Unknown)
}

// ---- is_supported_audio: extension filter ----

@(test)
supported_extensions :: proc(t: ^testing.T) {
	for name in ([]string{"a.wav", "a.flac", "a.mp3", "a.ogg", "a.m4a"}) {
		testing.expectf(t, is_supported_audio(name), "%s should be supported", name)
	}
}

@(test)
supported_is_case_insensitive :: proc(t: ^testing.T) {
	testing.expect(t, is_supported_audio("Song.MP3"), "uppercase ext supported")
	testing.expect(t, is_supported_audio("Song.FLAC"), "uppercase ext supported")
}

@(test)
unsupported_and_extensionless :: proc(t: ^testing.T) {
	testing.expect(t, !is_supported_audio("notes.txt"), "txt not audio")
	testing.expect(t, !is_supported_audio("README"), "no extension")
	testing.expect(t, !is_supported_audio(".mp3"), "dotfile with no stem")
}

// ---- slug: filename -> library folder name ----

@(test)
slug_basic :: proc(t: ^testing.T) {
	buf: [64]u8
	testing.expect_value(t, slug("My Song.mp3", buf[:]), "my-song")
}

@(test)
slug_strips_punct_and_collapses :: proc(t: ^testing.T) {
	buf: [64]u8
	testing.expect_value(t, slug("My Song (Live!!).flac", buf[:]), "my-song-live")
	testing.expect_value(t, slug("  spaced  out  .wav", buf[:]), "spaced-out")
}

@(test)
slug_keeps_digits :: proc(t: ^testing.T) {
	buf: [64]u8
	testing.expect_value(t, slug("Track 07.wav", buf[:]), "track-07")
}

// ---- is_song_dir: are all 6 stems present? ----

@(test)
song_dir_needs_all_stems :: proc(t: ^testing.T) {
	all := []string{"vocals.wav", "drums.wav", "bass.wav", "guitar.wav", "piano.wav", "other.wav"}
	testing.expect(t, is_song_dir(all), "all six stems present")

	missing := []string{"vocals.wav", "drums.wav", "bass.wav", "guitar.wav", "piano.wav"}
	testing.expect(t, !is_song_dir(missing), "one stem missing")

	testing.expect(t, !is_song_dir([]string{}), "empty dir is not a song")
}

@(test)
test_is_song_dir_accepts_flac :: proc(t: ^testing.T) {
	// Real imports write mono FLAC.
	flac := []string {
		"vocals.flac",
		"drums.flac",
		"bass.flac",
		"guitar.flac",
		"piano.flac",
		"other.flac",
		"meta.txt",
	}
	testing.expect(t, is_song_dir(flac))
}

@(test)
test_is_song_dir_accepts_mixed_extensions :: proc(t: ^testing.T) {
	// A dir part-migrated from WAV to FLAC must still count as finished.
	mixed := []string {
		"vocals.flac",
		"drums.wav",
		"bass.flac",
		"guitar.wav",
		"piano.flac",
		"other.flac",
	}
	testing.expect(t, is_song_dir(mixed))
}

@(test)
test_is_song_dir_rejects_missing_stem :: proc(t: ^testing.T) {
	testing.expect(t, !is_song_dir([]string{"vocals.flac", "drums.flac"}))
	// A near-miss name must not satisfy a stem.
	testing.expect(t, !is_song_dir([]string{"vocals.flac", "drums.flac", "bass.flac", "guitar.flac", "piano.flac", "others.flac"}))
}
