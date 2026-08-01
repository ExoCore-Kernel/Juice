ARCHS = arm64
TARGET = iphone:clang:latest:16.0
PACKAGE_FORMAT = ipa

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Juice

Juice_FILES = main.m
Juice_FRAMEWORKS = UIKit Foundation
Juice_CFLAGS = -fobjc-arc -O2 -Wall -Wextra
Juice_CODESIGN_FLAGS = -Sentitlements.plist
Juice_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk
