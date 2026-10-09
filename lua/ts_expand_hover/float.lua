--- Float lifecycle module for ts-expand-hover.nvim.
--- Handles open, in-place update, auto-close autocmds, and buffer-local keymaps.

local M = {}

--- Return display width for text.
---@param text string
---@return integer
local function _display_width(text)
  return vim.fn.strdisplaywidth(text)
end

--- Truncate text so display width is <= max_width.
---@param text string
---@param max_width integer
---@return string
local function _truncate_to_width(text, max_width)
  if max_width <= 0 then return "" end
  if _display_width(text) <= max_width then return text end
  local chars = vim.fn.strchars(text)
  while chars > 0 do
    local candidate = vim.fn.strcharpart(text, 0, chars)
    if _display_width(candidate) <= max_width then
      return candidate
    end
    chars = chars - 1
  end
  return ""
end

--- Build hint row variants ordered from most to least descriptive.
---@param state table Session state with verbosity and can_expand fields
---@return string[]
local function _build_hint_variants(state)
  local can_expand = state.can_expand
  local at_min     = state.verbosity == 0

  local expand_full
  if can_expand then
    expand_full = "[+] expand"
  else
    expand_full = "[max]"
  end

  local collapse_full
  if at_min then
    collapse_full = "[-]"
  else
    collapse_full = "[-] collapse"
  end

  local full = string.format(
    " depth: %d  %s  %s  [q] close",
    state.verbosity,
    expand_full,
    collapse_full
  )
  local medium = string.format(
    " d:%d  %s  [-]  [q]",
    state.verbosity,
    can_expand and "[+]" or "[max]"
  )
  local minimal = string.format(" d:%d", state.verbosity)
  return { full, medium, minimal }
end

--- The markdown highlight query hides fence lines, so the cursor never belongs on one.
---@param line string
---@return boolean
local function _is_fence(line)
  return line:match("^%s*```") ~= nil
end

--- Content gets one column of padding on the left, like the noice hover does.
---@param lines string[]
---@return string[]
local function _pad(lines)
  local padded = {}
  for i, line in ipairs(lines) do
    if line == "" then
      padded[i] = ""
    else
      padded[i] = " " .. line
    end
  end
  return padded
end

--- Index of the next line in direction dir (1 or -1) that is not a fence, or nil at the edge.
---@param lines string[]
---@param from integer
---@param dir integer
---@return integer|nil
local function _next_visible_line(lines, from, dir)
  local i = from + dir
  while lines[i] and _is_fence(lines[i]) do
    i = i + dir
  end
  if lines[i] then return i end
  return nil
end

--- Cursor position for freshly written content: the first visible line, on its first character.
---@param lines string[]
---@return integer[]
local function _start_cursor(lines)
  local row = _next_visible_line(lines, 0, 1) or 1
  return { row, 1 }
end

local HINT_NS = vim.api.nvim_create_namespace("ts_expand_hover_hints")

--- Draw the hint row as the last two rows inside the float, like the action
--- row at the bottom of the VS Code hover: a separator line and the hints,
--- both in the border colour so they read as chrome. Comment would be the
--- other muted choice, but themes often draw it in italics, which looks
--- bigger than the code. Virtual lines are not buffer text, so the markdown
--- parser and the cursor never touch them. They hang off the last visible
--- line: a concealed fence line takes its virtual lines down with it.
---@param bufnr integer
---@param lines string[]
---@param width integer
---@param hint_text string
local function _write_hints(bufnr, lines, width, hint_text)
  local last_visible = _next_visible_line(lines, #lines + 1, -1) or #lines
  vim.api.nvim_buf_clear_namespace(bufnr, HINT_NS, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, HINT_NS, last_visible - 1, 0, {
    virt_lines = {
      { { string.rep("─", width), "FloatBorder" } },
      { { hint_text, "FloatBorder" } },
    },
  })
end

--- Apply treesitter markdown highlighting to the given buffer.
--- Called after every content write. pcall guards against missing markdown parser.
---@param bufnr integer
local function _apply_treesitter(bufnr)
  pcall(vim.treesitter.start, bufnr, "markdown")
end

--- Return the maximum display width of a list of lines.
---@param lines string[]
---@return integer
local function _max_line_width(lines)
  local max = 1
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > max then
      max = w
    end
  end
  return max
end

--- Compute window width and the best hint row variant for it.
--- The window is as wide as the content up to max_width, plus one column so
--- unwrapped lines do not touch the right border. The most descriptive hint
--- row that fits in max_width wins, widening the window when the content is narrower.
---@param lines string[]
---@param state table
---@param cfg table
---@return integer width
---@return string hint_text
local function _compute_layout(lines, state, cfg)
  local max_width = math.max(1, cfg.max_width)
  local width = math.min(max_width, _max_line_width(lines) + 1)
  local variants = _build_hint_variants(state)

  local chosen_hint = variants[#variants]
  for _, hint in ipairs(variants) do
    if _display_width(hint) + 1 <= max_width then
      chosen_hint = hint
      width = math.max(width, _display_width(hint) + 1)
      break
    end
  end

  if _display_width(chosen_hint) > width then
    chosen_hint = _truncate_to_width(chosen_hint, width)
  end

  return width, chosen_hint
end

--- Apply the width, then the height the content needs at that width.
--- Fence lines are concealed, long lines wrap and the hint rows are virtual,
--- so the raw line count is wrong in every direction. The window itself
--- reports the drawn rows, but only once it has its final width, hence two
--- writes. Read-then-write keeps relative and the other fields (NeoVim #31992).
---@param win integer
---@param width integer
---@param cfg table
local function _fit_window(win, width, cfg)
  local existing = vim.api.nvim_win_get_config(win)
  existing.width  = width
  vim.api.nvim_win_set_config(win, existing)

  local drawn_rows = vim.api.nvim_win_text_height(win, {}).all
  existing.height = math.min(cfg.max_height, drawn_rows)
  vim.api.nvim_win_set_config(win, existing)
end

--- Hide the markdown fence lines and the language label.
--- The runtime markdown highlight query conceals them, but only when the
--- window has conceallevel 2. The float is focused in normal mode, so without
--- "n" in concealcursor the cursor line would show its raw fence again.
---@param win integer
local function _apply_conceal(win)
  vim.wo[win].conceallevel  = 2
  vim.wo[win].concealcursor = "n"
end

--- Long lines wrap like in the built-in hover. linebreak wraps between words
--- instead of inside one, and breakindent keeps the wrapped part under the
--- one column of padding.
---@param win integer
local function _apply_wrap(win)
  vim.wo[win].wrap        = true
  vim.wo[win].linebreak   = true
  vim.wo[win].breakindent = true
end

--- Open a new focused floating window with the given content.
---@param lines string[]
---@param hint_text string
---@param width integer
---@param state table
---@param cfg table float config (border, max_width, max_height)
---@return integer win, integer buf
local function _open(lines, hint_text, width, state, cfg)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].modifiable = true

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  _apply_treesitter(buf)
  _write_hints(buf, lines, width, hint_text)

  local win = vim.api.nvim_open_win(buf, true, {
    relative   = "cursor",
    width      = width,
    height     = math.min(cfg.max_height, #lines),
    row        = 1,
    col        = 0,
    style      = "minimal",
    border     = cfg.border,
    focusable  = true,
  })
  _apply_wrap(win)
  _apply_conceal(win)
  _fit_window(win, width, cfg)
  vim.api.nvim_win_set_cursor(win, _start_cursor(lines))

  state.float_bufnr = buf
  state.float_winid = win

  return win, buf
end

--- Update an existing float in-place without closing and reopening.
---@param lines string[]
---@param hint_text string
---@param width integer
---@param state table
---@param cfg table
local function _update(lines, hint_text, width, state, cfg)
  local buf = state.float_bufnr
  local win = state.float_winid

  if not vim.api.nvim_win_is_valid(win) then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  _apply_treesitter(buf)
  _write_hints(buf, lines, width, hint_text)

  _fit_window(win, width, cfg)

  -- Reset scroll to top after content change.
  vim.api.nvim_win_set_cursor(win, _start_cursor(lines))
end

--- Register CursorMoved and BufLeave autocmds on the source buffer.
--- The autocmds auto-close the float when focus returns to the source buffer.
--- Guard prevents premature close when the float itself is focused (NeoVim #12923).
---@param winid integer float window ID
---@param source_bufnr integer source buffer number
---@param state table
local function _setup_close_autocmds(winid, source_bufnr, state)
  local augroup_name = "ts_expand_hover_" .. winid
  local augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
    group  = augroup,
    buffer = source_bufnr,
    callback = function()
      -- When enter=true, opening the float fires CursorMoved on the source
      -- buffer. Guard prevents the float from closing itself immediately.
      if vim.api.nvim_get_current_win() == winid then
        return
      end
      M.close(state)
    end,
  })
end

--- Bind buffer-local keymaps to close, expand, and collapse the float.
--- Keys are read from config; any key set to false is skipped entirely.
--- on_expand and on_collapse are closures provided by init.lua; nil = not registered.
---@param bufnr integer float buffer number
---@param state table
---@param on_expand function|nil callback for expand keymap
---@param on_collapse function|nil callback for collapse keymap
local function _setup_keymaps(bufnr, state, on_expand, on_collapse)
  --- Normalize a key config into a list of concrete mappings.
  --- The default + also answers to = (same key without shift) and both
  --- defaults answer to the numpad keys.
  ---@param key string|string[]
  ---@return string[]
  local function key_list(key)
    if type(key) == "table" then return key end
    if key == "+" then return { "+", "=", "<kPlus>" } end
    if key == "-" then return { "-", "<kMinus>" } end
    return { key }
  end

  local km    = require("ts_expand_hover.config").get().keymaps
  local close = function() M.close(state) end

  if km.close ~= false then
    for _, key in ipairs(key_list(km.close)) do
      vim.keymap.set("n", key, close, { buffer = bufnr, nowait = true, silent = true })
    end
  end

  if on_expand and km.expand ~= false then
    for _, key in ipairs(key_list(km.expand)) do
      vim.keymap.set("n", key, function() on_expand() end, { buffer = bufnr, nowait = true, silent = true })
    end
  end

  if on_collapse and km.collapse ~= false then
    for _, key in ipairs(key_list(km.collapse)) do
      vim.keymap.set("n", key, function() on_collapse() end, { buffer = bufnr, nowait = true, silent = true })
    end
  end

  -- Plain j and k step onto the hidden fence lines, where a press looks dead.
  local function step(dir)
    local win    = state.float_winid
    local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local target = _next_visible_line(lines, cursor[1], dir)
    if target then
      -- Column 1 is the first character after the padding.
      vim.api.nvim_win_set_cursor(win, { target, 1 })
    end
  end
  vim.keymap.set("n", "j", function() step(1) end,  { buffer = bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "k", function() step(-1) end, { buffer = bufnr, nowait = true, silent = true })
end

--- Open a focused float or update the existing one in-place.
--- Entry point called from init.lua on every LSP response.
---@param hover { lines: string[], can_expand: boolean } normalized answer built by lsp.lua
---@param state table Session state
---@param on_expand function|nil callback fired when user presses + inside the float
---@param on_collapse function|nil callback fired when user presses - inside the float
function M.show(hover, state, on_expand, on_collapse)
  local cfg   = require("ts_expand_hover.config").get().float
  local lines = _pad(hover.lines)

  -- Store can_expand in state so expand/collapse handlers can read it without
  -- needing a reference to the hover table.
  state.can_expand = hover.can_expand

  local width, hint = _compute_layout(lines, state, cfg)

  if state.float_winid and vim.api.nvim_win_is_valid(state.float_winid) then
    _update(lines, hint, width, state, cfg)
  else
    -- Capture source window before focus moves into the float.
    state.source_winid = vim.api.nvim_get_current_win()
    local win, buf = _open(lines, hint, width, state, cfg)
    _setup_close_autocmds(win, state.source_bufnr, state)
    _setup_keymaps(buf, state, on_expand, on_collapse)
  end
end

--- Close the float window, clean up autocmds, and restore source focus.
--- Nils state handles before closing to prevent re-entrant calls.
---@param state table Session state
function M.close(state)
  local win    = state.float_winid
  local source = state.source_winid

  -- Nil state first — prevents re-entrant close if autocmd fires during close.
  state.float_winid  = nil
  state.float_bufnr  = nil
  state.source_winid = nil

  if win then
    pcall(vim.api.nvim_del_augroup_by_name, "ts_expand_hover_" .. win)
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if source and vim.api.nvim_win_is_valid(source) then
    vim.api.nvim_set_current_win(source)
  end
end

return M
