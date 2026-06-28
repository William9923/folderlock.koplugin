local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local function load_isolation(mock_check, mocks)
	mocks = mocks or {}
	package.path = "./folderlock.koplugin/?.lua;" .. package.path

	package.loaded["lib/folderlock_core"] = {
		check_folder_lock = mock_check or function()
			return nil
		end,
	}
	package.loaded["bookinfomanager"] = mocks.bookinfomanager or nil
	package.loaded["ui/widget/booklist"] = mocks.booklist or nil
	package.loaded["lib/folderlock_cache_isolation"] = nil

	local iso = require("lib/folderlock_cache_isolation")
	return iso
end

local function make_mock_bookinfo_manager()
	return {
		getBookInfo = function(self, filepath, get_cover)
			return { title = filepath, get_cover = get_cover }
		end,
		getDocProps = function(self, filepath)
			return { title = filepath }
		end,
	}
end

local function make_mock_booklist()
	return {
		getBookInfo = function(file)
			return { been_opened = true, percent_finished = 0.5, file = file }
		end,
		hasBookBeenOpened = function(file)
			return true
		end,
	}
end

t.test("is_inside matches child directories exactly", function()
	local iso = load_isolation()
	eq(iso.is_inside("/a/b/c", "/a/b"), true)
	eq(iso.is_inside("/a/b/c", "/a/b/c"), true)
	eq(iso.is_inside("/a/bc", "/a/b"), false)
	eq(iso.is_inside("/a", "/a/b"), false)
	eq(iso.is_inside(nil, "/a/b"), false) -- simulating non folder menu, such as History, Collection, etc...
	eq(iso.is_inside("/a/b", nil), false)
end)

t.test("is_hidden_path hides locked paths outside current context", function()
	local iso = load_isolation(function(filepath)
		if filepath:sub(1, #"/locked") == "/locked" then
			return "/locked"
		end
		return nil
	end)

	iso.set_current_path(nil)
	eq(iso.is_hidden_path("/locked/book.epub"), true)

	iso.set_current_path("/other")
	eq(iso.is_hidden_path("/locked/book.epub"), true)

	iso.set_current_path("/locked")
	eq(iso.is_hidden_path("/locked/book.epub"), false)

	iso.set_current_path("/locked/sub")
	eq(iso.is_hidden_path("/locked/book.epub"), false)

	iso.set_current_path(nil)
	eq(iso.is_hidden_path("/open/book.epub"), false)
end)

t.test("with_context sets and clears path", function()
	local iso = load_isolation()
	iso.set_current_path(nil)

	local captured
	local result = iso.with_context("/locked", function(arg)
		captured = iso.get_current_path()
		return arg * 2
	end, 21)

	eq(captured, "/locked")
	eq(result, 42)
	eq(iso.get_current_path(), nil)
end)

t.test("with_context clears path even if fn errors", function()
	local iso = load_isolation()
	iso.set_current_path(nil)

	local ok, err = pcall(function()
		iso.with_context("/locked", function()
			error("boom")
		end)
	end)

	eq(ok, false)
	eq(iso.get_current_path(), nil)
	assert(tostring(err):find("boom"), "expected error to propagate")
end)

t.test("install tolerates missing modules", function()
	local iso = load_isolation()
	-- covermenu and view modules are not available in plain lua; install should not error.
	iso.install()
	eq(iso.get_current_path(), nil)
end)

t.test("BookInfoManager hooks hide info outside context", function()
	local bim = make_mock_bookinfo_manager()
	local iso = load_isolation(function(filepath)
		return filepath:sub(1, #"/locked") == "/locked" and "/locked" or nil
	end, {
		bookinfomanager = bim,
	})

	iso.install()

	iso.set_current_path(nil)
	eq(bim:getBookInfo("/locked/book.epub", true), nil)
	eq(bim:getDocProps("/locked/book.epub"), nil)

	iso.set_current_path("/locked")
	eq(bim:getBookInfo("/locked/book.epub", true), { title = "/locked/book.epub", get_cover = true })
	eq(bim:getDocProps("/locked/book.epub"), { title = "/locked/book.epub" })

	iso.set_current_path(nil)
	eq(bim:getBookInfo("/open/book.epub"), { title = "/open/book.epub", get_cover = nil })
end)

t.test("BookList hooks hide status outside context", function()
	local bl = make_mock_booklist()
	local calls = {}
	local orig_hasbeenopened = bl.hasBookBeenOpened
	bl.hasBookBeenOpened = function(file)
		table.insert(calls, file)
		return orig_hasbeenopened(file)
	end

	local iso = load_isolation(function(filepath)
		return filepath:sub(1, #"/locked") == "/locked" and "/locked" or nil
	end, {
		booklist = bl,
	})

	iso.install()

	iso.set_current_path(nil)
	eq(bl.getBookInfo("/locked/book.epub"), { been_opened = false })
	eq(bl.hasBookBeenOpened("/locked/book.epub"), false)
	eq(#calls, 0) -- short-circuited before touching cache

	iso.set_current_path("/locked")
	eq(bl.getBookInfo("/locked/book.epub"), { been_opened = true, percent_finished = 0.5, file = "/locked/book.epub" })
	eq(bl.hasBookBeenOpened("/locked/book.epub"), true)
	eq(#calls, 1)

	iso.set_current_path(nil)
	eq(bl.getBookInfo("/open/book.epub").been_opened, true) -- simulating other folder (unlocked)
end)

t.test("install is idempotent", function()
	local bim = make_mock_bookinfo_manager()
	local bl = make_mock_booklist()
	local iso = load_isolation(function(filepath)
		return filepath:sub(1, #"/locked") == "/locked" and "/locked" or nil
	end, {
		bookinfomanager = bim,
		booklist = bl,
	})

	iso.install()
	iso.install()

	iso.set_current_path(nil)
	eq(bim:getBookInfo("/locked/book.epub"), nil)
	eq(bl.hasBookBeenOpened("/locked/book.epub"), false)

	iso.set_current_path("/locked")
	eq(bim:getBookInfo("/locked/book.epub"), { title = "/locked/book.epub", get_cover = nil })
	eq(bl.hasBookBeenOpened("/locked/book.epub"), true)
end)

t.done()
