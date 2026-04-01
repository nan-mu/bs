#!/usr/bin/env fish

if test (count $argv) -ne 1
    echo "Usage: $argv[0] <source.c>"
    exit 1
end

set src $argv[1]
if not test -f "$src"
    echo "Error: source file '$src' not found."
    exit 1
end

if not string match -r '\.c$' "$src" > /dev/null
    echo "Error: source file must end with .c"
    exit 1
end

set base (basename "$src" .c)
set out "$base.o"

clang -O2 -g -target bpf -c "$src" -o "$out"
if test $status -ne 0
    echo "Compilation failed."
    exit $status
end

echo "Generated $out"