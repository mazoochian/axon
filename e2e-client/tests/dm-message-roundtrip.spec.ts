import { test, expect, type Page } from "@playwright/test";

/**
 * Two real Element Web clients (Alice, Bob) talking to a real Axon server —
 * distinct from apps/axon_web/test/e2e/*.exs and complement/, which both
 * drive raw HTTP against the Matrix API rather than an actual client. This
 * catches the class of bug that only shows up when a real client's own
 * sync loop, room-creation flow, and encryption defaults are exercised.
 *
 * Element Web's selectors can shift between versions — if this breaks after
 * bumping the pinned image tag in docker-compose.yml, `npx playwright test
 * --ui` against a local run is the fastest way to see exactly where the
 * flow diverges and adjust the selectors below.
 */

async function registerUser(page: Page, username: string, password: string) {
  await page.goto("/#/register");

  await page.getByRole("textbox", { name: "Username" }).fill(username);
  await page.getByRole("textbox", { name: "Password", exact: true }).fill(password);
  await page.getByRole("textbox", { name: "Confirm password" }).fill(password);
  await page.getByRole("button", { name: "Register" }).click();

  // A fresh account with no delegated auth configured shouldn't hit an
  // email/terms prompt, but guard anyway since onboarding varies by
  // Element Web version.
  const skipButton = page.getByRole("button", { name: /skip/i });
  if (await skipButton.isVisible({ timeout: 3_000 }).catch(() => false)) {
    await skipButton.click();
  }

  await expect(
    page.getByRole("button", { name: /start chat|add room|create a room/i }).first()
  ).toBeVisible({ timeout: 20_000 });
}

async function startDirectMessage(page: Page, targetUserId: string) {
  await page.getByRole("button", { name: /start chat/i }).click();
  await page.getByRole("textbox", { name: /search|identifier/i }).fill(targetUserId);
  await page.getByText(targetUserId).first().click();
  await page.getByRole("button", { name: /^go$|start chat/i }).click();
}

async function sendMessage(page: Page, text: string) {
  const composer = page.getByRole("textbox", { name: /send a message/i });
  await composer.fill(text);
  await composer.press("Enter");
}

test.describe("DM message round-trip between two real Element Web clients", () => {
  test("Alice and Bob can exchange messages in a DM", async ({ browser }) => {
    const runId = Date.now();
    const password = "Sup3rSecret!Password";
    const alice = { username: `alice_${runId}`, password };
    const bob = { username: `bob_${runId}`, password };
    const bobUserId = `@${bob.username}:localhost`;

    const aliceContext = await browser.newContext();
    const bobContext = await browser.newContext();
    const alicePage = await aliceContext.newPage();
    const bobPage = await bobContext.newPage();

    try {
      await registerUser(alicePage, alice.username, alice.password);
      await registerUser(bobPage, bob.username, bob.password);

      await startDirectMessage(alicePage, bobUserId);
      await sendMessage(alicePage, "hello from alice");

      // Playwright's built-in polling assertions match a real client's own
      // sync-loop latency — no manual sleep needed.
      await bobPage
        .getByText(new RegExp(alice.username, "i"))
        .first()
        .click({ timeout: 20_000 });
      await expect(bobPage.getByText("hello from alice")).toBeVisible({ timeout: 20_000 });

      await sendMessage(bobPage, "hello back from bob");
      await expect(alicePage.getByText("hello back from bob")).toBeVisible({ timeout: 20_000 });
    } finally {
      await aliceContext.close();
      await bobContext.close();
    }
  });
});
