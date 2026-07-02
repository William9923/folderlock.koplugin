local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

package.path = "./folderlock.koplugin/?.lua;" .. package.path

local function load_hasher(opts)
	helpers.install_stubs(opts)
	package.loaded["util/folderlock_hasher"] = nil
	return require("util/folderlock_hasher")
end

t.test("djb2_hash is deterministic and has known values", function()
	local hasher = load_hasher()
	eq(hasher.hash(""), "5381")
	eq(hasher.hash("test"), "2090570867")
	eq(hasher.hash("secret"), hasher.hash("secret"))
end)

t.test("normalize_path handles nil, empty, resolved and fallback", function()
	local hasher = load_hasher({
		realpath_map = {
			["/books"] = "/mnt/books",
		},
	})
	eq(hasher.normalize(nil), nil)
	eq(hasher.normalize(""), nil)
	eq(hasher.normalize("/books"), "/mnt/books")
	eq(hasher.normalize("/unknown"), "/unknown")
end)

t.done()
