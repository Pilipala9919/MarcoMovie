// Local host compatibility bridge for CatVodOpen `assets://js/lib/cat.js`.
import CryptoImpl from 'marco:catvod-crypto';
import _ from 'assets://js-host/lodash-shim.mjs';
import {load, jp, jinja2} from 'assets://js-host/cheerio-bridge.mjs';

export const Crypto = globalThis.CryptoJS || CryptoImpl;
export const CryptoJS = Crypto;
export {_, load, jp, jinja2};
export const cheerio = {load, jp, jinja2};

export class Uri {
  constructor(raw = '') {
    this._protocol = '';
    this._userInfo = '';
    this._host = '';
    this._port = '';
    this._path = '';
    this._queryPairs = [];
    this._anchor = '';
    this._parse(String(raw || ''));
  }

  _parse(str) {
    let rest = str;
    const hashIdx = rest.indexOf('#');
    if (hashIdx >= 0) {
      this._anchor = rest.slice(hashIdx + 1);
      rest = rest.slice(0, hashIdx);
    }
    const qIdx = rest.indexOf('?');
    let queryStr = '';
    if (qIdx >= 0) {
      queryStr = rest.slice(qIdx + 1);
      rest = rest.slice(0, qIdx);
    }
    const m = /^(?:([A-Za-z][A-Za-z0-9+.-]*):)?\/\/(?:([^/@]+)@)?([^/:]+)(?::(\d+))?(\/.*)?$/.exec(rest);
    if (m) {
      this._protocol = m[1] || '';
      this._userInfo = m[2] || '';
      this._host = m[3] || '';
      this._port = m[4] || '';
      this._path = m[5] || '';
    } else {
      this._path = rest;
    }
    if (queryStr) {
      for (const part of queryStr.split('&')) {
        if (!part) continue;
        const eq = part.indexOf('=');
        if (eq >= 0) {
          this._queryPairs.push([
            decodeURIComponent(part.slice(0, eq)),
            decodeURIComponent(part.slice(eq + 1))
          ]);
        } else {
          this._queryPairs.push([decodeURIComponent(part), '']);
        }
      }
    }
  }

  protocol(val) { if (val === undefined) return this._protocol; this._protocol = String(val); return this; }
  userInfo(val) { if (val === undefined) return this._userInfo; this._userInfo = String(val); return this; }
  host(val) { if (val === undefined) return this._host; this._host = String(val); return this; }
  port(val) { if (val === undefined) return this._port; this._port = String(val); return this; }
  path(val) { if (val === undefined) return this._path; this._path = String(val); return this; }
  anchor(val) { if (val === undefined) return this._anchor; this._anchor = String(val); return this; }

  query(val) {
    if (val === undefined) {
      return this._queryPairs
        .map(([k, v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v))
        .join('&');
    }
    this._queryPairs = [];
    const q = String(val || '').replace(/^\?/, '');
    if (q) {
      for (const part of q.split('&')) {
        if (!part) continue;
        const eq = part.indexOf('=');
        this._queryPairs.push(eq >= 0
          ? [decodeURIComponent(part.slice(0, eq)), decodeURIComponent(part.slice(eq + 1))]
          : [decodeURIComponent(part), '']);
      }
    }
    return this;
  }

  getQueryParamValue(key) {
    const found = this._queryPairs.find(([k]) => k === key);
    return found ? found[1] : undefined;
  }

  getQueryParamValues(key) {
    return this._queryPairs.filter(([k]) => k === key).map(([, v]) => v);
  }

  deleteQueryParam(key) {
    this._queryPairs = this._queryPairs.filter(([k]) => k !== key);
    return this;
  }

  addQueryParam(key, val = '') {
    this._queryPairs.push([String(key), String(val)]);
    return this;
  }

  replaceQueryParam(key, val = '') {
    this.deleteQueryParam(key);
    return this.addQueryParam(key, val);
  }

  toString() {
    let out = '';
    if (this._host) {
      out += (this._protocol ? this._protocol + ':' : '') + '//';
      if (this._userInfo) out += this._userInfo + '@';
      out += this._host;
      if (this._port) out += ':' + this._port;
    }
    out += this._path || '';
    const q = this.query();
    if (q) out += '?' + q;
    if (this._anchor) out += '#' + this._anchor;
    return out;
  }
}

export function md5X(text) {
  return Crypto.MD5(String(text ?? '')).toString();
}

export function sha256X(text) {
  return Crypto.SHA256(String(text ?? '')).toString();
}

const catExports = {
  Crypto,
  CryptoJS,
  _,
  load,
  cheerio,
  jp,
  jinja2,
  Uri,
  md5X,
  sha256X
};

export default catExports;
