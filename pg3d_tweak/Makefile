THEOS_PACKAGE_DIR_NAME = packages
export TARGET = iphone:clang:16.5:14.0

ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = pg3d_tweak

pg3d_tweak_FILES  = pg3d_tweak/Tweak.xm
pg3d_tweak_FILES += pg3d_tweak/Menu.mm
pg3d_tweak_FILES += pg3d_tweak/HookManager.mm

pg3d_tweak_CFLAGS  = -fobjc-arc -std=c++17
pg3d_tweak_CCFLAGS = -std=c++17
pg3d_tweak_LDFLAGS = -lsubstrate

pg3d_tweak_FRAMEWORKS = UIKit CoreGraphics Foundation

include $(THEOS)/makefiles/tweak.mk
