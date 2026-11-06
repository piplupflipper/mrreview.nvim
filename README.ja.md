# mrreview.nvim 💅✨

[English](README.md) | **日本語**

GitLab の Merge Request (MR) を、Neovim の実バッファとネイティブ diff のままレビューできちゃうプラグインだよ💖✨  
専用 UI に画面を切り替えないから、レビュー中も LSP や DAP がそのまま使えるの🔥

## 🌈 できること

- 📂 変更ファイルを順番に開いて、ネイティブ diff で見せるよ。
- 🧩 `git diff` の差分だけでもレビューできちゃう！MR があれば `glab` 経由で勝手に関連付けてくれるよ🔗
- 💬 MR のコメントを差分の上に出して、投稿、返信、resolve、削除までできるよ。
- 📝 draft を溜めといて、まとめて一気に公開できるよ🚀
- ✅ 確認済みにしたファイルを覚えてるよ。差分が変わったら確認済みは無効になるからズルはできないよ〜🙅‍♀️
- 🗂️ プロジェクトの境界とテストかどうかから、レビュー単位を自動で作って絞り込めるよ。
- 🕵️‍♀️ ローカルの HEAD と MR がずれてたら見つけて、statusline 用の情報として返すよ。

## 🛍️ 必要なもの

- Neovim 0.12 以上。動作確認は v0.12.5 でやってるよ🧪
- `git`
- [glab](https://gitlab.com/gitlab-org/cli)。MR 連携に使うよ。認証は `glab` におまかせ🔐
- [fzf-lua](https://github.com/ibhagwan/fzf-lua)。`:MrReviewScope` と `:MrReviewFiles` の一覧に使うよ🔍

## 📦 導入

lazy.nvim ならこれだけ！🍋

```lua
{
    "piplupflipper/mrreview.nvim",
    dependencies = { "ibhagwan/fzf-lua" },
    opts = {},
}
```

他のプラグインマネージャなら、`lua/` を runtimepath に載せてから `require("mrreview").setup({})` を呼んでね。  
コマンドは `setup()` が登録するから、忘れないでね🥺

## 🎀 使い方

`:MrReview` で始めて、`<Tab>` と `]c` で移動して、`<leader>x` で確認済みにして閉じる！これだけ💅

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

base を省略したら MR の base を使うよ🎯  
MR も無いときは `develop`、`main`、`master` の順に探すよ。

## ⚙️ 設定

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

上の `keymaps` の値が既定値だよ⌨️✨

## 📊 statusline

`require("mrreview").status()` は、レビュー中なら `{ text, label, hl }` を返して、それ以外は `nil` を返すよ。  
遅延読み込みしてるなら、`package.loaded["mrreview"]` を確認してから呼んでね。statusline の描画でプラグインを読み込まずに済むよ💡

## 🧪 テスト

```sh
nvim --headless -u NONE -l tests/run.lua
```

## 📜 ライセンス

MIT 💖
