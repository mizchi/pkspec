export default async ({page}) => {
  await page.setViewportSize({width: 240, height: 80});
  await page.setContent(`<!doctype html><html><body style="margin:0;padding:10px;font-family:monospace">
    <div>screenshot target</div>
  </body></html>`);
  // No explicit return: the harness takes a full-page screenshot itself.
};
