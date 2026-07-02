local M = {}

function M.runner()
    local pass, fail = 0, 0
    return {
        test = function(name, fn)
            local ok, err = pcall(fn)
            if ok then
                pass = pass + 1
            else
                fail = fail + 1
                io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
            end
        end,
        done = function()
            io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
            if fail > 0 then
                os.exit(1)
            end
        end,
    }
end

local function deep_equal(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then
            return false
        end
    end
    for k, v in pairs(b) do
        if not deep_equal(v, a[k]) then
            return false
        end
    end
    return true
end

function M.eq(got, want, msg)
    if not deep_equal(got, want) then
        error((msg or "values differ") .. "\n  got: " .. tostring(got) .. "\n  want: " .. tostring(want), 2)
    end
    return got
end

local function ensure_bit_stub()
    if package.loaded["bit"] then
        return
    end

    local ok, bit = pcall(require, "bit")
    if ok and bit then
        package.loaded["bit"] = bit
        return
    end

    local ok32, bit32 = pcall(require, "bit32")
    if ok32 and bit32 then
        package.loaded["bit"] = {
            bxor = bit32.bxor,
        }
        return
    end

    -- Fallback: emulate 32-bit bxor in pure Lua.
    local function bxor32(a, b)
        a = a % 4294967296
        b = b % 4294967296
        local result = 0
        local bitval = 1
        for _ = 1, 32 do
            local abit = a % 2
            local bbit = b % 2
            if abit ~= bbit then
                result = result + bitval
            end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
            bitval = bitval * 2
        end
        return result % 4294967296
    end

    package.loaded["bit"] = {
        bxor = bxor32,
    }
end

function M.install_stubs(opts)
    opts = opts or {}

    ensure_bit_stub()

    local state = {
        settings_dir = opts.settings_dir or "/tmp/folderlock-tests",
        realpath_map = opts.realpath_map or {},
        initial_locks = opts.initial_locks or {},
        save_calls = 0,
        flush_calls = 0,
        opened_paths = {},
        store = {
            locks = {},
        },
    }

    for k, v in pairs(state.initial_locks) do
        state.store.locks[k] = v
    end

    package.loaded["datastorage"] = {
        getSettingsDir = function()
            return state.settings_dir
        end,
    }

    package.loaded["ffi/util"] = {
        realpath = function(path)
            if state.realpath_map[path] ~= nil then
                return state.realpath_map[path]
            end
            return path
        end,
    }

    package.loaded["luasettings"] = {
        open = function(_, path)
            table.insert(state.opened_paths, path)
            return {
                readSetting = function(_, key)
                    return state.store[key]
                end,
                saveSetting = function(_, key, value)
                    state.save_calls = state.save_calls + 1
                    state.store[key] = value
                end,
                flush = function()
                    state.flush_calls = state.flush_calls + 1
                end,
            }
        end,
    }

    return state
end

return M
