from __future__ import annotations

import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from typer.testing import CliRunner

from ssbnk_cli.main import app

runner = CliRunner()


class TestSSBNKCLI(unittest.TestCase):
    def test_config_plain(self) -> None:
        result = runner.invoke(app, ["config", "--plain"])
        self.assertEqual(result.exit_code, 0)
        self.assertIn("SSBNK_URL=", result.output)
        self.assertIn("SSBNK_HOSTED_DIR=", result.output)
        self.assertIn("SSBNK_STATE_DIR=", result.output)

    def test_config_json(self) -> None:
        result = runner.invoke(app, ["config", "--json"])
        self.assertEqual(result.exit_code, 0)
        data = json.loads(result.output)
        self.assertIn("SSBNK_URL", data)
        self.assertIn("value", data["SSBNK_URL"])
        self.assertIn("source", data["SSBNK_URL"])

    def test_config_single_key(self) -> None:
        result = runner.invoke(app, ["config", "SSBNK_URL"])
        self.assertEqual(result.exit_code, 0)
        self.assertTrue(result.output.strip().startswith("http"))

    def test_config_unknown_key(self) -> None:
        result = runner.invoke(app, ["config", "UNKNOWN_KEY_XYZ_987"])
        self.assertNotEqual(result.exit_code, 0)

    def test_marker_precedes_newer_images_and_clipboard_matches_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            hosted = root / "hosted"
            screenshots = root / "screenshots"
            state = root / "state"
            for directory in (hosted, screenshots, state):
                directory.mkdir()
            marked = hosted / "old image.PNG"
            newer = screenshots / "new.jpg"
            newest = hosted / "newest.webp"
            for image, mtime in ((marked, 100), (newer, 200), (newest, 300)):
                image.write_bytes(b"image")
                os.utime(image, (mtime, mtime))
            (state / "last-screenshot").write_text(marked.name + "\n")
            config = self._config(root, hosted=hosted, screenshots=screenshots, state=state)
            expected = "\n".join(str(p.resolve()) for p in (marked, newest, newer))
            with patch("ssbnk_cli.main.get_config_map", return_value=config), patch(
                "ssbnk_cli.main.copy_to_wl_clipboard", return_value=(True, None)
            ) as copied:
                for args in (["get", "3"], ["get", "3", "--copy"]):
                    with self.subTest(args=args):
                        result = runner.invoke(app, args)
                        self.assertEqual(result.exit_code, 0, result.output)
                        self.assertEqual(result.stdout, expected + "\n")
                self.assertEqual(copied.call_count, 2)
                copied.assert_called_with(expected)

                for args in (["get"], ["get", "1"]):
                    with self.subTest(args=args):
                        self.assertEqual(runner.invoke(app, args).stdout, str(marked.resolve()) + "\n")
                copied.assert_called_with(str(marked.resolve()))

    def test_missing_absolute_marker_uses_basename_before_newer_images(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            hosted = root / "hosted"
            screenshots = root / "screenshots"
            state = root / "state"
            for directory in (hosted, screenshots, state):
                directory.mkdir()
            marked = hosted / "saved.png"
            newer = screenshots / "newer.webp"
            for image, mtime in ((marked, 100), (newer, 200)):
                image.write_bytes(b"image")
                os.utime(image, (mtime, mtime))
            (state / "last-screenshot").write_text(str(root / "gone" / marked.name))
            config = self._config(root, hosted=hosted, screenshots=screenshots, state=state)
            with patch("ssbnk_cli.main.get_config_map", return_value=config), patch(
                "ssbnk_cli.main.copy_to_wl_clipboard", return_value=(True, None)
            ) as copied:
                for args, expected in (
                    (["get"], str(marked.resolve())),
                    (["get", "1"], str(marked.resolve())),
                    (["get", "2"], f"{marked.resolve()}\n{newer.resolve()}"),
                ):
                    with self.subTest(args=args):
                        result = runner.invoke(app, args)
                        self.assertEqual(result.exit_code, 0, result.output)
                        self.assertEqual(result.stdout, expected + "\n")
                        copied.assert_called_with(expected)
                self.assertEqual(copied.call_count, 3)

    def test_single_valid_marker_skips_directory_and_ledger_scans(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            state = root / "state"
            state.mkdir()
            marked = root / "saved.png"
            marked.write_bytes(b"image")
            (state / "last-screenshot").write_text(str(marked))
            with patch("ssbnk_cli.main.get_config_map", return_value=self._config(root, state=state)), patch(
                "ssbnk_cli.get._directory_images", side_effect=AssertionError("directory scan")
            ), patch("ssbnk_cli.get._ledger_images", side_effect=AssertionError("ledger scan")):
                for args in (["get", "--no-copy"], ["get", "1", "--no-copy"]):
                    with self.subTest(args=args):
                        result = runner.invoke(app, args)
                        self.assertEqual(result.exit_code, 0, result.output)
                        self.assertEqual(result.stdout, str(marked.resolve()) + "\n")

    def test_scan_ties_dedup_overlapping_dirs_and_filters_nonimages(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            hosted = root / "hosted"
            hosted.mkdir()
            z = hosted / "z.gif"
            a = hosted / "a.jpeg"
            for image in (z, a):
                image.write_bytes(b"image")
                os.utime(image, ns=(1234567890123, 1234567890123))
            (hosted / "not-image.txt").write_text("text")
            (hosted / "folder.png").mkdir()
            (hosted / "a-again.png").symlink_to(a)
            config = self._config(root, hosted=hosted, screenshots=hosted)
            with patch("ssbnk_cli.main.get_config_map", return_value=config), patch(
                "ssbnk_cli.main.copy_to_wl_clipboard", return_value=(True, None)
            ) as copied:
                result = runner.invoke(app, ["get", "9"])
                expected = f"{a.resolve()}\n{z.resolve()}"
                self.assertEqual(result.exit_code, 0)
                self.assertEqual(result.stdout, expected + "\n")
                copied.assert_called_once_with(expected)

    def test_stale_and_nonimage_markers_fall_back_to_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            hosted = root / "hosted"
            state = root / "state"
            hosted.mkdir()
            state.mkdir()
            image = hosted / "shot.png"
            image.write_bytes(b"image")
            text = hosted / "notes.txt"
            text.write_text("text")
            config = self._config(root, hosted=hosted, state=state)
            for marker in ("missing.png", str(text), "notes.txt"):
                with self.subTest(marker=marker):
                    (state / "last-screenshot").write_text(marker)
                    with patch("ssbnk_cli.main.get_config_map", return_value=config):
                        self.assertEqual(runner.invoke(app, ["get", "--no-copy"]).stdout, str(image.resolve()) + "\n")

    def test_absolute_marker_and_data_hosted_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            hosted = root / "data" / "hosted"
            state = root / "state"
            hosted.mkdir(parents=True)
            state.mkdir()
            image = hosted / "image.png"
            image.write_bytes(b"image")
            outside = root / "outside.webp"
            outside.write_bytes(b"image")
            (state / "last-screenshot").write_text(str(outside))
            config = self._config(root, hosted="", state=state)
            config["SSBNK_DATA_DIR"] = str(root / "data")
            with patch("ssbnk_cli.main.get_config_map", return_value=config), patch(
                "ssbnk_cli.main.copy_to_wl_clipboard", return_value=(True, None)
            ) as copied:
                result = runner.invoke(app, ["get", "2"])
                self.assertEqual(result.stdout, f"{outside.resolve()}\n{image.resolve()}\n")
                copied.assert_called_once_with(f"{outside.resolve()}\n{image.resolve()}")

    def test_ledger_only_when_directories_have_no_images(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            ledger = root / ".local/state/ssbnk/ledger.db"
            ledger.parent.mkdir(parents=True)
            old = root / "old.jpg"
            newer = root / "new.gif"
            for image in (old, newer):
                image.write_bytes(b"image")
            conn = sqlite3.connect(ledger)
            try:
                conn.execute("CREATE TABLE captures (kind TEXT, capture_time TEXT, identity TEXT)")
                for kind, time, identity in (
                    ("image", "2026-01-01", {"path": str(old)}),
                    ("video", "2026-07-01", {"path": str(newer)}),
                    ("image", "2026-06-01", {"path": str(newer)}),
                    ("image", "2026-05-01", {"path": str(root / "missing.png")}),
                    ("image", "2026-04-01", {"path": str(newer)}),
                    ("image", "2026-03-01", {"bad": "path"}),
                ):
                    conn.execute("INSERT INTO captures VALUES (?, ?, ?)", (kind, time, json.dumps(identity)))
                conn.commit()
            finally:
                conn.close()
            config = self._config(root)
            with patch("ssbnk_cli.get.Path.home", return_value=root), patch(
                "ssbnk_cli.main.get_config_map", return_value=config
            ), patch("ssbnk_cli.main.copy_to_wl_clipboard", return_value=(True, None)) as copied:
                result = runner.invoke(app, ["get", "4"])
                expected = f"{newer.resolve()}\n{old.resolve()}"
                self.assertEqual(result.exit_code, 0)
                self.assertEqual(result.stdout, expected + "\n")
                copied.assert_called_once_with(expected)
                hosted = Path(config["SSBNK_HOSTED_DIR"])
                hosted.mkdir()
                directory_image = hosted / "dir.png"
                directory_image.write_bytes(b"image")
                result = runner.invoke(app, ["get", "4", "--no-copy"])
                self.assertEqual(result.stdout, str(directory_image.resolve()) + "\n")

    def test_malformed_ledger_identities_do_not_hide_older_valid_images(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            ledger = root / ".local/state/ssbnk/ledger.db"
            ledger.parent.mkdir(parents=True)
            valid = root / "older.png"
            valid.write_bytes(b"image")
            conn = sqlite3.connect(ledger)
            try:
                conn.execute("CREATE TABLE captures (kind TEXT, capture_time TEXT, identity TEXT)")
                for index, identity in enumerate((
                    "[]", "null", "{", "42", '"text"',
                    '{"path": []}', '{"path": 123}', '{"path": null}',
                    json.dumps({"path": str(valid)}),
                )):
                    conn.execute(
                        "INSERT INTO captures VALUES (?, ?, ?)",
                        ("image", f"2026-06-{20 - index:02d}", identity),
                    )
                conn.commit()
            finally:
                conn.close()
            with patch("ssbnk_cli.get.Path.home", return_value=root), patch(
                "ssbnk_cli.main.get_config_map", return_value=self._config(root)
            ), patch("ssbnk_cli.main.copy_to_wl_clipboard", return_value=(True, None)) as copied:
                result = runner.invoke(app, ["get", "3"])
                self.assertEqual(result.exit_code, 0, result.output)
                self.assertEqual(result.stdout, str(valid.resolve()) + "\n")
                copied.assert_called_once_with(str(valid.resolve()))

    def test_no_images_exits_one_without_clipboard(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            with patch("ssbnk_cli.get.Path.home", return_value=root), patch(
                "ssbnk_cli.main.get_config_map", return_value=self._config(root)
            ), patch("ssbnk_cli.main.copy_to_wl_clipboard") as copied:
                result = runner.invoke(app, ["get", "2"])
                self.assertEqual(result.exit_code, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("No recent screenshot", result.stderr)
                copied.assert_not_called()

    def test_invalid_count_fails_before_lookup(self) -> None:
        with patch("ssbnk_cli.main.get_config_map") as lookup, patch(
            "ssbnk_cli.main.copy_to_wl_clipboard"
        ) as copied:
            for args in (["0"], ["-1"], ["abc"], ["1.5"], ["1", "2"]):
                with self.subTest(args=args):
                    result = runner.invoke(app, ["get", *args])
                    self.assertNotEqual(result.exit_code, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertTrue(result.stderr)
            lookup.assert_not_called()
            copied.assert_not_called()

    def test_no_copy_and_warning_modes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            hosted = root / "hosted"
            hosted.mkdir()
            image = hosted / "shot.png"
            image.write_bytes(b"image")
            with patch("ssbnk_cli.main.get_config_map", return_value=self._config(root)), patch(
                "ssbnk_cli.main.copy_to_wl_clipboard", return_value=(False, "wl-copy missing")
            ) as copied:
                no_copy = runner.invoke(app, ["get", "--no-copy"])
                self.assertEqual(no_copy.exit_code, 0)
                self.assertEqual(no_copy.stdout, str(image.resolve()) + "\n")
                self.assertEqual(no_copy.stderr, "")
                copied.assert_not_called()
                warning = runner.invoke(app, ["get"])
                self.assertEqual(warning.exit_code, 0)
                self.assertEqual(warning.stdout, no_copy.stdout)
                self.assertIn("wl-copy missing", warning.stderr)
                for flag in ("--quiet", "-q"):
                    quiet = runner.invoke(app, ["get", flag])
                    self.assertEqual(quiet.exit_code, 0)
                    self.assertEqual(quiet.stdout, no_copy.stdout)
                    self.assertEqual(quiet.stderr, "")

    def test_help_describes_count_and_paths(self) -> None:
        result = runner.invoke(app, ["get", "--help"])
        self.assertEqual(result.exit_code, 0)
        for phrase in ("[num]", "default: 1", "absolute local image paths", "fewer than requested"):
            self.assertIn(phrase, result.stdout)

    @staticmethod
    def _config(root: Path, *, hosted: Path | str | None = None,
                screenshots: Path | None = None, state: Path | None = None) -> dict[str, str]:
        return {
            "SSBNK_STATE_DIR": str(state or root / "state"),
            "SSBNK_HOSTED_DIR": str(hosted if hosted is not None else root / "hosted"),
            "SSBNK_SCREENSHOT_DIR": str(screenshots or root / "screenshots"),
            "SSBNK_DATA_DIR": str(root / "data"),
        }


if __name__ == "__main__":
    unittest.main()
