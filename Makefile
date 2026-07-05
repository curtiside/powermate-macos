SWIFT     = swiftc
SWFLAGS   = -O -swift-version 5
MIN_MACOS = 11.0
BUILD     = build
BIN       = $(BUILD)/powermate
ID        = io.github.curtiside.powermate

.PHONY: all build run list watch test install uninstall config setup-karabiner clean

all: build

# Universal (arm64 + x86_64), ad-hoc signed.
build:
	mkdir -p $(BUILD)
	$(SWIFT) $(SWFLAGS) -target arm64-apple-macosx$(MIN_MACOS)  powermate.swift -o $(BUILD)/powermate-arm64
	$(SWIFT) $(SWFLAGS) -target x86_64-apple-macosx$(MIN_MACOS) powermate.swift -o $(BUILD)/powermate-x86_64
	lipo -create -output $(BIN) $(BUILD)/powermate-arm64 $(BUILD)/powermate-x86_64
	codesign --force --identifier $(ID) --sign - $(BIN)

run:   build ; $(BIN)
list:  build ; $(BIN) --list
watch: build ; $(BIN) --watch
test:  build ; $(BIN) --selftest

# Install as a per-user login agent (~/Library/LaunchAgents — sudo is needed
# only for the binary in /usr/local/bin). Migrates away from the old all-users
# /Library/LaunchAgents location if a previous version put the plist there.
AGENTS = $(HOME)/Library/LaunchAgents
install: build
	sudo install -d /usr/local/bin
	sudo install -m 755 $(BIN) /usr/local/bin/powermate
	launchctl bootout gui/$(shell id -u) /Library/LaunchAgents/$(ID).plist 2>/dev/null || true
	@if [ -f /Library/LaunchAgents/$(ID).plist ]; then \
		echo "migrating old all-users agent out of /Library/LaunchAgents"; \
		sudo rm -f /Library/LaunchAgents/$(ID).plist; \
	fi
	mkdir -p $(AGENTS) $(HOME)/Library/Logs
	sed 's|__HOME__|$(HOME)|g' $(ID).plist > $(AGENTS)/$(ID).plist
	launchctl bootout gui/$(shell id -u) $(AGENTS)/$(ID).plist 2>/dev/null || true
	launchctl bootstrap gui/$(shell id -u) $(AGENTS)/$(ID).plist
	@echo ""
	@echo ">> Grant Input Monitoring to /usr/local/bin/powermate in"
	@echo ">> System Settings > Privacy & Security > Input Monitoring, then:"
	@echo ">>   launchctl kickstart -k gui/$(shell id -u)/$(ID)"
	@echo ">> Logs: ~/Library/Logs/powermate.log"
	@echo ">> Optional: 'make config' installs an example config to ~/.config/powermate/"

uninstall:
	launchctl bootout gui/$(shell id -u) $(AGENTS)/$(ID).plist 2>/dev/null || true
	launchctl bootout gui/$(shell id -u) /Library/LaunchAgents/$(ID).plist 2>/dev/null || true
	rm -f $(AGENTS)/$(ID).plist
	sudo rm -f /Library/LaunchAgents/$(ID).plist /usr/local/bin/powermate

# Install the example config to ~/.config/powermate/ (won't overwrite an existing one).
config:
	@mkdir -p $(HOME)/.config/powermate
	@if [ -e $(HOME)/.config/powermate/powermate.conf ]; then \
		echo "exists: $(HOME)/.config/powermate/powermate.conf (left untouched)"; \
	else \
		install -m 644 powermate.conf.example $(HOME)/.config/powermate/powermate.conf; \
		echo "installed: $(HOME)/.config/powermate/powermate.conf"; \
	fi

# Karabiner recipe: stop a device from hijacking your Mac volume.
# make setup-karabiner KB="<vendor> <product> <label>"
KB ?=
setup-karabiner:
	./karabiner-block-volume.sh $(KB)

clean:
	rm -rf $(BUILD)
