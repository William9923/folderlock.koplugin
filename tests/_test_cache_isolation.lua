local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local function load_isolation(mock_check)
    package.path = "./folderlock.koplugin/?.lua;" .. package.path

    package.loaded["lib/folderlock_core"] = {
        check_folder_lock = mock_check or function() return nil end,
    }
    package.loaded["lib/folderlock_cache_isolation"] = nil

    local iso = require("lib/folderlock_cache_isolation")
    return iso
end

t.test("is_inside matches child directories exactly", function()
    local iso = load_isolation()
    eq(iso.is_inside("/a/b/c", "/a/b"), true)
    eq(iso.is_inside("/a/b/c", "/a/b/c"), true)
    eq(iso.is_inside("/a/bc", "/a/b"), false)
    eq(iso.is_inside("/a", "/a/b"), false)
    eq(iso.is_inside(nil, "/a/b"), false) -- simulating non folder menu, such as History, Collection, etc...
    eq(iso.is_inside("/a/b", nil), false)
end)

t.test("is_hidden_path hides locked paths outside current context", function()
    local iso = load_isolation(function(filepath)
        if filepath:sub(1, #"/locked") == "/locked" then
            return "/locked"
        end
        return nil
    end)

    iso.set_current_path(nil)
    eq(iso.is_hidden_path("/locked/book.epub"), true)

    iso.set_current_path("/other")
    eq(iso.is_hidden_path("/locked/book.epub"), true)

    iso.set_current_path("/locked")
    eq(iso.is_hidden_path("/locked/book.epub"), false)

    iso.set_current_path("/locked/sub")
    eq(iso.is_hidden_path("/locked/book.epub"), false)

    iso.set_current_path(nil)
    eq(iso.is_hidden_path("/open/book.epub"), false)
end)

t.done()
