local M = {}

local api = vim.api

local bufrename = require("infra.bufrename")
local fn = require("infra.fn")
local handyclosekeys = require("infra.handyclosekeys")
local jelly = require("infra.jellyfish")("pstree")
local bufmap = require("infra.keymap.buffer")
local listlib = require("infra.listlib")
local prefer = require("infra.prefer")
local subprocess = require("infra.subprocess")

-- used for &foldexpr
-- :h fold-expr
---@return number @fold level
function M.fold(lnum)
  local curline
  do
    local bufnr = api.nvim_get_current_buf()
    local lines = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, true)
    curline = lines[1]
  end

  if #curline == 0 then return 0 end

  local indent = 0
  do
    local index = 1
    local spaces = 0
    while true do
      local char = string.sub(curline, index, index)
      if char == " " then
        spaces = spaces + 1
        if spaces == 4 then
          spaces = 0
          indent = indent + 1
        end
      elseif char == "|" then
        assert(spaces == 2 or spaces == 3)
        local next_char = string.sub(curline, index + 1, index + 1)
        index = index + 1
        if next_char == " " then
          spaces = 0
          indent = indent + 1
        elseif next_char == "-" then
          spaces = 0
          indent = indent + 1
        else
          error(string.format("unreachable: %s%s", char, next_char))
        end
      elseif char == "`" then
        assert(spaces == 2 or spaces == 3)
        local next_char = string.sub(curline, index + 1, index + 1)
        index = index + 1
        if next_char == "-" then
          spaces = 0
          indent = indent + 1
        else
          error(string.format("unreachable: %s%s", char, next_char))
        end
      else
        break
      end
      index = index + 1
    end
  end

  return indent
end

local function rhs_hover()
  local pid
  do
    local line = api.nvim_get_current_line()
    -- blank line, it's possible
    if #line == 0 then return end
    -- a thread
    if string.match(line, "-{[%w-_]+},") ~= nil then return end
    local matched = string.match(line, ",%d+")
    if matched == nil then error(string.format('failed to find pid in line "%s"', line)) end
    pid = tonumber(string.sub(matched, 2))
  end
  assert(pid ~= nil)

  local bufnr = api.nvim_create_buf(false, true)
  prefer.bo(bufnr, "bufhidden", "wipe")

  subprocess.spawn("ps", { args = { "-orss,trs,drs,vsz,cputime,tty,lstart", tostring(pid) } }, function(iter)
    local start = 0
    for lines in fn.batch(iter, 50) do
      local stop = start + #lines
      api.nvim_buf_set_lines(bufnr, start, stop, false, lines)
      start = stop
    end
  end, function(exit_code)
    if exit_code == 0 then return end
    vim.schedule(function() jelly.err("unable to get process info of %d, exit=%d", pid, exit_code) end)
  end)

  local winid
  do
    -- depends on the output of ps
    local width, height = 70, 2
    -- stylua: ignore
    winid = api.nvim_open_win(bufnr, true, {
      relative = "cursor", style = "minimal",
      width = width, height = height, row = 1, col = 0,
    })
    api.nvim_win_set_buf(winid, bufnr)
  end

  handyclosekeys(bufnr)
end

local count = 0

---@param extra table @extra params for pstree command
function M.run(extra)
  extra = extra or {}

  local args = { "-A", "-acnpt" }
  listlib.extend(args, extra)

  count = count + 1

  local bufnr = api.nvim_create_buf(false, true)
  prefer.bo(bufnr, "bufhidden", "wipe")
  bufrename(bufnr, string.format("pstree://%d", count))
  bufmap(bufnr, "n", "K", rhs_hover)

  -- spawn
  subprocess.spawn("/usr/bin/pstree", { args = args }, function(iter)
    local start = 0
    for lines in fn.batch(iter, 50) do
      local stop = start + #lines
      api.nvim_buf_set_lines(bufnr, start, stop, false, lines)
      start = stop
    end
  end, function(exit_code)
    if exit_code == 0 then return end
    vim.schedule(function() jelly.err("unable to get pstree", exit_code) end)
  end)

  -- win setup
  do
    local winid = api.nvim_get_current_win()
    local wo = prefer.win(winid)
    wo.foldenable = true
    wo.foldmethod = "expr"
    wo.foldexpr = [[v:lua.require'pstree'.fold(v:lnum)]]
    api.nvim_win_set_buf(winid, bufnr)
  end
end

return M
