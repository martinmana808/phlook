# CLT_FPATH: where Testing.framework lives on Command Line Tools-only machines.
# On full Xcode installs the framework is in the SDK and -F is not needed,
# but it is harmless to pass it there too.
CLT_FPATH := /Library/Developer/CommandLineTools/Library/Developer/Frameworks

.PHONY: build test clean

build:
	swift build

test:
	swift test \
	  -Xswiftc -F -Xswiftc $(CLT_FPATH)

clean:
	swift package clean
