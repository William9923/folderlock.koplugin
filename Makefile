.PHONY: all ci test-unit test-e2e lint package-release run-koreader

LUA ?= lua
KOREADER_DIR ?= vendor/koreader
PLUGIN_NAME ?= folderlock.koplugin
PLUGIN_SRC ?= $(CURDIR)/$(PLUGIN_NAME)
PLUGIN_DST ?= $(KOREADER_DIR)/plugins/$(PLUGIN_NAME)
RUN_TARGET ?=
SIMULATE ?=
KODEV_OPTS ?=

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

run-koreader:
	@if [ ! -d "$(KOREADER_DIR)" ]; then \
		echo "koreader directory not found: $(KOREADER_DIR)"; \
		echo "Run: git submodule update --init --recursive"; \
		exit 1; \
	fi
	@if [ ! -x "$(KOREADER_DIR)/kodev" ]; then \
		echo "kodev script not found/executable: $(KOREADER_DIR)/kodev"; \
		exit 1; \
	fi
	@if [ ! -d "$(PLUGIN_SRC)" ]; then \
		echo "plugin source not found: $(PLUGIN_SRC)"; \
		exit 1; \
	fi
	@mkdir -p "$(KOREADER_DIR)/plugins"
	@rm -rf "$(PLUGIN_DST)"
	@ln -sfn "$(PLUGIN_SRC)" "$(PLUGIN_DST)"
	@echo "Linked $(PLUGIN_DST) -> $(PLUGIN_SRC)"
	@set --; \
	if [ -n "$(SIMULATE)" ]; then \
		set -- "$$@" --simulate="$(SIMULATE)"; \
	fi; \
	if [ -n "$(RUN_TARGET)" ]; then \
		set -- "$$@" "$(RUN_TARGET)"; \
	fi; \
	cd "$(KOREADER_DIR)" && ./kodev run $(KODEV_OPTS) "$$@"
