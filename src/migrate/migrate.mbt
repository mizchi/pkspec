// Package migrate text-transforms pre-v0.2.0 Pkl spec sources into the
// v0.2.0 / v0.3.0 shape. Direct port of internal/migrate/migrate.go — the
// transform is text-only (Pkl semantics are never invoked) and idempotent.
//
// Pipeline:
//   1. Pass-1: line-level rewrites (Rules 1-6).
//   2. Pass-2: body consolidation (Rule 7), inner Step bodies then outer Test.

///|
/// Take the bytes of a v0.1.x Pkl Spec/Test module and return the v0.2.0 /
/// v0.3.0 equivalent plus advisory Notes. Mirrors Go's MigrateV01ToV02.
pub fn migrate_v01_to_v02(source : String, path : String) -> (String, Array[Note]) {
  let (pass1_out, pass1_notes) = migrate_pass1(source, path)
  let (pass2_out, pass2_notes) = migrate_body_consolidation(pass1_out, path)
  let notes : Array[Note] = []
  for n in pass1_notes {
    notes.push(n)
  }
  for n in pass2_notes {
    notes.push(n)
  }
  (pass2_out, notes)
}

///|
/// Accessor for a Note's fields (the struct fields are package-private; the CLI
/// renders them via these).
pub fn Note::path(self : Note) -> String {
  self.path
}

///|
pub fn Note::line(self : Note) -> Int {
  self.line
}

///|
pub fn Note::message(self : Note) -> String {
  self.message
}
