# mrreview.nvim

GitLab の Merge Request (MR) を、Neovim の実バッファとネイティブ diff のままレビューするプラグインです。
画面を専用 UI へ切り替えないので、レビュー中も LSP や DAP をそのまま使えます。

## 機能

- 変更ファイルを順に開き、ネイティブ diff で表示します。
- `git diff` の差分だけでもレビューできます。MR があれば `glab` 経由で自動的に関連付けます。
- MR のコメントを差分上に表示し、投稿、返信、resolve、削除ができます。
- draft を溜めて一括で公開できます。
- 確認済みにしたファイルを記憶します。差分が変わると確認済みは無効になります。
- プロジェクトの境界とテストかどうかからレビュー単位を自動で作り、絞り込めます。
- ローカルの HEAD と MR のずれを検出し、statusline 用の情報として返します。

## 必要なもの

- Neovim 0.12 以上。動作確認は v0.12.5 で行っています。
- `git`
- [glab](https://gitlab.com/gitlab-org/cli)。MR 連携に使い、認証は `glab` 側に任せます。
- [fzf-lua](https://github.com/ibhagwan/fzf-lua)。`:MrReviewScope` と `:MrReviewFiles` の一覧に使います。

## 導入

lazy.nvim では次のように書きます。

```lua
{
    "piplupflipper/mrreview.nvim",
    dependencies = { "ibhagwan/fzf-lua" },
    opts = {},
}
```

他のプラグインマネージャでは `lua/` を runtimepath に載せたうえで、`require("mrreview").setup({})` を呼びます。
コマンドは `setup()` が登録します。

## 使い方

`:MrReview` で開始し、`<Tab>` と `]c` で移動して、`<leader>x` で確認済みにして閉じます。

| コマンド | 内容 |
|---|---|
| `:MrReview [base] [--dir <dir>]` | レビューを開始する。`!` を付けると確認済みも表示する |
| `:MrReviewScope` | レビュー単位を選んで開始または切り替える |
| `:MrReviewFiles` | 変更ファイルの一覧から選ぶ |
| `:MrReviewNext`、`:MrReviewPrev` | 次、前の変更ファイルへ移動する |
| `:MrReviewDiff` | diff 表示を現在のバッファに同期する |
| `:MrReviewFold` | 未変更行の折りたたみを切り替える |
| `:MrReviewClose` | 現在のファイルを閉じる。MR 連携時は確認済みとして記録する |
| `:MrReviewed`、`:MrReviewedClear` | 確認済みを個別に解除する、すべて解除する |
| `:MrReviewOff` | レビューを終了する |
| `:MrComment` | カーソル行または選択範囲にコメントを投稿する |
| `:MrPeek` | カーソル行のコメントをポップアップで読む |
| `:MrThread` | カーソル行の discussion を開く |
| `:MrNotes` | 行に紐づかない MR 全体のコメントを開く |
| `:MrDraftToggle`、`:MrDraftPublish`、`:MrDraftDiscard` | draft の切り替え、一括公開、全破棄 |

base を省略すると、MR の base を使います。
MR も無いときは `develop`、`main`、`master` の順に探します。

## 設定

```lua
require("mrreview").setup({
    -- diff から自動で作る単位に加えて選べるレビュー単位
    scopes = {
        {
            kind = "layer", -- project、subtree、layer、entrypoint、test、test-layer のいずれか
            name = "domain",
            description = "domain 層",
            patterns = { "backend/app/domain/**", "**/backend/app/domain/**" },
        },
    },
    -- プロジェクトの境界とみなすファイル。省略時は pyproject.toml、package.json、Cargo.toml など
    scope_markers = nil,
    -- レビュー対象のバッファにだけ張るキー。値は文字列か文字列の配列で、false なら割り当てない
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

上の `keymaps` の値は既定値です。

## statusline

`require("mrreview").status()` は、レビュー中なら `{ text, label, hl }` を返し、それ以外では `nil` を返します。
遅延読み込みしている場合は `package.loaded["mrreview"]` を確認してから呼ぶと、statusline の描画でプラグインを読み込まずに済みます。

## テスト

```sh
nvim --headless -u NONE -l tests/run.lua
```

## ライセンス

MIT
