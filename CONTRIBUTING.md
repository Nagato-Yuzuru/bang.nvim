# Contributing

Not filing a pull request? Bugs and feature requests go through the issue forms,
not a blank issue.

With [mise](https://mise.jdx.dev) installed, `mise install` fetches the tools,
`prek` among them, and `prek install` wires `.pre-commit-config.yaml` in as the
pre-commit hook. `mise run check` runs what CI runs:

- `mise run lint`: runs stylua, selene, dprint, actionlint and the file checks in
  `.pre-commit-config.yaml`, fixing in place. It exits 1 when a file changed.
  Forget to run it and autofix.ci pushes the fixes onto the pull request as a
  `style:` commit; pull before you push again.
- `mise run docs`: regenerates `doc/tags` and fails on a duplicate or malformed
  help tag.
- `mise run test`: runs the mini.test suite, headless, against the mini.nvim tag
  pinned in `tests/minimal_init.lua`. CI runs it on Neovim 0.11.0, stable and
  nightly; nightly reports but never blocks. One file while you work:
  `nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('tests/test_operator.lua')"`.

Tests drive the plugin through its public contract only: `require("bang")`, the
`<Plug>` mappings, `:Bang` and `vim.g.bang`, always from a child Neovim. A test
that names an internal module is testing the wrong thing.

`mise run demo` re-renders the GIFs in `demo/` from their tapes. It needs vhs,
ttyd and ffmpeg, and clones screenkey.nvim into `.deps/` to draw the keys into
the recording. One GIF per claim. A scene that shows two things is two scenes.

Name your branch `type/topic` and title the pull request `type: subject`, with
`type` one of `feat`, `fix`, `docs`, `refactor`, `test`, `ci` or `chore`. A pull
request squash-merges with its title as the commit subject, so write the title
as the commit you want.
