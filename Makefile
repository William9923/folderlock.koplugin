.PHONY: all ci test-unit test-e2e lint package-release

LUA ?= lua

all: test-unit test-e2e
ci: all

test-unit:
	LUA="$(LUA)" sh tests/run_unit.sh

test-e2e:
	sh tests/run_e2e.sh

lint:
	luacheck folderlock.koplugin tests

package-release:
	sh scripts/package_release.sh $(VERSION)
