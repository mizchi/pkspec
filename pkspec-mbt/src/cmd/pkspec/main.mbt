///|
fn pkspec_version() -> String {
  "0.4.0"
}

///|
fn usage() -> String {
  let s =
    #|usage: pkspec <command> [args...]
    #|
    #|commands:
    #|  version              print pkspec version
    #|  help                 show this help
  s
}

///|
fn main {
  let argv = @sys.get_cli_args()
  // argv[0] is the program name; the subcommand (if any) is argv[1].
  if argv.length() < 2 {
    println(usage())
    return
  }
  let code = match argv[1] {
    "version" | "--version" | "-v" => {
      println(pkspec_version())
      0
    }
    "help" | "--help" | "-h" => {
      println(usage())
      0
    }
    other => {
      println("pkspec: unknown command: \{other}")
      println(usage())
      2
    }
  }
  @sys.exit(code)
}
