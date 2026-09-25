/**
 * Lovekey 信标 v1 —— 唯一目的：证明「模块脚本是否被执行」
 * 不注册账号、不改写任何流量、不依赖 CryptoJS。执行即弹通知。
 */
(function () {
  var u = "";
  try { if (typeof $request !== "undefined" && $request && $request.url) u = String($request.url); } catch (e) {}
  var hasResp = false;
  try { hasResp = (typeof $response !== "undefined" && !!$response); } catch (e) {}
  try {
    if (typeof $notify !== "undefined") {
      $notify("LK信标已执行", hasResp ? "[响应阶段]" : "[请求阶段]", u.slice(0, 90));
    }
  } catch (e) {}
  try { $done({}); } catch (e) {}
})();
