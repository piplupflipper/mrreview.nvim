# mrreview.nvim 💅✨

**English** | [日本語](README.ja.md)

This plugin lets you review GitLab Merge Requests (MRs) right inside Neovim, using real buffers and native diff mode 💖✨  
No switching to some special UI, sooo your LSP and DAP keep working the whole time you review 🔥

## 🌈 What it can do

- 📂 Opens the changed files one by one and shows them in native diff.
- 🧩 Works with just a plain `git diff` too! If there's an MR, it hooks it up automatically through `glab` 🔗
- 💬 Shows MR comments right on the diff, and you can post, reply, resolve, and delete them.
- 📝 Stack up drafts and publish them all at once 🚀
- ✅ Remembers which files you marked as reviewed. If the diff changes, that mark gets reset (no cheating lol 🙅‍♀️)
- 🗂️ Builds review scopes automatically from project boundaries and whether a file is a test, so you can narrow things down.
- 🕵️‍♀️ Detects when your local HEAD and the MR drift apart, and returns that info for your statusline.

## 🛍️ Requirements

- Neovim 0.12 or newer. Tested on v0.12.5 🧪
- `git`
- [glab](https://gitlab.com/gitlab-org/cli). Used for the MR integration, and auth is left to `glab` 🔐
- [fzf-lua](https://github.com/ibhagwan/fzf-lua). Used for the lists in `:MrReviewScope` and `:MrReviewFiles` 🔍

## 📦 Install

With lazy.nvim, it's just this 🍋

```lua
{
    "piplupflipper/mrreview.nvim",
    dependencies = { "ibhagwan/fzf-lua" },
    opts = {},
}
```

With other plugin managers, put `lua/` on your runtimepath and call `require("mrreview").setup({})`.  
`setup()` is what registers the commands, so don't skip it okay? 🥺

## 🎀 Usage

Start with `:MrReview`, move around with `<Tab>` and `]c`, then hit `<leader>x` to mark the file reviewed and close it 💅

| Command | What it does |
|---|---|
| `:MrReview [base] [--dir <dir>]` | Start a review. Add `!` to also show reviewed files |
| `:MrReviewScope` | Pick a review scope to start or switch to |
| `:MrReviewFiles` | Pick from the list of changed files |
| `:MrReviewNext`, `:MrReviewPrev` | Go to the next / previous changed file |
| `:MrReviewDiff` | Sync the diff view to the current buffer |
| `:MrReviewFold` | Toggle folding of unchanged lines |
| `:MrReviewClose` | Close the current file. With an MR, it's recorded as reviewed |
| `:MrReviewed`, `:MrReviewedClear` | Unmark one file as reviewed / unmark everything |
| `:MrReviewOff` | End the review |
| `:MrComment` | Post a comment on the cursor line or the selected range |
| `:MrPeek` | Read the comments on the cursor line in a popup |
| `:MrThread` | Open the discussion on the cursor line |
| `:MrNotes` | Open the MR-wide comments that aren't tied to a line |
| `:MrDraftToggle`, `:MrDraftPublish`, `:MrDraftDiscard` | Toggle drafts, publish them all, discard them all |

If you leave out base, it uses the MR's base 🎯  
If there's no MR either, it looks for `develop`, `main`, then `master`, in that order.

## ⚙️ Config

```lua
require("mrreview").setup({
    -- Extra review scopes you can pick, on top of the ones built automatically from the diff
    scopes = {
        {
            kind = "layer", -- one of project, subtree, layer, entrypoint, test, test-layer
            name = "domain",
            description = "domain layer",
            patterns = { "backend/app/domain/**", "**/backend/app/domain/**" },
        },
    },
    -- Files that mark a project boundary. Defaults to pyproject.toml, package.json, Cargo.toml, etc.
    scope_markers = nil,
    -- Keys mapped only on buffers under review. A string or a list of strings; false means no mapping
    keymaps = {
        next_file = { "<Tab>", "]r" },
        prev_file = { "<S-Tab>", "[r" },
        next_hunk = "]c",
        prev_hunk = "[c",
        close_file = "<leader>x",
        toggle_folds = "<leader>z",
        peek = "<leader>mc",
        notes = "<leader>mn",
        help = "<leader>m?",
    },
})
```

The `keymaps` values above are the defaults ⌨️✨

## 📊 statusline

`require("mrreview").status()` returns `{ text, label, hl }` while you're reviewing, and `nil` otherwise.  
If you lazy-load the plugin, check `package.loaded["mrreview"]` before calling it, so drawing the statusline doesn't load the plugin for no reason 💡

## 🧪 Tests

```sh
nvim --headless -u NONE -l tests/run.lua
```

## 📜 License

MIT 💖
