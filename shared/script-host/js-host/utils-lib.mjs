// Local host compatibility bridge for `assets://js/lib/utils.js` & netdisk helpers.
import {Crypto, CryptoJS, _, load, cheerio, jp, jinja2, Uri, md5X, sha256X} from 'assets://js-host/cat-lib.mjs';

export {Crypto, CryptoJS, _, load, cheerio, jp, jinja2, Uri, md5X, sha256X};

export function base64Encode(text = '') {
  return Crypto.enc.Base64.stringify(Crypto.enc.Utf8.parse(String(text)));
}

export function base64Decode(encoded = '') {
  const clean = String(encoded).trim().replace(/-/g, '+').replace(/_/g, '/');
  return Crypto.enc.Utf8.stringify(Crypto.enc.Base64.parse(clean));
}

export function md5(text = '') {
  return Crypto.MD5(String(text)).toString();
}

export function sha1(text = '') {
  return Crypto.SHA1(String(text)).toString();
}

export function sha256(text = '') {
  return Crypto.SHA256(String(text)).toString();
}

export function hmacSha1(message = '', secret = '') {
  return Crypto.HmacSHA1(String(message), String(secret)).toString();
}

export function hmacSha256(message = '', secret = '') {
  return Crypto.HmacSHA256(String(message), String(secret)).toString();
}

export function aesEncrypt(plainText = '', keyStr = '', ivStr = '') {
  const key = Crypto.enc.Utf8.parse(String(keyStr));
  const opts = ivStr
    ? {iv: Crypto.enc.Utf8.parse(String(ivStr)), mode: Crypto.mode.CBC, padding: Crypto.pad.Pkcs7}
    : {mode: Crypto.mode.ECB, padding: Crypto.pad.Pkcs7};
  return Crypto.AES.encrypt(String(plainText), key, opts).toString();
}

export function aesDecrypt(cipherText = '', keyStr = '', ivStr = '') {
  const key = Crypto.enc.Utf8.parse(String(keyStr));
  const opts = ivStr
    ? {iv: Crypto.enc.Utf8.parse(String(ivStr)), mode: Crypto.mode.CBC, padding: Crypto.pad.Pkcs7}
    : {mode: Crypto.mode.ECB, padding: Crypto.pad.Pkcs7};
  return Crypto.AES.decrypt(String(cipherText), key, opts).toString(Crypto.enc.Utf8);
}

export function urlJoin(base = '', part = '') {
  if (typeof globalThis.joinUrl === 'function') return globalThis.joinUrl(base, part);
  return String(part || base || '');
}
export const joinUrl = urlJoin;

export function parseQuery(queryStr = '') {
  const out = {};
  const q = String(queryStr || '').replace(/^[?#]/, '');
  if (!q) return out;
  for (const part of q.split('&')) {
    if (!part) continue;
    const eq = part.indexOf('=');
    if (eq >= 0) {
      out[decodeURIComponent(part.slice(0, eq))] = decodeURIComponent(part.slice(eq + 1));
    } else {
      out[decodeURIComponent(part)] = '';
    }
  }
  return out;
}

export function stringifyQuery(params = {}) {
  if (!params || typeof params !== 'object') return '';
  return Object.entries(params)
    .filter(([, v]) => v !== undefined && v !== null)
    .map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(String(v)))
    .join('&');
}

export function buildUrl(base = '', params = {}) {
  const q = stringifyQuery(params);
  if (!q) return String(base || '');
  const clean = String(base || '');
  return clean + (clean.includes('?') ? '&' : '?') + q;
}

export function getHost(url = '') {
  const m = /^(https?:\/\/[^/?#]+)/i.exec(String(url || '').trim());
  return m ? m[1] : '';
}

export function stripHtml(html = '') {
  return String(html || '')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function unescapeHtml(str = '') {
  return String(str || '')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'");
}

export function formatSize(bytes = 0) {
  const n = Number(bytes) || 0;
  if (n <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let idx = 0;
  let val = n;
  while (val >= 1024 && idx < units.length - 1) {
    val /= 1024;
    idx++;
  }
  return (idx === 0 ? String(val) : val.toFixed(2)) + ' ' + units[idx];
}
export const getSize = formatSize;

const PAN_PATTERNS = [
  {type: 'quark', regex: /https?:\/\/pan\.quark\.cn\/s\/([A-Za-z0-9]+)/i},
  {type: 'uc', regex: /https?:\/\/drive\.uc\.cn\/s\/([A-Za-z0-9]+)/i},
  {type: 'ali', regex: /https?:\/\/(?:www\.)?(?:aliyundrive|alipan)\.com\/s\/([A-Za-z0-9]+)/i},
  {type: 'baidu', regex: /https?:\/\/pan\.baidu\.com\/s\/([A-Za-z0-9_-]+)/i},
  {type: 'pan115', regex: /https?:\/\/(?:115|115cdn|anxia)\.com\/s\/([A-Za-z0-9]+)/i},
  {type: 'tianyi', regex: /https?:\/\/cloud\.189\.cn\/(?:t\/|web\/share\?code=)([A-Za-z0-9]+)/i},
  {type: 'yd', regex: /https?:\/\/caiyun\.139\.com\/(?:m\/i\?|w\/i\/)([A-Za-z0-9]+)/i},
  {type: 'pan123', regex: /https?:\/\/(?:www\.)?(?:123pan|123684|123865|123912|123592)\.com\/s\/([A-Za-z0-9_-]+)/i},
  {type: 'pikpak', regex: /https?:\/\/mypikpak\.com\/s\/([A-Za-z0-9_-]+)/i}
];

export function detectPanType(url = '') {
  const s = String(url || '');
  for (const item of PAN_PATTERNS) {
    if (item.regex.test(s)) return item.type;
  }
  return '';
}

export function isPanUrl(url = '') {
  return detectPanType(url) !== '';
}

export function extractShareId(url = '') {
  const s = String(url || '');
  for (const item of PAN_PATTERNS) {
    const m = item.regex.exec(s);
    if (m) return m[1];
  }
  return '';
}

export function sleep(ms = 0) {
  if (typeof globalThis.sleep === 'function') globalThis.sleep(Number(ms) || 0);
}
export const delay = async (ms = 0) => { sleep(ms); };

export function formatPlayUrl(lineName = '', episodeName = '') {
  const cleanEp = String(episodeName || '').replace(/[$#]/g, ' ').trim();
  const cleanLine = String(lineName || '').trim();
  return cleanLine && !cleanEp.includes(cleanLine) ? `[${cleanLine}] ${cleanEp}` : cleanEp;
}

const utilsExports = {
  Crypto,
  CryptoJS,
  _,
  load,
  cheerio,
  jp,
  jinja2,
  Uri,
  base64Encode,
  base64Decode,
  md5,
  md5X,
  sha1,
  sha256,
  sha256X,
  hmacSha1,
  hmacSha256,
  aesEncrypt,
  aesDecrypt,
  urlJoin,
  joinUrl,
  parseQuery,
  stringifyQuery,
  buildUrl,
  getHost,
  stripHtml,
  unescapeHtml,
  formatSize,
  getSize,
  detectPanType,
  isPanUrl,
  extractShareId,
  sleep,
  delay,
  formatPlayUrl
};

export default utilsExports;
