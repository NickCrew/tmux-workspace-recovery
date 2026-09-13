#!/usr/bin/env python3
"""Validate and query tmux-resurrect snapshot files."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import sys
from dataclasses import dataclass
from typing import Callable, Optional


MAX_SNAPSHOT_BYTES = 10 * 1024 * 1024
STATE_DELIMITER = "\x1f"
FIELD_COUNTS = {
    "pane": 11,
    "window": 8,
    "state": 3,
    "grouped_session": 5,
}


class SnapshotError(ValueError):
    """The snapshot cannot be restored safely."""


@dataclass(frozen=True)
class Record:
    kind: str
    fields: tuple[str, ...]
    raw: str
    line_number: int


@dataclass(frozen=True)
class LayoutCell:
    width: int
    height: int
    x: int
    y: int
    pane: Optional[int] = None
    split: Optional[str] = None
    children: tuple["LayoutCell", ...] = ()


class LayoutParser:
    def __init__(self, value: str) -> None:
        self.value = value
        self.position = 0

    def parse(self) -> LayoutCell:
        if len(self.value) > 65536:
            fail("window layout is too long")
        checksum = self.read_while(lambda char: char in "0123456789abcdefABCDEF")
        if len(checksum) != 4 or not self.consume(","):
            fail("invalid window layout checksum")
        payload_start = self.position
        cell = self.parse_cell(0)
        if self.position != len(self.value):
            fail("invalid trailing window layout data")
        calculated = 0
        for char in self.value[payload_start:]:
            calculated = (calculated >> 1) + ((calculated & 1) << 15)
            calculated = (calculated + ord(char)) & 0xFFFF
        if int(checksum, 16) != calculated:
            fail("invalid window layout checksum")
        return cell

    def parse_cell(self, depth: int) -> LayoutCell:
        if depth > 100:
            fail("window layout is nested too deeply")
        width = self.read_integer()
        self.require("x")
        height = self.read_integer()
        self.require(",")
        x = self.read_integer()
        self.require(",")
        y = self.read_integer()
        if self.consume(","):
            return LayoutCell(width, height, x, y, pane=self.read_integer())
        if self.position >= len(self.value) or self.value[self.position] not in "[{":
            fail("invalid window layout cell")
        opening = self.value[self.position]
        closing = "]" if opening == "[" else "}"
        self.position += 1
        children = [self.parse_cell(depth + 1)]
        while self.consume(","):
            children.append(self.parse_cell(depth + 1))
        self.require(closing)
        if len(children) < 2:
            fail("window layout split must contain at least two cells")
        return LayoutCell(
            width,
            height,
            x,
            y,
            split=opening,
            children=tuple(children),
        )

    def read_integer(self) -> int:
        raw = self.read_while(lambda char: "0" <= char <= "9")
        if not raw:
            fail("invalid window layout integer")
        if len(raw) > 10:
            fail("window layout integer is too large")
        return int(raw)

    def read_while(self, predicate: Callable[[str], bool]) -> str:
        start = self.position
        while self.position < len(self.value) and predicate(self.value[self.position]):
            self.position += 1
        return self.value[start : self.position]

    def consume(self, token: str) -> bool:
        if self.value.startswith(token, self.position):
            self.position += len(token)
            return True
        return False

    def require(self, token: str) -> None:
        if not self.consume(token):
            fail(f"invalid window layout, expected {token!r}")


def parse_layout(value: str) -> LayoutCell:
    return LayoutParser(value).parse()


def layout_shape(cell: LayoutCell) -> str:
    if cell.pane is not None:
        return "pane"
    closing = "]" if cell.split == "[" else "}"
    children = ",".join(layout_shape(child) for child in cell.children)
    return f"{cell.split}{children}{closing}"


def pane_schema(fields: tuple[str, ...]) -> str:
    if fields[7].startswith(":"):
        return "current"
    if fields[6].startswith(":"):
        return "legacy"
    return "unknown"


def fail(message: str) -> None:
    raise SnapshotError(message)


def encode_text(value: str) -> str:
    return "x" + value.encode("utf-8").hex()


def decode_text(value: str) -> str:
    if not value.startswith("x"):
        fail("invalid encoded text field")
    try:
        return bytes.fromhex(value[1:]).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        fail("invalid encoded text field")


def encode_live_rows(kind: str, rows: list[str]) -> list[str]:
    expected = 5 if kind == "window" else 3
    output = []
    for line_number, row in enumerate(rows, start=1):
        fields = row.split(STATE_DELIMITER)
        if len(fields) != expected:
            fail(f"live {kind} state line {line_number} has an unsafe field")
        fields[1] = encode_text(fields[1])
        output.append("\t".join(fields))
    return output


def validate_session_name(name: str, line_number: int) -> None:
    if not name:
        fail(f"line {line_number}: empty session name")
    if any(char in name for char in ":\t\r\n"):
        fail(f"line {line_number}: unsafe session name {name!r}")
    if not (name[0].isalnum() or name[0] == "_"):
        fail(f"line {line_number}: unsafe session name {name!r}")
    if any(not (char.isalnum() or char in " _-") for char in name[1:]):
        fail(f"line {line_number}: unsafe session name {name!r}")


def parse_nonnegative(value: str, label: str, line_number: int) -> int:
    if not re.fullmatch(r"0|[1-9][0-9]*", value):
        fail(f"line {line_number}: {label} must be a canonical nonnegative integer")
    return int(value)


def load_snapshot(path: Path) -> list[Record]:
    try:
        file_stat = path.stat()
    except OSError as error:
        fail(f"cannot read snapshot {path}: {error}")

    if not stat.S_ISREG(file_stat.st_mode):
        fail(f"snapshot is not a regular file: {path}")
    if file_stat.st_size > MAX_SNAPSHOT_BYTES:
        fail(f"snapshot exceeds {MAX_SNAPSHOT_BYTES} bytes: {path}")

    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        fail(f"cannot decode snapshot {path}: {error}")

    if "\x00" in text or "\r" in text:
        fail("snapshot contains unsupported control characters")

    records: list[Record] = []
    panes: set[tuple[str, int, int]] = set()
    windows: set[tuple[str, int]] = set()

    for line_number, raw in enumerate(text.splitlines(), start=1):
        if not raw:
            continue
        fields = tuple(raw.split("\t"))
        kind = fields[0]
        expected = FIELD_COUNTS.get(kind)
        if expected is None:
            fail(f"line {line_number}: unknown record type")
        if len(fields) != expected:
            fail(
                f"line {line_number}: {kind} has {len(fields)} fields, "
                f"expected {expected}"
            )

        if kind == "pane":
            session = fields[1]
            validate_session_name(session, line_number)
            window = parse_nonnegative(fields[2], "window index", line_number)
            pane = parse_nonnegative(fields[5], "pane index", line_number)
            schema = pane_schema(fields)
            if schema == "current":
                active_pane = parse_nonnegative(fields[8], "active pane flag", line_number)
            elif schema == "legacy":
                active_pane = parse_nonnegative(fields[7], "active pane flag", line_number)
            else:
                fail(f"line {line_number}: unrecognized pane record format")
            if active_pane not in {0, 1}:
                fail(f"line {line_number}: active pane flag must be 0 or 1")
            if not fields[6]:
                fail(f"line {line_number}: empty pane title is not supported")
            key = (session, window, pane)
            if key in panes:
                fail(f"line {line_number}: duplicate pane {session}:{window}.{pane}")
            panes.add(key)
        elif kind == "window":
            session = fields[1]
            validate_session_name(session, line_number)
            window = parse_nonnegative(fields[2], "window index", line_number)
            active_window = parse_nonnegative(fields[4], "active window flag", line_number)
            if active_window not in {0, 1}:
                fail(f"line {line_number}: active window flag must be 0 or 1")
            try:
                parse_layout(fields[6])
            except SnapshotError as error:
                fail(f"line {line_number}: {error}")
            if fields[7] not in {":", "on", "off"}:
                fail(f"line {line_number}: invalid automatic-rename value")
            key = (session, window)
            if key in windows:
                fail(f"line {line_number}: duplicate window {session}:{window}")
            windows.add(key)
        elif kind == "grouped_session":
            validate_session_name(fields[1], line_number)
            validate_session_name(fields[2], line_number)

        records.append(Record(kind, fields, raw, line_number))

    if not records:
        fail("snapshot is empty")

    for session, window, pane in panes:
        if (session, window) not in windows:
            fail(f"pane {session}:{window}.{pane} has no window record")

    return records


def records_for_session(records: list[Record], session: str) -> list[Record]:
    validate_session_name(session, 0)
    for record in records:
        if record.kind == "grouped_session" and session in record.fields[1:3]:
            fail(f"session {session!r} is grouped; targeted restore is not supported")

    selected = [
        record
        for record in records
        if record.kind in {"pane", "window"} and record.fields[1] == session
    ]
    if not selected:
        fail(f"session {session!r} is not present in the snapshot")
    if any(
        record.kind == "pane" and pane_schema(record.fields) != "current"
        for record in selected
    ):
        fail(
            f"session {session!r} uses a legacy pane format that the installed "
            "tmux-resurrect cannot restore safely"
        )
    return selected


def session_rows(records: list[Record]) -> list[tuple[str, int, int]]:
    names = {
        record.fields[1]
        for record in records
        if record.kind in {"pane", "window"}
    }
    rows = []
    for name in sorted(names):
        window_count = sum(
            record.kind == "window" and record.fields[1] == name
            for record in records
        )
        pane_count = sum(
            record.kind == "pane" and record.fields[1] == name
            for record in records
        )
        rows.append((name, window_count, pane_count))
    return rows


def window_rows(records: list[Record], session: str) -> list[tuple[int, str, int]]:
    selected = records_for_session(records, session)
    panes: dict[int, int] = {}
    for record in selected:
        if record.kind == "pane":
            window = int(record.fields[2])
            panes[window] = panes.get(window, 0) + 1

    rows = []
    for record in selected:
        if record.kind != "window":
            continue
        window = int(record.fields[2])
        name = record.fields[3][1:] if record.fields[3].startswith(":") else record.fields[3]
        rows.append((window, name, panes.get(window, 0)))
    return sorted(rows)


def property_rows(
    records: list[Record], session: str
) -> list[tuple[int, str, int, str, str, int, int]]:
    selected = records_for_session(records, session)
    pane_counts: dict[int, int] = {}
    active_panes: dict[int, int] = {}
    zoomed: dict[int, int] = {}
    for record in selected:
        if record.kind != "pane":
            continue
        window = int(record.fields[2])
        pane_counts[window] = pane_counts.get(window, 0) + 1
        if int(record.fields[8]) == 1:
            if window in active_panes:
                fail(f"window {session}:{window} has multiple active panes")
            active_panes[window] = int(record.fields[5])
            zoomed[window] = int("Z" in record.fields[4])

    rows = []
    for record in selected:
        if record.kind != "window":
            continue
        window = int(record.fields[2])
        if window not in active_panes:
            fail(f"window {session}:{window} has no active pane")
        layout = record.fields[6]
        rows.append(
            (
                window,
                record.fields[3][1:] if record.fields[3].startswith(":") else record.fields[3],
                pane_counts.get(window, 0),
                layout,
                record.fields[7],
                active_panes[window],
                zoomed[window],
            )
        )
    return sorted(rows)


def checksum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def publish_checkpoint(source: Path, root: Path) -> Path:
    load_snapshot(source)
    root = root.expanduser().resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    last_pointer = root / "last"
    if last_pointer.exists() and not last_pointer.is_symlink():
        fail(f"snapshot pointer is not a symlink: {last_pointer}")
    base = source.stem
    if not re.fullmatch(r"tmux_resurrect_[A-Za-z0-9_.-]+", base):
        fail("checkpoint filename is not a tmux-resurrect snapshot")

    destination = root / f"{base}_workspace_recovery_{os.getpid()}.txt"
    counter = 0
    while True:
        try:
            with source.open("rb") as input_stream:
                descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                try:
                    with os.fdopen(descriptor, "wb") as output_stream:
                        shutil.copyfileobj(input_stream, output_stream)
                        output_stream.flush()
                        os.fsync(output_stream.fileno())
                except Exception:
                    destination.unlink(missing_ok=True)
                    raise
            break
        except FileExistsError:
            counter += 1
            destination = root / (
                f"{base}_workspace_recovery_{os.getpid()}_{counter}.txt"
            )

    if checksum(source) != checksum(destination):
        destination.unlink(missing_ok=True)
        fail("published checkpoint checksum mismatch")

    temporary_link = root / f".last.workspace-recovery.{os.getpid()}"
    replaced = False
    try:
        temporary_link.symlink_to(destination.name)
        os.replace(temporary_link, last_pointer)
        replaced = True
        directory_descriptor = os.open(root, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except Exception:
        temporary_link.unlink(missing_ok=True)
        if not replaced:
            destination.unlink(missing_ok=True)
        raise
    return destination


def resolve_snapshot(root: Path, reference: str) -> Path:
    root = root.expanduser().resolve()
    candidate = root / "last" if reference == "latest" else root / reference
    if candidate.name == "last" and not candidate.is_symlink():
        fail(f"snapshot pointer is not a symlink: {candidate}")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        fail(f"cannot resolve snapshot {candidate}: {error}")

    try:
        resolved.relative_to(root)
    except ValueError:
        fail(f"snapshot resolves outside the resurrect directory: {candidate}")

    load_snapshot(resolved)
    return resolved


def write_filtered(records: list[Record], session: str, output: Path) -> None:
    selected = records_for_session(records, session)
    payload = "\n".join(record.raw for record in selected) + "\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(output, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except Exception:
        output.unlink(missing_ok=True)
        raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("snapshot", type=Path)

    digest = subparsers.add_parser("checksum")
    digest.add_argument("snapshot", type=Path)

    sessions = subparsers.add_parser("sessions")
    sessions.add_argument("snapshot", type=Path)

    windows = subparsers.add_parser("windows")
    windows.add_argument("snapshot", type=Path)
    windows.add_argument("session")

    properties = subparsers.add_parser("properties")
    properties.add_argument("snapshot", type=Path)
    properties.add_argument("session")

    shape = subparsers.add_parser("layout-shape")
    shape.add_argument("layout")

    decode = subparsers.add_parser("decode-text")
    decode.add_argument("value")

    encode_live = subparsers.add_parser("encode-live-state")
    encode_live.add_argument("kind", choices=("window", "pane"))

    filtered = subparsers.add_parser("filter")
    filtered.add_argument("snapshot", type=Path)
    filtered.add_argument("session")
    filtered.add_argument("output", type=Path)

    resolve = subparsers.add_parser("resolve")
    resolve.add_argument("root", type=Path)
    resolve.add_argument("reference")

    publish = subparsers.add_parser("publish-checkpoint")
    publish.add_argument("snapshot", type=Path)
    publish.add_argument("root", type=Path)

    list_command = subparsers.add_parser("list")
    list_command.add_argument("root", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "resolve":
            print(resolve_snapshot(args.root, args.reference))
            return 0
        if args.command == "publish-checkpoint":
            print(publish_checkpoint(args.snapshot, args.root))
            return 0
        if args.command == "layout-shape":
            print(layout_shape(parse_layout(args.layout)))
            return 0
        if args.command == "decode-text":
            print(decode_text(args.value), end="")
            return 0
        if args.command == "encode-live-state":
            for row in encode_live_rows(args.kind, sys.stdin.read().splitlines()):
                print(row)
            return 0
        if args.command == "list":
            root = args.root.expanduser().resolve()
            if not root.is_dir():
                fail(f"resurrect directory not found: {root}")
            paths = sorted(root.glob("tmux_resurrect_*.txt"), reverse=True)
            if not paths:
                fail(f"no tmux-resurrect snapshots found in {root}")
            for path in paths:
                try:
                    listed_records = load_snapshot(path)
                    rows = session_rows(listed_records)
                    print(
                        "\t".join(
                            [
                                path.name,
                                str(len(rows)),
                                str(sum(row[1] for row in rows)),
                                str(sum(row[2] for row in rows)),
                                "ok",
                            ]
                        )
                    )
                except SnapshotError as error:
                    message = str(error)
                    location = message.split(":", maxsplit=1)[0]
                    detail = (
                        f"validation failed at {location}"
                        if location.startswith("line ")
                        else "validation failed"
                    )
                    print("\t".join([path.name, "0", "0", "0", f"invalid: {detail}"]))
            return 0

        records = load_snapshot(args.snapshot)
        if args.command == "validate":
            return 0
        if args.command == "checksum":
            print(checksum(args.snapshot))
            return 0
        if args.command == "sessions":
            for row in session_rows(records):
                print("\t".join(str(value) for value in row))
            return 0
        if args.command == "windows":
            for row in window_rows(records, args.session):
                print("\t".join([str(row[0]), encode_text(row[1]), str(row[2])]))
            return 0
        if args.command == "properties":
            for row in property_rows(records, args.session):
                encoded = [str(row[0]), encode_text(row[1])]
                encoded.extend(str(value) for value in row[2:])
                print("\t".join(encoded))
            return 0
        if args.command == "filter":
            write_filtered(records, args.session, args.output)
            return 0
    except SnapshotError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
