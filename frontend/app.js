'use strict';
const $ = (id) => document.getElementById(id);
let token = null, user = null, busy = false, traceId = '';
const cooldown = { login: 0, query: 0 };
const remaining = (kind) => Math.max(0, Math.ceil((cooldown[kind] - Date.now()) / 1000));
function notice(kind, text, tone = 'error') {
  const node = $(kind + '-notice');
  node.textContent = text; node.dataset.tone = tone; node.hidden = !text;
}
function controls() {
  const loginWait = remaining('login'), queryWait = remaining('query');
  $('login-button').disabled = busy || loginWait > 0;
  $('login-button').textContent = loginWait ? '请等待 ' + loginWait + ' 秒' : busy ? '处理中…' : '登录工作台 ↗';
  $('query-button').disabled = busy || !token || queryWait > 0;
  $('query-button').textContent = queryWait ? '请等待 ' + queryWait + ' 秒' : busy ? '处理中…' : '查询工单 →';
  $('logout-button').disabled = busy;
  for (const id of ['username', 'password', 'ticket-id']) $(id).disabled = busy;
}
function clearTicket() {
  $('ticket-result').hidden = true; $('empty-state').hidden = false;
  for (const id of ['ticket-title', 'result-id', 'ticket-status']) $(id).textContent = '';
}
function signedOut() {
  token = null; user = null; cooldown.query = 0;
  notice('login', ''); notice('query', '');
  $('signed-in').hidden = true; $('signed-out').hidden = false;
  $('session-badge').textContent = '未登录'; $('session-badge').className = 'badge';
  $('current-user').textContent = ''; $('permissions').textContent = '';
  $('password').value = ''; clearTicket();
  $('empty-title').textContent = '准备好，开始第一次查询';
  $('empty-description').textContent = '先在左侧登录，工单详情将在这里显示。';
  controls();
}
function signedIn(profile) {
  user = profile;
  $('signed-out').hidden = true; $('signed-in').hidden = false;
  $('session-badge').textContent = '已登录'; $('session-badge').className = 'badge success';
  $('current-user').textContent = profile.username;
  $('permissions').textContent = profile.permissions.includes('ticket:read') ? '权限：工单查询' : '权限：无工单查询权限';
  $('empty-title').textContent = '选择一个工单，查看详情';
  $('empty-description').textContent = '输入工单编号，点击“查询工单”。';
}
async function request(path, method = 'GET', body) {
  const controller = new AbortController(), start = performance.now();
  const timer = setTimeout(() => controller.abort(), 15000);
  $('copy-notice').textContent = '';
  let response;
  try {
    const headers = { Accept: 'application/json' };
    if (token) headers.Authorization = 'Bearer ' + token;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    response = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: controller.signal, cache: 'no-store' });
    const data = await response.json().catch(() => null);
    if (!response.ok) throw { status: response.status, retry: response.headers.get('Retry-After') };
    if (!data) throw { invalid: true };
    return data;
  } catch (error) {
    if (error.status || error.invalid) throw error;
    throw { network: true, timeout: error.name === 'AbortError' };
  } finally {
    clearTimeout(timer);
    traceId = response?.headers.get('X-Trace-Id') || '';
    $('request-path').textContent = method + ' ' + path;
    $('request-status').textContent = response ? String(response.status) : '未收到响应';
    $('request-duration').textContent = Math.round(performance.now() - start) + ' ms';
    $('request-trace').textContent = traceId || '未返回';
    $('copy-trace').disabled = !traceId;
  }
}
function failed(kind, error, loginAttempt = false) {
  if (error.status === 401) {
    if (!loginAttempt) signedOut();
    notice(kind, loginAttempt ? '账号或密码不正确，请检查后重试。' : '登录已失效，请重新登录。');
  } else if (error.status === 403) notice(kind, '当前账号没有工单查询权限。可退出后使用 demo 账号登录。', 'warning');
  else if (error.status === 404) notice(kind, '没有找到这个工单，请检查编号后重试。', 'warning');
  else if (error.status === 429) {
    const seconds = Number(error.retry);
    if (Number.isFinite(seconds) && seconds > 0) cooldown[kind] = Date.now() + seconds * 1000;
    notice(kind, '请求过于频繁，请等待后重试。' + (seconds > 0 ? '本次需等待约 ' + Math.ceil(seconds) + ' 秒。' : ''), 'warning');
  } else if (error.status === 400) notice(kind, '输入格式不正确，请检查后重试。');
  else if (error.network) notice(kind, error.timeout ? '请求超时，请稍后重试。' : '无法连接服务，请确认 Docker 和项目已启动。');
  else notice(kind, error.invalid ? '服务返回内容异常，请稍后重试。' : '服务暂时不可用，请稍后重试。');
}
$('login-form').addEventListener('submit', async (event) => {
  event.preventDefault(); if (busy || remaining('login')) return;
  busy = true; notice('login', ''); notice('query', ''); controls();
  let loggedIn = false;
  try {
    const session = await request('/api/auth/login', 'POST', { username: $('username').value.trim(), password: $('password').value });
    if (typeof session.token !== 'string' || !/^[0-9a-f]{64}$/.test(session.token)) throw { invalid: true };
    token = session.token; loggedIn = true;
    const profile = await request('/api/auth/me');
    if (typeof profile.username !== 'string' || !Array.isArray(profile.permissions)) throw { invalid: true };
    signedIn(profile); notice('login', '登录成功，可以开始查询了。', 'success');
  } catch (error) {
    // 登录已成功但用户信息请求失败时，先尽力撤销新会话；后台 TTL 作为最终回收。
    if (token) { try { await request('/api/auth/logout', 'POST'); } catch (_) {} }
    signedOut(); failed('login', error, !loggedIn);
  } finally { $('password').value = ''; busy = false; controls(); }
});
$('ticket-form').addEventListener('submit', async (event) => {
  event.preventDefault(); if (busy || remaining('query')) return;
  if (!token) { notice('query', '请先登录后再查询。', 'warning'); return; }
  const id = $('ticket-id').value.trim();
  if (!/^[1-9][0-9]{0,18}$/.test(id) || BigInt(id) > 9223372036854775807n) { clearTicket(); notice('query', '请输入有效的正整数工单编号。'); return; }
  busy = true; clearTicket(); notice('query', ''); controls();
  try {
    const ticket = await request('/api/tickets/' + encodeURIComponent(id));
    if (typeof ticket.title !== 'string' || ticket.id === undefined || typeof ticket.status !== 'string') throw { invalid: true };
    $('ticket-title').textContent = ticket.title;
    $('result-id').textContent = '#' + ticket.id;
    $('ticket-status').textContent = ({ OPEN: '待处理', CLOSED: '已关闭', IN_PROGRESS: '处理中' })[ticket.status] || ticket.status;
    $('empty-state').hidden = true; $('ticket-result').hidden = false;
  } catch (error) { failed('query', error); }
  finally { busy = false; controls(); }
});
$('logout-button').addEventListener('click', async () => {
  if (busy || !token) return;
  busy = true; notice('login', ''); controls();
  try { await request('/api/auth/logout', 'POST'); signedOut(); notice('query', ''); notice('login', '已退出登录。', 'success'); }
  catch (error) { failed('login', error); }
  finally { busy = false; controls(); }
});
$('copy-trace').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText(traceId); $('copy-notice').textContent = 'TraceId 已复制。'; }
  catch (_) { $('copy-notice').textContent = '无法自动复制，请选中上方 TraceId 手动复制。'; }
});
setInterval(controls, 1000);
controls();
