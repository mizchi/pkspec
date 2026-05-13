import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import {
  mergeRanges,
  parseArgs,
  toPkspecCoverage,
} from "./playwright-coverage-lib.mjs";

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
const root = dirname(here);

test("mergeRanges clamps and merges overlapping coverage ranges", () => {
  assert.deepEqual(
    mergeRanges(
      [
        { start: 8, end: 14 },
        { start: 0, end: 4 },
        { start: 2, end: 6 },
        { start: -5, end: 1 },
      ],
      10,
    ),
    [
      { start: 0, end: 6 },
      { start: 8, end: 10 },
    ],
  );
});

test("toPkspecCoverage reports JS and CSS byte coverage separately", () => {
  const report = toPkspecCoverage(
    {
      js: [
        {
          text: "0123456789",
          ranges: [
            { start: 0, end: 4 },
            { start: 2, end: 6 },
            { start: 8, end: 10 },
          ],
        },
      ],
      css: [
        {
          text: "abcdefghijkl",
          ranges: [
            { start: 0, end: 3 },
            { start: 6, end: 12 },
          ],
        },
      ],
    },
    ["js", "css"],
  );

  assert.deepEqual(report, {
    metrics: [
      { name: "js/bytes", covered: 8, total: 10, pct: 80 },
      { name: "css/bytes", covered: 9, total: 12, pct: 75 },
    ],
  });
});

test("parseArgs accepts repeated coverage-kind values", () => {
  assert.deepEqual(
    parseArgs([
      "coverage",
      "--url",
      "http://127.0.0.1:3000",
      "--coverage-kind",
      "js",
      "--coverage-kind",
      "css",
      "--project",
      "chromium",
    ]).coverageKinds,
    ["js", "css"],
  );
});

test("CLI can convert fixture coverage into pkspec-coverage-json", async () => {
  const { stdout } = await execFileAsync(process.execPath, [
    join(here, "pkspec-adapter-playwright.mjs"),
    "coverage",
    "--from-json",
    join(root, "fixtures", "playwright-coverage.json"),
    "--coverage-kind",
    "js",
    "--coverage-kind",
    "css",
  ]);

  assert.deepEqual(JSON.parse(stdout), {
    metrics: [
      { name: "js/bytes", covered: 8, total: 10, pct: 80 },
      { name: "css/bytes", covered: 9, total: 12, pct: 75 },
    ],
  });
});
