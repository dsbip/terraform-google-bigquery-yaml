#!/usr/bin/env python3
"""Rewrite v1 configuration files in the v2 layout.

v1 nested tables, views, materialized views and routines inside their dataset:

    datasets:
      sales:
        tables:
          orders: {...}

v2 has them as top-level sections whose entries name their dataset:

    datasets:
      sales: {}

    tables:
      orders:
        dataset: sales
        ...

Keys are kept, so the Terraform addresses ("sales.orders") do not change and
the first plan after upgrading shows no changes. The rewrite works on the text,
so comments, flow-style mappings and ${...} placeholders are preserved.

Usage:
    python scripts/upgrade-to-v2.py config.yaml [more.yaml ...]   rewrite in place
    python scripts/upgrade-to-v2.py --check config.yaml            exit 1 if a file needs upgrading
    python scripts/upgrade-to-v2.py --stdout config.yaml           print the result instead

Anything the script cannot rewrite safely (for example a dataset written in
flow style, `sales: {tables: ...}`) is reported, the file is left unchanged,
and the exit code is 1. Needs Python 3.8 or newer and nothing else.
"""
import argparse
import re
import sys
from pathlib import Path

CHILD_TYPES = ["tables", "views", "materialized_views", "routines"]
# Words YAML 1.1 reads as booleans or null; dataset keys like these must be quoted.
YAML_SPECIAL = {"y", "n", "yes", "no", "on", "off", "true", "false", "null", "~"}


class Unsupported(Exception):
    """The file uses a layout the script does not rewrite."""


def indent(line):
    return len(line) - len(line.lstrip(" "))


def blank(line):
    return line.strip() == ""


def comment(line):
    return line.lstrip().startswith("#")


def code(line):
    return not blank(line) and not comment(line)


def block_end(lines, start, parent_indent):
    """Index just past the block of lines (from `start`) indented deeper than
    parent_indent. Trailing blank lines and shallower comments are not part of
    the block."""
    end = start
    for i in range(start, len(lines)):
        line = lines[i]
        if blank(line) or (comment(line) and indent(line) > parent_indent):
            continue
        if indent(line) <= parent_indent:
            break
        end = i + 1
    return end


def split_value(rest):
    """`rest` is what follows `key:`; returns (value, trailing comment)."""
    if rest.lstrip().startswith("#"):
        return "", rest.strip()
    m = re.match(r"^(.*?)(\s+#.*)?$", rest)
    return m.group(1).strip(), (m.group(2) or "").strip()


def yaml_scalar(text):
    if re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]*", text) and text.lower() not in YAML_SPECIAL:
        return text
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def add_dataset(entry, dataset):
    """entry[0] is the `key: value` line of one table/view/routine."""
    m = re.match(r"^(\s*)((?:\"[^\"]*\"|'[^']*'|[^:#])+?):(\s.*|)$", entry[0])
    if not m:
        raise Unsupported(f"cannot read the entry line {entry[0].strip()!r}")
    lead, key, rest = m.groups()
    value, note = split_value(rest)
    note = f" {note}" if note else ""
    ref = f"dataset: {yaml_scalar(dataset)}"
    body = [line for line in entry[1:] if code(line)]
    if value == "" and body:
        return [entry[0], " " * indent(body[0]) + ref] + entry[1:]
    if value in ("", "~", "null", "{}"):
        return [f"{lead}{key}: {{ {ref} }}{note}"] + entry[1:]
    if value.startswith("{"):
        return [f"{lead}{key}: {{ {ref}, {value[1:].lstrip()}{note}"] + entry[1:]
    raise Unsupported(f"entry {key.strip()!r} has a value that is not a mapping: {value!r}")


def split_entries(lines):
    """Split a section body into entries; comments and blank lines before an
    entry belong to it."""
    first = next((line for line in lines if code(line)), None)
    if first is None:
        return []
    level = indent(first)
    entries, current, pending = [], [], []
    for line in lines:
        if code(line) and indent(line) == level:
            if current:
                entries.append(current)
            current, pending = pending + [line], []
        elif blank(line) or (comment(line) and indent(line) <= level):
            pending.append(line)
        else:
            current += pending + [line]
            pending = []
    if current:
        entries.append(current)
    return entries


def dedent(lines, amount):
    return [line[amount:] if line[:amount].strip() == "" else line.lstrip() for line in lines]


def upgrade(text):
    """Returns the v2 text (unchanged when there is nothing to move)."""
    lines = text.split("\n")
    starts = [i for i, line in enumerate(lines) if re.match(r"^datasets:\s*(#.*)?$", line)]
    if not starts:
        flow = re.search(r"^datasets:(.*)$", text, re.M)
        if flow and any(re.search(rf"\b{t}\s*:", flow.group(1)) for t in CHILD_TYPES):
            raise Unsupported("datasets is written in flow style; rewrite it by hand")
        return text
    start = starts[0]
    end = block_end(lines, start + 1, 0)
    body = lines[start + 1:end]
    moved = {t: [] for t in CHILD_TYPES}
    out = []

    first = next((line for line in body if code(line)), None)
    level = indent(first) if first else 0
    i = 0
    while i < len(body):
        line = body[i]
        if not code(line) or indent(line) != level:
            out.append(line)
            i += 1
            continue
        m = re.match(r"^\s*((?:\"[^\"]*\"|'[^']*'|[^:#])+?):(\s.*|)$", line)
        if not m:
            raise Unsupported(f"cannot read the dataset line {line.strip()!r}")
        dataset = m.group(1).strip().strip("\"'")
        value, _ = split_value(m.group(2))
        ds_end = block_end(body, i + 1, level)
        if value:
            if any(re.search(rf"\b{t}\s*:", value) for t in CHILD_TYPES):
                raise Unsupported(f"dataset {dataset!r} is written in flow style; rewrite it by hand")
            out.append(line)
            i += 1
            continue

        kept = [line]
        ds_lines = body[i + 1:ds_end]
        j = 0
        while j < len(ds_lines):
            child = ds_lines[j]
            sm = re.match(r"^(\s*)(tables|views|materialized_views|routines):(\s.*|)$", child)
            if not (sm and code(child)):
                kept.append(child)
                j += 1
                continue
            section, section_indent = sm.group(2), indent(child)
            section_value, _ = split_value(sm.group(3))
            # Comments directly above the section header move with its entries.
            header_notes = []
            while kept and comment(kept[-1]) and indent(kept[-1]) == section_indent:
                header_notes.insert(0, kept.pop())
            sec_end = block_end(ds_lines, j + 1, section_indent)
            if section_value not in ("", "{}", "~", "null"):
                raise Unsupported(f"datasets.{dataset}.{section} is written in flow style; rewrite it by hand")
            entries = split_entries(ds_lines[j + 1:sec_end])
            for n, entry in enumerate(entries):
                k = next(x for x, l in enumerate(entry) if code(l))
                entry_indent = indent(entry[k])
                # Entries move to two spaces of indentation.
                rewritten = dedent(entry[:k] + add_dataset(entry[k:], dataset), entry_indent - 2)
                if n == 0:
                    rewritten = dedent(header_notes, max(section_indent - 2, 0)) + rewritten
                moved[section].append(rewritten)
            j = sec_end
        while len(kept) > 1 and blank(kept[-1]):
            kept.pop()
        out.extend(kept)
        if ds_end > i + 1 and ds_end < len(body) and blank(body[ds_end - 1]) and not blank(out[-1]):
            out.append("")
        i = ds_end

    if not any(moved.values()):
        return text
    for section in CHILD_TYPES:
        if moved[section] and re.search(rf"^{section}:", text, re.M):
            raise Unsupported(f"the file has a top-level {section} section and {section} inside datasets; finish the upgrade by hand")
        # v1 keys were unique per dataset; v2 keys are unique per section.
        owners = {}
        for entry in moved[section]:
            k = next(n for n, l in enumerate(entry) if code(l))
            key = re.match(r"^\s*((?:\"[^\"]*\"|'[^']*'|[^:#])+?):", entry[k]).group(1).strip().strip("\"'")
            # add_dataset() put the reference on the key line or the next one.
            dataset = re.search(r"dataset: (\"(?:[^\"\\]|\\.)*\"|[^,}\s]+)", "\n".join(entry[k:k + 2])).group(1).strip('"')
            owners.setdefault(key, []).append(dataset)
        for key, datasets in owners.items():
            if len(datasets) > 1:
                id_key = "routine_id" if section == "routines" else "table_id"
                raise Unsupported(
                    f"{section} key {key!r} is used in datasets {', '.join(datasets)}, but keys must be unique in the "
                    f"{section} section; first rename all but one in the v1 file and set {id_key}: {key} on them "
                    "(see docs/upgrading.md)"
                )
    while out and blank(out[-1]):
        out.pop()

    def trim(entry):
        while entry and blank(entry[-1]):
            entry = entry[:-1]
        while entry and blank(entry[0]):
            entry = entry[1:]
        return entry

    result = lines[:start + 1] + out
    for section in CHILD_TYPES:
        if not moved[section]:
            continue
        result += ["", f"{section}:"]
        entries = [trim(entry) for entry in moved[section]]
        for n, entry in enumerate(entries):
            # A blank line between entries when either spans several lines.
            if n and (len(entry) > 1 or len(entries[n - 1]) > 1):
                result.append("")
            result += entry
    rest = lines[end:]
    while rest and blank(rest[0]):
        rest = rest[1:]
    if rest and any(not blank(line) for line in rest):
        result += [""] + rest
    else:
        result += [""]
    return "\n".join(result)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("files", nargs="+", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="only report files that need upgrading (exit 1 if any)")
    mode.add_argument("--stdout", action="store_true", help="print the upgraded text instead of writing it")
    args = parser.parse_args(argv)

    status = 0
    for path in args.files:
        text = path.read_bytes().decode("utf-8")
        try:
            new = upgrade(text.replace("\r\n", "\n"))
        except Unsupported as e:
            print(f"{path}: not changed: {e}", file=sys.stderr)
            status = 1
            continue
        changed = new != text.replace("\r\n", "\n")
        if args.stdout:
            sys.stdout.write(new)
        elif args.check:
            if changed:
                print(f"{path}: needs upgrading")
                status = 1
        elif changed:
            path.write_bytes(new.encode("utf-8"))
            print(f"{path}: upgraded")
        else:
            print(f"{path}: already in the v2 layout")
    return status


if __name__ == "__main__":
    sys.exit(main())
