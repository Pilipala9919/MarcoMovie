import {JSONPath} from 'assets://js-host/jsonpath.mjs';

function rootTag(fragment) {
  const m = /^\s*<([A-Za-z][A-Za-z0-9:-]*)/.exec(fragment || '');
  return m ? m[1] : 'body';
}

function hostOne(html, expr) {
  if (typeof globalThis.__hostHtml === 'function') {
    return globalThis.__hostHtml(String(html || ''), String(expr || ''), 'one');
  }
  return '';
}

function hostMany(html, selector) {
  if (!selector || typeof globalThis.__hostHtml !== 'function') return [];
  try {
    return JSON.parse(globalThis.__hostHtml(String(html || ''), String(selector), 'many'));
  } catch (_) {
    return [];
  }
}

export function load(html) {
  const docHtml = String(html == null ? '' : html);

  function wrap(fragments) {
    const items = Array.isArray(fragments) ? fragments.map(f => (f && typeof f === 'object' && typeof f.__outerHtml === 'string') ? f.__outerHtml : String(f || '')).filter(Boolean) : [];
    const collection = items.map(f => ({__outerHtml: f}));
    const api = {
      length: collection.length,
      toArray() { return collection.slice(); },
      get(index) { return index == null ? collection.slice() : collection[index]; },
      eq(index) {
        const idx = index < 0 ? collection.length + index : index;
        return wrap(idx >= 0 && idx < items.length ? [items[idx]] : []);
      },
      first() { return api.eq(0); },
      last() { return api.eq(collection.length - 1); },
      each(fn) {
        for (let i = 0; i < collection.length; i++) {
          if (fn.call(collection[i], i, collection[i]) === false) break;
        }
        return api;
      },
      map(fn) {
        const mapped = [];
        for (let i = 0; i < collection.length; i++) {
          const val = fn.call(collection[i], i, collection[i]);
          if (val != null) mapped.push(val);
        }
        return {
          length: mapped.length,
          get(idx) { return idx == null ? mapped.slice() : mapped[idx]; },
          toArray() { return mapped.slice(); },
          each(cb) { mapped.forEach((v, idx) => cb.call(v, idx, v)); return this; }
        };
      },
      find(selector) {
        const out = [];
        for (const frag of items) {
          const inner = hostOne(frag, rootTag(frag) + '&&Html');
          if (inner) out.push(...hostMany(inner, selector));
        }
        return wrap(out);
      },
      text() {
        return items.map(frag => hostOne(frag, 'Text')).join('');
      },
      html() {
        if (!items.length) return '';
        return hostOne(items[0], rootTag(items[0]) + '&&Html');
      },
      attr(name) {
        if (!items.length || !name) return undefined;
        const val = hostOne(items[0], rootTag(items[0]) + '&&' + name);
        return val === '' && !new RegExp('\\b' + String(name).replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*=', 'i').test(items[0])
          ? undefined
          : val;
      },
      val() {
        const v = api.attr('value');
        return v === undefined ? api.text() : v;
      },
      parent() { return wrap([]); },
      children(selector) { return selector ? api.find(selector) : api.find('> *'); }
    };
    for (let i = 0; i < collection.length; i++) {
      api[i] = collection[i];
    }
    api[Symbol.iterator] = function* () {
      for (let i = 0; i < collection.length; i++) yield collection[i];
    };
    return api;
  }

  function $(selector, context) {
    if (!selector) return wrap([]);
    if (typeof selector === 'object') {
      if (typeof selector.__outerHtml === 'string') return wrap([selector.__outerHtml]);
      if (Array.isArray(selector)) return wrap(selector);
      return selector;
    }
    const str = String(selector).trim();
    if (str.startsWith('<') && str.endsWith('>')) return wrap([str]);
    if (context) {
      const ctx = $(context);
      return ctx.find(str);
    }
    return wrap(hostMany(docHtml, str));
  }

  $.html = () => docHtml;
  $.text = () => hostOne(docHtml, 'Text');
  $.load = load;
  return $;
}

export function jp(path, json) {
  return JSONPath({path, json, wrap: true});
}

export function jinja2(template, values) {
  if (typeof globalThis.jinja !== 'undefined') return globalThis.jinja.render(template, values);
  return String(template || '').replace(/\{\{\s*([A-Za-z0-9_.$]+)\s*\}\}/g, (_, key) => {
    const parts = key.split('.');
    let cur = values;
    for (const p of parts) {
      if (cur == null) return '';
      cur = cur[p];
    }
    return cur == null ? '' : String(cur);
  });
}

export default {
  load,
  jp,
  jinja2
};
