BINARY  := awsssh
VERSION ?= 0.0.0-dev

DIST  := dist
APP   := $(DIST)/Awsssh.app
BUILD := $(DIST)/build
RES   := $(APP)/Contents/Resources
ZIP   := $(DIST)/Awsssh-$(VERSION).zip

GOREL       := -trimpath -ldflags "-s -w"
SWIFT_FILES := --recursive --configuration .swift-format app/Sources app/Tests

ifeq ($(findstring .app/,$(shell xcode-select -p 2>/dev/null)),.app/)
SWIFT_BUILD   := swift build --package-path app -c release --arch arm64 --arch x86_64
SWIFT_PRODUCT := app/.build/apple/Products/Release/AwssshApp
SWIFT_ARCH    := universal
else
SWIFT_BUILD   := swift build --package-path app -c release
SWIFT_PRODUCT := app/.build/release/AwssshApp
SWIFT_ARCH    := host arch only (install full Xcode for a universal build)
endif

define universal_go
	GOOS=darwin GOARCH=arm64 go build $(GOREL) -o $(BUILD)/$(2).arm64 $(1)
	GOOS=darwin GOARCH=amd64 go build $(GOREL) -o $(BUILD)/$(2).amd64 $(1)
	lipo -create -output $(RES)/$(2) $(BUILD)/$(2).arm64 $(BUILD)/$(2).amd64
endef

define require_universal
archs="$$(lipo -archs $(1))"; \
for want in arm64 x86_64; do \
  case " $$archs " in *" $$want "*) ;; \
    *) echo "$(1) is missing $$want (has: $$archs)"; exit 1;; esac; \
done
endef

define require_file
test -s $(1) || { echo "missing $(1)"; exit 1; }
endef

.PHONY: build test fmt check app verify-app clean

build:
	mkdir -p $(DIST)
	go build -o $(DIST)/$(BINARY) ./cmd/$(BINARY)

test:
	go test ./...

fmt:
	gofmt -w .
	swift format --in-place $(SWIFT_FILES)

check:
	@out=$$(gofmt -l .); if [ -n "$$out" ]; then echo "$$out"; echo "gofmt: run 'make fmt'"; exit 1; fi
	go mod tidy -diff
	go mod verify
	go vet ./...
	go test -race ./...
	golangci-lint run --max-same-issues 0 --max-issues-per-linter 0 ./...
	govulncheck ./...
	actionlint
	swift format lint --strict $(SWIFT_FILES)
	go build -trimpath ./...
	@echo "all checks passed"

app:
	@echo ">> layout"
	rm -rf $(APP) $(BUILD)
	mkdir -p $(BUILD) $(APP)/Contents/MacOS $(RES)/completions
	@echo ">> go binaries: universal"
	$(call universal_go,./cmd/$(BINARY),$(BINARY))
	$(call universal_go,./cmd/$(BINARY)-helper,$(BINARY)-helper)
	@echo ">> completions"
	$(RES)/$(BINARY) completion zsh  > $(RES)/completions/_$(BINARY)
	$(RES)/$(BINARY) completion bash > $(RES)/completions/$(BINARY).bash
	$(RES)/$(BINARY) completion fish > $(RES)/completions/$(BINARY).fish
	@echo ">> swift: $(SWIFT_ARCH)"
	$(SWIFT_BUILD)
	cp $(SWIFT_PRODUCT) $(APP)/Contents/MacOS/Awsssh
	@echo ">> icon"
	swift build --package-path app -c release --product IconExport
	app/.build/release/IconExport $(BUILD)/Awsssh.iconset
	iconutil -c icns -o $(RES)/Awsssh.icns $(BUILD)/Awsssh.iconset
	@echo ">> Info.plist: $(VERSION)"
	sed 's/__VERSION__/$(VERSION)/g' packaging/Info.plist > $(APP)/Contents/Info.plist
	@echo ">> sign"
	codesign --force --deep --sign - $(APP)
	codesign --verify --deep --strict $(APP)
	@echo ">> zip"
	rm -f $(ZIP)
	cd $(DIST) && ditto -c -k --keepParent Awsssh.app $(notdir $(ZIP))
	@echo ">> $(ZIP)"
	@shasum -a 256 $(ZIP)

verify-app:
	@$(call require_file,$(RES)/completions/_$(BINARY))
	@$(call require_file,$(RES)/completions/$(BINARY).bash)
	@$(call require_file,$(RES)/completions/$(BINARY).fish)
	@$(call require_file,$(RES)/Awsssh.icns)
	@test -x $(RES)/$(BINARY) || { echo "missing $(BINARY)"; exit 1; }
	@test -x $(RES)/$(BINARY)-helper || { echo "missing $(BINARY)-helper"; exit 1; }
	@codesign --verify --deep --strict $(APP)
	@$(call require_universal,$(RES)/$(BINARY))
	@$(call require_universal,$(RES)/$(BINARY)-helper)
ifeq ($(SWIFT_ARCH),universal)
	@$(call require_universal,$(APP)/Contents/MacOS/Awsssh)
else
	@echo "skipping app-executable arch check (no full Xcode)"
endif
	@echo "bundle verified"

clean:
	rm -rf $(DIST)
