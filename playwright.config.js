// @ts-check
const { defineConfig, devices } = require("@playwright/test");

// Stage 4 and Stage 7 (docs/PIPELINE-SPEC.md) both run this suite, against a
// container in Stage 4 and against the live Pages URL in Stage 7. The target
// is selected purely via env var — no code branching needed here.
const baseURL = process.env.PLAYWRIGHT_BASE_URL || "http://localhost:8080";

module.exports = defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: false, // tests share localStorage state in the same origin
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: process.env.CI
    ? [["html", { open: "never" }], ["list"]]
    : "list",
  timeout: 30_000,
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
