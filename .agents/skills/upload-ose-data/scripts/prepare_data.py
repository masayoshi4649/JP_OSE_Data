"""原本を保持して大阪取引所データの圧縮・登録前後の照合を行う。"""

import argparse
import concurrent.futures
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zlib


BLOCK_SIZE = 4 * 1024 * 1024
MAX_FILE_SIZE = 100 * 1024 * 1024
DATA_FOLDERS = ("future", "op")


def git(repo: Path, *arguments: str) -> bytes:
    """指定したリポジトリで読み取り専用の Git コマンドを実行する。

    引数:
        repo (Path): リポジトリの作業ディレクトリ。
        arguments (str): Git に渡す各引数。
    返り値:
        bytes: コマンドの標準出力。
    """
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments], capture_output=True, check=False
    )
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace").strip())
    return result.stdout


def inventory(repo: Path) -> list[str]:
    """対象フォルダの通常ファイルを列挙し、未対応形式やリンクを拒否する。

    引数:
        repo (Path): リポジトリのルート。
    返り値:
        list[str]: リポジトリ相対パスの昇順一覧。
    """
    paths = []
    for name in DATA_FOLDERS:
        folder = repo / name
        if folder.is_symlink() or (folder.exists() and not folder.is_dir()):
            raise RuntimeError(f"対象フォルダが通常のディレクトリではありません: {name}")
        if not folder.exists():
            continue
        for path in folder.rglob("*"):
            relative = path.relative_to(repo).as_posix()
            if path.is_symlink():
                raise RuntimeError(f"リンクは自動登録しません: {relative}")
            if path.is_dir():
                continue
            if not path.is_file() or not relative.endswith((".csv", ".jsonl", ".jsonl.gz")):
                raise RuntimeError(f"未対応のファイルは自動登録しません: {relative}")
            if "\n" in relative or "\r" in relative:
                raise RuntimeError(f"改行を含むファイル名は処理できません: {relative!r}")
            paths.append(relative)
    if not paths:
        raise RuntimeError("future/ または op/ に登録できるデータがありません。")
    return sorted(paths)


def stamp(path: Path) -> tuple[int, int, int, int]:
    """読み取り中の変更検知に使うファイル属性を取得する。

    引数:
        path (Path): 属性を調べるファイル。
    返り値:
        tuple[int, int, int, int]: サイズ、更新日時、変更日時、ファイル識別子。
    """
    status = path.stat()
    return status.st_size, status.st_mtime_ns, status.st_ctime_ns, status.st_ino


def fingerprint(repo: Path, relative: str) -> dict:
    """ファイル全体の SHA256 と属性を取得し、読み取り中の変更を検出する。

    引数:
        repo (Path): リポジトリのルート。
        relative (str): リポジトリ相対パス。
    返り値:
        dict: パス、サイズ、更新日時、SHA256 の記録。
    """
    path = repo / relative
    before = stamp(path)
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(BLOCK_SIZE):
            digest.update(block)
    if stamp(path) != before:
        raise RuntimeError(f"読み取り中にファイルが変更されました: {relative}")
    return {"path": relative, "size": before[0], "mtime_ns": before[1], "sha256": digest.hexdigest()}


def restored_fingerprint(path: Path) -> tuple[int, str]:
    """gzip を最後まで展開して整合性と展開後のサイズ・SHA256 を確認する。

    引数:
        path (Path): 検証する gzip ファイル。
    返り値:
        tuple[int, str]: 展開後のサイズと SHA256。
    """
    before = stamp(path)
    digest = hashlib.sha256()
    size = 0
    with gzip.open(path, "rb") as source:
        while block := source.read(BLOCK_SIZE):
            digest.update(block)
            size += len(block)
    if stamp(path) != before:
        raise RuntimeError(f"展開中にファイルが変更されました: {path}")
    return size, digest.hexdigest()


def prepare_file(repo: Path, work: Path, relative: str) -> dict:
    """原本を保持して必要な圧縮を行い、登録候補の検証記録を作成する。

    引数:
        repo (Path): リポジトリのルート。
        work (Path): Git 管理外の一時作業ディレクトリ。
        relative (str): 原本または原本のない gzip の相対パス。
    返り値:
        dict: 原本・登録候補の属性と gzip 展開内容の照合結果。
    """
    source = fingerprint(repo, relative)
    destination = relative + ".gz" if relative.endswith(".jsonl") else relative
    target = repo / destination
    restored = None
    validated_candidate = None

    # ----------------------------------------
    # 原本付き gzip は、同じ展開内容を持つ既存ファイルをそのまま保持する。
    if relative.endswith(".jsonl"):
        expected = source["size"], source["sha256"]
        reusable = False
        if target.exists():
            existing = fingerprint(repo, destination)
            try:
                reusable = restored_fingerprint(target) == expected
            except (gzip.BadGzipFile, EOFError, OSError, zlib.error):
                reusable = False
            if fingerprint(repo, destination) != existing:
                raise RuntimeError(f"照合中に圧縮ファイルが変更されました: {destination}")
            if reusable:
                validated_candidate = existing
        if not reusable:
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=work, suffix=".jsonl.gz", delete=False) as output:
                    temporary = Path(output.name)
                    digest = hashlib.sha256()
                    size = 0
                    with (repo / relative).open("rb") as original:
                        with gzip.GzipFile(filename="", mode="wb", fileobj=output, compresslevel=6, mtime=0) as archive:
                            while block := original.read(BLOCK_SIZE):
                                digest.update(block)
                                size += len(block)
                                archive.write(block)
                if (size, digest.hexdigest()) != expected or fingerprint(repo, relative) != source:
                    raise RuntimeError(f"圧縮中に原本が変更されました: {relative}")
                validated_candidate = {**fingerprint(work, temporary.name), "path": destination}
                if restored_fingerprint(temporary) != expected:
                    raise RuntimeError(f"圧縮後の展開内容が原本と一致しません: {relative}")
                if temporary.stat().st_size >= MAX_FILE_SIZE:
                    raise RuntimeError(f"登録候補が 100 MiB 以上です: {destination}")
                os.replace(temporary, target)
            finally:
                if temporary is not None and temporary.exists():
                    temporary.unlink()
        restored = {"size": expected[0], "sha256": expected[1]}
    elif relative.endswith(".jsonl.gz"):
        if source["size"] >= MAX_FILE_SIZE:
            raise RuntimeError(f"登録候補が 100 MiB 以上です: {destination}")
        size, digest = restored_fingerprint(target)
        restored = {"size": size, "sha256": digest}

    # ----------------------------------------
    # CSV と gzip の登録バイト列、および保持する原本を記録する。
    candidate = fingerprint(repo, destination)
    if validated_candidate is not None and candidate != validated_candidate:
        raise RuntimeError(f"展開検証後に圧縮ファイルが変更されました: {destination}")
    if candidate["size"] >= MAX_FILE_SIZE:
        raise RuntimeError(f"登録候補が 100 MiB 以上です: {destination}")
    if fingerprint(repo, relative) != source:
        raise RuntimeError(f"処理中に原本が変更されました: {relative}")
    return {"source": source, "destination": candidate, "restored": restored}


def verify_files(repo: Path, records: list[dict]) -> None:
    """記録と現在のファイル集合・内容・更新日時を照合する。

    引数:
        repo (Path): リポジトリのルート。
        records (list[dict]): 準備処理が保存した原本と登録候補の記録。
    返り値:
        None: 一致しない場合は例外で停止する。
    """
    expected = {}
    destinations = set()
    for record in records:
        destination = record["destination"]["path"]
        if destination in destinations or not destination.endswith((".csv", ".jsonl.gz")):
            raise RuntimeError("検証記録に不正または重複した登録候補があります。")
        destinations.add(destination)
        if record["destination"]["size"] >= MAX_FILE_SIZE:
            raise RuntimeError(f"登録候補が 100 MiB 以上です: {destination}")
        for field in ("source", "destination"):
            entry = record[field]
            if entry["path"] in expected and expected[entry["path"]] != entry:
                raise RuntimeError("検証記録内のファイル属性が矛盾しています。")
            expected[entry["path"]] = entry
    actual = inventory(repo)
    if set(actual) != set(expected):
        added = sorted(set(actual) - set(expected))
        removed = sorted(set(expected) - set(actual))
        raise RuntimeError(f"準備後にファイル集合が変化しました。追加: {added} / 消失: {removed}")
    for relative in actual:
        if fingerprint(repo, relative) != expected[relative]:
            raise RuntimeError(f"準備後にファイルが変更されました: {relative}")


def verify_index(repo: Path, records: list[dict]) -> None:
    """全登録候補と Git index のバイト列を照合し、未圧縮 JSONL を拒否する。

    引数:
        repo (Path): リポジトリのルート。
        records (list[dict]): 準備処理が保存した登録候補の記録。
    返り値:
        None: 未登録、競合、内容不一致の場合は例外で停止する。
    """
    entries = {}
    for entry in git(repo, "ls-files", "--stage", "-z", "--", *DATA_FOLDERS).split(b"\0"):
        if not entry:
            continue
        metadata, encoded_path = entry.split(b"\t", 1)
        mode, object_id, stage = metadata.split()
        relative = encoded_path.decode("utf-8")
        if relative.endswith(".jsonl"):
            raise RuntimeError(f"未圧縮 JSONL が Git index に含まれています: {relative}")
        if stage != b"0" or mode not in (b"100644", b"100755"):
            raise RuntimeError(f"Git index に競合または通常ファイル以外があります: {relative}")
        entries[relative] = object_id

    # ----------------------------------------
    # Git オブジェクトを連続取得し、フィルター適用後の index と実ファイルを比較する。
    process = subprocess.Popen(
        ["git", "-C", str(repo), "cat-file", "--batch"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        for record in records:
            candidate = record["destination"]
            relative = candidate["path"]
            if relative not in entries:
                raise RuntimeError(f"登録候補が Git index にありません: {relative}")
            process.stdin.write(entries[relative] + b"\n")
            process.stdin.flush()
            header = process.stdout.readline().split()
            if len(header) != 3 or header[1] != b"blob" or int(header[2]) != candidate["size"]:
                raise RuntimeError(f"Git index のサイズが一致しません: {relative}")
            remaining = candidate["size"]
            with (repo / relative).open("rb") as source:
                while remaining:
                    count = min(BLOCK_SIZE, remaining)
                    block = process.stdout.read(count)
                    if len(block) != count or block != source.read(count):
                        raise RuntimeError(f"Git index の内容が一致しません: {relative}")
                    remaining -= count
                if source.read(1):
                    raise RuntimeError(f"照合中に登録候補が変更されました: {relative}")
            if process.stdout.read(1) != b"\n":
                raise RuntimeError("Git オブジェクトの取得結果が不正です。")
    finally:
        if process.poll() is None:
            process.terminate()
        process.communicate()


def save_text(path: Path, text: str) -> None:
    """Git 管理外の記録ファイルを一時ファイル経由で置き換える。

    引数:
        path (Path): 保存先。
        text (str): UTF-8 で保存する文字列。
    返り値:
        None: 保存後に終了する。
    """
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, mode="w", encoding="utf-8", newline="\n", delete=False) as output:
            temporary = Path(output.name)
            output.write(text)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main() -> int:
    """引数に応じて圧縮準備または登録後照合を行う。

    引数:
        なし。コマンドラインから --repo、--workers、--verify を受け取る。
    返り値:
        int: 成功時は 0、検証失敗時は 1。
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="対象リポジトリ内のパス（既定: 現在のフォルダ）")
    parser.add_argument("--workers", type=int, default=4, help="圧縮準備の並列数（既定: 4）")
    parser.add_argument("--verify", action="store_true", help="ファイルを変更せず、準備後の状態と Git index を照合する")
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("--workers には 1 以上を指定してください。")
    try:
        repo = Path(git(args.repo, "rev-parse", "--show-toplevel").decode("utf-8").strip()).resolve()
        work = Path(git(repo, "rev-parse", "--git-path", "ose-data-upload").decode("utf-8").strip())
        if not work.is_absolute():
            work = repo / work
        manifest_path = work / "manifest.json"
        targets_path = work / "targets.txt"

        # ----------------------------------------
        # 検証モードでは記録の再生成やファイルの更新を行わない。
        if args.verify:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if manifest["version"] != 1 or manifest["repo"] != str(repo):
                raise RuntimeError("検証記録の形式またはリポジトリが一致しません。準備を再実行してください。")
            records = manifest["records"]
            targets = "".join(record["destination"]["path"] + "\n" for record in records)
            if targets_path.read_text(encoding="utf-8") != targets:
                raise RuntimeError("targets.txt と検証記録が一致しません。")
            verify_files(repo, records)
            verify_index(repo, records)
            verify_files(repo, records)
            print(f"登録前検証に成功しました: {len(records)} ファイル。原本・登録候補・Git index が一致しています。")
            return 0

        # ----------------------------------------
        # gzip と原本の重複を除き、元ファイルを削除せず圧縮・検証する。
        paths = inventory(repo)
        present = set(paths)
        sources = [path for path in paths if not (path.endswith(".jsonl.gz") and path[:-3] in present)]
        work.mkdir(parents=True, exist_ok=True)
        records = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
            tasks = [pool.submit(prepare_file, repo, work, relative) for relative in sources]
            for task in concurrent.futures.as_completed(tasks):
                records.append(task.result())
                if len(records) % 100 == 0 or len(records) == len(tasks):
                    print(f"圧縮・照合完了: {len(records)} / {len(tasks)}", flush=True)
        records.sort(key=lambda record: record["destination"]["path"])
        verify_files(repo, records)
        save_text(targets_path, "".join(record["destination"]["path"] + "\n" for record in records))
        save_text(manifest_path, json.dumps({"version": 1, "repo": str(repo), "records": records}, ensure_ascii=False, indent=2) + "\n")
        print(f"準備完了: {len(records)} ファイル。登録対象一覧: {targets_path}")
        print(f"登録候補の合計サイズ: {sum(record['destination']['size'] for record in records):,} バイト。")
        print("Git への登録後、コミット・プッシュの前に --verify を実行してください。")
        return 0
    except (OSError, RuntimeError, ValueError, KeyError, TypeError, EOFError, zlib.error) as error:
        print(f"エラー: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
