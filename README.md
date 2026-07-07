# Challenge2026 Launcher

:coconut: 這是 [Challenge 2026](https://github.com/CSIE-Challenge/Challenge2026) 的 Launcher，會自動更新並開啟遊戲。

## 功能 Feature

- Launcher 每次啟動都會檢查最新版本；已是最新版就不會重新下載
- 確認並解壓縮遊戲檔案
- 自動啟動遊戲

## 如何使用 How to use

到 Repo 的 [Releases page](https://github.com/CSIE-Challenge/Challenge2026-Launcher/releases) 頁面，下載對應 OS 的檔案。

- 第一次下載會比較久
- 若把 `GameBuilds/` 資料夾刪掉，下次啟動 Launcher 後便會全部重新下載

> [!Note]
> - 執行 Launcher 需要網路連線
> - 由於遊戲執行後會產生一些檔案，請先開個資料夾，並將執行檔放到資料夾底下，再開始執行。


## 疑難排解 Troubleshooting

| 訊息 | 原因 / 處理 |
|---|---|
| `Failed to fetch release data: ...` | 無網路，或 GitHub API rate limit，請稍等再試。 |
| `Download failed: ...` | 下載中斷。請刪掉 `GameBuilds/` 重開 launcher。 |
| `Game executable not found at: ...` | 下載或解壓失敗。刪掉 `GameBuilds/` 重開 launcher。 |
