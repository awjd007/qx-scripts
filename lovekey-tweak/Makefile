TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

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
LovekeyTweak_FILES = Tweak.x LKCrypto.m LKAccount.m LKURLProtocol.m
LovekeyTweak_CFLAGS = -fobjc-arc -w
LovekeyTweak_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 LoveKeyboard SeekLoveKeyboard 2>/dev/null || true"
