# SumSpec in Neovim

Neovim (0.11+) runs `sumspec lsp` for files ending in `.sumspec`. It shows
the parse error, or every error and warning of the checker, as you edit.

1. Install `sumspec` so it's on your `PATH` (see `DEVELOPMENT.md`):

   ```
   cabal install exe:sumspec
   ```

2. Add this to your config (`init.lua`):

   ```lua
   vim.filetype.add({ extension = { sumspec = "sumspec" } })

   vim.lsp.config("sumspec", {
     cmd = { "sumspec", "lsp" },
     filetypes = { "sumspec" },
     root_markers = { ".git" },
   })
   vim.lsp.enable("sumspec")
   ```

3. Open a spec, such as `example/drone.sumspec`. `:checkhealth vim.lsp`
   shows whether the server is attached.

The server logs to stderr, which Neovim writes to its LSP log
(`:lua vim.cmd.edit(vim.lsp.get_log_path())`).

There's no syntax highlighting yet: semantic tokens and a fallback Vim
syntax file come later (see `docs/lsp.md`).
