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
	eq(updater.get_latest_release_url(), "https://api.github.com/repos/William9923/folderlock.koplugin/releases/latest")
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

-- ============================================================
-- install() tests
-- ============================================================

-- Save/restore globals so tests don't leak stubs
local function install_deps(download_ok, download_data, expected_hash)
	local saved = {
		os_tmpname = os.tmpname,
		os_remove = os.remove,
		io_open = io.open,
	}

	local tmp_idx = 0
	os.tmpname = function()
		tmp_idx = tmp_idx + 1
		return "/tmp/folderlock-install-test-" .. tmp_idx
	end
	os.remove = function() end

	-- Stub io.open: track files written so reads return the same content.
	-- Since ltn12.sink.file never explicitly closes, we save on each write call.
	local written_files = {}
	io.open = function(path, mode)
		if mode == "wb" then
			local data = ""
			return {
				write = function(_, chunk)
					if chunk then
						data = data .. chunk
						written_files[path] = data
					end
					return true
				end,
				close = function() end,
			}
		elseif mode == "r" then
			local data = written_files[path]
			-- If the file wasn't written yet, provide test data based on role
			if not data then
				-- The sha256 file: provide a checksum line
				if expected_hash then
					data = expected_hash .. "  folderlock.koplugin-test.zip\n"
				else
					data = download_data or "fake-zip-content"
				end
			end
			if not data then
				return nil, "no such file"
			end
			return {
				read = function(_, fmt)
					if fmt == "*all" or fmt == "*a" then
						local r = data
						data = ""
						return r
					elseif fmt == "*l" then
						local nl = data:find("\n")
						if nl then
							local r = data:sub(1, nl - 1)
							data = data:sub(nl + 1)
							return r
						end
						r = data
						data = ""
						return #r > 0 and r or nil
					end
					return nil
				end,
				close = function() end,
			}
		elseif mode == "rb" then
			-- Used by file_sha256: read the already-written zip content
			local data = written_files[path] or download_data or "fake-zip-content"
			return {
				read = function(_, fmt)
					if fmt == "*all" or fmt == "*a" then
						local r = data
						data = ""
						return r
					end
					return nil
				end,
				close = function() end,
			}
		end
		return nil, "unsupported mode: " .. tostring(mode)
	end

	-- Stub http.request for download
	local http_stub = {
		request = function(req)
			if not download_ok then
				return 1, 404, "Not Found"
			end
			local sink = req.sink
			local url = req.url or ""
			if url:match("%.sha256$") and expected_hash then
				-- Feed the checksum file content
				sink(expected_hash .. "  folderlock.koplugin-test.zip\n")
			else
				sink(download_data or "fake-zip-bytes")
			end
			return 1, 200, {}
		end,
	}

	local deps = {
		["ui/network/manager"] = {
			isConnected = function()
				return true
			end,
		},
		["socket.http"] = http_stub,
		["ltn12"] = {
			sink = {
				file = function(handle)
					return function(chunk)
						if chunk then
							handle:write(chunk)
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
			FILE_BLOCK_TIMEOUT = 30,
			FILE_TOTAL_TIMEOUT = 120,
		},
		["logger"] = { dbg = function() end, warn = function() end },
		["ffi/sha2"] = {
			sha256 = function(s)
				-- Return a predictable hash based on content
				if not download_data and not s then
					return "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
				end
				if s and s == "fake-zip-content" then
					return "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
				end
				return ("hash-of-%s"):format(tostring(s)):sub(1, 64)
			end,
		},
	}

	local restore = stub_updater_deps(deps)

	return function()
		restore()
		os.tmpname = saved.os_tmpname
		os.remove = saved.os_remove
		io.open = saved.io_open
	end
end

t.test("install fails with download error when HTTP fails", function()
	local cleanup = install_deps(false, nil)
	local updater = make_updater("dev")
	local result, err = updater.install("1.0.0", "http://example.com/test.zip", nil)
	eq(result, nil)
	eq(err, "Download failed (HTTP 404)")
	cleanup()
end)

t.test("install fails when checksum does not match", function()
	-- download_ok = true, download_data = the zip content, expected_hash is different
	local cleanup =
		install_deps(true, "real-zip-bytes", "0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff")
	local updater = make_updater("dev")
	local result, err = updater.install("1.0.0", "http://example.com/test.zip", "http://example.com/test.zip.sha256")
	eq(result, nil)
	eq(err:match("Checksum mismatch"), "Checksum mismatch")
	cleanup()
end)

-- Stub lfs.attributes globally (KOReader has it as a global).
-- In test environment it may not exist, so we create a shim.
if not lfs then
	_G.lfs = {
		attributes = function()
			return "directory"
		end,
	}
end
local _lfs_attr = lfs.attributes

local function install_deps_full(download_ok, download_data, expected_hash, fail_step)
	local cleanup1 = install_deps(download_ok, download_data, expected_hash)

	local saved_rename = os.rename

	lfs.attributes = function(path)
		if path:match("%.new$") or path:match("%.bak$") then
			return nil
		end
		return _lfs_attr(path)
	end

	os.rename = function(old, new)
		if fail_step == "bak" and old:match("%.bak$") then
			return nil, "rename failed (bak)"
		end
		if fail_step == "new" and old:match("%.new$") then
			return nil, "rename failed (new)"
		end
		return true
	end

	local deps = {
		["libs/libkoreader-lfs"] = { attributes = lfs.attributes },
		["device"] = {
			unpackArchive = function(_, _archive, _extract_to, _strip)
				if fail_step == "extract" then
					return nil, "extraction error"
				end
				return true
			end,
		},
		["ffi/util"] = {
			purgeDir = function() end,
		},
		["util"] = {
			makePath = function()
				return true
			end,
		},
		["logger"] = { dbg = function() end, warn = function() end },
	}

	local cleanup2 = stub_updater_deps(deps)

	return function()
		cleanup2()
		lfs.attributes = _lfs_attr
		os.rename = saved_rename
		cleanup1()
	end
end

t.test("install fails when no plugin_dir is set", function()
	local cleanup = install_deps(true, "some-data", nil)
	local updater = make_updater("dev")
	local result, err = updater.install("1.0.0", "http://example.com/test.zip", nil)
	eq(result, nil)
	eq(err, "Plugin directory not set")
	cleanup()
end)

t.test("install fails on extraction error", function()
	local cleanup = install_deps_full(true, "some-data", nil, "extract")
	local updater = make_updater("dev")
	updater.set_plugin_dir("/tmp/plugins/folderlock.koplugin")
	local result, err = updater.install("1.0.0", "http://example.com/test.zip", nil)
	eq(result, nil)
	eq(err:match("Extraction failed"), "Extraction failed")
	cleanup()
end)

t.test("install succeeds with checksum verification", function()
	local cleanup =
		install_deps_full(true, "fake-zip-content", "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
	local updater = make_updater("dev")
	updater.set_plugin_dir("/tmp/plugins/folderlock.koplugin")
	local result, err = updater.install("1.0.0", "http://example.com/test.zip", "http://example.com/test.zip.sha256")
	eq(err, nil)
	eq(result, true)
	cleanup()
end)

t.test("install succeeds without checksum", function()
	local cleanup = install_deps_full(true, "some-data", nil)
	local updater = make_updater("dev")
	updater.set_plugin_dir("/tmp/plugins/folderlock.koplugin")
	local result, err = updater.install("1.0.0", "http://example.com/test.zip", nil)
	eq(err, nil)
	eq(result, true)
	cleanup()
end)

t.test("install rolls back when .new→live rename fails", function()
	local cleanup = install_deps_full(true, "some-data", nil, "new")
	local updater = make_updater("dev")
	updater.set_plugin_dir("/tmp/plugins/folderlock.koplugin")
	local result, err = updater.install("1.0.0", "http://example.com/test.zip", nil)
	eq(result, nil)
	eq(err:match("Failed to install update"), "Failed to install update")
	cleanup()
end)

t.test("recover_or_cleanup removes stale .new", function()
	local saved_attr = lfs.attributes
	local purged = {}
	lfs.attributes = function(path)
		if path:match("%.new$") then
			return "directory"
		end
		if path:match("%.bak$") then
			return nil
		end
		return "directory"
	end

	local cleanup = stub_updater_deps({
		["libs/libkoreader-lfs"] = { attributes = lfs.attributes },
		["ffi/util"] = {
			purgeDir = function(p)
				table.insert(purged, p)
			end,
		},
		["logger"] = { dbg = function() end },
	})
	local updater = make_updater("dev")
	updater.set_plugin_dir("/tmp/plugins/folderlock.koplugin")
	local ok, err = updater.recover_or_cleanup()
	eq(ok, true)
	local found_new = false
	for _, p in ipairs(purged) do
		if p:match("%.new$") then
			found_new = true
		end
	end
	eq(found_new, true)

	lfs.attributes = saved_attr
	cleanup()
end)

t.test("recover_or_cleanup removes .bak when both live and .bak exist", function()
	local saved_attr = lfs.attributes
	local purged = {}
	lfs.attributes = function(path)
		if path:match("%.bak$") then
			return "directory"
		end
		if path:match("%.new$") then
			return nil
		end
		return "directory"
	end

	local cleanup = stub_updater_deps({
		["libs/libkoreader-lfs"] = { attributes = lfs.attributes },
		["ffi/util"] = {
			purgeDir = function(p)
				table.insert(purged, p)
			end,
		},
		["logger"] = { dbg = function() end },
	})
	local updater = make_updater("dev")
	updater.set_plugin_dir("/tmp/plugins/folderlock.koplugin")
	local ok, err = updater.recover_or_cleanup()
	eq(ok, true)
	local found_bak = false
	for _, p in ipairs(purged) do
		if p:match("%.bak$") then
			found_bak = true
		end
	end
	eq(found_bak, true)

	lfs.attributes = saved_attr
	cleanup()
end)

t.test("recover_or_cleanup restores .bak when live missing", function()
	local saved_attr = lfs.attributes
	local saved_rename = os.rename
	local renamed = {}
	lfs.attributes = function(path)
		if path:match("%.bak$") then
			return "directory"
		end
		if path:match("%.new$") then
			return nil
		end
		return nil
	end
	os.rename = function(old, new)
		table.insert(renamed, { old = old, new = new })
		return true
	end

	local cleanup = stub_updater_deps({
		["libs/libkoreader-lfs"] = { attributes = lfs.attributes },
		["ffi/util"] = { purgeDir = function() end },
		["logger"] = { dbg = function() end },
	})
	local updater = make_updater("dev")
	updater.set_plugin_dir("/tmp/plugins/folderlock.koplugin")
	local ok, err = updater.recover_or_cleanup()
	eq(ok, true)
	local found_restore = false
	for _, r in ipairs(renamed) do
		if r.old:match("%.bak$") and not r.new:match("%.bak$") then
			found_restore = true
		end
	end
	eq(found_restore, true)

	lfs.attributes = saved_attr
	os.rename = saved_rename
	cleanup()
end)

t.done()
