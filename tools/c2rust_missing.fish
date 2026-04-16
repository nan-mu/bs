#!/usr/bin/env fish

set DEFAULT_DB "/Users/nan/bs/aot/target/c2rust.sqlite3"
set -g VERBOSE 0
set LOG_PREFIX "[c2rust-missing]"

function usage
    echo "Usage: $argv[0] [-v|--verbose] <file.rs> [db_path]"
end

function vlog
    if test "$VERBOSE" = "1"
        echo "$LOG_PREFIX $argv"
    end
end

set positional
for arg in $argv
    switch "$arg"
        case -v --verbose
            set VERBOSE 1
        case '*'
            set positional $positional "$arg"
    end
end

if test (count $positional) -lt 1 -o (count $positional) -gt 2
    usage
    exit 1
end

set file (realpath "$positional[1]")
if not test -f "$file"
    echo "Error: file not found: $positional[1]"
    exit 1
end

set db $DEFAULT_DB
if test (count $positional) -eq 2
    set db "$positional[2]"
end
set db (realpath "$db")

vlog "Start processing file=$file db=$db"

# 1) 建表
set create_sql "CREATE TABLE IF NOT EXISTS missing (name TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('函数','类型','值','库'))); CREATE TABLE IF NOT EXISTS existing (name TEXT NOT NULL, source_path TEXT NOT NULL, PRIMARY KEY (name, source_path)); CREATE TABLE IF NOT EXISTS exempt (name TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('函数','类型','值','库')));"
vlog "SQL EXEC: create schema"
sqlite3 "$db" "$create_sql"
if test $status -ne 0
    echo "Error: failed to create schema"
    exit 1
end

# 2) 把当前文件的 pub fn 写入 existing
set esc_file (string replace -a "'" "''" -- "$file")
for fn in (rg -o "pub fn\s+(\w+)" "$file" | awk '{print $3}' | sort -u)
    set esc_fn (string replace -a "'" "''" -- "$fn")

    set exists_row (sqlite3 "$db" "SELECT 1 FROM existing WHERE name='$esc_fn' AND source_path='$esc_file' LIMIT 1;")
    if test -n "$exists_row"
        vlog "SKIP existing insert: name=$fn source_path=$file reason=already_exists"
    else
        vlog "SQL EXEC: INSERT existing(name=$fn, source_path=$file)"
        sqlite3 "$db" "INSERT INTO existing(name, source_path) VALUES('$esc_fn', '$esc_file');"
    end
end

# 3) 编译并解析缺失符号
set missing_funcs
set missing_types
set missing_values
set missing_libs

set tmp (mktemp)
rustc --emit=metadata --crate-type lib "$file" 2>&1 >/dev/null | rg "error\[" | sort -u > "$tmp"

while read -l line
    set kind ""
    set name ""

    if string match -rq "cannot find function `([^`]+)`" -- "$line"
        set kind "函数"
        set name (string replace -r ".*cannot find function `([^`]+)`.*" '$1' -- "$line")
    else if string match -rq "cannot find type `([^`]+)`" -- "$line"
        set kind "类型"
        set name (string replace -r ".*cannot find type `([^`]+)`.*" '$1' -- "$line")
    else if string match -rq "use of undeclared type `([^`]+)`" -- "$line"
        set kind "类型"
        set name (string replace -r ".*use of undeclared type `([^`]+)`.*" '$1' -- "$line")
    else if string match -rq "cannot find value `([^`]+)`" -- "$line"
        set kind "值"
        set name (string replace -r ".*cannot find value `([^`]+)`.*" '$1' -- "$line")
    else if string match -rq "unresolved import `([^`]+)`" -- "$line"
        set kind "库"
        set import_name (string replace -r ".*unresolved import `([^`]+)`.*" '$1' -- "$line")
        set name (string split "::" -- "$import_name")[1]
    else
        vlog "SKIP PARSE: line='$line' reason=no_supported_pattern"
        continue
    end

    set esc_name (string replace -a "'" "''" -- "$name")
    set esc_kind (string replace -a "'" "''" -- "$kind")

    set exempt_hit (sqlite3 "$db" "SELECT 1 FROM exempt WHERE name='$esc_name' LIMIT 1;")
    if test -n "$exempt_hit"
        vlog "SKIP missing: name=$name kind=$kind reason=exempt"
        continue
    end

    set hits (sqlite3 "$db" "SELECT source_path || ',' || name FROM existing WHERE name='$esc_name';")
    if test (count $hits) -gt 0
        vlog "SKIP missing: name=$name kind=$kind reason=already_in_existing"
        for row in $hits
            vlog "EXISTING HIT: $row"
        end
        continue
    end

    switch "$kind"
        case 函数
            if not contains -- "$name" $missing_funcs
                set missing_funcs $missing_funcs "$name"
            end
        case 类型
            if not contains -- "$name" $missing_types
                set missing_types $missing_types "$name"
            end
        case 值
            if not contains -- "$name" $missing_values
                set missing_values $missing_values "$name"
            end
        case 库
            if not contains -- "$name" $missing_libs
                set missing_libs $missing_libs "$name"
            end
    end

    set missing_hit (sqlite3 "$db" "SELECT 1 FROM missing WHERE name='$esc_name' AND kind='$esc_kind' LIMIT 1;")
    if test -n "$missing_hit"
        vlog "SKIP INSERT missing: name=$name kind=$kind reason=already_in_missing"
    else
        vlog "SQL EXEC: INSERT missing(name=$name, kind=$kind)"
        sqlite3 "$db" "INSERT INTO missing(name, kind) VALUES('$esc_name', '$esc_kind');"
    end
end < "$tmp"

rm -f "$tmp"

set funcs_sorted (printf '%s\n' $missing_funcs | sort -u)
set types_sorted (printf '%s\n' $missing_types | sort -u)
set values_sorted (printf '%s\n' $missing_values | sort -u)
set libs_sorted (printf '%s\n' $missing_libs | sort -u)

echo "函数："(string join "," $funcs_sorted)
echo "类型："(string join "," $types_sorted)
echo "值："(string join "," $values_sorted)
echo "库："(string join "," $libs_sorted)

vlog "Done"
