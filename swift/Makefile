.PHONY: build run install uninstall test clean

BINARY := .build/glm-quota-menubar
SOURCES := $(wildcard Sources/GlmQuotaMenubar/*.swift)
PLIST_NAME := com.lixiang.glm-quota-menubar.plist
PLIST_DST := $(HOME)/Library/LaunchAgents/$(PLIST_NAME)

build: $(BINARY)

$(BINARY): $(SOURCES)
	@mkdir -p .build
	swiftc -framework AppKit -o $@ $^

run: build
	nohup $(BINARY) > /tmp/glm-quota-menubar.log 2>&1 &
	@echo "GLM Quota MenuBar started (PID $$!)"
	@echo "Log: /tmp/glm-quota-menubar.log"

install: build
	mkdir -p $(HOME)/Library/LaunchAgents
	sed -e "s|__BINARY__|$(shell pwd)/$(BINARY)|g" \
	    -e "s|__LOG__|/tmp/glm-quota-menubar.log|g" \
	    $(PLIST_NAME) > $(PLIST_DST)
	launchctl bootout gui/$(shell id -u)/$(PLIST_NAME) 2>/dev/null || true
	launchctl bootstrap gui/$(shell id -u) $(PLIST_DST)
	@echo "✅ Installed launchd auto-start"
	@echo "   binary: $(shell pwd)/$(BINARY)"
	launchctl list | grep glm-quota-menubar || true

uninstall:
	launchctl bootout gui/$(shell id -u)/$(PLIST_NAME) 2>/dev/null || true
	rm -f $(PLIST_DST)
	@echo "✅ Removed launchd auto-start"

test: build
	swiftc -o .build/model-tests tests/main.swift Sources/GlmQuotaMenubar/Models.swift
	.build/model-tests

clean:
	rm -rf .build
