export default async ({page}) => {
  await page.setContent(`<!doctype html><html><body>
    <script>
      console.log('boot');
      console.log('init complete');
    </script>
  </body></html>`);
};
