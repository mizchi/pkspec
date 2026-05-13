import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const VALID_COVERAGE_KINDS = new Set(["js", "css"]);

export class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = "UsageError";
  }
}

export function usage() {
  return `usage:
  pkspec-adapter-playwright coverage --url URL [--coverage-kind js] [--coverage-kind css]
  pkspec-adapter-playwright coverage --from-json FILE [--coverage-kind js] [--coverage-kind css]

options:
  --url URL                 page URL to measure with Playwright
  --from-json FILE          read raw Playwright coverage JSON (for fixtures/tests)
  --coverage-kind js|css    coverage stream to collect; repeatable, defaults to both
  --browser chromium        Playwright browser type; coverage currently requires chromium
  --timeout MS              navigation timeout, default 30000
  --wait-until STATE        Playwright goto waitUntil value, default load
  --evaluate SCRIPT         page.evaluate() script after navigation
  --coverage-dir DIR        write raw and normalized coverage artifacts
  --config PATH             accepted for adapter preset compatibility
  --project NAME            accepted for adapter preset compatibility; repeatable
  --grep PATTERN            accepted for adapter preset compatibility
  --reporter NAME           accepted for adapter preset compatibility`;
}

export function parseArgs(argv) {
  const command = argv[0] ?? "";
  if (command === "-h" || command === "--help") {
    return { command: "help", help: true };
  }
  if (command !== "coverage") {
    throw new UsageError(`unsupported command ${JSON.stringify(command)}`);
  }

  const opts = {
    command,
    browserName: "chromium",
    coverageKinds: [],
    projects: [],
    reporter: "json-summary",
    timeoutMs: 30000,
    waitUntil: "load",
  };

  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "-h":
      case "--help":
        opts.help = true;
        break;
      case "--url":
        opts.url = takeValue(argv, ++i, arg);
        break;
      case "--from-json":
        opts.fromJson = takeValue(argv, ++i, arg);
        break;
      case "--coverage-kind": {
        const kind = takeValue(argv, ++i, arg);
        if (!VALID_COVERAGE_KINDS.has(kind)) {
          throw new UsageError(`unsupported coverage kind ${JSON.stringify(kind)}`);
        }
        if (!opts.coverageKinds.includes(kind)) {
          opts.coverageKinds.push(kind);
        }
        break;
      }
      case "--browser":
        opts.browserName = takeValue(argv, ++i, arg);
        break;
      case "--timeout":
        opts.timeoutMs = parsePositiveInt(takeValue(argv, ++i, arg), arg);
        break;
      case "--wait-until":
        opts.waitUntil = takeValue(argv, ++i, arg);
        break;
      case "--evaluate":
        opts.evaluate = takeValue(argv, ++i, arg);
        break;
      case "--coverage-dir":
        opts.coverageDir = takeValue(argv, ++i, arg);
        break;
      case "--config":
        opts.configPath = takeValue(argv, ++i, arg);
        break;
      case "--project":
        opts.projects.push(takeValue(argv, ++i, arg));
        break;
      case "--grep":
        opts.grep = takeValue(argv, ++i, arg);
        break;
      case "--reporter":
        opts.reporter = takeValue(argv, ++i, arg);
        break;
      default:
        throw new UsageError(`unknown option ${JSON.stringify(arg)}`);
    }
  }

  if (opts.coverageKinds.length === 0) {
    opts.coverageKinds = ["js", "css"];
  }
  if (opts.url && opts.fromJson) {
    throw new UsageError("use either --url or --from-json, not both");
  }
  if (!opts.url && !opts.fromJson && !opts.help) {
    throw new UsageError("coverage requires --url or --from-json");
  }
  return opts;
}

export function mergeRanges(ranges, total) {
  const normalized = [];
  for (const r of ranges ?? []) {
    const start = clampInt(r.start, 0, total);
    const end = clampInt(r.end, 0, total);
    if (end > start) {
      normalized.push({ start, end });
    }
  }
  normalized.sort((a, b) => a.start - b.start || a.end - b.end);

  const merged = [];
  for (const range of normalized) {
    const last = merged[merged.length - 1];
    if (last && range.start <= last.end) {
      last.end = Math.max(last.end, range.end);
    } else {
      merged.push({ ...range });
    }
  }
  return merged;
}

export function toPkspecCoverage(rawCoverage, coverageKinds) {
  const metrics = [];
  for (const kind of coverageKinds) {
    const entries = rawCoverage?.[kind] ?? [];
    const { covered, total } = summarizeEntries(entries);
    metrics.push({
      name: `${kind}/bytes`,
      covered,
      total,
      pct: total > 0 ? Number(((covered / total) * 100).toFixed(1)) : 0,
    });
  }
  return { metrics };
}

export async function runCoverageCommand(opts) {
  const rawCoverage = opts.fromJson
    ? await readRawCoverage(opts.fromJson)
    : await collectPlaywrightCoverage(opts);
  const report = toPkspecCoverage(rawCoverage, opts.coverageKinds);
  if (opts.coverageDir) {
    await writeCoverageArtifacts(opts.coverageDir, rawCoverage, report);
  }
  return report;
}

export async function collectPlaywrightCoverage(opts) {
  if (opts.browserName !== "chromium") {
    throw new Error("Playwright JS/CSS coverage is Chromium-only; pass --browser chromium");
  }

  let playwright;
  try {
    playwright = await import("playwright");
  } catch (err) {
    throw new Error(
      "Cannot import playwright. Install it with `pnpm add -D playwright` and `pnpm exec playwright install chromium`.",
      { cause: err },
    );
  }

  const browser = await playwright.chromium.launch();
  try {
    const page = await browser.newPage();
    if (opts.coverageKinds.includes("js")) {
      await page.coverage.startJSCoverage({ resetOnNavigation: false });
    }
    if (opts.coverageKinds.includes("css")) {
      await page.coverage.startCSSCoverage({ resetOnNavigation: false });
    }

    await page.goto(opts.url, {
      timeout: opts.timeoutMs,
      waitUntil: opts.waitUntil,
    });
    if (opts.evaluate) {
      await page.evaluate(opts.evaluate);
    }

    const rawCoverage = {};
    if (opts.coverageKinds.includes("js")) {
      rawCoverage.js = await page.coverage.stopJSCoverage();
    }
    if (opts.coverageKinds.includes("css")) {
      rawCoverage.css = await page.coverage.stopCSSCoverage();
    }
    return rawCoverage;
  } finally {
    await browser.close();
  }
}

function summarizeEntries(entries) {
  let covered = 0;
  let total = 0;
  for (const entry of entries ?? []) {
    const text = typeof entry.text === "string" ? entry.text : "";
    const length = text.length;
    total += length;
    for (const range of mergeRanges(entry.ranges, length)) {
      covered += range.end - range.start;
    }
  }
  return { covered, total };
}

async function readRawCoverage(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

async function writeCoverageArtifacts(coverageDir, rawCoverage, report) {
  await mkdir(coverageDir, { recursive: true });
  await writeFile(
    join(coverageDir, "playwright-coverage.raw.json"),
    `${JSON.stringify(rawCoverage, null, 2)}\n`,
  );
  await writeFile(
    join(coverageDir, "pkspec-coverage.json"),
    `${JSON.stringify(report, null, 2)}\n`,
  );
}

function takeValue(argv, index, option) {
  const value = argv[index];
  if (!value || value.startsWith("--")) {
    throw new UsageError(`${option} requires a value`);
  }
  return value;
}

function parsePositiveInt(value, option) {
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) {
    throw new UsageError(`${option} requires a positive integer`);
  }
  return n;
}

function clampInt(value, lo, hi) {
  const n = Number.isFinite(value) ? Math.trunc(value) : lo;
  return Math.max(lo, Math.min(hi, n));
}
