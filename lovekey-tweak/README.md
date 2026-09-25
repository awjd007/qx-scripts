# LovekeyTweak

Lovekey「超会说」修复 —— **进程内注入版**（不走 Shadowrocket MITM）。

同类方案参考：[Wtrwx/DYYY](https://github.com/Wtrwx/DYYY)（抖音 UI Tweak）。

## 为什么换这条路

Shadowrocket 模块链路反复失败：同一模块内 `[URL Rewrite]` 生效、`[Script]` 段始终零执行，
且导出的 `default.conf` 里根本没有 `[Script]` 段。改为把逻辑写进 App 进程，绕开该链路。

## 原理

```
hook NSURLSessionConfiguration.protocolClasses
        └─ 注入 LKURLProtocol
                ├─ 请求 /v1/chat/*        → 每条换一个全新访客账号（每号仅 3 次额度）
                └─ 响应 /v[12]/account    → 注入会员字段（v2 走 AES 解密再加密）
                     /v[12]/app/config    → 清空 AINeedLogin
```

超会说走的 `/v1/chat/stream_super_msg` 是**明文 JSON**，所以核心功能只需替换
`Authorization` 头，无需解密响应。

## 关键常量（自 App 逆向）

| 项 | 值 |
|---|---|
| AES key | `d4XvusEYeafO9SBK`（AES-128-ECB / PKCS7） |
| 签名密钥 | `BeJsdgiq1azlQItxc93W`（`MD5(query + ts + secret)`） |
| 注册端点 | `POST https://sea.api.lovekeyboard.com/v2/auth/guest` |

## 注入目标

| Bundle | 说明 |
|---|---|
| `com.fd.lovekeyboard` | 主 App |
| `com.fd.lovekeyboard.SeekLoveKeyboard` | 键盘扩展（超会说的实际发起方） |

## 编译

不需要 Mac —— 用 GitHub Actions：

```
仓库 Actions → Build LovekeyTweak → Run workflow
```

产物在 Artifacts 里，包含三个 deb：

- `LovekeyTweak_*_iphoneos-arm.deb`（默认，越狱）
- `*_rootless.deb`（无根越狱）
- `*_roothide.deb`

本地编译（需 Theos）：

```bash
make package FINALPACKAGE=1
make package SCHEME=roothide FINALPACKAGE=1
```

## 安装

**TrollStore**：直接选 deb 安装（TrollStore 会自动解包并注入对应 Bundle）。
装完**强退** Lovekey 与键盘进程再重开。

**越狱**：`dpkg -i` 或 Sileo 安装，然后 `killall -9 Lovekey`。

## 验证

1. 打开 Lovekey，键盘里点「超会说」。
2. 若仍无建议，看设备日志过滤 `LovekeyTweak`（确认 dylib 已加载）。
3. 用抓包工具确认 `/v1/chat/stream_super_msg` 的 `Authorization` 是否变成新的 `Bearer ...`。

## 注意

- 仅供学习交流。
- 若 App 未使用 NSURLSession（当前 UA 显示 Alamofire，理论上是），需改为 hook 其网络层类，
  届时需要脱壳 IPA 反查类名。
