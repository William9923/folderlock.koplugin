local FolderLockVersion = require("lib/folderlock_version")

local REPO = "William9923/folderlock.koplugin"
local DEFAULT_LATEST_RELEASE_URL = "https://api.github.com/repos/" .. REPO .. "/releases/latest"
local USER_AGENT = "FolderLock/" .. (FolderLockVersion.VERSION or "dev")

local FolderLockUpdater = {
	REPO = REPO,
	DEFAULT_LATEST_RELEASE_URL = DEFAULT_LATEST_RELEASE_URL,
	_latest_release_url_override = nil,
}

function FolderLockUpdater.get_current_version()
	return FolderLockVersion.VERSION or "dev"
end

function FolderLockUpdater.set_plugin_dir(dir)
	FolderLockUpdater._plugin_dir = dir
end

function FolderLockUpdater.set_latest_release_url(url)
	FolderLockUpdater._latest_release_url_override = url
end

function FolderLockUpdater.get_latest_release_url()
	return FolderLockUpdater._latest_release_url_override or FolderLockUpdater.DEFAULT_LATEST_RELEASE_URL
end

-- Compare two semver-ish strings. Returns -1, 0, or 1.
-- Accepts "v" prefix, pre-release suffixes (ignored in comparison).
function FolderLockUpdater.compare_versions(a, b)
	if a == b then
		return 0
	end

	local function parse(s)
		local parts = {}
		-- Strip leading "v" if present
		s = s:match("^v?(.+)$") or s
		-- Strip pre-release suffix (e.g. "-alpha", "-rc1")
		s = s:match("^(.-)%-") or s
		for num in s:gmatch("%d+") do
			parts[#parts + 1] = tonumber(num)
		end
		return parts
	end

	local pa, pb = parse(a), parse(b)
	for i = 1, math.max(#pa, #pb) do
		local na, nb = pa[i] or 0, pb[i] or 0
		if na < nb then
			return -1
		end
		if na > nb then
			return 1
		end
	end
	return 0
end

-- Extract asset URL by matching asset name pattern.
local function find_asset(assets, name_pattern)
	for _, asset in ipairs(assets or {}) do
		if asset.name and asset.name:match(name_pattern) then
			return asset.browser_download_url
		end
	end
	return nil
end

function FolderLockUpdater.check()
	local NetworkMgr = require("ui/network/manager")
	if not NetworkMgr:isConnected() then
		return nil, "Cannot check for updates while offline"
	end

	local http = require("socket.http")
	local ltn12 = require("ltn12")
	local socket = require("socket")
	local socketutil = require("socketutil")
	local JSON = require("json")
	local logger = require("logger")

	local response_body = {}
	socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
	local code, _, status = socket.skip(
		1,
		http.request({
			url = FolderLockUpdater.get_latest_release_url(),
			method = "GET",
			headers = {
				["User-Agent"] = USER_AGENT,
				["Accept"] = "application/vnd.github+json",
			},
			sink = ltn12.sink.table(response_body),
		})
	)
	socketutil:reset_timeout()

	if code == 403 then
		local content = table.concat(response_body)
		local ok, parsed = pcall(JSON.decode, content)
		if ok and parsed and parsed.message then
			return nil, "GitHub API rate limit exceeded: " .. parsed.message
		end
		return nil, "Update check rate limited, try again later"
	end

	if code ~= 200 then
		logger.dbg("FolderLock: update check failed, code=" .. tostring(code) .. ", status=" .. tostring(status))
		return nil, "Failed to check for updates (HTTP " .. tostring(code) .. ")"
	end

	local content = table.concat(response_body)
	local ok, release = pcall(JSON.decode, content)
	if not ok or not release then
		return nil, "Failed to parse update response"
	end

	if not release.tag_name or not release.assets then
		return nil, "Unexpected release format: missing tag_name or assets"
	end

	local latest_tag = release.tag_name:match("^v?(.+)$") or release.tag_name
	local current = FolderLockUpdater.get_current_version()
	local cmp = FolderLockUpdater.compare_versions(latest_tag, current)

	if cmp <= 0 then
		return {
			available = false,
			current_version = current,
			latest_version = latest_tag,
		}
	end

	-- Build asset names to look for
	local zip_pattern = "^folderlock%.koplugin%-" .. latest_tag .. "%.zip$"
	local sha_pattern = "^folderlock%.koplugin%-" .. latest_tag .. "%.zip%.sha256$"

	local zip_url = find_asset(release.assets, zip_pattern)
	if not zip_url then
		return nil, ("Update %s found but no matching zip asset"):format(latest_tag)
	end

	local sha256_url = find_asset(release.assets, sha_pattern)

	return {
		available = true,
		current_version = current,
		latest_version = latest_tag,
		zip_url = zip_url,
		sha256_url = sha256_url,
		release_url = release.html_url,
	}
end

-- Download a file from url to dest_path. Returns true on success, nil+err on failure.
local function download_file(url, dest_path)
	local http = require("socket.http")
	local ltn12 = require("ltn12")
	local socket = require("socket")
	local socketutil = require("socketutil")
	local logger = require("logger")

	socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
	local code, _, _ = socket.skip(
		1,
		http.request({
			url = url,
			sink = ltn12.sink.file(io.open(dest_path, "wb")),
			headers = {
				["User-Agent"] = USER_AGENT,
			},
		})
	)
	socketutil:reset_timeout()

	if code ~= 200 then
		logger.dbg("FolderLock: download failed, url=" .. url .. ", code=" .. tostring(code))
		os.remove(dest_path)
		return nil, "Download failed (HTTP " .. tostring(code) .. ")"
	end
	return true
end

-- Compute SHA256 hex digest of a file.
local function file_sha256(filepath)
	local sha2 = require("ffi/sha2")
	local file, err = io.open(filepath, "rb")
	if not file then
		return nil, err
	end
	local content = file:read("*all")
	file:close()
	return sha2.sha256(content)
end

function FolderLockUpdater.install(version, zip_url, sha256_url)
	local logger = require("logger")
	local tmp = os.tmpname()
	local tmp_sha
	local ok, err

	logger.dbg("FolderLock: downloading update zip from", zip_url)
	ok, err = download_file(zip_url, tmp)
	if not ok then
		return nil, err
	end

	if sha256_url then
		tmp_sha = os.tmpname()
		ok, err = download_file(sha256_url, tmp_sha)
		if not ok then
			os.remove(tmp)
			return nil, err
		end

		local sha_file, sha_err = io.open(tmp_sha, "r")
		if not sha_file then
			os.remove(tmp)
			os.remove(tmp_sha)
			return nil, "Failed to read checksum file: " .. tostring(sha_err)
		end
		local sha_line = sha_file:read("*l")
		sha_file:close()

		local expected_hash = sha_line:match("^(%x+)%s")
		if not expected_hash then
			os.remove(tmp)
			os.remove(tmp_sha)
			return nil, "Could not parse checksum from .sha256 file"
		end

		local computed_hash, hash_err = file_sha256(tmp)
		if not computed_hash then
			os.remove(tmp)
			os.remove(tmp_sha)
			return nil, "Failed to compute SHA256: " .. tostring(hash_err)
		end

		if computed_hash ~= expected_hash then
			os.remove(tmp)
			os.remove(tmp_sha)
			return nil, "Checksum mismatch: expected " .. expected_hash .. ", got " .. computed_hash
		end

		logger.dbg("FolderLock: checksum verified OK")
		os.remove(tmp_sha)
	end

	logger.dbg("FolderLock: checksum verified, extracting update")

	local plugin_dir = FolderLockUpdater._plugin_dir
	if not plugin_dir then
		os.remove(tmp)
		return nil, "Plugin directory not set"
	end

	local ffiUtil = require("ffi/util")
	local util = require("util")
	local Device = require("device")

	local plugin_dir_new = plugin_dir .. ".new"
	local plugin_dir_bak = plugin_dir .. ".bak"

	local lfs = require("libs/libkoreader-lfs")

	-- Clean up any stale .new from a previous aborted install
	local attr_new = lfs.attributes(plugin_dir_new)
	if attr_new then
		ffiUtil.purgeDir(plugin_dir_new)
	end

	-- Create fresh extract target
	util.makePath(plugin_dir_new)

	-- Extract zip into .new directory (strip root folder)
	local extract_ok, extract_err = Device:unpackArchive(tmp, plugin_dir_new, true)
	os.remove(tmp)
	if not extract_ok then
		ffiUtil.purgeDir(plugin_dir_new)
		return nil, "Extraction failed: " .. tostring(extract_err)
	end

	-- Remove existing .bak from a previous successful install
	local attr_bak = lfs.attributes(plugin_dir_bak)
	if attr_bak then
		ffiUtil.purgeDir(plugin_dir_bak)
	end

	-- Swap: live → .bak
	local rename_ok, rename_err = os.rename(plugin_dir, plugin_dir_bak)
	if not rename_ok then
		ffiUtil.purgeDir(plugin_dir_new)
		return nil, "Failed to back up current plugin: " .. tostring(rename_err)
	end

	-- Swap: .new → live
	local swap_ok, swap_err = os.rename(plugin_dir_new, plugin_dir)
	if not swap_ok then
		-- Rollback: restore .bak → live
		os.rename(plugin_dir_bak, plugin_dir)
		ffiUtil.purgeDir(plugin_dir_new)
		return nil, "Failed to install update: " .. tostring(swap_err)
	end

	logger.dbg("FolderLock: update installed successfully")
	return true
end

function FolderLockUpdater.recover_or_cleanup()
	local plugin_dir = FolderLockUpdater._plugin_dir
	if not plugin_dir then
		return true
	end

	local lfs = require("libs/libkoreader-lfs")
	local ffiUtil = require("ffi/util")
	local plugin_dir_bak = plugin_dir .. ".bak"
	local plugin_dir_new = plugin_dir .. ".new"

	local attr_live = lfs.attributes(plugin_dir)
	local attr_bak = lfs.attributes(plugin_dir_bak)
	local attr_new = lfs.attributes(plugin_dir_new)

	-- Stale .new from an aborted pre-swap install: delete it
	if attr_new then
		ffiUtil.purgeDir(plugin_dir_new)
	end

	-- .bak exists alongside live: install completed successfully, safe to clean up
	if attr_live and attr_bak then
		ffiUtil.purgeDir(plugin_dir_bak)
		return true
	end

	-- .bak exists but no live: previous install was rolled back or interrupted mid-swap
	if not attr_live and attr_bak then
		local ok, err = os.rename(plugin_dir_bak, plugin_dir)
		if not ok then
			return nil, err
		end
	end

	return true
end

return FolderLockUpdater
