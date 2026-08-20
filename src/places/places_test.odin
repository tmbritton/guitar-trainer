package places

import "core:testing"

@(test)
test_parse_line_extracts_dir_and_fstype :: proc(t: ^testing.T) {
	m, ok := parse_line("//nasty/RAID /var/mnt/nasty/RAID cifs rw,relatime,vers=3.1.1 0 0")
	testing.expect(t, ok)
	testing.expect_value(t, m.dir, "/var/mnt/nasty/RAID")
	testing.expect_value(t, m.fstype, "cifs")
}

@(test)
test_parse_line_rejects_junk :: proc(t: ^testing.T) {
	_, ok := parse_line("")
	testing.expect(t, !ok)
	_, ok2 := parse_line("only-one-field")
	testing.expect(t, !ok2)
	_, ok3 := parse_line("dev /mnt/x") // no fstype
	testing.expect(t, !ok3)
}

@(test)
test_is_interesting_keeps_real_media_mounts :: proc(t: ^testing.T) {
	testing.expect(t, is_interesting("/var/mnt/nasty/RAID", "cifs"))
	testing.expect(t, is_interesting("/run/media/tom/USB", "vfat"))
	testing.expect(t, is_interesting("/media/backup", "ext4"))
}

@(test)
test_is_interesting_drops_noise :: proc(t: ^testing.T) {
	testing.expect(t, !is_interesting("/", "ext4"), "root is not a shortcut")
	testing.expect(t, !is_interesting("/proc", "proc"))
	testing.expect(t, !is_interesting("/home", "ext4"), "outside the prefixes")
	// An idle automounted NAS share appears ONLY as an autofs entry, so it
	// must be kept or Places loses the share whenever it is not in use.
	testing.expect(t, is_interesting("/var/mnt/nasty/RAID", "autofs"))
	testing.expect(t, is_automount("autofs"))
	testing.expect(t, !is_automount("cifs"))
	// ...but autofs plumbing outside the media prefixes is still noise.
	testing.expect(t, !is_interesting("/proc/sys/fs/binfmt_misc", "autofs"))
	// the prefix itself is not a place, only things under it
	testing.expect(t, !is_interesting("/mnt/", "ext4"))
}

@(test)
test_unescape_decodes_octal :: proc(t: ^testing.T) {
	buf: [64]u8
	testing.expect_value(t, unescape("/mnt/My\\040Disk", buf[:]), "/mnt/My Disk")
	// no escapes: passthrough
	testing.expect_value(t, unescape("/mnt/plain", buf[:]), "/mnt/plain")
	// a lone backslash is not an escape and must survive
	testing.expect_value(t, unescape("/mnt/a\\b", buf[:]), "/mnt/a\\b")
}

@(test)
test_unescape_respects_buffer :: proc(t: ^testing.T) {
	small: [4]u8
	testing.expect_value(t, unescape("/mnt/toolong", small[:]), "/mnt")
}

@(test)
test_label_is_last_component :: proc(t: ^testing.T) {
	testing.expect_value(t, label("/var/mnt/nasty/RAID"), "RAID")
	testing.expect_value(t, label("/run/media/tom/USB/"), "USB")
	testing.expect_value(t, label("/mnt"), "mnt")
	testing.expect_value(t, label("/"), "/")
}
