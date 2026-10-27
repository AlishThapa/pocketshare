'use strict';

const CHUNK_SIZE = 8 * 1024 * 1024;
const CHUNK_RETRIES = 4;

let cwd = '';
let viewing = 'files'; // 'files' | 'trash' | 'search'

const $ = (id) => document.getElementById(id);

// --- api --------------------------------------------------------------------

async function api(path, { method = 'GET', body, raw, signal } = {}) {
  const init = { method, signal, headers: {} };

  if (raw !== undefined) {
    init.body = raw;
  } else if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }

  const res = await fetch(path, init);

  if (res.status === 401 && viewing !== 'login') {
    showLogin();
    throw new Error('signed out');
  }

  const text = await res.text();
  const data = text ? JSON.parse(text) : {};
  if (!res.ok) throw new Error(data.error || `request failed (${res.status})`);
  return data;
}

// --- formatting -------------------------------------------------------------

function humanSize(bytes) {
  if (bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const n = bytes / Math.pow(1024, i);
  return `${n < 10 && i > 0 ? n.toFixed(1) : Math.round(n)} ${units[i]}`;
}

function humanDate(ms) {
  const d = new Date(ms);
  const sameYear = d.getFullYear() === new Date().getFullYear();
  return d.toLocaleDateString(undefined, {
    day: 'numeric',
    month: 'short',
    ...(sameYear ? {} : { year: 'numeric' }),
  });
}

function joinPath(dir, name) {
  return dir ? `${dir}/${name}` : name;
}

// --- login ------------------------------------------------------------------

function showLogin() {
  viewing = 'login';
  $('app').hidden = true;
  $('login').hidden = false;
  $('login-host').textContent = location.host;
}

function showApp() {
  $('login').hidden = true;
  $('app').hidden = false;
  viewing = 'files';
  navigate('');
}

$('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = $('login-btn');
  const err = $('login-error');
  err.textContent = '';
  btn.disabled = true;
  btn.textContent = 'Signing in…';

  try {
    await api('/api/auth/login', {
      method: 'POST',
      body: { username: $('u').value, password: $('p').value },
    });
    $('p').value = '';
    showApp();
  } catch (e2) {
    err.textContent = e2.message;
  } finally {
    btn.disabled = false;
    btn.textContent = 'Sign in';
  }
});

$('btn-logout').addEventListener('click', async () => {
  try {
    await api('/api/auth/logout', { method: 'POST' });
  } catch { /* signing out locally regardless */ }
  showLogin();
});

// --- navigation -------------------------------------------------------------

async function navigate(path) {
  cwd = path;
  viewing = 'files';
  $('search').value = '';
  renderCrumbs();

  const { entries } = await api(`/api/files?path=${encodeURIComponent(path)}`);
  renderList(entries);
}

async function openTrash() {
  viewing = 'trash';
  renderCrumbs();
  const { entries } = await api('/api/trash');
  renderTrash(entries);
}

function renderCrumbs() {
  const nav = $('crumbs');
  nav.replaceChildren();

  if (viewing === 'trash') {
    const back = document.createElement('button');
    back.textContent = '← Files';
    back.onclick = () => navigate('');
    nav.append(back, Object.assign(document.createElement('span'), {
      textContent: ' / Trash',
    }));
    return;
  }

  const root = document.createElement('button');
  root.textContent = 'Home';
  root.onclick = () => navigate('');
  nav.append(root);

  let acc = '';
  for (const part of cwd.split('/').filter(Boolean)) {
    acc = joinPath(acc, part);
    const target = acc;
    nav.append(Object.assign(document.createElement('span'), { textContent: '/' }));
    const b = document.createElement('button');
    b.textContent = part;
    b.onclick = () => navigate(target);
    nav.append(b);
  }
}

// --- listing ----------------------------------------------------------------

function renderList(entries) {
  const list = $('list');
  list.replaceChildren();
  $('empty').hidden = entries.length > 0;

  for (const entry of entries) {
    list.append(fileRow(entry));
  }
}

function fileRow(entry) {
  const row = document.createElement('div');
  row.className = 'row';

  const icon = document.createElement('span');
  icon.className = 'icon';
  icon.textContent = entry.isDir ? '📁' : '📄';

  // textContent, never innerHTML: a filename is attacker-controlled input and
  // would otherwise be a stored XSS vector against whoever opens the drive.
  const name = document.createElement('button');
  name.className = 'name';
  name.textContent = entry.name;
  name.onclick = () =>
    entry.isDir ? navigate(entry.path) : download(entry.path);

  const meta = document.createElement('span');
  meta.className = 'meta';
  meta.textContent = entry.isDir
    ? humanDate(entry.modified)
    : `${humanSize(entry.size)} · ${humanDate(entry.modified)}`;

  const menu = document.createElement('menu');
  menu.append(
    action('Rename', () => renameEntry(entry)),
    action('Delete', () => deleteEntry(entry)),
  );

  row.append(icon, name, meta, menu);
  return row;
}

function renderTrash(entries) {
  const list = $('list');
  list.replaceChildren();
  $('empty').hidden = entries.length > 0;

  for (const entry of entries) {
    const row = document.createElement('div');
    row.className = 'row';

    const icon = document.createElement('span');
    icon.className = 'icon';
    icon.textContent = '🗑';

    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = entry.name;

    const meta = document.createElement('span');
    meta.className = 'meta';
    meta.textContent = `deleted ${humanDate(entry.deletedAt)}`;

    const menu = document.createElement('menu');
    menu.append(action('Restore', async () => {
      await api('/api/trash/restore', { method: 'POST', body: { id: entry.id } });
      openTrash();
    }));

    row.append(icon, name, meta, menu);
    list.append(row);
  }
}

function action(label, fn) {
  const b = document.createElement('button');
  b.textContent = label;
  b.onclick = fn;
  return b;
}

// --- file operations --------------------------------------------------------

function download(path) {
  // A normal navigation, so the browser's own download manager handles
  // resumption and progress rather than buffering the file in memory.
  const a = document.createElement('a');
  a.href = `/api/download?path=${encodeURIComponent(path)}`;
  a.download = '';
  document.body.append(a);
  a.click();
  a.remove();
}

async function renameEntry(entry) {
  const next = prompt('New name', entry.name);
  if (!next || next === entry.name) return;
  if (next.includes('/')) return alert('A name cannot contain "/".');

  const parent = entry.path.slice(0, entry.path.length - entry.name.length);
  try {
    await api('/api/rename', {
      method: 'POST',
      body: { from: entry.path, to: parent + next },
    });
    navigate(cwd);
  } catch (e) {
    alert(e.message);
  }
}

async function deleteEntry(entry) {
  if (!confirm(`Move "${entry.name}" to trash?`)) return;
  try {
    await api('/api/delete', { method: 'POST', body: { path: entry.path } });
    navigate(cwd);
  } catch (e) {
    alert(e.message);
  }
}

$('btn-mkdir').addEventListener('click', async () => {
  const name = prompt('Folder name');
  if (!name) return;
  try {
    await api('/api/folders', { method: 'POST', body: { path: joinPath(cwd, name) } });
    navigate(cwd);
  } catch (e) {
    alert(e.message);
  }
});

$('btn-trash').addEventListener('click', openTrash);

// --- search -----------------------------------------------------------------

let searchTimer;
$('search').addEventListener('input', (e) => {
  clearTimeout(searchTimer);
  const q = e.target.value.trim();

  searchTimer = setTimeout(async () => {
    if (!q) return navigate(cwd);
    viewing = 'search';
    const { results } = await api(`/api/search?q=${encodeURIComponent(q)}`);
    renderList(results);
  }, 250);
});

// --- uploads ----------------------------------------------------------------

$('btn-upload').addEventListener('click', () => $('file-input').click());

$('file-input').addEventListener('change', (e) => {
  uploadAll([...e.target.files]);
  e.target.value = '';
});

async function uploadAll(files) {
  // Sequential: a phone's uplink and SD card are both happier with one
  // transfer at a time than with four competing ones.
  for (const file of files) {
    await uploadOne(file);
  }
  navigate(cwd);
}

async function uploadOne(file) {
  const card = uploadCard(file.name);

  try {
    const session = await api('/api/uploads', {
      method: 'POST',
      body: {
        path: joinPath(cwd, file.name),
        size: file.size,
        chunkSize: CHUNK_SIZE,
      },
    });

    for (let i = 0; i < session.chunkCount; i++) {
      const start = i * session.chunkSize;
      const blob = file.slice(start, Math.min(start + session.chunkSize, file.size));
      await putChunkWithRetry(session.id, i, blob);
      card.progress((i + 1) / session.chunkCount);
    }

    await api(`/api/uploads/${session.id}/complete`, { method: 'POST' });
    card.done();
  } catch (e) {
    card.fail(e.message);
  }
}

async function putChunkWithRetry(id, index, blob) {
  let lastError;

  for (let attempt = 0; attempt < CHUNK_RETRIES; attempt++) {
    try {
      return await api(`/api/uploads/${id}/chunks/${index}`, {
        method: 'PUT',
        raw: blob,
      });
    } catch (e) {
      lastError = e;
      // A phone on mobile data drops connections routinely; back off and
      // retry the one chunk rather than restarting the whole file.
      await new Promise((r) => setTimeout(r, 400 * Math.pow(2, attempt)));
    }
  }
  throw lastError;
}

function uploadCard(name) {
  const el = document.createElement('div');
  el.className = 'upload';

  const top = document.createElement('div');
  top.className = 'top';
  const label = document.createElement('span');
  label.textContent = name;
  const pct = document.createElement('span');
  pct.textContent = '0%';
  top.append(label, pct);

  const bar = document.createElement('progress');
  bar.max = 1;
  bar.value = 0;

  el.append(top, bar);
  $('uploads').append(el);

  return {
    progress(v) {
      bar.value = v;
      pct.textContent = `${Math.round(v * 100)}%`;
    },
    done() {
      pct.textContent = 'Done';
      setTimeout(() => el.remove(), 1500);
    },
    fail(msg) {
      el.classList.add('failed');
      pct.textContent = msg;
      bar.remove();
    },
  };
}

// --- drag and drop ----------------------------------------------------------

let dragDepth = 0;

addEventListener('dragenter', (e) => {
  e.preventDefault();
  if (++dragDepth === 1) document.body.classList.add('dragging');
});

addEventListener('dragover', (e) => e.preventDefault());

addEventListener('dragleave', () => {
  if (--dragDepth <= 0) {
    dragDepth = 0;
    document.body.classList.remove('dragging');
  }
});

addEventListener('drop', (e) => {
  e.preventDefault();
  dragDepth = 0;
  document.body.classList.remove('dragging');

  const files = [...(e.dataTransfer?.files || [])];
  if (files.length) uploadAll(files);
});

// --- boot -------------------------------------------------------------------

/**
 * Removes any query string from the address bar without reloading.
 *
 * An older build's form could submit natively as a GET, leaving
 * ?username=…&password=… in the URL. Clearing it keeps the credentials out of
 * the visible address bar and out of Referer headers on subsequent requests.
 * The history entry itself is the browser's; only the user can purge that.
 */
function scrubUrl() {
  if (!location.search) return;
  try {
    history.replaceState({}, '', location.pathname);
  } catch {
    // Non-fatal: the app works fine with a dirty URL.
  }
}

(async function boot() {
  scrubUrl();
  try {
    await api('/api/me');
    showApp();
  } catch {
    showLogin();
  }
})();
