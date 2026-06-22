local FolderLockVersion = require("lib/folderlock_version")

local REPO = "William9923/folderlock.koplugin"
local DEFAULT_LATEST_RELEASE_URL = "https://api.github.com/repos/" .. REPO .. "/releases/latest"

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

function FolderLockUpdater.check()
    return nil, "update check not implemented yet"
end

function FolderLockUpdater.install(_version)
    return nil, "update install not implemented yet"
end

function FolderLockUpdater.recover_or_cleanup()
    return true
end

return FolderLockUpdater
