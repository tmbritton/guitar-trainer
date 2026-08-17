package store

// Minimal hand-written bindings to the system SQLite (Homebrew provides
// libsqlite3 + headers; the system also ships libsqlite3.so.0). We bind only the
// handful of entry points the trial log needs. `system:sqlite3` links -lsqlite3.

import "core:c"

foreign import sqlite "system:sqlite3"

sqlite3 :: struct {} // opaque handle
sqlite3_stmt :: struct {} // opaque prepared statement

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101

@(default_calling_convention = "c")
foreign sqlite {
	sqlite3_open :: proc(filename: cstring, ppDb: ^^sqlite3) -> c.int ---
	sqlite3_close :: proc(db: ^sqlite3) -> c.int ---
	sqlite3_exec :: proc(db: ^sqlite3, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: ^sqlite3, zSql: cstring, nByte: c.int, ppStmt: ^^sqlite3_stmt, pzTail: ^cstring) -> c.int ---
	sqlite3_bind_int64 :: proc(stmt: ^sqlite3_stmt, idx: c.int, val: i64) -> c.int ---
	sqlite3_step :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_reset :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_finalize :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_column_int64 :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> i64 ---
	sqlite3_errmsg :: proc(db: ^sqlite3) -> cstring ---
}
