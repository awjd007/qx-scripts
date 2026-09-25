TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# 本地可选覆盖
-include Makefile.local

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LovekeyTweak
LovekeyTweak_FILES = Tweak.x LKCrypto.m LKAccount.m LKURLProtocol.m
LovekeyTweak_CFLAGS = -fobjc-arc -w
LovekeyTweak_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

# 按参数选择打包方案（roothide / rootless / 默认）
ifeq ($(SCHEME),roothide)
    export THEOS_PACKAGE_SCHEME = roothide
else ifeq ($(SCHEME),rootless)
    export THEOS_PACKAGE_SCHEME = rootless
endif

# GitHub Actions 下只出包、不安装
ifeq ($(GITHUB_ACTIONS),true)
    export INSTALL = 0
    export FINALPACKAGE = 1
endif

after-install::
	install.exec "killall -9 LoveKeyboard SeekLoveKeyboard 2>/dev/null || true"
