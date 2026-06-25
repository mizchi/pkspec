#!/usr/bin/env bash
# Regenerate the self-contained conformance fixtures by re-vendoring the pkl/
# schema tree and copying the examples verbatim. See README.md for why these
# fixtures bundle the schema. Run from anywhere; paths are resolved relative
# to the repo root (this script's grandparent directory).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

for ex in spec-id spec-graph; do
  fx="$here/$ex"
  rm -rf "$fx"
  mkdir -p "$fx/pkl" "$fx/examples/$ex"
  cp "$repo/pkl/Spec.pkl" "$repo/pkl/Test.pkl" "$fx/pkl/"
  cp "$repo/examples/$ex/Spec.pkl" "$repo/examples/$ex/Test.pkl" "$fx/examples/$ex/"
  echo "regenerated $fx"
done
