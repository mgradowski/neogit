local cli = require("neogit.lib.git.cli")
local notification = require("neogit.lib.notification")
local input = require("neogit.lib.input")

local M = {}

M.create = function(directory, sync)
  sync = sync or false

  if sync then
    cli.init.args(directory).call_sync()
  else
    cli.init.args(directory).call()
  end
end

-- TODO Use path input
-- TODO: Don't call the status buffer directly here
M.init_repo = function()
  local directory = input.get_user_input("Create repository in", { completion = "dir" })
  if not directory then
    return
  end

  -- git init doesn't understand ~
  directory = vim.fn.fnamemodify(directory, ":p")

  if vim.fn.isdirectory(directory) == 0 then
    notification.error("Invalid Directory")
    return
  end

  local status = require("neogit.status")
  status.cwd_changed = true
  vim.cmd.lcd(directory)

  if cli.is_inside_worktree() then
    if not input.get_permission(("Reinitialize existing repository %s?"):format(directory)) then
      return
    end
  end

  M.create(directory)

  status.refresh(nil, "InitRepo")
end

return M
