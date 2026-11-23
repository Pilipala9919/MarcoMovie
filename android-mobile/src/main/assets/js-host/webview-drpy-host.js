/* Clean-room off-screen WebView host for async JS / CatVod / DRPY2 spiders. */
(function () {
  'use strict';

  var bridge = window.__mmBridge;
  var activeSpider = null;
  var docCacheKeys = [];
  var docCacheMap = Object.create(null);
  var MAX_DOC_CACHE = 16;

  function hashString(str) {
    var h = 2166136261;
    var s = String(str || '');
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(16) + ':' + s.length;
  }

  function parseHtmlDoc(html) {
    if (html && typeof html === 'object' && html.querySelectorAll) return html;
    var text = String(html || '');
    var key = hashString(text);
    if (docCacheMap[key]) return docCacheMap[key];
    var parser = new DOMParser();
    var doc = parser.parseFromString(text, 'text/html');
    docCacheKeys.push(key);
    docCacheMap[key] = doc;
    while (docCacheKeys.length > MAX_DOC_CACHE) {
      var oldest = docCacheKeys.shift();
      delete docCacheMap[oldest];
    }
    return doc;
  }

  function splitSelectorChain(selector) {
    var parts = String(selector || '').trim().split(/\s+/);
    var steps = [];
    for (var i = 0; i < parts.length; i++) {
      var token = parts[i].trim();
      if (!token) continue;
      var eqMatch = token.match(/^(.*?):eq\((-?\d+)\)$/);
      if (eqMatch) {
        steps.push({ sel: eqMatch[1] || '*', eq: parseInt(eqMatch[2], 10) });
      } else {
        steps.push({ sel: token, eq: null });
      }
    }
    return steps;
  }

  function queryElements(root, selector) {
    if (!root || !selector) return [];
    var excludeParts = String(selector).split('--');
    var mainSel = excludeParts[0].trim();
    var excludes = excludeParts.slice(1).map(function (s) { return s.trim(); }).filter(Boolean);
    if (!mainSel) return [];

    var nodes = [root];
    if (mainSel.indexOf(':eq(') >= 0) {
      var steps = splitSelectorChain(mainSel);
      for (var i = 0; i < steps.length; i++) {
        var step = steps[i];
        var next = [];
        for (var j = 0; j < nodes.length; j++) {
          var found = [];
          try {
            found = Array.prototype.slice.call(nodes[j].querySelectorAll(step.sel));
          } catch (e) {
            found = [];
          }
          if (step.eq !== null) {
            var idx = step.eq < 0 ? found.length + step.eq : step.eq;
            if (idx >= 0 && idx < found.length) next.push(found[idx]);
          } else {
            for (var k = 0; k < found.length; k++) next.push(found[k]);
          }
        }
        nodes = next;
      }
    } else {
      try {
        nodes = Array.prototype.slice.call(root.querySelectorAll(mainSel));
      } catch (e) {
        nodes = [];
      }
    }

    if (excludes.length > 0) {
      nodes = nodes.map(function (el) {
        var clone = el.cloneNode(true);
        for (var i = 0; i < excludes.length; i++) {
          try {
            var bad = clone.querySelectorAll(excludes[i]);
            for (var j = 0; j < bad.length; j++) {
              if (bad[j].parentNode) bad[j].parentNode.removeChild(bad[j]);
            }
          } catch (e) {}
        }
        return clone;
      });
    }
    return nodes;
  }

  function extractAttr(el, attr) {
    if (!el) return '';
    var a = String(attr || 'Text').trim();
    if (!a || a === 'Text' || a === 'text') return (el.textContent || '').trim();
    if (a === 'Html' || a === 'html') return el.innerHTML || '';
    if (a === 'OuterHtml' || a === 'outerHtml') return el.outerHTML || '';
    return (el.getAttribute(a) || '').trim();
  }

  function urljoin(base, rel) {
    if (!rel) return '';
    var r = String(rel).trim();
    if (/^https?:\/\//i.test(r)) return r;
    if (!base) return r;
    try {
      return new URL(r, base).href;
    } catch (e) {
      return r;
    }
  }

  function pdfa(html, rule) {
    if (!html || !rule) return [];
    var doc = parseHtmlDoc(html);
    var alts = String(rule).split('||');
    for (var i = 0; i < alts.length; i++) {
      var sel = alts[i].trim();
      if (!sel) continue;
      var els = queryElements(doc, sel);
      if (els.length > 0) {
        return els.map(function (el) { return el.outerHTML; });
      }
    }
    return [];
  }

  function pdfh(html, rule, baseUrl) {
    if (!html || !rule) return '';
    var doc = parseHtmlDoc(html);
    var alts = String(rule).split('||');
    for (var i = 0; i < alts.length; i++) {
      var candidate = alts[i].trim();
      if (!candidate) continue;
      var parts = candidate.split('&&');
      var sel = parts[0].trim();
      var attr = parts.length > 1 ? parts[1].trim() : 'Text';
      var regex = parts.length > 2 ? parts.slice(2).join('&&').trim() : '';
      var els = sel ? queryElements(doc, sel) : [doc.body || doc.documentElement];
      if (els.length === 0) continue;
      var val = extractAttr(els[0], attr);
      if (regex && val) {
        try {
          var m = val.match(new RegExp(regex));
          if (m) val = m[1] !== undefined ? m[1] : m[0];
        } catch (e) {}
      }
      if (val) {
        return baseUrl ? urljoin(baseUrl, val) : val;
      }
    }
    return '';
  }

  function pd(html, rule, baseUrl) {
    return pdfh(html, rule, baseUrl || '');
  }

  function reqSync(url, opt) {
    if (!bridge || !bridge.req) {
      throw new Error('Native HTTP bridge unavailable');
    }
    var raw = bridge.req(String(url || ''), JSON.stringify(opt || {}));
    return JSON.parse(raw || '{}');
  }

  function req(url, opt) {
    return Promise.resolve().then(function () {
      return reqSync(url, opt);
    });
  }

  function request(url, opt) {
    var res = reqSync(url, opt);
    return res && res.content !== undefined ? String(res.content) : '';
  }

  var localStore = {
    get: function (group, key) {
      var k = arguments.length >= 2 ? String(group) + ':' + String(key) : String(group);
      return bridge && bridge.localGet ? String(bridge.localGet(k) || '') : '';
    },
    set: function (group, key, value) {
      var k = arguments.length >= 3 ? String(group) + ':' + String(key) : String(group);
      var v = arguments.length >= 3 ? String(value || '') : String(key || '');
      if (bridge && bridge.localSet) bridge.localSet(k, v);
    },
    delete: function (group, key) {
      var k = arguments.length >= 2 ? String(group) + ':' + String(key) : String(group);
      if (bridge && bridge.localDelete) bridge.localDelete(k);
    }
  };

  function base64Encode(text) {
    try {
      return btoa(unescape(encodeURIComponent(String(text || ''))));
    } catch (e) {
      return btoa(String(text || ''));
    }
  }

  function base64Decode(encoded) {
    var raw = atob(String(encoded || '').replace(/\s+/g, ''));
    try {
      return decodeURIComponent(escape(raw));
    } catch (e) {
      return raw;
    }
  }

  function md5X(text) {
    if (window.CryptoJS && window.CryptoJS.MD5) {
      return window.CryptoJS.MD5(String(text || '')).toString();
    }
    throw new Error('CryptoJS MD5 unavailable');
  }

  window.req = req;
  window.reqSync = reqSync;
  window.request = request;
  window.getHtml = request;
  window.pdfa = pdfa;
  window.pdfh = pdfh;
  window.pd = pd;
  window.urljoin = urljoin;
  window.local = localStore;
  window.base64Encode = base64Encode;
  window.base64Decode = base64Decode;
  window.md5X = md5X;
  window.Crypto = window.CryptoJS;

  async function instantiateCode(code) {
    var src = String(code || '');
    var looksEsModule = /(?:^|[;\n])\s*(?:export\s+(?:default\b|(?:async\s+)?function\b|const\b|let\b|var\b|class\b|\{|\*)|import\s)/.test(src);
    if (looksEsModule) {
      var blob = new Blob([src], { type: 'text/javascript' });
      var blobUrl = URL.createObjectURL(blob);
      try {
        var mod = await import(blobUrl);
        if (mod && mod.default) {
          if (typeof mod.default === 'function') return mod.default();
          if (typeof mod.default.__jsEvalReturn === 'function') return mod.default.__jsEvalReturn();
          return mod.default;
        }
        if (mod && typeof mod.__jsEvalReturn === 'function') return mod.__jsEvalReturn();
        return mod;
      } finally {
        URL.revokeObjectURL(blobUrl);
      }
    }
    var moduleObj = { exports: {} };
    var exportsObj = moduleObj.exports;
    var factory = new Function(
      'module',
      'exports',
      'req',
      'request',
      'pdfa',
      'pdfh',
      'pd',
      'local',
      'CryptoJS',
      'Crypto',
      src + '\n;if (typeof __jsEvalReturn === "function") return __jsEvalReturn(); return module.exports;'
    );
    var res = factory(
      moduleObj,
      exportsObj,
      req,
      request,
      pdfa,
      pdfh,
      pd,
      localStore,
      window.CryptoJS,
      window.CryptoJS
    );
    if (typeof res === 'function') return res();
    if (res && res.default) return typeof res.default === 'function' ? res.default() : res.default;
    return res;
  }

  function normalizeOutput(val) {
    if (val === undefined || val === null) return '';
    if (typeof val === 'string') return val;
    return JSON.stringify(val);
  }

  window.__mmHost = {
    load: function (callId, code, cfgJson) {
      Promise.resolve()
        .then(async function () {
          var cfg = JSON.parse(cfgJson || '{}');
          activeSpider = await instantiateCode(code);
          if (!activeSpider || typeof activeSpider !== 'object') {
            throw new Error('Spider module did not export an object');
          }
          if (typeof activeSpider.init === 'function') {
            await Promise.resolve(activeSpider.init(cfg));
          }
          return 'ok';
        })
        .then(function (ok) {
          bridge.resolve(callId, String(ok));
        })
        .catch(function (err) {
          bridge.reject(callId, err && err.message ? String(err.message) : String(err));
        });
    },
    call: function (callId, method, argsJson) {
      Promise.resolve()
        .then(async function () {
          if (!activeSpider) throw new Error('WebView spider not initialized');
          var fn = activeSpider[method];
          if (typeof fn !== 'function') {
            if (method === 'homeVod') return '{"list":[]}';
            throw new Error('Method not found: ' + method);
          }
          var args = JSON.parse(argsJson || '[]');
          var result = await Promise.resolve(fn.apply(activeSpider, args));
          return normalizeOutput(result);
        })
        .then(function (out) {
          bridge.resolve(callId, out);
        })
        .catch(function (err) {
          bridge.reject(callId, err && err.message ? String(err.message) : String(err));
        });
    }
  };
})();
