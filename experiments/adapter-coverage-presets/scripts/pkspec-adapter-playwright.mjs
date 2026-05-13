#!/usr/bin/env node
import {
  parseArgs,
  runCoverageCommand,
  UsageError,
  usage,
} from "./playwright-coverage-lib.mjs";

async function main(argv) {
  const opts = parseArgs(argv);
  if (opts.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  const report = await runCoverageCommand(opts);
  process.stdout.write(`${JSON.stringify(report)}\n`);
}

main(process.argv.slice(2)).catch((err) => {
  process.stderr.write(`pkspec-adapter-playwright: ${err.message}\n`);
  if (err instanceof UsageError) {
    process.stderr.write(`${usage()}\n`);
    process.exitCode = 2;
  } else {
    process.exitCode = 1;
  }
});
