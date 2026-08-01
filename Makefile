ROOT := $(CURDIR)
BASH := $(if $(wildcard /var/jb/usr/bin/bash),/var/jb/usr/bin/bash,/bin/bash)

.PHONY: verify preflight bootstrap pe-wrapper app launchers configure-wine build-wine runtime tipa install zip-test device source-archive

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
