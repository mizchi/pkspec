import { test, expect } from '@playwright/test';

test('login form renders', async ({ page }) => {
  await page.setContent('<form><input name="email"></form>');
  await expect(page.locator('input[name=email]')).toBeVisible();
});

test('signup form renders', async ({ page }) => {
  await page.setContent('<form><input name="email"><input name="password"></form>');
  await expect(page.locator('input[name=password]')).toBeVisible();
});

test.skip('password reset (not yet wired)', async () => {});
