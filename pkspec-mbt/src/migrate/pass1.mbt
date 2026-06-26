// Pass 1: line-level rewrites (Rules 1-6). Direct port of
// internal/migrate/migrate.go's migratePass1.

///|
priv struct AccEntry {
  indent : String
  key : String
  value : String
}

///|
priv struct ShellEntry {
  indent : String
  // rendered line excluding the leading indent; emitted verbatim inside the new
  // shellExpectations block at indent+"  ".
  body : String
}

///|
fn migrate_pass1(source : String, path : String) -> (String, Array[Note]) {
  let lines = split_keep_eol(source)
  let out = StringBuilder::new()
  let notes : Array[Note] = []

  // accBlocks[depth] = pending audienceNotes entries for that scope.
  let acc_blocks : Array[Array[AccEntry]] = [[]]
  let mut depth = 0

  // Rule 6 state.
  let shell_acc : Array[Array[ShellEntry]] = [[]]
  let mut shell_wrap_depth = -1

  fn flush_audience_notes(entries : Array[AccEntry]) {
    if entries.length() == 0 {
      return
    }
    let indent = entries[0].indent
    out.write_string("\{indent}audienceNotes {")
    if entries.length() == 1 {
      out.write_string(" [\{quote_go(entries[0].key)}] = \{entries[0].value} }\n")
      return
    }
    out.write_string("\n")
    for e in entries {
      out.write_string("\{indent}  [\{quote_go(e.key)}] = \{e.value}\n")
    }
    out.write_string("\{indent}}\n")
  }

  fn flush_shell_expectations(entries : Array[ShellEntry]) {
    if entries.length() == 0 {
      return
    }
    let indent = entries[0].indent
    out.write_string("\{indent}shellExpectations {\n")
    for e in entries {
      out.write_string("\{indent}  \{e.body}\n")
    }
    out.write_string("\{indent}}\n")
  }

  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    let raw = strip_eol(line)
    let trimmed = trim_space(raw)
    let opens = count_char(raw, '{')
    let closes = count_char(raw, '}')

    // Rule 2: audience-specific note fields -> accumulate.
    match match_audience_note(raw) {
      Some((indent, old_field, value)) => {
        let key = audience_key(old_field)
        while acc_blocks.length() <= depth {
          acc_blocks.push([])
        }
        acc_blocks[depth].push({ indent, key, value })
        depth = depth + opens - closes
        if depth < 0 {
          depth = 0
        }
        i = i + 1
        continue
      }
      None => ()
    }

    // Rule 6: entry into an existing `shellExpectations {` block.
    if shell_wrap_depth < 0 &&
      match_shell_expectations_open(raw) &&
      opens > closes {
      shell_wrap_depth = depth + (opens - closes)
      out.write_string(line)
      depth = depth + opens - closes
      if depth < 0 {
        depth = 0
      }
      i = i + 1
      continue
    }
    if shell_wrap_depth >= 0 && depth >= shell_wrap_depth {
      out.write_string(line)
      depth = depth + opens - closes
      if depth < shell_wrap_depth {
        shell_wrap_depth = -1
      }
      if depth < 0 {
        depth = 0
      }
      i = i + 1
      continue
    }

    // Rule 6: consolidate sibling shell-expectation lines.
    match match_shell_expect_scalar(raw) {
      Some((indent, name, rest)) => {
        while shell_acc.length() <= depth {
          shell_acc.push([])
        }
        shell_acc[depth].push({ indent, body: "\{name} = \{rest}" })
        depth = depth + opens - closes
        if depth < 0 {
          depth = 0
        }
        i = i + 1
        continue
      }
      None => ()
    }
    let mut block_handled = false
    match match_shell_expect_block(raw) {
      Some((indent, name, body)) =>
        if opens == closes {
          while shell_acc.length() <= depth {
            shell_acc.push([])
          }
          shell_acc[depth].push({ indent, body: "\{name} {\{body}}" })
          i = i + 1
          block_handled = true
        }
      None => ()
    }
    if block_handled {
      continue
    }
    match match_shell_expect_multiline_open(raw) {
      Some((_, name)) =>
        notes.push({
          path,
          line: i + 1,
          message: "\{name} opens a multi-line block; wrap the surrounding sibling expect* fields inside a `shellExpectations { ... }` block by hand.",
        })
      None => ()
    }

    // Rule 5: pre-abstract `new Implementation { kind = "X"; at = "Y" }`.
    match match_impl_flat_inline(raw) {
      Some((indent, kind, at)) => {
        out.write_string("\{indent}new \{impl_subclass(kind)} { at = \{at} }\n")
        i = i + 1
        continue
      }
      None => ()
    }

    // Rule 4: scalar inline-snapshot fields -> InlineSnapshot block.
    match match_inline_scalar(raw) {
      Some((indent, name, rest_raw)) => {
        let rest = trim_space(rest_raw)
        if has_prefix(rest, "new InlineSnapshot") {
          out.write_string(line)
          depth = depth + opens - closes
          if depth < 0 {
            depth = 0
          }
          i = i + 1
          continue
        }
        if rest == "null" {
          out.write_string(line)
          depth = depth + opens - closes
          if depth < 0 {
            depth = 0
          }
          i = i + 1
          continue
        }
        match match_inline_string_value(rest) {
          Some(literal) => {
            if literal == "\"\"" {
              out.write_string("\{indent}\{name} = new InlineSnapshot {}\n")
            } else {
              out.write_string(
                "\{indent}\{name} = new InlineSnapshot { state = \"match\"; value = \{literal} }\n",
              )
            }
            i = i + 1
            continue
          }
          None => ()
        }
        notes.push({
          path,
          line: i + 1,
          message: "\{name} has a non-string-literal value; wrap it as `new InlineSnapshot { state = \"match\"; value = ... }` by hand.",
        })
        out.write_string(line)
        depth = depth + opens - closes
        if depth < 0 {
          depth = 0
        }
        i = i + 1
        continue
      }
      None => ()
    }

    // Rule 1: implementedBy [+ implementedAt] -> implementations.
    match match_implemented_by(raw) {
      Some((indent, kind)) => {
        let mut at = ""
        let mut advance = 1
        let mut j = i + 1
        while j < lines.length() && j <= i + 2 {
          let next = strip_eol(lines[j])
          if trim_space(next) == "" {
            j = j + 1
            continue
          }
          match match_implemented_at(next) {
            Some((_, v)) => {
              at = v
              advance = j - i + 1
            }
            None => ()
          }
          break
        }
        if kind == "test" && at == "" {
          i = i + advance
          continue
        }
        if at == "" {
          notes.push({
            path,
            line: i + 1,
            message: "implementedBy=\{quote_go(kind)} has no sibling implementedAt; emitting implementations entry without `at`.",
          })
          out.write_string("\{indent}implementations {\n")
          out.write_string("\{indent}  new \{impl_subclass(kind)} {}\n")
          out.write_string("\{indent}}\n")
          i = i + advance
          continue
        }
        out.write_string("\{indent}implementations {\n")
        out.write_string("\{indent}  new \{impl_subclass(kind)} { at = \{at} }\n")
        out.write_string("\{indent}}\n")
        i = i + advance
        continue
      }
      None => ()
    }

    match match_implemented_at(raw) {
      Some(_) =>
        notes.push({
          path,
          line: i + 1,
          message: "orphan `implementedAt` without a preceding `implementedBy`; passed through unchanged.",
        })
      None => ()
    }

    // Rule 3a: `progress { method = "X" }` block form (3 lines).
    let mut progress_block_done = false
    match match_progress_block_open(raw) {
      Some(indent) =>
        if i + 2 < lines.length() {
          let mid_raw = strip_eol(lines[i + 1])
          let end_raw = strip_eol(lines[i + 2])
          match match_progress_method(mid_raw) {
            Some(m) =>
              if match_progress_block_close(end_raw) {
                out.write_string("\{indent}progressMethod = \{quote_go(m)}\n")
                i = i + 3
                progress_block_done = true
              }
            None => ()
          }
        }
      None => ()
    }
    if progress_block_done {
      continue
    }

    match match_progress_one_line(raw) {
      Some((indent, meth)) => {
        out.write_string("\{indent}progressMethod = \{quote_go(meth)}\n")
        i = i + 1
        continue
      }
      None => ()
    }

    if match_progress_empty(raw) {
      i = i + 1
      continue
    }

    // Flush pending accumulators before a bare `}` closing line.
    if closes > opens && trimmed == "}" {
      if depth >= 0 && depth < acc_blocks.length() && acc_blocks[depth].length() > 0 {
        flush_audience_notes(acc_blocks[depth])
        acc_blocks[depth] = []
      }
      if depth >= 0 && depth < shell_acc.length() && shell_acc[depth].length() > 0 {
        flush_shell_expectations(shell_acc[depth])
        shell_acc[depth] = []
      }
    }

    out.write_string(line)
    depth = depth + opens - closes
    if depth < 0 {
      depth = 0
    }
    i = i + 1
  }
  // Final flush at module scope.
  if acc_blocks.length() > 0 && acc_blocks[0].length() > 0 {
    flush_audience_notes(acc_blocks[0])
  }
  if shell_acc.length() > 0 && shell_acc[0].length() > 0 {
    flush_shell_expectations(shell_acc[0])
  }
  (out.to_string(), notes)
}
