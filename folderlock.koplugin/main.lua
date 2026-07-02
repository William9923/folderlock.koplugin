--[[--
Plugin that protect folders in KOReader with passwords via a lock registry saved in settings.
@module koplugin.FolderLock
--]]
--
--
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local LuaSettings = require("luasettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local FileManagerUtil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")

local FolderLockUpdater = require("util/folderlock_updater")
local FolderLockHasher = require("util/folderlock_hasher")

local _is_filechooser_patched = false
local _is_filemanagerutil_patched = false
local _registry_name = "locks"

local _defaultOnDenied = function()
	UIManager:show(InfoMessage:new({
		text = _("Access Denied"),
		timeout = 2,
	}))
end

local FolderLock = WidgetContainer:extend({
	name = "folderlock",
	is_doc_only = false,
	settings_file = DataStorage:getSettingsDir() .. "/folderlock_registry.lua",
	settings = nil,
	registry = nil,
})

function FolderLock:init()
	self.hasher = FolderLockHasher
	self.loadLocksRegistry(self)

	self.ui.menu:registerToMainMenu(self)
	self.patchFileChooser(self)
	self.patchFileManagerUtil(self)

	self.registerFileDialogMenu(self)
end

-- Core logic
function FolderLock:loadLocksRegistry()
	self.settings = LuaSettings:open(self.settings_file)
	self.registry = self.settings:readSetting(_registry_name) or {}
end

function FolderLock:saveLocksRegistry()
	self.settings:saveSetting(_registry_name, self.registry)
	self.settings:flush()
end

-- Generate path ancestor given real path, sorted from the deepest path
-- Input: normalized absolute path that start with root ("/") and not ending in last folder name without additional "/" suffix
--
-- Example:
--  - /a/b/c: {"/a/b/c", "/a/b", "/a", "/"}
--  - /a/b: {"/a/b", "/a", "/"}
local function generatePathAncestors(path)
	local ancestors = {}
	if not path or path == "" then
		return ancestors
	end

	while path ~= "/" and path ~= "" do
		table.insert(ancestors, path)
		local parent = path:match("^(.*)/[^/]+$")
		if parent == path or not parent then
			break
		end
		path = parent
	end

	if path == "/" or (#ancestors > 0 and ancestors[#ancestors] ~= "/") then
		table.insert(ancestors, "/")
	end

	return ancestors
end

-- Check if a lock exist in the folder for a path (file or folder)
-- Return the deepest locked folder absolute path
function FolderLock:checkFolderLock(path)
	local normalized = self.hasher.normalize(path)
	if not normalized then
		return nil
	end

	local ancestors = generatePathAncestors(normalized)
	for _, ancestor_path in ipairs(ancestors) do
		if self.registry[ancestor_path] then
			return ancestor_path
		end
	end

	return nil
end

-- Check if `current` path is inside (or equal to) `parent` locked folder
function FolderLock:isPathInside(current, parent)
	if not current or not parent then
		return false
	end
	-- add trailing slash to avoid false match on /a vs /abc
	local p = parent:match("/$") and parent or parent .. "/"
	local c = current:match("/$") and current or current .. "/"
	return c:sub(1, #p) == p
end

-- Retrieve key for unlocking the locked folder
function FolderLock:retrieveLockedFolderKey(locked_folder_path)
	return self.registry[locked_folder_path]
end

--- If `path` is inside a locked tree, show a password dialog.
--- On correct password (or if already unlocked) call `on_allowed`.
--- On Cancel call `on_denied`.
function FolderLock:promptUnlockOrBlock(locked_path, on_allowed, on_denied)
	assert(on_allowed ~= nil, "on_allowed callback must exist")
	assert(on_denied ~= nil, "on_denied callback must exist")

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
						on_denied()
					end,
				},
				{
					text = _("Enter"),
					is_enter_default = true,
					callback = function()
						local input = dialog:getInputText()
						local hash = self.hasher.hash(input)
						local stored = self:retrieveLockedFolderKey(locked_path)
						if not stored then
							-- NOTE: no stored hash (shouldn't happen), allow through
							UIManager:close(dialog)
							on_allowed()
							return
						end

						if hash == stored then
							UIManager:close(dialog)
							on_allowed()
							return
						end

						-- TODO: implement max attempt
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

function FolderLock:removeLock(path)
	return self:setLock(path, nil)
end
function FolderLock:addLock(path, raw_pwd)
	return self:setLock(path, self.hasher.hash(raw_pwd))
end

function FolderLock:setLock(path, pwd)
	local normalized = self.hasher.normalize(path)
	if not normalized then
		return false
	end
	if self.registry == nil then
		self:loadLocksRegistry()
	end

	self.registry[normalized] = pwd
	self:saveLocksRegistry()
	return true
end

-- Patching FileChooser.changeToPath
function FolderLock:patchFileChooser()
	if _is_filechooser_patched then
		return
	end

	do
		local orig_changeToPath = FileChooser.changeToPath

		FileChooser.changeToPath = function(self_fc, path, focused_path)

			local real_path = self.hasher.normalize(path)
			local locked_path = self:checkFolderLock(real_path)

			if locked_path ~= nil then
				self:promptUnlockOrBlock(path, function()
					orig_changeToPath(self_fc, path, focused_path)
				end, _defaultOnDenied)
			else
				orig_changeToPath(self_fc, path, focused_path)
			end
		end

		_is_filechooser_patched = true
	end
end

-- Patching FileManagerUtil:openFile
function FolderLock:patchFileManagerUtil()
	if _is_filemanagerutil_patched then
		return
	end

	do
		local orig_openFile = FileManagerUtil.openFile

		FileManagerUtil.openFile = function(ui, file, caller_pre_callback, no_dialog)
			local path, filename = util.splitFilePathName(file)
			local real_path = self.hasher.normalize(path)
			local locked_path = self:checkFolderLock(real_path)

			-- only prompt if approaching the locked folder from outside
			if locked_path ~= nil and not self:isPathInside(ui.file_chooser.path, locked_path) then
				self:promptUnlockOrBlock(path, function()
					orig_openFile(ui, file, caller_pre_callback, no_dialog)
				end, _defaultOnDenied)
			else
				orig_openFile(ui, file, caller_pre_callback, no_dialog)
			end
		end

		_is_filemanagerutil_patched = true
	end
end

-- MENU related
function FolderLock:getSubMenuItems()
	return {
		{
			text = _("About"),
			callback = function()
				UIManager:show(InfoMessage:new({
					text = _("Protect folders in KOReader with passwords"),
				}))
			end,
		},
		-- TODO: setup menu
		-- 1. setting up master password
		-- 2. opening menu for managing all folder locks

		-- Version submenu
		table.unpack(FolderLockUpdater.addSubMenu()),
	}
end

-- Lock Management logic
function FolderLock:promptLockFolderDialog(path, on_success)
	assert(on_success ~= nil, "on_success callback must exist")

	local pw_dialog
	pw_dialog = InputDialog:new({
		title = _("Lock folder"),
		description = path,
		text_type = "password",
		input_hint = _("Enter password"),
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(pw_dialog)
					end,
				},
				{
					text = _("Next"),
					is_enter_default = true,
					callback = function()
						local pw1 = pw_dialog:getInputText()
						if pw1 == "" then
							UIManager:show(InfoMessage:new({
								text = _("Password cannot be empty"),
								timeout = 2,
							}))
							return
						end
						UIManager:close(pw_dialog)

						local confirm_dialog
						confirm_dialog = InputDialog:new({
							title = _("Confirm password"),
							text_type = "password",
							input_hint = _("Re-enter password"),
							buttons = {
								{
									{
										text = _("Cancel"),
										id = "close",
										callback = function()
											UIManager:close(confirm_dialog)
										end,
									},
									{
										text = _("Lock"),
										is_enter_default = true,
										callback = function()
											local pw2 = confirm_dialog:getInputText()
											if pw1 ~= pw2 then
												UIManager:show(InfoMessage:new({
													text = _("Password does not match"),
													timeout = 2,
												}))
												UIManager:close(confirm_dialog)
												return
											end
											UIManager:close(confirm_dialog)
											local ok = self:addLock(path, pw1)
											if not ok then
												UIManager:show(InfoMessage:new({
													text = _("Failed to lock folder"),
													timeout = 2,
												}))
												return
											end

											on_success()

											UIManager:show(InfoMessage:new({
												text = _("Folder locked"),
												timeout = 2,
											}))
										end,
									},
								},
							},
						})
						UIManager:show(confirm_dialog)
						confirm_dialog:onShowKeyboard()
					end,
				},
			},
		},
	})
	UIManager:show(pw_dialog)
	pw_dialog:onShowKeyboard()
end

function FolderLock:promptUnlockFolderDialog(path, on_success)
	assert(on_success ~= nil, "on_success callback must exist")

	local unlock_dialog
	unlock_dialog = InputDialog:new({
		title = _("Unlock folder"),
		description = path,
		text_type = "password",
		input_hint = _("Enter current password"),
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(unlock_dialog)
					end,
				},
				{
					text = _("Unlock"),
					is_enter_default = true,
					callback = function()
						local input = unlock_dialog:getInputText()
						local hash = self.hasher.hash(input)
						local stored = self:retrieveLockedFolderKey(path)
						if hash ~= stored then
							-- TODO: implement max attempt
							UIManager:show(InfoMessage:new({
								text = _("Incorrect password"),
								timeout = 2,
							}))
							return
						end
						UIManager:close(unlock_dialog)
						local ok = self:removeLock(path)
						if not ok then
							UIManager:show(InfoMessage:new({
								text = _("Failed to remove lock"),
								timeout = 2,
							}))
							return
						end
						on_success()
						UIManager:show(InfoMessage:new({
							text = _("Folder lock removed"),
							timeout = 2,
						}))
					end,
				},
			},
		},
	})
	UIManager:show(unlock_dialog)
	unlock_dialog:onShowKeyboard()
end

function FolderLock:registerFileDialogMenu()
	FileManager.addFileDialogButtons(self.ui, "folderlock", function(file, is_file)
		local is_directory = lfs.attributes(file, "mode") == "directory"
		if is_file or not is_directory then
			return nil
		end

		local normalizedPath = self.hasher.normalize(file)
		if self.registry == nil then
			return
		end

		if self.registry[normalizedPath] then
			return {
				{
					text = _("Remove Lock"),
					callback = function()
						self:promptUnlockFolderDialog(normalizedPath, function()
							UIManager:close(self.ui.file_chooser.file_dialog)
							self.ui.file_chooser:refreshPath()
						end)
					end,
				},
			}
		else
			return {
				{
					text = _("Lock folder"),
					callback = function()
						self:promptLockFolderDialog(normalizedPath, function()
							UIManager:close(self.ui.file_chooser.file_dialog)
							self.ui.file_chooser:refreshPath()
						end)
					end,
				},
			}
		end
	end)
end

function FolderLock:addToMainMenu(menu_items)
	menu_items.folder_lock = {
		text = _("Folder Lock"),
		-- in which menu this should be appended
		sorting_hint = "more_tools",
		-- what submenu to show
		sub_item_table_func = function()
			return self:getSubMenuItems()
		end,
	}
end

return FolderLock
