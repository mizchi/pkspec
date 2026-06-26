// Pass 2: body consolidation (Rule 7). Direct port of
// internal/migrate/migrate.go's migrateBodyConsolidation + bodyConsolidationPass
// + the inline one-liner pre-pass.

///|
priv enum FrameKind {
  Module
  Tests
  Steps
  ParallelSteps
  SpecSteps
  SpecStep
  TestBody
  StepBody
  Other
} derive(Eq)

///|
priv struct BodyFrame {
  kind : FrameKind
  content_indent : String
  body_lines : Array[String]
  mut discriminator : String
  mut already_migrated : Bool
}

///|
fn migrate_body_consolidation(
  source : String,
  path : String,
) -> (String, Array[Note]) {
  let (step_out, notes1) = body_consolidation_pass(source, path, StepBody)
  let (test_out, notes2) = body_consolidation_pass(step_out, path, TestBody)
  let all : Array[Note] = []
  for n in notes1 {
    all.push(n)
  }
  for n in notes2 {
    all.push(n)
  }
  (test_out, all)
}

///|
/// rewriteInlineOneLiners: regex pre-pass for the single-line cases the walker
/// can't absorb (block opens AND closes on the same line).
fn rewrite_inline_one_liners(source : String, active_kind : FrameKind) -> String {
  if active_kind != StepBody && active_kind != TestBody {
    return source
  }
  let lines = split_keep_eol(source)
  let out = StringBuilder::new()
  for line in lines {
    let raw = strip_eol(line)
    let rewritten = if active_kind == StepBody {
      match match_inline_impl_step(raw) {
        Some((indent, cmd_val)) =>
          Some(
            "\{indent}impl = new Step { body = new ShellBody { cmd = \{cmd_val} } }",
          )
        None =>
          match match_inline_dense_step(raw) {
            Some((indent, name, cmd_val)) =>
              Some(
                "\{indent}new { name = \{name}; body = new ShellBody { cmd = \{cmd_val} } }",
              )
            None => None
          }
      }
    } else {
      // TestBody
      match match_inline_dense_test(raw) {
        Some((indent, name, cmd_val, trailing_raw)) => {
          let trailing = trim_space(trailing_raw)
          let tail = if trailing != "" { "; " + trailing } else { "" }
          Some(
            "\{indent}new { name = \{name}; body = new CmdTest { cmd = \{cmd_val} }\{tail} }",
          )
        }
        None => None
      }
    }
    match rewritten {
      Some(r) => {
        out.write_string(r)
        // Preserve the original line's EOL (the regex replaced the line content
        // only; Go's ReplaceAllFunc keeps the surrounding "\n").
        out.write_string(eol_of(line))
      }
      None => out.write_string(line)
    }
  }
  out.to_string()
}

///|
/// Return the trailing EOL of a line as produced by split_keep_eol (always
/// "\n" except possibly the final no-newline line, which has "").
fn eol_of(line : String) -> String {
  if line.length() > 0 && line.unsafe_charcode_at(line.length() - 1) == 0x0A {
    "\n"
  } else {
    ""
  }
}

///|
fn body_consolidation_pass(
  source : String,
  path : String,
  active_kind : FrameKind,
) -> (String, Array[Note]) {
  let source = rewrite_inline_one_liners(source, active_kind)
  let lines = split_keep_eol(source)
  let out = StringBuilder::new()
  let notes : Array[Note] = []
  let stack : Array[BodyFrame] = [
    { kind: Module, content_indent: "", body_lines: [], discriminator: "", already_migrated: false },
  ]
  let mut body_value_depth = 0
  let mut in_triple_quote = false
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    let raw = strip_eol(line)
    let trimmed = trim_space(raw)
    let opens = count_char(raw, '{')
    let closes = count_char(raw, '}')
    let top_f = stack[stack.length() - 1]
    let collecting = top_f.kind == active_kind

    // Continuation of a triple-quoted multi-line body value.
    if in_triple_quote && collecting && not(top_f.already_migrated) {
      top_f.body_lines.push(line)
      if contains(raw, "\"\"\"") {
        in_triple_quote = false
      }
      i = i + 1
      continue
    }

    // Continuation of a multi-line body value.
    if body_value_depth > 0 && collecting && not(top_f.already_migrated) {
      top_f.body_lines.push(line)
      body_value_depth = body_value_depth + opens - closes
      i = i + 1
      continue
    }

    // `body = new ...` already present — idempotency.
    if collecting && match_body_already_migrated(raw) {
      top_f.already_migrated = true
      out.write_string(line)
      update_stack(stack, top_f, raw, trim_space(raw), opens, closes)
      i = i + 1
      continue
    }

    // Body-field detection inside a collecting frame.
    if collecting && not(top_f.already_migrated) {
      let consumed = try_collect_body_field(
        top_f, line, raw, opens, closes, lines, i, notes, path,
      )
      match consumed {
        Consumed1 => {
          i = i + 1
          continue
        }
        ConsumedMulti(triple, value_depth) => {
          if triple {
            in_triple_quote = true
          } else {
            body_value_depth = value_depth
          }
          i = i + 1
          continue
        }
        NotConsumed => ()
      }
    }

    // Block-close: emit the wrap before the closer.
    if closes > opens &&
      trimmed == "}" &&
      collecting &&
      not(top_f.already_migrated) &&
      top_f.body_lines.length() > 0 {
      emit_body_wrap(out, top_f)
    }
    out.write_string(line)
    update_stack(stack, top_f, raw, trimmed, opens, closes)
    i = i + 1
  }
  (out.to_string(), notes)
}

///|
priv enum Consumed {
  NotConsumed
  Consumed1
  // (isTripleQuoteOpen, valueDepth)
  ConsumedMulti(Bool, Int)
}

///|
/// try_collect_body_field: examine a single line inside a body-collection frame.
fn try_collect_body_field(
  top_f : BodyFrame,
  line : String,
  raw : String,
  opens : Int,
  closes : Int,
  _lines : Array[String],
  i : Int,
  notes : Array[Note],
  path : String,
) -> Consumed {
  let trimmed = trim_space(raw)
  let (disc, is_discriminator) = classify_discriminator(top_f.kind, trimmed)
  let is_sibling = classify_sibling(top_f.kind, top_f.discriminator, trimmed)
  if not(is_discriminator) && not(is_sibling) && top_f.discriminator == "" {
    return NotConsumed
  }
  if not(is_discriminator) && not(is_sibling) {
    return NotConsumed
  }
  if is_discriminator {
    if top_f.discriminator != "" && disc != top_f.discriminator {
      notes.push({
        path,
        line: i + 1,
        message: "two body discriminators present in the same block (\{quote_go(top_f.discriminator)} and \{quote_go(disc)}); leaving block unwrapped — hand-fix.",
      })
      return NotConsumed
    }
    top_f.discriminator = disc
  }
  top_f.body_lines.push(line)
  let open_triple_count = count_substr(raw, "\"\"\"")
  if open_triple_count % 2 == 1 {
    return ConsumedMulti(true, 0)
  } else if opens > closes {
    return ConsumedMulti(false, opens - closes)
  }
  Consumed1
}

///|
/// classify_discriminator: is `trimmed` a body discriminator assignment?
fn classify_discriminator(fk : FrameKind, trimmed : String) -> (String, Bool) {
  match fk {
    StepBody =>
      match match_discriminator(trimmed, ["cmd", "http", "playwrightTest", "playwright", "sql"]) {
        Some(d) => (d, true)
        None => ("", false)
      }
    TestBody =>
      match match_discriminator(trimmed, ["cmd", "parallelSteps", "steps"]) {
        Some(d) => (d, true)
        None => ("", false)
      }
    _ => ("", false)
  }
}

///|
/// `^(name)\s*(=|\{)` over the discriminator alternatives. Longer prefixes
/// (`playwrightTest` before `playwright`, `parallelSteps` before `steps`) come
/// first so the leftmost-longest behaviour of Go's alternation is preserved.
fn match_discriminator(trimmed : String, names : Array[String]) -> String? {
  for name in names {
    if has_prefix(trimmed, name) {
      let rest = trim_space(trimmed.substring(start=name.length(), end=trimmed.length()))
      // Go regex: `name\s*(=|\{)` — after the name (and optional ws) the next
      // non-ws char must be '=' or '{'. trim_space on the rest then check head.
      if rest.length() > 0 {
        let head = rest.unsafe_charcode_at(0)
        if head == 0x3D || head == 0x7B {
          return Some(name)
        }
      }
    }
  }
  None
}

///|
/// classify_sibling: is `trimmed` a body-specific sibling field?
fn classify_sibling(fk : FrameKind, disc : String, trimmed : String) -> Bool {
  if disc == "" {
    return false
  }
  let allowed = allowed_siblings(fk, disc)
  for name in allowed {
    if match_field_line(trimmed, name) {
      return true
    }
  }
  false
}

///|
fn allowed_siblings(fk : FrameKind, disc : String) -> Array[String] {
  match fk {
    StepBody =>
      match disc {
        "cmd" => [
          "shell", "stdin", "shellExpectations", "inlineStdout", "captureStdout",
          "captureExitCode",
        ]
        "http" => [
          "expectStatus", "expectStatusBetween", "expectBodyEquals", "expectBodyContains",
          "expectHeaderEquals", "expectBodyJsonPath", "inlineHttpBody", "inlineJsonPath",
          "inlineHeaders", "captureBody", "captureStatus", "captureBodyJsonPath",
          "cassette",
        ]
        "playwright" => ["inlineConsoleLog"]
        "playwrightTest" => []
        "sql" => ["inlineSqlRows"]
        _ => []
      }
    TestBody =>
      match disc {
        "cmd" => [
          "stdin", "shellExpectations", "expectStdoutSnapshot", "expectStderrSnapshot",
          "inlineStdout", "inlineStderr",
        ]
        "steps" => []
        "parallelSteps" => []
        _ => []
      }
    _ => []
  }
}

///|
/// matchFieldLine: `<name> = ...` or `<name> { ...`.
fn match_field_line(trimmed : String, name : String) -> Bool {
  if not(has_prefix(trimmed, name)) {
    return false
  }
  let rest = trim_space(trimmed.substring(start=name.length(), end=trimmed.length()))
  has_prefix(rest, "=") || has_prefix(rest, "{")
}

///|
/// emit_body_wrap: write the `body = new XBody { ... }` block.
fn emit_body_wrap(out : StringBuilder, f : BodyFrame) -> Unit {
  let body_class = pick_body_class(f.kind, f.discriminator)
  if body_class == "" {
    for l in f.body_lines {
      out.write_string(l)
    }
    return
  }
  let indent = f.content_indent
  out.write_string("\{indent}body = new \{body_class} {\n")
  for l in f.body_lines {
    let raw = strip_eol(l)
    if trim_space(raw) == "" {
      out.write_string(l)
      continue
    }
    out.write_string("  \{raw}\n")
  }
  out.write_string("\{indent}}\n")
}

///|
fn pick_body_class(fk : FrameKind, disc : String) -> String {
  match fk {
    StepBody =>
      match disc {
        "cmd" => "ShellBody"
        "http" => "HttpBody"
        "playwright" => "PlaywrightBody"
        "playwrightTest" => "PlaywrightTestBody"
        "sql" => "SqlBody"
        _ => ""
      }
    TestBody =>
      match disc {
        "cmd" => "CmdTest"
        "steps" => "SequentialTest"
        "parallelSteps" => "ParallelTest"
        _ => ""
      }
    _ => ""
  }
}

///|
/// updateStack: apply a line's braces to the scope stack.
fn update_stack(
  stack : Array[BodyFrame],
  top_f : BodyFrame,
  raw : String,
  trimmed : String,
  opens : Int,
  closes : Int,
) -> Unit {
  if opens == 0 && closes > 0 {
    for _ in 0..<closes {
      if stack.length() > 1 {
        stack.pop() |> ignore
      }
    }
    return
  }
  if opens > 0 && closes == 0 {
    let (new_kind, indent) = classify_opener(top_f.kind, raw, trimmed)
    for k in 0..<opens {
      if k == 0 {
        stack.push({
          kind: new_kind,
          content_indent: indent + "  ",
          body_lines: [],
          discriminator: "",
          already_migrated: false,
        })
      } else {
        stack.push({
          kind: Other,
          content_indent: "",
          body_lines: [],
          discriminator: "",
          already_migrated: false,
        })
      }
    }
    return
  }
  let delta = opens - closes
  if delta > 0 {
    let (new_kind, indent) = classify_opener(top_f.kind, raw, trimmed)
    for k in 0..<delta {
      if k == 0 {
        stack.push({
          kind: new_kind,
          content_indent: indent + "  ",
          body_lines: [],
          discriminator: "",
          already_migrated: false,
        })
      } else {
        stack.push({
          kind: Other,
          content_indent: "",
          body_lines: [],
          discriminator: "",
          already_migrated: false,
        })
      }
    }
  } else if delta < 0 {
    for _ in 0..<(-delta) {
      if stack.length() > 1 {
        stack.pop() |> ignore
      }
    }
  }
}

///|
/// classifyOpener: what frame a `{`-opening line pushes.
fn classify_opener(
  parent_kind : FrameKind,
  raw : String,
  trimmed : String,
) -> (FrameKind, String) {
  let indent = leading_spaces(raw)
  if match_tests_open(trimmed) {
    return (Tests, indent)
  }
  if match_steps_open(trimmed) {
    return (Steps, indent)
  }
  if match_parallel_steps_open(trimmed) {
    return (ParallelSteps, indent)
  }
  if match_spec_steps_open(trimmed) {
    return (SpecSteps, indent)
  }
  if match_impl_step_open(trimmed) {
    return (StepBody, indent)
  }
  if match_new_block_open(trimmed) {
    match parent_kind {
      Tests => return (TestBody, indent)
      Steps | ParallelSteps => return (StepBody, indent)
      SpecSteps => return (SpecStep, indent)
      _ => return (Other, indent)
    }
  }
  (Other, indent)
}
