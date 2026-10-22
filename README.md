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
