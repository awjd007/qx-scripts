#import <Foundation/Foundation.h>

// 构建版本标识。
// 每次交付新 dylib 必须递增此值 —— 设备日志里会打印 tweakBuild=x.y.z，
// 用于确认手机上实际加载的是哪一份产物（避免对着旧日志排查新问题）。
#define LK_TWEAK_BUILD "v13-classlist"

// 日志双通道：
//   1) 写入多个候选路径的文件（App 沙盒 / 共享目录），带时间戳与进程名
//   2) 走 os_log（%{public}），可用 pymobiledevice3 syslog 或 Console 抓取
// 设计目标：即使 TrollFools 注入后行为异常，也能拿到证据定位根因。

void LKLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// 返回当前实际生效的日志文件路径（无则返回 nil）
NSString *LKLogPath(void);

// 诊断信息：构建版本、注入环境、沙盒路径、可写性探测结果
void LKLogEnvironment(void);
