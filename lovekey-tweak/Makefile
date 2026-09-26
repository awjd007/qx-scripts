TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e
DEBUG = 0

# 打包方案必须在 include 之前 export，否则 layout 不生效
ifeq ($(SCHEME),rootless)
    export THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(SCHEME),roothide)
    export THEOS_PACKAGE_SCHEME = roothide
endif

# 本地可选覆盖
-include Makefile.local

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LovekeyTweak
LovekeyTweak_FILES = Tweak.m LKLog.m LKCrypto.m LKAccount.m LKLogin.m LKURLProtocol.m
LovekeyTweak_CFLAGS = -fobjc-arc -w -O2
LovekeyTweak_FRAMEWORKS = Foundation UIKit
# 关键：纯 runtime 实现，不依赖 substrate。
# -dead_strip_dylibs 剔除未使用的 dylib 依赖，保证 TrollFools 环境能加载。
LovekeyTweak_LDFLAGS = -Wl,-dead_strip_dylibs
LovekeyTweak_LIBRARIES =

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 LoveKeyboard SeekLoveKeyboard 2>/dev/null || true"
