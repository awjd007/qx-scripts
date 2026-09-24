/**
 * Lovekey MITM 连通性测试
 * 作用：仅验证小火箭的 MITM 与模块脚本机制是否工作
 * 不做任何改写，只弹通知 + 打日志
 */
(function () {
  var url = (typeof $request !== "undefined" && $request && $request.url) ? $request.url : "(无 $request)";
  var method = (typeof $request !== "undefined" && $request && $request.method) ? $request.method : "?";
  var info = method + " " + url;

  // 日志
  try { console.log("[LovekeyTest] 脚本已执行: " + info); } catch (_) {}

  // 通知（小火箭支持 $notify）
  try {
    if (typeof $notify !== "undefined") {
      $notify("Lovekey 测试", "脚本已执行 ✅", info.slice(0, 120));
    }
  } catch (_) {}

  // 原样放行，不做修改
  $done({});
})();
