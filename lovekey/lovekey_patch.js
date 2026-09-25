/**
 * Lovekey 1.8.5 · Quantumult X 修复版
 * 2026-07-23（原作者 xiadasy）
 * PATCH by awjd007：账号配额轮换 + v1明文账号 + 关闭绑定弹窗
 */
const APP_VERSION = "v1.8.5";
const APP_NUM = "1.8.5";
const SOURCE = "App store";
const SIGN_SECRET = "BeJsdgiq1azlQItxc93W";
const AES_KEY = "d4XvusEYeafO9SBK";
const GUEST_URL = "https://sea.api.lovekeyboard.com/v2/auth/guest";
const CRYPTO_URL = "https://cdnjs.cloudflare.com/ajax/libs/crypto-js/4.2.0/crypto-js.min.js";
const CRYPTO_KEY = "Lovekey_CryptoJS_420";
const TOKEN_KEY = "Lovekey_GuestToken_V185";
const TOKEN_TIME_KEY = "Lovekey_GuestTokenTime_V185";
const TOKEN_TTL = 6 * 60 * 60 * 1000;
const CHAT_RE = /\/v1\/chat\/(?:keyboard-(?:ow|stream)-msg|stream_super_msg)/i;
const ACCOUNT_RE = /\/v[12]\/account(?:\?|$)/i;
const CONFIG_RE = /\/v[12]\/app\/config/i;
const USED_KEY = "Lovekey_UsedCount";
const ROTATE_LIMIT = 3;

function read(key) {
  try {
    if (typeof $prefs !== "undefined") return $prefs.valueForKey(key) || "";
    if (typeof $persistentStore !== "undefined") return $persistentStore.read(key) || "";
  } catch (_) {}
  return "";
}
function write(key, value) {
  try {
    if (typeof $prefs !== "undefined") return $prefs.setValueForKey(String(value), key);
    if (typeof $persistentStore !== "undefined") return $persistentStore.write(String(value), key);
  } catch (_) {}
  return false;
}
function request(options) {
  return new Promise((resolve, reject) => {
    const method = String(options.method || "GET").toUpperCase();
    if (typeof $task !== "undefined") {
      $task.fetch(options).then(r => resolve({ body: r.body, response: r }), e => reject(e && e.error || e));
    } else if (typeof $httpClient !== "undefined") {
      const fn = method === "POST" ? $httpClient.post : $httpClient.get;
      fn(options, (e, r, body) => e ? reject(e) : resolve({ body, response: r }));
    } else reject(new Error("Unsupported environment"));
  });
}
function json(text) {
  try { return JSON.parse(text); } catch (_) { return null; }
}
function installCrypto(code) {
  try { (0, eval)(code); } catch (_) { try { eval(code); } catch (_) {} }
  return typeof CryptoJS !== "undefined" ? CryptoJS :
    (typeof globalThis !== "undefined" ? globalThis.CryptoJS : null);
}
async function loadCrypto() {
  if (typeof CryptoJS !== "undefined") return CryptoJS;
  let code = read(CRYPTO_KEY);
  let C = code ? installCrypto(code) : null;
  if (C) return C;
  const r = await request({ url: CRYPTO_URL, method: "GET", headers: { "accept-encoding": "identity" }, timeout: 15 });
  code = r.body || "";
  C = installCrypto(code);
  if (C) write(CRYPTO_KEY, code);
  return C;
}
function uuid() {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    return (c === "x" ? r : r & 3 | 8).toString(16).toUpperCase();
  });
}
function copyHeaders(source) {
  const out = {};
  Object.keys(source || {}).forEach(k => out[k] = source[k]);
  return out;
}
function delHeader(headers, name) {
  Object.keys(headers).forEach(k => {
    if (k.toLowerCase() === name.toLowerCase()) delete headers[k];
  });
}
function setHeader(headers, name, value) {
  const old = Object.keys(headers).find(k => k.toLowerCase() === name.toLowerCase());
  headers[old || name] = value;
}
function decrypt(C, text) {
  const key = C.enc.Utf8.parse(AES_KEY);
  const bytes = C.AES.decrypt({ ciphertext: C.enc.Base64.parse(text) }, key, {
    mode: C.mode.ECB,
    padding: C.pad.Pkcs7
  });
  return bytes.toString(C.enc.Utf8);
}
function encrypt(C, text) {
  const key = C.enc.Utf8.parse(AES_KEY);
  const result = C.AES.encrypt(C.enc.Utf8.parse(text), key, {
    mode: C.mode.ECB,
    padding: C.pad.Pkcs7
  });
  return result.ciphertext.toString(C.enc.Base64);
}
function patchVip(a) {
  if (!a || typeof a !== "object") return a;
  if (!a.nickname || String(a.nickname).indexOf("游客") === 0) a.nickname = "baby";
  a.guest = false;
  if (!a.member_id || a.member_id <= 0) a.member_id = 99999999;
  a.perpetual_vip = 1;
  a.vip_expired_at = "3742732800";
  a.member_vip = 2;
  a.vip_level = "永久会员";
  a.is_must_vip_keyboard = false;
  a.is_formal = true;
  a.restrict_times = 999999;
  a.free_search_time = 999999;
  a.img_analysis_remain_times = 999;
  a.hy_expired_day = "9999";
  // PATCH: 绑定手机号弹窗相关字段
  if (!a.phone) a.phone = "13800000000";
  a.has_password = true;
  a.third_party_bound = true;
  return a;
}
async function createGuestToken() {
  const C = await loadCrypto();
  if (!C) return null;
  const ms = Date.now();
  const ts = Math.floor(ms / 1000);
  const models = ["iPhone 16 Pro Max", "iPhone 16 Pro", "iPhone 16", "iPhone 15 Pro Max", "iPhone 15 Pro", "iPhone 15"];
  const model = models[Math.random() * models.length | 0];
  const id = uuid();
  const prefix = id.replace(/-/g, "").slice(0, 16).padEnd(16, "0");
  const installId = C.MD5(prefix + String(ms)).toString();
  const pairs = [
    ["device[identifier]", id], ["device[name]", model], ["device[platform]", "0"],
    ["install_id", installId], ["source", SOURCE], ["version", APP_VERSION]
  ];
  const query = pairs.map(x => x[0].replace(/\[/g, "%5B").replace(/\]/g, "%5D") + "=" + encodeURIComponent(String(x[1]))).join("&");
  const sign = C.MD5(query + String(ts) + SIGN_SECRET).toString();
  const headers = {
    "User-Agent": `LoveKeyboard/${APP_NUM} (com.fd.lovekeyboard; build:55; iOS 18.5.0) Alamofire/5.10.2`,
    "device-name": "iPhone", "device-band": model, "device-version": "18.5",
    "device-type": "1", channel: "1", "app-version": APP_VERSION,
    "app-locale": "zh-Hans", "app-lan": "zh", timestamp: String(ts), sign,
    authorization: "", accept: "*/*", "content-type": "application/json;charset=utf-8",
    "accept-encoding": "identity", "X-Surge-Skip-Scripting": true
  };
  const body = JSON.stringify({
    version: APP_VERSION,
    install_id: installId,
    device: { name: model, platform: "0", identifier: id },
    source: SOURCE
  });
  const r = await request({ url: GUEST_URL, method: "POST", headers, body, timeout: 15 });
  const wrapped = json(r.body || "");
  if (!wrapped || typeof wrapped.data !== "string") return null;
  const value = json(decrypt(C, wrapped.data));
  return value && value.access_token || null;
}
async function guestToken() {
  const cached = read(TOKEN_KEY);
  const time = parseInt(read(TOKEN_TIME_KEY) || "0", 10) || 0;
  const used = parseInt(read(USED_KEY) || "0", 10) || 0;
  // PATCH: 每个访客账号仅 3 次 AI 额度，用尽即轮换新账号
  if (cached && Date.now() - time < TOKEN_TTL && used < ROTATE_LIMIT) return cached;
  const token = await createGuestToken();
  if (token) {
    write(TOKEN_KEY, token);
    write(TOKEN_TIME_KEY, Date.now());
    write(USED_KEY, "0");
  }
  return token || cached;
}
async function chatRequest() {
  const headers = copyHeaders($request.headers || {});
  const token = await guestToken();
  delHeader(headers, "authorization");
  if (token) setHeader(headers, "Authorization", "Bearer " + token);
  // PATCH: 累计调用次数，达到上限后下次自动换账号
  const used = parseInt(read(USED_KEY) || "0", 10) || 0;
  write(USED_KEY, String(used + 1));
  $done({ headers });
}
async function accountResponse() {
  const C = await loadCrypto();
  const wrapped = json($response.body || "");
  if (!wrapped) return $done({});
  const reqUrl = (typeof $request !== "undefined" && $request && $request.url) || "";

  // PATCH: /v1/account 是明文（键盘扩展调用），/v2/account 是密文
  if (/\/v1\/account/i.test(reqUrl)) {
    if (!wrapped.data || typeof wrapped.data !== "object" || Array.isArray(wrapped.data)) return $done({});
    patchVip(wrapped.data);
    const h1 = copyHeaders($response.headers || {});
    delHeader(h1, "Content-Length");
    return $done({ body: JSON.stringify(wrapped), headers: h1 });
  }

  if (!C || typeof wrapped.data !== "string") return $done({});
  const account = json(decrypt(C, wrapped.data));
  if (!account) return $done({});
  patchVip(account);
  wrapped.data = encrypt(C, JSON.stringify(account));
  const headers = copyHeaders($response.headers || {});
  setHeader(headers, "Content-Type", "application/json; charset=utf-8");
  delHeader(headers, "Content-Length");
  $done({ body: JSON.stringify(wrapped), headers });
}

// PATCH: 关闭"AI功能需绑定手机号"弹窗（清空服务器下发的 AINeedLogin）
async function configResponse() {
  const C = await loadCrypto();
  const wrapped = json($response.body || "");
  if (!wrapped) return $done({});
  const fix = function (o) {
    if (!o || typeof o !== "object") return;
    if (Array.isArray(o.AINeedLogin)) o.AINeedLogin = [];
    if (o.conf && typeof o.conf === "object" && Array.isArray(o.conf.AINeedLogin)) o.conf.AINeedLogin = [];
  };
  if (typeof wrapped.data === "string") {
    const plain = json(decrypt(C, wrapped.data));
    if (!plain) return $done({});
    fix(plain);
    wrapped.data = encrypt(C, JSON.stringify(plain));
  } else {
    fix(wrapped);
    fix(wrapped.data);
  }
  const headers = copyHeaders($response.headers || {});
  delHeader(headers, "Content-Length");
  $done({ body: JSON.stringify(wrapped), headers });
}
(async () => {
  try {
    const url = typeof $request !== "undefined" && $request ? $request.url : "";
    const hasResponse = typeof $response !== "undefined" && !!$response;
    if (url && hasResponse && CONFIG_RE.test(url)) return await configResponse();
    if (url && !hasResponse && CHAT_RE.test(url)) return await chatRequest();
    if (url && hasResponse && ACCOUNT_RE.test(url)) return await accountResponse();
    $done({});
  } catch (_) { $done({}); }
})();
