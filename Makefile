# wifiscan — terminal WiFi survey & channel planner (Swift / CoreWLAN).
# `make` (or `make help`) lists the targets; `make build` assembles a signed
# wifiscan.app under .build/ and `make install` copies it into ~/Applications with a
# `wifiscan` launcher on PATH.
#
# Why an .app bundle? macOS gates Wi-Fi SSIDs behind Location Services and only
# grants it to an app with its own identity. A bare CLI has none, so its request
# can't be attributed to the terminal reliably. Running the binary *inside* a
# signed .app gives the process the bundle's identity, so "wifiscan" appears in
# Location Services on its own — independent of which terminal you launch it from.

# Optional machine-local overrides (git-ignored) — e.g. SIGN := <your cert>.
-include Makefile.local

BINARY      := wifiscan
# Core.swift = pure, framework-free logic (also compiled standalone by `make test`
# and held at 100% coverage by `make coverage`); main.swift = CoreWLAN/CoreLocation,
# TUI, scan helper, entrypoint.
CORE        := Sources/wifiscan/Core.swift
SRC         := $(CORE) Sources/wifiscan/main.swift
TEST_SRC    := $(CORE) Tests/CoreTests.swift
# Everything we generate lives under .build/ (git-ignored, shared with SwiftPM).
BUILD_DIR   := .build
COV_DIR     := $(BUILD_DIR)/coverage
TEST_BIN    := $(BUILD_DIR)/wifiscan-tests
PLIST       := Info.plist
INSTALL_DIR := $(HOME)/.bin
APP_DIR     := $(HOME)/Applications
APP         := $(APP_DIR)/$(BINARY).app
EXE         := $(APP)/Contents/MacOS/$(BINARY)
# The bundle is assembled here first; `install` swaps it into ~/Applications only once
# the build has succeeded, so a failed compile never removes a working install.
BUILD_APP   := $(BUILD_DIR)/$(BINARY).app
BUILD_EXE   := $(BUILD_APP)/Contents/MacOS/$(BINARY)
BUNDLE_ID   := com.lucasdaddiego.wifiscan
# The version is owned by Info.plist (CFBundleShortVersionString) — `--version` reads it
# from the bundle at runtime, `make release` tags from it.
VERSION     := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(PLIST))
DIST_DIR    := $(BUILD_DIR)/dist
DIST_APP    := $(DIST_DIR)/$(BINARY).app
DIST_ZIP    := $(DIST_DIR)/wifiscan-v$(VERSION)-macos-universal.zip

# Swift compiler — override to pin a toolchain, e.g. `make SWIFTC="xcrun swiftc"`.
SWIFTC      ?= swiftc
# Swift 6 language mode everywhere (matches Package.swift): strict concurrency checking.
SWIFTFLAGS  := -swift-version 6

# Signing identity. Ad-hoc ("-") by default — but ad-hoc has no stable identity, so
# macOS ties the Location grant to the exact build and forgets it on every rebuild.
# For a grant that survives rebuilds, create a self-signed "Code Signing" certificate
# once (Keychain Access → Certificate Assistant → Create a Certificate, type "Code
# Signing"), then build with:  make SIGN="Your Cert Name"
SIGN        ?= -

FRAMEWORKS  := -framework CoreWLAN -framework CoreLocation
# Release: optimise (-O), strip local symbols (-x), drop dead code (-dead_strip).
# No -g, so zero debug info. Stripping is at link time, before signing.
RELEASE     := -O -Xlinker -x -Xlinker -dead_strip

LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.DEFAULT_GOAL := help
.PHONY: help build install test coverage dist release clean uninstall

help: ## List all targets
	@echo "wifiscan — make targets ('make install' builds + installs):"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: $(BUILD_EXE) ## Build the optimised, signed .build/wifiscan.app (no install)

# File rule = real dependency tracking: relink only when the sources, the plist, or the
# build flags (this Makefile) actually change. The bundle is signed as a whole (the seal
# lives in Contents/_CodeSignature), so it must be assembled before codesign runs.
$(BUILD_EXE): $(SRC) $(PLIST) Makefile
	@rm -rf "$(BUILD_APP)"
	@mkdir -p "$(BUILD_APP)/Contents/MacOS"
	cp $(PLIST) "$(BUILD_APP)/Contents/Info.plist"
	$(SWIFTC) $(SWIFTFLAGS) $(RELEASE) $(SRC) -o "$(BUILD_EXE)" $(FRAMEWORKS)
	codesign --force --sign $(SIGN) --identifier $(BUNDLE_ID) "$(BUILD_APP)"
	@echo "built $(BUILD_APP) ($$(du -sh "$(BUILD_APP)" | cut -f1)), signed as '$(SIGN)'"

# The previous install is removed only AFTER the build above succeeded, so a compile
# error on an older toolchain leaves the working app and the ~/.bin launcher intact.
# The copy is re-signed in place: the installed bundle's signature and Location identity
# never depend on what the copy step did.
install: build ## Build, then install wifiscan.app into ~/Applications + a launcher in ~/.bin
	@mkdir -p "$(APP_DIR)" "$(INSTALL_DIR)"
	rm -rf "$(APP)"
	ditto "$(BUILD_APP)" "$(APP)"
	codesign --force --sign $(SIGN) --identifier $(BUNDLE_ID) "$(APP)"
	ln -sf "$(EXE)" "$(INSTALL_DIR)/$(BINARY)"
	-$(LSREGISTER) -f "$(APP)"
	@echo "installed $(APP) ($$(du -sh "$(APP)" | cut -f1))"
	@echo "         launcher: $(INSTALL_DIR)/$(BINARY) -> in-bundle binary"
	@echo
	@echo "one-time permission:"
	@echo "  1. run \`$(BINARY)\` once  (registers it with Location Services)"
	@echo "  2. System Settings → Privacy & Security → Location Services → enable 'wifiscan'"
	@echo "  3. fully quit Terminal (⌘Q) and reopen, then run \`$(BINARY)\`"

test: ## Build & run the dependency-free core unit tests (no Xcode/XCTest needed)
	@mkdir -p "$(BUILD_DIR)"
	@$(SWIFTC) $(SWIFTFLAGS) -parse-as-library $(TEST_SRC) -o "$(TEST_BIN)"
	@"$(TEST_BIN)"

coverage: ## Run the core tests under coverage; fail unless Core.swift is 100% covered
	@mkdir -p "$(COV_DIR)"
	@$(SWIFTC) $(SWIFTFLAGS) -profile-generate -profile-coverage-mapping -parse-as-library $(TEST_SRC) -o "$(COV_DIR)/tests"
	@LLVM_PROFILE_FILE="$(COV_DIR)/tests.profraw" "$(COV_DIR)/tests"
	@xcrun llvm-profdata merge -sparse "$(COV_DIR)/tests.profraw" -o "$(COV_DIR)/tests.profdata"
	@xcrun llvm-cov report "$(COV_DIR)/tests" -instr-profile="$(COV_DIR)/tests.profdata" $(CORE)
	@bash scripts/check-coverage.sh "$(COV_DIR)/tests" "$(COV_DIR)/tests.profdata" $(CORE)

# Universal bundle: the two slices are cross-compiled with -target (the macOS SDK carries
# both), lipo'd together into a fresh .app, signed once, then zipped with LICENSE + README
# and a SHA-256 manifest. Run by the release workflow on every v* tag.
dist: ## Build a universal (arm64 + x86_64) signed wifiscan.app, zip it + write SHA256SUMS
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_APP)/Contents/MacOS"
	$(SWIFTC) $(SWIFTFLAGS) $(RELEASE) -target arm64-apple-macosx12.0 $(SRC) -o "$(DIST_DIR)/$(BINARY)-arm64" $(FRAMEWORKS)
	$(SWIFTC) $(SWIFTFLAGS) $(RELEASE) -target x86_64-apple-macosx12.0 $(SRC) -o "$(DIST_DIR)/$(BINARY)-x86_64" $(FRAMEWORKS)
	lipo -create "$(DIST_DIR)/$(BINARY)-arm64" "$(DIST_DIR)/$(BINARY)-x86_64" -output "$(DIST_APP)/Contents/MacOS/$(BINARY)"
	cp $(PLIST) "$(DIST_APP)/Contents/Info.plist"
	codesign --force --sign $(SIGN) --identifier $(BUNDLE_ID) "$(DIST_APP)"
	cp LICENSE README.md "$(DIST_DIR)/"
	cd "$(DIST_DIR)" && zip -qry "$(notdir $(DIST_ZIP))" "$(BINARY).app" LICENSE README.md
	cd "$(DIST_DIR)" && shasum -a 256 "$(notdir $(DIST_ZIP))" > SHA256SUMS
	@echo "built $(DIST_ZIP) ($$(du -h "$(DIST_ZIP)" | cut -f1)): $$(lipo -archs "$(DIST_APP)/Contents/MacOS/$(BINARY)")"

# Tagging is the release trigger: .github/workflows/release.yml builds `make dist` on the
# tag and publishes the zip + SHA256SUMS as a GitHub release. Bump CFBundleShortVersionString
# first. HEAD must already be on origin/master: a tag on an unpushed commit would release
# code nobody has reviewed on GitHub.
release: ## Tag v$(VERSION) (from Info.plist) and push the tag — CI builds + publishes the release
	@git diff --quiet && git diff --cached --quiet || { echo "release: commit or stash your changes first"; exit 1; }
	@git fetch -q origin master
	@git merge-base --is-ancestor HEAD origin/master || { echo "release: HEAD is not on origin/master — push it first"; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || { echo "release: tag v$(VERSION) exists — bump CFBundleShortVersionString in $(PLIST)"; exit 1; }
	git tag -a "v$(VERSION)" -m "wifiscan v$(VERSION)"
	git push origin "v$(VERSION)"
	@echo "tagged v$(VERSION) — follow the release build with: gh run watch"

clean: ## Remove local build artifacts (leaves the installed app — see uninstall)
	rm -rf "$(BUILD_APP)" "$(COV_DIR)" "$(DIST_DIR)" "$(TEST_BIN)" "$(BINARY)" _CodeSignature

uninstall: ## Remove wifiscan.app from ~/Applications and the launcher from ~/.bin
	rm -rf "$(APP)" "$(INSTALL_DIR)/$(BINARY)"
	@echo "removed $(APP) and $(INSTALL_DIR)/$(BINARY)"
	@echo "note: the Location Services entry remains in System Settings → Privacy & Security."
