#!/usr/bin/env fish

# 用法: c2rust_existing.fish <file.rs> [db_path]

set DEFAULT_DB "/Users/nan/bs/aot/target/c2rust.sqlite3"

if test (count $argv) -lt 1 -o (count $argv) -gt 2
    echo "Usage: $argv[0] <file.rs> [db_path]"
    exit 1
end

set file (realpath "$argv[1]")
if not test -f "$file"
    echo "Error: file not found: $argv[1]"
    exit 1
end

set db $DEFAULT_DB
if test (count $argv) -eq 2
    set db "$argv[2]"
end
set db (realpath "$db")

# 建表
sqlite3 "$db" "CREATE TABLE IF NOT EXISTS missing (name TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('函数','类型','值','库'))); CREATE TABLE IF NOT EXISTS existing (name TEXT NOT NULL, source_path TEXT NOT NULL, PRIMARY KEY (name, source_path));"
if test $status -ne 0
    echo "Error: failed to create tables in $db"
    exit 1
end

# 提取 pub fn 并写入 existing(name, source_path)
set inserted 0
set skipped 0

for fn in (rg -o "pub fn\s+(\w+)" "$file" | awk '{print $3}' | sort -u)
    set esc_fn (string replace -a "'" "''" -- "$fn")
    set esc_file (string replace -a "'" "''" -- "$file")

    set exists (sqlite3 "$db" "SELECT 1 FROM existing WHERE name='$esc_fn' AND source_path='$esc_file' LIMIT 1;")
    if test -n "$exists"
        set skipped (math $skipped + 1)
        echo "SKIP existing: $file,$fn (already exists)"
        continue
    end

    sqlite3 "$db" "INSERT INTO existing(name, source_path) VALUES('$esc_fn', '$esc_file');"
    if test $status -eq 0
        set inserted (math $inserted + 1)
        echo "INSERT existing: $file,$fn"
    else
        echo "FAIL existing: $file,$fn"
    end
end

echo "Done. inserted=$inserted skipped=$skipped file=$file db=$db"
