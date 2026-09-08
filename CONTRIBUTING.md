# Contributing

Bugs and feature requests go through the issue forms. Everything below is for a
pull request.

## Setup

[mise](https://mise.jdx.dev) installs the tools at the versions CI uses:

```sh
mise install
prek install
```

The second line makes every commit run the same checks as `mise run lint`.

## Checks

`mise run check` runs the three tasks CI runs:

| Task | What it does |
| - | - |
| `mise run lint` | stylua, selene, dprint, actionlint and the file checks in `.pre-commit-config.yaml`, fixing in place. Exits 1 when a file changed. |
| `mise run docs` | Rebuilds `doc/tags`. Fails on a duplicate or malformed help tag. |
| `mise run test` | The mini.test suite, headless, on the mini.nvim tag pinned in `tests/minimal_init.lua`. |

CI runs the suite on Neovim 0.11.0, stable and nightly. Nightly reports but never
blocks. If a pull request arrives unformatted, autofix.ci pushes the fixes onto
it as a `style:` commit; pull before you push again.

One test file while you work:

```sh
nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('tests/test_operator.lua')"
```

## Tests

Tests drive the plugin through its public contract only: `require("bang")`, the
`<Plug>` mappings, `:Bang` and `vim.g.bang`, always from a child Neovim. A test
that names an internal module is testing the wrong thing.

## Demos

`mise run demo` re-renders the GIFs in `demo/` from their tapes. It needs vhs,
ttyd and ffmpeg, and clones screenkey.nvim into `.deps/` to draw the keys into
the recording. One GIF per claim: a scene that shows two things is two scenes.

## Pull requests

Name the branch `type/topic` and title the pull request `type: subject`, with
`type` one of `feat`, `fix`, `docs`, `refactor`, `test`, `ci` or `chore`. The
pull request squash-merges with its title as the commit subject, and the release
notes are built from those subjects, so write the title as the changelog line
you want. `mise run notes` shows the notes the next tag would get.
