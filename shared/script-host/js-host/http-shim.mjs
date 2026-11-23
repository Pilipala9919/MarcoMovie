// Local host HTTP shim for `assets://js/lib/http.js` & `net.js`.
export async function req(url, options = {}) {
  if (typeof globalThis.req !== 'function') {
    throw new Error('Host req transport is not initialized');
  }
  return globalThis.req(url, options || {});
}

export async function get(url, headers = {}, options = {}) {
  return req(url, {...options, method: 'GET', headers: {...(options.headers || {}), ...headers}});
}

export async function post(url, data, headers = {}, options = {}) {
  const mergedHeaders = {...(options.headers || {}), ...headers};
  const payload = typeof data === 'string' ? {body: data} : {data: data || {}};
  return req(url, {...options, method: 'POST', headers: mergedHeaders, ...payload});
}

export async function json(url, options = {}) {
  const res = await req(url, options);
  if (!res || typeof res.content !== 'string' || !res.content.trim()) return {};
  return JSON.parse(res.content);
}

export const net = {req, get, post, json};
export default net;
