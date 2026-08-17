package store

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The test runner seeds every test's RNG identically, so rand can't give unique
// names; use a process-global atomic counter instead.
@(private = "file")
g_temp_counter: u64

// unique temp DB path per test (parallel-safe), plus its cleanup.
temp_db :: proc() -> (path: string, cpath: cstring) {
	n := intrinsics.atomic_add(&g_temp_counter, 1)
	path = fmt.aprintf("/tmp/gt_store_%d_%d.db", os.get_pid(), n)
	cpath = strings.clone_to_cstring(path)
	os.remove(path)
	return
}

cleanup_db :: proc(path: string, cpath: cstring) {
	os.remove(path)
	delete(path)
	delete(cpath)
}

sample_row :: proc(midi: i64, correct: bool) -> Trial_Row {
	return Trial_Row {
		ts = 1000,
		key = 60,
		target_degree = 1,
		target_midi = midi,
		detected_midi = midi,
		onset_offset_samples = 42,
		correct = correct,
		response_ms = 500,
		session_id = 7,
	}
}

@(test)
open_creates_empty_table :: proc(t: ^testing.T) {
	path, cpath := temp_db()
	defer cleanup_db(path, cpath)

	s, ok := open(cpath)
	testing.expect(t, ok, "open should succeed")
	defer close(&s)
	testing.expect_value(t, count_trials(&s), i64(0))
}

@(test)
insert_increments_count :: proc(t: ^testing.T) {
	path, cpath := temp_db()
	defer cleanup_db(path, cpath)

	s, ok := open(cpath)
	testing.expect(t, ok, "open should succeed")
	defer close(&s)

	testing.expect(t, insert_trial(&s, sample_row(60, true)), "insert should succeed")
	testing.expect_value(t, count_trials(&s), i64(1))
}

degree_row :: proc(degree, midi: i64, correct: bool) -> Trial_Row {
	r := sample_row(midi, correct)
	r.target_degree = degree
	return r
}

@(test)
degree_stats_aggregates_per_degree :: proc(t: ^testing.T) {
	path, cpath := temp_db()
	defer cleanup_db(path, cpath)
	s, ok := open(cpath)
	testing.expect(t, ok, "open should succeed")
	defer close(&s)

	// degree 1: 2 attempts, 1 correct; degree 2: 1 attempt, 1 correct
	insert_trial(&s, degree_row(1, 60, true))
	insert_trial(&s, degree_row(1, 60, false))
	insert_trial(&s, degree_row(2, 62, true))

	attempts, correct := degree_stats(&s)
	testing.expect_value(t, attempts[1], i64(2))
	testing.expect_value(t, correct[1], i64(1))
	testing.expect_value(t, attempts[2], i64(1))
	testing.expect_value(t, correct[2], i64(1))
	testing.expect_value(t, attempts[3], i64(0)) // unseen
	testing.expect_value(t, correct[3], i64(0))
}

@(test)
degree_stats_all_wrong_degree :: proc(t: ^testing.T) {
	path, cpath := temp_db()
	defer cleanup_db(path, cpath)
	s, ok := open(cpath)
	testing.expect(t, ok, "open should succeed")
	defer close(&s)

	// degree 4 attempted 3x, never correct -> attempts 3, correct 0 (SUM=0).
	insert_trial(&s, degree_row(4, 65, false))
	insert_trial(&s, degree_row(4, 65, false))
	insert_trial(&s, degree_row(4, 65, false))

	attempts, correct := degree_stats(&s)
	testing.expect_value(t, attempts[4], i64(3))
	testing.expect_value(t, correct[4], i64(0))
}

@(test)
multiple_inserts_persist_across_reopen :: proc(t: ^testing.T) {
	path, cpath := temp_db()
	defer cleanup_db(path, cpath)

	{
		s, ok := open(cpath)
		testing.expect(t, ok, "first open should succeed")
		insert_trial(&s, sample_row(62, true))
		insert_trial(&s, sample_row(63, false))
		insert_trial(&s, sample_row(64, true))
		testing.expect_value(t, count_trials(&s), i64(3))
		close(&s)
	}
	{
		s, ok := open(cpath) // reopen same file
		testing.expect(t, ok, "reopen should succeed")
		defer close(&s)
		testing.expect_value(t, count_trials(&s), i64(3)) // data persisted
	}
}
