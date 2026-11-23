// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// App-owned CatPaw host. Imported bundles are user code, never bundled with the app.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');
const HASH = /^[a-f0-9]{64}$/;

if (!isMainThread) {
  // Node 18's built-in fetch initializes a WASM HTTP parser even under --jitless.
  // Use a pinned, pure-JS Fetch implementation on iOS; preserve the standard API.
  if (typeof WebAssembly === 'undefined') {
    // Node 22 lazily initializes Undici even when its global accessor is
    // redefined. Delete those accessors before installing the no-WASM shim.
    for (const name of ['Headers', 'Request', 'Response', 'FormData', 'Blob', 'File', 'fetch']) {
      delete globalThis[name];
    }
    const fetch = require('./fetch.cjs');
    for (const name of ['Headers', 'Request', 'Response', 'FormData', 'Blob', 'File']) {
      Object.defineProperty(globalThis, name, { configurable: true, writable: true, value: fetch[name] });
    }
    Object.defineProperty(globalThis, 'fetch', { configurable: true, writable: true, value: fetch.default });
  }
  // A separate Node isolate gives each subscription its own globals and module cache.
  const net = require('node:net');
  // Bundles must advertise this device's loopback listener, not a LAN address.
  require('node:os').networkInterfaces = () => ({ lo: [{ address: '127.0.0.1',
    netmask: '255.0.0.0', family: 'IPv4', mac: '00:00:00:00:00:00', internal: true,
    cidr: '127.0.0.1/8' }] });
  const listen = net.Server.prototype.listen;
  net.Server.prototype.listen = function (...args) {
    const callback = args.find(v => typeof v === 'function');
    return listen.call(this, { host: '127.0.0.1', port: 0 }, callback);
  };
  process.env.NODE_PATH = workerData.state;
  let main;
  global.catServerFactory = handler => (main = http.createServer(handler));
  global.catDartServerPort = () => 0;
  global.messageToDart = async () => null;
  (async () => {
    const bundle = require(workerData.script);
    if (typeof bundle.start !== 'function') throw Error('entry');
    await bundle.start({});
    if (main && !main.listening) await new Promise((resolve, reject) => {
      main.once('listening', resolve); main.once('error', reject);
    });
    const endpoint = main?.address();
    if (!endpoint || endpoint.address !== '127.0.0.1') throw Error('listen');
    main.on('error', () => {});
    parentPort.postMessage({ port: endpoint.port });
  })().catch(() => { parentPort.postMessage({ error: 'bundle_start_failed' }); });
} else {
  const net = require('node:net');
  const embedded = process.argv.includes('--embedded');
  process.on('uncaughtException', () => {});
  process.on('unhandledRejection', () => {});
  const MAX_RUNTIMES = 6;
  const root = path.resolve(process.argv[2]);
  const readyFile = path.resolve(process.argv[3]);
  const rebindFile = path.join(root, 'rebind.json');
  const secret = crypto.randomBytes(32).toString('hex');
  const runtimes = new Map();
  const loading = new Map();
  const releases = new Map();
  let loadQueue = Promise.resolve();
  let rebindQueue = Promise.resolve();
  let bootstrap = null;
  let idleBootstrapWorker = null;
  async function dropIdleBootstrapWorker() {
    const w = idleBootstrapWorker;
    idleBootstrapWorker = null;
    if (w) { try { await w.terminate(); } catch (_) {} }
  }
  let server = null;
  let writeCounter = 0;
  let lastRebindSeq = 0;
  let closing = false, resetting = false;
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  try { fs.unlinkSync(rebindFile); } catch (_) {}
  const respond = (res, status, body) => {
    if (res.destroyed || res.writableEnded) return;
    try {
      if (!res.headersSent) {
        res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      }
      res.end(JSON.stringify(body));
    } catch (_) {
      try { res.destroy(); } catch (_) {}
    }
  };
  async function portBootstrap(req, res) {
    if (resetting || closing) { req.resume(); return respond(res, 409, { error: 'runtime_reset' }); }
    if (bootstrap) { req.resume(); return respond(res, 429, { error: 'bootstrap_busy' }); }
    let finish;
    const task = { worker: null, cancel: null, done: new Promise(resolve => { finish = resolve; }) };
    bootstrap = task;
    const cancelled = () => { task.cancel?.(); };
    res.once('close', cancelled);
    let status = 200, payload = null;
    try {
      const body = await new Promise((resolve, reject) => {
        const chunks = []; let size = 0, finished = false;
        const done = (error, value) => {
          if (finished) return; finished = true;
          clearTimeout(timer); req.off('data', data); req.off('end', end); req.off('error', failed);
          task.cancel = null;
          if (error) reject(error); else resolve(value);
        };
        const data = chunk => { size += chunk.length; if (size > 17 * 1024) { req.resume(); done(Error('bootstrap_request')); } else chunks.push(chunk); };
        const end = () => { try { done(null, JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch (_) { done(Error('bootstrap_request')); } };
        const failed = () => done(Error('bootstrap_cancelled'));
        const timer = setTimeout(() => { req.resume(); done(Error('bootstrap_timeout')); }, 2000);
        task.cancel = failed;
        req.on('data', data); req.once('end', end); req.once('error', failed);
      });
      const ftyAdapters = ['jpys-v1', 'jpj-v1', 'nmyswv-v1', 'hmys-v1', 'app99-v1', 'appsx-v1', 'newcz-v1', 'libvio-v1', 'ygp-v1', 'kanqiu-v1', 'doubao-v1', 'livegz-v1', 'alllive-v1', 'tingshu275-v1', 'yueting-v1', 'seedhub-v1', 'szps-v1', 'ypanso-v1', 'bpanso-v1', 'kkss-v1', 'uuss-v1', 'jumitv-v1', 'wexappv7-v1', 'wexguazi-v1', 'wexduboku-v1', 'wexwencai-v1', 'wexfengye-v1', 'wexjianpian-v1', 'wexjuxiafan-v1', 'wexrebo-v1', 'wexbobo-v1', 'wexikanbot-v1', 'wexyiys-v1', 'wexhanxiaoquan-v1', 'wexduoduo-v1', 'wexhuban-v1', 'wexkuaiying-v1', 'wexlabi-v1', 'wexmuou-v1', 'wexshandian-v1', 'wexxiaopan-v1', 'wexzhizhen-v1', 'wexwogg-v1', 'wexhuajuan-v1', 'wexjutou-v1', 'wexzhinan-v1', 'wexwoniu-v1', 'wexpianku-v1', 'wexqiwei-v1', 'wexyidong-v1', 'wexaipanso-v1', 'wexhaiyin-v1', 'wexquanpan-v1', 'wexkaka-v1', 'wexmodu-v1', 'wexhaokan-v1', 'wexqimiao-v1', 'wexkuwoa-v1', 'wexqingting-v1', 'wexsportguazi-v1', 'wexkafei-v1', 'wexkanqiutong-v1', 'wexkanqiu-v1', 'wexwwe-v1'];
      const needsExtension = ['t4-v1', 'apptt-v1'].includes(body?.adapter);
      const optionalExtension = ftyAdapters.includes(body?.adapter);
      const bodyKeys = body && !Array.isArray(body) ? Object.keys(body).sort().join(',') : '';
      const validKeys = needsExtension
        ? bodyKeys === 'adapter,artifactHash,extension,version'
        : optionalExtension
          ? (bodyKeys === 'adapter,artifactHash,version' || bodyKeys === 'adapter,artifactHash,extension,version')
          : bodyKeys === 'adapter,artifactHash,version';
      if (!validKeys ||
          body.version !== 1 || (!optionalExtension && !['dm84-v1', 'auete-v1', 'bttwoo-v1', 'appgz-v1', 't4-v1', 'apptt-v1', 'fy-v1'].includes(body.adapter)) || typeof body.artifactHash !== 'string' || !HASH.test(body.artifactHash) ||
          (needsExtension && (typeof body.extension !== 'string' || !body.extension.trim() || Buffer.byteLength(body.extension) > 16 * 1024)) ||
          (optionalExtension && Object.prototype.hasOwnProperty.call(body, 'extension') && (typeof body.extension !== 'string' || Buffer.byteLength(body.extension) > 16 * 1024))) throw Error('bootstrap_request');
      if (res.destroyed || closing || resetting) throw Error('bootstrap_cancelled');
      const imports = path.join(root, 'imports');
      try { if (fs.lstatSync(imports).isSymbolicLink() || !fs.lstatSync(imports).isDirectory()) throw Error(); }
      catch (_) { throw Error('guard_artifact_invalid'); }
      const job = { file: path.join(imports, body.artifactHash + '.jar'), hash: body.artifactHash, adapter: body.adapter, extension: body.extension, reusable: true };
      let worker = idleBootstrapWorker;
      const reused = Boolean(worker);
      idleBootstrapWorker = null;
      if (!worker) {
        worker = new Worker(path.join(__dirname, 'drpy-bootstrap-worker.cjs'), {
          workerData: job,
          resourceLimits: { maxOldGenerationSizeMb: 96, maxYoungGenerationSizeMb: 16, stackSizeMb: 2 },
          stdout: true, stderr: true,
        });
        worker.stdout.resume(); worker.stderr.resume();
      }
      task.worker = worker;
      let keepWarm = false;
      const result = await new Promise((resolve, reject) => {
        let settled = false;
        const cleanupListeners = () => {
          worker.off('message', onMsg);
          worker.off('error', onErr);
          worker.off('exit', onExit);
        };
        const done = (error, value) => {
          if (settled) return; settled = true; clearTimeout(timer); task.cancel = null;
          cleanupListeners();
          if (error) reject(error); else resolve(value);
        };
        const onMsg = value => done(null, value);
        const onErr = () => done(Error('guard_artifact_invalid'));
        const onExit = () => done(Error('guard_artifact_invalid'));
        const timer = setTimeout(() => done(Error('bootstrap_timeout')), 3800);
        task.cancel = () => done(Error('bootstrap_cancelled'));
        worker.once('message', onMsg);
        worker.once('error', onErr);
        worker.once('exit', onExit);
        if (reused) worker.postMessage(job);
      });
      if (result && result.reusable && !closing && !resetting) {
        keepWarm = true;
        delete result.reusable;
      }
      if (result.error) throw Error(result.error);
      payload = result;
      if (keepWarm && task.worker === worker) {
        worker.once('exit', () => { if (idleBootstrapWorker === worker) idleBootstrapWorker = null; });
        worker.once('error', () => { if (idleBootstrapWorker === worker) idleBootstrapWorker = null; });
        idleBootstrapWorker = worker;
        task.worker = null;
      }
    } catch (error) {
      const code = ['guard_artifact_unsupported', 'guard_artifact_integrity', 'guard_artifact_invalid', 'bootstrap_timeout', 'bootstrap_request'].includes(error.message) ? error.message : 'guard_artifact_invalid';
      status = code === 'bootstrap_request' ? 400 : code === 'bootstrap_timeout' ? 504 : 422;
      payload = { error: code };
    } finally {
      res.off('close', cancelled);
      try { await task.worker?.terminate(); } catch (_) {}
      if (bootstrap === task) bootstrap = null;
      finish();
    }
    if (!res.destroyed && !closing && payload) respond(res, status, payload);
  }
  async function stop(instance) {
    try { instance.http?.close(); } catch (_) {}
    clearTimeout(instance.callTimer);
    try { instance.manager?.close(); } catch (_) {}
    try { await instance.worker.terminate(); } catch (_) {}
  }
  function load(hash) {
    if (resetting || closing) return Promise.reject(Error('runtime_reset'));
    if (runtimes.has(hash)) return runtimes.get(hash).ready;
    if (loading.has(hash)) return loading.get(hash);
    // Serialize only creation/eviction, not worker startup or source requests.
    // Otherwise simultaneous loads can each see a spare slot and exceed cap.
    const epoch = releases.get(hash) || 0;
    const queuedUntil = Date.now()+20000;
    const created = loadQueue.then(()=>createRuntime(hash,epoch,queuedUntil));
    loadQueue = created.then(()=>{},()=>{});
    const ready = created.then(instance=>instance.ready).finally(()=>loading.delete(hash));
    loading.set(hash,ready);
    return ready;
  }
  async function createRuntime(hash,epoch,queuedUntil) {
    if (!HASH.test(hash)) throw Error('bundle_id');
    if ((releases.get(hash)||0)!==epoch || closing || resetting) throw Error('bundle_released');
    if (runtimes.has(hash)) return runtimes.get(hash);
    // Do not evict an active playback to make room for a background source search.
    // Cap protected idle played runtimes to the 2 most recent so concurrent search
    // batches never starve all slots.
    while (runtimes.size >= MAX_RUNTIMES) {
      const now = Date.now();
      const protectedPlayed = new Set(
        [...runtimes.entries()]
          .filter(([, r]) => r.played > 0 && now - r.played <= 15 * 60 * 1000)
          .sort((a, b) => b[1].played - a[1].played)
          .slice(0, 2)
          .map(([k]) => k)
      );
      const idle = [...runtimes.entries()].filter(([k, r]) => r.port && !r.active && !r.manager &&
        !protectedPlayed.has(k)).sort((a,b) => a[1].used - b[1].used)[0];
      if (!idle) {
        if (closing || resetting || Date.now()>=queuedUntil || (releases.get(hash)||0)!==epoch) throw Error('runtime_limit');
        // Existing CatPaw playback remains protected. A running/starting DRPY
        // query can free a slot; wait asynchronously instead of dropping
        // the app's six-source concurrent search batch.
        if (![...runtimes.values()].some(r=>r.kind==='drpy'||!r.port)) throw Error('runtime_limit');
        await new Promise(resolve=>setTimeout(resolve,20));
        continue;
      }
      runtimes.delete(idle[0]); await stop(idle[1]);
    }
    if (Date.now()>=queuedUntil) throw Error('runtime_queue_timeout');
    const folder = path.join(root, hash);
    let script = path.join(folder, 'index.cjs');
    const manifestFile = path.join(folder, 'drpy.json');
    const kind = fs.existsSync(script) ? 'catpaw' : 'drpy';
    if (kind === 'catpaw' && fs.existsSync(manifestFile)) throw Error('bundle_ambiguous');
    if (kind === 'drpy') script = manifestFile;
    let state = path.join(folder, 'state');
    const stat = fs.statSync(script);
    if (!stat.isFile() || stat.size > 16 * 1024 * 1024) throw Error('bundle_size');
    const bytes = fs.readFileSync(script);
    if (crypto.createHash('sha256').update(bytes).digest('hex') !== hash) throw Error('bundle_changed');
    let manifest;
    if (kind === 'drpy') {
      manifest = require('./drpy-schema.cjs').validateManifest(JSON.parse(bytes.toString('utf8')));
      state = path.join(root, 'drpy-state', manifest.sourceId);
      // A rule refresh keeps its storage ID; never run two stale copies against
      // the same persistent state file at once.
      for (const [otherHash,other] of runtimes) {
        if (other.kind !== 'drpy' || other.sourceId !== manifest.sourceId) continue;
        if (other.active) throw Error('drpy_source_busy');
        runtimes.delete(otherHash); await stop(other);
      }
    }
    if ((releases.get(hash)||0)!==epoch || closing || resetting) throw Error('bundle_released');
    fs.mkdirSync(state, { recursive: true, mode: 0o700 });
    if (kind === 'catpaw') syncPanConfigToState(state);
    const worker = new Worker(kind === 'drpy' ? path.join(__dirname,'drpy-worker.cjs') : __filename, {
      workerData: kind === 'drpy' ? {manifest,state} : { script, state }, stdout: true, stderr: true,
      resourceLimits: { maxOldGenerationSizeMb: kind === 'drpy' ? 128 : 256 },
    });
    // Source logs can contain cookies, query strings and media tokens.
    worker.stdout.resume(); worker.stderr.resume();
    const instance = { worker, kind, sourceId:manifest?.sourceId, ready: null, port: 0, active: 0, used: Date.now(), played: 0, manager: null,
      playedPaths: new Set(),
      http: kind === 'drpy' ? new (require('./drpy-http.cjs').SourceHttp)(manifest) : null, callTimer:null };
    instance.ready = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { stop(instance); reject(Error('bundle_timeout')); }, 25000);
      const ready = value => {
        clearTimeout(timer);
        if (Number.isInteger(value.port) && value.port > 0 && value.port < 65536) {
          instance.port = value.port; resolve(instance);
        } else { stop(instance); reject(Error('bundle_start_failed')); }
      };
      if (kind === 'catpaw') worker.once('message',ready);
      else worker.on('message',value=>{
        if(value.kind==='ready')ready(value);
        else if(value.kind==='fatal')ready({});
        else if(value.kind==='http'||value.kind==='cancel')instance.http.receive(value);
        else if(value.kind==='playback')instance.played=Date.now();
        else if(value.kind==='call-start') {
          clearTimeout(instance.callTimer);
          instance.callTimer=setTimeout(()=>stop(instance),Math.max(1,Math.min(21000,value.deadline-Date.now()+500)));
        } else if(value.kind==='call-end'){clearTimeout(instance.callTimer);instance.callTimer=null;}
      });
      worker.on('error', () => { clearTimeout(timer); reject(Error('bundle_start_failed')); });
      worker.once('exit', () => {
        try { instance.http?.close(); } catch (_) {}
        clearTimeout(instance.callTimer);
        try { instance.manager?.close(); } catch (_) {}
        clearTimeout(timer);
        if (runtimes.get(hash) === instance) runtimes.delete(hash);
        reject(Error('bundle_exited'));
      });
    });
    runtimes.set(hash, instance);
    return instance;
  }

  // A separate loopback origin preserves the source author's settings UI paths.
  // Only an explicit app request creates it; a one-time ticket establishes a
  // per-origin HttpOnly session. The playback endpoint never exposes admin paths.
  async function manage(instance) {
    if (instance.kind === 'drpy') throw Error('settings_unavailable');
    if (instance.manager) return instance.manager.open();
    const cookie = 'marco_' + crypto.randomBytes(12).toString('hex');
    const value = crypto.randomBytes(32).toString('hex');
    let ticket = '', expires = Date.now() + 15 * 60 * 1000;
    const backend = `http://127.0.0.1:${instance.port}`;
    const manager = http.createServer((req, res) => {
      req.on('error', () => {}); res.on('error', () => {});
      const addr = manager.address();
      if (!addr || typeof addr !== 'object' || !addr.port) return respond(res,503,{error:'settings_unavailable'});
      const origin = `http://127.0.0.1:${addr.port}`;
      if (req.headers.host !== `127.0.0.1:${addr.port}` ||
          (req.headers.origin && req.headers.origin !== origin)) return respond(res,403,{error:'forbidden'});
      res.setHeader('Referrer-Policy','no-referrer');
      res.setHeader('X-Frame-Options','DENY');
      res.setHeader('Cache-Control','no-store');
      if (ticket && req.method === 'GET' && req.url === '/authorize/' + ticket) {
        ticket = '';
        res.writeHead(303,{Location:'/website', 'Set-Cookie': `${cookie}=${value}; Path=/; HttpOnly; SameSite=Strict`});
        res.end(); return;
      }
      if (Date.now() > expires || !(req.headers.cookie || '').split(';').some(v=>v.trim()===`${cookie}=${value}`)) {
        return respond(res,403,{error:'settings_session_expired'});
      }
      expires = Date.now() + 15 * 60 * 1000;
      if (!req.url.startsWith('/') || req.url.startsWith('//')) return respond(res,400,{error:'path'});
      const headers = {...req.headers,host:`127.0.0.1:${instance.port}`};
      delete headers.cookie; delete headers.origin; delete headers['accept-encoding'];
      const upstream = http.request(backend+req.url,{method:req.method,headers},source=>{
        const output={...source.headers};
        delete output['set-cookie']; delete output['access-control-allow-origin'];
        const rewrite=text=>text.split(backend).join(origin);
        if(output.location) output.location=rewrite(output.location);
        const transformed=/json|text\/|javascript/i.test(String(output['content-type']||''));
        if(!transformed) {res.writeHead(source.statusCode,output);source.pipe(res);}
        else {
          delete output['content-length'];delete output['content-encoding'];
          let size=0;const chunks=[];
          source.on('data',chunk=>{size+=chunk.length;if(size>24*1024*1024){source.destroy();res.destroy();}else chunks.push(chunk);});
          source.on('end',()=>{if(!res.destroyed){res.writeHead(source.statusCode,output);res.end(rewrite(Buffer.concat(chunks).toString('utf8')));}});
        }
        source.on('error',()=>res.destroy());
      });
      upstream.setTimeout(30000,()=>upstream.destroy());
      upstream.on('error',()=>{if(!res.headersSent)respond(res,502,{error:'settings_request_failed'});else res.destroy();});
      res.on('close',()=>upstream.destroy());req.pipe(upstream);
    });
    manager.on('error', () => {});
    await new Promise((resolve,reject)=>{manager.once('error',reject);manager.listen(0,'127.0.0.1',resolve);});
    const expiry = setInterval(()=>{if(Date.now()>expires) session.close();},60000);
    expiry.unref();
    const session = instance.manager = {
      open() {ticket=crypto.randomBytes(32).toString('hex');expires=Date.now()+15*60*1000;
        const addr=manager.address();
        if(!addr||typeof addr!=='object'||!addr.port)throw Error('settings_unavailable');
        return `http://127.0.0.1:${addr.port}/authorize/${ticket}`;},
      close() {clearInterval(expiry);try{manager.close();manager.closeAllConnections?.();}catch(_){}instance.manager=null;},
    };
    return session.open();
  }

  function syncPanConfigToState(stateDir) {
    try {
      const srcFile = path.join(root, 'wexfnwconfig.json');
      if (!fs.existsSync(srcFile)) return null;
      const incoming = JSON.parse(fs.readFileSync(srcFile, 'utf8'));
      const pan = incoming?.pan;
      if (!pan || typeof pan !== 'object') return null;
      const dstFile = path.join(stateDir, 'wexfnwconfig.json');
      let existing = {};
      if (fs.existsSync(dstFile)) {
        try { existing = JSON.parse(fs.readFileSync(dstFile, 'utf8')) || {}; } catch (_) {}
      }
      if (!existing.pan || typeof existing.pan !== 'object') existing.pan = {};
      for (const [k, v] of Object.entries(pan)) {
        if (v && typeof v === 'object') {
          existing.pan[k] = { ...(existing.pan[k] || {}), ...v };
        }
      }
      fs.writeFileSync(dstFile, JSON.stringify(existing, null, 2) + '\n', 'utf8');
      return pan;
    } catch (_) {
      return null;
    }
  }

  function requestBackend(backend, method, reqPath, bodyObj) {
    return new Promise((resolve, reject) => {
      const payload = bodyObj !== undefined ? Buffer.from(JSON.stringify(bodyObj), 'utf8') : null;
      const headers = { host: new URL(backend).host };
      if (payload) {
        headers['content-type'] = 'application/json; charset=utf-8';
        headers['content-length'] = String(payload.length);
      }
      const r = http.request(backend + reqPath, { method, headers }, resp => {
        let size = 0; const chunks = [];
        resp.on('data', c => {
          size += c.length;
          if (size > 16 * 1024 * 1024) { resp.destroy(); reject(Error('too_large')); }
          else chunks.push(c);
        });
        resp.on('end', () => resolve({
          status: resp.statusCode || 500,
          headers: resp.headers,
          text: Buffer.concat(chunks).toString('utf8'),
        }));
        resp.on('error', reject);
      });
      r.setTimeout(35000, () => r.destroy(Error('timeout')));
      r.on('error', err => {
        if (err && ['ECONNREFUSED', 'ECONNRESET', 'ECONNABORTED'].includes(err.code)) {
          err.deadBackend = true;
        }
        reject(err);
      });
      if (payload) r.write(payload);
      r.end();
    });
  }

  function isSafeProxyTail(tail) {
    if (typeof tail !== 'string') return false;
    if (/[\x00-\x1f\x7f\\]/.test(tail) || /%00|%5c/i.test(tail)) return false;
    for (const seg of tail.split('/')) {
      if (seg === '.' || seg === '..') return false;
      let decoded;
      try { decoded = decodeURIComponent(seg); } catch (_) { return false; }
      if (/[\x00-\x1f\x7f\\]/.test(decoded)) return false;
      for (const part of decoded.split('/')) {
        if (part === '.' || part === '..') return false;
      }
    }
    return true;
  }

  function isAdminOrInternalPath(pathname) {
    if (typeof pathname !== 'string' || !pathname.startsWith('/')) return true;
    if (/^\/(?:website|config|full-config|admin|authorize|_)(?:\/|$)/i.test(pathname)) return true;
    if (/^\/spider\/[^/]+\/[^/]+\/(?:website|config|admin)(?:\/|$)/i.test(pathname)) return true;
    return false;
  }

  function isSpiderProxyPath(pathname) {
    const m = /^\/spider\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)\/proxy(?:\/(.*))?$/.exec(pathname);
    if (!m || m[1] === '.' || m[1] === '..' || m[2] === '.' || m[2] === '..') return false;
    return m[3] === undefined || isSafeProxyTail(m[3]);
  }

  function isStandardProxyPath(pathname) {
    const m = /^\/(?:api\/)?proxy(?:\/(.*))?$/.exec(pathname);
    if (m) return m[1] === undefined || isSafeProxyTail(m[1]);
    const apiSpider = /^\/api\/spider\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)\/proxy(?:\/(.*))?$/.exec(pathname);
    if (!apiSpider || apiSpider[1] === '.' || apiSpider[1] === '..' || apiSpider[2] === '.' || apiSpider[2] === '..') return false;
    return apiSpider[3] === undefined || isSafeProxyTail(apiSpider[3]);
  }

  function canonicalProxyPath(pathname) {
    if (typeof pathname !== 'string' || !pathname.startsWith('/')) return null;
    const out = [];
    for (const seg of pathname.split('/')) {
      let decoded;
      try { decoded = decodeURIComponent(seg); } catch (_) { return null; }
      out.push(encodeURIComponent(decoded));
    }
    return out.join('/');
  }

  function grantPlayedPath(instance, rawUrl, publicBase) {
    if (!instance?.playedPaths || typeof rawUrl !== 'string' || !rawUrl.startsWith(publicBase + '/')) return;
    let clean = rawUrl.trim();
    const pipe = clean.indexOf('|');
    if (pipe > publicBase.length && /(?:^|&)\s*(?:cookie|referer|user-agent|origin|authorization)\s*=/i.test(clean.slice(pipe + 1))) {
      clean = clean.slice(0, pipe).trim();
    }
    const at = clean.search(/@(?:Referer|User-Agent|Cookie|Origin|Authorization)=/i);
    if (at > publicBase.length) clean = clean.slice(0, at).trim();
    const rel = clean.slice(publicBase.length);
    let pathname;
    try { pathname = new URL('http://127.0.0.1' + rel).pathname; } catch (_) { return; }
    if (isAdminOrInternalPath(pathname) || !isSafeProxyTail(pathname.slice(1))) return;
    const key = canonicalProxyPath(pathname);
    if (!key) return;
    if (instance.playedPaths.size >= 256 && !instance.playedPaths.has(key)) {
      const oldest = instance.playedPaths.values().next().value;
      if (oldest !== undefined) instance.playedPaths.delete(oldest);
    }
    instance.playedPaths.add(key);
  }

  function recordPlayedUrls(instance, text, publicBase) {
    if (!instance?.playedPaths || typeof text !== 'string') return;
    const normalizedText = text.includes('\\/') ? text.replace(/\\\//g, '/') : text;
    if (!normalizedText.includes(publicBase)) return;
    const trimmed = text.trimStart();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        const parsed = JSON.parse(text);
        const stack = [parsed];
        let visited = 0;
        while (stack.length > 0 && visited < 512) {
          visited++;
          const current = stack.pop();
          if (typeof current === 'string') {
            if (current.startsWith(publicBase + '/')) {
              grantPlayedPath(instance, current, publicBase);
            } else if (current.startsWith('[') || current.startsWith('{')) {
              try {
                const nested = JSON.parse(current);
                if (nested && typeof nested === 'object') stack.push(nested);
              } catch (_) {}
            }
          } else if (Array.isArray(current)) {
            for (const item of current) stack.push(item);
          } else if (current && typeof current === 'object') {
            for (const val of Object.values(current)) stack.push(val);
          }
        }
      } catch (_) {}
    }
    let idx = 0;
    while (idx < normalizedText.length) {
      const pos = normalizedText.indexOf(publicBase + '/', idx);
      if (pos < 0) break;
      let end = pos + publicBase.length + 1;
      while (end < normalizedText.length) {
        const ch = normalizedText[end];
        if (ch === '"' || ch === "'" || ch === '\\' || ch === '\r' || ch === '\n' || ch === ' ' || ch === '\t' || ch === '<' || ch === '>') break;
        end++;
      }
      grantPlayedPath(instance, normalizedText.slice(pos, end), publicBase);
      idx = end;
    }
  }

  async function handleRequest(req, res) {
    req.on('error', () => {}); res.on('error', () => {});
    try {
      if (closing || req.headers.origin || !req.url || !req.url.startsWith('/' + secret + '/')) {
        return respond(res, 403, { error: 'forbidden' });
      }
      const route = req.url.slice(secret.length + 2);
      if (route === 'health' && req.method === 'GET') return respond(res, 200, { version: 1, runtime:process.versions.node });
      if (route === '_reset' && req.method === 'POST') {
        if (resetting) return respond(res,409,{error:'runtime_reset'});
        resetting=true;
        try {
          const pendingBootstrap=bootstrap;
          pendingBootstrap?.cancel?.();
          await dropIdleBootstrapWorker();
          for(const hash of new Set([...runtimes.keys(),...loading.keys()]))releases.set(hash,(releases.get(hash)||0)+1);
          const instances=[...runtimes.values()];runtimes.clear();
          await Promise.all(instances.map(stop));
          await loadQueue;
          await Promise.allSettled([...loading.values()]);
          await pendingBootstrap?.done;
          return respond(res,200,{reset:true});
        }finally{resetting=false;}
      }
      if (route === '_port-bootstrap' && req.method === 'POST') return portBootstrap(req, res);
      const match = /^([a-f0-9]{64})(\/.*)$/.exec(route);
      if (!match) return respond(res, 404, { error: 'route' });
      const hash = match[1], resource = match[2];
      if (resource === '/_release' && req.method === 'POST') {
        releases.set(hash,(releases.get(hash)||0)+1);
        const instance = runtimes.get(hash);
        if (instance) { runtimes.delete(hash); await stop(instance); }
        return respond(res, 200, { released: true });
      }
      if (resource === '/_manage' && req.method === 'POST') {
        try { return respond(res,200,{url:await manage(await load(hash))}); }
        catch (_) { return respond(res,503,{error:'settings_unavailable'}); }
      }
      // Only data/playback routes are exposed to the player, never the source's admin panel.
      // CatPaw also returns signed HLS/netdisk proxies under /spider/<site>/<version>/proxy/,
      // /proxy/, or play-minted media proxy routes. Validate normalized/decoded segments so
      // dot traversal or admin paths are always rejected.
      let normalizedPath;
      try { normalizedPath = new URL('http://127.0.0.1' + resource).pathname; }
      catch (_) { return respond(res, 400, { error: 'route' }); }
      const rawPath = resource.split(/[?#]/)[0];
      const rawPathSafe = rawPath.startsWith('/') && isSafeProxyTail(rawPath.slice(1));
      const isReadMethod = ['GET', 'HEAD'].includes(req.method);
      const spiderProxy = isReadMethod && rawPathSafe && isSpiderProxyPath(normalizedPath);
      const standardProxy = isReadMethod && rawPathSafe && isStandardProxyPath(normalizedPath);
      const canonicalPath = canonicalProxyPath(normalizedPath);
      const grantedPlayback = isReadMethod &&
        rawPathSafe &&
        !isAdminOrInternalPath(normalizedPath) &&
        isSafeProxyTail(normalizedPath.slice(1)) &&
        Boolean(canonicalPath && runtimes.get(hash)?.playedPaths?.has(canonicalPath));
      const mediaProxy = spiderProxy || standardProxy || grantedPlayback;
      if (!mediaProxy && !/^\/(t4(?:\?|$)|api\/|videos\/|stream\.)/.test(resource)) {
        return respond(res, 403, { error: 'route_not_exposed' });
      }
      let instance;
      try { instance = await load(hash); }
      catch (_) { return respond(res, 503, { error: 'source_runtime_unavailable' }); }
      if (res.destroyed) {
        if (instance.kind==='drpy' && !instance.active) {
          if(runtimes.get(hash)===instance)runtimes.delete(hash);
          await stop(instance);
        }
        return;
      }
      const activeAddr = server?.address();
      if (!activeAddr || typeof activeAddr !== 'object' || !activeAddr.port) {
        return respond(res, 503, { error: 'source_runtime_unavailable' });
      }
      instance.active++; instance.used=Date.now();
      if (mediaProxy||/[?&]play=/.test(resource)) instance.played=Date.now();
      res.once('close',()=>{
        instance.active--;
        if(instance.kind==='drpy' && resource==='/api/drpy' && !res.writableFinished && !instance.active) {
          if(runtimes.get(hash)===instance)runtimes.delete(hash);
          stop(instance);
        }
      });
      const backend = `http://127.0.0.1:${instance.port}`;
      const publicBase = `http://127.0.0.1:${activeAddr.port}/${secret}/${hash}`;
      const escapedBackend = backend.replace(/\//g, '\\/');
      const escapedPublic = publicBase.replace(/\//g, '\\/');
      const rewrite = text => text
        .split(backend).join(publicBase)
        .split(`http://localhost:${instance.port}`).join(publicBase)
        .split(escapedBackend).join(escapedPublic)
        .split(`http:\\/\\/localhost:${instance.port}`).join(escapedPublic);
      if (req.method === 'GET' && /^\/t4(?:\?|$)/.test(resource)) {
        try {
          const t4Resp = await requestBackend(backend, 'GET', resource);
          if (t4Resp.status === 404) {
            let cfgResp = await requestBackend(backend, 'GET', '/config');
            if (cfgResp.status !== 200) cfgResp = await requestBackend(backend, 'GET', '/full-config');
            if (cfgResp.status === 200) {
              const cfg = JSON.parse(cfgResp.text);
              const rawSites = Array.isArray(cfg?.video?.sites)
                ? cfg.video.sites
                : (Array.isArray(cfg?.sites) ? cfg.sites : null);
              if (rawSites) {
                const skipKeys = new Set(['nodejs_baseset', 'nodejs_gengxin', 'nodejs_mypan']);
                const sites = rawSites
                  .filter(s => s && typeof s === 'object' && typeof s.api === 'string' && s.api.startsWith('/spider/') && !skipKeys.has(s.key))
                  .map(s => {
                    const isDouban = s.key === 'nodejs_douban' || /\/douban\//i.test(s.api);
                    return {
                      ...s,
                      type: 4,
                      searchable: isDouban ? 0 : (s.searchable ?? 1),
                      quickSearch: isDouban ? 0 : (s.quickSearch ?? 1),
                      api: `${publicBase}/api${s.api}`,
                    };
                  });
                if (sites.length > 0 && !res.destroyed) {
                  return respond(res, 200, { sites });
                }
              }
            }
          }
          if (!res.destroyed) {
            res.writeHead(t4Resp.status, {
              'Content-Type': t4Resp.headers['content-type'] || 'application/json; charset=utf-8',
              'Cache-Control': 'no-store',
            });
            res.end(rewrite(t4Resp.text));
          }
        } catch (err) {
          if (err?.deadBackend && runtimes.get(hash) === instance) {
            runtimes.delete(hash); stop(instance);
          }
          if (!res.headersSent) respond(res, 502, { error: 'source_request_failed' });
          else res.destroy();
        }
        return;
      }
      if (req.method === 'GET' && /^\/api\/spider\/[A-Za-z0-9_-]+\/[0-9]+(?:\?|$)/.test(resource)) {
        const parsedUrl = new URL('http://127.0.0.1' + resource);
        const spiderPath = parsedUrl.pathname.slice(4);
        const params = parsedUrl.searchParams;
        try {
          const srcFile = path.join(root, 'wexfnwconfig.json');
          const mtime = fs.existsSync(srcFile) ? fs.statSync(srcFile).mtimeMs : 0;
          if (mtime > 0 && instance.syncedPanMtime !== mtime) {
            instance.syncedPanMtime = mtime;
            const pan = syncPanConfigToState(path.join(root, hash, 'state'));
            if (pan) {
              for (const p of ['quark', 'uc', 'baidu']) {
                const ck = String(pan[p]?.cookie || '');
                await requestBackend(backend, 'PUT', `/website/api/credential/${p}/cookie`, { value: ck }).catch(() => {});
              }
            }
          }
        } catch (_) {}
        if (!instance.initedSpiders) instance.initedSpiders = new Set();
        if (!instance.initedSpiders.has(spiderPath)) {
          instance.initedSpiders.add(spiderPath);
          try { await requestBackend(backend, 'POST', spiderPath + '/init', {}); } catch (_) {}
        }
        try {
          let resp;
          if (params.has('play')) {
            resp = await requestBackend(backend, 'POST', spiderPath + '/play', {
              flag: params.get('flag') || '',
              id: params.get('play') || '',
              flags: [],
            });
          } else if (params.has('ids')) {
            resp = await requestBackend(backend, 'POST', spiderPath + '/detail', {
              id: params.get('ids') || '',
            });
          } else if (params.has('wd')) {
            const pg = parseInt(params.get('pg') || '1', 10) || 1;
            const wd = params.get('wd') || '';
            resp = await requestBackend(backend, 'POST', spiderPath + '/search', {
              wd, key: wd, quick: false, page: pg, pg,
            });
          } else if (params.has('t') || params.has('pg')) {
            const tid = params.get('t') || '';
            const pg = parseInt(params.get('pg') || '1', 10) || 1;
            const extend = {};
            const rawExt = params.get('ext') || '';
            if (rawExt && rawExt.length <= 8192) {
              let parsedExt = null;
              try {
                parsedExt = JSON.parse(rawExt);
              } catch (_) {
                try {
                  const b64 = rawExt.replace(/-/g, '+').replace(/_/g, '/');
                  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
                  parsedExt = JSON.parse(Buffer.from(padded, 'base64').toString('utf8'));
                } catch (_) {}
              }
              if (parsedExt && typeof parsedExt === 'object' && !Array.isArray(parsedExt)) {
                for (const [ek, ev] of Object.entries(parsedExt)) {
                  if (!ek || ek.length > 64 || ek === '__proto__' || ek === 'constructor' || ek === 'prototype') continue;
                  if (typeof ev === 'string' || typeof ev === 'number' || typeof ev === 'boolean') {
                    const sv = String(ev);
                    if (sv) extend[ek] = sv;
                  }
                }
              }
            }
            for (const k of ['class', 'area', 'year', 'by', 'lang', 'cateId', 'type', 'tid']) {
              if (params.get(k)) extend[k] = params.get(k);
            }
            resp = await requestBackend(backend, 'POST', spiderPath + '/category', {
              id: tid, tid, page: pg, pg, filter: true, extend,
            });
          } else {
            resp = await requestBackend(backend, 'POST', spiderPath + '/home', { filter: true });
            try {
              const homeObj = JSON.parse(resp.text);
              if (homeObj && typeof homeObj === 'object' && (!Array.isArray(homeObj.list) || homeObj.list.length === 0)) {
                const vodResp = await requestBackend(backend, 'POST', spiderPath + '/homeVod', {});
                if (vodResp.status === 200) {
                  const vodObj = JSON.parse(vodResp.text);
                  if (Array.isArray(vodObj?.list) && vodObj.list.length > 0) {
                    homeObj.list = vodObj.list;
                    resp.text = JSON.stringify(homeObj);
                  }
                }
              }
            } catch (_) {}
          }
          if (!res.destroyed) {
            const rewritten = rewrite(resp.text);
            if (params.has('play')) recordPlayedUrls(instance, rewritten, publicBase);
            res.writeHead(resp.status, {
              'Content-Type': 'application/json; charset=utf-8',
              'Cache-Control': 'no-store',
            });
            res.end(rewritten);
          }
        } catch (err) {
          if (err?.deadBackend && runtimes.get(hash) === instance) {
            runtimes.delete(hash); stop(instance);
          }
          if (!res.headersSent) respond(res, 502, { error: 'source_request_failed' });
          else res.destroy();
        }
        return;
      }
      const headers = { ...req.headers, host: `127.0.0.1:${instance.port}` };
      delete headers.origin;
      delete headers['accept-encoding'];
      if (!mediaProxy) {
        delete headers.authorization;
        delete headers.cookie;
      }
      const upstream = http.request(backend + resource, { method: req.method, headers }, source => {
        const type = String(source.headers['content-type'] || '');
        const isPartial = source.statusCode === 206 || Boolean(req.headers.range);
        const transformed = /json|mpegurl/i.test(type) || (/text\//i.test(type) && !isPartial);
        const outputHeaders = { ...source.headers };
        delete outputHeaders['set-cookie']; delete outputHeaders['access-control-allow-origin'];
        if (outputHeaders.location) {
          // Relative redirects must remain under this subscription's capability path.
          try {
            const location = new URL(outputHeaders.location, backend + resource).href;
            outputHeaders.location = rewrite(location);
            if (mediaProxy) grantPlayedPath(instance, outputHeaders.location, publicBase);
          } catch (_) {
            delete outputHeaders.location;
          }
        }
        if (transformed) {
          delete outputHeaders['content-length']; delete outputHeaders['content-encoding'];
          let size = 0; const chunks = [];
          source.on('data', chunk => {
            size += chunk.length;
            if (size > 16 * 1024 * 1024) { source.destroy(); res.destroy(); }
            else chunks.push(chunk);
          });
          source.on('end', () => {
            if (res.destroyed) return;
            let body = rewrite(Buffer.concat(chunks).toString('utf8'));
            if (/[?&]play=/.test(resource) && /json/i.test(type)) {
              recordPlayedUrls(instance, body, publicBase);
            }
            if (/mpegurl/i.test(type)) {
              const absolute = value => {
                if (!value || /^(data:|https?:)/i.test(value)) return rewrite(value);
                try { return rewrite(new URL(value, backend + resource).href); }
                catch (_) { return rewrite(value); }
              };
              body = body.split('\n').map(line => line.startsWith('#')
                ? line.replace(/URI="([^"]+)"/g, (_, value) => `URI="${absolute(value)}"`)
                : absolute(line.trim())).join('\n');
              if (mediaProxy) recordPlayedUrls(instance, body, publicBase);
            }
            if (!res.headersSent) res.writeHead(source.statusCode, outputHeaders);
            res.end(body);
          });
          source.on('error', () => res.destroy());
        } else {
          if (!res.headersSent) res.writeHead(source.statusCode, outputHeaders);
          source.pipe(res);
          source.on('error', () => res.destroy());
        }
      });
      if (!mediaProxy) upstream.setTimeout(30000, () => upstream.destroy());
      upstream.on('error', err => {
        if (err && ['ECONNREFUSED', 'ECONNRESET', 'ECONNABORTED'].includes(err.code) && runtimes.get(hash) === instance) {
          runtimes.delete(hash); stop(instance);
        }
        if (!res.headersSent) respond(res, 502, { error: 'source_request_failed' });
        else res.destroy();
      });
      res.on('close', () => upstream.destroy());
      req.pipe(upstream);
    } catch (_) {
      if (!res.headersSent) respond(res, 500, { error: 'internal_error' });
      else try { res.destroy(); } catch (_) {}
    }
  }

  function writeReady(port, seq) {
    const temporary = `${readyFile}.tmp.${process.pid}.${++writeCounter}`;
    const payload = seq > 0
      ? { version: 1, port, secret, seq }
      : { version: 1, port, secret };
    fs.writeFileSync(temporary, JSON.stringify(payload), { mode: 0o600 });
    fs.renameSync(temporary, readyFile);
  }

  function createHostServer() {
    const srv = http.createServer(handleRequest);
    srv.requestTimeout = 0;
    srv.headersTimeout = 10000;
    srv.on('error', () => {
      if (!closing && srv === server) triggerRebind(0);
    });
    return srv;
  }

  async function performRebind(seq) {
    if (closing) return;
    const nextServer = createHostServer();
    try {
      await new Promise((resolve, reject) => {
        const onErr = err => { nextServer.off('listening', onListen); reject(err); };
        const onListen = () => { nextServer.off('error', onErr); resolve(); };
        nextServer.once('error', onErr);
        nextServer.once('listening', onListen);
        nextServer.listen(0, '127.0.0.1');
      });
    } catch (_) {
      try { nextServer.close(); } catch (_) {}
      return;
    }
    if (closing) {
      try { nextServer.close(); } catch (_) {}
      return;
    }
    const prevServer = server;
    server = nextServer;
    try { prevServer?.close(); prevServer?.closeAllConnections?.(); } catch (_) {}
    const pendingBootstrap = bootstrap;
    pendingBootstrap?.cancel?.();
    for (const hash of new Set([...runtimes.keys(), ...loading.keys()])) {
      releases.set(hash, (releases.get(hash) || 0) + 1);
    }
    const instances = [...runtimes.values()];
    runtimes.clear();
    await Promise.race([
      Promise.allSettled(instances.map(stop)),
      new Promise(resolve => setTimeout(resolve, 1500)),
    ]);
    if (seq > lastRebindSeq) lastRebindSeq = seq;
    const addr = nextServer.address();
    if (addr && typeof addr === 'object' && addr.port && !closing) {
      try { writeReady(addr.port, lastRebindSeq); } catch (_) {}
    }
  }

  function triggerRebind(seq = 0) {
    rebindQueue = rebindQueue.then(() => performRebind(seq), () => performRebind(seq));
    return rebindQueue;
  }

  function checkRebindFile() {
    if (closing) return;
    let raw;
    try {
      if (!fs.existsSync(rebindFile)) return;
      raw = fs.readFileSync(rebindFile, 'utf8');
    } catch (_) {
      return;
    }
    try { fs.unlinkSync(rebindFile); } catch (_) {}
    let seq = 0;
    try {
      const parsed = JSON.parse(raw);
      if (Number.isSafeInteger(parsed?.seq) && parsed.seq > 0) seq = parsed.seq;
    } catch (_) {}
    triggerRebind(seq || (lastRebindSeq + 1));
  }

  function probeCurrentServer() {
    return new Promise(resolve => {
      const addr = server?.address();
      if (!addr || typeof addr !== 'object' || !addr.port) return resolve(false);
      let settled = false;
      const finish = ok => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try { sock.destroy(); } catch (_) {}
        resolve(ok);
      };
      const sock = net.connect({ host: '127.0.0.1', port: addr.port });
      const timer = setTimeout(() => finish(false), 400);
      sock.once('connect', () => finish(true));
      sock.once('error', () => finish(false));
    });
  }

  server = createHostServer();
  server.listen(0, '127.0.0.1', () => {
    const addr = server?.address();
    if (addr && typeof addr === 'object' && addr.port) {
      writeReady(addr.port, 0);
    }
  });

  let lastTick = Date.now();
  let probing = false;
  const monitor = setInterval(() => {
    if (closing) return;
    checkRebindFile();
    const now = Date.now();
    const elapsed = now - lastTick;
    lastTick = now;
    if (embedded && elapsed > 3000 && !probing) {
      probing = true;
      probeCurrentServer().then(ok => {
        probing = false;
        if (!ok && !closing) triggerRebind(0);
      }, () => { probing = false; });
    }
  }, 400);
  if (!embedded) monitor.unref();

  let watcher = null;
  try {
    watcher = fs.watch(root, (_, filename) => {
      if (!filename || filename === 'rebind.json') checkRebindFile();
    });
    watcher.on('error', () => {});
    watcher.unref();
  } catch (_) {}

  const close = async () => {
    if (closing) return;
    closing = true;
    clearInterval(monitor);
    try { watcher?.close(); } catch (_) {}
    bootstrap?.cancel?.();
    await dropIdleBootstrapWorker();
    try { server?.close(); server?.closeAllConnections?.(); } catch (_) {}
    await Promise.allSettled([...runtimes.values()].map(stop));
    try { fs.unlinkSync(readyFile); } catch (_) { }
    try { fs.unlinkSync(rebindFile); } catch (_) { }
    process.exit(0);
  };
  if (!embedded) {
    process.on('SIGTERM', close);
    process.on('SIGINT', close);
    process.stdin.resume();
    process.stdin.on('end', close);
  }
}
