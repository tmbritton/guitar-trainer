package store

// The trial log: a single SQLite file with one `trials` table (spec §9.6).
// Everything else — spacing schedules, ladder levels, progress views — is
// derivable from this log, so resist adding tables. Main-thread only; never
// touched from the audio callback.

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
			sqlite3_close(s.db)
		}
		return {}, false
	}
	if sqlite3_exec(s.db, DDL, nil, nil, nil) != SQLITE_OK {
		sqlite3_close(s.db)
		return {}, false
	}
	if sqlite3_prepare_v2(s.db, INSERT_SQL, -1, &s.insert_stmt, nil) != SQLITE_OK {
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
