local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local function load_updater(version)
    package.path = "./folderlock.koplugin/?.lua;" .. package.path
    package.loaded["lib/folderlock_updater"] = nil
    package.loaded["lib/folderlock_version"] = {
        VERSION = version,
    }
    return require("lib/folderlock_updater")
end

t.test("updater exposes version and default release URL", function()
    local updater = load_updater("1.2.3")

    eq(updater.get_current_version(), "1.2.3")
    eq(updater.get_latest_release_url(), "https://api.github.com/repos/William9923/folderlock.koplugin/releases/latest")
end)

t.test("updater allows temporary latest-release URL override", function()
    local updater = load_updater("dev")

    updater.set_latest_release_url("http://127.0.0.1:18080/latest.json")
    eq(updater.get_latest_release_url(), "http://127.0.0.1:18080/latest.json")

    updater.set_latest_release_url(nil)
    eq(updater.get_latest_release_url(), updater.DEFAULT_LATEST_RELEASE_URL)
end)

t.test("updater skeleton methods return explicit not-implemented status", function()
    local updater = load_updater("dev")

    local check_result, check_err = updater.check()
    eq(check_result, nil)
    eq(check_err, "update check not implemented yet")

    local install_result, install_err = updater.install("1.2.3")
    eq(install_result, nil)
    eq(install_err, "update install not implemented yet")

    eq(updater.recover_or_cleanup(), true)
end)

t.done()
