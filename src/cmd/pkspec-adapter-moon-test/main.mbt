// Thin wrapper for the `pkspec-adapter-moon-test` shim binary (Go
// `cmd/pkspec-adapter-moon-test/main.go`). The binary name is taken from this
// package directory, so it is referenced verbatim by the Pkl adapter
// `adapterCommand` (e.g. GoTest.pkl / MoonTest.pkl). The cutover build emits
// all five `pkspec-adapter-*` binaries alongside `pkspec`.

///|
async fn main {
  let argv = @sys.get_cli_args()
  // argv[0] is the program name; the shim subcommand starts at argv[1].
  let code = match (try? @adaptershim.run(@adaptershim.KindMoonTest, argv[1:])) {
    Ok(code) => code
    Err(e) => {
      let _ = (try? @stdio.stderr.write(e.to_string() + "\n"))
      1
    }
  }
  @sys.exit(code)
}
