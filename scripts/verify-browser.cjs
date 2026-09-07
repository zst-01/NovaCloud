// Browser acceptance harness; uses an already installed Playwright library, not a test framework.
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE);
const root = path.resolve(__dirname, '..');
const password = fs.readFileSync(path.join(root, '.env'), 'utf8').split(/\r?\n/).find(line => line.startsWith('DEMO_PASSWORD=')).slice(14);
const tokens = new Set();
const check = (value, label) => { if (!value) throw new Error(label); };
(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const context = await browser.newContext({ viewport: { width: 1360, height: 1000 } });
  const page = await context.newPage();
  const runtimeErrors = [];
  page.on('pageerror', error => runtimeErrors.push(error.name));
  page.on('request', req => { const header = req.headers().authorization; if (header) tokens.add(header.slice(7)); });
  const base = process.env.LAB_BASE_URL || 'http://127.0.0.1:18080';
  const output = path.join(root, 'output', 'playwright');
  fs.mkdirSync(output, { recursive: true });
  const status = async code => page.waitForFunction(code => document.querySelector('#request-status').textContent === String(code), code);
  const login = async (username, secret = password) => {
    await page.locator('#username').fill(username);
    await page.locator('#password').fill(secret);
    await page.locator('#login-button').click();
  };
  const query = async id => {
    await page.locator('#ticket-id').fill(id);
    await page.locator('#query-button').click();
  };
  try {
    await page.goto(base);
    check(await page.locator('#query-button').isDisabled(), 'Anonymous query must be disabled');
    await login('demo', 'browser-test-wrong'); await status(401);
    check((await page.locator('#login-notice').textContent()).includes('账号或密码'), 'Wrong password message');
    await login('demo');
    await page.locator('#signed-in').waitFor({ state: 'visible' });
    check(await page.locator('#current-user').textContent() === 'demo', 'Current account');
    check(await page.locator('#password').inputValue() === '', 'Password must be cleared');
    await query('1'); await page.locator('#ticket-result').waitFor({ state: 'visible' });
    check((await page.locator('#ticket-title').textContent()) === 'Demo after-sales ticket', 'Real MySQL ticket');
    check(/^[a-f0-9]{32}$/.test(await page.locator('#request-trace').textContent()), 'Real TraceId');
    await page.screenshot({ path: path.join(output, 'workbench-result.png'), fullPage: true });
    await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: base });
    await page.locator('#copy-trace').click();
    await page.waitForFunction(() => document.querySelector('#copy-notice').textContent.includes('已复制'));
    await query('999999'); await status(404);
    check(await page.locator('#ticket-result').isHidden(), 'Old ticket hidden after 404');
    await query('0');
    check((await page.locator('#query-notice').textContent()).includes('正整数'), 'Invalid ID hint');
    await query('1'); await page.locator('#ticket-result').waitFor({ state: 'visible' });
    await page.setViewportSize({ width: 390, height: 844 });
    check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Mobile horizontal overflow');
    await page.screenshot({ path: path.join(output, 'workbench-mobile.png'), fullPage: true });
    await page.setViewportSize({ width: 1360, height: 1000 });
    await query('0');
    check(await page.locator('#ticket-title').textContent() === '', 'Invalid ID clears old result');
    await page.locator('#logout-button').click(); await page.locator('#signed-out').waitFor({ state: 'visible' });
    check(await page.locator('#ticket-result').isHidden(), 'Logout clears ticket');
    console.log('PASS real browser: login, MySQL query, 404, ID validation, TraceId copy, logout, mobile layout');
    await login('observer'); await page.locator('#signed-in').waitFor({ state: 'visible' });
    await query('1'); await status(403);
    check((await page.locator('#query-notice').textContent()).includes('没有工单查询权限'), '403 hint');
    const observerToken = [...tokens].at(-1);
    await context.request.post(base + '/api/auth/logout', { headers: { Authorization: 'Bearer ' + observerToken } });
    await query('1'); await status(401);
    check(await page.locator('#signed-out').isVisible(), '401 clears authentication');
    check(await page.locator('#login-notice').isHidden(), '401 clears stale login-success message');
    console.log('PASS real browser: observer permission denial and revoked session');
    await login('demo'); await page.locator('#signed-in').waitFor({ state: 'visible' });
    const mockTrace = 'b'.repeat(32);
    await page.route('**/api/tickets/*', route => route.fulfill({ status:429, contentType:'application/json',
      headers:{'Retry-After':'2','X-Trace-Id':mockTrace}, body:'{"error":"rate_limited","retryAfter":2}' }));
    await query('1'); await status(429);
    check(await page.locator('#query-button').isDisabled(), '429 query cooldown');
    await page.waitForFunction(() => !document.querySelector('#query-button').disabled);
    await page.unroute('**/api/tickets/*');
    await page.route('**/api/tickets/*', route => route.abort());
    await query('1');
    await page.waitForFunction(() => document.querySelector('#query-notice').textContent.includes('无法连接'));
    check(await page.locator('#signed-in').isVisible(), 'Network error preserves session');
    await page.unroute('**/api/tickets/*');
    await page.route('**/api/tickets/*', route => route.fulfill({status:200,contentType:'application/json',
      body:JSON.stringify({id:1,title:'<img src=x onerror=alert(1)>',status:'OPEN'})}));
    await query('1'); await page.locator('#ticket-result').waitFor({state:'visible'});
    check(await page.locator('#ticket-result img').count() === 0, 'Untrusted title rendered as text');
    await page.unroute('**/api/tickets/*');
    await page.route('**/api/auth/logout', route => route.fulfill({status:503,contentType:'application/json',body:'{"error":"unavailable"}'}));
    await page.locator('#logout-button').click(); await status(503);
    check(await page.locator('#signed-in').isVisible(), 'Failed logout must preserve retryable session');
    await page.unroute('**/api/auth/logout');
    await page.locator('#logout-button').click(); await page.locator('#signed-out').waitFor({state:'visible'});
    await page.route('**/api/auth/login', route => route.fulfill({status:429,contentType:'application/json',
      headers:{'Retry-After':'2'},body:'{"error":"rate_limited"}'}));
    await login('demo','not-a-secret'); await status(429);
    check(await page.locator('#login-button').isDisabled(), 'Login cooldown');
    await page.waitForFunction(() => !document.querySelector('#login-button').disabled);
    await page.unroute('**/api/auth/login');
    await login('demo'); await page.locator('#signed-in').waitFor({state:'visible'});
    await page.reload();
    check(await page.locator('#query-button').isDisabled(), 'Reload clears in-memory login');
    check(await page.evaluate(() => localStorage.length === 0 && sessionStorage.length === 0), 'No persisted credentials');
    check(runtimeErrors.length === 0, 'No uncaught JavaScript errors');
    console.log('PASS simulated responses: login/query 429 countdown, network failure, safe title rendering, failed logout');
    console.log('PASS real browser: refresh clears login; no persistent credentials or uncaught JavaScript errors');
  } finally {
    for (const token of tokens) {
      await context.request.post(base + '/api/auth/logout', {headers:{Authorization:'Bearer '+token}}).catch(() => {});
    }
    await browser.close();
  }
})().catch(error => {
  let message = error.message.replaceAll(password, '[redacted]');
  for (const token of tokens) message = message.replaceAll(token, '[redacted]');
  console.error(message); process.exitCode = 1;
});
