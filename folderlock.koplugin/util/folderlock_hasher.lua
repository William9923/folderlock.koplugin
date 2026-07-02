local bit = require("bit")
local ffiUtil = require("ffi/util")
local function djb2_hash(str)
	local hash = 5381
	for i = 1, #str do
		local byte = str:byte(i)
		hash = bit.bxor(hash * 33 + byte, 0xFFFFFFFF)
	end
	return tostring(hash)
end

local function normalize_path(path)
	if not path or path == "" then
		return nil
	end
	return ffiUtil.realpath(path) or path
end
local FolderLockHasher = {
	hash = djb2_hash,
	normalizer = normalize_path,
}

return FolderLockHasher
