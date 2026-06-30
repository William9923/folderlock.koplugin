describe("FolderLock plugin", function()
	local DataStorage, FileManager, Screen, UIManager, lfs, ffiUtil, LuaSettings, makePath
	local test_root, open_dir, locked_dir, locked_sub_dir, registry_file
	local fm
	local test_idx = 0

	local orig_FileChooser_changeToPath

	local function create_dir(path)
		makePath(path)
		assert.is_not_nil(lfs.attributes(path, "mode"), "failed to create dir: " .. path)
	end

	local function remove_tree(path)
		local mode = lfs.attributes(path, "mode")
		if mode == "directory" then
			for entry in lfs.dir(path) do
				if entry ~= "." and entry ~= ".." then
					remove_tree(path .. "/" .. entry)
				end
			end
			lfs.rmdir(path)
		elseif mode == "file" then
			os.remove(path)
		end
	end

	local function cleanup_registry()
		os.remove(registry_file)
	end

	local function seed_registry(entries)
		cleanup_registry()
		local reg = LuaSettings:open(registry_file)
		reg:saveSetting("locks", entries or {})
		reg:flush()
	end

	local function djb2_hash(str)
		local bit = require("bit")
		local hash = 5381
		for i = 1, #str do
			hash = bit.bxor(hash * 33 + str:byte(i), 0xFFFFFFFF)
		end
		return tostring(hash)
	end

	local function reset_global_plugin_state()
		local ok_guard, FolderLockGuard = pcall(require, "lib/folderlock_guard")
		if ok_guard and FolderLockGuard and type(FolderLockGuard._reset) == "function" then
			FolderLockGuard._reset()
		end

		local FileChooser = require("ui/widget/filechooser")
		if not orig_FileChooser_changeToPath then
			orig_FileChooser_changeToPath = FileChooser.changeToPath
		else
			FileChooser.changeToPath = orig_FileChooser_changeToPath
		end

		local PluginLoader = require("pluginloader")
		PluginLoader.enabled_plugins = {}
		PluginLoader.disabled_plugins = {}
		PluginLoader.loaded_plugins = {}

		load_plugin("folderlock.koplugin")
	end

	local function create_filemanager(root_path)
		fm = FileManager:new({
			dimen = Screen:getSize(),
			root_path = root_path,
		})
		UIManager:show(fm)
		fastforward_ui_events()
		assert.is_not_nil(fm.file_chooser, "file_chooser should exist")
		return fm
	end

	local function find_password_dialog()
		for widget in UIManager:topdown_widgets_iter() do
			if
				type(widget) == "table"
				and type(widget.getInputText) == "function"
				and type(widget.setInputText) == "function"
				and widget.text_type == "password"
			then
				return widget
			end
		end
		return nil
	end

	setup(function()
		require("commonrequire")
		DataStorage = require("datastorage")
		FileManager = require("apps/filemanager/filemanager")
		Screen = require("device").screen
		UIManager = require("ui/uimanager")
		lfs = require("libs/libkoreader-lfs")
		ffiUtil = require("ffi/util")
		LuaSettings = require("luasettings")
		makePath = require("util").makePath

		registry_file = DataStorage:getSettingsDir() .. "/folderlock_registry.lua"
	end)

	before_each(function()
		test_idx = test_idx + 1
		test_root = DataStorage:getDataDir() .. "/folderlock_test_" .. tostring(test_idx)
		open_dir = test_root .. "/open"
		locked_dir = test_root .. "/locked"
		locked_sub_dir = locked_dir .. "/sub"

		create_dir(open_dir)
		create_dir(locked_sub_dir)

		reset_global_plugin_state()
		seed_registry({})
	end)

	after_each(function()
		if fm then
			fm:onClose()
			fm = nil
		end
		UIManager:quit()

		cleanup_registry()
		remove_tree(test_root)

		-- Always restore class-level patch target so tests don't leak state.
		local FileChooser = require("ui/widget/filechooser")
		if orig_FileChooser_changeToPath then
			FileChooser.changeToPath = orig_FileChooser_changeToPath
		end

		disable_plugins()
	end)

	it("creates deterministic directory fixtures", function()
		assert.are.equal("directory", lfs.attributes(open_dir, "mode"))
		assert.are.equal("directory", lfs.attributes(locked_dir, "mode"))
		assert.are.equal("directory", lfs.attributes(locked_sub_dir, "mode"))
	end)

	it("seeds and cleans registry deterministically", function()
		local entries = {
			[locked_dir] = djb2_hash("seed"),
		}
		seed_registry(entries)

		local reg = LuaSettings:open(registry_file)
		local locks = reg:readSetting("locks") or {}
		assert.are.same(entries, locks)

		cleanup_registry()
		assert.is_nil(lfs.attributes(registry_file, "mode"))
	end)

	it("smoke: patches FileChooser.changeToPath on plugin init", function()
		local FileChooser = require("ui/widget/filechooser")
		local before_patch = FileChooser.changeToPath

		create_filemanager(open_dir)

		local after_patch = require("ui/widget/filechooser").changeToPath
		assert.are_not.equal(before_patch, after_patch)
	end)

	it("smoke: unlocked navigation succeeds via patched changeToPath", function()
		create_filemanager(open_dir)

		fm.file_chooser:changeToPath(locked_sub_dir)
		local expected = ffiUtil.realpath(locked_sub_dir) or locked_sub_dir
		local actual = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		assert.are.equal(expected, actual)
	end)

	it("scenario: unlocked navigation is unaffected even when another folder is locked", function()
		seed_registry({
			[ffiUtil.realpath(locked_dir) or locked_dir] = djb2_hash("secret123"),
		})

		create_filemanager(test_root)

		fm.file_chooser:changeToPath(open_dir)
		local expected = ffiUtil.realpath(open_dir) or open_dir
		local actual = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		assert.are.equal(expected, actual)
	end)

	it("scenario: locked navigation shows password prompt and keeps current path", function()
		seed_registry({
			[ffiUtil.realpath(locked_dir) or locked_dir] = djb2_hash("secret123"),
		})

		create_filemanager(test_root)

		local before = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path

		-- Try entering a locked folder
		fm.file_chooser:changeToPath(locked_dir)
		fastforward_ui_events()

		-- Path should remain unchanged until successful unlock
		local after = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		assert.are.equal(before, after)

		-- Verify a password dialog is shown
		local dialog = find_password_dialog()
		assert.is_not_nil(dialog, "password InputDialog should be visible for locked folder")

		-- Cleanup shown dialog to avoid leaking UI state across tests
		UIManager:close(dialog)
	end)

	it("scenario: wrong password keeps lock and path unchanged", function()
		local password = "secret123"
		seed_registry({
			[ffiUtil.realpath(locked_dir) or locked_dir] = djb2_hash(password),
		})

		create_filemanager(test_root)

		-- Trigger lock prompt
		fm.file_chooser:changeToPath(locked_dir)
		fastforward_ui_events()

		local before = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		local dialog = find_password_dialog()
		assert.is_not_nil(dialog, "password dialog should appear on locked navigation")

		local unlock_cb = dialog.buttons
			and dialog.buttons[1]
			and dialog.buttons[1][2]
			and dialog.buttons[1][2].callback
		assert.is_not_nil(unlock_cb, "unlock callback should be available")

		-- Wrong password: path must remain unchanged, dialog should remain available
		dialog:setInputText("wrong-password")
		unlock_cb()
		fastforward_ui_events()

		local after_wrong = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		assert.are.equal(before, after_wrong)

		local still_visible = find_password_dialog()
		assert.is_not_nil(still_visible, "password dialog should still be visible after wrong password")

		-- Cleanup dialog to avoid UI state leakage
		UIManager:close(still_visible)
	end)

	it("scenario: correct password unlocks and navigates to locked path", function()
		local password = "secret123"
		seed_registry({
			[ffiUtil.realpath(locked_dir) or locked_dir] = djb2_hash(password),
		})

		create_filemanager(test_root)

		-- Trigger lock prompt
		fm.file_chooser:changeToPath(locked_dir)
		fastforward_ui_events()

		local dialog = find_password_dialog()
		assert.is_not_nil(dialog, "password dialog should appear on locked navigation")

		local unlock_cb = dialog.buttons
			and dialog.buttons[1]
			and dialog.buttons[1][2]
			and dialog.buttons[1][2].callback
		assert.is_not_nil(unlock_cb, "unlock callback should be available")

		-- Correct password: navigation should proceed to locked_dir
		dialog:setInputText(password)
		unlock_cb()
		fastforward_ui_events()

		local expected = ffiUtil.realpath(locked_dir) or locked_dir
		local after_correct = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		assert.are.equal(expected, after_correct)

		local leftover_dialog = find_password_dialog()
		if leftover_dialog then
			UIManager:close(leftover_dialog)
		end
	end)

	it("scenario: ancestor lock on parent blocks child path and prompts", function()
		-- Lock parent folder, attempt to enter child folder
		seed_registry({
			[ffiUtil.realpath(locked_dir) or locked_dir] = djb2_hash("secret123"),
		})

		create_filemanager(test_root)

		local before = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path

		fm.file_chooser:changeToPath(locked_sub_dir)
		fastforward_ui_events()

		local after = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		assert.are.equal(before, after, "child path should be blocked by parent lock")

		local dialog = find_password_dialog()
		assert.is_not_nil(dialog, "password dialog should appear for child path when parent is locked")
		UIManager:close(dialog)
	end)

	it("scenario: lock enforcement persists after FileManager/plugin re-init", function()
		local hash = djb2_hash("secret123")
		seed_registry({
			[ffiUtil.realpath(locked_dir) or locked_dir] = hash,
		})

		-- First runtime instance: lock is enforced
		create_filemanager(test_root)
		local before_first = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		fm.file_chooser:changeToPath(locked_sub_dir)
		fastforward_ui_events()
		local after_first = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		assert.are.equal(before_first, after_first, "first instance should block locked child path")

		local first_dialog = find_password_dialog()
		assert.is_not_nil(first_dialog, "first instance should show lock prompt")
		UIManager:close(first_dialog)

		-- Re-init runtime context without reseeding registry (persistence check)
		if fm then
			fm:onClose()
			fm = nil
		end
		UIManager:quit()

		reset_global_plugin_state()

		create_filemanager(test_root)
		local before_second = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		fm.file_chooser:changeToPath(locked_sub_dir)
		fastforward_ui_events()
		local after_second = ffiUtil.realpath(fm.file_chooser.path) or fm.file_chooser.path
		assert.are.equal(before_second, after_second, "re-init instance should still block locked child path")

		local second_dialog = find_password_dialog()
		assert.is_not_nil(second_dialog, "re-init instance should still show lock prompt")
		UIManager:close(second_dialog)
	end)

	describe("Long-press menu button", function()
		it("shows Lock folder for unlocked folder", function()
			seed_registry({})
			create_filemanager(test_root)

			local row_func = fm.file_dialog_added_buttons[1]
			assert.is_not_nil(row_func, "row_func should be registered")

			local result = row_func(open_dir, false, nil)
			assert.is_not_nil(result, "should return a button row for folders")
			assert.are.equal("Lock folder", result[1].text)
		end)

		it("shows Unlock folder for locked folder", function()
			local locked_path = ffiUtil.realpath(locked_dir) or locked_dir
			seed_registry({
				[locked_path] = djb2_hash("secret123"),
			})
			create_filemanager(test_root)

			local row_func = fm.file_dialog_added_buttons[1]
			assert.is_not_nil(row_func, "row_func should be registered")

			local result = row_func(locked_dir, false, nil)
			assert.is_not_nil(result, "should return a button row for locked folder")
			assert.are.equal("Unlock folder", result[1].text)
		end)

		it("returns nil for folder inside locked parent", function()
			local locked_path = ffiUtil.realpath(locked_dir) or locked_dir
			seed_registry({
				[locked_path] = djb2_hash("secret123"),
			})
			create_filemanager(test_root)

			local row_func = fm.file_dialog_added_buttons[1]
			assert.is_not_nil(row_func, "row_func should be registered")

			local result = row_func(locked_sub_dir, false, nil)
			assert.is_nil(result, "should skip button for child of locked parent")
		end)
	end)

	describe("Update system", function()
		it("smoke: updater module loads and reports version", function()
			local Updater = require("lib/folderlock_updater")
			local v = Updater.get_current_version()
			assert.is_not_nil(v)
			assert.is_true(type(v) == "string")
		end)

		it("smoke: URL override round-trips", function()
			local Updater = require("lib/folderlock_updater")
			local test_url = "http://127.0.0.1:18080/latest.json"
			local default = Updater.get_latest_release_url()
			Updater.set_latest_release_url(test_url)
			assert.are.equal(Updater.get_latest_release_url(), test_url)
			Updater.set_latest_release_url(nil)
			assert.are.equal(Updater.get_latest_release_url(), default)
		end)

		it("smoke: recover_or_cleanup runs without error", function()
			local Updater = require("lib/folderlock_updater")
			local ok, err = Updater.recover_or_cleanup()
			assert.is_true(ok, tostring(err))
		end)
	end)

	describe("Cover cache isolation hooks", function()
		it("BookList.hasBookBeenOpened hides locked files outside context and shows inside", function()
			local password = "secret123"
			local locked_path = ffiUtil.realpath(locked_dir) or locked_dir
			seed_registry({
				[locked_path] = djb2_hash(password),
			})

			create_filemanager(test_root)

			local locked_file = locked_dir .. "/book.epub"
			local sidecar_dir = locked_dir .. "/book.sdr"
			local sidecar_file = sidecar_dir .. "/metadata.epub.lua"
			makePath(sidecar_dir)
			local f = io.open(sidecar_file, "w")
			f:write("return {}\n")
			f:close()

			local FolderLockCacheIsolation = require("lib/folderlock_cache_isolation")
			local BookList = require("ui/widget/booklist")

			-- Outside context → hidden
			FolderLockCacheIsolation.set_current_path(test_root)
			BookList.book_info_cache[locked_file] = nil
			assert.is_false(BookList.hasBookBeenOpened(locked_file))

			-- Inside locked folder context → visible
			FolderLockCacheIsolation.set_current_path(locked_path)
			BookList.book_info_cache[locked_file] = nil
			assert.is_true(BookList.hasBookBeenOpened(locked_file))

			FolderLockCacheIsolation.set_current_path(nil)
		end)

		it("BookInfoManager and BookList hooks are installed when modules are available", function()
			local BookList = require("ui/widget/booklist")
			assert.is_true(BookList._folderlock_getBookInfo_hooked)
			assert.is_true(BookList._folderlock_hasBookBeenOpened_hooked)

			local ok, BookInfoManager = pcall(require, "bookinfomanager")
			if ok and BookInfoManager then
				assert.is_true(BookInfoManager._folderlock_getBookInfo_hooked)
				assert.is_true(BookInfoManager._folderlock_getDocProps_hooked)
			end
		end)
	end)
end)
