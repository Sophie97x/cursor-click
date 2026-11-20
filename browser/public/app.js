'use strict';

const launchForm = document.querySelector('#launch-form');
const startButton = document.querySelector('#start-button');
const showMaster = document.querySelector('#show-master');
const stopButton = document.querySelector('#stop-button');
const countInput = document.querySelector('#session-count');
const urlInput = document.querySelector('#target-url');
urlInput.value = new URL('/test', window.location.origin).href;
const authorizationPanel = document.querySelector('#authorization-panel');
const authorizationExplanation = document.querySelector('#authorization-explanation');
const syncToggle = document.querySelector('#sync-toggle');
const toast = document.querySelector('#toast');
let toastTimer;
let renderedLogIds = new Set();
let lastPostedLaunchProgress;

function postLaunchProgress(payload) {
  const normalized = payload == null ? null : {
    requested: payload.requested,
    completed: payload.completed,
    failed: payload.failed,
    inProgress: payload.inProgress,
  };
  const key = JSON.stringify(normalized);
  if (key === lastPostedLaunchProgress) return;
  lastPostedLaunchProgress = key;
  window.webkit?.messageHandlers?.browserLaunchProgress?.postMessage(normalized);
}

function showToast(message, isError = false) {
  toast.textContent = message;
  toast.classList.toggle('error', isError);
  toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('show'), 4500);
}

async function api(path, body) {
  const response = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || `Request failed (${response.status}).`);
  return result;
}

function isLocalUrl(value) {
  try {
    const host = new URL(value).hostname.toLowerCase().replace(/^\[|\]$/g, '');
    return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host.endsWith('.localhost');
  } catch {
    return true;
  }
}

function selectedAuthorization() {
  return document.querySelector('input[name="authorization"]:checked')?.value || 'no';
}

function updateAuthorization() {
  const external = Boolean(urlInput.value) && !isLocalUrl(urlInput.value);
  authorizationPanel.hidden = !external;
  if (external) {
    document.querySelector('input[name="authorization"][value="no"]').checked = true;
    authorizationExplanation.textContent = 'Choose Yes only for a website you own or are explicitly authorized to test. Selecting No blocks browser startup for external websites.';
  }
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);
}

function renderSessions(sessions) {
  const rows = document.querySelector('#session-rows');
  if (!sessions.length) {
    rows.innerHTML = '<tr class="empty-row"><td colspan="4">No sessions running.</td></tr>';
    return;
  }
  rows.innerHTML = sessions.map((session, index) => {
    const role = index === 0 ? '<span class="role-master">Master</span>' : 'Follower';
    const url = escapeHtml(session.url || 'Opening page…');
    const error = session.error ? ` title="${escapeHtml(session.error)}"` : '';
    return `<tr><td>Session ${session.id}</td><td>${role}</td><td${error}><span class="status-pill ${escapeHtml(session.status)}">${escapeHtml(session.status)}</span></td><td class="url-cell" title="${url}">${url}</td></tr>`;
  }).join('');
}

function renderLogs(logs) {
  const list = document.querySelector('#log-list');
  document.querySelector('#log-count').textContent = `${logs.length} event${logs.length === 1 ? '' : 's'}`;
  if (!logs.length) {
    list.innerHTML = '<div class="empty-log">System activity will appear here.</div>';
    return;
  }
  const unseen = logs.filter((entry) => !renderedLogIds.has(`${entry.time}|${entry.message}`));
  unseen.slice().reverse().forEach((entry) => {
    if (entry.level === 'error') showToast(entry.message, true);
  });
  renderedLogIds = new Set(logs.map((entry) => `${entry.time}|${entry.message}`));
  list.innerHTML = logs.map((entry) => {
    const time = new Date(entry.time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    return `<div class="log-entry"><span class="log-time">${time}</span><span class="log-level ${escapeHtml(entry.level)}">${escapeHtml(entry.level)}</span><span class="log-message">${escapeHtml(entry.message)}</span></div>`;
  }).join('');
}

function renderStatus(status) {
  renderSessions(status.sessions);
  renderLogs(status.logs);
  document.querySelector('#active-count').textContent = status.activeCount;
  renderLaunchProgress(status.launch ?? null);
  document.querySelector('#cpu-value').innerHTML = `${status.cpuPercent ?? '—'}<small>%</small>`;
  document.querySelector('#memory-value').innerHTML = `${status.memoryBytes == null ? '—' : (status.memoryBytes / (1024 ** 3)).toFixed(2)}<small> GB</small>`;
  document.querySelector('#sync-label').textContent = status.syncEnabled ? 'Sync is on' : 'Sync is off';
  document.querySelector('.sync-indicator').classList.toggle('off', !status.syncEnabled);
  syncToggle.checked = status.syncEnabled;
  const percent = status.memoryLimitBytes ? Math.min(100, (status.memoryBytes / status.memoryLimitBytes) * 100) : 0;
  document.querySelector('#memory-bar').style.width = `${percent}%`;
  document.querySelector('#memory-foot').textContent = `${percent.toFixed(0)}% of warning threshold`;
  const warning = document.querySelector('#resource-warning');
  warning.hidden = status.memoryBytes == null || status.memoryBytes < status.memoryLimitBytes;
  if (!warning.hidden) warning.textContent = 'Chromium is using over 65% of system memory. Consider stopping some sessions.';
  startButton.disabled = status.refreshing || Boolean(status.launch?.inProgress) || status.sessions.some((session) => session.status === 'starting');
  stopButton.disabled = !status.browserRunning;
  showMaster.hidden = status.headless || status.sessions[0]?.status !== 'active';
  document.querySelector('#session-display').textContent = status.refreshing ? 'Refreshing tabs · clicker paused' : status.browserRunning
    ? (status.headless ? 'Running in the background' : 'Followers in background')
    : '';
}

function renderLaunchProgress(launch) {
  const panel = document.querySelector('#launch-progress');
  if (!launch) {
    panel.hidden = true;
    postLaunchProgress(null);
    return;
  }
  const requested = Math.max(0, Number(launch.requested) || 0);
  const completed = Math.min(requested, Math.max(0, Number(launch.completed) || 0));
  const failed = Math.min(completed, Math.max(0, Number(launch.failed) || 0));
  const inProgress = Boolean(launch.inProgress);
  postLaunchProgress({ requested, completed, failed, inProgress });
  const ready = completed - failed;
  const bar = document.querySelector('#launch-progress-bar');
  const fill = document.querySelector('#launch-progress-fill');
  bar.setAttribute('aria-valuemax', String(requested));
  bar.setAttribute('aria-valuenow', String(completed));
  fill.style.width = `${requested ? (completed / requested) * 100 : 0}%`;
  const result = `${ready} of ${requested} ready${failed ? ` · ${failed} failed` : ''}`;
  bar.setAttribute('aria-valuetext', result);
  const label = document.querySelector('#launch-progress-label');
  const message = inProgress
    ? `Starting Chrome · ${result}`
    : failed && ready === 0 ? `Launch failed · ${result}` : result;
  if (label.textContent !== message) label.textContent = message;
  panel.hidden = false;
}

launchForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const count = Number(countInput.value);
  if (!Number.isInteger(count) || count < 1 || count > 40) return showToast('Choose between 1 and 40 browser sessions.', true);
  const local = isLocalUrl(urlInput.value);
  const authorized = selectedAuthorization() === 'yes';
  if (!local && !authorized) {
    authorizationExplanation.textContent = 'Not started: select “Yes, I own it or have permission” only if you are authorized. The server independently enforces this check.';
    authorizationExplanation.classList.add('blocked');
    return showToast('External website automation was blocked. Confirm ownership or explicit permission to test.', true);
  }
  authorizationExplanation.classList.remove('blocked');
  try {
    await api('/api/start', { url: urlInput.value, count, authorized });
    refresh();
  } catch (error) {
    if (!local) {
      authorizationExplanation.textContent = `${error.message} Select Yes only if you own this website or have explicit permission to test it.`;
      authorizationExplanation.classList.add('blocked');
    }
    showToast(error.message, true);
  }
});

showMaster.addEventListener('click', async () => {
  try {
    await api('/api/show-master', {});
  } catch (error) {
    showToast(error.message, true);
  }
});

stopButton.addEventListener('click', async () => {
  try {
    await api('/api/stop', {});
    showToast('Stopping browser sessions…');
  } catch (error) {
    showToast(error.message, true);
  }
});

syncToggle.addEventListener('change', async () => {
  try {
    await api('/api/sync', { enabled: syncToggle.checked });
  } catch (error) {
    showToast(error.message, true);
  }
});

urlInput.addEventListener('input', updateAuthorization);
updateAuthorization();

async function refresh() {
  try {
    const response = await fetch('/api/status', { cache: 'no-store' });
    renderStatus(await response.json());
  } catch {
    postLaunchProgress(null);
    showToast('Lost connection to the local dashboard server.', true);
  }
}
refresh();
setInterval(refresh, 1000);
