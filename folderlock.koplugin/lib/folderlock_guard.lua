--[[--
Shared password-dialog helper and single-use unlock token for file-open interception.
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local FileChooser = require("ui/widget/filechooser")
local FolderLockCore = require("lib/folderlock_core")
local FolderLockCacheIsolation = require("lib/folderlock_cache_isolation")
local _ = require("gettext")

local FolderLockGuard = {}

-- single-use unlock token table
local _allow_once = {}

--- Clear all tokens (testing / reset).
function FolderLockGuard._reset()
	_allow_once = {}
end

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
--- On Cancel call `on_denied` (if provided).
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

local _filechooser_patch_installed = false
local _orig_FileChooser_changeToPath = nil

function FolderLockGuard.install_ensure_filechooser_patch()
	if _filechooser_patch_installed then
		return
	end

	if type(FileChooser.changeToPath) ~= "function" then
		return
	end

	_orig_FileChooser_changeToPath = FileChooser.changeToPath

	FileChooser.changeToPath = function(self_fc, path, focused_path)
		local chooser_name = self_fc and self_fc.name or "nil"

		if chooser_name ~= "filemanager" then
			return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
		end

		local real_path = FolderLockCore.normalize_path(path)
		if not real_path then
			return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
		end

		-- Consume a pre-authorized unlock token (set by File Search folder result)
		if FolderLockGuard.consume_once(real_path) then
			return FolderLockCacheIsolation.with_context(real_path, function()
				return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
			end)
		end

		local locked_path = FolderLockCore.check_folder_lock(real_path)
		if not locked_path then
			return FolderLockCacheIsolation.with_context(real_path, function()
				return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
			end)
		end

		FolderLockGuard.prompt_unlock_or_block(real_path,
			function()
				FolderLockCacheIsolation.with_context(real_path, function()
					_orig_FileChooser_changeToPath(self_fc, path, focused_path)
				end)
			end,
			function()
				UIManager:show(InfoMessage:new{
					text = _("Access Denied"),
					timeout = 2,
				})
			end
		)
	end

	_filechooser_patch_installed = true
end

--- Install all file-open interception patches (call from plugin init).
function FolderLockGuard.install()
	FolderLockGuard.install_ensure_filechooser_patch()
end

return FolderLockGuard
