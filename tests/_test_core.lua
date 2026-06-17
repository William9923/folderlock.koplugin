local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

t.test("djb2_hash is deterministic and has known values", function()
    local core = helpers.load_core()
    eq(core.djb2_hash(""), "5381")
    eq(core.djb2_hash("test"), "2090570867")
    eq(core.djb2_hash("secret"), core.djb2_hash("secret"))
end)

t.test("normalize_path handles nil, empty, resolved and fallback", function()
    local core = helpers.load_core({
        realpath_map = {
            ["/books"] = "/mnt/books",
        },
    })

    eq(core.normalize_path(nil), nil)
    eq(core.normalize_path(""), nil)
    eq(core.normalize_path("/books"), "/mnt/books")
    eq(core.normalize_path("/unknown"), "/unknown")
end)

t.test("path_ancestors enumerates deepest to root", function()
    local core = helpers.load_core()
    eq(core.path_ancestors("/a/b/c"), { "/a/b/c", "/a/b", "/a", "/" })
    eq(core.path_ancestors("/"), { "/" })
    eq(core.path_ancestors(""), {})
end)

t.test("check_folder_lock returns nil before registry load", function()
    local core = helpers.load_core()
    eq(core.check_folder_lock("/a/b"), nil)
end)

t.test("check_folder_lock resolves direct and ancestor lock", function()
    local core = helpers.load_core({
        initial_locks = {
            ["/locked"] = "hash1",
            ["/parent"] = "hash2",
        },
    })

    core.load_registry()

    eq(core.check_folder_lock("/locked"), "/locked")
    eq(core.check_folder_lock("/parent/child"), "/parent")
    eq(core.check_folder_lock("/open"), nil)
end)

t.test("set_folder_lock and remove_folder_lock persist settings", function()
    local core, state = helpers.load_core({
        realpath_map = {
            ["/raw/path"] = "/real/path",
        },
    })

    core.load_registry()

    eq(core.set_folder_lock("/raw/path", "pw"), true)
    eq(core.get_lock_hash("/real/path"), core.djb2_hash("pw"))
    eq(state.save_calls, 1)
    eq(state.flush_calls, 1)

    eq(core.remove_folder_lock("/raw/path"), true)
    eq(core.get_lock_hash("/real/path"), nil)
    eq(state.save_calls, 2)
    eq(state.flush_calls, 2)
end)

t.test("load_registry reads from expected settings file", function()
    local core, state = helpers.load_core({
        settings_dir = "/tmp/ko-settings",
        initial_locks = {
            ["/seed"] = "seed-hash",
        },
    })

    core.load_registry()

    eq(state.opened_paths[1], "/tmp/ko-settings/folderlock_registry.lua")
    eq(core.get_lock_hash("/seed"), "seed-hash")
end)

t.done()
