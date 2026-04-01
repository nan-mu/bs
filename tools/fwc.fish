#!/usr/bin/env fish
# Build the ESP-IDF Rust firmware in this repository.
# This script ensures the correct Rust toolchain and ESP-IDF workspace tool path are used.

# Change to the firmware repository root (script directory).
cd firmware

# Ensure local Cargo bin is available so ldproxy and rustup are found.
set -gx PATH $HOME/.cargo/bin $PATH

# Use the workspace-local ESP-IDF tools installation.
set -gx IDF_TOOLS_PATH (pwd)/.embuild/espressif

# Ensure the necessary executable exists.
if not test -x $HOME/.cargo/bin/ldproxy
    echo "Error: ldproxy is not installed in $HOME/.cargo/bin" >&2
    echo "Install it with: curl -L https://github.com/esp-rs/embuild/releases/latest/download/ldproxy-aarch64-apple-darwin.zip | funzip > $HOME/.cargo/bin/ldproxy; chmod +x $HOME/.cargo/bin/ldproxy" >&2
    exit 1
end

if not test -x $HOME/.rustup/toolchains/nightly-aarch64-apple-darwin/bin/cargo
    echo "Error: nightly toolchain cargo not found at $HOME/.rustup/toolchains/nightly-aarch64-apple-darwin/bin/cargo" >&2
    echo "Install the toolchain with: rustup toolchain install nightly && rustup component add rust-src --toolchain nightly" >&2
    exit 1
end

# Run cargo build with the nightly toolchain.
set -lx RUSTUP_TOOLCHAIN nightly
rustup run nightly cargo build --verbose
