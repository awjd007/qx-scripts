/**
 * Lovekey 诊断信标 D —— 仅上报，不改写任何流量
 * 可见信号：该路径首次被本脚本看到时弹一次通知「Lovekey 诊断D」
 * 抓包信号：sea.api.lovekeyboard.com/lkdiag/D/{req|resp}?...   UA = LkDiagD/1.0
 * 说明：纯 ES5、不依赖 CryptoJS，始终 $done({}) 原样放行
 */
(function () {
  var TAG = "D";
  var u = "";
  try { if (typeof $request !== "undefined" && $request && $request.url) u = String($request.url); } catch (e) {}
  if (!u) { try { $done({}); } catch (e) {} return; }
  if (u.indexOf("/lkdiag") >= 0) { try { $done({}); } catch (e) {} return; }

  var isResp = false;
  try { isResp = (typeof $response !== "undefined" && !!$response); } catch (e) {}

  var path = u.replace(/^https?:\/\/[^\/]+/, "").split("#")[0];
  var short = path.split("?")[0];

  // 每个路径首次出现时弹一次通知，避免刷屏
  var first = false;
  var key = "LkDiagSeen_" + TAG;
  var seen = "";
  try {
    if (typeof $persistentStore !== "undefined" && $persistentStore) seen = String($persistentStore.read(key) || "");
    else if (typeof $prefs !== "undefined" && $prefs) seen = String($prefs.valueForKey(key) || "");
  } catch (e) {}
  if (seen.indexOf("|" + short + "|") < 0) {
    first = true;
    try {
      var nx = (seen + "|" + short + "|").slice(-600);
      if (typeof $persistentStore !== "undefined" && $persistentStore) $persistentStore.write(nx, key);
      else if (typeof $prefs !== "undefined" && $prefs) $prefs.setValueForKey(nx, key);
    } catch (e) {}
  }

  // 运行环境探测位：1=存在 0=不存在
  var env = "hc" + (typeof $httpClient !== "undefined" ? 1 : 0)
    + ".tk" + (typeof $task !== "undefined" ? 1 : 0)
    + ".tf" + ((typeof $task !== "undefined" && $task && typeof $task.fetch === "function") ? 1 : 0)
    + ".cj" + (typeof CryptoJS !== "undefined" ? 1 : 0)
    + ".nt" + (typeof $notify !== "undefined" ? 1 : 0)
    + ".ps" + (typeof $persistentStore !== "undefined" ? 1 : 0)
    + ".pf" + (typeof $prefs !== "undefined" ? 1 : 0);

  // 上报信标
  var beacon = "https://sea.api.lovekeyboard.com/lkdiag/" + TAG + "/" + (isResp ? "resp" : "req")
    + "?p=" + encodeURIComponent(short.slice(0, 80))
    + "&e=" + encodeURIComponent(env)
    + "&t=" + Date.now();
  var opt = { url: beacon, method: "GET", headers: { "User-Agent": "LkDiag" + TAG + "/1.0", "Accept": "*/*" }, timeout: 6 };
  try {
    if (typeof $httpClient !== "undefined" && $httpClient && typeof $httpClient.get === "function") {
      $httpClient.get(opt, function () {});
    } else if (typeof $task !== "undefined" && $task && typeof $task.fetch === "function") {
      $task.fetch(opt).then(function () {}, function () {});
    }
  } catch (e) {}

  // 可见信号
  try {
    if (first && typeof $notify !== "undefined") {
      $notify("Lovekey 诊断" + TAG, "脚本已执行 ✅", (isResp ? "[响应] " : "[请求] ") + short.slice(0, 56) + "  " + env);
    }
  } catch (e) {}

  try { $done({}); } catch (e) {}
})();
