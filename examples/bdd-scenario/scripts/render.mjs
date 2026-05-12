export default async ({page, ctx}) => {
  await page.setContent(`<h1>${ctx.env.LABEL ?? 'page'}</h1>`);
  return { output: await page.locator('h1').textContent() };
};
