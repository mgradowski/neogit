local PopupBuilder = require("neogit.lib.popup.builder")
local Buffer = require("neogit.lib.buffer")
local common = require("neogit.buffers.common")
local Ui = require("neogit.lib.ui")
local logger = require("neogit.logger")
local util = require("neogit.lib.util")
local config = require("neogit.config")
local state = require("neogit.lib.state")
local input = require("neogit.lib.input")

local branch = require("neogit.lib.git.branch")
local config_lib = require("neogit.lib.git.config")

local col = Ui.col
local row = Ui.row
local text = Ui.text
local Component = Ui.Component
local map = util.map
local filter_map = util.filter_map
local build_reverse_lookup = util.build_reverse_lookup
local intersperse = util.intersperse
local List = common.List
local Grid = common.Grid

local M = {}

function M.builder()
  return PopupBuilder.new(M.new)
end

function M.new(state)
  local instance = {
    state = state,
    buffer = nil,
  }
  setmetatable(instance, { __index = M })
  return instance
end

-- Returns a table of strings, each representing a toggled option/switch in the popup. Filters out internal arguments.
-- Formatted for consumption by cli:
-- Option: --name=value
-- Switch: --name
---@return string[]
function M:get_arguments()
  local flags = {}

  for _, arg in pairs(self.state.args) do
    if arg.type == "switch" and arg.enabled and not arg.internal then
      table.insert(flags, arg.cli_prefix .. arg.cli)
    end

    if arg.type == "option" and #arg.value ~= 0 and not arg.internal then
      table.insert(flags, arg.cli_prefix .. arg.cli .. "=" .. arg.value)
    end
  end

  return flags
end

-- Returns a table of key/value pairs, where the key is the name of the switch, and value is `true`, for all
-- enabled arguments that are NOT for cli consumption (internal use only).
---@return table
function M:get_internal_arguments()
  local args = {}
  for _, arg in pairs(self.state.args) do
    if arg.type == "switch" and arg.enabled and arg.internal then
      args[arg.cli] = true
    end
  end
  return args
end

-- Combines all cli arguments into a single string.
---@return string
function M:to_cli()
  return table.concat(self:get_arguments(), " ")
end

-- Closes the popup buffer
function M:close()
  self.buffer:close()
  self.buffer = nil
end

-- Determines the correct highlight group for a switch based on it's state.
---@return string
local function get_highlight_for_switch(switch)
  if switch.enabled then
    return "NeogitPopupSwitchEnabled"
  end

  return "NeogitPopupSwitchDisabled"
end

-- Determines the correct highlight group for an option based on it's state.
---@return string
local function get_highlight_for_option(option)
  if option.value ~= nil and option.value ~= "" then
    return "NeogitPopupOptionEnabled"
  end

  return "NeogitPopupOptionDisabled"
end

-- Determines the correct highlight group for a config based on it's type and state.
---@return string
local function get_highlight_for_config(config)
  if config.value and config.value ~= "" and config.value ~= "unset" then
    return config.type or "NeogitPopupConfigEnabled"
  end

  return "NeogitPopupConfigDisabled"
end

-- Builds config component to be rendered
---@return table
local function construct_config_options(config)
  local options = filter_map(config.options, function(option)
    if option.display == "" then
      return
    end

    local highlight
    if config.value == option.value then
      highlight = "NeogitPopupConfigEnabled"
    else
      highlight = "NeogitPopupConfigDisabled"
    end

    return text.highlight(highlight)(option.display)
  end)

  local value = intersperse(options, text.highlight("NeogitPopupConfigDisabled")("|"))
  table.insert(value, 1, text.highlight("NeogitPopupConfigDisabled")("["))
  table.insert(value, #value + 1, text.highlight("NeogitPopupConfigDisabled")("]"))

  return value
end

---@param id integer ID of component to be updated
---@param highlight string New highlight group for value
---@param value string|table New value to display
---@return nil
function M:update_component(id, highlight, value)
  local component = self.buffer.ui:find_component(function(c)
    return c.options.id == id
  end)

  assert(component, "Component not found! Cannot update.")

  if highlight then
    if component.options.highlight then
      component.options.highlight = highlight
    else
      component.children[1].options.highlight = highlight
    end
  end

  if value then
    if type(value) == "string" then
      component.children[#component.children].value = value
    elseif type(value) == "table" then
      -- Remove last n children from row
      for _ = 1, #value do
        table.remove(component.children)
      end

      -- insert new items to row
      for _, text in ipairs(value) do
        table.insert(component.children, text)
      end
    else
      logger.debug(string.format("[POPUP]: Unhandled component value type! (%s)", type(value)))
    end
  end

  self.buffer.ui:update()
end

-- Toggle a switch on/off
---@param switch table
---@return nil
function M:toggle_switch(switch)
  switch.enabled = not switch.enabled

  -- If a switch depends on user input, i.e. `-Gsomething`, prompt user to get input
  if switch.user_input then
    if switch.enabled then
      local value = input.get_user_input(switch.cli_prefix .. switch.cli_base .. ": ")
      if value then
        switch.cli = switch.cli_base .. value
      end
    else
      switch.cli = switch.cli_base
    end
  end

  -- Update internal state and UI.
  state.set({ self.state.name, switch.cli }, switch.enabled)
  self:update_component(switch.id, get_highlight_for_switch(switch), switch.cli)

  -- Ensure that other switches that are incompatible with this one are disabled
  if switch.enabled and #switch.incompatible > 0 then
    for _, var in ipairs(self.state.args) do
      if var.type == "switch" and var.enabled and switch.incompatible[var.cli] then
        var.enabled = false
        state.set({ self.state.name, var.cli }, var.enabled)
        self:update_component(var.id, get_highlight_for_switch(var))
      end
    end
  end
end

-- Toggle an option on/off and set it's value
---@param option table
---@return nil
function M:set_option(option)
  local set = function(value)
    option.value = value
    state.set({ self.state.name, option.cli }, option.value)
    self:update_component(option.id, get_highlight_for_option(option), option.value)
  end

  -- Prompt user to select from predetermined choices
  if option.choices then
    if not option.value or option.value == "" then
      vim.ui.select(option.choices, { prompt = option.description }, set)
    else
      set("")
    end
  else
    -- ...Otherwise get the value via input.
    local input =
      vim.fn.input { prompt = option.cli .. "=", default = option.value, cancelreturn = option.value }

    -- If the option specifies a default value, and the user set the value to be empty, defer to default value.
    -- This is handy to prevent the user from accidently loading thousands of log entries by accident.
    if option.default and input == "" then
      set(option.default)
    else
      set(input)
    end
  end
end

-- Set a config value
---@param config table
---@return nil
function M:set_config(config)
  if config.options then
    -- For config's that offer predetermined options to choose from.
    local options = build_reverse_lookup(map(config.options, function(option)
      return option.value
    end))

    local index = options[config.value]
    config.value = options[(index + 1)] or options[1]
    self:update_component(config.id, nil, construct_config_options(config))
  elseif config.callback then
    config.callback(self, config)
    -- block here?
  else
    -- For config's that require user input
    local result = vim.fn.input {
      prompt = config.name .. " > ",
      default = config.value == "unset" and "" or config.value,
      cancelreturn = config.value,
    }

    config.value = result == "" and "unset" or result
    self:update_component(config.id, get_highlight_for_config(config), config.value)
  end

  -- Update config value via CLI
  config_lib.set(config.name, config.value)

  -- Updates passive variables (variables that don't get interacted with directly)
  for _, var in ipairs(self.state.config) do
    if var.passive then
      local c_value = config_lib.get(var.name)
      if c_value then
        var.value = c_value.value
        self:update_component(var.id, nil, var.value)
      end
    end
  end
end

local Switch = Component.new(function(switch)
  return row.tag("Switch").value(switch) {
    text(" "),
    row.highlight("NeogitPopupSwitchKey") {
      text(switch.key_prefix),
      text(switch.key),
    },
    text(" "),
    text(switch.description),
    text(" ("),
    row.id(switch.id).highlight(get_highlight_for_switch(switch)) {
      text(switch.cli_prefix),
      text(switch.cli),
    },
    text(")"),
  }
end)

local Option = Component.new(function(option)
  return row.tag("Option").value(option) {
    text(" "),
    row.highlight("NeogitPopupOptionKey") {
      text(option.key_prefix),
      text(option.key),
    },
    text(" "),
    text(option.description),
    text(" ("),
    row.id(option.id).highlight(get_highlight_for_option(option)) {
      text(option.cli_prefix),
      text(option.cli),
      text("="),
      text(option.value or ""),
    },
    text(")"),
  }
end)

local Section = Component.new(function(title, items)
  return col {
    text.highlight("NeogitPopupSectionTitle")(title),
    col(items),
  }
end)

local Config = Component.new(function(props)
  local c = {}

  if not props.state[1].heading then
    table.insert(c, text.highlight("NeogitPopupSectionTitle")("Variables"))
  end

  table.insert(
    c,
    col(map(props.state, function(config)
      if config.heading then
        return row.highlight("NeogitPopupSectionTitle") { text(config.heading) }
      end

      local value
      if config.options then
        value = construct_config_options(config)
      else
        local value_text
        if not config.value or config.value == "" then
          value_text = "unset"
        else
          value_text = config.value
        end

        value = { text.highlight(get_highlight_for_config(config))(value_text) }
      end

      local key
      if config.passive then
        key = " "
      elseif #config.key > 1 then
        key = table.concat(vim.split(config.key, ""), " ")
      else
        key = config.key
      end

      return row.tag("Config").value(config) {
        text(" "),
        row.highlight("NeogitPopupConfigKey") { text(key) },
        text(" " .. config.name .. " "),
        row.id(config.id) { unpack(value) },
      }
    end))
  )

  return col(c)
end)

local Actions = Component.new(function(props)
  return col {
    Grid.padding_left(1) {
      items = props.state,
      gap = 3,
      render_item = function(item)
        if item.heading then
          return row.highlight("NeogitPopupSectionTitle") { text(item.heading) }
        elseif not item.callback then
          return row.highlight("NeogitPopupActionDisabled") {
            text(" "),
            text(item.key),
            text(" "),
            text(item.description),
          }
        else
          return row {
            text(" "),
            text.highlight("NeogitPopupActionKey")(item.key),
            text(" "),
            text(item.description),
          }
        end
      end,
    },
  }
end)

function M:show()
  local mappings = {
    n = {
      ["q"] = function()
        self:close()
      end,
      ["<esc>"] = function()
        self:close()
      end,
      ["<tab>"] = function()
        local stack = self.buffer.ui:get_component_stack_under_cursor()

        for _, x in ipairs(stack) do
          if x.options.tag == "Switch" then
            self:toggle_switch(x.options.value)
            break
          elseif x.options.tag == "Config" then
            self:set_config(x.options.value)
            break
          elseif x.options.tag == "Option" then
            self:set_option(x.options.value)
            break
          end
        end
      end,
    },
  }

  for _, arg in pairs(self.state.args) do
    if arg.id then
      mappings.n[arg.id] = function()
        if arg.type == "switch" then
          self:toggle_switch(arg)
        elseif arg.type == "option" then
          self:set_option(arg)
        end
      end
    end
  end

  for _, config in pairs(self.state.config) do
    -- selene: allow(empty_if)
    if config.heading then
      -- nothing
    elseif not config.passive then
      mappings.n[config.id] = function()
        self:set_config(config)
      end
    end
  end

  for _, group in pairs(self.state.actions) do
    for _, action in pairs(group) do
      -- selene: allow(empty_if)
      if action.heading then
        -- nothing
      elseif action.callback then
        mappings.n[action.key] = function()
          logger.debug(string.format("[POPUP]: Invoking action '%s' of %s", action.key, self.state.name))
          local ret = action.callback(self)
          self:close()
          if type(ret) == "function" then
            ret()
          end
        end
      else
        mappings.n[action.key] = function()
          local notif = require("neogit.lib.notification")
          notif.create(action.description .. " has not been implemented yet", vim.log.levels.WARN)
        end
      end
    end
  end

  local items = {}

  if self.state.config[1] then
    table.insert(items, Config { state = self.state.config })
  end

  if self.state.args[1] then
    local section = {}
    local name = "Arguments"
    for _, item in ipairs(self.state.args) do
      if item.type == "option" then
        table.insert(section, Option(item))
      elseif item.type == "switch" then
        table.insert(section, Switch(item))
      elseif item.type == "heading" then
        if section[1] then -- If there are items in the section, flush to items table with current name
          table.insert(items, Section(name, section))
          section = {}
        end

        name = item.heading
      end
    end

    table.insert(items, Section(name, section))
  end

  if self.state.actions[1] then
    table.insert(items, Actions { state = self.state.actions })
  end

  self.buffer = Buffer.create {
    name = self.state.name,
    filetype = "NeogitPopup",
    kind = config.values.popup.kind,
    mappings = mappings,
    after = function()
      vim.cmd([[setlocal nocursorline]])
      vim.fn.matchadd("NeogitPopupBranchName", self.state.env.highlight or branch.current(), 100)

      if config.values.popup.kind == "split" then
        vim.cmd([[execute "resize" . (line("$") + 1)]])
      end
    end,
    render = function()
      return {
        List {
          separator = "",
          items = items,
        },
      }
    end,
  }
end

return M
