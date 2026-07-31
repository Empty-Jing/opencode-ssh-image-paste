#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cargo build --release --manifest-path "$root/Cargo.toml"
install -Dm755 "$root/target/release/opencode-ssh-image-paste" "$HOME/.local/bin/opencode-ssh-image-paste"

printf 'Installed receiver: %s\n' "$HOME/.local/bin/opencode-ssh-image-paste"
