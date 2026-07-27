BINARY  := awsssh
VERSION ?= 0.0.0-dev

DIST    := dist
APP     := $(DIST)/Awsssh.app
BUILD   := $(DIST)/build
RES     := $(APP)/Contents/Resources
ZIP     := $(DIST)/Awsssh-$(VERSION).zip
GOREL   := -trimpath -ldflags "-s -w"

define universal_go
	GOOS=darwin GOARCH=arm64 go build $(GOREL) -o $(BUILD)/$(2).arm64 $(1)
	GOOS=darwin GOARCH=amd64 go build $(GOREL) -o $(BUILD)/$(2).amd64 $(1)
	lipo -create -output $(RES)/$(2) $(BUILD)/$(2).arm64 $(BUILD)/$(2).amd64
endef

.PHONY: build clean test check fmt verify-app \
        app bundle-dirs bundle-go bundle-completions bundle-swift bundle-icon \
        bundle-plist bundle-sign bundle-zip

build:
	mkdir -p $(DIST)
	go build -o $(DIST)/$(BINARY) ./cmd/$(BINARY)

test:
	go test ./...

fmt:
	gofmt -w .
	swift format --in-place --recursive --configuration .swift-format app/Sources app/Tests

check:
	@out=$$(gofmt -l .); if [ -n "$$out" ]; then echo "$$out"; echo "gofmt: run 'make fmt'"; exit 1; fi
	go mod tidy -diff
	go mod verify
	go vet ./...
	go test -race ./...
	golangci-lint run --max-same-issues 0 --max-issues-per-linter 0 ./...
	govulncheck ./...
	actionlint
	swift format lint --strict --recursive --configuration .swift-format app/Sources app/Tests
	go build -trimpath ./...
	@echo "all checks passed"

clean:
	rm -rf $(DIST)

app: bundle-zip

bundle-dirs:
	rm -rf $(APP) $(BUILD)
	mkdir -p $(BUILD) $(APP)/Contents/MacOS $(RES)/completions

bundle-go: bundle-dirs
	$(call universal_go,./cmd/$(BINARY),$(BINARY))
	$(call universal_go,./cmd/$(BINARY)-helper,$(BINARY)-helper)

bundle-completions: bundle-go
	$(RES)/$(BINARY) completion zsh  > $(RES)/completions/_$(BINARY)
	$(RES)/$(BINARY) completion bash > $(RES)/completions/$(BINARY).bash
	$(RES)/$(BINARY) completion fish > $(RES)/completions/$(BINARY).fish

bundle-swift: bundle-completions
	@case "$$(xcode-select -p 2>/dev/null)" in \
	  *.app/*) \
	    echo ">> swift: universal" ; \
	    swift build --package-path app -c release --arch arm64 --arch x86_64 ; \
	    cp app/.build/apple/Products/Release/AwssshApp $(APP)/Contents/MacOS/Awsssh ;; \
	  *) \
	    echo ">> swift: host arch only (install full Xcode for a universal build)" ; \
	    swift build --package-path app -c release ; \
	    cp app/.build/release/AwssshApp $(APP)/Contents/MacOS/Awsssh ;; \
	esac

bundle-icon: bundle-swift
	swift build --package-path app -c release --product IconExport
	app/.build/release/IconExport $(BUILD)/Awsssh.iconset
	iconutil -c icns -o $(RES)/Awsssh.icns $(BUILD)/Awsssh.iconset

bundle-plist: bundle-icon
	sed 's/__VERSION__/$(VERSION)/g' packaging/Info.plist > $(APP)/Contents/Info.plist

bundle-sign: bundle-plist
	codesign --force --deep --sign - $(APP)
	codesign --verify --deep --strict $(APP)

verify-app:
	@for f in _$(BINARY) $(BINARY).bash $(BINARY).fish; do \
	  test -s "$(RES)/completions/$$f" || { echo "missing completion $$f"; exit 1; }; \
	done
	@test -x $(RES)/$(BINARY) || { echo "missing $(BINARY)"; exit 1; }
	@test -x $(RES)/$(BINARY)-helper || { echo "missing $(BINARY)-helper"; exit 1; }
	@test -s $(RES)/Awsssh.icns || { echo "missing Awsssh.icns"; exit 1; }
	@codesign --verify --deep --strict $(APP)
	@for bin in $(RES)/$(BINARY) $(RES)/$(BINARY)-helper; do \
	  archs="$$(lipo -archs $$bin)"; \
	  for want in arm64 x86_64; do \
	    case " $$archs " in *" $$want "*) ;; \
	      *) echo "$$bin is missing $$want (has: $$archs)"; exit 1;; esac; \
	  done; \
	done
	@case "$$(xcode-select -p 2>/dev/null)" in \
	  *.app/*) \
	    archs="$$(lipo -archs $(APP)/Contents/MacOS/Awsssh)" ; \
	    for want in arm64 x86_64; do \
	      case " $$archs " in *" $$want "*) ;; \
	        *) echo "app executable is missing $$want (has: $$archs)"; exit 1;; esac; \
	    done ;; \
	  *) echo "skipping app-executable arch check (no full Xcode)" ;; \
	esac
	@echo "bundle verified"

bundle-zip: bundle-sign
	rm -f $(ZIP)
	cd $(DIST) && ditto -c -k --keepParent Awsssh.app $(notdir $(ZIP))
	@echo ">> $(ZIP)"
	@shasum -a 256 $(ZIP)
