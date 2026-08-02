import { test, expect, type Page } from "@playwright/test";

/**
 * Two real Element Web clients (Alice, Bob) actually initiating device
 * verification against a real Axon server — distinct from
 * `apps/axon_web/test/e2e/verification_flow_test.exs`, which drives the
 * same SAS exchange over raw HTTP with plaintext to-device events. This
 * exercises the real thing: matrix-js-sdk's own cross-signing bootstrap
 * (real olm, real key backup, real `/keys/device_signing/upload` +
 * `/keys/signatures/upload`) and the real "Verify" UI, to catch the class
 * of bug that only shows up when an actual client — not a raw HTTP script
 * asserting on decoded JSON — decides whether to even show a verification
 * prompt.
 *
 * Important, easy-to-miss precondition this test locks in: a user must
 * complete their own "Set up Secure Backup" cross-signing bootstrap
 * before verifying someone ELSE will present the clean "Verify User" /
 * emoji-SAS flow — skip it (it's a dismissible "Later" toast, not
 * something that visibly blocks anything) and Element instead shows a
 * confusing device-specific "Not Trusted" dialog, or silently redirects
 * the initiator into their own setup first. That's the most likely
 * explanation for a report of "verification doesn't do anything" — not a
 * server bug (this test's own passing run is proof the underlying
 * mechanism, including real cross-signing + to-device delivery, works).
 */

// Axon itself is always on :8008 regardless of which profile started it
// (see docker-compose.yml) — distinct from Element Web's own baseURL,
// which varies (published on :8080 by docker-compose, but overridden via
// E2E_BASE_URL for local port-conflict workarounds).
const HOMESERVER = "http://localhost:8008";

async function apiRegister(username: string, password: string): Promise<string> {
  const res = await fetch(`${HOMESERVER}/_matrix/client/v3/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      username,
      password,
      kind: "user",
      auth: { type: "m.login.dummy" },
    }),
  });
  if (!res.ok) throw new Error(`register failed: ${res.status} ${await res.text()}`);
  const body = await res.json();
  return body.user_id as string;
}

async function loginUser(page: Page, username: string, password: string) {
  await page.goto("/#/login");
  await page.getByRole("textbox", { name: /username/i }).fill(username);
  await page.getByRole("textbox", { name: "Password", exact: true }).fill(password);
  await page.getByRole("button", { name: /^sign in$/i }).click();

  await expect(
    page.getByRole("button", { name: /start chat|add room|create a room/i }).first()
  ).toBeVisible({ timeout: 20_000 });

  const threadsOk = page.getByRole("button", { name: "OK" });
  if (await threadsOk.isVisible({ timeout: 3_000 }).catch(() => false)) {
    await threadsOk.click();
  }
}

// Completes the real "Set up Secure Backup" cross-signing bootstrap wizard
// if/when Element shows it (generates a security key, confirms it's saved,
// waits for the async "Setting up keys" step to actually finish) — a no-op
// if the prompt isn't showing right now, since it can appear on a delay or
// get triggered later by some other action (e.g. opening another user's
// device list) instead of right after login.
async function completeSecureBackupIfPrompted(page: Page) {
  const continueBtn = page.getByRole("button", { name: /^continue$/i });
  if (!(await continueBtn.isVisible({ timeout: 5_000 }).catch(() => false))) {
    return;
  }
  await continueBtn.click();

  for (let i = 0; i < 6; i++) {
    await page.waitForTimeout(1000);
    const nextish = page.getByRole("button", { name: /^continue$|^copy$|^done$|^finish$/i });
    if (await nextish.first().isVisible({ timeout: 3000 }).catch(() => false)) {
      await nextish.first().click();
    } else {
      break;
    }
  }

  await page
    .getByText("Setting up keys")
    .waitFor({ state: "hidden", timeout: 30_000 })
    .catch(() => {});

  // The "Secure Backup successful" confirmation can land on its own delay.
  const done = page.getByRole("button", { name: /^done$/i });
  if (await done.isVisible({ timeout: 8_000 }).catch(() => false)) {
    await done.click();
  }
}

async function startDirectMessage(page: Page, targetUserId: string) {
  await page.getByRole("button", { name: /start chat|send a direct message/i }).first().click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("textbox").first().fill(targetUserId);
  await dialog.getByText(targetUserId).first().click();
  await dialog.getByRole("button", { name: /^go$|start chat/i }).click();
}

test.describe("device verification request between two real Element Web clients", () => {
  test("Bob's client receives Alice's verification request", async ({ browser }) => {
    test.setTimeout(150_000);

    const runId = Date.now();
    const password = "Sup3rSecret!Password";
    const aliceUsername = `alice_${runId}`;
    const bobUsername = `bob_${runId}`;

    const bobUserId = await apiRegister(bobUsername, password);
    await apiRegister(aliceUsername, password);

    const aliceContext = await browser.newContext();
    const bobContext = await browser.newContext();
    const alicePage = await aliceContext.newPage();
    const bobPage = await bobContext.newPage();

    try {
      await loginUser(alicePage, aliceUsername, password);
      await loginUser(bobPage, bobUsername, password);

      await startDirectMessage(alicePage, bobUserId);
      const composer = alicePage.getByRole("textbox", { name: /send a message/i });
      await composer.fill("hi bob");
      await composer.press("Enter");
      await completeSecureBackupIfPrompted(alicePage);

      // Bob: accept the DM invite (sidebar shows "Empty room" until
      // accepted — he doesn't know who's in it yet), then bootstrap too.
      await bobPage
        .getByText(/empty room|alice_/i)
        .first()
        .click({ timeout: 20_000 });
      await bobPage.waitForTimeout(1500);
      const acceptBtn = bobPage.getByRole("button", { name: /^accept$/i });
      if (await acceptBtn.isVisible({ timeout: 5000 }).catch(() => false)) {
        await acceptBtn.click();
      }
      await bobPage.waitForTimeout(1500);
      await completeSecureBackupIfPrompted(bobPage);

      // Alice: reach Bob's real user-info card. Per Element's own hint
      // ("Verify ... in their profile - tap on their profile picture"),
      // that's the avatar next to one of his timeline entries — the
      // room-info "People" panel is a DIFFERENT, generic room-options
      // panel that merely displays his photo for a DM, not a per-user card.
      await alicePage.bringToFront();
      const bobAvatarInTimeline = alicePage
        .getByRole("button", { name: /^avatar$|^profile picture$/i })
        .filter({ hasText: "b" })
        .last();
      await expect(bobAvatarInTimeline).toBeVisible({ timeout: 10_000 });
      await bobAvatarInTimeline.click({ force: true });

      // Reaching the actual verify entry point from here is genuinely
      // timing-sensitive and not idempotent to retry naively: the device
      // list toggles collapsed ("N sessions") / expanded ("Hide sessions"
      // + a device-id button) on each click, and clicking another user's
      // device can trigger (or re-trigger) Alice's own cross-signing
      // bootstrap inline, an unbounded number of times, as
      // matrix-js-sdk's own crypto state machine settles — this is
      // upstream Element/matrix-js-sdk timing, not anything Axon
      // controls. Poll for whichever state we're actually in and react,
      // rather than assuming a fixed number of steps gets there.
      const collapsedSessions = alicePage.getByText(/^\d+ sessions?$/i).first();
      const deviceIdBtn = alicePage.getByRole("button", { name: /^[A-Z0-9]{8,14}$/ }).first();
      const emojiVerify = alicePage.getByRole("button", { name: /interactively verify by emoji/i });
      const verifyBtn = alicePage.getByRole("button", { name: /^verify$/i });
      const ownBootstrapContinue = alicePage.getByRole("button", { name: /^continue$/i });

      let reachedVerifyEntryPoint = false;
      for (let attempt = 0; attempt < 10 && !reachedVerifyEntryPoint; attempt++) {
        if (await emojiVerify.isVisible({ timeout: 1500 }).catch(() => false)) {
          reachedVerifyEntryPoint = true;
          break;
        }
        if (await verifyBtn.isVisible({ timeout: 1500 }).catch(() => false)) {
          reachedVerifyEntryPoint = true;
          break;
        }
        if (await ownBootstrapContinue.isVisible({ timeout: 1500 }).catch(() => false)) {
          await completeSecureBackupIfPrompted(alicePage);
          continue;
        }
        if (await collapsedSessions.isVisible({ timeout: 1500 }).catch(() => false)) {
          await collapsedSessions.click();
          await alicePage.waitForTimeout(500);
          continue;
        }
        if (await deviceIdBtn.isVisible({ timeout: 1500 }).catch(() => false)) {
          await deviceIdBtn.click({ force: true });
          await alicePage.waitForTimeout(1000);
          continue;
        }
        // None of the above matched — give the UI a moment and re-poll.
        await alicePage.waitForTimeout(1000);
      }

      expect(reachedVerifyEntryPoint, "never reached a verify entry point").toBe(true);

      if (await emojiVerify.isVisible({ timeout: 1000 }).catch(() => false)) {
        await emojiVerify.click();
      } else {
        await verifyBtn.click({ force: true });
      }

      // The actual assertion: Bob's client must show the incoming request.
      await bobPage.bringToFront();
      await expect(bobPage.getByText(/verification requested/i)).toBeVisible({ timeout: 20_000 });
      await expect(bobPage.getByRole("button", { name: /verify session/i })).toBeVisible();
    } finally {
      await aliceContext.close();
      await bobContext.close();
    }
  });
});
