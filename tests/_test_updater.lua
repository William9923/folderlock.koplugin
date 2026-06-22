local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local dkjson = require("dkjson")

-- Stub the KOReader modules that folderlock_updater.lua depends on.
-- Returns a restore function that undoes the stubs.
local function stub_updater_deps(deps)
	local saved = {}
	for name, stub in pairs(deps) do
		saved[name] = package.loaded[name]
		package.loaded[name] = stub
	end
	return function()
		for name, saved_mod in pairs(saved) do
			if saved_mod == nil then
				package.loaded[name] = nil
			else
				package.loaded[name] = saved_mod
			end
		end
	end
end

-- Build a valid GitHub /releases/latest response body.
local function make_release_body(tag, assets)
	return {
		tag_name = tag,
		html_url = "https://github.com/William9923/folderlock.koplugin/releases/tag/" .. tag,
		assets = assets
			or {
				{
					name = ("folderlock.koplugin-%s.zip"):format(tag:match("^v?(.+)$") or tag),
					browser_download_url = ("https://github.com/William9923/folderlock.koplugin/releases/download/%s/folderlock.koplugin-%s.zip"):format(
						tag,
						tag:match("^v?(.+)$") or tag
					),
				},
				{
					name = ("folderlock.koplugin-%s.zip.sha256"):format(tag:match("^v?(.+)$") or tag),
					browser_download_url = ("https://github.com/William9923/folderlock.koplugin/releases/download/%s/folderlock.koplugin-%s.zip.sha256"):format(
						tag,
						tag:match("^v?(.+)$") or tag
					),
				},
			},
	}
end

-- Helper: load updater with given version and deps stubs.
local function make_updater(version)
	package.path = "./folderlock.koplugin/?.lua;" .. package.path
	package.loaded["lib/folderlock_version"] = {
		VERSION = version,
	}
	package.loaded["lib/folderlock_updater"] = nil
	return require("lib/folderlock_updater")
end

-- Shared deps that most check() tests need (json, socket, ltn12, socketutil, logger)
local function shared_deps(request_fn)
	return {
		["ui/network/manager"] = {
			isConnected = function()
				return true
			end,
		},
		["socket.http"] = {
			request = request_fn,
		},
		["ltn12"] = {
			sink = {
				table = function(t)
					return function(chunk)
						if chunk then
							t[#t + 1] = chunk
						end
					end
				end,
			},
		},
		["socket"] = {
			skip = function(n, ...)
				local args = table.pack(...)
				return table.unpack(args, n + 1, args.n)
			end,
		},
		["socketutil"] = {
			set_timeout = function() end,
			reset_timeout = function() end,
			LARGE_BLOCK_TIMEOUT = 10,
			LARGE_TOTAL_TIMEOUT = 60,
		},
		["json"] = {
			decode = function(s)
				local ok, val = pcall(dkjson.decode, s)
				if ok then
					return val
				end
				return nil, val
			end,
		},
		["logger"] = { dbg = function() end, warn = function() end },
	}
end

local function sink_body(body)
	return function(req)
		local sink_fn = req.sink
		sink_fn(body)
		return 1, 200, {}
	end
end

-- ============================================================
-- Skeleton tests (still valid)
-- ============================================================

t.test("updater exposes version and default release URL", function()
	local updater = make_updater("1.2.3")

	eq(updater.get_current_version(), "1.2.3")
	eq(
		updater.get_latest_release_url(),
		"https://api.github.com/repos/William9923/folderlock.koplugin/releases/latest"
	)
end)

t.test("updater allows temporary latest-release URL override", function()
	local updater = make_updater("dev")

	updater.set_latest_release_url("http://127.0.0.1:18080/latest.json")
	eq(updater.get_latest_release_url(), "http://127.0.0.1:18080/latest.json")

	updater.set_latest_release_url(nil)
	eq(updater.get_latest_release_url(), updater.DEFAULT_LATEST_RELEASE_URL)
end)

-- ============================================================
-- check() tests
-- ============================================================

t.test("check returns error when offline", function()
	local restore = stub_updater_deps({
		["ui/network/manager"] = {
			isConnected = function()
				return false
			end,
		},
		["logger"] = { dbg = function() end, warn = function() end },
	})
	local updater = make_updater("1.0.0")

	local result, err = updater.check()
	eq(result, nil)
	eq(err, "Cannot check for updates while offline")

	restore()
end)

t.test("check returns available=false when local version matches latest", function()
	local body = dkjson.encode(make_release_body("1.0.0"))
	local restore = stub_updater_deps(shared_deps(sink_body(body)))
	local updater = make_updater("1.0.0")

	local result, err = updater.check()
	eq(err, nil)
	eq(result.available, false)
	eq(result.current_version, "1.0.0")
	eq(result.latest_version, "1.0.0")

	restore()
end)

t.test("check returns available=false when local version is newer than latest", function()
	local body = dkjson.encode(make_release_body("0.5.0"))
	local restore = stub_updater_deps(shared_deps(sink_body(body)))
	local updater = make_updater("1.0.0")

	local result, err = updater.check()
	eq(err, nil)
	eq(result.available, false)
	eq(result.current_version, "1.0.0")
	eq(result.latest_version, "0.5.0")

	restore()
end)

t.test("check returns available=true with URLs when update exists", function()
	local body = dkjson.encode(make_release_body("1.2.0"))
	local restore = stub_updater_deps(shared_deps(sink_body(body)))
	local updater = make_updater("1.0.0")

	local result, err = updater.check()
	eq(err, nil)
	eq(result.available, true)
	eq(result.current_version, "1.0.0")
	eq(result.latest_version, "1.2.0")
	eq(
		result.zip_url,
		"https://github.com/William9923/folderlock.koplugin/releases/download/1.2.0/folderlock.koplugin-1.2.0.zip"
	)
	eq(
		result.sha256_url,
		"https://github.com/William9923/folderlock.koplugin/releases/download/1.2.0/folderlock.koplugin-1.2.0.zip.sha256"
	)
	eq(result.release_url, "https://github.com/William9923/folderlock.koplugin/releases/tag/1.2.0")

	restore()
end)

t.test("check returns error when HTTP status is not 200", function()
	local restore = stub_updater_deps({
		["ui/network/manager"] = {
			isConnected = function()
				return true
			end,
		},
		["socket.http"] = {
			request = function(req)
				local sink_fn = req.sink
				sink_fn("")
				return 1, 404, "Not Found"
			end,
		},
		["ltn12"] = {
			sink = {
				table = function(tbl)
					return function(chunk)
						if chunk then
							tbl[#tbl + 1] = chunk
						end
					end
				end,
			},
		},
		["socket"] = {
			skip = function(n, ...)
				local args = table.pack(...)
				return table.unpack(args, n + 1, args.n)
			end,
		},
		["socketutil"] = {
			set_timeout = function() end,
			reset_timeout = function() end,
			LARGE_BLOCK_TIMEOUT = 10,
			LARGE_TOTAL_TIMEOUT = 60,
		},
		["json"] = {
			decode = function()
				return nil, "no content"
			end,
		},
		["logger"] = { dbg = function() end, warn = function() end },
	})
	local updater = make_updater("1.0.0")

	local result, err = updater.check()
	eq(result, nil)
	eq(err, "Failed to check for updates (HTTP 404)")

	restore()
end)

t.test("check returns error on rate limit (403)", function()
	local restore = stub_updater_deps(shared_deps(function(req)
		local sink_fn = req.sink
		sink_fn(dkjson.encode({ message = "API rate limit exceeded for 1.2.3.4" }))
		return 1, 403, "Forbidden"
	end))
	local updater = make_updater("1.0.0")

	local result, err = updater.check()
	eq(result, nil)
	eq(err:match("rate limit"), "rate limit")

	restore()
end)

t.test("check returns error when expected zip asset is missing", function()
	local release = {
		tag_name = "2.0.0",
		html_url = "https://github.com/...",
		assets = {
			{ name = "some-other-file.txt", browser_download_url = "https://example.com/some-other-file.txt" },
		},
	}
	local restore = stub_updater_deps(shared_deps(sink_body(dkjson.encode(release))))
	local updater = make_updater("1.0.0")

	local result, err = updater.check()
	eq(result, nil)
	eq(err, "Update 2.0.0 found but no matching zip asset")

	restore()
end)

t.test("check returns error on malformed JSON", function()
	local restore = stub_updater_deps({
		["ui/network/manager"] = {
			isConnected = function()
				return true
			end,
		},
		["socket.http"] = {
			request = function(req)
				local sink_fn = req.sink
				sink_fn("{broken json")
				return 1, 200, {}
			end,
		},
		["ltn12"] = {
			sink = {
				table = function(t)
					return function(chunk)
						if chunk then
							t[#t + 1] = chunk
						end
					end
				end,
			},
		},
		["socket"] = {
			skip = function(n, ...)
				local args = table.pack(...)
				return table.unpack(args, n + 1, args.n)
			end,
		},
		["socketutil"] = {
			set_timeout = function() end,
			reset_timeout = function() end,
			LARGE_BLOCK_TIMEOUT = 10,
			LARGE_TOTAL_TIMEOUT = 60,
		},
		["json"] = {
			-- Force decode failure
			decode = function()
				return nil, "parse error"
			end,
		},
		["logger"] = { dbg = function() end, warn = function() end },
	})
	local updater = make_updater("1.0.0")

	local result, err = updater.check()
	eq(result, nil)
	eq(err, "Failed to parse update response")

	restore()
end)

t.test("check handles 'v' prefix in tag_name", function()
	local release = {
		tag_name = "v0.2.0",
		html_url = "https://github.com/...",
		assets = {
			{
				name = "folderlock.koplugin-0.2.0.zip",
				browser_download_url = "https://example.com/folderlock.koplugin-0.2.0.zip",
			},
		},
	}
	local restore = stub_updater_deps(shared_deps(sink_body(dkjson.encode(release))))
	local updater = make_updater("0.1.0")

	local result, err = updater.check()
	eq(err, nil)
	eq(result.available, true)
	eq(result.latest_version, "0.2.0")
	eq(result.zip_url, "https://example.com/folderlock.koplugin-0.2.0.zip")

	restore()
end)

-- ============================================================
-- version comparison unit tests
-- ============================================================

t.test("compare_versions: equal versions", function()
	local u = make_updater("1.0.0")
	eq(u.compare_versions("1.0.0", "1.0.0"), 0)
	eq(u.compare_versions("2.3.4", "2.3.4"), 0)
	eq(u.compare_versions("0.0.1", "0.0.1"), 0)
end)

t.test("compare_versions: higher version detected", function()
	local u = make_updater("1.0.0")
	eq(u.compare_versions("2.0.0", "1.0.0"), 1)
	eq(u.compare_versions("1.1.0", "1.0.0"), 1)
	eq(u.compare_versions("1.0.1", "1.0.0"), 1)
	eq(u.compare_versions("10.0.0", "9.9.9"), 1)
end)

t.test("compare_versions: lower version detected", function()
	local u = make_updater("1.0.0")
	eq(u.compare_versions("1.0.0", "2.0.0"), -1)
	eq(u.compare_versions("1.0.0", "1.1.0"), -1)
	eq(u.compare_versions("1.0.0", "1.0.1"), -1)
end)

t.test("compare_versions: strips leading 'v' prefix", function()
	local u = make_updater("1.0.0")
	eq(u.compare_versions("v1.0.0", "1.0.0"), 0)
	eq(u.compare_versions("v2.0.0", "v1.0.0"), 1)
	eq(u.compare_versions("1.0.0", "v2.0.0"), -1)
end)

t.test("compare_versions: ignores pre-release suffix", function()
	local u = make_updater("1.0.0")
	eq(u.compare_versions("1.0.0-alpha", "1.0.0"), 0)
	eq(u.compare_versions("1.0.0-rc1", "1.0.0"), 0)
end)

t.test("compare_versions: handles different segment lengths", function()
	local u = make_updater("1.0.0")
	eq(u.compare_versions("1.0", "1.0.0"), 0)
	eq(u.compare_versions("2.0", "1.0.0"), 1)
	eq(u.compare_versions("1.0.0", "2.0"), -1)
	eq(u.compare_versions("1.0.0.1", "1.0.0"), 1)
end)

t.test("install returns not-implemented", function()
	local updater = make_updater("dev")
	local result, err = updater.install("1.2.3")
	eq(result, nil)
	eq(err, "update install not implemented yet")
end)

t.test("recover_or_cleanup returns true", function()
	local updater = make_updater("dev")
	eq(updater.recover_or_cleanup(), true)
end)

t.done()
