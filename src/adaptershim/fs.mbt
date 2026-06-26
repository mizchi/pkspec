// File collection + glob matching for JS / moon discovery.
//
// Mirrors Go's `collectFiles` / `expandInput` / `expandGlob` / `walkAccepted`
// / `globMatch`: each input is a glob (if it contains `*?[`), a directory
// (recursively walked) or a single file. Results are cleaned, de-duped, and
// sorted. Skip-dirs (`.git`, `node_modules`, ...) are pruned during the walk.

///|
/// Collect accepted files across `inputs` (Go `collectFiles`): de-dupe on the
/// cleaned path, sort ascending.
async fn collect_files(
  inputs : Array[String],
  accept : (String) -> Bool,
) -> Array[String] raise {
  let seen : Map[String, Bool] = {}
  let files : Array[String] = []
  for input in inputs {
    if input == "" {
      continue
    }
    for f in expand_input(input, accept) {
      let cleaned = clean_path(f)
      if seen.contains(cleaned) {
        continue
      }
      seen[cleaned] = true
      files.push(cleaned)
    }
  }
  files.sort()
  files
}

///|
async fn expand_input(
  input : String,
  accept : (String) -> Bool,
) -> Array[String] raise {
  if has_meta(input) {
    return expand_glob(input, accept)
  }
  if not(@fs.path_exists(input)) {
    return []
  }
  if (try? @fs.is_dir(input)).unwrap_or(false) {
    return walk_accepted(input, accept)
  }
  if accept(input) {
    [input]
  } else {
    []
  }
}

///|
/// Recursively walk `root`, collecting accepted files; prune skip-dirs.
async fn walk_accepted(
  root : String,
  accept : (String) -> Bool,
) -> Array[String] raise {
  let out : Array[String] = []
  walk_dir(root, accept, out, None)
  out
}

///|
/// Glob expansion (Go `expandGlob`): walk from the static glob root, keep
/// accepted files whose path matches the pattern.
async fn expand_glob(
  pattern : String,
  accept : (String) -> Bool,
) -> Array[String] raise {
  let mut root = glob_root(pattern)
  if root == "" {
    root = "."
  }
  if not(@fs.path_exists(root)) {
    return []
  }
  let out : Array[String] = []
  walk_dir(root, accept, out, Some(pattern))
  out
}

///|
/// Shared recursive directory walk. When `pattern` is Some, an accepted file is
/// kept only if it glob-matches; when None, every accepted file is kept.
async fn walk_dir(
  dir : String,
  accept : (String) -> Bool,
  out : Array[String],
  pattern : String?,
) -> Unit raise {
  let entries = (try? @fs.read_dir(dir)).unwrap_or([])
  for name in entries {
    if name == "." || name == ".." {
      continue
    }
    let full = join_path(dir, name)
    let is_dir = (try? @fs.is_dir(full)).unwrap_or(false)
    if is_dir {
      if should_skip_dir(name) {
        continue
      }
      walk_dir(full, accept, out, pattern)
      continue
    }
    if not(accept(full)) {
      continue
    }
    match pattern {
      Some(p) => if glob_match(p, full) { out.push(full) }
      None => out.push(full)
    }
  }
}

///|
/// Drop files matching any exclude glob (Go `filterExcluded`).
fn filter_excluded(
  files : Array[String],
  excludes : Array[String],
) -> Array[String] {
  if excludes.length() == 0 {
    return files
  }
  let out : Array[String] = []
  for file in files {
    let mut excluded = false
    for pattern in excludes {
      if glob_match(pattern, file) {
        excluded = true
        break
      }
    }
    if not(excluded) {
      out.push(file)
    }
  }
  out
}

///|
/// `.js/.jsx/.mjs/.cjs/.ts/.tsx/.mts/.cts` with `.test.` or `.spec.` in the
/// basename (Go `isJSLikeTestFile`).
fn is_js_like_test_file(path : String) -> Bool {
  let base = base_name(path)
  let ext = ext_of(base)
  let ok_ext = match ext {
    ".js" | ".jsx" | ".mjs" | ".cjs" | ".ts" | ".tsx" | ".mts" | ".cts" => true
    _ => false
  }
  if not(ok_ext) {
    return false
  }
  contains(base, ".test.") || contains(base, ".spec.")
}

///|
/// `.mbt` files (Go `isMoonTestFile`).
fn is_moon_test_file(path : String) -> Bool {
  ext_of(path) == ".mbt"
}

///|
fn should_skip_dir(name : String) -> Bool {
  match name {
    ".git" | "node_modules" | "vendor" | "dist" | "build" | ".next" | "coverage" =>
      true
    _ => false
  }
}

///|
fn has_meta(pattern : String) -> Bool {
  for c in pattern {
    if c == '*' || c == '?' || c == '[' {
      return true
    }
  }
  false
}

///|
/// The static directory prefix before the first glob metacharacter (Go
/// `globRoot`).
fn glob_root(pattern : String) -> String {
  let chars = pattern.to_array()
  let mut cut = chars.length()
  for tok in ['*', '?', '['] {
    let idx = index_of_char(chars, tok)
    if idx >= 0 && idx < cut {
      cut = idx
    }
  }
  let prefix = StringBuilder::new()
  for i in 0..<cut {
    prefix.write_char(chars[i])
  }
  let root = dir_name(prefix.to_string())
  if root == "." && pattern.has_prefix("/") {
    return "/"
  }
  if root == "." || root == "" {
    return "."
  }
  root
}

///|
/// Glob match (Go `globMatch`): `path.Match` plus a `**/` segment that matches
/// across directory boundaries.
fn glob_match(pattern : String, target : String) -> Bool {
  let p = to_slash(clean_path(pattern))
  let t = to_slash(clean_path(target))
  if path_match(p, t) {
    return true
  }
  if not(contains(p, "**/")) {
    return false
  }
  let (prefix, suffix) = split_once(p, "**/")
  if prefix != "" && not(t.has_prefix(prefix)) {
    return false
  }
  let rest = if t.has_prefix(prefix) {
    t.substring(start=prefix.length())
  } else {
    t
  }
  if path_match(suffix, rest) {
    return true
  }
  path_match(suffix, base_name(rest))
}
