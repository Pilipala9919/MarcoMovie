/**
 * Cloudflare Worker relay for Marco Movie automatic crash-report submission to GitHub Issues.
 *
 * Route: https://marcotv.wlj9919.top/movie/api/crash-report
 * Required secret binding:
 *   GITHUB_TOKEN  - Fine-grained GitHub PAT with ONLY "Issues: Read and write"
 *                   on repository Pilipala9919/MarcoMovie.
 * Optional env var:
 *   GITHUB_REPO   - Defaults to "Pilipala9919/MarcoMovie".
 */

const DEFAULT_REPO = 'Pilipala9919/MarcoMovie';
const MAX_PAYLOAD_BYTES = 64 * 1024;
const ALLOWED_LABELS = new Set(['bug', 'crash-report', 'android-tv', 'android-mobile']);

// Best-effort per-isolate sliding-window rate limiter (Cloudflare WAF rate limiting can be layered on top).
const ipHits = new Map();
const RATE_WINDOW_MS = 10 * 60 * 1000;
const RATE_LIMIT = 5;

function allowRequest(ip) {
  const now = Date.now();
  const prev = (ipHits.get(ip) || []).filter((t) => now - t < RATE_WINDOW_MS);
  if (prev.length >= RATE_LIMIT) {
    ipHits.set(ip, prev);
    return false;
  }
  prev.push(now);
  ipHits.set(ip, prev);
  return true;
}

function redactSecondary(text) {
  return String(text || '')
    .replace(/(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/g, '[TOKEN_REDACTED]')
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, 'Bearer [REDACTED]')
    .replace(
      /\b(cookie|authorization|token|password|passwd|puus|bduss|stoken)\s*[:=]\s*[^\s,;"'&\r\n]+/gi,
      '$1=[REDACTED]',
    );
}

function jsonResponse(status, obj) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  });
}

const GITHUB_API_BASE = 'https://api.github.com/';

async function githubFetch(path, token, init = {}) {
  const cleanPath = String(path || '').replace(/^\/+/, '');
  return fetch(GITHUB_API_BASE + cleanPath, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'MarcoMovie-CrashRelay/1.0',
      ...(init.headers || {}),
    },
  });
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return jsonResponse(405, { ok: false, error: 'Method Not Allowed' });
    }
    const token = env && env.GITHUB_TOKEN;
    if (!token) {
      return jsonResponse(503, { ok: false, error: 'Relay token not configured' });
    }
    const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
    if (!allowRequest(ip)) {
      return jsonResponse(429, { ok: false, error: 'Too many crash reports; please retry later' });
    }

    const raw = await request.arrayBuffer();
    if (raw.byteLength === 0 || raw.byteLength > MAX_PAYLOAD_BYTES) {
      return jsonResponse(413, { ok: false, error: 'Payload out of allowed size range' });
    }

    let payload;
    try {
      payload = JSON.parse(new TextDecoder('utf-8').decode(raw));
    } catch {
      return jsonResponse(400, { ok: false, error: 'Invalid JSON body' });
    }

    const repo = (env && env.GITHUB_REPO) || DEFAULT_REPO;
    const title = redactSecondary(payload.title || '[Crash] MarcoMovie report').slice(0, 140);
    const body = redactSecondary(payload.body || '').slice(0, 56000);
    const fingerprint = String(payload.fingerprint || '')
      .replace(/[^a-fA-F0-9_-]/g, '')
      .slice(0, 24);
    const labels = Array.isArray(payload.labels)
      ? payload.labels.filter((l) => typeof l === 'string' && ALLOWED_LABELS.has(l))
      : ['bug', 'crash-report'];
    if (labels.length === 0) labels.push('bug', 'crash-report');

    if (!body) {
      return jsonResponse(400, { ok: false, error: 'Missing report body' });
    }

    // Deduplicate against an existing open Issue carrying the same crash fingerprint.
    if (fingerprint.length >= 8) {
      const q = encodeURIComponent(
        `repo:${repo} is:issue is:open "crash-fingerprint: ${fingerprint}"`,
      );
      const searchRes = await githubFetch(`/search/issues?q=${q}&per_page=1`, token);
      if (searchRes.ok) {
        const found = await searchRes.json();
        const existing = found && Array.isArray(found.items) && found.items[0];
        if (existing && existing.number) {
          const commentBody = `### 同指纹崩溃补充上报\n\n${body}`;
          const commentRes = await githubFetch(
            `/repos/${repo}/issues/${existing.number}/comments`,
            token,
            {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ body: commentBody }),
            },
          );
          if (commentRes.ok) {
            return jsonResponse(200, {
              ok: true,
              deduplicated: true,
              issue_number: existing.number,
              issue_url: existing.html_url,
            });
          }
        }
      }
    }

    const createRes = await githubFetch(`/repos/${repo}/issues`, token, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title, body, labels }),
    });
    if (!createRes.ok) {
      return jsonResponse(502, {
        ok: false,
        error: `GitHub API rejected request (${createRes.status})`,
      });
    }
    const created = await createRes.json();
    return jsonResponse(200, {
      ok: true,
      deduplicated: false,
      issue_number: created.number,
      issue_url: created.html_url,
    });
  },
};
