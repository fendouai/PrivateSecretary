.PHONY: build test release demo install uninstall lint smoke e2e install-test soak verify clean

build:
	swift build

release:
	swift build -c release

test:
	./scripts/test.sh

demo:
	swift run secretary demo

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh

lint:
	./scripts/lint.sh

smoke:
	./scripts/smoke-test.sh

e2e:
	./scripts/e2e-test.sh

install-test:
	./scripts/install-test.sh

soak:
	./scripts/soak-test.sh

verify:
	./scripts/verify.sh

clean:
	swift package clean
