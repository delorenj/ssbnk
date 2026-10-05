import tempfile
import unittest
from pathlib import Path

from ssbnk_client.config import Configuration
from ssbnk_client.legacy import LegacyHandover, import_nonsecret_legacy
from ssbnk_client.store import Store


class HandoverTests(unittest.TestCase):
    def test_nonsecret_import_never_executes_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "remote.env"
            path.write_text(
                "SSBNK_HOST=https://ss.delo.sh\nSSBNK_UPLOAD_KEY=never-import\n"
                "SSBNK_SCREENSHOT_DIR='/safe/screenshots'\n"
            )
            values = import_nonsecret_legacy(path)
            self.assertNotIn("SSBNK_UPLOAD_KEY", values)
            self.assertEqual(values["SSBNK_SCREENSHOT_DIR"], "/safe/screenshots")
            path.write_text("SSBNK_HOST=$(touch /tmp/not-executed)\n")
            with self.assertRaises(ValueError):
                import_nonsecret_legacy(path)

    def test_failed_disable_preserves_rollback_and_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store(root / "state/ledger.sqlite")
            configuration = Configuration(
                str(root / "images"),
                str(root / "videos"),
                credential_reference="op://DeLoSecrets/test/key",
            )
            calls = []

            def command(*arguments):
                calls.append(arguments)
                if arguments[0] in ("is-active", "is-enabled"):
                    return True
                return arguments[0] != "disable"

            migration = LegacyHandover(
                store,
                configuration,
                root / "state",
                lambda _: "test-key",
                lambda directory, credential: None,
                command,
                lambda: True,
                root / "absent.env",
            )
            try:
                with self.assertRaises(ValueError):
                    migration.execute(True)
                self.assertEqual(store.setting("handover"), "pending")
                self.assertTrue(store.setting("handover_boundary"))
                self.assertIn(("enable", "ssbnk-remote-upload.service"), calls)
                self.assertIn(("start", "ssbnk-remote-upload.service"), calls)
            finally:
                store.close()

    def test_vault_mismatch_never_disables_or_deletes_legacy_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store(root / "state/ledger.sqlite")
            legacy = root / "remote.env"
            legacy.write_text("SSBNK_UPLOAD_KEY=old-test-key\n")
            calls = []
            migration = LegacyHandover(
                store,
                Configuration(
                    str(root / "images"),
                    str(root / "videos"),
                    credential_reference="op://DeLoSecrets/test/key",
                ),
                root / "state",
                lambda _: "different-test-key",
                lambda *_: None,
                lambda *args: calls.append(args),
                lambda: True,
                legacy,
            )
            try:
                with self.assertRaises(ValueError):
                    migration.execute(True)
                self.assertEqual(calls, [])
                self.assertTrue(legacy.exists())
            finally:
                store.close()


if __name__ == "__main__":
    unittest.main()
