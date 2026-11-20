'use strict';

const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { execFile, execFileSync } = require('node:child_process');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);
const MAX_SESSIONS = 40;
const VIEWPORT = { width: 1280, height: 800 };
const PUBLIC_DIR = path.join(__dirname, 'public');

function isLocalHost(hostname) {
  const host = String(hostname).toLowerCase().replace(/^\[|\]$/g, '');
  return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host.endsWith('.localhost');
}

function validateStartRequest(body) {
  let target;
  try {
    target = new URL(body.url);
  } catch {
    return { error: 'Enter a valid http:// or https:// URL.', status: 400 };
  }
  if (!['http:', 'https:'].includes(target.protocol) || target.username || target.password) {
    return { error: 'Only http:// and https:// URLs without embedded credentials are supported.', status: 400 };
  }
  const count = Number(body.count);
  if (!Number.isInteger(count) || count < 1 || count > MAX_SESSIONS) {
    return { error: `Session count must be between 1 and ${MAX_SESSIONS}.`, status: 400 };
  }
  if (!isLocalHost(target.hostname) && body.authorized !== true) {
    return {
      error: 'External website automation is blocked. Confirm that you own the website or have explicit permission to test it.',
      status: 403,
    };
  }
  return { url: target.href, count };
}

function findChrome() {
  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    path.join(os.homedir(), 'Applications/Google Chrome.app/Contents/MacOS/Google Chrome'),
  ];
  return candidates.find((candidate) => fs.existsSync(candidate));
}

class SessionManager {
  constructor({ headless = false, refreshGate, refreshInterval = 8 * 60 * 60 * 1000 } = {}) {
    this.headless = headless;
    this.refreshGate = refreshGate;
    this.refreshInterval = refreshInterval;
    this.refreshTimer = null;
    this.refreshing = false;
    this.browser = null;
    this.browserCdp = null;
    this.followerBrowser = null;
    this.browserPids = new Map();
    this.sessions = [];
    this.syncEnabled = true;
    this.stopping = false;
    this.startPromise = null;
    this.stopPromise = null;
    this.actionQueue = Promise.resolve();
    this.nextId = 1;
    this.logs = [];
    this.log('info', 'Dashboard ready. Start with the local test page or an authorized website.');
  }

  log(level, message) {
    this.logs.unshift({ time: new Date().toISOString(), level, message });
    this.logs.length = Math.min(this.logs.length, 100);
  }

  async ensureBrowser(follower = false) {
    const slot = follower ? 'followerBrowser' : 'browser';
    if (this[slot]?.isConnected()) return this[slot];
    const headless = follower || this.headless;

    const chromePath = findChrome();
    const localBrowserPath = process.env.PLAYWRIGHT_BROWSERS_PATH || path.join(__dirname, '.playwright-browsers');
    if (!chromePath) process.env.PLAYWRIGHT_BROWSERS_PATH = localBrowserPath;
    const { chromium } = require('playwright');
    let executablePath = chromePath || chromium.executablePath();
    if (!fs.existsSync(executablePath)) {
      if (chromePath) throw new Error(`Chrome executable not found: ${chromePath}`);
      const cliPath = path.join(path.dirname(require.resolve('playwright/package.json')), 'cli.js');
      this.log('info', 'Installing Playwright Chromium into this project.');
      await execFileAsync(process.execPath, [cliPath, 'install', 'chromium'], {
        env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: localBrowserPath },
        maxBuffer: 8 * 1024 * 1024,
      });
      executablePath = chromium.executablePath();
    }

    const browser = await chromium.launch({
      executablePath,
      headless,
      args: ['--disable-extensions'],
    });
    this[slot] = browser;
    browser.once('disconnected', () => {
      if (this[slot] !== browser) return;
      this[slot] = null;
      this.browserPids.delete(browser);
      if (!follower) this.browserCdp = null;
      if (!this.stopping) {
        this.log('warning', 'A browser process disconnected; ending the managed sessions.');
        this.stop().catch((error) => this.log('error', error.message));
      }
    });
    const cdp = await browser.newBrowserCDPSession();
    try {
      const { processInfo } = await cdp.send('SystemInfo.getProcessInfo');
      const pid = processInfo.find(({ type }) => type === 'browser')?.id;
      if (pid && browser.isConnected()) this.browserPids.set(browser, pid);
    } catch (error) {
      this.log('warning', `Could not identify the browser process: ${error.message}`);
    } finally {
      if (headless) await cdp.detach().catch(() => {});
      else if (browser.isConnected()) this.browserCdp = cdp;
    }
    this.log('success', headless ? 'Started a background browser process.' : 'Started the visible master browser.');
    return browser;
  }

  async start(url, count, headless = this.headless) {
    if (this.startPromise) return this.startPromise;
    if (this.stopPromise) throw new Error('Wait for browsers to stop.');
    if (this.refreshing) throw new Error('Wait for the tab refresh to finish.');
    this.stopping = false;
    if (!this.browser?.isConnected()) this.headless = headless;
    if (!this.browser?.isConnected() && this.refreshGate) {
      if (fs.existsSync(this.refreshGate)) fs.unlinkSync(this.refreshGate);
    }
    this.startPromise = this.startSessions(url, count);
    try {
      return await this.startPromise;
    } finally {
      this.startPromise = null;
    }
  }

  async startSessions(url, count) {
    const masterBrowser = await this.ensureBrowser();
    if (this.sessions.length > count) {
      const excess = this.sessions.splice(count);
      for (const session of excess) await session.context?.close().catch((error) => {
        this.log('warning', `Could not close session ${session.id}: ${error.message}`);
      });
    }

    while (!this.stopping && this.sessions.length < count) {
      const session = { id: this.nextId++, status: 'starting', url, error: null, context: null, page: null };
      this.sessions.push(session);
      try {
        const follower = !this.headless && this.sessions[0] !== session;
        const browser = follower ? await this.ensureBrowser(true) : masterBrowser;
        if (this.stopping) break;
        const context = await browser.newContext({ viewport: VIEWPORT });
        session.context = context;
        await context.exposeBinding('__automationMirror', ({ page }, action) => this.receiveAction(page, action));
        await context.addInitScript(() => {
          window.__mirrorApplying = false;
          const send = (payload) => {
            if (!window.__mirrorApplying && typeof window.__automationMirror === 'function') {
              window.__automationMirror(payload).catch(() => {});
            }
          };
          document.addEventListener('click', (event) => {
            if (event.detail === 0) return;
            send({
              type: 'click', x: event.clientX, y: event.clientY, button: event.button,
              modifiers: { alt: event.altKey, ctrl: event.ctrlKey, meta: event.metaKey, shift: event.shiftKey },
            });
          }, true);
          document.addEventListener('keydown', (event) => {
            send({ type: 'key', phase: 'down', key: event.key === ' ' ? 'Space' : event.key });
          }, true);
          document.addEventListener('keyup', (event) => {
            send({ type: 'key', phase: 'up', key: event.key === ' ' ? 'Space' : event.key });
          }, true);
          window.addEventListener('wheel', (event) => {
            send({ type: 'wheel', x: event.clientX, y: event.clientY, deltaX: event.deltaX, deltaY: event.deltaY });
          }, { capture: true, passive: true });
        });
        const page = await context.newPage();
        session.page = page;
        page.on('framenavigated', (frame) => {
          if (frame === page.mainFrame()) {
            session.url = frame.url();
            if (!this.refreshing && this.sessions[0] === session) this.enqueue(() => this.mirrorNavigation(frame.url()));
          }
        });
        page.on('pageerror', (error) => this.log('warning', `Session ${session.id}: ${error.message}`));
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
        session.url = page.url();
        session.status = 'active';
        this.log('success', `Session ${session.id} opened ${session.url}`);
      } catch (error) {
        session.status = 'error';
        session.error = error.message;
        this.log('error', `Session ${session.id} failed: ${error.message}`);
        if (!session.context) break;
      }
    }
    await this.focusMaster().catch((error) => this.log('warning', `Could not show the master Chrome window: ${error.message}`));
    if (!this.stopping) this.log('info', `Startup finished: ${this.sessions.filter((item) => item.status === 'active').length} active session(s).`);
    if (!this.stopping) this.scheduleRefresh();
    return this.status();
  }

  scheduleRefresh() {
    if (!this.refreshGate || this.refreshTimer || !this.sessions.length) return;
    this.refreshTimer = setTimeout(async () => {
      this.refreshTimer = null;
      await this.refreshTabs();
      if (!this.stopping && this.browser?.isConnected()) this.scheduleRefresh();
    }, this.refreshInterval);
    this.refreshTimer.unref();
  }

  async refreshTabs() {
    if (this.stopping || !this.sessions.length || this.refreshing) return;
    const gate = this.refreshGate;
    const busy = path.join(path.dirname(gate), 'clicker-busy');
    const deadline = Date.now() + 5000;
    this.refreshing = true;
    this.log('info', 'Pausing the clicker to refresh browser tabs.');
    try {
      fs.writeFileSync(gate, 'paused');
      while (fs.existsSync(busy)) {
        if (Date.now() >= deadline) throw new Error('The clicker did not finish its current input.');
        await new Promise((resolve) => setTimeout(resolve, 30));
      }
      const pages = this.sessions.flatMap(({ context }) => context?.pages().filter((page) => !page.isClosed()) ?? []);
      if (!pages.length) throw new Error('There are no open tabs.');
      for (let i = 0; i < pages.length; i += 4) {
        if (this.stopping || !this.browser?.isConnected()) throw new Error('The browser stopped during refresh.');
        const results = await Promise.allSettled(pages.slice(i, i + 4).map((page) =>
          page.reload({ waitUntil: 'load', timeout: 45_000 })
        ));
        const failed = results.find((result) => result.status === 'rejected');
        if (failed) throw failed.reason;
      }
      if (this.stopping || !this.browser?.isConnected()) throw new Error('The browser stopped during refresh.');
      fs.unlinkSync(gate);
      this.log('success', `Refreshed ${pages.length} tabs. The clicker may resume.`);
    } catch (error) {
      try {
        fs.writeFileSync(gate, 'failed');
      } catch (gateError) {
        this.log('error', `Could not update the clicker pause: ${gateError.message}`);
      }
      this.log('error', `Tab refresh failed: ${error.message}. Stop and restart browser sessions before starting the clicker again.`);
    } finally {
      this.refreshing = false;
    }
  }

  async focusMaster() {
    const master = this.sessions[0];
    if (this.headless || !master?.page || master.page.isClosed()) return;
    const pageCdp = await master.context.newCDPSession(master.page);
    try {
      const { targetInfo } = await pageCdp.send('Target.getTargetInfo');
      const { windowId, bounds } = await this.browserCdp.send('Browser.getWindowForTarget', {
        targetId: targetInfo.targetId,
      });
      if (bounds.windowState === 'minimized') {
        await this.browserCdp.send('Browser.setWindowBounds', {
          windowId, bounds: { windowState: 'normal' },
        });
      }
      await master.page.bringToFront();
    } finally {
      await pageCdp.detach().catch(() => {});
    }
  }

  receiveAction(sourcePage, action) {
    if (this.refreshing || !this.syncEnabled || this.sessions[0]?.page !== sourcePage || !action) return;
    this.enqueue(() => this.mirrorAction(action));
  }

  enqueue(operation) {
    this.actionQueue = this.actionQueue.then(operation).catch((error) => {
      this.log('error', `Synchronized action failed: ${error.message}`);
    });
  }

  async mirrorAction(action) {
    if (this.refreshing || !this.syncEnabled) return;
    const followers = this.sessions.slice(1).filter((session) => session.status === 'active' && session.page);
    await Promise.all(followers.map(async ({ id, page }) => {
      try {
        await page.evaluate(() => { window.__mirrorApplying = true; });
        if (action.type === 'click') {
          const modifiers = Object.entries(action.modifiers || {})
            .filter(([, enabled]) => enabled)
            .map(([name]) => ({ alt: 'Alt', ctrl: 'Control', meta: 'Meta', shift: 'Shift' })[name]);
          await page.mouse.click(action.x, action.y, {
            button: ['left', 'middle', 'right'][action.button] || 'left',
            modifiers,
          });
        } else if (action.type === 'key' && action.phase === 'down') {
          await page.keyboard.down(action.key);
        } else if (action.type === 'key' && action.phase === 'up') {
          await page.keyboard.up(action.key);
        } else if (action.type === 'wheel') {
          await page.mouse.move(action.x, action.y);
          await page.mouse.wheel(action.deltaX, action.deltaY);
        }
      } catch (error) {
        this.log('warning', `Could not mirror ${action.type} to session ${id}: ${error.message}`);
      } finally {
        if (!page.isClosed()) await page.evaluate(() => { window.__mirrorApplying = false; }).catch(() => {});
      }
    }));
  }

  async mirrorNavigation(url) {
    if (this.refreshing || !this.syncEnabled) return;
    await Promise.all(this.sessions.slice(1)
      .filter((session) => session.status === 'active' && session.page && session.page.url() !== url)
      .map(async (session) => {
        try {
          await session.page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
          session.url = session.page.url();
        } catch (error) {
          this.log('warning', `Could not mirror navigation to session ${session.id}: ${error.message}`);
        }
      }));
  }

  setSync(enabled) {
    this.syncEnabled = enabled;
    this.log('info', `Action synchronization ${enabled ? 'enabled' : 'disabled'}.`);
    return this.status();
  }

  async stop() {
    if (this.stopPromise) return this.stopPromise;
    this.stopping = true;
    clearTimeout(this.refreshTimer);
    this.refreshTimer = null;
    this.stopPromise = this.closeBrowsers();
    try {
      return await this.stopPromise;
    } finally {
      this.stopPromise = null;
    }
  }

  async closeBrowsers() {
    const close = async () => {
      const browsers = [this.browser, this.followerBrowser];
      this.browser = null;
      this.followerBrowser = null;
      this.browserCdp = null;
      this.browserPids.clear();
      await Promise.all(browsers.filter(Boolean).map((browser) =>
        browser.close().catch((error) => this.log('warning', error.message))
      ));
    };
    await close();
    await this.startPromise?.catch(() => {});
    if (this.browser || this.followerBrowser) await close();
    this.sessions = [];
    this.log('success', 'All browser sessions have stopped.');
    return this.status();
  }

  processUsage() {
    if (!this.browserPids.size) return { cpu: 0, memoryBytes: 0 };
    try {
      const lines = execFileSync('ps', ['-axo', 'pid=,ppid=,%cpu=,rss='], { encoding: 'utf8' }).trim().split('\n');
      const processes = lines.map((line) => {
        const [pid, ppid, cpu, rss] = line.trim().split(/\s+/).map(Number);
        return { pid, ppid, cpu, rss };
      }).filter((item) => Number.isFinite(item.pid));
      const descendants = new Set(this.browserPids.values());
      let updated = true;
      while (updated) {
        updated = false;
        for (const item of processes) {
          if (!descendants.has(item.pid) && descendants.has(item.ppid)) {
            descendants.add(item.pid);
            updated = true;
          }
        }
      }
      const family = processes.filter((item) => descendants.has(item.pid));
      return {
        cpu: Math.round(family.reduce((sum, item) => sum + item.cpu, 0) * 10) / 10,
        memoryBytes: family.reduce((sum, item) => sum + item.rss * 1024, 0),
      };
    } catch (error) {
      this.log('warning', `Could not read Chromium resource usage: ${error.message}`);
      return { cpu: null, memoryBytes: null };
    }
  }

  status() {
    const usage = this.processUsage();
    return {
      sessions: this.sessions.map(({ id, status, url, error }) => ({ id, status, url, error })),
      activeCount: this.sessions.filter((session) => session.status === 'active').length,
      syncEnabled: this.syncEnabled,
      headless: this.headless,
      refreshing: this.refreshing,
      browserRunning: Boolean(this.browser?.isConnected() || this.startPromise || this.stopPromise),
      cpuPercent: usage.cpu,
      memoryBytes: usage.memoryBytes,
      memoryLimitBytes: Math.round(os.totalmem() * 0.65),
      logs: this.logs.slice(0, 60),
    };
  }
}

function sendJson(response, status, body) {
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  response.end(JSON.stringify(body));
}

async function readJson(request) {
  let body = '';
  for await (const chunk of request) {
    body += chunk;
    if (body.length > 16 * 1024) throw new Error('Request body is too large.');
  }
  return body ? JSON.parse(body) : {};
}

function createServer({ headless = process.env.HEADLESS === '1', openBrowser = true, port = 3000, refreshGate, refreshInterval } = {}) {
  const manager = new SessionManager({ headless, refreshGate, refreshInterval });
  const server = http.createServer(async (request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    try {
      let host;
      try {
        host = new URL(`http://${request.headers.host}`).hostname;
      } catch {
        return sendJson(response, 400, { error: 'Invalid Host header.' });
      }
      if (!isLocalHost(host)) return sendJson(response, 403, { error: 'This dashboard only accepts loopback requests.' });
      if (request.method === 'POST' && request.headers.origin) {
        let origin;
        try {
          origin = new URL(request.headers.origin).origin;
        } catch {
          return sendJson(response, 403, { error: 'Invalid request origin.' });
        }
        if (origin !== `http://${request.headers.host}`) return sendJson(response, 403, { error: 'Cross-origin requests are not allowed.' });
      }

      if (request.method === 'GET' && pathname === '/api/status') return sendJson(response, 200, manager.status());
      if (request.method === 'POST' && pathname === '/api/start') {
        const body = await readJson(request);
        const validation = validateStartRequest(body);
        if (validation.error) return sendJson(response, validation.status, { error: validation.error });
        if (body.background !== undefined && typeof body.background !== 'boolean') {
          return sendJson(response, 400, { error: 'background must be true or false.' });
        }
        if (body.background !== undefined && body.background !== manager.headless &&
            (manager.browser?.isConnected() || manager.startPromise)) {
          return sendJson(response, 409, { error: 'Stop browsers before changing background mode.' });
        }
        response.writeHead(202, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
        response.end(JSON.stringify({ accepted: true }));
        manager.start(validation.url, validation.count, body.background).catch((error) => manager.log('error', `Could not start sessions: ${error.message}`));
        return;
      }
      if (request.method === 'POST' && pathname === '/api/stop') {
        manager.stop().catch((error) => manager.log('error', `Could not stop sessions: ${error.message}`));
        return sendJson(response, 202, { accepted: true });
      }
      if (request.method === 'POST' && pathname === '/api/show-master') {
        if (manager.headless || !manager.sessions[0]?.page || manager.sessions[0].page.isClosed()) {
          return sendJson(response, 409, { error: 'Start browsers with background mode off to show the master window.' });
        }
        await manager.focusMaster();
        return sendJson(response, 200, { shown: true });
      }
      if (request.method === 'POST' && pathname === '/api/sync') {
        const body = await readJson(request);
        if (typeof body.enabled !== 'boolean') return sendJson(response, 400, { error: 'enabled must be true or false.' });
        return sendJson(response, 200, manager.setSync(body.enabled));
      }
      if (!['GET', 'HEAD'].includes(request.method)) return sendJson(response, 404, { error: 'Not found.' });

      const file = pathname === '/' ? 'index.html' : pathname === '/test' ? 'test.html' : path.basename(pathname);
      const contentType = {
        '.html': 'text/html; charset=utf-8',
        '.css': 'text/css; charset=utf-8',
        '.js': 'text/javascript; charset=utf-8',
      }[path.extname(file)];
      const filePath = path.join(PUBLIC_DIR, file);
      if (!contentType || !filePath.startsWith(`${PUBLIC_DIR}${path.sep}`) || !fs.existsSync(filePath)) {
        return sendJson(response, 404, { error: 'Not found.' });
      }
      response.writeHead(200, {
        'Content-Type': contentType,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'Referrer-Policy': 'no-referrer',
      });
      if (request.method === 'HEAD') return response.end();
      fs.createReadStream(filePath).pipe(response);
    } catch (error) {
      return sendJson(response, 400, { error: error.message || 'Invalid request.' });
    }
  });

  return {
    manager,
    async listen() {
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, '127.0.0.1', resolve);
      });
      const address = server.address();
      const url = `http://localhost:${address.port}`;
      manager.log('success', `Dashboard available at ${url}`);
      if (openBrowser && process.env.BROWSER_AUTOLAUNCH !== '0') {
        execFile('open', [url], (error) => {
          if (error) manager.log('warning', `Could not open a browser: ${error.message}`);
        });
      }
      return url;
    },
    async close() {
      await manager.stop();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

if (require.main === module) {
  const app = createServer();
  app.listen().then((url) => {
    console.log(`Browser Automation dashboard: ${url}`);
    console.log('Listening only on 127.0.0.1. Press Ctrl+C to stop.');
  }).catch((error) => {
    console.error(`Could not start dashboard: ${error.message}`);
    process.exitCode = 1;
  });
  const shutdown = () => app.close().finally(() => process.exit(0));
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

module.exports = { createServer, SessionManager, isLocalHost, validateStartRequest };
