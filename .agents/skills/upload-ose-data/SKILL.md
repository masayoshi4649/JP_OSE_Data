---
name: upload-ose-data
description: JP_OSE_Data の future/ と op/ のデータを GitHub にアップロードするときに使用する。JSONL の gzip 圧縮、原本との照合、対象を限定したコミット、プッシュと反映確認を行う。
---

# 取引データのアップロード

このリポジトリのデータを、元ファイルを保持して GitHub に反映する。会話、説明、コミットメッセージは日本語にする。

## 対象と保存形式

- `future/`：NK225・TOPIX の板情報とローソク足。
- `op/`：銘柄ごとのオプションデータ。
- `.jsonl` はローカルに残し、同じディレクトリの `.jsonl.gz` を登録する。
- `.csv` はバイト列を変えずに登録する。
- 原本のない既存 `.jsonl.gz` も保持する。原本がないことを削除指示として扱わない。
- 既存の送信先は `https://github.com/masayoshi4649/JP_OSE_Data` の `origin/main`。実行時の設定とユーザー指定を確認し、無断で送信先やブランチを変更しない。

ユーザーのアップロード依頼はコミットとプッシュを含む。既に承認された送信先への通常の反映に再確認は不要。手順説明や準備だけの依頼では、その範囲にとどめる。

## 実行前の確認

リポジトリルートで `git status --short --branch`、`git remote -v`、`git diff --cached --name-only` を確認し、既存の作業と今回の対象を区別する。アップロードする場合は `git fetch origin` でリモートの進行も確認する。未送信コミットがあれば、その内容も今回の送信範囲に含まれることを確認する。

`git ls-files -- 'future/**/*.jsonl' 'op/**/*.jsonl'` で、原本が既に追跡されていないことも確認する。追跡済み原本は `.gitignore` では除外できないため、以下の通常手順をそのまま進めない。原本をローカルに保持して追跡から外す移行を準備し、過去のコミットに大容量ファイルが残る場合は履歴への対応も検討する。既存履歴を無断で書き換えない。

`.gitignore` と `.gitattributes` は既存設定を保持し、以下の指定が有効なことを確認する。足りない指定だけ追加する。

```gitignore
/future/**/*.jsonl
/op/**/*.jsonl
```

```gitattributes
*.csv -text
*.gz binary
```

## 圧縮と照合

Python 3.10 以降と Git を使う。[補助スクリプト](scripts/prepare_data.py)は標準ライブラリのみで動作する。以下はリポジトリルートからの PowerShell の例。各コマンドが成功したことを確認してから次へ進む。

```powershell
python -X utf8 .agents/skills/upload-ose-data/scripts/prepare_data.py --repo .
```

スクリプトは原本を圧縮し、解凍後の SHA-256 とサイズを照合する。同じ内容の gzip は書き換えず、更新や破損がある場合は原本から作った照合済みの一時ファイルで置き換える。処理中の原本変更、原本のない壊れた gzip、想定外のファイル、100 MiB 以上の登録候補はエラーとして扱う。

Git 管理領域の `ose-data-upload/` に次の作業用ファイルを保存する。これらはコミットしない。

- `manifest.json`：原本と登録候補の照合記録。
- `targets.txt`：今回検証したデータファイルのパス一覧。

生成先は `.git` を固定値にせず、次のコマンドで取得する。エラー時はコミット・プッシュせず、表示された原因を解消して準備から実行し直す。

```powershell
$uploadState = git rev-parse --git-path ose-data-upload
$uploadTargets = Join-Path $uploadState 'targets.txt'
```

## 登録と反映

対象一覧だけをステージし、原本・圧縮結果・Git の登録内容が一致することを検証する。

```powershell
git add --pathspec-from-file="$uploadTargets"
python -X utf8 .agents/skills/upload-ose-data/scripts/prepare_data.py --repo . --verify
git diff --cached --check
git diff --cached --stat
```

無関係のステージ済み変更がある場合は、それもコミットしてしまう `git commit` や `git add .` を使わない。今回の対象に変更がある場合に限り、パスを限定してコミットする。

```powershell
git commit --only --pathspec-from-file="$uploadTargets" -m "先物・オプションデータを更新"
```

今回 `.gitignore`、`.gitattributes`、読み込み方法の説明を変更した場合は、`targets.txt` を同じ作業用ディレクトリの `commit-targets.txt` にコピーし、その変更のパスだけを UTF-8 で追記する。その一覧でステージ・コミットし、データの `--verify` は省略しない。同じ補助ファイルに既存の無関係な変更がある場合は、この一覧へ追加しない。パス限定でも同じファイル内の変更は分離できないため、必要な変更部分だけを独立したコミットとして扱う。スキル自体の編集や他の作業をデータ更新へ自動的に含めない。

`git commit --only` は作業ツリーを読み直すため、コミット後も次の照合を行う。原本・登録候補・検証記録の一致に加え、コミット内のデータと作業ツリーの一致を確認する。どちらかが失敗した場合はプッシュせず、変更原因を確認して準備からやり直す。

```powershell
python -X utf8 .agents/skills/upload-ose-data/scripts/prepare_data.py --repo . --verify
git diff --exit-code HEAD -- future op
```

コミットに含まれたパスと内容を確認してから、確認済みのブランチへ通常のプッシュを行う。以下は `main` の場合。

```powershell
git push origin main
git rev-parse HEAD
git ls-remote --heads origin main
git status --short --branch
```

ローカルのコミットとリモートのコミットが一致することを確認する。対象データに差分がなければ空コミットを作らない。既存の未送信コミットが今回の依頼に該当する場合は、その反映まで行う。

## 問題がある場合

- 原本が更新中の場合は、その状態を伝え、安定したデータで圧縮・照合をやり直す。収集プロセスを無断で停止しない。
- CSV と Git index の不一致が改行の自動変換によるものなら、`.gitattributes` の `*.csv -text` を確認し、該当 CSV だけを `git add --renormalize -- <対象のパス>` で再登録して `--verify` をやり直す。
- リモートが進んでいたら変更内容を確認して統合する。強制プッシュや既存変更の破棄で解決しない。競合や認証問題が解消できない場合は、完了した工程と未完了の工程を報告する。
- 容量エラーでは [GitHub のファイル制限](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)を確認し、原因を報告する。追加費用が生じ得る Git LFS への切り替えを自動で行わない。
- 通信エラー時はリモートのコミットを確認する。一時的な障害なら通常のプッシュを一度再試行し、同じ障害が続く場合はエラーを報告する。

完了時は送信先、コミット、対象ファイル数、圧縮後の容量、照合結果を簡潔に伝える。
