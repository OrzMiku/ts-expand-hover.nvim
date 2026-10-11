# ts-expand-hover.nvim

![ts-expand-hover demo](https://github.com/nemanjamalesija/ts-expand-hover.nvim/raw/61f34bc/assets/demo.gif)

A TypeScript hover for Neovim where you can expand type aliases in place.

The normal hover shows `Props` and stops there. With this plugin you open the hover, press `+` and `Props` turns into the object it stands for. Press it again to go one level deeper, `-` to go back. The float stays where it is and just updates its text.

It uses the `verbosityLevel` hover option TypeScript added in 5.9. It works with vtsls and with the TypeScript 7 server (`tsc --lsp`, also called tsgo).

## Requirements

- Neovim 0.10 or newer
- One of these servers attached to your TypeScript buffers:
  - [vtsls](https://github.com/yioneko/vtsls) 0.2.9 or newer, running TypeScript 5.9 or newer. vtsls 0.3.0 ships with 5.9, so that is the easy route.
  - The TypeScript 7 server, which [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) calls `tsc` (`tsgo` in older versions). It needs one extra capability, see [TypeScript 7 setup](#typescript-7-setup).

## Installation

With lazy.nvim:

```lua
{
  "nemanjamalesija/ts-expand-hover.nvim",
  ft = { "typescript", "typescriptreact" },
  opts = {
    keymaps = { hover = "<leader>th" },
  },
}
```

With any other plugin manager, call `require("ts_expand_hover").setup()` after the plugin loads.

## TypeScript 7 setup

The TypeScript 7 server only tells the plugin whether a type can expand further if the client declares the `experimental.hoverVerbosityLevel` capability. Without it the float opens, but `+` does nothing. Add it to your `tsc` config (Neovim 0.11+ shown):

```lua
-- On older nvim-lspconfig the server is called "tsgo".
-- Use that name here and in vim.lsp.enable().
vim.lsp.config("tsc", {
  capabilities = { experimental = { hoverVerbosityLevel = true } },
  -- Optional. The server cuts long types at 500 characters and shows
  -- "... N more ..." in their place. Raise the cap to see big types whole.
  settings = { ["js/ts"] = { maximumHoverLength = 5000 } },
})
vim.lsp.enable("tsc")
```

TypeScript marks this capability as experimental, so support for the TypeScript 7 server is experimental here too.

## Usage

| Key | Where | What it does |
|-----|-------|--------------|
| `K` | Normal mode | Open the hover |
| `+` or `=` | In the float | Expand one level |
| `-` | In the float | Collapse one level |
| `q` or `Esc` | In the float | Close the float |

The bottom row of the float shows how deep you are and shows `[max]` when there is nothing left to expand. The float closes when you move the cursor in the source buffer.

Below the type you get the documentation and JSDoc tags (`@param`, `@returns`, `@example`). The type itself is highlighted with treesitter.

If no supported server is attached, or the server returns an error, `K` falls back to the built-in `vim.lsp.buf.hover()`. If both vtsls and the TypeScript 7 server are attached, the plugin uses vtsls.

## Configuration

These are the defaults. `setup()` with no arguments gives you exactly this:

```lua
require("ts_expand_hover").setup({
  keymaps = {
    hover    = "K",
    expand   = "+",  -- = works too
    collapse = "-",
    close    = { "q", "<Esc>" },
  },
  float = {
    border     = "rounded",  -- "rounded", "single", "double", "none"
    max_width  = 80,
    max_height = 30,
  },
})
```

Set a keymap to `false` and the plugin won't register it. This is handy if something else already uses `K` and you only want the plugin's hover in TypeScript files:

```lua
require("ts_expand_hover").setup({
  keymaps = { hover = false },
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "typescript", "typescriptreact" },
  callback = function(ev)
    vim.keymap.set("n", "K", require("ts_expand_hover").hover, {
      buffer = ev.buf,
      desc = "TypeScript expandable hover",
    })
  end,
})
```

## Troubleshooting

Start with `:checkhealth ts_expand_hover`, with a TypeScript file open so the server has attached. It shows your Neovim version, which server is attached and its TypeScript version, and for the TypeScript 7 server whether the capability is declared.

You get the standard LSP hover instead of this one: no supported server is attached to the buffer.

`+` does nothing: either the bottom row says `[max]`, vtsls is running a TypeScript older than 5.9, or the TypeScript 7 server is missing the capability from [TypeScript 7 setup](#typescript-7-setup).

A type ends in `... N more ...`: the TypeScript 7 server cut it at `maximumHoverLength`. Raise that setting, also shown in [TypeScript 7 setup](#typescript-7-setup).

## How it works

Both servers accept a `verbosityLevel` with the hover request and answer whether the type can expand further. `K` asks for level 0, `+` and `-` ask again one level up or down and the plugin swaps the text in the float.

With vtsls the request goes through `workspace/executeCommand` as a `typescript.tsserverRequest` for tsserver's `quickinfo` command. With the TypeScript 7 server it is a plain `textDocument/hover` request with `verbosityLevel` added.

## Tests

```sh
make test
```

Needs Neovim and [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). The tests run headless and don't need a language server.

## License

MIT
