#!/usr/bin/env bash
set -euo pipefail

# Consume only an archive of the supplied commit/tree, or HEAD when no revision is given.
candidate_tree="$(git rev-parse --verify "${1:-HEAD}^{tree}")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git archive --format=tar.gz --output="$scratch/wingman.tar.gz" "$candidate_tree"
mkdir "$scratch/consumer"
tar -xzf "$scratch/wingman.tar.gz" -C "$scratch/consumer" --strip-components=2 examples/consumer

archive_url="file://$scratch/wingman.tar.gz"
export ZIG_GLOBAL_CACHE_DIR="$scratch/global-cache"
export ZIG_LOCAL_CACHE_DIR="$scratch/local-cache"
package_hash="$(zig fetch "$archive_url")"
python3 - "$scratch/consumer/build.zig.zon" "$archive_url" "$package_hash" <<'PY'
from pathlib import Path
import sys

manifest = Path(sys.argv[1])
source = manifest.read_text()
needle = '.wingman = .{ .path = "../.." }'
assert source.count(needle) == 1, "consumer dependency layout changed"
replacement = f'.wingman = .{{ .url = "{sys.argv[2]}", .hash = "{sys.argv[3]}" }}'
manifest.write_text(source.replace(needle, replacement))
PY

cd "$scratch/consumer"
zig build test -Doptimize=ReleaseSafe -Dcpu=baseline --summary all
zig build test -Doptimize=ReleaseFast -Dcpu=baseline --summary all
