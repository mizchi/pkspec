// Port of internal/migrate/migrate_test.go. Inputs/expectations are byte-faithful
// to the Go oracle's test cases.

///|
fn mig(src : String) -> String {
  let (out, _) = migrate_v01_to_v02(src, "Spec.pkl")
  out
}

///|
fn mig_notes(src : String) -> (String, Array[Note]) {
  migrate_v01_to_v02(src, "Spec.pkl")
}

///|
test "implemented_by_code_with_at" {
  let in_ =
    #|  new {
    #|    id = "x"
    #|    implementedBy = "code"
    #|    implementedAt = "cmd/pkspec/main.go:cmdRun"
    #|  }
    #|
  let want =
    #|  new {
    #|    id = "x"
    #|    implementations {
    #|      new CodeImpl { at = "cmd/pkspec/main.go:cmdRun" }
    #|    }
    #|  }
    #|
  let (got, notes) = mig_notes(in_)
  assert_eq(got, want)
  assert_eq(notes.length(), 0)
}

///|
test "implemented_by_test_without_at_is_dropped" {
  let in_ =
    #|  new {
    #|    id = "x"
    #|    implementedBy = "test"
    #|  }
    #|
  let got = mig(in_)
  assert_false(contains(got, "implementedBy"))
  assert_false(contains(got, "implementations"))
}

///|
test "audience_note_rewrite" {
  let in_ =
    #|  new {
    #|    id = "x"
    #|    pmNotes = "PM line"
    #|    userDescription = "user line"
    #|    operatorNotes = "op line"
    #|    apiNotes = "api line"
    #|  }
    #|
  let got = mig(in_)
  for want in [
    "audienceNotes {", "[\"pm\"] = \"PM line\"", "[\"end-user\"] = \"user line\"",
    "[\"operator\"] = \"op line\"", "[\"api\"] = \"api line\"",
  ] {
    assert_true(contains(got, want))
  }
  assert_eq(count_substr(got, "audienceNotes {"), 1)
  for banned in ["pmNotes", "userDescription", "operatorNotes", "apiNotes"] {
    assert_false(contains(got, banned + " ="))
  }
}

///|
test "single_audience_note_is_one_liner" {
  let in_ =
    #|  new {
    #|    id = "x"
    #|    userDescription = "only one"
    #|  }
    #|
  let got = mig(in_)
  assert_true(contains(got, "audienceNotes { [\"end-user\"] = \"only one\" }"))
}

///|
test "progress_block_flattens" {
  let in_ =
    #|  new Goal {
    #|    id = "g"
    #|    progress {
    #|      method = "severity-weighted"
    #|    }
    #|  }
    #|
  let got = mig(in_)
  assert_true(contains(got, "progressMethod = \"severity-weighted\""))
  assert_false(contains(got, "progress {"))
}

///|
test "progress_one_liner_flattens" {
  let in_ =
    #|progress = new { method = "scenario-count" }
    #|
  let got = mig(in_)
  assert_true(contains(got, "progressMethod = \"scenario-count\""))
}

///|
test "progress_empty_dropped" {
  let in_ =
    #|progress = new {}
    #|keep = 1
    #|
  let got = mig(in_)
  assert_false(contains(got, "progress"))
  assert_true(contains(got, "keep = 1"))
}

///|
test "idempotent" {
  let in_ =
    #|  new {
    #|    id = "x"
    #|    implementations {
    #|      new CodeImpl { at = "a.go:f" }
    #|    }
    #|    audienceNotes { ["pm"] = "hi" }
    #|    progressMethod = "scenario-count"
    #|    inlineStdout = new InlineSnapshot { state = "match"; value = "ok\n" }
    #|  }
    #|
  let (got, notes) = mig_notes(in_)
  assert_eq(got, in_)
  assert_eq(notes.length(), 0)
}

///|
test "inline_empty_string_becomes_capture_snapshot" {
  let in_ =
    #|  new {
    #|    name = "echo"
    #|    cmd = "echo hi"
    #|    inlineStdout = ""
    #|  }
    #|
  let (got, notes) = mig_notes(in_)
  assert_true(contains(got, "inlineStdout = new InlineSnapshot {}"))
  assert_false(contains(got, "inlineStdout = \"\""))
  assert_eq(notes.length(), 0)
}

///|
test "inline_literal_becomes_match_snapshot" {
  let in_ =
    #|  new {
    #|    name = "echo"
    #|    cmd = "echo pong"
    #|    inlineStdout = "pong\n"
    #|  }
    #|
  let got = mig(in_)
  assert_true(
    contains(
      got, "inlineStdout = new InlineSnapshot { state = \"match\"; value = \"pong\\n\" }",
    ),
  )
}

///|
test "inline_null_stays_null" {
  let in_ =
    #|  new {
    #|    name = "echo"
    #|    cmd = "echo hi"
    #|    inlineStdout = null
    #|  }
    #|
  let got = mig(in_)
  assert_true(contains(got, "inlineStdout = null"))
  assert_false(contains(got, "InlineSnapshot"))
}

///|
test "pre_abstract_implementation_flat_rewrite" {
  let in_ =
    #|  implementations {
    #|    new Implementation { kind = "code"; at = "internal/x.go:Foo" }
    #|    new Implementation { kind = "doc"; at = "docs/y.md#bar" }
    #|    new Implementation { kind = "test"; at = "Test.pkl#baz" }
    #|    new Implementation { kind = "task"; at = "Taskfile.pkl#release" }
    #|  }
    #|
  let got = mig(in_)
  for want in [
    "new CodeImpl { at = \"internal/x.go:Foo\" }",
    "new DocImpl { at = \"docs/y.md#bar\" }",
    "new TestImpl { at = \"Test.pkl#baz\" }",
    "new TaskImpl { at = \"Taskfile.pkl#release\" }",
  ] {
    assert_true(contains(got, want))
  }
  assert_false(contains(got, "new Implementation {"))
}

///|
test "body_consolidation_shell_step" {
  let in_ =
    #|tests {
    #|  new {
    #|    name = "echo"
    #|    steps {
    #|      new {
    #|        name = "say"
    #|        cmd = "echo hi"
    #|        shellExpectations {
    #|          expectStdout = "hi\n"
    #|        }
    #|      }
    #|    }
    #|  }
    #|}
    #|
  let (out, _) = migrate_v01_to_v02(in_, "Test.pkl")
  assert_true(contains(out, "body = new ShellBody {"))
  assert_true(contains(out, "cmd = \"echo hi\""))
}

///|
test "body_consolidation_http_step" {
  let in_ =
    #|tests {
    #|  new {
    #|    name = "fetch"
    #|    steps {
    #|      new {
    #|        name = "call"
    #|        http = new HttpRequest {
    #|          method = "GET"
    #|          url = "http://localhost/items"
    #|        }
    #|        expectStatus = 200
    #|        expectBodyJsonPath {
    #|          ["ok"] = true
    #|        }
    #|      }
    #|    }
    #|  }
    #|}
    #|
  let (out, _) = migrate_v01_to_v02(in_, "Test.pkl")
  assert_true(contains(out, "body = new HttpBody {"))
  assert_true(contains(out, "http = new HttpRequest {"))
  assert_true(contains(out, "expectStatus = 200"))
}

///|
test "body_consolidation_parallel_step" {
  let in_ =
    #|tests {
    #|  new {
    #|    name = "fan_out"
    #|    parallelSteps {
    #|      new { name = "p1"; cmd = "sleep 0.2" }
    #|      new { name = "p2"; cmd = "sleep 0.2" }
    #|    }
    #|  }
    #|}
    #|
  let (out, _) = migrate_v01_to_v02(in_, "Test.pkl")
  assert_true(contains(out, "body = new ParallelTest"))
}

///|
test "body_consolidation_cmd_test" {
  let in_ =
    #|tests {
    #|  new {
    #|    name = "echo"
    #|    cmd = "echo hi"
    #|    shellExpectations {
    #|      expectStdout = "hi\n"
    #|    }
    #|  }
    #|}
    #|
  let (out, _) = migrate_v01_to_v02(in_, "Test.pkl")
  assert_true(contains(out, "body = new CmdTest {"))
  assert_true(contains(out, "cmd = \"echo hi\""))
}

///|
test "body_consolidation_sequential_test" {
  let in_ =
    #|tests {
    #|  new {
    #|    name = "seq"
    #|    steps {
    #|      new {
    #|        name = "step1"
    #|        cmd = "echo 1"
    #|      }
    #|    }
    #|  }
    #|}
    #|
  let (out, _) = migrate_v01_to_v02(in_, "Test.pkl")
  assert_true(contains(out, "body = new SequentialTest"))
  assert_true(contains(out, "body = new ShellBody"))
}

///|
test "body_consolidation_idempotent" {
  let in_ =
    #|tests {
    #|  new {
    #|    name = "echo"
    #|    body = new CmdTest {
    #|      cmd = "echo hi"
    #|    }
    #|  }
    #|}
    #|
  let (out, _) = migrate_v01_to_v02(in_, "Test.pkl")
  assert_eq(out, in_)
}

///|
test "body_consolidation_impl_step" {
  let in_ =
    #|scenarios {
    #|  new {
    #|    id = "x"
    #|    given {
    #|      new SpecStep {
    #|        description = "set up"
    #|        impl = new Step {
    #|          cmd = "echo seed"
    #|          captureStdout = "S"
    #|        }
    #|      }
    #|    }
    #|  }
    #|}
    #|
  let got = mig(in_)
  assert_true(contains(got, "body = new ShellBody"))
}

///|
test "shell_expectations_scalar_consolidation" {
  let in_ =
    #|  new {
    #|    name = "echo"
    #|    cmd = "echo hi"
    #|    expectExitCode = 0
    #|    expectStdout = "hi\n"
    #|  }
    #|
  let got = mig(in_)
  assert_true(contains(got, "shellExpectations {"))
  assert_true(contains(got, "expectExitCode = 0"))
  assert_true(contains(got, "expectStdout = \"hi\\n\""))
  assert_eq(count_substr(got, "expectExitCode = 0"), 1)
}

///|
test "shell_expectations_block_field_consolidation" {
  let in_ =
    #|  new {
    #|    name = "contracts"
    #|    cmd = "echo {}"
    #|    expectStdoutContains { "tasks" }
    #|    expectStdoutJsonPath { ["ok"] = true }
    #|  }
    #|
  let got = mig(in_)
  assert_true(contains(got, "shellExpectations {"))
  assert_true(contains(got, "expectStdoutContains { \"tasks\" }"))
  assert_true(contains(got, "expectStdoutJsonPath { [\"ok\"] = true }"))
}

///|
test "shell_expectations_already_migrated_is_idempotent" {
  let in_ =
    #|  new {
    #|    name = "echo"
    #|    cmd = "echo hi"
    #|    shellExpectations {
    #|      expectStdout = "hi\n"
    #|    }
    #|  }
    #|
  let (got, notes) = mig_notes(in_)
  assert_eq(got, in_)
  assert_eq(count_substr(got, "shellExpectations {"), 1)
  assert_eq(notes.length(), 0)
}

///|
test "shell_expectations_multi_line_block_emits_note" {
  let in_ =
    #|  new {
    #|    name = "contracts"
    #|    cmd = "echo hi"
    #|    expectStdoutMatches {
    #|      "pattern1"
    #|      "pattern2"
    #|    }
    #|  }
    #|
  let (_, notes) = mig_notes(in_)
  assert_true(notes.length() > 0)
  assert_true(contains(notes[0].message, "expectStdoutMatches"))
}

///|
test "inline_covers_all_four_scalar_names" {
  let in_ =
    #|  new {
    #|    name = "any-shape"
    #|    inlineStdout = ""
    #|    inlineStderr = "err\n"
    #|    inlineHttpBody = "{}"
    #|    inlineConsoleLog = ""
    #|  }
    #|
  let got = mig(in_)
  for want in [
    "inlineStdout = new InlineSnapshot {}",
    "inlineStderr = new InlineSnapshot { state = \"match\"; value = \"err\\n\" }",
    "inlineHttpBody = new InlineSnapshot { state = \"match\"; value = \"{}\" }",
    "inlineConsoleLog = new InlineSnapshot {}",
  ] {
    assert_true(contains(got, want))
  }
}
