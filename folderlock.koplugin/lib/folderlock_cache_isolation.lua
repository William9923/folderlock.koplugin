--[[--
FolderLock cover cache isolation hooks.
@module koplugin.FolderLockCacheIsolation
--]]
--

local FolderLockCore = require("lib/folderlock_core")

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

local function install_context_wrappers()
	install_covermenu_wrapper()
	install_view_wrappers()
end

function FolderLockCacheIsolation.install()
	install_context_wrappers()
	-- TODO: install BookInfoManager and BookList hooks in subsequent steps.
end

return FolderLockCacheIsolation
