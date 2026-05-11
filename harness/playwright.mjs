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

async function loadPixelmatch() {
  try {
    const [pm, pngMod] = await Promise.all([
      import('pixelmatch'),
      import('pngjs'),
    ]);
    return { pixelmatch: pm.default ?? pm, PNG: pngMod.PNG ?? pngMod.default?.PNG };
  } catch {
    return null;
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

      // Optional pixel diff: if Go sent a baseline AND pixelmatch is
      // available, compute the per-pixel diff% so Go can compare it
      // against `thresholdPct`. Without pixelmatch installed, Go
      // falls back to byte-exact (its existing behaviour).
      if (cfg.expectScreenshotBaseline) {
        const pm = await loadPixelmatch();
        if (pm) {
          try {
            const baselineBuf = Buffer.from(cfg.expectScreenshotBaseline, 'base64');
            const actualBuf = Buffer.from(shot);
            const baselinePng = pm.PNG.sync.read(baselineBuf);
            const actualPng = pm.PNG.sync.read(actualBuf);
            if (baselinePng.width === actualPng.width && baselinePng.height === actualPng.height) {
              const diffPng = new pm.PNG({ width: baselinePng.width, height: baselinePng.height });
              const diffPixels = pm.pixelmatch(
                baselinePng.data,
                actualPng.data,
                diffPng.data,
                baselinePng.width,
                baselinePng.height,
                { threshold: 0.1 }
              );
              const total = baselinePng.width * baselinePng.height;
              output.diffPct = total > 0 ? (diffPixels / total) * 100 : 0;
              output.diffPng = pm.PNG.sync.write(diffPng).toString('base64');
            } else {
              output.diffPct = 100;
              output.diffSizeMismatch = {
                baseline: { w: baselinePng.width, h: baselinePng.height },
                actual: { w: actualPng.width, h: actualPng.height },
              };
            }
          } catch (e) {
            output.diffError = (e.stack || e.message || String(e)).slice(0, 800);
          }
        }
      }
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
