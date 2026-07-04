SWIFT     = swiftc
SWFLAGS   = -O -swift-version 5
MIN_MACOS = 11.0
BUILD     = build
BIN       = $(BUILD)/powermate
ID        = io.github.curtiside.powermate

.PHONY: all build run list watch install uninstall setup-karabiner clean

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

# Install as a per-user login agent.
install: build
	sudo install -d /usr/local/bin
	sudo install -m 755 $(BIN) /usr/local/bin/powermate
	sudo install -m 644 $(ID).plist /Library/LaunchAgents/$(ID).plist
	launchctl bootout gui/$(shell id -u) /Library/LaunchAgents/$(ID).plist 2>/dev/null || true
	launchctl bootstrap gui/$(shell id -u) /Library/LaunchAgents/$(ID).plist
	@echo ""
	@echo ">> Grant Input Monitoring to /usr/local/bin/powermate in"
	@echo ">> System Settings > Privacy & Security > Input Monitoring, then:"
	@echo ">>   launchctl kickstart -k gui/$(shell id -u)/$(ID)"

uninstall:
	launchctl bootout gui/$(shell id -u) /Library/LaunchAgents/$(ID).plist 2>/dev/null || true
	sudo rm -f /Library/LaunchAgents/$(ID).plist /usr/local/bin/powermate

# Karabiner recipe: stop a device from hijacking your Mac volume.
# make setup-karabiner KB="<vendor> <product> <label>"
KB ?=
setup-karabiner:
	./karabiner-block-volume.sh $(KB)

clean:
	rm -rf $(BUILD)
