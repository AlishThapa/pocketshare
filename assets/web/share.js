'use strict';

// The public face of a share link. Deliberately a separate bundle from the
// owner's app: a visitor holds a token for one path, and shipping them the
// code that drives the whole drive would be handing over a map they have no
// use for and no right to.

const $ = (id) => document.getElementById(id);

// /s/<token> — the token is the permission, so it stays in the path and is
// never put in a query string, where it would end up in logs more readily.
const TOKEN = location.pathname.split('/').filter(Boolean)[1] || '';

let within = '';

function show(which) {
  for (const id of ['loading', 'locked', 'gone', 'single', 'folder']) {
    $(id).hidden = id !== which;
  }
}

function dead(message) {
  $('gone-why').textContent = message || 'This link is no longer available.';
  show('gone');
}

async function get(path) {
  const res = await fetch(path);
  const text = await res.text();
  const data = text ? JSON.parse(text) : {};
  if (!res.ok) {
    const err = new Error(data.error || `failed (${res.status})`);
    err.status = res.status;
    throw err;
  }
  return data;
}

function humanSize(bytes) {
  if (!bytes) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const n = bytes / Math.pow(1024, i);
  return `${n < 10 && i > 0 ? n.toFixed(1) : Math.round(n)} ${units[i]}`;
}

function humanDate(ms) {
  return new Date(ms).toLocaleDateString(undefined, {
    day: 'numeric', month: 'short', year: 'numeric',
  });
}

function extensionOf(name) {
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
}

// Mirrors the server's allowlist; the server is what enforces it.
const PREVIEWABLE = {
  image: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'bmp', 'ico'],
  video: ['mp4', 'webm', 'mov', 'm4v', 'ogv'],
  audio: ['mp3', 'm4a', 'aac', 'ogg', 'oga', 'wav', 'flac', 'opus'],
  pdf: ['pdf'],
};

function previewKind(name) {
  const ext = extensionOf(name);
  for (const [kind, extensions] of Object.entries(PREVIEWABLE)) {
    if (extensions.includes(ext)) return kind;
  }
  return null;
}

function downloadUrl(path, { inline = false } = {}) {
  const url = new URL(`/api/share/${encodeURIComponent(TOKEN)}/download`,
      location.origin);
  if (path) url.searchParams.set('path', path);
  if (inline) url.searchParams.set('inline', '1');
  return url.pathname + url.search;
}

// --- password ---------------------------------------------------------------

$('sreveal').addEventListener('click', () => {
  const field = $('sp');
  const showing = field.type === 'text';
  field.type = showing ? 'password' : 'text';
  const btn = $('sreveal');
  btn.textContent = showing ? 'Show' : 'Hide';
  btn.setAttribute('aria-pressed', String(!showing));
  btn.setAttribute('aria-label', showing ? 'Show password' : 'Hide password');
  field.focus();
});

$('unlock-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = $('unlock-btn');
  const err = $('unlock-error');
  err.textContent = '';
  btn.disabled = true;
  btn.textContent = 'Unlocking…';

  try {
    const res = await fetch(`/api/share/${encodeURIComponent(TOKEN)}/unlock`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: $('sp').value }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || 'Wrong password.');
    $('sp').value = '';
    await open();
  } catch (e2) {
    err.textContent = e2.message;
  } finally {
    btn.disabled = false;
    btn.textContent = 'Unlock';
  }
});

// --- single file ------------------------------------------------------------

function showSingle(info) {
  $('single-name').textContent = info.name;
  $('single-download').onclick = () => { location.href = downloadUrl(''); };

  const kind = previewKind(info.name);
  const holder = $('single-preview');
  holder.replaceChildren();

  const inline = downloadUrl('', { inline: true });

  if (kind === 'image') {
    const img = document.createElement('img');
    img.src = inline;
    img.alt = info.name;
    img.className = 'share-preview';
    holder.append(img);
  } else if (kind === 'video' || kind === 'audio') {
    const el = document.createElement(kind);
    el.src = inline;
    el.controls = true;
    el.className = 'share-preview';
    holder.append(el);
  } else if (kind === 'pdf') {
    const frame = document.createElement('iframe');
    frame.src = inline;
    frame.title = info.name;
    frame.className = 'share-preview share-pdf';
    holder.append(frame);
  }

  $('single-meta').textContent = kind ? '' : 'Ready to download.';
  show('single');
}

// --- folder -----------------------------------------------------------------

async function showFolder(info) {
  $('folder-name').textContent = info.name;
  show('folder');
  await listFolder('');
}

async function listFolder(path) {
  within = path;
  const { entries } = await get(
    `/api/share/${encodeURIComponent(TOKEN)}/list?path=${encodeURIComponent(path)}`,
  );

  renderCrumbs();
  const list = $('share-list');
  list.replaceChildren();
  $('share-empty').hidden = entries.length > 0;

  const sorted = [...entries].sort((a, b) =>
    a.isDir !== b.isDir
      ? (a.isDir ? -1 : 1)
      : a.name.localeCompare(b.name, undefined, { numeric: true }));

  for (const entry of sorted) {
    const row = document.createElement('div');
    row.className = 'row';

    const icon = document.createElement('span');
    icon.className = 'icon';
    icon.textContent = entry.isDir ? '📁' : '📄';

    // textContent, never innerHTML: these names came off someone's phone.
    const name = document.createElement('button');
    name.className = 'name';
    name.textContent = entry.name;

    // Paths sent back are relative to the share, never to the drive. The
    // server re-checks containment regardless; this just keeps the client
    // from ever constructing something it has no business asking for.
    const rel = path ? `${path}/${entry.name}` : entry.name;
    name.onclick = () => {
      if (entry.isDir) return listFolder(rel);
      location.href = downloadUrl(rel);
    };

    const meta = document.createElement('span');
    meta.className = 'meta';
    meta.textContent = entry.isDir
      ? humanDate(entry.modified)
      : `${humanSize(entry.size)} · ${humanDate(entry.modified)}`;

    row.append(icon, name, meta);
    list.append(row);
  }
}

function renderCrumbs() {
  const nav = $('share-crumbs');
  nav.replaceChildren();

  const root = document.createElement('button');
  root.textContent = $('folder-name').textContent || 'Shared folder';
  root.onclick = () => listFolder('');
  nav.append(root);

  let acc = '';
  for (const part of within.split('/').filter(Boolean)) {
    acc = acc ? `${acc}/${part}` : part;
    const target = acc;
    nav.append(Object.assign(document.createElement('span'), { textContent: '/' }));
    const b = document.createElement('button');
    b.textContent = part;
    b.onclick = () => listFolder(target);
    nav.append(b);
  }
}

// --- boot -------------------------------------------------------------------

async function open() {
  try {
    const info = await get(`/api/share/${encodeURIComponent(TOKEN)}`);
    if (info.needsPassword) {
      // The server tells us a password is needed but not whether this
      // browser has already answered it; the listing call is what finds out.
      try {
        if (info.isDir) {
          await showFolder(info);
        } else {
          await probeUnlocked(info);
        }
        return;
      } catch (e) {
        if (e.status === 401) return show('locked');
        throw e;
      }
    }
    return info.isDir ? showFolder(info) : showSingle(info);
  } catch (e) {
    if (e.status === 401) return show('locked');
    dead(e.message);
  }
}

/// A single file has nothing to list, so a zero-length range request is what
/// asks "may I read this?" without pulling the file down to find out.
async function probeUnlocked(info) {
  const res = await fetch(downloadUrl(''), { headers: { Range: 'bytes=0-0' } });
  if (res.status === 401) {
    const err = new Error('password required');
    err.status = 401;
    throw err;
  }
  showSingle(info);
}

if (!TOKEN) {
  dead('That link is missing its code.');
} else {
  open();
}
