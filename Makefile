ROOT := $(CURDIR)
BASH := $(if $(wildcard /var/jb/usr/bin/bash),/var/jb/usr/bin/bash,/bin/bash)
REUSE_X64 ?= auto

.DEFAULT_GOAL := all

.PHONY: all verify preflight bootstrap pe-wrapper app launchers configure-wine build-wine runtime tipa install zip-test device source-archive installer-smokes arm64-smoke-build x64-components x64-runtime x64-tipa win32-components win32-runtime win32-tipa reuse reuse-install verify-fex linux-x86_64 linux-x86_64-x64 linux-x86_64-deps linux-x86_64-sdk linux-x86_64-freetype linux-x86_64-preflight linux-x86_64-ios-toolchain linux-x86_64-toolchain linux-x86_64-host-tools linux-x86_64-configure linux-x86_64-configure-pe linux-x86_64-build

# Primary build: complete Juice TIPA from an x86_64 Linux host.
all: linux-x86_64-x64

verify: ; $(BASH) scripts/verify-source.sh
preflight: ; $(BASH) scripts/preflight-device.sh
bootstrap: ; $(BASH) scripts/bootstrap-trust-carrier-device.sh
pe-wrapper: ; $(BASH) scripts/build-pe-compiler-wrapper-device.sh
app: ; $(BASH) scripts/build-app.sh
launchers: ; $(BASH) scripts/build-launchers.sh
configure-wine: ; $(BASH) scripts/configure-wine-device.sh
build-wine: ; $(BASH) scripts/build-wine-device.sh
runtime: ; $(BASH) scripts/assemble-runtime.sh
tipa: ; $(BASH) scripts/package-tipa.sh
install: ; $(BASH) scripts/install-tipa-device.sh
zip-test: ; $(BASH) scripts/test-zip-extractor-device.sh
device: ; $(BASH) scripts/build-all-device.sh
source-archive: ; $(BASH) scripts/source-archive.sh
installer-smokes: ; $(BASH) scripts/build-installer-smokes-device.sh
arm64-smoke-build: ; $(BASH) scripts/build-arm64-smoke-linux.sh
x64-components: ; $(BASH) scripts/build-experimental-x86_64-linux.sh
x64-runtime: ; $(BASH) scripts/assemble-x86_64-runtime.sh
x64-tipa: ; JUICE_X64_RUNTIME_STAGE="$(ROOT)/build/x86_64-runtime-stage" $(BASH) scripts/package-tipa.sh
win32-components: ; $(BASH) scripts/build-experimental-win32-linux.sh
win32-runtime: ; JUICE_REQUIRE_WIN32=1 $(BASH) scripts/assemble-x86_64-runtime.sh
win32-tipa: ; JUICE_X64_RUNTIME_STAGE="$(ROOT)/build/x86_64-runtime-stage" $(BASH) scripts/package-tipa.sh
reuse:
	@test -n "$(BINARIES)" || { echo "Usage: make reuse BINARIES=/path/to/prebuilt [REUSE_X64=auto|0|1]" >&2; exit 2; }
	@BINARIES="$(BINARIES)" JUICE_REUSE_X64="$(REUSE_X64)" $(BASH) scripts/package-reuse-tipa.sh
reuse-install:
	@test -n "$(BINARIES)" || { echo "Usage: make reuse-install BINARIES=/path/to/prebuilt [REUSE_X64=auto|0|1]" >&2; exit 2; }
	@out="$(ROOT)/dist/Juice-Reuse-$$(date +%Y%m%d-%H%M%S).tipa"; \
	 BINARIES="$(BINARIES)" JUICE_REUSE_X64="$(REUSE_X64)" $(BASH) scripts/package-reuse-tipa.sh "$$out" && \
	 $(BASH) scripts/install-tipa-device.sh "$$out"
verify-fex: ; $(BASH) scripts/fetch-fex-linux.sh && $(BASH) scripts/verify-fex-patch.sh

# x86_64 Linux cross-build. External SDK/FreeType inputs are fetched into build/deps.
linux-x86_64-sdk: ; $(BASH) scripts/fetch-ios-sdk-linux.sh
linux-x86_64-freetype:
	@if test "$${JUICE_WITHOUT_FREETYPE:-0}" != 1; then $(BASH) scripts/fetch-freetype-linux.sh; fi
linux-x86_64-deps: linux-x86_64-sdk linux-x86_64-freetype
linux-x86_64-ios-toolchain: linux-x86_64-sdk
	@v="$${JUICE_IOS_SDK_VERSION:-16.5}"; \
	 IOS_SDK="$${IOS_SDK:-$(ROOT)/build/deps/theos-sdks/iPhoneOS$$v.sdk}" \
	 $(BASH) scripts/bootstrap-ios-toolchain-linux.sh
linux-x86_64-toolchain: ; $(BASH) scripts/bootstrap-x86_64-toolchain-linux.sh
linux-x86_64-host-tools: ; $(BASH) scripts/build-wine-tools-linux.sh
linux-x86_64-preflight: linux-x86_64-deps
	@v="$${JUICE_IOS_SDK_VERSION:-16.5}"; \
	 sdk="$${IOS_SDK:-$(ROOT)/build/deps/theos-sdks/iPhoneOS$$v.sdk}"; \
	 toolchain="$${JUICE_IOS_TOOLCHAIN:-$(ROOT)/build/ios-toolchain}"; \
	 prefix="$${JUICE_IOS_TRIPLE_PREFIX:-arm-apple-darwin11}"; \
	 if test ! -x "$$toolchain/bin/$$prefix-clang"; then \
	   IOS_SDK="$$sdk" JUICE_IOS_TOOLCHAIN="$$toolchain" $(BASH) scripts/bootstrap-ios-toolchain-linux.sh; \
	 else \
	   echo "JUICE_IOS_TOOLCHAIN_REUSE path=$$toolchain"; \
	 fi; \
	 IOS_SDK="$$sdk" JUICE_IOS_TOOLCHAIN="$$toolchain" \
	 JUICE_IOS_ROOTLESS_SYSROOT="$${JUICE_IOS_ROOTLESS_SYSROOT:-$(ROOT)/build/deps/rootless-sysroot}" \
	 $(BASH) scripts/preflight-linux-x86_64.sh
linux-x86_64-configure: linux-x86_64-preflight linux-x86_64-host-tools
	@v="$${JUICE_IOS_SDK_VERSION:-16.5}"; \
	 IOS_SDK="$${IOS_SDK:-$(ROOT)/build/deps/theos-sdks/iPhoneOS$$v.sdk}" \
	 JUICE_IOS_ROOTLESS_SYSROOT="$${JUICE_IOS_ROOTLESS_SYSROOT:-$(ROOT)/build/deps/rootless-sysroot}" \
	 $(BASH) scripts/configure-wine-linux.sh
linux-x86_64-configure-pe: linux-x86_64-preflight linux-x86_64-host-tools linux-x86_64-toolchain
	@v="$${JUICE_IOS_SDK_VERSION:-16.5}"; \
	 IOS_SDK="$${IOS_SDK:-$(ROOT)/build/deps/theos-sdks/iPhoneOS$$v.sdk}" \
	 $(BASH) scripts/configure-wine-pe-linux.sh
linux-x86_64-build: ; $(BASH) scripts/build-wine-linux.sh
linux-x86_64: linux-x86_64-preflight
	@v="$${JUICE_IOS_SDK_VERSION:-16.5}"; \
	 IOS_SDK="$${IOS_SDK:-$(ROOT)/build/deps/theos-sdks/iPhoneOS$$v.sdk}" \
	 JUICE_IOS_ROOTLESS_SYSROOT="$${JUICE_IOS_ROOTLESS_SYSROOT:-$(ROOT)/build/deps/rootless-sysroot}" \
	 $(BASH) scripts/build-all-linux-x86_64.sh
linux-x86_64-x64: linux-x86_64-preflight
	@v="$${JUICE_IOS_SDK_VERSION:-16.5}"; \
	 IOS_SDK="$${IOS_SDK:-$(ROOT)/build/deps/theos-sdks/iPhoneOS$$v.sdk}" \
	 JUICE_IOS_ROOTLESS_SYSROOT="$${JUICE_IOS_ROOTLESS_SYSROOT:-$(ROOT)/build/deps/rootless-sysroot}" \
	 JUICE_BUILD_X64=1 JUICE_REQUIRE_WIN32="$${JUICE_REQUIRE_WIN32:-1}" $(BASH) scripts/build-all-linux-x86_64.sh
