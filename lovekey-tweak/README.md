# LovekeyTweak

Lovekey「超会说」修复 —— **进程内注入版**，面向 **TrollFools** 注入。

同类方案参考：[Wtrwx/DYYY](https://github.com/Wtrwx/DYYY)（抖音 UI Tweak）。

## 为什么不用 Shadowrocket 模块

实测结论：同一模块内 `[URL Rewrite]` 生效（reject 命中 35 次），但 `[Script]` 段**始终零执行**；
导出的 `default.conf` 里根本没有 `[Script]` 段。改为把逻辑写进 App 进程。

## TrollFools 兼容性（重要）

TrollFools 只做 **Mach-O 改写**（`insert_dylib` + ChOma），**不提供 hook 运行时**。
因此：

- **不使用 Logos `%hook`**，全部改用纯 Objective-C runtime API（只依赖 `libobjc`）
- **不依赖 `mobilesubstrate`**，链接时加 `-Wl,-dead_strip_dylibs` 剔除无用依赖
- CI 内置 `otool -L` 自检，一旦出现 `substrate` / `libhooker` / `ellekit` 直接判定失败

## 原理

```
constructor 启动
  └─ hook NSURLSessionConfiguration.protocolClasses (method_setImplementation)
        └─ 注入 LKURLProtocol
              ├─ 请求 /v1/chat/*        → 每条换一个全新访客账号（每号仅 3 次额度）
              └─ 响应 /v[12]/account    → 注入会员字段（v2 走 AES-ECB 解密再加密）
                   /v[12]/app/config    → 清空 AINeedLogin
```

超会说走的 `/v1/chat/stream_super_msg` 是**明文 JSON**，核心功能只需替换 `Authorization` 头。

## 注入目标

| Bundle | 说明 |
|---|---|
| `com.fd.lovekeyboard` | 主 App |
| `com.fd.lovekeyboard.SeekLoveKeyboard` | 键盘扩展（**超会说的实际发起方，必须注入这个**） |

抓包证据：超会说请求的 UA 是 `SeekLoveKeyboard/1.8.5`，说明请求由键盘扩展发出。
**只注入主 App 拦不到超会说。**

## 日志（排查用）

三通道并行，任取其一：

**通道 1 — syslog（推荐，Windows 可抓）**

```powershell
pip install pymobiledevice3
python -m pymobiledevice3 syslog live | Select-String "LK "
```

日志行格式：`[LK 2026-09-25 20:00:00 +0800][SeekLoveKeyboard pid=1234] ...`

**通道 2 — 文件**

按顺序尝试写入，取第一个可写：

```
<沙盒>/Documents/lk_tweak.log
<沙盒>/Library/Caches/lk_tweak.log
<沙盒>/lk_tweak.log
/var/mobile/Documents/lk_tweak.log
/var/tmp/lk_tweak.log
<NSTemporaryDirectory>/lk_tweak.log
```

启动时日志会打印实际生效路径（`logFile = ...`）。

**通道 3 — 文件 App**

若设备有 Filza 或已开启 App 文件共享，直接去上述路径取 `lk_tweak.log`。

### 关键日志行

| 日志 | 含义 |
|---|---|
| `=== LovekeyTweak 启动 ===` | dylib 已加载（最基础的成功信号） |
| `[hook] protocolClasses 挂钩成功` | hook 生效 |
| `[self-test] ephemeral.protocolClasses = (...)` | 自检，列表里应含 `LKURLProtocol` |
| `[拦截] 命中 host=...` | 有流量被接管 |
| `[chat] 进入换账号流程` | 超会说请求被识别 |
| `[注册] token = ...(len=32)` | 换账号成功 |
| `[chat] Authorization 已替换` | 鉴权头已替换（核心动作） |
| `[响应] status=... 改写=已改写` | 响应注入成功 |

## 编译

不需要 Mac，用 GitHub Actions：

```
仓库 Actions → Build LovekeyTweak → Run workflow
```

产物自动提交到 `dist/lovekey-tweak/`：

```
LovekeyTweak.dylib                                  ← TrollFools 用这个
com.awjd007.lovekeytweak_*_iphoneos-arm64.deb       ← rootless 越狱
com.awjd007.lovekeytweak_*_iphoneos-arm.deb         ← rootful 越狱
```

## 安装（TrollFools）

1. 打开 TrollFools，选 **Lovekey**。
2. 在列表里展开，找到 **SeekLoveKeyboard**（键盘扩展）。
3. 注入 `LovekeyTweak.dylib`。
4. 同样给主 App 也注入一份。
5. 强退 Lovekey 与键盘进程，重新打开。

## 无越狱方案

TrollFools 需要 TrollStore。若设备还没有：

- iOS 16.6.1 走 kfd 路线（Misaka / PureKFD / Picasso）

## 注意

- 仅供学习交流。
- 若日志里看不到 `[拦截] 命中 host=`，说明 Lovekey 未走 NSURLSession，
  需改 hook 其网络层，届时需要脱壳 IPA 反查类名。
