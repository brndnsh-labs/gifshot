# gifshot build. This Makefile is the single source of truth for building.
#   make          build and assemble build/gifshot.app
#   make run      build, then (re)launch the app
#   make clean    remove build products
# Override the signing identity with: make SIGN_IDENTITY="Apple Development: ..." run

APP_NAME      := gifshot
CONFIG        ?= release
SIGN_IDENTITY ?= gifshot Local
APP           := build/$(APP_NAME).app

.PHONY: all build app run clean check-identity

all: app

build:
	swift build -c $(CONFIG)

app: build check-identity
	rm -rf build/$(APP_NAME).app
	mkdir -p "$(APP)/Contents/MacOS"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources"
	cp Resources/Status*Template.svg "$(APP)/Contents/Resources/"
	@# The partial plist flag is required: without it actool writes nothing and still exits 0.
	xcrun actool Resources/AppIcon.icon --compile "$(APP)/Contents/Resources" \
	  --platform macosx --minimum-deployment-target 27.0 --app-icon AppIcon \
	  --output-partial-info-plist build/actool-partial.plist \
	  --errors --warnings --output-format human-readable-text
	test -f "$(APP)/Contents/Resources/Assets.car"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	codesign --force --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)" "$(APP)"

run: app
	@pkill -x $(APP_NAME) && sleep 0.5 || true
	open "$(APP)"

clean:
	rm -rf .build build

# A stable identity keeps the Screen Recording grant across rebuilds (see README.md).
check-identity:
	@security find-identity -p codesigning | grep -qF -- '$(SIGN_IDENTITY)' || { \
	  echo "error: code-signing identity '$(SIGN_IDENTITY)' not found."; \
	  echo "Create it once (README.md, First-time setup), or pass SIGN_IDENTITY=\"<name>\"."; \
	  exit 1; }
