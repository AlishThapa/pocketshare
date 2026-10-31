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

function extensionOf(name) {
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
}

// --- sorting and filtering --------------------------------------------------

// Mirrors the server's allowlist in lib/server/inline_types.dart. The server
// is what enforces it; this only decides whether to offer a preview, so a
// disagreement costs a pointless dialog, never an unsafe render.
const PREVIEWABLE = {
  image: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'ico'],
  video: ['mp4', 'webm', 'mov', 'm4v', 'ogv'],
  audio: ['mp3', 'm4a', 'aac', 'ogg', 'oga', 'wav', 'flac', 'opus'],
  pdf: ['pdf'],
  text: ['txt', 'log', 'md', 'csv'],
};

function previewKind(entry) {
  if (entry.isDir) return null;
  const ext = extensionOf(entry.name);
  for (const [kind, extensions] of Object.entries(PREVIEWABLE)) {
    if (extensions.includes(ext)) return kind;
  }
  return null;
}

const SORT_KEY = 'ps.sort';

let sort = { by: 'name', asc: true };

function loadSort() {
  try {
    const saved = JSON.parse(localStorage.getItem(SORT_KEY) || 'null');
    if (saved && ['name', 'size', 'modified'].includes(saved.by)) {
      sort = { by: saved.by, asc: saved.asc !== false };
    }
  } catch {
    // A corrupt or unavailable localStorage is not a reason to fail to list
    // files; the default order is perfectly usable.
  }
  $('sort-by').value = sort.by;
  paintSortDirection();
}

function saveSort() {
  try {
    localStorage.setItem(SORT_KEY, JSON.stringify(sort));
  } catch { /* private mode, or storage disabled */ }
}

function paintSortDirection() {
  const btn = $('sort-dir');
  btn.textContent = sort.asc ? '↑' : '↓';
  btn.setAttribute('aria-pressed', String(!sort.asc));
  btn.title = sort.asc ? 'Ascending' : 'Descending';
}

/**
 * Folders first, always, then the chosen key.
 *
 * Folders have no size worth comparing, and burying them among files sorted
 * by size is how you lose the one you were looking for. The direction toggle
 * applies within each group, not across them.
 */
function sortEntries(entries) {
  const collator = new Intl.Collator(undefined, {
    numeric: true,
    sensitivity: 'base',
  });
  const direction = sort.asc ? 1 : -1;

  return [...entries].sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;

    let cmp;
    if (sort.by === 'size' && !a.isDir) {
      cmp = (a.size || 0) - (b.size || 0);
    } else if (sort.by === 'modified') {
      cmp = (a.modified || 0) - (b.modified || 0);
    } else {
      cmp = collator.compare(a.name, b.name);
    }
    // Ties fall back to the name so the order never shuffles between renders.
    return (cmp || collator.compare(a.name, b.name)) * direction;
  });
}

function applyFilter(entries) {
  const q = $('filter').value.trim().toLowerCase();
  if (!q) return entries;
  return entries.filter((e) => e.name.toLowerCase().includes(q));
}

// --- login ------------------------------------------------------------------

function showLogin() {
  viewing = 'login';
  $('app').hidden = true;
  $('login').hidden = false;
  $('login-host').textContent = location.host;

  // Never leave a password visible across a sign-out.
  const field = $('p');
  field.type = 'password';
  field.value = '';
  const btn = $('reveal');
  btn.textContent = 'Show';
  btn.setAttribute('aria-pressed', 'false');
  btn.setAttribute('aria-label', 'Show password');
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

// Typing a long password blind on a phone keyboard is how people end up
// choosing short ones. aria-pressed carries the state; the label says what
// the button will do next.
$('reveal').addEventListener('click', () => {
  const field = $('p');
  const showing = field.type === 'text';
  field.type = showing ? 'password' : 'text';

  const btn = $('reveal');
  btn.textContent = showing ? 'Show' : 'Hide';
  btn.setAttribute('aria-pressed', String(!showing));
  const label = showing ? 'Show password' : 'Hide password';
  btn.setAttribute('aria-label', label);
  btn.title = label;

  // Focus goes back to the field, at the end, so the reveal does not cost
  // the user their place mid-password.
  field.focus();
  const end = field.value.length;
  try {
    field.setSelectionRange(end, end);
  } catch { /* some browsers refuse on type=password */ }
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
  // The filter describes a folder, so it does not survive leaving one.
  $('filter').value = '';
  $('toolbar').hidden = false;
  renderCrumbs();

  const { entries } = await api(`/api/files?path=${encodeURIComponent(path)}`);
  renderList(entries);
}

async function openTrash() {
  viewing = 'trash';
  // Trash rows are deleted things with their own ordering by when they went;
  // the folder toolbar does not apply to them.
  $('toolbar').hidden = true;
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

// The last listing the server gave us. Kept so sorting and filtering are
// instant and offline-safe: neither changes what is in the folder, so neither
// is a reason to ask again.
let currentEntries = [];

function renderList(entries) {
  currentEntries = entries;
  paintList();
}

function paintList() {
  const list = $('list');
  const shown = sortEntries(applyFilter(currentEntries));

  list.replaceChildren();
  for (const entry of shown) {
    list.append(fileRow(entry));
  }

  const empty = $('empty');
  empty.hidden = shown.length > 0;
  empty.textContent = currentEntries.length === 0
      ? 'Nothing here yet.'
      : 'Nothing matches that filter.';
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
  const kind = previewKind(entry);
  name.onclick = () => {
    if (entry.isDir) return navigate(entry.path);
    // Opening a file the browser can show should show it. Anything else
    // still downloads, which is what clicking it has always done.
    return kind ? openPreview(entry, kind) : download(entry.path);
  };

  const meta = document.createElement('span');
  meta.className = 'meta';
  meta.textContent = entry.isDir
    ? humanDate(entry.modified)
    : `${humanSize(entry.size)} · ${humanDate(entry.modified)}`;

  const menu = document.createElement('menu');
  if (!entry.isDir) {
    menu.append(action('Download', () => download(entry.path)));
  }
  menu.append(
    action('Details', () => showInfo(entry)),
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

// --- toolbar ----------------------------------------------------------------

$('sort-by').addEventListener('change', (e) => {
  sort.by = e.target.value;
  saveSort();
  paintList();
});

$('sort-dir').addEventListener('click', () => {
  sort.asc = !sort.asc;
  paintSortDirection();
  saveSort();
  paintList();
});

$('filter').addEventListener('input', paintList);

// --- preview ----------------------------------------------------------------

let previewUrl = null;

/**
 * Shows a file rather than downloading it.
 *
 * `inline=1` only asks; the server decides, and refuses for anything outside
 * its allowlist. Range requests already work, so video and audio seek.
 */
async function openPreview(entry, kind) {
  const dialog = $('preview');
  const body = $('preview-body');
  body.replaceChildren();

  $('preview-name').textContent = entry.name;
  previewUrl = `/api/download?path=${encodeURIComponent(entry.path)}&inline=1`;

  let node;
  if (kind === 'image') {
    node = document.createElement('img');
    node.src = previewUrl;
    node.alt = entry.name;
  } else if (kind === 'video') {
    node = document.createElement('video');
    node.src = previewUrl;
    node.controls = true;
    node.preload = 'metadata';
  } else if (kind === 'audio') {
    node = document.createElement('audio');
    node.src = previewUrl;
    node.controls = true;
  } else if (kind === 'pdf') {
    node = document.createElement('iframe');
    node.src = previewUrl;
    node.title = entry.name;
  } else {
    // Text is fetched rather than framed so it can be put in a <pre> as
    // textContent. Framing it would render it as a document of this origin,
    // and a file the drive holds is not something to hand that to.
    node = document.createElement('pre');
    node.className = 'preview-text';
    node.textContent = 'Loading…';
    fetchText(entry.path, node);
  }

  node.className = `preview-${kind}${node.className ? ' ' + node.className : ''}`;
  body.append(node);
  dialog.showModal();
}

const TEXT_PREVIEW_LIMIT = 512 * 1024;

async function fetchText(path, node) {
  try {
    const res = await fetch(
      `/api/download?path=${encodeURIComponent(path)}&inline=1`,
      { headers: { Range: `bytes=0-${TEXT_PREVIEW_LIMIT - 1}` } },
    );
    if (!res.ok && res.status !== 206) throw new Error(`failed (${res.status})`);
    const text = await res.text();
    node.textContent = text;
    if (res.status === 206) {
      node.append(Object.assign(document.createElement('em'), {
        textContent: '\n\n— showing the first 512 KB —',
      }));
    }
  } catch (e) {
    node.textContent = `Could not read this file: ${e.message}`;
  }
}

function closePreview() {
  const dialog = $('preview');
  // Emptying it stops a video that is still playing; leaving the node alive
  // in a closed dialog keeps the audio going, which is startling.
  $('preview-body').replaceChildren();
  previewUrl = null;
  if (dialog.open) dialog.close();
}

$('preview-close').addEventListener('click', closePreview);
$('preview').addEventListener('close', () => $('preview-body').replaceChildren());

// Clicking the backdrop closes it. The dialog's own box is a child, so a
// click that lands on the element itself landed outside the content.
$('preview').addEventListener('click', (e) => {
  if (e.target === $('preview')) closePreview();
});

$('preview-download').addEventListener('click', () => {
  if (!previewUrl) return;
  download(decodeURIComponent(new URL(previewUrl, location.href)
      .searchParams.get('path')));
});

// --- details ----------------------------------------------------------------

function showInfo(entry) {
  const body = $('info-body');
  body.replaceChildren();

  const rows = [
    ['Name', entry.name],
    ['Where', '/' + (entry.path || entry.name)],
    ['Kind', entry.isDir ? 'Folder' : (kindLabel(entry) || 'File')],
  ];
  if (!entry.isDir) {
    rows.push(['Size', `${humanSize(entry.size || 0)} (${(entry.size || 0).toLocaleString()} bytes)`]);
  }
  rows.push(['Modified', new Date(entry.modified).toLocaleString()]);

  for (const [label, value] of rows) {
    body.append(
      Object.assign(document.createElement('dt'), { textContent: label }),
      Object.assign(document.createElement('dd'), { textContent: value }),
    );
  }
  $('info').showModal();
}

function kindLabel(entry) {
  const ext = extensionOf(entry.name);
  const kind = previewKind(entry);
  if (kind) return `${kind[0].toUpperCase()}${kind.slice(1)}${ext ? ` · .${ext}` : ''}`;
  return ext ? `.${ext} file` : null;
}

$('info-close').addEventListener('click', () => $('info').close());
$('info').addEventListener('click', (e) => {
  if (e.target === $('info')) $('info').close();
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
  loadSort();
  try {
    await api('/api/me');
    showApp();
  } catch {
    showLogin();
  }
})();
