from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "snapshot.py"
SPEC = importlib.util.spec_from_file_location("snapshot", MODULE_PATH)
assert SPEC and SPEC.loader
snapshot = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = snapshot
SPEC.loader.exec_module(snapshot)


def pane(session: str, window: int, index: int, command: str = ":") -> str:
    return "\t".join(
        [
            "pane",
            session,
            str(window),
            "0",
            ":",
            str(index),
            "title",
            ":/workspace",
            "1" if index == 1 else "0",
            "zsh",
            command,
        ]
    )


def window(session: str, index: int, name: str = "work") -> str:
    return "\t".join(
        [
            "window",
            session,
            str(index),
            f":{name}",
            "1",
            ":*",
            "b25d,80x24,0,0,0",
            "off",
        ]
    )


def legacy_pane(session: str, window_index: int, pane_index: int) -> str:
    return "\t".join(
        [
            "pane",
            session,
            str(window_index),
            "1",
            ":*",
            str(pane_index),
            ":/workspace",
            "1",
            "zsh",
            "12345",
            ":",
        ]
    )


class SnapshotTests(unittest.TestCase):
    def write_snapshot(self, directory: Path, lines: list[str], name: str = "saved.txt") -> Path:
        path = directory / name
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def test_lists_exact_session_counts_deterministically(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            path = self.write_snapshot(
                directory,
                [
                    pane("team space", 1, 1, ":$(touch /tmp/nope); `false`"),
                    pane("team space", 1, 2),
                    pane("α", 3, 1),
                    window("α", 3, "unicode"),
                    window("team space", 1, "mapping"),
                    "state\tteam space\t",
                ],
            )

            records = snapshot.load_snapshot(path)

            self.assertEqual(
                snapshot.session_rows(records),
                [("team space", 1, 2), ("α", 1, 1)],
            )

    def test_filter_preserves_selected_records_and_excludes_state(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            source = self.write_snapshot(
                directory,
                [
                    pane("keep", 1, 1),
                    window("keep", 1),
                    pane("recover", 2, 1),
                    window("recover", 2, "restored"),
                    "state\trecover\tkeep",
                ],
            )
            output = directory / "filtered.txt"

            snapshot.write_filtered(snapshot.load_snapshot(source), "recover", output)

            self.assertEqual(
                output.read_text(encoding="utf-8").splitlines(),
                [pane("recover", 2, 1), window("recover", 2, "restored")],
            )
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_rejects_duplicate_panes(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            path = self.write_snapshot(
                directory,
                [pane("recover", 1, 1), pane("recover", 1, 1), window("recover", 1)],
            )

            with self.assertRaisesRegex(snapshot.SnapshotError, "duplicate pane"):
                snapshot.load_snapshot(path)

    def test_rejects_noncanonical_numeric_targets(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            malformed = pane("recover", 1, 1).replace("\trecover\t1\t", "\trecover\t+1\t")
            path = self.write_snapshot(directory, [malformed, window("recover", 1)])

            with self.assertRaisesRegex(snapshot.SnapshotError, "canonical nonnegative integer"):
                snapshot.load_snapshot(path)

    def test_rejects_pane_without_window(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            path = self.write_snapshot(directory, [pane("recover", 1, 1)])

            with self.assertRaisesRegex(snapshot.SnapshotError, "has no window record"):
                snapshot.load_snapshot(path)

    def test_rejects_empty_pane_title(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            empty_title = pane("recover", 1, 1).replace("\t1\ttitle\t", "\t1\t\t")
            path = self.write_snapshot(directory, [empty_title, window("recover", 1)])

            with self.assertRaisesRegex(snapshot.SnapshotError, "empty pane title"):
                snapshot.load_snapshot(path)

    def test_rejects_unknown_record_type(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            path = self.write_snapshot(directory, ["future\tdata"])

            with self.assertRaisesRegex(snapshot.SnapshotError, "unknown record type"):
                snapshot.load_snapshot(path)

    def test_rejects_malformed_window_layout(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            malformed = window("recover", 1).replace("b25d,80x24,0,0,0", "not-a-layout")
            path = self.write_snapshot(directory, [pane("recover", 1, 1), malformed])

            with self.assertRaisesRegex(snapshot.SnapshotError, "invalid window layout"):
                snapshot.load_snapshot(path)

    def test_rejects_invalid_window_layout_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            malformed = window("recover", 1).replace("b25d,", "0000,")
            path = self.write_snapshot(directory, [pane("recover", 1, 1), malformed])

            with self.assertRaisesRegex(snapshot.SnapshotError, "invalid window layout checksum"):
                snapshot.load_snapshot(path)

    def test_rejects_oversized_layout_integer(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            malformed = window("recover", 1).replace("80x24", f"{'9' * 5000}x24")
            path = self.write_snapshot(directory, [pane("recover", 1, 1), malformed])

            with self.assertRaisesRegex(snapshot.SnapshotError, "integer is too large"):
                snapshot.load_snapshot(path)

    def test_layout_shape_ignores_pane_identifiers(self) -> None:
        saved = snapshot.parse_layout("f6f2,80x24,0,0[40x24,0,0,11,39x24,41,0,12]")
        live = snapshot.parse_layout("160b,120x40,0,0[60x40,0,0,91,59x40,61,0,92]")

        self.assertEqual(snapshot.layout_shape(saved), snapshot.layout_shape(live))

    def test_publishes_checkpoint_without_overwriting_source(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            staging = directory / "staging"
            archive = directory / "archive"
            staging.mkdir()
            archive.mkdir()
            source = self.write_snapshot(
                staging,
                [pane("recover", 1, 1), window("recover", 1)],
                "tmux_resurrect_20260101T000000.txt",
            )
            collision = self.write_snapshot(
                archive,
                [pane("keep", 1, 1), window("keep", 1)],
                source.name,
            )
            collision_before = collision.read_bytes()

            published = snapshot.publish_checkpoint(source, archive)

            self.assertNotEqual(published, collision)
            self.assertEqual(collision.read_bytes(), collision_before)
            self.assertEqual(published.read_bytes(), source.read_bytes())
            self.assertEqual((archive / "last").resolve(), published)

    def test_publish_refuses_to_replace_regular_last_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            staging = directory / "staging"
            archive = directory / "archive"
            staging.mkdir()
            archive.mkdir()
            source = self.write_snapshot(
                staging,
                [pane("recover", 1, 1), window("recover", 1)],
                "tmux_resurrect_20260101T000000.txt",
            )
            regular_last = self.write_snapshot(
                archive,
                [pane("keep", 1, 1), window("keep", 1)],
                "last",
            )
            before = regular_last.read_bytes()

            with self.assertRaisesRegex(snapshot.SnapshotError, "not a symlink"):
                snapshot.publish_checkpoint(source, archive)

            self.assertEqual(regular_last.read_bytes(), before)

    def test_rejects_grouped_target(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            path = self.write_snapshot(
                directory,
                [
                    pane("recover", 1, 1),
                    window("recover", 1),
                    "grouped_session\trecover\toriginal\t:1\t:1",
                ],
            )
            records = snapshot.load_snapshot(path)

            with self.assertRaisesRegex(snapshot.SnapshotError, "is grouped"):
                snapshot.records_for_session(records, "recover")

    def test_counts_legacy_snapshot_but_refuses_to_filter_it(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            path = self.write_snapshot(
                directory,
                [legacy_pane("recover", 1, 1), window("recover", 1)],
            )
            records = snapshot.load_snapshot(path)

            self.assertEqual(snapshot.session_rows(records), [("recover", 1, 1)])
            with self.assertRaisesRegex(snapshot.SnapshotError, "legacy pane format"):
                snapshot.records_for_session(records, "recover")

    def test_rejects_unsafe_session_name(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            path = self.write_snapshot(directory, [pane("bad:name", 1, 1), window("bad:name", 1)])

            with self.assertRaisesRegex(snapshot.SnapshotError, "unsafe session name"):
                snapshot.load_snapshot(path)

    def test_rejects_tmux_target_metacharacter_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            path = self.write_snapshot(
                directory,
                [pane("=recover", 1, 1), window("=recover", 1)],
            )

            with self.assertRaisesRegex(snapshot.SnapshotError, "unsafe session name"):
                snapshot.load_snapshot(path)

    def test_rejects_session_name_that_tmux_would_canonicalize(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            path = self.write_snapshot(
                directory,
                [pane("recover.one", 1, 1), window("recover.one", 1)],
            )

            with self.assertRaisesRegex(snapshot.SnapshotError, "unsafe session name"):
                snapshot.load_snapshot(path)

    def test_latest_link_must_stay_inside_resurrect_directory(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            root = directory / "resurrect"
            root.mkdir()
            outside = self.write_snapshot(
                directory,
                [pane("recover", 1, 1), window("recover", 1)],
                "outside.txt",
            )
            (root / "last").symlink_to(outside)

            with self.assertRaisesRegex(snapshot.SnapshotError, "outside the resurrect directory"):
                snapshot.resolve_snapshot(root, "latest")

    def test_latest_pointer_must_be_a_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            self.write_snapshot(
                root,
                [pane("recover", 1, 1), window("recover", 1)],
                "last",
            )

            with self.assertRaisesRegex(snapshot.SnapshotError, "not a symlink"):
                snapshot.resolve_snapshot(root, "latest")

    def test_state_encoding_preserves_empty_text_fields(self) -> None:
        delimiter = snapshot.STATE_DELIMITER

        window_rows = snapshot.encode_live_rows(
            "window", [delimiter.join(["0", "", "layout", "off", "0"])]
        )
        pane_rows = snapshot.encode_live_rows(
            "pane", [delimiter.join(["%1", "", "1"])]
        )

        self.assertEqual(window_rows, ["0\tx\tlayout\toff\t0"])
        self.assertEqual(pane_rows, ["%1\tx\t1"])
        self.assertEqual(snapshot.decode_text("x"), "")

    def test_malformed_snapshot_does_not_hide_valid_siblings(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            valid = self.write_snapshot(
                directory,
                [pane("recover", 1, 1), window("recover", 1)],
                "tmux_resurrect_20260102T000000.txt",
            )
            invalid = self.write_snapshot(
                directory,
                ["not-a-record"],
                "tmux_resurrect_20260101T000000.txt",
            )

            self.assertEqual(snapshot.session_rows(snapshot.load_snapshot(valid)), [("recover", 1, 1)])
            with self.assertRaisesRegex(snapshot.SnapshotError, "unknown record type"):
                snapshot.load_snapshot(invalid)


if __name__ == "__main__":
    unittest.main()
