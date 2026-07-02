--[[--
Plugin that protect folders in KOReader with passwords via a lock registry saved in settings.
@module koplugin.FolderLock
--]]
--
--
local util = require("util")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local FileChooser = require("ui/widget/filechooser")
local FileManager = require("apps/filemanager/filemanager")
local FileManagerUtil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")

local FolderLockUpdater = require("lib/folderlock_updater")

local _is_filechooser_patched = false
local _is_filemanagerutil_patched = false

local FolderLock = WidgetContainer:extend({
	name = "folderlock",
	is_doc_only = false,
	settings_file = DataStorage:getSettingsDir() .. "/folderlock_registry.lua",
})

function FolderLock:init()
	self.ui.menu:registerToMainMenu(self)
	self.patchFileChooser(self)
	self.patchFileManagerUtil(self)

	self.registerFileDialogMenu(self)
end

-- Patching FileChooser.changeToPath
function FolderLock:patchFileChooser()
	if _is_filechooser_patched then
		return
	end

	do
		local orig_changeToPath = FileChooser.changeToPath

		FileChooser.changeToPath = function(self_fc, path, focused_path)
			print("[FOLDERLOCK] onPrePathChanged event", path, focused_path)
			orig_changeToPath(self_fc, path, focused_path)
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
			print("[FOLDERLOCK] onPreOpenFile event", path, filename)
			orig_openFile(ui, file, caller_pre_callback, no_dialog)
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

		-- Version submenu
		table.unpack(FolderLockUpdater.addSubMenu()),
	}
end

function FolderLock:registerFileDialogMenu()
	FileManager.addFileDialogButtons(self.ui, "folderlock", function(file, is_file)
		if is_file then
			return nil
		end

		return {
			{
				text = _("Lock folder"),
				callback = function()
					print("[FOLDERLOCK] Lock Folder event clicked")
				end,
			},
		}
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

-- TODO:
-- 1. Interaction is on Long Press folder only (to lock and unlock) -> unlock options should remain on the affected folder => DONE
-- 2. Lock should be applied simply on onPreOpenFile or onPreOpenFile events
-- OPTIONAL:
-- 3. Learn how does open next or previous documents work. And OpenLastDocument. it seems cannot be catched with our current patch
-- 4. Learn about module/menu in lua if possible. But if cannot then it's fine as it is. Reuse the versioning capabilities
