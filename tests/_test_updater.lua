local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

package.path = "./folderlock.koplugin/?.lua;" .. package.path

local function load_updater(version)
	package.loaded["util/folderlock_version"] = { VERSION = version }

	-- Minimal stubs so the updater module can load outside KOReader.
	package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }
	package.loaded["device"] = { unpackArchive = function() return true end }
	package.loaded["ffi/util"] = { purgeDir = function() end, realpath = function(p) return p end }
	package.loaded["util"] = { makePath = function() end, splitFilePathName = function(f) return "", f end }
	package.loaded["gettext"] = function(s) return s end
	package.loaded["ui/network/manager"] = { isConnected = function() return true end }
	package.loaded["ui/uimanager"] = { show = function() end, close = function() end }
	package.loaded["ui/widget/confirmbox"] = {}
	package.loaded["ui/trapper"] = { wrap = function(fn) fn() end }
	package.loaded["ui/widget/infomessage"] = {}
	package.loaded["socket.http"] = { request = function() return 1, 200, {} end }
	package.loaded["ltn12"] = {
		sink = {
			table = function(t)
				return function(c)
					if c then
						t[#t + 1] = c
					end
				end
			end,
			file = function(h)
				return function(c)
					if c then
						h:write(c)
					end
				end
			end,
		},
	}
	package.loaded["socket"] = {
		skip = function(n, ...)
			local a = table.pack(...)
			return table.unpack(a, n + 1, a.n)
		end,
	}
	package.loaded["socketutil"] = {
		set_timeout = function() end,
		reset_timeout = function() end,
		LARGE_BLOCK_TIMEOUT = 10,
		LARGE_TOTAL_TIMEOUT = 60,
		FILE_BLOCK_TIMEOUT = 30,
		FILE_TOTAL_TIMEOUT = 120,
	}
	package.loaded["json"] = { decode = function() return {} end }
	package.loaded["ffi/sha2"] = { sha256 = function() return ("h"):rep(64) end }

	package.loaded["util/folderlock_updater"] = nil
	return require("util/folderlock_updater")
end

t.test("version and default release URL", function()
	local u = load_updater("1.2.3")
	eq(u.get_current_version(), "1.2.3")
	eq(u.get_latest_release_url(), "https://api.github.com/repos/William9923/folderlock.koplugin/releases/latest")
end)

t.test("URL override round-trips", function()
	local u = load_updater("dev")
	local default = u.get_latest_release_url()
	u.set_latest_release_url("http://127.0.0.1:18080/latest.json")
	eq(u.get_latest_release_url(), "http://127.0.0.1:18080/latest.json")
	u.set_latest_release_url(nil)
	eq(u.get_latest_release_url(), default)
end)

t.test("compare_versions: equal", function()
	local u = load_updater("1.0.0")
	eq(u.compare_versions("1.0.0", "1.0.0"), 0)
	eq(u.compare_versions("v1.0.0", "1.0.0"), 0)
	eq(u.compare_versions("1.0.0-alpha", "1.0.0"), 0)
end)

t.test("compare_versions: higher and lower", function()
	local u = load_updater("1.0.0")
	eq(u.compare_versions("2.0.0", "1.0.0"), 1)
	eq(u.compare_versions("1.0.0", "2.0.0"), -1)
	eq(u.compare_versions("1.0.1", "1.0.0"), 1)
	eq(u.compare_versions("1.0.0.1", "1.0.0"), 1)
end)

t.done()
