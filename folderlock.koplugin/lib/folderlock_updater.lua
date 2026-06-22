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

function FolderLockUpdater.install(_version)
	return nil, "update install not implemented yet"
end

function FolderLockUpdater.recover_or_cleanup()
	return true
end

return FolderLockUpdater
