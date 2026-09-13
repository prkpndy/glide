// Drives the app against a running fork + dev server: ship from the UI, time travel, arb, swap via Uniswap.
//   SHOTS=/path/to/dir node scripts/e2e.mjs
import { chromium } from "playwright";
import { mkdirSync } from "node:fs";

const base = process.env.BASE_URL ?? "http://localhost:3000";
const shots = process.env.SHOTS ?? "./e2e-shots";
mkdirSync(shots, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
page.on("pageerror", (e) => console.log("PAGE ERROR:", e.message));
page.on("console", (m) => { if (m.type() === "error") console.log("CONSOLE ERROR:", m.text().slice(0, 300)); });

const ready = () => page.waitForFunction(() => document.body.innerText.includes("block "), null, { timeout: 30000 });
const role = async (r) => { await page.locator(".role button", { hasText: r }).click(); };
const shot = (name) => page.screenshot({ path: `${shots}/${name}.png`, fullPage: true });

console.log("1. create page");
await page.goto(base + "/");
await ready();
await page.waitForFunction(() => document.body.innerText.includes("Start share is derived"), null, { timeout: 30000 });
await page.locator("select").first().selectOption(process.env.SHAPE ?? "s-curve");
await page.waitForTimeout(500);
await shot("1-create");
const ship = page.getByRole("button", { name: /Approve & ship/ });
await page.waitForFunction(() => { const b = [...document.querySelectorAll("button")].find((x) => x.textContent.includes("Approve & ship")); return b && !b.disabled; }, null, { timeout: 30000 });
await ship.click();
await page.waitForURL(/\/position/, { timeout: 120000 });
await page.waitForFunction(() => document.body.innerText.includes("live"), null, { timeout: 30000 });
await page.waitForTimeout(3500);
await shot("2-position-fresh");
console.log("   shipped, position page shows:", (await page.locator(".stats").innerText()).replace(/\n+/g, " | ").slice(0, 300));

console.log("2. demo: time travel + arb");
await page.goto(base + "/demo");
await ready();
await role("taker");
await page.getByRole("button", { name: "+6h" }).click();
await page.waitForFunction(() => document.body.innerText.includes("advanced chain time"), null, { timeout: 30000 });
await page.getByRole("button", { name: /Arb until/ }).click();
await page.waitForFunction(() => /within \d+ bps/.test(document.body.innerText) || document.querySelector(".log .err"), null, { timeout: 240000 });
console.log("   arb log:\n" + (await page.locator(".log").innerText()).split("\n").map((l) => "     " + l).join("\n"));

console.log("3. demo: swap via Uniswap");
await page.getByRole("button", { name: "Swap", exact: true }).click();
await page.waitForFunction(() => document.body.innerText.includes("filled from the maker") || document.querySelectorAll(".log .err").length > 0, null, { timeout: 120000 });
await shot("3-demo");
console.log("   last log line:", (await page.locator(".log").innerText()).trim().split("\n").pop());

console.log("4. position page after trading");
await page.goto(base + "/position");
await ready();
await page.waitForFunction(() => document.querySelectorAll("tbody tr").length > 2, null, { timeout: 30000 });
await page.waitForTimeout(2000);
await shot("4-position-after");
console.log("   stats:", (await page.locator(".stats").innerText()).replace(/\n+/g, " | ").slice(0, 400));
console.log("   trades rows:", await page.locator(".card:has-text('Trades') tbody tr").count());

await browser.close();
console.log("done, screenshots in", shots);
