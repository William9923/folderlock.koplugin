--[[--
FolderLock cover cache isolation hooks.
@module koplugin.FolderLockCacheIsolation
--]]
--

local _ = require("gettext")
local FolderLockCore = require("lib/folderlock_core")

-- logger may not be available in plain-Lua unit tests
local ok_logger, logger = pcall(require, "logger")
if not ok_logger or not logger then
	logger = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end

local FolderLockCacheIsolation = {}

-- Current browse directory of the view that is rendering items.
-- nil = no "inside locked folder" context → locked paths are hidden.
local _current_browse_path = nil

function FolderLockCacheIsolation.set_current_path(path)
	_current_browse_path = path
end

function FolderLockCacheIsolation.get_current_path()
	return _current_browse_path
end

-- Check whether child path is inside parent directory.
local function is_inside(child, parent)
	if not child or not parent then
		return false
	end
	if child == parent then
		return true
	end
	return child:sub(1, #parent + 1) == parent .. "/"
end

-- Determine if filepath's book info should be hidden right now.
local function is_hidden_path(filepath)
	local locked_path = FolderLockCore.check_folder_lock(filepath)
	if not locked_path then
		return false
	end
	local current = FolderLockCacheIsolation.get_current_path()
	if current and is_inside(current, locked_path) then
		return false
	end
	return true
end

FolderLockCacheIsolation.is_inside = is_inside
FolderLockCacheIsolation.is_hidden_path = is_hidden_path

-- Run fn with the current browse path set, always clearing it afterwards.
-- NOTES: Use pcall so the path is reset even if fn errors.
function FolderLockCacheIsolation.with_context(path, fn, ...)
	FolderLockCacheIsolation.set_current_path(path)
	local ok, ret = pcall(fn, ...)
	FolderLockCacheIsolation.set_current_path(nil)
	if not ok then
		error(ret)
	end
	return ret
end

local function wrap_method(module, method_name, context_fn)
	local orig = module[method_name]
	if type(orig) ~= "function" then
		return
	end
	module[method_name] = function(self, ...)
		return FolderLockCacheIsolation.with_context(context_fn(self), orig, self, ...)
	end
end

local function install_covermenu_wrapper()
	local ok, CoverMenu = pcall(require, "covermenu")
	if not ok or not CoverMenu then
		return
	end
	wrap_method(CoverMenu, "updateItems", function(self)
		return self.path
	end)
end

local function install_filechooser_wrapper()
	local ok, FileChooser = pcall(require, "ui/widget/filechooser")
	if not ok or not FileChooser then
		return
	end
	wrap_method(FileChooser, "updateItems", function(self)
		return self.path
	end)
end

local function wrap_view_close_callback(view, widget_field)
	local widget = view[widget_field]
	if not widget then
		return
	end
	local cb = widget.close_callback
	if type(cb) ~= "function" then
		return
	end
	widget.close_callback = function(...)
		FolderLockCacheIsolation.set_current_path(nil)
		return cb(...)
	end
end

local function install_view_wrappers()
	local views = {
		{ "apps/filemanager/filemanagerhistory", "onShowHist", "booklist_menu" },
		{ "apps/filemanager/filemanagercollection", "onShowColl", "booklist_menu" },
		{ "apps/filemanager/filemanagerfilesearcher", "onShowSearchResults", "booklist_menu" },
	}

	for _, spec in ipairs(views) do
		local ok, mod = pcall(require, spec[1])
		if ok and mod then
			local method_name = spec[2]
			local widget_field = spec[3]
			local orig = mod[method_name]
			if type(orig) == "function" then
				mod[method_name] = function(self, ...)
					FolderLockCacheIsolation.set_current_path(nil)
					local fnOk, ret = pcall(orig, self, ...)
					if fnOk then
						wrap_view_close_callback(self, widget_field)
					end
					FolderLockCacheIsolation.set_current_path(nil)
					if not fnOk then
						error(ret)
					end
					return ret
				end
			end
		end
	end
end

local function install_bookinfo_hook()
	local ok, BookInfoManager = pcall(require, "bookinfomanager")
	if not ok or not BookInfoManager then
		return
	end
	if BookInfoManager._folderlock_getBookInfo_hooked then
		return
	end
	BookInfoManager._folderlock_getBookInfo_hooked = true

	local orig = BookInfoManager.getBookInfo
	BookInfoManager.getBookInfo = function(self, filepath, get_cover)
		if filepath and is_hidden_path(filepath) then
			return nil -- TODO: should we return dummy information instead ??
		end
		return orig(self, filepath, get_cover)
	end
end

local function install_docprops_hook()
	local ok, BookInfoManager = pcall(require, "bookinfomanager")
	if not ok or not BookInfoManager then
		return
	end
	if BookInfoManager._folderlock_getDocProps_hooked then
		return
	end
	BookInfoManager._folderlock_getDocProps_hooked = true

	local orig = BookInfoManager.getDocProps
	BookInfoManager.getDocProps = function(self, filepath)
		if filepath and is_hidden_path(filepath) then
			return nil -- TODO: should we return dummy information instead ??
		end
		return orig(self, filepath)
	end
end

local function install_booklist_hook()
	local ok, BookList = pcall(require, "ui/widget/booklist")
	if not ok or not BookList then
		return
	end
	if BookList._folderlock_getBookInfo_hooked then
		return
	end
	BookList._folderlock_getBookInfo_hooked = true

	local orig = BookList.getBookInfo
	BookList.getBookInfo = function(file)
		if file and is_hidden_path(file) then
			return { been_opened = false }
		end
		return orig(file)
	end
end

-- Sanitize a filename-only list item so locked files display as "Locked".
local function sanitize_list_item(item, filepath_field)
	local filepath = item and item[filepath_field]
	if not filepath then
		return
	end
	local locked_path = FolderLockCore.check_folder_lock(filepath)
	if not locked_path then
		return
	end

	-- When viewing inside the locked folder, don't hide.
	local current = FolderLockCacheIsolation.get_current_path()
	if current and is_inside(current, locked_path) then
		return
	end

	item.text = _("Locked")
	item.bidi_wrap_func = nil
	item.bold = nil
	item.opened = nil
	item.mandatory = nil
	item.mandatory_func = nil
	item.doc_props = nil
end

local function install_hasbeenopened_hook()
	local ok, BookList = pcall(require, "ui/widget/booklist")
	if not ok or not BookList then
		return
	end
	if BookList._folderlock_hasBookBeenOpened_hooked then
		return
	end
	BookList._folderlock_hasBookBeenOpened_hooked = true

	local orig = BookList.hasBookBeenOpened
	BookList.hasBookBeenOpened = function(file)
		if file and is_hidden_path(file) then
			return false
		end
		return orig(file)
	end
end

-- placeholder locked file for mosaic view
local function locked_file_placeholder_mosaic(dimen)
	local CenterContainer = require("ui/widget/container/centercontainer")
	local FrameContainer = require("ui/widget/container/framecontainer")
	local Geom = require("ui/geometry")
	local TextWidget = require("ui/widget/textwidget")
	local Font = require("ui/font")
	local Size = require("ui/size")
	local _ = require("gettext")

	local font_size = math.max(12, math.floor(dimen.h * 0.22))
	local border = Size.border.thin
	local frame_w = math.max(1, math.floor(dimen.w * 7 / 8))
	local frame_h = math.max(1, dimen.h)

	return CenterContainer:new({
		dimen = Geom:new({ w = dimen.w, h = dimen.h }),
		FrameContainer:new({
			width = frame_w,
			height = frame_h,
			margin = 0,
			padding = 0,
			bordersize = border,
			CenterContainer:new({
				dimen = Geom:new({ w = math.max(1, frame_w - 2 * border), h = math.max(1, frame_h - 2 * border) }),
				TextWidget:new({
					text = _("Locked"),
					face = Font:getFace("cfont", font_size),
				}),
			}),
		}),
	})
end

-- placeholder locked file for listview
local function locked_file_placeholder_list(dimen, underline_h)
	local CenterContainer = require("ui/widget/container/centercontainer")
	local Geom = require("ui/geometry")
	local TextWidget = require("ui/widget/textwidget")
	local Font = require("ui/font")
	local VerticalGroup = require("ui/widget/verticalgroup")
	local VerticalSpan = require("ui/widget/verticalspan")
	local _ = require("gettext")

	underline_h = underline_h or 1
	local body_h = dimen.h - 2 * underline_h
	if body_h < 1 then
		body_h = dimen.h
	end
	local font_size = math.max(12, math.floor(body_h * 0.35))

	return VerticalGroup:new({
		VerticalSpan:new({ width = underline_h }),
		CenterContainer:new({
			dimen = Geom:new({ w = dimen.w, h = body_h }),
			TextWidget:new({
				text = _("Locked"),
				face = Font:getFace("cfont", font_size),
			}),
		}),
	})
end

local function locked_file_placeholder(class_name, dimen, underline_h)
	if class_name == "ListMenuItem" then
		return locked_file_placeholder_list(dimen, underline_h)
	end
	return locked_file_placeholder_mosaic(dimen)
end

local function is_menu_entry_locked(item)
	local filepath = item.filepath or (item.entry and (item.entry.file or item.entry.path))
	if not filepath then
		return false
	end
	return is_hidden_path(filepath)
end

local function wrap_menuitem_update(MenuItemClass, class_name)
	local orig = MenuItemClass.update
	if type(orig) ~= "function" then
		return
	end
	MenuItemClass.update = function(self)
		local is_directory = not (self.entry.is_file or self.entry.file)
		local is_locked = is_menu_entry_locked(self)

		if is_locked and is_directory then
			self.mandatory = nil
		end

		orig(self)

		if is_locked and not is_directory then
			local container = self._underline_container
			if container and container[1] then
				container[1]:free()
			end
			container[1] = locked_file_placeholder(class_name, container.dimen, self.underline_h)
			self.bookinfo_found = true -- prevent re-schedule extract book info
			self.cover_specs = nil
			self.has_description = false
		end
	end
end

local function get_local_class(module_name, func_name, class_name)
	local ok_up, userpatch = pcall(require, "userpatch")
	if not ok_up or not userpatch then
		return nil
	end
	local ok, mod = pcall(require, module_name)
	if not ok or not mod then
		return nil
	end
	local func = mod[func_name]
	if type(func) ~= "function" then
		return nil
	end
	return userpatch.getUpValue(func, class_name)
end

local function install_menuitem_hooks()
	local MosaicMenuItem = get_local_class("mosaicmenu", "_updateItemsBuildUI", "MosaicMenuItem")
	if MosaicMenuItem then
		wrap_menuitem_update(MosaicMenuItem, "MosaicMenuItem")
	end

	local ListMenuItem = get_local_class("listmenu", "_updateItemsBuildUI", "ListMenuItem")
	if ListMenuItem then
		wrap_menuitem_update(ListMenuItem, "ListMenuItem")
	end
end

local function install_context_wrappers()
	install_covermenu_wrapper()
	install_filechooser_wrapper()
	install_view_wrappers()
end

function FolderLockCacheIsolation.install()
	install_context_wrappers()
	install_bookinfo_hook()
	install_docprops_hook()
	install_booklist_hook()
	install_hasbeenopened_hook()
	install_menuitem_hooks()
  -- TODO: classic filename only patch
end

return FolderLockCacheIsolation
