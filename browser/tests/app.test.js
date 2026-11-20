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

test('launch progress starts before Chrome opens and reports a launch failure', async () => {
  const manager = new SessionManager();
  let failLaunch;
  manager.ensureBrowser = () => new Promise((_, reject) => { failLaunch = reject; });
  assert.equal(manager.status().launch, null);
  const startup = manager.start('http://localhost/test', 3);
  assert.deepEqual(manager.status().launch, { requested: 3, completed: 0, failed: 0, inProgress: true });
  failLaunch(new Error('Chrome did not start'));
  await assert.rejects(startup, /Chrome did not start/);
  assert.deepEqual(manager.status().launch, { requested: 3, completed: 3, failed: 3, inProgress: false });
  await manager.stop();
  assert.equal(manager.status().launch, null);
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
  assert.equal(await page.getByRole('link', { name: /open built-in test page/i }).count(), 0);
  assert.equal(await page.locator('#total-clicks').count(), 0);
  assert.equal(await page.locator('#target-url').inputValue(), `${url}/test`);

  await page.locator('#target-url').fill('https://owned.example');
  assert.equal(await page.locator('#authorization-panel').isVisible(), true);
  assert.equal(await page.locator('input[name="authorization"][value="no"]').isChecked(), true);
  await page.locator('input[name="authorization"][value="yes"]').check();
  await Promise.all([
    page.waitForResponse((response) => response.url().endsWith('/api/start')),
    page.locator('#launch-form button[type="submit"]').click(),
  ]);
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
  await app.manager.startPromise;
  assert.deepEqual(app.manager.status().launch, { requested: 5, completed: 5, failed: 0, inProgress: false });
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
  await master.bringToFront();
  await master.waitForFunction(() => document.querySelector('#managed-clicks').textContent === '5');

  await master.locator('#keyboard-test').click();
  await master.keyboard.type('mirrored');
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const values = await Promise.all(sessions.map((session) => session.page.locator('#keyboard-test').inputValue()));
    if (values.every((value) => value === 'mirrored')) break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.deepEqual(await Promise.all(sessions.map((session) => session.page.locator('#keyboard-test').inputValue())), Array(5).fill('mirrored'));
  await master.waitForFunction(() => document.querySelector('#managed-characters').textContent === '40');
  assert.equal(await master.locator('#managed-keys').textContent(), '40');
  const testStatus = await (await fetch(`${url}/api/test-status`)).json();
  assert.equal(testStatus.running, true);
  assert.deepEqual(testStatus.totals, { clicks: 5, keys: 40, characters: 40 });
  assert.deepEqual(testStatus.sessions.map(({ role }) => role), ['Main', 'Follower', 'Follower', 'Follower', 'Follower']);
  assert.deepEqual(await master.locator('#managed-rows tr').allTextContents(),
    ['1Main188', '2Follower188', '3Follower188', '4Follower188', '5Follower188']);
  assert.equal(JSON.stringify(testStatus).includes('mirrored'), false);

  app.manager.setSync(false);
  await app.manager.actionQueue;
  await master.locator('#increment').click();
  await master.waitForFunction(() => document.querySelector('#managed-clicks').textContent === '6');
  assert.deepEqual(app.manager.testStatus().sessions.map(({ clicks }) => clicks), [2, 1, 1, 1, 1]);

  await app.manager.stop();
  assert.equal(app.manager.status().activeCount, 0);
  assert.equal(app.manager.testStatus().totals.clicks, 6);
  assert.equal(app.manager.testStatus().running, false);
  assert.equal(app.manager.status().launch, null);
  assert.equal(app.manager.browser, null);
  await app.manager.start(url, 1);
  await app.manager.sessions[0].page.evaluate(() => window.__automationTestInput({ clicks: 999, characters: 999 }));
  assert.deepEqual(app.manager.testStatus(), {
    sessions: [], totals: { clicks: 0, keys: 0, characters: 0 }, running: false,
  });
});

test('repeated mouse and Space input stays synchronized without scrolling followers', async (t) => {
  const app = createServer({ headless: true, openBrowser: false, port: 0 });
  const url = await app.listen();
  t.after(() => app.close());

  const response = await fetch(`${url}/api/start`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url: `${url}/test`, count: 3, authorized: false }),
  });
  assert.equal(response.status, 202);
  for (let attempt = 0; attempt < 120 && app.manager.status().activeCount !== 3; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(app.manager.status().activeCount, 3);
  await app.manager.startPromise;

  const sessions = app.manager.sessions;
  const master = sessions[0].page;
  const button = master.locator('#increment');
  const bounds = await button.boundingBox();
  assert.ok(bounds);
  await master.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
  for (let round = 0; round < 6; round += 1) {
    await master.mouse.down();
    await master.keyboard.down('Space');
    await new Promise((resolve) => setTimeout(resolve, 25));
    await master.mouse.up();
    await master.keyboard.up('Space');
    for (const key of ['A', 'B', 'C', 'D', 'E', 'F', 'G']) {
      await master.keyboard.press(key);
    }
    await new Promise((resolve) => setTimeout(resolve, 75));
  }

  for (let attempt = 0; attempt < 80; attempt += 1) {
    const clicks = await Promise.all(sessions.map((session) => session.page.locator('#count').textContent()));
    if (clicks.every((count) => count === clicks[0])) break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const clickCounts = await Promise.all(sessions.map((session) => session.page.locator('#count').textContent()));
  assert.ok(Number(clickCounts[0]) >= 6);
  assert.deepEqual(clickCounts, Array(3).fill(clickCounts[0]));
  assert.deepEqual(await Promise.all(sessions.map((session) => session.page.evaluate(() => window.scrollY))), [0, 0, 0]);
  const testClicks = app.manager.testStatus().sessions.map(({ clicks }) => clicks);
  assert.ok(testClicks[0] >= 6);
  assert.deepEqual(testClicks, Array(3).fill(testClicks[0]));
  await app.manager.stop();
});
