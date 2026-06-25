// pkspec config: the eval -> JSON foundation later phases build the typed
// config model on top of.
//
// This is intentionally minimal in P1: a module path goes in, a `@json.Json`
// tree comes out. No pkspec-specific shape parsing (Test/Spec/Adapter typing)
// lives here yet -- that lands in P2+. The point is to lock the embedded Pkl
// evaluator dependency behind one reusable library function.

///|
/// Raised when the embedded Pkl evaluator reports diagnostics for the module.
/// (`@loader.LoaderError` -- module resolution / fetch / IO failures -- is
/// allowed to propagate unwrapped.)
pub suberror ConfigError { ConfigError(String) } derive(Debug)

///|
/// Evaluate the Pkl module at `path` (through the embedded loader, so
/// `amends`/`import`/glob/package:// all resolve in-process) and return its
/// rendered value as a parsed `@json.Json` tree.
///
/// - On `@pkl.EvalOk(v)`: returns `@json.parse(@pkl.render_value_as_json(v))`.
/// - On `@pkl.EvalError(errs)`: raises `ConfigError` with the joined diagnostics.
/// - `@loader.LoaderError` (and JSON parse failures) propagate via `raise`.
pub async fn eval_module_to_json(path : String) -> Json raise {
  let value = match @loader.eval_module_path(path) {
    @pkl.EvalOk(v) => v
    @pkl.EvalError(errs) => {
      let msgs : Array[String] = []
      for e in errs {
        msgs.push(e.message)
      }
      raise ConfigError("pkl eval \{path}: " + join_messages(msgs, "; "))
    }
  }
  @json.parse(@pkl.render_value_as_json(value))
}

///|
/// Join `parts` with `sep` (no dependency on a stdlib join helper so this stays
/// self-contained across MoonBit core versions).
fn join_messages(parts : Array[String], sep : String) -> String {
  let buf = StringBuilder::new()
  for i, p in parts {
    if i > 0 {
      buf.write_string(sep)
    }
    buf.write_string(p)
  }
  buf.to_string()
}
