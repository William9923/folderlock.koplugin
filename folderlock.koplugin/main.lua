--[[--
Plugin to password-protect folders via a lock registry.
@module koplugin.FolderLock
--]]
--

local FolderLockCore = require("lib/folderlock_core")
local FolderLockUpdater = require("lib/folderlock_updater")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local _orig_FileChooser_changeToPath = nil
local _filechooser_patch_installed = false

local function ensure_filechooser_patch()
    if _filechooser_patch_installed then
        return
    end

    local FileChooser = require("ui/widget/filechooser")
    if type(FileChooser.changeToPath) ~= "function" then
        return
    end

    _orig_FileChooser_changeToPath = FileChooser.changeToPath

    FileChooser.changeToPath = function(self_fc, path, focused_path)
        local chooser_name = self_fc and self_fc.name or "nil"

        -- Only guard FileManager navigation.
        if chooser_name ~= "filemanager" then
            return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
        end

        local real_path = FolderLockCore.normalize_path(path)
        if not real_path then
            return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
        end

        local locked_path = FolderLockCore.check_folder_lock(real_path)
        if not locked_path then
            return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
        end

        local dialog
        dialog = InputDialog:new({
            title = _("Folder Lock"),
            text_type = "password",
            input_hint = _("Enter password"),
            buttons = {
                {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function()
                            UIManager:close(dialog)
                            UIManager:show(InfoMessage:new({
                                text = _("Access Denied"),
                                timeout = 2,
                            }))
                        end,
                    },
                    {
                        text = _("Unlock"),
                        is_enter_default = true,
                        callback = function()
                            local input = dialog:getInputText()
                            local hash = FolderLockCore.djb2_hash(input)
                            local stored = FolderLockCore.get_lock_hash(locked_path)
                            if not stored then
                                UIManager:close(dialog)
                                return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
                            end

                            if hash == stored then
                                UIManager:close(dialog)
                                return _orig_FileChooser_changeToPath(self_fc, path, focused_path)
                            end

                            UIManager:show(InfoMessage:new({
                                text = _("Incorrect password"),
                                timeout = 2,
                            }))
                            dialog:onClose()
                            UIManager:show(dialog)
                            dialog:onShowKeyboard()
                        end,
                    },
                },
            },
        })

        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    _filechooser_patch_installed = true
end

local FolderLock = WidgetContainer:extend({
    name = "folderlock",
    is_doc_only = false,
})

function FolderLock:init()
    FolderLockCore.load_registry()
    FolderLockUpdater.recover_or_cleanup()

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Install one class-level patch for all FileChooser instances.
    ensure_filechooser_patch()
end

local function get_current_folder(self)
    local path = self.ui and self.ui.file_chooser and self.ui.file_chooser.path or nil
    return path
end

function FolderLock:addToMainMenu(menu_items)
    menu_items.folder_lock = {
        text = _("Folder Lock"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Lock current folder"),
                callback = function()
                    local path = get_current_folder(self)
                    if not path then
                        UIManager:show(InfoMessage:new({
                            text = _("No folder selected"),
                            timeout = 2,
                        }))
                        return
                    end

                    local normalized_path = FolderLockCore.normalize_path(path) or path

                    -- First password entry dialog
                    local pw_dialog
                    pw_dialog = InputDialog:new({
                        title = _("Lock folder"),
                        description = normalized_path,
                        text_type = "password",
                        input_hint = _("Enter password"),
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(pw_dialog)
                                    end,
                                },
                                {
                                    text = _("Next"),
                                    is_enter_default = true,
                                    callback = function()
                                        local pw1 = pw_dialog:getInputText()
                                        if pw1 == "" then
                                            UIManager:show(InfoMessage:new({
                                                text = _("Password cannot be empty"),
                                                timeout = 2,
                                            }))
                                            return
                                        end
                                        UIManager:close(pw_dialog)

                                        -- Re-confirm password dialog
                                        local confirm_dialog
                                        confirm_dialog = InputDialog:new({
                                            title = _("Confirm password"),
                                            text_type = "password",
                                            input_hint = _("Re-enter password"),
                                            buttons = {
                                                {
                                                    {
                                                        text = _("Cancel"),
                                                        id = "close",
                                                        callback = function()
                                                            UIManager:close(confirm_dialog)
                                                        end,
                                                    },
                                                    {
                                                        text = _("Lock"),
                                                        is_enter_default = true,
                                                        callback = function()
                                                            local pw2 = confirm_dialog:getInputText()
                                                            if pw1 ~= pw2 then
                                                                UIManager:show(
                                                                    InfoMessage:new({
                                                                        text = _("Passwords do not match"),
                                                                        timeout = 2,
                                                                    })
                                                                )
                                                                UIManager:close(confirm_dialog)
                                                                return
                                                            end
                                                            UIManager:close(confirm_dialog)
                                                            local ok = FolderLockCore.set_folder_lock(path, pw1)
                                                            if not ok then
                                                                UIManager:show(
                                                                    InfoMessage:new({
                                                                        text = _("Failed to lock folder"),
                                                                        timeout = 2,
                                                                    })
                                                                )
                                                                return
                                                            end
                                                            UIManager:show(
                                                                InfoMessage:new({
                                                                    text = _("Folder locked"),
                                                                    timeout = 2,
                                                                })
                                                            )
                                                        end,
                                                    },
                                                },
                                            },
                                        })
                                        UIManager:show(confirm_dialog)
                                        confirm_dialog:onShowKeyboard()
                                    end,
                                },
                            },
                        },
                    })
                    UIManager:show(pw_dialog)
                    pw_dialog:onShowKeyboard()
                end,
            },
            {
                text = _("Unlock current folder"),
                callback = function()
                    local path = get_current_folder(self)
                    if not path then
                        UIManager:show(InfoMessage:new({
                            text = _("No folder selected"),
                            timeout = 2,
                        }))
                        return
                    end

                    local locked_path = FolderLockCore.check_folder_lock(path)
                    if not locked_path then
                        UIManager:show(InfoMessage:new({
                            text = _("Folder is not locked"),
                            timeout = 2,
                        }))
                        return
                    end

                    local unlock_dialog
                    unlock_dialog = InputDialog:new({
                        title = _("Unlock folder"),
                        description = locked_path,
                        text_type = "password",
                        input_hint = _("Enter current password"),
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(unlock_dialog)
                                    end,
                                },
                                {
                                    text = _("Unlock"),
                                    is_enter_default = true,
                                    callback = function()
                                        local input = unlock_dialog:getInputText()
                                        local hash = FolderLockCore.djb2_hash(input)
                                        local stored = FolderLockCore.get_lock_hash(locked_path)
                                        if hash ~= stored then
                                            UIManager:show(InfoMessage:new({
                                                text = _("Incorrect password"),
                                                timeout = 2,
                                            }))
                                            return
                                        end
                                        UIManager:close(unlock_dialog)
                                        local ok = FolderLockCore.remove_folder_lock(locked_path)
                                        if not ok then
                                            UIManager:show(InfoMessage:new({
                                                text = _("Failed to unlock folder"),
                                                timeout = 2,
                                            }))
                                            return
                                        end
                                        UIManager:show(InfoMessage:new({
                                            text = _("Folder unlocked"),
                                            timeout = 2,
                                        }))
                                    end,
                                },
                            },
                        },
                    })
                    UIManager:show(unlock_dialog)
                    unlock_dialog:onShowKeyboard()
                end,
            },
            {
                text = _("Check for updates"),
                callback = function()
                    UIManager:show(ConfirmBox:new({
                        text = _("Check for Folder Lock updates?"),
                        ok_text = _("Check"),
                        ok_callback = function()
                            Trapper:wrap(function()
                                local result, err = FolderLockUpdater.check()
                                if not result then
                                    UIManager:show(InfoMessage:new({
                                        text = _("Update check failed: ") .. err,
                                    }))
                                    return
                                end
                                if not result.available then
                                    UIManager:show(InfoMessage:new({
                                        text = _("You're running the latest version (") .. result.current_version .. _(")."),
                                        timeout = 3,
                                    }))
                                    return
                                end
                                UIManager:show(ConfirmBox:new({
                                    text = _("Update ") .. result.latest_version .. _(" is available. Install?"),
                                    ok_text = _("Install"),
                                    ok_callback = function()
                                        local install_ok, install_err = FolderLockUpdater.install(result.latest_version)
                                        if install_err then
                                            UIManager:show(InfoMessage:new({
                                                text = _("Install failed: ") .. install_err,
                                            }))
                                            return
                                        end
                                        UIManager:askForRestart(_("Update installed. Please restart KOReader."))
                                    end,
                                }))
                            end)
                        end,
                    }))
                end,
            },
        },
    }
end

return FolderLock
