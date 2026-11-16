#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 CSV 读取若干列整数值（逗号分隔、无表头，各行列数一致），
生成 INSERT INTO `<relname>` 语句，替换模板 SQL 中
LOCK TABLES `<relname>` WRITE 与 UNLOCK TABLES 之间的 INSERT 块。

用法（四个位置参数，顺序固定）:
  python regen_alice_init_from_csv.py <csv路径> <模板.sql> <输出.sql> <relname>

示例:
  python regen_alice_init_from_csv.py alice.csv alice_init.sql out.sql lineitem
  python regen_alice_init_from_csv.py q17_p2.csv bob_init.sql out.sql part
"""

from __future__ import annotations

import argparse
from pathlib import Path


def mysql_backtick_ident(name: str) -> str:
    """MySQL 反引号包裹的标识符，内部反引号按规则加倍。"""
    if not name.strip():
        raise ValueError("relname 不能为空")
    return "`" + name.replace("`", "``") + "`"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="用 CSV 重写模板 SQL 中指定表的 INSERT 段",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "csv",
        type=Path,
        help="CSV 文件路径（整型列，逗号分隔，无表头，各行列数须一致）",
    )
    p.add_argument(
        "template_sql",
        type=Path,
        help="作为模板的 .sql 路径（其中的 INSERT 段会被替换）",
    )
    p.add_argument(
        "output_sql",
        type=Path,
        help="生成的 .sql 输出路径",
    )
    p.add_argument(
        "relname",
        type=str,
        help="表名（与模板中 LOCK TABLES `<relname>` WRITE 一致，如 lineitem、part）",
    )
    return p.parse_args()


def load_csv_rows(path: Path) -> list[tuple[int, ...]]:
    rows: list[tuple[int, ...]] = []
    text = path.read_text(encoding="utf-8")
    ncol: int | None = None
    for line_no, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(",")]
        if ncol is None:
            ncol = len(parts)
            if ncol < 1:
                raise ValueError(f"{path}:{line_no} 至少需要一列数据")
        elif len(parts) != ncol:
            raise ValueError(
                f"{path}:{line_no} 期望 {ncol} 列，得到 {len(parts)}: {raw!r}"
            )
        try:
            vals = tuple(int(x) for x in parts)
        except ValueError as e:
            raise ValueError(f"{path}:{line_no} 含有非整数: {raw!r}") from e
        rows.append(vals)
    if not rows:
        raise ValueError(f"{path} 无有效数据行")
    return rows


def splice_table_inserts(sql_text: str, rows: list[tuple[int, ...]], relname: str) -> str:
    lines = sql_text.splitlines(keepends=True)
    qi = mysql_backtick_ident(relname.strip())
    lock_marker = f"LOCK TABLES {qi} WRITE;"
    unlock_prefix = "UNLOCK TABLES"

    lock_idx = -1
    unlock_idx = -1
    for i, ln in enumerate(lines):
        if lock_marker in ln:
            lock_idx = i
        if ln.strip().startswith(unlock_prefix):
            unlock_idx = i
            break

    if lock_idx < 0:
        raise ValueError(f"未找到 `{lock_marker}`（请确认 relname 与模板中 LOCK TABLES 一致）")
    if unlock_idx < 0:
        raise ValueError("未找到 `UNLOCK TABLES`")
    if unlock_idx <= lock_idx:
        raise ValueError("LOCK / UNLOCK 顺序异常")

    def values_tuple(row: tuple[int, ...]) -> str:
        return ", ".join(str(x) for x in row)

    inserts = "".join(f"INSERT INTO {qi} VALUES ({values_tuple(row)});\n" for row in rows)
    return "".join(lines[: lock_idx + 1]) + inserts + "".join(lines[unlock_idx:])


def main() -> None:
    args = parse_args()
    rel = args.relname.strip()

    rows = load_csv_rows(args.csv)
    template = args.template_sql.read_text(encoding="utf-8")
    new_sql = splice_table_inserts(template, rows, rel)
    args.output_sql.parent.mkdir(parents=True, exist_ok=True)
    args.output_sql.write_text(new_sql, encoding="utf-8", newline="\n")
    q = mysql_backtick_ident(rel)
    print(f"已写入 {args.output_sql}，共 {len(rows)} 条 INSERT INTO {q}。")


if __name__ == "__main__":
    main()
