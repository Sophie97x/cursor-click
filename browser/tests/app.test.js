'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createServer, SessionManager, isLocalHost, validateStartRequest } = require('../server');

test('replay overflow pauses sync and discards queued stale actions', async () => {
  const manager = new SessionManager();
  let release;
  let enteredResolve;
  const entered = new Promise((resolve) => { enteredResolve = resolve; });
  manager.replayed = [];
  manager.mirrorAction = async (action) => {
    manager.replayed.push(action.id);
    if (action.id === 0) {
      enteredResolve();
      await new Promise((resolveRelease) => { release = resolveRelease; });
    }
  };
  manager.enqueueAction({ id: 0 });
  await entered;
  for (let id = 1; id < 130; id += 1) manager.enqueueAction({ id });
  assert.equal(manager.pendingActions.length, 0);
  assert.equal(manager.syncEnabled, false);
  release();
  await manager.actionQueue;
  assert.deepEqual(manager.replayed, [0]);
});

test('local host recognition is limited to loopback names', () => {
  assert.equal(isLocalHost('localhost'), true);
  assert.equal(isLocalHost('127.0.0.1'), true);
  assert.equal(isLocalHost('demo.localhost'), true);
  assert.equal(isLocalHost('example.com'), false);
});

test('external URLs require Yes; Yes authorizes and No is rejected', () => {
  const no = validateStartRequest({ url: 'https://example.com', count: 1, authorized: false });
  assert.equal(no.status, 403);
  assert.match(no.error, /explicit permission/);

  const yes = validateStartRequest({ url: 'https://example.com', count: 1, authorized: true });
  assert.deepEqual(yes, { url: 'https://example.com/', count: 1 });
});

test('localhost URLs work without an authorization confirmation', () => {
  assert.deepEqual(
    validateStartRequest({ url: 'http://localhost:3000/test', count: 5, authorized: false }),
    { url: 'http://localhost:3000/test', count: 5 },
  );
});

test('dashboard Yes proceeds while No blocks, and a new external URL resets to No', async (t) => {
  const app = createServer({ headless: true, openBrowser: false, port: 0 });
  const url = await app.listen();
  const browser = await app.manager.ensureBrowser();
  t.after(() => app.close());

  const page = await browser.newPage();
  const requests = [];
  await page.route('**/api/start', async (route) => {
    requests.push(JSON.parse(route.request().postData()));
    await route.fulfill({ status: 202, contentType: 'application/json', body: JSON.stringify({ accepted: true }) });
  });
  await page.goto(url);
  assert.equal(await page.locator('#authorization-panel').isVisible(), false);

  await page.locator('#target-url').fill('https://owned.example');
  assert.equal(await page.locator('#authorization-panel').isVisible(), true);
  assert.equal(await page.locator('input[name="authorization"][value="no"]').isChecked(), true);
  await page.locator('input[name="authorization"][value="yes"]').check();
  await page.locator('#launch-form button[type="submit"]').click();
  await page.waitForFunction(() => document.querySelector('#toast').classList.contains('show'));
  assert.equal(requests.length, 1);
  assert.equal(requests[0].authorized, true);

  await page.locator('#target-url').fill('https://another-owned.example');
  assert.equal(await page.locator('input[name="authorization"][value="no"]').isChecked(), true);
  await page.locator('#launch-form button[type="submit"]').click();
  assert.equal(requests.length, 1);
  assert.match(await page.locator('#toast').textContent(), /blocked/i);
});

test('rejects cross-origin dashboard control requests', async (t) => {
  const app = createServer({ headless: true, openBrowser: false, port: 0 });
  const url = await app.listen();
  t.after(() => app.close());
  const response = await fetch(`${url}/api/sync`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Origin: 'https://untrusted.example' },
    body: JSON.stringify({ enabled: false }),
  });
  assert.equal(response.status, 403);
  assert.equal(app.manager.syncEnabled, true);
});

test('five isolated sessions mirror clicks and keyboard input, then stop', async (t) => {
  const app = createServer({ headless: true, openBrowser: false, port: 0 });
  const url = await app.listen();
  t.after(() => app.close());

  const response = await fetch(`${url}/api/start`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url: `${url}/test`, count: 5, authorized: false }),
  });
  assert.equal(response.status, 202);
  for (let attempt = 0; attempt < 120 && app.manager.status().activeCount !== 5; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(app.manager.status().activeCount, 5);
  const sessions = app.manager.sessions;
  assert.equal(new Set(sessions.map((session) => session.context)).size, 5);

  await sessions[0].page.evaluate(() => {
    localStorage.setItem('private-value', 'master-only');
    sessionStorage.setItem('private-value', 'master-only');
    document.cookie = 'private-cookie=master-only; path=/';
  });
  for (const session of sessions.slice(1)) {
    const storage = await session.page.evaluate(() => ({
      local: localStorage.getItem('private-value'),
      session: sessionStorage.getItem('private-value'),
      cookie: document.cookie.includes('private-cookie='),
    }));
    assert.deepEqual(storage, { local: null, session: null, cookie: false });
  }

  const master = sessions[0].page;
  await master.getByRole('button', { name: 'Count a click' }).click();
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const counts = await Promise.all(sessions.map((session) => session.page.locator('#count').textContent()));
    if (counts.every((count) => count === '1')) break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.deepEqual(await Promise.all(sessions.map((session) => session.page.locator('#count').textContent())), ['1', '1', '1', '1', '1']);

  await master.locator('#keyboard-test').click();
  await master.keyboard.type('mirrored');
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const values = await Promise.all(sessions.map((session) => session.page.locator('#keyboard-test').inputValue()));
    if (values.every((value) => value === 'mirrored')) break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.deepEqual(await Promise.all(sessions.map((session) => session.page.locator('#keyboard-test').inputValue())), Array(5).fill('mirrored'));

  await app.manager.stop();
  assert.equal(app.manager.status().activeCount, 0);
  assert.equal(app.manager.browser, null);
});
