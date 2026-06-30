local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

-- Build a fresh mock environment for each test.
-- Returns (Guard, { dialog: captured dialog widget; on_allowed/denied: flags }).
local function fresh_guard(opts)
	opts = opts or {}
	local state = {
		allowed = false,
		denied = false,
		dialog = nil,
	}
	package.path = "./folderlock.koplugin/?.lua;" .. package.path
	package.loaded["lib/folderlock_guard"] = nil
	package.loaded["libs/libkoreader-lfs"] = {
		attributes = function() end,
	}
	package.loaded["gettext"] = function(s) return s end

	-- Stubs for modules required by folderlock_guard at load time
	package.loaded["lib/folderlock_cache_isolation"] = {
		set_current_path = function() end,
		is_inside = function() return false end,
		is_hidden_path = function() return false end,
		with_context = function(ctx, fn, ...)
			return fn(...)
		end,
	}
	package.loaded["ui/widget/filechooser"] = {
		changeToPath = function() return "original" end,
	}

	-- FolderLockCore mock
	package.loaded["lib/folderlock_core"] = {
		normalize_path = function(p) return p or nil end,
		djb2_hash = function(s) return tostring(#s) end,
		check_folder_lock = function(p)
			if opts.locked_path and p:find(opts.locked_path, 1, true) == 1 then
				return opts.locked_path
			end
			if opts.locked then
				return "/locked"
			end
			return nil
		end,
		get_lock_hash = function()
			if opts.no_hash then return nil end
			return opts.hash or "9"
		end,
	}

	-- UI stubs
	package.loaded["ui/uimanager"] = {
		show = function(w) end,
		close = function(w) end,
	}
	package.loaded["ui/widget/infomessage"] = {
		new = function(self, o) return o end,
	}
	package.loaded["ui/widget/inputdialog"] = {
		new = function(self, o)
			state.dialog = o
			o.setInputText = function(_, t) o._input_text = t or "" end
			o.getInputText = function(_) return o._input_text or "" end
			o.onClose = function() end
			o.onShowKeyboard = function() end
			return o
		end,
	}

	local Guard = require("lib/folderlock_guard")
	Guard._reset()
	return Guard, state
end

-- Helper that calls prompt_unlock_or_block and returns state
local function run_prompt(path, on_allowed, on_denied, opts)
	opts = opts or {}
	local Guard, state = fresh_guard(opts)
	if on_allowed == nil then
		on_allowed = function() state.allowed = true end
	elseif type(on_allowed) == "function" then
		local orig = on_allowed
		on_allowed = function() state.allowed = true; orig() end
	end
	if on_denied == nil then
		on_denied = function() state.denied = true end
	elseif type(on_denied) == "function" then
		local orig = on_denied
		on_denied = function() state.denied = true; orig() end
	end
	Guard.prompt_unlock_or_block(path, on_allowed, on_denied)
	state.Guard = Guard
	return state
end

-- ── Token helpers ──

t.test("allow_once + consume_once round-trip", function()
	local Guard = fresh_guard()
	Guard.allow_once("/tmp/test")
	eq(Guard.consume_once("/tmp/test"), true)
	eq(Guard.consume_once("/tmp/test"), false)
end)

t.test("peek_once leaves token in place", function()
	local Guard = fresh_guard()
	Guard.allow_once("/tmp/test")
	eq(Guard.peek_once("/tmp/test"), true)
	eq(Guard.consume_once("/tmp/test"), true, "token should still be present after peek")
	eq(Guard.consume_once("/tmp/test"), false)
end)

t.test("consume_once returns false for non-existent path", function()
	local Guard = fresh_guard()
	eq(Guard.consume_once("/nonexistent"), false)
end)

t.test("peek_once returns false for non-existent path", function()
	local Guard = fresh_guard()
	eq(Guard.peek_once("/tmp/missing"), false)
end)

t.test("with_unlock_token sets token before fn and clears after", function()
	local Guard = fresh_guard()
	local token_seen = false
	Guard.with_unlock_token("/tmp/test", function()
		token_seen = Guard.consume_once("/tmp/test")
	end)
	eq(token_seen, true, "fn should see the token")
	eq(Guard.consume_once("/tmp/test"), false, "token must be cleared after with_unlock_token")
end)

t.test("with_unlock_token clears token if fn errors", function()
	local Guard = fresh_guard()
	local ok, err = pcall(function()
		Guard.with_unlock_token("/tmp/test", function()
			error("intentional error")
		end)
	end)
	eq(ok, false)
	eq(Guard.consume_once("/tmp/test"), false, "token must be cleared even after error")
end)

t.test("allow_once with nil path does nothing", function()
	local Guard = fresh_guard()
	Guard.allow_once(nil)
end)

t.test("consume_once with nil path returns false", function()
	local Guard = fresh_guard()
	eq(Guard.consume_once(nil), false)
end)

t.test("with_unlock_token with nil path just calls fn", function()
	local Guard = fresh_guard()
	local called = false
	Guard.with_unlock_token(nil, function() called = true end)
	eq(called, true)
end)

t.test("_reset clears all tokens", function()
	local Guard = fresh_guard()
	Guard.allow_once("/tmp/a")
	Guard.allow_once("/tmp/b")
	Guard._reset()
	eq(Guard.consume_once("/tmp/a"), false)
	eq(Guard.consume_once("/tmp/b"), false)
end)

-- ── prompt_unlock_or_block ──

t.test("calls on_allowed immediately for unlocked path", function()
	local s = run_prompt("/open", nil, nil, { locked = false })
	eq(s.allowed, true)
end)

t.test("shows password dialog for locked path", function()
	local s = run_prompt("/locked/file", nil, nil, { locked = true })
	eq(s.dialog ~= nil, true, "should have created a dialog")
	eq(s.allowed, false, "on_allowed should not be called before password is entered")
end)

t.test("Cancel calls on_denied and does not call on_allowed", function()
	local s = run_prompt("/locked/file", nil, nil, { locked_path = "/locked", hash = "9" })
	eq(s.dialog ~= nil, true, "dialog must exist")

	local cancel_cb = s.dialog.buttons[1][1].callback
	cancel_cb()

	eq(s.denied, true, "on_denied should be called on Cancel")
	eq(s.allowed, false, "on_allowed should not be called on Cancel")
end)

t.test("correct password calls on_allowed", function()
	local s = run_prompt("/locked/file", nil, nil, { locked_path = "/locked", hash = "9" })
	eq(s.dialog ~= nil, true, "dialog must exist")

	local enter_cb = s.dialog.buttons[1][2].callback
	s.dialog:setInputText("secret123")
	enter_cb()

	eq(s.allowed, true, "on_allowed should be called after correct password")
end)

t.test("wrong password shows error and does not call either callback", function()
	local s = run_prompt("/locked/file", nil, nil, { locked_path = "/locked", hash = "9" })
	eq(s.dialog ~= nil, true, "dialog must exist")

	local enter_cb = s.dialog.buttons[1][2].callback
	s.dialog:setInputText("wrong")
	enter_cb()

	eq(s.allowed, false, "on_allowed should not be called after wrong password")
	eq(s.denied, false, "on_denied should not be called after wrong password")
end)

t.test("no stored hash for locked path allows through on Enter", function()
	local s = run_prompt("/locked/file", nil, nil, { locked_path = "/locked", no_hash = true })
	eq(s.dialog ~= nil, true, "dialog should appear")
	-- press Enter with any or empty password; no stored hash so allows
	local enter_cb = s.dialog.buttons[1][2].callback
	s.dialog:setInputText("anything")
	enter_cb()
	eq(s.allowed, true, "should allow through if no stored hash")
end)

t.test("on_denied is optional (nil)", function()
	local Guard, st = fresh_guard({ locked_path = "/locked", hash = "9" })
	local allowed = false
	Guard.prompt_unlock_or_block("/locked/file", function() allowed = true end)
	eq(st.dialog ~= nil, true, "dialog must exist")

	local cancel_cb = st.dialog.buttons[1][1].callback
	cancel_cb()

	eq(allowed, false, "on_allowed not called on Cancel")
	-- no error from missing on_denied
end)

t.test("on_allowed is not called until password verified", function()
	local Guard, st = fresh_guard({ locked_path = "/locked", hash = "9" })
	local allowed = false
	Guard.prompt_unlock_or_block("/locked/file", function() allowed = true end)
	eq(allowed, false, "on_allowed should not be called immediately for locked path")
end)

t.test("user-provided on_allowed receives its own callback", function()
	local my_allowed = false
	local s = run_prompt("/open", function() my_allowed = true end, nil, { locked = false })
	eq(s.allowed, true, "state.allowed set by wrapper")
	eq(my_allowed, true, "user callback also called")
end)

-- ── install_ensure_filechooser_patch ──

t.test("install_ensure_filechooser_patch patches FileChooser.changeToPath", function()
	local Guard = fresh_guard()
	local FC = require("ui/widget/filechooser")
	local before = FC.changeToPath
	Guard.install_ensure_filechooser_patch()
	eq(FC.changeToPath ~= before, true, "changeToPath should be replaced")
end)

t.test("install_ensure_filechooser_patch is idempotent", function()
	local Guard = fresh_guard()
	local FC = require("ui/widget/filechooser")
	Guard.install_ensure_filechooser_patch()
	local patched = FC.changeToPath
	Guard.install_ensure_filechooser_patch()
	eq(FC.changeToPath, patched, "second call should not re-patch")
end)

t.done()
