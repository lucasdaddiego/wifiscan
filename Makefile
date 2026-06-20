# wifiscan — terminal WiFi survey & channel planner (Swift / CoreWLAN).
# `make` builds a stripped, signed release binary into ~/.bin.

BINARY      := wifiscan
SRC         := Sources/wifiscan/main.swift
PLIST       := Info.plist
INSTALL_DIR := $(HOME)/.bin
SIGN_ID     := local.wifiscan

FRAMEWORKS  := -framework CoreWLAN -framework CoreLocation
# Embed Info.plist (Location-Services usage string) into the binary's __TEXT.
PLIST_LD    := -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(PLIST)
# Release: optimise (-O), strip local symbols (-x), drop dead code (-dead_strip).
# No -g, so zero debug info is emitted. Stripping happens at link time, before
# signing, so the ad-hoc signature stays valid.
RELEASE     := -O -Xlinker -x -Xlinker -dead_strip

.DEFAULT_GOAL := deploy
.PHONY: deploy clean

deploy: ## Build a stripped, signed release binary into ~/.bin
	@mkdir -p $(INSTALL_DIR)
	rm -f "$(INSTALL_DIR)/$(BINARY)"
	swiftc $(RELEASE) $(SRC) -o "$(INSTALL_DIR)/$(BINARY)" $(FRAMEWORKS) $(PLIST_LD)
	codesign --force --sign - --identifier $(SIGN_ID) "$(INSTALL_DIR)/$(BINARY)"
	@echo "deployed $(INSTALL_DIR)/$(BINARY) ($$(du -h "$(INSTALL_DIR)/$(BINARY)" | cut -f1))"

clean: ## Remove the deployed binary
	rm -f "$(INSTALL_DIR)/$(BINARY)"
