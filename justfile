set shell := ["bash", "-euo", "pipefail", "-c"]

release_version := "0.1.2"

default:
  @just --list

test:
  go test ./...

build:
  go build -trimpath -ldflags "-s -w -X main.version={{release_version}}" -o ./bin/pkspec ./cmd/pkspec

smoke: build
  ./bin/pkspec version
  ./bin/pkspec help >/dev/null

init-smoke: build
  @tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; ./bin/pkspec init --dir "$tmp/pkspec"; printf 'amends "./pkspec/Test.pkl"\n\ntests {\n  new {\n    name = "smoke"\n    cmd = "true"\n  }\n}\n' > "$tmp/Test.pkl"; ./bin/pkspec exec -f "$tmp/Test.pkl"

action-lint:
  actionlint

nix-check:
  nix flake check --print-build-logs

nix-build:
  nix build .#default --print-build-logs

release-check: test smoke init-smoke action-lint nix-check nix-build

tag version=release_version: release-check
  git diff --exit-code
  git tag -a v{{version}} -m "Release v{{version}}"
  git push origin main
  git push origin v{{version}}
