BINARY   := birne
INSTALL  := /usr/local/bin/$(BINARY)
BUILD    := .build/release/$(BINARY)

.PHONY: build install uninstall clean

build:
	swift build -c release

install: build
	cp $(BUILD) $(INSTALL)
	@echo "installed to $(INSTALL)"

uninstall:
	rm -f $(INSTALL)
	@echo "removed $(INSTALL)"

clean:
	swift package clean
