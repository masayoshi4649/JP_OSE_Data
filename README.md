# JP_OSE_Data

大阪取引所の先物・オプションの取引データを保存するリポジトリです。

- `future/NK225/`：日経225先物の板情報とローソク足データ。
- `future/TOPIX/`：TOPIX先物の板情報とローソク足データ。
- `op/`：銘柄ごとのオプションデータ。

日付と取引時間帯ごとにディレクトリを分けています。`Day` は日中、`Night` は夜間のデータです。

JSONL はファイル単位で gzip 圧縮し、`.jsonl.gz` として保存しています。解凍すると元の JSONL をバイト単位で復元できます。CSV は圧縮せず保存しています。

Python では解凍ファイルを作らずに読み込めます。

```python
import gzip
import json

with gzip.open("future/NK225/2026-09-21_Day/book.jsonl.gz", "rt", encoding="utf-8") as source:
    for line in source:
        record = json.loads(line)
```

ローカルの元の `.jsonl` ファイルは `.gitignore` で除外しています。データを更新した場合は、対応する `.jsonl.gz` も更新してください。

## データの取得

このフォルダーの `FetchData.cmd` をダブルクリックします。起動引数や追加のツールファイルは不要です。
取得元は `\\10.10.100.1\log`、保存先は `FetchData.cmd` の配置フォルダーです。変更する場合はファイル先頭の `OSE_SOURCE`・`OSE_DESTINATION`・`OSE_MAXMBPS` を編集します。

新形式の `future/NK225/`・`future/TOPIX/`・`op/` を同じ構成のまま取得します。先物はセッションごとの `book.jsonl`・`candle_1min.csv`・`candle_5min.csv`、OP はセッションごとの銘柄名 `.jsonl` が対象です。旧形式のフォルダーや一時ファイルは対象外です。

同じ相対パスの既存ファイルは内容を読まず省略し、未取得ファイルだけを初期値 10 Mbps の単一転送で取得します。転送成功と取得前後のサイズ・更新日時を確認してから公開します。中断した場合は同じファイルを再実行してください。途中データと実行記録は `.fetchdata/` に保存します。

取得時は JSONL の変換・gzip 圧縮を行いません。`.jsonl.gz` だけが存在する場合も、生 `.jsonl` がなければ取得します。圧縮版の更新は別工程です。終了コードは成功が `0`、一部転送失敗が `1`、準備などの失敗が `2` です。
