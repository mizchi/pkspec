// The `adapter` command: run an Adapter.pkl module via the pkspec adapter
// protocol. Port of internal/adapter/adapter.go + cmd/pkspec/adapter_cmd.go.
//
// Flow per rendered AdapterSuite (sorted by name):
//   1. discover — run discover.command, parse `pkspec-cases-json` (`{cases:[]}`)
//   2. merge explicit suite.cases, apply overlays, sort cases by id
//   3. dry-run -> print plan; else:
//   4. run — write the JSON case manifest to a temp file, run run.command with
//      PKSPEC_CASE_MANIFEST set, parse `pkspec-events-jsonl` caseFinish events
//   5. aggregate outcomes; collect coverage via collectors (`pkspec-coverage-json`)
// Summary + exit codes match Go: non-zero on any failed / errored / skipped.

///|
/// An adapter command (Go `adapter.Command`): argv with `$VAR` expansion, env
/// overrides, optional workdir, timeout.
priv struct AdapterCommand {
  argv : Array[String]
  env : Map[String, String]
  workdir : String?
  // Go's runCommand enforces command.timeoutSec via context.WithTimeout. The
  // conformance-gated adapters (mock / go-test / moon-test) all finish well
  // under the 300s default, so the timeout is not threaded into the MoonBit
  // subprocess runner here; if a future gate needs it, wire a cancel_handler.
}

///|
/// A data-format descriptor (`kind` + `options`) for discover output / run
/// input+output / collector output (Go `adapter.Format`).
priv struct AdapterFormat {
  kind : String
  options : Map[String, Json]
}

///|
/// A rendered adapter (Go `adapter.Adapter`): the bits the runner needs.
priv struct AdapterDef {
  id : String
  protocol : String
  config : Map[String, Json]
  discover_command : AdapterCommand?
  discover_output : AdapterFormat?
  run_command : AdapterCommand?
  run_input : AdapterFormat?
  run_output : AdapterFormat?
}

///|
/// A rendered collector (Go `adapter.Collector`).
priv struct AdapterCollector {
  name : String
  command : AdapterCommand?
  output : AdapterFormat?
}

///|
/// A case overlay (Go `adapter.Overlay`).
priv struct AdapterOverlay {
  spec_ref : Array[String]
  tags : Array[String]
  pending : Bool
  timeout_sec : Int?
}

///|
/// A rendered suite (Go `adapter.Suite`).
priv struct AdapterSuiteDef {
  name : String
  adapter : AdapterDef?
  workdir : String?
  env : Map[String, String]
  overlays : Map[String, AdapterOverlay]
  cases : Array[@adaptershim.ShimCase]
  collectors : Array[AdapterCollector]
}

///|
/// Aggregated adapter result (Go `adapter.Result`).
priv struct AdapterResult {
  mut total : Int
  mut passed : Int
  mut failed : Int
  mut errored : Int
  mut pending : Int
  mut skipped : Int
  coverage : Array[CoverageReport]
}

///|
priv struct CoverageMetric {
  name : String
  covered : Int
  total : Int
  pct : Double // 0 => derive from covered/total
}

///|
priv struct CoverageReport {
  // (Go's CoverageReport also carries `suite` for its JSON form; the command's
  // FormatSummary only renders name + metrics, so suite is not stored here.)
  name : String
  metrics : Array[CoverageMetric]
}

///|
/// Entry point for `pkspec adapter ...` (Go `cmdAdapter`). Returns the process
/// exit code.
pub async fn run_adapter_cmd(rest : ArrayView[String]) -> Int {
  // Flag parsing (Go uses a flag.FlagSet; we hand-roll the same flags).
  let mut file = "Adapter.pkl"
  let mut suite = ""
  let mut dry_run = false
  let mut root = ""
  let mut i = 0
  let positional : Array[String] = []
  while i < rest.length() {
    let a = rest[i]
    fn next() -> String {
      i = i + 1
      if i < rest.length() {
        rest[i]
      } else {
        ""
      }
    }

    match a {
      "-f" | "--file" => file = next()
      "--suite" => suite = next()
      "--dry-run" => dry_run = true
      "--root" => root = next()
      "-h" | "--help" => {
        @stdio.stdout.write(usage_adapter())
        return 0
      }
      _ => positional.push(a)
    }
    i = i + 1
  }
  if positional.length() > 0 {
    eprintln_pkspec("adapter takes no positional args, got \{positional}")
    return 1
  }

  // Go: filepath.Abs(file) recorded as the plan source path; the embedded
  // evaluator resolves the (relative) path + its amends chain.
  let abs = abs_path(file)
  let plan = match (try? load_adapter_plan(file, abs)) {
    Ok(p) => p
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let run_root = if root != "" { abs_path(root) } else { "" }
  let result = match
    (try? run_adapter_plan(plan, abs, run_root, suite, dry_run)) {
    Ok(r) => r
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  if dry_run {
    return 0
  }
  @stdio.stdout.write(format_adapter_summary(result))
  if result.failed > 0 || result.errored > 0 || result.skipped > 0 {
    eprintln_pkspec(
      "\{result.failed} adapter case(s) failed, \{result.errored} errored, \{result.skipped} skipped",
    )
    return 1
  }
  0
}

///|
fn usage_adapter() -> String {
  let text =
    #|pkspec adapter — run an Adapter.pkl module via the pkspec adapter protocol
    #|
    #|usage:
    #|  pkspec adapter [-f|--file Adapter.pkl] [--suite NAME] [--dry-run] [--root DIR]
    #|
    #|options:
    #|  -f, --file PATH    path to the Adapter.pkl module (default: Adapter.pkl).
    #|  --suite NAME       run only the AdapterSuite with this name.
    #|  --dry-run          discover cases and print the plan; skip the batch run.
    #|  --root DIR         base directory for resolving relative adapter workdirs
    #|                     (default: the directory containing Adapter.pkl).
    #|
    #|Loads the rendered AdapterSuite from the Pkl file, executes the
    #|discover command, merges explicit cases and overlays, writes the
    #|JSON case manifest, runs the adapter batch, and parses
    #|pkspec-events-jsonl output. Exits non-zero on any failed / errored
    #|/ skipped adapter case.
    #|
  text
}
