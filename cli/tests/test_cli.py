from __future__ import annotations

import json
import os
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

    def test_get_from_marker(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            state_dir = tmp / "state"
            hosted_dir = tmp / "hosted"
            state_dir.mkdir()
            hosted_dir.mkdir()

            test_img = hosted_dir / "shot1.png"
            test_img.write_text("dummy")

            marker = state_dir / "last-screenshot"
            marker.write_text("shot1.png\n")

            env_patch = {
                "SSBNK_STATE_DIR": str(state_dir),
                "SSBNK_HOSTED_DIR": str(hosted_dir),
                "SSBNK_SCREENSHOT_DIR": str(tmp / "screenshots"),
            }

            with patch.dict(os.environ, env_patch), \
                 patch("ssbnk_cli.main.copy_to_wl_clipboard", return_value=(True, None)) as mock_copy:
                result = runner.invoke(app, ["get"])
                self.assertEqual(result.exit_code, 0)
                self.assertEqual(result.output.strip(), str(test_img.resolve()))
                mock_copy.assert_called_once_with(str(test_img.resolve()))

    def test_get_fallback_scan(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            hosted_dir = tmp / "hosted"
            hosted_dir.mkdir()

            older_img = hosted_dir / "older.png"
            older_img.write_text("older")
            os.utime(older_img, (1000, 1000))

            newer_img = hosted_dir / "newer.png"
            newer_img.write_text("newer")
            os.utime(newer_img, (2000, 2000))

            env_patch = {
                "SSBNK_STATE_DIR": str(tmp / "empty_state"),
                "SSBNK_HOSTED_DIR": str(hosted_dir),
                "SSBNK_SCREENSHOT_DIR": str(tmp / "empty_screenshots"),
            }

            with patch.dict(os.environ, env_patch), \
                 patch("ssbnk_cli.main.copy_to_wl_clipboard", return_value=(True, None)) as mock_copy:
                result = runner.invoke(app, ["get"])
                self.assertEqual(result.exit_code, 0)
                self.assertEqual(result.output.strip(), str(newer_img.resolve()))
                mock_copy.assert_called_once_with(str(newer_img.resolve()))

    def test_get_no_screenshot(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            env_patch = {
                "SSBNK_STATE_DIR": str(tmp / "empty_state"),
                "SSBNK_HOSTED_DIR": str(tmp / "empty_hosted"),
                "SSBNK_SCREENSHOT_DIR": str(tmp / "empty_screenshots"),
                "SSBNK_DATA_DIR": str(tmp / "empty_data"),
            }

            with patch.dict(os.environ, env_patch), \
                 patch("ssbnk_cli.get.Path.home", return_value=tmp):
                result = runner.invoke(app, ["get"])
                self.assertEqual(result.exit_code, 1)

    def test_get_no_copy_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            hosted_dir = tmp / "hosted"
            hosted_dir.mkdir()
            img = hosted_dir / "shot.png"
            img.write_text("img")

            env_patch = {
                "SSBNK_STATE_DIR": str(tmp / "empty_state"),
                "SSBNK_HOSTED_DIR": str(hosted_dir),
            }

            with patch.dict(os.environ, env_patch), \
                 patch("ssbnk_cli.main.copy_to_wl_clipboard") as mock_copy:
                result = runner.invoke(app, ["get", "--no-copy"])
                self.assertEqual(result.exit_code, 0)
                self.assertEqual(result.output.strip(), str(img.resolve()))
                mock_copy.assert_not_called()


if __name__ == "__main__":
    unittest.main()
