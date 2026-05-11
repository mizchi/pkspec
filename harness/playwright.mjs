#!/usr/bin/env node
// pkthunder Playwright harness.
//
// The pkt Go binary embeds this file, writes it to a tmp path, and
// spawns `node <this>` for each playwright Step. Communication is
// JSON over stdin/stdout:
//
//   stdin:  {scriptPath, browser, env, workdir, captureScreenshot}
//   stdout: {status, error?, output: {screenshotBase64?, text?}}
//
// Exit 0 = response is valid (status may still be "fail" if the
// user's script raised). Non-zero exit = harness itself broke
// (could not load playwright, malformed config, etc.).
//
// The user script must default-export `async ({page, ctx}) => result`
// where result is optional. If captureScreenshot is set on the
// config and the script does not return one, the harness takes a
// full-page screenshot itself so authors can write the simplest
// possible script.

import { readFile } from 'node:fs/promises';

async function readStdin() {
  let raw = '';
  for await (const chunk of process.stdin) raw += chunk;
  return raw ? JSON.parse(raw) : {};
}

async function loadPlaywright() {
  try {
    return await import('playwright');
  } catch (e) {
    const msg =
      "playwright is not installed in the project (or not visible to the harness).\n" +
      "Install it with: pnpm add -D playwright && pnpm exec playwright install\n" +
      "Underlying error: " + (e.stack || e.message);
    throw new Error(msg);
  }
}

async function main() {
  const cfg = await readStdin();
  if (!cfg.scriptPath) throw new Error('config.scriptPath is required');

  const pw = await loadPlaywright();
  const browserType = pw[cfg.browser || 'chromium'];
  if (!browserType) throw new Error(`unknown browser: ${cfg.browser}`);

  const browser = await browserType.launch();
  try {
    const context = await browser.newContext();
    const page = await context.newPage();

    let mod;
    try {
      mod = await import(cfg.scriptPath);
    } catch (e) {
      throw new Error(`load script ${cfg.scriptPath}: ${e.stack || e.message}`);
    }
    const handler = mod.default;
    if (typeof handler !== 'function') {
      throw new Error(
        `${cfg.scriptPath} must export default async ({page, ctx}) => result`
      );
    }

    let result;
    try {
      result = await handler({
        page,
        ctx: { env: cfg.env || {}, workdir: cfg.workdir || '' },
      });
    } catch (e) {
      process.stdout.write(JSON.stringify({
        status: 'fail',
        error: 'script threw: ' + (e.stack || e.message),
      }));
      process.exit(0);
    }

    const output = {};
    if (cfg.captureScreenshot) {
      let shot = result && result.screenshot;
      if (!shot) {
        shot = await page.screenshot({ fullPage: true });
      }
      output.screenshotBase64 = Buffer.from(shot).toString('base64');
    }
    if (result && typeof result.output === 'string') {
      output.text = result.output;
    } else if (result && result.output != null) {
      output.text = JSON.stringify(result.output);
    }

    process.stdout.write(JSON.stringify({ status: 'ok', output }));
    process.exit(0);
  } finally {
    await browser.close().catch(() => {});
  }
}

main().catch(e => {
  process.stdout.write(JSON.stringify({
    status: 'harness_error',
    error: e.stack || e.message || String(e),
  }));
  process.exit(1);
});
