--[[--
Core logic for folder lock registry and path checks.
--]]

local FolderLockCore = {}

local _lock_registry = nil
local _registry_settings = nil

function FolderLockCore.djb2_hash(str)
    local bit = require("bit")
    local hash = 5381
    for i = 1, #str do
        local byte = str:byte(i)
        hash = bit.bxor(hash * 33 + byte, 0xFFFFFFFF)
    end
    return tostring(hash)
end

function FolderLockCore.normalize_path(path)
    local ffiUtil = require("ffi/util")
    if not path or path == "" then
        return nil
    end
    return ffiUtil.realpath(path) or path
end

local function _save_registry()
    if not _registry_settings then
        return
    end
    _registry_settings:saveSetting("locks", _lock_registry)
    _registry_settings:flush()
end

function FolderLockCore.load_registry()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local _registry_file = DataStorage:getSettingsDir() .. "/folderlock_registry.lua"
    _registry_settings = LuaSettings:open(_registry_file)
    _lock_registry = _registry_settings:readSetting("locks") or {}
    return _lock_registry
end

function FolderLockCore.get_lock_hash(path)
    if _lock_registry == nil then
        return nil
    end
    return _lock_registry[path]
end

function FolderLockCore.set_folder_lock(path, password)
    local normalized = FolderLockCore.normalize_path(path)
    if not normalized then
        return false
    end
    if _lock_registry == nil then
        FolderLockCore.load_registry()
    end
    _lock_registry[normalized] = FolderLockCore.djb2_hash(password)
    _save_registry()
    return true
end

function FolderLockCore.remove_folder_lock(path)
    local normalized = FolderLockCore.normalize_path(path)
    if not normalized then
        return false
    end
    if _lock_registry == nil then
        FolderLockCore.load_registry()
    end
    _lock_registry[normalized] = nil
    _save_registry()
    return true
end

function FolderLockCore.path_ancestors(path)
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

function FolderLockCore.check_folder_lock(path)
    if _lock_registry == nil then
        return nil
    end

    local normalized = FolderLockCore.normalize_path(path)
    if not normalized then
        return nil
    end

    local ancestors = FolderLockCore.path_ancestors(normalized)
    for _, ancestor_path in ipairs(ancestors) do
        if _lock_registry[ancestor_path] then
            return ancestor_path
        end
    end

    return nil
end

return FolderLockCore
