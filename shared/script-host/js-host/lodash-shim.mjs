// Lightweight Lodash/Underscore compatibility shim for CatVod & netdisk spiders.
function toPath(path) {
  if (Array.isArray(path)) return path.map(String);
  if (typeof path !== 'string') return path == null ? [] : [String(path)];
  const result = [];
  path.replace(/([^.[\]]+)|\[(?:(-?\d+)|(["'])(.*?)\3)\]/g, (_, prop, idx, _q, quoted) => {
    result.push(prop !== undefined ? prop : (quoted !== undefined ? quoted : idx));
  });
  return result;
}

function iterateeFn(iteratee) {
  if (iteratee == null) return v => v;
  if (typeof iteratee === 'function') return iteratee;
  if (typeof iteratee === 'string') return obj => get(obj, iteratee);
  if (Array.isArray(iteratee)) return obj => get(obj, iteratee[0]) === iteratee[1];
  if (typeof iteratee === 'object') {
    const entries = Object.entries(iteratee);
    return obj => obj != null && entries.every(([k, v]) => get(obj, k) === v);
  }
  return v => v;
}

function get(obj, path, defaultValue) {
  if (obj == null) return defaultValue;
  const parts = toPath(path);
  let cur = obj;
  for (const key of parts) {
    if (cur == null) return defaultValue;
    cur = cur[key];
  }
  return cur === undefined ? defaultValue : cur;
}

function set(obj, path, value) {
  if (obj == null || typeof obj !== 'object') return obj;
  const parts = toPath(path);
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    const key = parts[i];
    const nextKey = parts[i + 1];
    if (cur[key] == null || typeof cur[key] !== 'object') {
      cur[key] = /^\d+$/.test(nextKey) ? [] : {};
    }
    cur = cur[key];
  }
  if (parts.length) cur[parts[parts.length - 1]] = value;
  return obj;
}

function has(obj, path) {
  if (obj == null) return false;
  const parts = toPath(path);
  if (!parts.length) return false;
  let cur = obj;
  for (const key of parts) {
    if (cur == null || !(key in Object(cur))) return false;
    cur = cur[key];
  }
  return true;
}

function each(collection, fn) {
  if (collection == null) return collection;
  const cb = iterateeFn(fn);
  if (Array.isArray(collection) || typeof collection === 'string') {
    for (let i = 0; i < collection.length; i++) {
      if (cb(collection[i], i, collection) === false) break;
    }
  } else if (typeof collection === 'object') {
    for (const key of Object.keys(collection)) {
      if (cb(collection[key], key, collection) === false) break;
    }
  }
  return collection;
}

function map(collection, fn) {
  if (collection == null) return [];
  const cb = iterateeFn(fn);
  if (Array.isArray(collection)) return collection.map((v, i) => cb(v, i, collection));
  if (typeof collection === 'object') return Object.keys(collection).map(k => cb(collection[k], k, collection));
  return [];
}

function filter(collection, pred) {
  if (collection == null) return [];
  const cb = iterateeFn(pred);
  const arr = Array.isArray(collection) ? collection : Object.values(collection);
  return arr.filter((v, i) => Boolean(cb(v, i, arr)));
}

function reject(collection, pred) {
  const cb = iterateeFn(pred);
  return filter(collection, (v, i, c) => !cb(v, i, c));
}

function find(collection, pred) {
  if (collection == null) return undefined;
  const cb = iterateeFn(pred);
  const arr = Array.isArray(collection) ? collection : Object.values(collection);
  return arr.find((v, i) => Boolean(cb(v, i, arr)));
}

function findIndex(array, pred) {
  if (!Array.isArray(array)) return -1;
  const cb = iterateeFn(pred);
  return array.findIndex((v, i) => Boolean(cb(v, i, array)));
}

function some(collection, pred) {
  if (collection == null) return false;
  const cb = iterateeFn(pred);
  const arr = Array.isArray(collection) ? collection : Object.values(collection);
  return arr.some((v, i) => Boolean(cb(v, i, arr)));
}

function every(collection, pred) {
  if (collection == null) return true;
  const cb = iterateeFn(pred);
  const arr = Array.isArray(collection) ? collection : Object.values(collection);
  return arr.every((v, i) => Boolean(cb(v, i, arr)));
}

function includes(collection, value, fromIndex = 0) {
  if (collection == null) return false;
  if (typeof collection === 'string' || Array.isArray(collection)) return collection.includes(value, fromIndex);
  return Object.values(collection).includes(value);
}

function reduce(collection, fn, accumulator) {
  if (collection == null) return accumulator;
  const cb = iterateeFn(fn);
  const entries = Array.isArray(collection)
    ? collection.map((v, i) => [i, v])
    : Object.entries(collection);
  let idx = 0;
  let acc = accumulator;
  if (arguments.length < 3 && entries.length > 0) {
    acc = entries[0][1];
    idx = 1;
  }
  for (; idx < entries.length; idx++) {
    acc = cb(acc, entries[idx][1], entries[idx][0], collection);
  }
  return acc;
}

function uniq(array) {
  return Array.isArray(array) ? Array.from(new Set(array)) : [];
}

function uniqBy(array, iteratee) {
  if (!Array.isArray(array)) return [];
  const cb = iterateeFn(iteratee);
  const seen = new Set();
  const out = [];
  for (const item of array) {
    const key = cb(item);
    if (!seen.has(key)) {
      seen.add(key);
      out.push(item);
    }
  }
  return out;
}

function flatten(array) {
  return Array.isArray(array) ? [].concat(...array) : [];
}

function flattenDeep(array) {
  if (!Array.isArray(array)) return [];
  const out = [];
  for (const item of array) {
    if (Array.isArray(item)) out.push(...flattenDeep(item));
    else out.push(item);
  }
  return out;
}

function compact(array) {
  return Array.isArray(array) ? array.filter(Boolean) : [];
}

function chunk(array, size = 1) {
  if (!Array.isArray(array) || size < 1) return [];
  const n = Math.floor(size);
  const out = [];
  for (let i = 0; i < array.length; i += n) out.push(array.slice(i, i + n));
  return out;
}

function sortBy(collection, iteratees) {
  const arr = Array.isArray(collection) ? collection.slice() : (collection ? Object.values(collection) : []);
  const fns = (Array.isArray(iteratees) ? iteratees : [iteratees]).map(iterateeFn);
  return arr.sort((a, b) => {
    for (const fn of fns) {
      const va = fn(a), vb = fn(b);
      if (va < vb) return -1;
      if (va > vb) return 1;
    }
    return 0;
  });
}

function orderBy(collection, iteratees, orders) {
  const arr = Array.isArray(collection) ? collection.slice() : (collection ? Object.values(collection) : []);
  const fns = (Array.isArray(iteratees) ? iteratees : [iteratees]).map(iterateeFn);
  const dirs = Array.isArray(orders) ? orders : [orders];
  return arr.sort((a, b) => {
    for (let i = 0; i < fns.length; i++) {
      const va = fns[i](a), vb = fns[i](b);
      const mult = String(dirs[i] || 'asc').toLowerCase() === 'desc' ? -1 : 1;
      if (va < vb) return -1 * mult;
      if (va > vb) return 1 * mult;
    }
    return 0;
  });
}

function groupBy(collection, iteratee) {
  const out = {};
  const cb = iterateeFn(iteratee);
  each(collection, item => {
    const key = String(cb(item));
    if (!out[key]) out[key] = [];
    out[key].push(item);
  });
  return out;
}

function keyBy(collection, iteratee) {
  const out = {};
  const cb = iterateeFn(iteratee);
  each(collection, item => { out[String(cb(item))] = item; });
  return out;
}

function isEmpty(value) {
  if (value == null) return true;
  if (typeof value === 'string' || Array.isArray(value)) return value.length === 0;
  if (value instanceof Map || value instanceof Set) return value.size === 0;
  if (typeof value === 'object') return Object.keys(value).length === 0;
  return true;
}

function cloneDeep(value) {
  if (value == null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(cloneDeep);
  if (value instanceof Date) return new Date(value.getTime());
  if (value instanceof RegExp) return new RegExp(value.source, value.flags);
  const out = {};
  for (const key of Object.keys(value)) out[key] = cloneDeep(value[key]);
  return out;
}

function merge(target, ...sources) {
  if (target == null || typeof target !== 'object') return target;
  for (const src of sources) {
    if (src == null || typeof src !== 'object') continue;
    for (const key of Object.keys(src)) {
      const sv = src[key], tv = target[key];
      if (sv && typeof sv === 'object' && !Array.isArray(sv) && tv && typeof tv === 'object' && !Array.isArray(tv)) {
        merge(tv, sv);
      } else if (sv !== undefined) {
        target[key] = cloneDeep(sv);
      }
    }
  }
  return target;
}

function pick(obj, paths) {
  const out = {};
  if (obj == null) return out;
  for (const p of flatten(paths ? [paths] : [])) {
    if (p in Object(obj)) out[p] = obj[p];
  }
  return out;
}

function omit(obj, paths) {
  if (obj == null) return {};
  const excluded = new Set(flatten(paths ? [paths] : []).map(String));
  const out = {};
  for (const k of Object.keys(obj)) {
    if (!excluded.has(k)) out[k] = obj[k];
  }
  return out;
}

const methods = {
  each, forEach: each, map, filter, reject, find, findIndex, some, every,
  includes, contains: includes, reduce,
  uniq, uniqBy, flatten, flattenDeep, compact, chunk,
  slice: (a, s, e) => Array.isArray(a) ? a.slice(s, e) : [],
  take: (a, n = 1) => Array.isArray(a) ? a.slice(0, n) : [],
  drop: (a, n = 1) => Array.isArray(a) ? a.slice(n) : [],
  first: a => Array.isArray(a) ? a[0] : undefined,
  head: a => Array.isArray(a) ? a[0] : undefined,
  last: a => Array.isArray(a) && a.length ? a[a.length - 1] : undefined,
  without: (a, ...vals) => Array.isArray(a) ? a.filter(x => !vals.includes(x)) : [],
  difference: (a, ...rest) => {
    if (!Array.isArray(a)) return [];
    const ex = new Set(flatten(rest));
    return a.filter(x => !ex.has(x));
  },
  intersection: (...arrays) => {
    if (!arrays.length || !Array.isArray(arrays[0])) return [];
    const sets = arrays.slice(1).map(x => new Set(Array.isArray(x) ? x : []));
    return uniq(arrays[0]).filter(item => sets.every(s => s.has(item)));
  },
  union: (...arrays) => uniq(flatten(arrays)),
  zipObject: (props = [], vals = []) => {
    const out = {};
    for (let i = 0; i < props.length; i++) out[props[i]] = vals[i];
    return out;
  },
  sortBy, orderBy, groupBy, keyBy,
  isEmpty,
  isNil: v => v == null,
  isNull: v => v === null,
  isUndefined: v => v === undefined,
  isString: v => typeof v === 'string',
  isNumber: v => typeof v === 'number' && !Number.isNaN(v),
  isBoolean: v => typeof v === 'boolean',
  isArray: Array.isArray,
  isObject: v => v != null && (typeof v === 'object' || typeof v === 'function'),
  isPlainObject: v => Boolean(v) && Object.prototype.toString.call(v) === '[object Object]',
  isFunction: v => typeof v === 'function',
  isEqual: (a, b) => JSON.stringify(a) === JSON.stringify(b),
  get, set, has, pick, omit,
  keys: o => o == null ? [] : Object.keys(o),
  values: o => o == null ? [] : Object.values(o),
  entries: o => o == null ? [] : Object.entries(o),
  toPairs: o => o == null ? [] : Object.entries(o),
  fromPairs: pairs => {
    const out = {};
    if (Array.isArray(pairs)) for (const p of pairs) if (p) out[p[0]] = p[1];
    return out;
  },
  assign: Object.assign,
  extend: Object.assign,
  merge,
  defaults: (target, ...sources) => {
    const out = Object(target);
    for (const s of sources) {
      if (s != null) for (const k of Object.keys(s)) if (out[k] === undefined) out[k] = s[k];
    }
    return out;
  },
  clone: v => Array.isArray(v) ? v.slice() : (v && typeof v === 'object' ? Object.assign({}, v) : v),
  cloneDeep,
  trim: (s = '', chars) => {
    const str = String(s);
    if (!chars) return str.trim();
    const esc = String(chars).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return str.replace(new RegExp(`^[${esc}]+|[${esc}]+$`, 'g'), '');
  },
  trimStart: (s = '') => String(s).trimStart(),
  trimEnd: (s = '') => String(s).trimEnd(),
  padStart: (s = '', len = 0, ch = ' ') => String(s).padStart(len, ch),
  padEnd: (s = '', len = 0, ch = ' ') => String(s).padEnd(len, ch),
  capitalize: (s = '') => { const str = String(s); return str ? str[0].toUpperCase() + str.slice(1).toLowerCase() : ''; },
  escape: (s = '') => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),
  unescape: (s = '') => String(s).replace(/&(?:amp|lt|gt|quot|#39|#x27);/g, m => ({'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&#39;':"'",'&#x27;':"'"}[m] || m)),
  range: (start = 0, end, step) => {
    if (end === undefined) { end = start; start = 0; }
    if (step === undefined) step = start < end ? 1 : -1;
    const out = [];
    if (step === 0) return out;
    for (let i = start; step > 0 ? i < end : i > end; i += step) out.push(i);
    return out;
  },
  random: (lower = 0, upper = 1) => Math.floor(Math.random() * (upper - lower + 1)) + lower,
  clamp: (n, lower, upper) => Math.min(Math.max(Number(n), lower), upper),
  sum: a => Array.isArray(a) ? a.reduce((s, x) => s + Number(x || 0), 0) : 0,
  max: a => Array.isArray(a) && a.length ? Math.max(...a) : undefined,
  min: a => Array.isArray(a) && a.length ? Math.min(...a) : undefined,
  noop: () => undefined,
  identity: x => x,
  times: (n, fn = x => x) => Array.from({length: Math.max(0, Number(n) || 0)}, (_, i) => fn(i)),
  debounce: fn => fn,
  throttle: fn => fn
};

function createChain(val) {
  const wrapper = {_wrapped: val, value() { return this._wrapped; }, toJSON() { return this._wrapped; }};
  for (const name of Object.keys(methods)) {
    wrapper[name] = function(...args) {
      const res = methods[name](this._wrapped, ...args);
      return createChain(res);
    };
  }
  return wrapper;
}

export function _(value) {
  return createChain(value);
}
Object.assign(_, methods);
_.chain = createChain;

export default _;
