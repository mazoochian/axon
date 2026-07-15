import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  timeout: 60_000,
  expect: { timeout: 15_000 },
  // Registration/DM flows below share no state, but keeping this serial
  // (rather than parallelizing workers) avoids competing for the same
  // single Axon/Postgres instance while the harness is new and unproven.
  fullyParallel: false,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    // Element Web is always published on :8080 by docker-compose.yml,
    // regardless of whether the "local" or "ci" profile started it.
    baseURL: "http://localhost:8080",
    trace: "retain-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
