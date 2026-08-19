package store

// The trial log: a single SQLite file with one `trials` table (spec §9.6).
// Everything else — spacing schedules, ladder levels, progress views — is
// derivable from this log, so resist adding tables. Main-thread only; never
// touched from the audio callback.

import "core:fmt"

Store :: struct {
	db:          ^sqlite3,
	insert_stmt: ^sqlite3_stmt,
}

Trial_Row :: struct {
	ts:                   i64,
	key:                  i64,
	target_degree:        i64,
	target_midi:          i64,
	detected_midi:        i64,
	onset_offset_samples: i64,
	correct:              bool,
	response_ms:          i64,
	session_id:           i64,
}

@(private)
DDL : cstring : "CREATE TABLE IF NOT EXISTS trials (" +
	"id INTEGER PRIMARY KEY, ts INTEGER, key INTEGER, target_degree INTEGER, " +
	"target_midi INTEGER, detected_midi INTEGER, onset_offset_samples INTEGER, " +
	"correct INTEGER, response_ms INTEGER, session_id INTEGER);"

@(private)
INSERT_SQL : cstring : "INSERT INTO trials " +
	"(ts, key, target_degree, target_midi, detected_midi, onset_offset_samples, " +
	"correct, response_ms, session_id) VALUES (?,?,?,?,?,?,?,?,?);"

// open opens (or creates) the DB at `path`, ensures the schema, and prepares the
// insert statement. Returns ok=false on any failure (closing anything it opened).
open :: proc(path: cstring) -> (Store, bool) {
	s: Store
	if sqlite3_open(path, &s.db) != SQLITE_OK {
		if s.db != nil {
			fmt.eprintfln("store: open %s failed: %s", path, sqlite3_errmsg(s.db))
			sqlite3_close(s.db)
		} else {
			fmt.eprintfln("store: open %s failed (out of memory)", path)
		}
		return {}, false
	}
	if sqlite3_exec(s.db, DDL, nil, nil, nil) != SQLITE_OK {
		fmt.eprintfln("store: create table failed: %s", sqlite3_errmsg(s.db))
		sqlite3_close(s.db)
		return {}, false
	}
	if sqlite3_prepare_v2(s.db, INSERT_SQL, -1, &s.insert_stmt, nil) != SQLITE_OK {
		fmt.eprintfln("store: prepare insert failed: %s", sqlite3_errmsg(s.db))
		sqlite3_close(s.db)
		return {}, false
	}
	return s, true
}

close :: proc(s: ^Store) {
	if s.insert_stmt != nil {
		sqlite3_finalize(s.insert_stmt)
		s.insert_stmt = nil
	}
	if s.db != nil {
		sqlite3_close(s.db)
		s.db = nil
	}
}

// insert_trial writes one trial row via the prepared statement.
insert_trial :: proc(s: ^Store, row: Trial_Row) -> bool {
	st := s.insert_stmt
	sqlite3_reset(st)
	correct_i: i64 = row.correct ? 1 : 0
	sqlite3_bind_int64(st, 1, row.ts)
	sqlite3_bind_int64(st, 2, row.key)
	sqlite3_bind_int64(st, 3, row.target_degree)
	sqlite3_bind_int64(st, 4, row.target_midi)
	sqlite3_bind_int64(st, 5, row.detected_midi)
	sqlite3_bind_int64(st, 6, row.onset_offset_samples)
	sqlite3_bind_int64(st, 7, correct_i)
	sqlite3_bind_int64(st, 8, row.response_ms)
	sqlite3_bind_int64(st, 9, row.session_id)
	rc := sqlite3_step(st)
	sqlite3_reset(st) // release the statement's lock so later queries don't get BUSY
	return rc == SQLITE_DONE
}

// degree_stats returns per-degree attempt and correct counts (indexed 1..7;
// index 0 unused), aggregated from the whole trial log. Feeds the scheduler.
degree_stats :: proc(s: ^Store) -> (attempts: [8]i64, correct: [8]i64) {
	stmt: ^sqlite3_stmt
	sql: cstring : "SELECT target_degree, COUNT(*), COALESCE(SUM(correct),0) FROM trials GROUP BY target_degree;"
	if sqlite3_prepare_v2(s.db, sql, -1, &stmt, nil) != SQLITE_OK {
		return
	}
	defer sqlite3_finalize(stmt)
	for sqlite3_step(stmt) == SQLITE_ROW {
		deg := sqlite3_column_int64(stmt, 0)
		if deg >= 1 && deg <= 7 {
			attempts[deg] = sqlite3_column_int64(stmt, 1)
			correct[deg] = sqlite3_column_int64(stmt, 2)
		}
	}
	return
}

// response_ms_bounds returns (min, max) response_ms across all trials, or
// (0, 0) if empty. Diagnostic — used to catch nonsensical logged values.
response_ms_bounds :: proc(s: ^Store) -> (lo: i64, hi: i64) {
	stmt: ^sqlite3_stmt
	sql: cstring : "SELECT COALESCE(MIN(response_ms),0), COALESCE(MAX(response_ms),0) FROM trials;"
	if sqlite3_prepare_v2(s.db, sql, -1, &stmt, nil) != SQLITE_OK {
		return
	}
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW {
		return
	}
	return sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1)
}

// query_two_i64 runs a single-row query returning two int64 columns.
@(private)
query_two_i64 :: proc(s: ^Store, sql: cstring) -> (a: i64, b: i64) {
	stmt: ^sqlite3_stmt
	if sqlite3_prepare_v2(s.db, sql, -1, &stmt, nil) != SQLITE_OK {
		return
	}
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW {
		return
	}
	return sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1)
}

// overall returns total (attempts, correct) across the whole log.
overall :: proc(s: ^Store) -> (attempts: i64, correct: i64) {
	return query_two_i64(s, "SELECT COUNT(*), COALESCE(SUM(correct),0) FROM trials;")
}

// recent_accuracy returns (attempts, correct) over the most recent n trials by id.
recent_accuracy :: proc(s: ^Store, n: int) -> (attempts: i64, correct: i64) {
	stmt: ^sqlite3_stmt
	sql: cstring : "SELECT COUNT(*), COALESCE(SUM(correct),0) FROM (SELECT correct FROM trials ORDER BY id DESC LIMIT ?);"
	if sqlite3_prepare_v2(s.db, sql, -1, &stmt, nil) != SQLITE_OK {
		return
	}
	defer sqlite3_finalize(stmt)
	sqlite3_bind_int64(stmt, 1, i64(n))
	if sqlite3_step(stmt) != SQLITE_ROW {
		return
	}
	return sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1)
}

// practice_days returns the number of distinct calendar-day buckets practiced,
// bucketing by session_id (a per-launch unix timestamp) / seconds-per-day.
practice_days :: proc(s: ^Store) -> i64 {
	a, _ := query_two_i64(s, "SELECT COUNT(DISTINCT session_id / 86400), 0 FROM trials;")
	return a
}

// count_trials returns the number of rows (diagnostic / progress helper).
count_trials :: proc(s: ^Store) -> i64 {
	stmt: ^sqlite3_stmt
	if sqlite3_prepare_v2(s.db, "SELECT COUNT(*) FROM trials;", -1, &stmt, nil) != SQLITE_OK {
		return -1
	}
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW {
		return -1
	}
	return sqlite3_column_int64(stmt, 0)
}
