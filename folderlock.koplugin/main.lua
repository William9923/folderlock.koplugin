--[[--
Plugin to password-protect folders via a lock registry.
@module koplugin.FolderLock
--]]
--
local lfs = require("libs/libkoreader-lfs")

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")

local FolderLockCore = require("lib/folderlock_core")
local FolderLockUpdater = require("lib/folderlock_updater")
local FolderLockCacheIsolation = require("lib/folderlock_cache_isolation")
local FolderLockGuard = require("lib/folderlock_guard")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FileManager = require("apps/filemanager/filemanager")
local _ = require("gettext")

-- Helper: show lock password dialog, optional on_success callback after lock
local function lock_folder_dialog(path, on_success)
	local pw_dialog
	pw_dialog = InputDialog:new({
		title = _("Lock folder"),
		description = path,
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
												UIManager:show(InfoMessage:new({
													text = _("Passwords do not match"),
													timeout = 2,
												}))
												UIManager:close(confirm_dialog)
												return
											end
											UIManager:close(confirm_dialog)
											local ok = FolderLockCore.set_folder_lock(path, pw1)
											if not ok then
												UIManager:show(InfoMessage:new({
													text = _("Failed to lock folder"),
													timeout = 2,
												}))
												return
											end
											if on_success then
												on_success()
											end
											UIManager:show(InfoMessage:new({
												text = _("Folder locked"),
												timeout = 2,
											}))
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
end

-- Helper: show unlock password dialog, optional on_success callback after unlock
local function unlock_folder_dialog(path, hash_key, on_success)
	local unlock_dialog
	unlock_dialog = InputDialog:new({
		title = _("Unlock folder"),
		description = path,
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
						local stored = FolderLockCore.get_lock_hash(hash_key)
						if hash ~= stored then
							UIManager:show(InfoMessage:new({
								text = _("Incorrect password"),
								timeout = 2,
							}))
							return
						end
						UIManager:close(unlock_dialog)
						local ok = FolderLockCore.remove_folder_lock(path)
						if not ok then
							UIManager:show(InfoMessage:new({
								text = _("Failed to unlock folder"),
								timeout = 2,
							}))
							return
						end
						if on_success then
							on_success()
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
end

local FolderLock = WidgetContainer:extend({
	name = "folderlock",
	is_doc_only = false,
})

function FolderLock:init()
	FolderLockCore.load_registry()
	FolderLockUpdater.set_plugin_dir(self.path)
	FolderLockUpdater.recover_or_cleanup()
	FolderLockCacheIsolation.set_cover_path(self.path .. "/assets/folderlock_cover.png")

	if self.ui and self.ui.menu then
		self.ui.menu:registerToMainMenu(self)
	end

	FolderLockGuard.install()
	FolderLockCacheIsolation.install()

	-- register long press button
	FileManager.addFileDialogButtons(self.ui, "folderlock", function(file, is_file, _book_props)
		local is_directory = lfs.attributes(file, "mode") == "directory"
		if is_file or not is_directory then
			return nil
		end
		local normalized = FolderLockCore.normalize_path(file)
		local exact_hash = FolderLockCore.get_lock_hash(normalized)
		local ancestor_lock = FolderLockCore.check_folder_lock(file)

		if exact_hash then
			return {
				{
					text = _("Unlock folder"),
					callback = function()
						unlock_folder_dialog(file, normalized, function()
							UIManager:close(self.ui.file_chooser.file_dialog)
							self.ui.file_chooser:refreshPath()
						end)
					end,
				},
			}
		elseif not ancestor_lock then
			return {
				{
					text = _("Lock folder"),
					callback = function()
						lock_folder_dialog(file, function()
							UIManager:close(self.ui.file_chooser.file_dialog)
							self.ui.file_chooser:refreshPath()
						end)
					end,
				},
			}
		end
		-- ancestor is locked but not this folder → skip button
		return nil
	end)
end

local function get_current_folder(self)
	return self.ui and self.ui.file_chooser and self.ui.file_chooser.path or nil
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
					lock_folder_dialog(path)
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
					unlock_folder_dialog(locked_path, locked_path)
				end,
			},
			{
				text_func = function()
					return _("Version: ") .. FolderLockUpdater.get_current_version()
				end,
				callback = function()
					UIManager:show(InfoMessage:new({
						text = _("Folder Lock ") .. FolderLockUpdater.get_current_version(),
						timeout = 3,
					}))
				end,
			},
			{
				text = _("Check for updates"),
				callback = function()
					local ConfirmBox = require("ui/widget/confirmbox")
					local Trapper = require("ui/trapper")

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
										text = _("You're running the latest version (") .. result.current_version .. _(
											")."
										),
										timeout = 3,
									}))
									return
								end
								UIManager:show(ConfirmBox:new({
									text = _("Update ") .. result.latest_version .. _(" is available. Install?"),
									ok_text = _("Install"),
									ok_callback = function()
										local install_ok, install_err = FolderLockUpdater.install(
											result.latest_version,
											result.zip_url,
											result.sha256_url
										)
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
