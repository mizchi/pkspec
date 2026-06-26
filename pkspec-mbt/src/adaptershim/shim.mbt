// MoonBit port of internal/adaptershim/shim.go.
//
// One shared library package implementing the `discover` / `run` / `coverage`
// subcommands of the pkspec adapter shim protocol (`pkspec.adapter.v1`). The
// five `pkspec-adapter-<kind>` binaries are thin `main`s that call `run` with
// their fixed kind (KindVitest / KindPlaywright / KindNodeTest / KindGoTest /
// KindMoonTest), exactly like the Go `cmd/pkspec-adapter-*/main.go` wrappers.
//
// Wire-format parity with Go (gated by the go-test / moon-test conformance
// fixtures): discover emits compact `{"cases":[...]}` + trailing newline with
// fields in struct-declaration order and Go `omitempty` semantics; run emits
// one compact JSON event object per line; coverage emits `{"metrics":[...]}`.

///|
pub const KindVitest = "vitest"

///|
pub const KindPlaywright = "playwright"

///|
pub const KindNodeTest = "node-test"

///|
pub const KindGoTest = "go-test"

///|
pub const KindMoonTest = "moon-test"

///|
/// A discovered / manifest case. Mirrors Go `adaptershim.Case` (and the
/// adapter command's `Case`), including the JSON `omitempty` tags.
pub(all) struct ShimCase {
  id : String
  name : String?
  source_module : String?
  export_name : String?
  selector : Map[String, String] // empty => omitted
  // `params` (map[string]any) is carried opaquely as a raw JSON value so the
  // manifest round-trips losslessly. None => omitted.
  params : Json?
  // specRef / tags / pending / timeoutSec are mutable so the adapter command's
  // overlay step (Go `applyOverlays`) can replace them on a discovered case.
  spec_ref : Array[String]
  tags : Array[String]
  mut pending : Bool
  mut timeout_sec : Int?
  batch_key : String
}

///|
/// Raised for shim-level usage / IO / runner errors. `Show` writes only the
/// message so the thin `main` prints it like Go's `fmt.Fprintln(os.Stderr, err)`.
pub(all) suberror ShimError {
  ShimError(String)
}

///|
pub impl Show for ShimError with output(self, logger) {
  let ShimError(msg) = self
  logger.write_string(msg)
}

///|
/// Execute a native adapter shim command (Go `adaptershim.Run`). Returns the
/// process exit code; the caller's `main` exits with it.
pub async fn run(
  kind : String,
  args : ArrayView[String],
) -> Int raise {
  if args.length() == 0 {
    raise ShimError("usage: pkspec-adapter-\{kind} <discover|run|coverage>")
  }
  match args[0] {
    "discover" => {
      run_discover(kind, args[1:])
      0
    }
    "run" => {
      run_manifest(kind, args[1:])
      0
    }
    "coverage" => {
      run_coverage(kind, args[1:])
      0
    }
    "-h" | "--help" | "help" => {
      println("usage: pkspec-adapter-\{kind} <discover|run|coverage>")
      0
    }
    other => raise ShimError("unknown adapter shim command \{go_quote(other)}")
  }
}
