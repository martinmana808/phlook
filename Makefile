# CLT_FPATH: where Testing.framework lives on Command Line Tools-only machines.
# On full Xcode installs the framework is in the SDK and -F is not needed,
# but it is harmless to pass it there too.
CLT_FPATH := /Library/Developer/CommandLineTools/Library/Developer/Frameworks

.PHONY: build test clean ingest

build:
	swift build

test:
	swift test \
	  -Xswiftc -F -Xswiftc $(CLT_FPATH)

clean:
	swift package clean

# Run a single test/suite by name: make test-one NAME=SomeTests
test-one:
	swift test -Xswiftc -F -Xswiftc $(CLT_FPATH) --filter $(NAME)

# Build a double-clickable Phlook.app bundle
app:
	./scripts/bundle-app.sh release

# Build + open the app bundle
run-app: app
	open ./Phlook.app

# Ingest staged media into the library:
#   make ingest                      (~/Pictures/PHLOOK_staging → ~/Pictures/PHLOOK)
#   make ingest STAGING=/p LIBRARY=/q
ingest:
	swift run -c release phlook-ingest $(STAGING) $(LIBRARY)
