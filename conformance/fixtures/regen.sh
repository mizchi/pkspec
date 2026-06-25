#!/usr/bin/env bash
# Regenerate the self-contained conformance fixtures by re-vendoring the pkl/
# schema tree and copying the examples verbatim. See README.md for why these
# fixtures bundle the schema. Run from anywhere; paths are resolved relative
# to the repo root (this script's grandparent directory).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

for ex in spec-id spec-graph spec-open-questions spec-pending spec-docs spec-strict-missing; do
  fx="$here/$ex"
  rm -rf "$fx"
  mkdir -p "$fx/pkl" "$fx/examples/$ex"
  cp "$repo/pkl/Spec.pkl" "$repo/pkl/Test.pkl" "$fx/pkl/"
  # Copy whichever of the example's .pkl modules exist (spec-pending has no
  # Spec.pkl). The files are copied verbatim — do not hand-edit.
  for f in Spec.pkl Test.pkl; do
    [ -f "$repo/examples/$ex/$f" ] && cp "$repo/examples/$ex/$f" "$fx/examples/$ex/"
  done
  echo "regenerated $fx"
done
