#!/usr/bin/env fish

function die
    echo "Error: $argv" >&2
    exit 1
end

if test (count $argv) -ne 1
    echo "Usage: $argv[0] <source.rs>"
    exit 1
end

set src (realpath $argv[1])
if not test -f $src
    die "Source file not found: $src"
end

set toolchain nightly
set target riscv32imac-unknown-none-elf
set build_dir target/rv32c
set out_base (basename $src .rs)
set elf "$build_dir/$out_base.elf"
set bin "$build_dir/$out_base.bin"

mkdir -p $build_dirt

if not rustup toolchain list | grep -q "^$toolchain\$"
    echo "Installing Rust toolchain $toolchain..."
    rustup toolchain install $toolchain --profile minimal || die "Failed to install $toolchain"
end

if not rustup target list --installed --toolchain $toolchain | grep -q "^$target\$"
    echo "Adding target $target..."
    rustup target add $target --toolchain $toolchain || die "Failed to add target $target"
end

if not type -q riscv32-unknown-elf-gcc
    echo "Warning: riscv32-unknown-elf-gcc not found in PATH. Linking may fail."
end

set tmp_linker (mktemp -t rv32-link.XXXXXX.ld)
cat > $tmp_linker <<'EOF'
SECTIONS
{
    . = 0x80000000;
    .text : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data : { *(.data .data.*) }
    .bss : { *(.bss .bss.* COMMON) }
}
EOF

echo "Compiling $src for target $target using $toolchain..."
rustc +$toolchain --edition=2021 --crate-type bin \
    --target=$target \
    -C opt-level=z -C panic=abort \
    -C linker=riscv32-unknown-elf-gcc -C link-arg=--script=$tmp_linker \
    -o $elf \
    $src

set status $status
rm -f $tmp_linker

if test $status -ne 0
    die "Compilation failed"
end

if type -q riscv32-unknown-elf-objcopy
    riscv32-unknown-elf-objcopy -O binary $elf $bin
    if test $status -ne 0
        die "Failed to generate binary image"
    end
    echo "Firmware built:"
    echo "  ELF:  $elf"
    echo "  BIN:  $bin"
else
    echo "Firmware built ELF: $elf"
    echo "Note: riscv32-unknown-elf-objcopy not found, .bin not generated"
end