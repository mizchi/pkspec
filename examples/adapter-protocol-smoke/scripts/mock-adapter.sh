#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

case "$cmd" in
  discover)
    cat <<'JSON'
{"cases":[{"id":"native.echo","name":"native echo from discover","tags":["native"],"batchKey":"mock"}]}
JSON
    ;;
  run)
    manifest=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --manifest)
          manifest="${2:-}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    test -n "$manifest"
    test -f "$manifest"
    printf '%s\n' '{"type":"caseStart","caseId":"native.echo"}'
    printf '%s\n' '{"type":"caseFinish","caseId":"native.echo","outcome":"passed","durationMs":3}'
    printf '%s\n' '{"type":"caseStart","caseId":"generated.case"}'
    printf '%s\n' '{"type":"caseFinish","caseId":"generated.case","outcome":"passed","durationMs":4}'
    ;;
  coverage)
    cat <<'JSON'
{"metrics":[{"name":"lines","covered":8,"total":10},{"name":"branches","covered":3,"total":4}]}
JSON
    ;;
  *)
    echo "unknown mock adapter command: $cmd" >&2
    exit 2
    ;;
esac
