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

-- Path to the default cover image shown for locked files in mosaic/list view.
local _cover_path = nil

function FolderLockCacheIsolation.set_current_path(path)
	_current_browse_path = path
end

function FolderLockCacheIsolation.get_current_path()
	return _current_browse_path
end

function FolderLockCacheIsolation.set_cover_path(path)
	_cover_path = path
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
local function is_hidden_path(filepath, current_folder)
	local locked_path = FolderLockCore.check_folder_lock(filepath)
	if not locked_path then
		return false
	end

	local current = current_folder
	if current == nil then
		current = FolderLockCacheIsolation.get_current_path()
	end
	if current then
		return not is_inside(current, locked_path)
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

-- Hook Menu.getMenuText to hide filenames of locked files in classic mode.
local function install_menu_getmenutext_hook()
	local ok, Menu = pcall(require, "ui/widget/menu")
	if not ok or not Menu then
		return
	end
	if Menu._folderlock_getMenuText_hooked then
		return
	end
	Menu._folderlock_getMenuText_hooked = true

	local orig = Menu.getMenuText
	Menu.getMenuText = function(item)
		if item then
			local filepath = item.path or item.file
			if filepath and is_hidden_path(filepath) then
				local is_directory = not (item.is_file or item.file)
				if not is_directory then
					item.mandatory = nil
					return _("Locked")
				end
			end
		end
		return orig(item)
	end
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

-- Return an ImageWidget for the default locked cover, or nil if unavailable.
local function cover_or_locked(width, height, scale_factor)
	if not _cover_path then
		return nil
	end
	local ok, ImageWidget = pcall(require, "ui/widget/imagewidget")
	if not ok or not ImageWidget then
		return nil
	end
	return ImageWidget:new({
		file = _cover_path,
		width = width,
		height = height,
		scale_factor = scale_factor,
		alpha = true,
	})
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

	local border = Size.border.thin
	local frame_w = math.max(1, math.floor(dimen.w * 7 / 8))
	local frame_h = math.max(1, dimen.h)
	local inner_w = math.max(1, frame_w - 2 * border)
	local inner_h = math.max(1, frame_h - 2 * border)

	local content = cover_or_locked(inner_w, inner_h)
	if not content then
		local font_size = math.max(12, math.floor(dimen.h * 0.22))
		content = TextWidget:new({
			text = _("Locked"),
			face = Font:getFace("cfont", font_size),
		})
	end

	return CenterContainer:new({
		dimen = Geom:new({ w = dimen.w, h = dimen.h }),
		FrameContainer:new({
			width = frame_w,
			height = frame_h,
			margin = 0,
			padding = 0,
			bordersize = border,
			CenterContainer:new({
				dimen = Geom:new({ w = inner_w, h = inner_h }),
				content,
			}),
		}),
	})
end

-- placeholder locked file for listview
local function locked_file_placeholder_list(dimen, underline_h)
	local CenterContainer = require("ui/widget/container/centercontainer")
	local FrameContainer = require("ui/widget/container/framecontainer")
	local Geom = require("ui/geometry")
	local HorizontalGroup = require("ui/widget/horizontalgroup")
	local HorizontalSpan = require("ui/widget/horizontalspan")
	local LeftContainer = require("ui/widget/container/leftcontainer")
	local OverlapGroup = require("ui/widget/overlapgroup")
	local TextWidget = require("ui/widget/textwidget")
	local Font = require("ui/font")
	local Size = require("ui/size")
	local VerticalGroup = require("ui/widget/verticalgroup")
	local VerticalSpan = require("ui/widget/verticalspan")
	local Screen = require("device").screen
	local _ = require("gettext")

	underline_h = underline_h or 1
	local body_h = dimen.h - 2 * underline_h
	if body_h < 1 then
		body_h = dimen.h
	end

	local border_size = Size.border.thin
	local cover_size = math.max(1, body_h - 2 * border_size)
	local cover = cover_or_locked(cover_size, cover_size, 0)
	if not cover then
		local font_size = math.max(12, math.floor(body_h * 0.35))
		local content = TextWidget:new({
			text = _("Locked"),
			face = Font:getFace("cfont", font_size),
		})
		return VerticalGroup:new({
			VerticalSpan:new({ width = underline_h }),
			CenterContainer:new({
				dimen = Geom:new({ w = dimen.w, h = body_h }),
				content,
			}),
		})
	end

	local wleft = CenterContainer:new({
		dimen = Geom:new({ w = body_h, h = body_h }),
		FrameContainer:new({
			width = cover_size + 2 * border_size,
			height = cover_size + 2 * border_size,
			margin = 0,
			padding = 0,
			bordersize = border_size,
			CenterContainer:new({
				dimen = Geom:new({ w = cover_size, h = cover_size }),
				cover,
			}),
		}),
	})

	local title_font_size = math.max(12, math.floor(body_h * 0.35))
	local wtitle = TextWidget:new({
		text = _("Locked"),
		face = Font:getFace("cfont", title_font_size),
	})

	local pad = Screen:scaleBySize(5)
	local wmain = HorizontalGroup:new({
		HorizontalSpan:new({ width = body_h + pad }),
		LeftContainer:new({
			dimen = Geom:new({ w = math.max(1, dimen.w - body_h - pad), h = body_h }),
			wtitle,
		}),
	})

	return VerticalGroup:new({
		VerticalSpan:new({ width = underline_h }),
		OverlapGroup:new({
			dimen = Geom:new({ w = dimen.w, h = body_h }),
			wleft,
			wmain,
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
	install_menu_getmenutext_hook()
end

return FolderLockCacheIsolation
