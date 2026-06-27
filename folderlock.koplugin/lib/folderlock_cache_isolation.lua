--[[--
FolderLock cover cache isolation hooks.
@module koplugin.FolderLockCacheIsolation
--]]--

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

function FolderLockCacheIsolation.install()
    -- TODO: install context wrappers and hooks in subsequent steps.
end

return FolderLockCacheIsolation
