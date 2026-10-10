--- Public API surface for ts-expand-hover.nvim.
--- All mutable session state lives here; sub-modules are stateless.

local M = {}

local config = require("ts_expand_hover.config")
local lsp    = require("ts_expand_hover.lsp")
local float  = require("ts_expand_hover.float")

-- Centralized session state. Sub-modules receive a reference to this table.
local state = {
  verbosity    = 0,
  generation   = 0,     -- monotonic counter for stale response rejection
  source_bufnr = nil,
  source_pos   = nil,   -- { row, col } captured in M.hover() for re-requests
  can_expand   = false, -- set by float.show() from hover.can_expand
  requesting   = false, -- concurrent request guard (EXPN-07)
  float_winid  = nil,   -- set by float.show()
  float_bufnr  = nil,   -- set by float.show()
  source_winid = nil,   -- for focus restore on float close (Phase 2+)
}

--- Return the session state table.
--- Sub-modules use this to read and update state without owning it.
---@return table
function M.get_state()
  return state
end

--- Initialize the plugin with user options.
--- Compatible with lazy.nvim `opts` table convention.
--- Registers the hover keymap from config unless keymaps.hover is false.
---@param opts table|nil
---@return table M for chaining
function M.setup(opts)
  config.setup(opts)
  local keymaps = config.get().keymaps
  if keymaps.hover ~= false then
    vim.keymap.set("n", keymaps.hover, function() M.hover() end, { desc = "TypeScript expandable hover" })
  end
  return M
end

local _do_expand, _do_collapse

--- Ask the server for the type at state.verbosity and show the answer.
--- Each request gets a new generation number; an answer whose number is no
--- longer the current one belongs to a superseded request and is dropped.
local function request_hover()
  state.generation = state.generation + 1
  local gen = state.generation

  lsp.request({
    bufnr     = state.source_bufnr,
    row       = state.source_pos[1],
    col       = state.source_pos[2],
    verbosity = state.verbosity,
    state     = state,
    callback  = function(hover)
      vim.schedule(function()
        if state.generation ~= gen then return end
        float.show(hover, state, _do_expand, _do_collapse)
      end)
    end,
  })
end

--- Expand the current type one verbosity level.
--- Silent no-op when at max expansion or when a request is already in-flight.
_do_expand = function()
  -- EXPN-05: silent no-op when the server said the type cannot expand further.
  if not state.can_expand then return end
  -- EXPN-07: drop if a request is already in-flight.
  if state.requesting then return end

  state.verbosity = state.verbosity + 1
  request_hover()
end

--- Collapse the current type one verbosity level.
--- Silent no-op when already at depth 0 or when a request is already in-flight.
_do_collapse = function()
  -- EXPN-06: silent no-op when verbosity is already at minimum.
  if state.verbosity == 0 then return end
  -- EXPN-07: drop if a request is already in-flight.
  if state.requesting then return end

  state.verbosity = state.verbosity - 1
  request_hover()
end

--- Trigger expandable hover at the current cursor position.
--- Asks the attached TypeScript server (vtsls or tsc) for the hover; falls back
--- to vim.lsp.buf.hover() when none is attached or the server cannot answer
--- (COMP-01, COMP-02).
function M.hover()
  state.source_bufnr = vim.api.nvim_get_current_buf()
  state.verbosity    = 0

  local cursor = vim.api.nvim_win_get_cursor(0)
  -- nvim_win_get_cursor returns { row, col } where row is 1-indexed.
  -- Convert to 0-indexed row; lsp.lua adds 1 back for tsserver.
  -- Capture position for expand/collapse re-requests targeting the same symbol.
  state.source_pos = { cursor[1] - 1, cursor[2] }

  -- A new hover starts a new session, so a request still in flight no longer
  -- matters: its answer fails the generation check. Clearing the flag here
  -- also recovers from a server that died without answering.
  state.requesting = false

  request_hover()
end

return M
