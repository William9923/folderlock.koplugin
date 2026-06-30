--[[--
Shared password-dialog helper and single-use unlock token for file-open interception.
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local FileChooser = require("ui/widget/filechooser")
local DocumentRegistry = require("document/documentregistry")
local FileManager = require("apps/filemanager/filemanager")
local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
local FileManagerCollection = require("apps/filemanager/filemanagercollection")
local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
local FolderLockCore = require("lib/folderlock_core")
local ReaderUI = nil -- lazy-loaded in install_readerui_patches
local FolderLockCacheIsolation = require("lib/folderlock_cache_isolation")
local _ = require("gettext")

local FolderLockGuard = {}

local default_on_denied = function()
	UIManager:show(InfoMessage:new({
		text = _("Access Denied"),
		timeout = 2,
	}))
end

-- single-use unlock token table
local _allow_once = {}

-- FileChooser patch state: keep a reference to the wrapper so we can tell
local _filechooser_patch_wrapper = nil

-- ReaderUI patch state: keep a reference to the wrapper so we can tell
local _readerui_showReader_patch_wrapper = nil
local _readerui_switchDocument_patch_wrapper = nil

-- List source patch state
local _list_patches_installed = false

-- ReaderUI patch state
local _readerui_patches_installed = false

--- Set a single-use unlock token for the normalized path.
function FolderLockGuard.allow_once(path)
	local norm = FolderLockCore.normalize_path(path)
	if norm then
		_allow_once[norm] = true
	end
end

--- Check token without consuming it.
function FolderLockGuard.peek_once(path)
	local norm = FolderLockCore.normalize_path(path)
	return not not (norm and _allow_once[norm])
end

--- Check and consume a single-use unlock token.
function FolderLockGuard.consume_once(path)
	local norm = FolderLockCore.normalize_path(path)
	if norm and _allow_once[norm] then
		_allow_once[norm] = nil
		return true
	end
	return false
end

--- Run a function with a single-use unlock token set for the path.
--- The token is cleared when fn returns (or errors).
function FolderLockGuard.with_unlock_token(path, fn)
	local norm = FolderLockCore.normalize_path(path)
	if norm then
		_allow_once[norm] = true
	end
	local ok, err = pcall(fn)
	if norm then
		_allow_once[norm] = nil
	end
	if not ok then
		error(err)
	end
	return ok, err
end

--- If `path` is inside a locked tree, show a password dialog.
--- On correct password (or if already unlocked) call `on_allowed`.
--- On Cancel call `on_denied` (optional. if not provided use default_on_denied).
function FolderLockGuard.prompt_unlock_or_block(path, on_allowed, on_denied)
	local real_path = FolderLockCore.normalize_path(path)
	if not real_path then
		if on_allowed then
			on_allowed()
		end
		return
	end

	local locked_path = FolderLockCore.check_folder_lock(real_path)
	if not locked_path then
		if on_allowed then
			on_allowed()
		end
		return
	end

	-- locked: show password dialog
	local dialog
	dialog = InputDialog:new({
		title = _("Folder Lock"),
		text_type = "password",
		input_hint = _("Enter password"),
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(dialog)
						if on_denied then
							on_denied()
						else
							default_on_denied()
						end
					end,
				},
				{
					text = _("Enter"),
					is_enter_default = true,
					callback = function()
						local input = dialog:getInputText()
						local hash = FolderLockCore.djb2_hash(input)
						local stored = FolderLockCore.get_lock_hash(locked_path)
						if not stored then
							-- no stored hash (shouldn't happen), allow through
							UIManager:close(dialog)
							if on_allowed then
								on_allowed()
							end
							return
						end

						if hash == stored then
							UIManager:close(dialog)
							if on_allowed then
								on_allowed()
							end
							return
						end

						UIManager:show(InfoMessage:new({
							text = _("Incorrect password"),
							timeout = 2,
						}))
						dialog:onClose()
						UIManager:show(dialog)
						dialog:onShowKeyboard()
					end,
				},
			},
		},
	})
	UIManager:show(dialog)
	dialog:onShowKeyboard()
end

-- ── FileChooser.changeToPath patch ──

function FolderLockGuard.install_ensure_filechooser_patch()
	if type(FileChooser.changeToPath) ~= "function" then
		return
	end

	-- idempotent patch check
	if _filechooser_patch_wrapper and FileChooser.changeToPath == _filechooser_patch_wrapper then
		return
	end

	-- Capture the original in a local so a later reset/re-patch cannot make
	-- this closure recurse into itself (Lua closures capture the variable,
	-- not the value, so a module-level upvalue that gets reassigned is unsafe).
	local orig_FileChooser_changeToPath = FileChooser.changeToPath

	FileChooser.changeToPath = function(self_fc, path, focused_path)
		local chooser_name = self_fc and self_fc.name or "nil"

		if chooser_name ~= "filemanager" then
			return orig_FileChooser_changeToPath(self_fc, path, focused_path)
		end

		local real_path = FolderLockCore.normalize_path(path)
		if not real_path then
			return orig_FileChooser_changeToPath(self_fc, path, focused_path)
		end

		-- Consume a pre-authorized unlock token (set by File Search folder result)
		if FolderLockGuard.consume_once(real_path) then
			return FolderLockCacheIsolation.with_context(real_path, function()
				return orig_FileChooser_changeToPath(self_fc, path, focused_path)
			end)
		end

		local locked_path = FolderLockCore.check_folder_lock(real_path)
		if not locked_path then
			return FolderLockCacheIsolation.with_context(real_path, function()
				return orig_FileChooser_changeToPath(self_fc, path, focused_path)
			end)
		end

		FolderLockGuard.prompt_unlock_or_block(real_path, function()
			FolderLockCacheIsolation.with_context(real_path, function()
				orig_FileChooser_changeToPath(self_fc, path, focused_path)
			end)
		end)
	end

	_filechooser_patch_wrapper = FileChooser.changeToPath
end

-- ── List source patches (History, Collection, File Search) ──

function FolderLockGuard.install_list_source_patches()
	if _list_patches_installed then
		return
	end

	-- History
	do
		local orig = FileManagerHistory.onMenuSelect
		FileManagerHistory.onMenuSelect = function(self, item)
			FolderLockGuard.prompt_unlock_or_block(item.file, function()
				FolderLockGuard.with_unlock_token(item.file, function()
					orig(self, item)
				end)
			end)
		end
	end

	-- Collection / Favorites
	do
		local orig = FileManagerCollection.onMenuSelect
		FileManagerCollection.onMenuSelect = function(self, item)
			if self._manager.selected_files then
				return orig(self, item)
			end
			FolderLockGuard.prompt_unlock_or_block(item.file, function()
				FolderLockGuard.with_unlock_token(item.file, function()
					orig(self, item)
				end)
			end)
		end
	end

	-- File Search
	do
		local orig = FileSearcher.onMenuSelect
		FileSearcher.onMenuSelect = function(self, item)
			if lfs.attributes(item.path) == nil then
				return
			end
			if self._manager.selected_files then
				return orig(self, item)
			end

			local function guarded()
				FolderLockGuard.with_unlock_token(item.path, function()
					orig(self, item)
				end)
			end

			if item.is_file then
				if DocumentRegistry:hasProvider(item.path, nil, true) then
					FolderLockGuard.prompt_unlock_or_block(item.path, guarded)
				end
			else
				if FolderLockCore.check_folder_lock(item.path) then
					FolderLockGuard.prompt_unlock_or_block(item.path, guarded)
				else
					orig(self, item)
				end
			end
		end
	end

	_list_patches_installed = true
end

-- ── ReaderUI.showReader / switchDocument patches ──

function FolderLockGuard.install_readerui_patches()
	if not ReaderUI then
		ReaderUI = require("apps/reader/readerui")
	end
	if _readerui_patches_installed then
		return
	end

	if type(ReaderUI.showReader) ~= "function" or type(ReaderUI.switchDocument) ~= "function" then
		return
	end

	-- idempotent patch check
	if
		(_readerui_showReader_patch_wrapper and ReaderUI.showReader == _readerui_showReader_patch_wrapper)
		and (
			_readerui_switchDocument_patch_wrapper
			and ReaderUI.switchDocument == _readerui_switchDocument_patch_wrapper
		)
	then
		return
	end

	-- A locked file is "visible" (not hidden) exactly when we are browsing
	-- inside the locked tree that contains it.
	local function is_inside_current_locked_tree(file)
		local folder_path = FileManager.instance.file_chooser.path
		return not FolderLockCacheIsolation.is_hidden_path(file, folder_path)
	end

	local orig_showReader = ReaderUI.showReader
	-- Patch showReader in ReaderUI
	ReaderUI.showReader = function(self, file, provider, seamless, is_provider_forced, after_open_callback)
		-- Token set by a list-source pre-guard (History, Collection, File Search)
		if FolderLockGuard.consume_once(file) then
			return orig_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
		end

		-- Re-opening the current document -> skip
		local function is_current()
			return self.document
				and self.document.file
				and FolderLockCore.normalize_path(self.document.file) == FolderLockCore.normalize_path(file)
		end

		if is_current() then
			return orig_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
		end

		local normalized_path = FolderLockCore.normalize_path(file)
		print("[FOLDERLOCK]:" .. normalized_path)
		print("[FOLDERLOCK] is_inside_current_locked_tree:", is_inside_current_locked_tree(normalized_path))

		-- Already browsing inside the locked tree that contains this file -> allow
		if is_inside_current_locked_tree(normalized_path) then
			return orig_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
		end

		-- Not inside a locked tree -> allow
		if not FolderLockCore.check_folder_lock(normalized_path) then
			return orig_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
		end

		-- Inside a locked tree -> prompt
		FolderLockGuard.prompt_unlock_or_block(file, function()
			orig_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
		end)
	end

	local orig_switchDocument = ReaderUI.switchDocument
	-- Patch switchDocument in ReaderUI
	ReaderUI.switchDocument = function(self, new_file, seamless, after_open_callback)
		if not new_file then
			return
		end

		-- Token is set (list source) -- peek so showReader can consume it
		if FolderLockGuard.peek_once(new_file) then
			return orig_switchDocument(self, new_file, seamless, after_open_callback)
		end

		-- Re-opening the current document -> skip
		local function is_current()
			return self.document
				and self.document.file
				and FolderLockCore.normalize_path(self.document.file) == FolderLockCore.normalize_path(new_file)
		end

		if is_current() then
			return orig_switchDocument(self, new_file, seamless, after_open_callback)
		end

		-- Already browsing inside the locked tree that contains this file -> allow
		if is_inside_current_locked_tree(new_file) then
			return orig_switchDocument(self, new_file, seamless, after_open_callback)
		end

		-- Not inside a locked tree -> allow
		if not FolderLockCore.check_folder_lock(new_file) then
			return orig_switchDocument(self, new_file, seamless, after_open_callback)
		end

		-- Inside a locked tree -> prompt, then set token for showReader to consume
		FolderLockGuard.prompt_unlock_or_block(new_file, function()
			FolderLockGuard.with_unlock_token(new_file, function()
				orig_switchDocument(self, new_file, seamless, after_open_callback)
			end)
		end)
	end

	_readerui_showReader_patch_wrapper = ReaderUI.showReader
	_readerui_switchDocument_patch_wrapper = ReaderUI.switchDocument
end

--- Install all file-open interception patches (call from plugin init).
function FolderLockGuard.install()
	FolderLockGuard.install_ensure_filechooser_patch()
	FolderLockGuard.install_list_source_patches()
	FolderLockGuard.install_readerui_patches()
end

return FolderLockGuard
