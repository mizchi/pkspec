export default async ({page, ctx}) => {
  const label = ctx.env.LABEL ?? 'default';
  await page.setContent(`<!doctype html><html><body>
    <h1>hello ${label}</h1>
  </body></html>`);
  return { output: await page.locator('h1').textContent() };
};
