import hashlib
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from ssbnk_client.config import Configuration, StateError, parse_origin
from ssbnk_client.scanner import Scanner
from ssbnk_client.session import Singleton
from ssbnk_client.store import Identity, Store
from ssbnk_client.upload import UploadError, parse_receipt


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.images = self.root / "images"
        self.videos = self.root / "videos"
        self.images.mkdir()
        self.videos.mkdir()
        self.store = Store(self.root / "state/ledger.sqlite")
        self.scanner = Scanner(self.store, self.root / "state/outbox")
        self.configuration = Configuration(
            str(self.images),
            str(self.videos),
            credential_reference="op://DeLoSecrets/test/credential",
        )

    def tearDown(self):
        self.store.close()
        self.temporary.cleanup()

    def capture(self, name="capture.png", kind="image", auto=True):
        path = self.images / name
        path.write_bytes(b"durable capture")
        return self.store.observe(Identity.current(path), kind, self.configuration.api_origin, auto)

    def ready(self, capture):
        digest = hashlib.sha256(b"durable capture").hexdigest()
        filename = capture.uuid + (".png" if capture.kind == "image" else ".gif")
        receipt = {
            "version": 2,
            "uuid": capture.uuid,
            "kind": capture.kind,
            "size": capture.identity.size,
            "profile": capture.profile,
            "sha256": digest,
            "offset": capture.identity.size,
            "state": "ready",
            "attempt": 1,
            "accepted_at": "2026-10-05T00:00:00Z",
            "result": {
                "metadata_id": capture.uuid,
                "filename": filename,
                "url": capture.origin + "/" + filename,
                "availability": "available",
                "media_type": "image/png" if capture.kind == "image" else "image/gif",
                "size": capture.identity.size,
                "sha256": digest,
            },
        }
        return self.store.transition(capture.uuid, phase="ready", receipt=receipt, sha256=digest)

    def test_initial_baseline_restart_and_alias_coverage(self):
        (self.images / "old.png").write_bytes(b"old")
        self.scanner.reconcile(self.configuration)
        self.assertEqual(self.store.captures(), [])
        new = self.images / "missed.png"
        new.write_bytes(b"new")
        resumed = Scanner(self.store, self.scanner.outbox)
        resumed.reconcile(self.configuration)
        resumed.samples[str(new)] = (Identity.current(new), time.monotonic() - 1)
        resumed.reconcile(self.configuration)
        self.assertEqual(len(self.store.captures()), 1)
        alias = self.root / "alias"
        alias.symlink_to(self.images, target_is_directory=True)
        aliased = Configuration(
            str(alias), str(self.images), credential_reference="op://DeLoSecrets/test/key"
        )
        self.assertEqual(len(aliased.roots()), 1)
        resumed.reconcile(aliased)
        self.assertEqual(len(self.store.captures()), 1)

    def test_verified_stage_is_authoritative_after_original_deletion(self):
        capture = self.capture()
        self.scanner.stage(capture)
        staged = self.store.get(capture.uuid)
        self.assertEqual(staged.phase, "queued")
        Path(capture.identity.path).unlink()
        self.assertTrue(self.scanner.recover_stage(staged))
        self.assertEqual(self.store.get(capture.uuid).uuid, capture.uuid)

    def test_capacity_deferred_then_recovery_and_changed_original(self):
        capture = self.capture()
        with patch("ssbnk_client.scanner.STAGING_BUDGET", 1):
            self.scanner.stage(capture)
        deferred = self.store.get(capture.uuid)
        self.assertEqual(deferred.phase, "deferred")
        self.assertIsNone(deferred.staged_path)
        self.scanner.stage(deferred)
        self.assertEqual(self.store.get(capture.uuid).phase, "queued")
        changed = self.capture("changed.png")
        Path(changed.identity.path).write_bytes(b"different identity")
        self.scanner.stage(changed)
        self.assertEqual(self.store.get(changed.uuid).phase, "error")
        self.assertIn("changed", self.store.get(changed.uuid).error.lower())

    def test_missing_stage_never_rebuilds_from_changed_original(self):
        capture = self.capture()
        self.scanner.stage(capture)
        staged = self.store.get(capture.uuid)
        Path(staged.staged_path).unlink()
        Path(capture.identity.path).write_bytes(b"new bytes")
        self.assertFalse(self.scanner.recover_stage(staged))
        self.assertEqual(self.store.get(capture.uuid).phase, "error")

    def test_broken_root_does_not_block_other_root(self):
        missing = self.root / "missing"
        configuration = Configuration(
            str(self.images), str(missing), credential_reference="op://DeLoSecrets/test/key"
        )
        self.scanner.reconcile(configuration)
        path = self.images / "healthy.png"
        path.write_bytes(b"capture")
        self.scanner.reconcile(configuration)
        self.scanner.samples[str(path)] = (Identity.current(path), time.monotonic() - 1)
        self.scanner.reconcile(configuration)
        self.assertEqual(len(self.store.captures()), 1)
        self.assertIn(str(missing), self.scanner.root_errors)

    def test_copy_claim_fence_failure_and_no_retransmission(self):
        older = self.ready(self.capture("older.mov", "video"))
        newer = self.ready(self.capture("newer.png"))
        self.assertIsNone(self.store.claim_copy(older.uuid))
        claimed = self.store.claim_copy(newer.uuid)
        self.assertTrue(claimed.copy_consumed)
        self.assertIsNone(self.store.claim_copy(newer.uuid))
        self.store.transition(newer.uuid, copy_warning="Copy failed")
        self.assertEqual(self.store.get(newer.uuid).phase, "ready")
        self.assertIsNotNone(self.store.claim_copy(older.uuid, manual=True))
        self.assertIsNone(self.store.claim_copy(newer.uuid))
        backfill = self.ready(self.capture("backfill.png", auto=False))
        self.assertIsNone(self.store.claim_copy(backfill.uuid))

    def test_receipt_rejects_acceptance_as_ready_wrong_uuid_and_url(self):
        capture = self.ready(self.capture())
        receipt = capture.receipt
        self.assertEqual(parse_receipt(receipt, capture)["state"], "ready")
        for field, value in [("uuid", "another"), ("offset", -1), ("state", "verifying")]:
            invalid = dict(receipt, **{field: value})
            with self.assertRaises(UploadError):
                parse_receipt(invalid, capture)
        invalid = dict(
            receipt, result=dict(receipt["result"], url="https://wrong.example/image.png")
        )
        with self.assertRaises(UploadError):
            parse_receipt(invalid, capture)

    def test_corrupt_and_future_ledgers_fail_closed(self):
        path = self.root / "future.sqlite"
        connection = sqlite3.connect(path)
        connection.execute("PRAGMA user_version=999")
        connection.close()
        with self.assertRaises(StateError):
            Store(path)
        corrupt = self.root / "corrupt.sqlite"
        corrupt.write_bytes(b"not sqlite")
        with self.assertRaises(sqlite3.DatabaseError):
            Store(corrupt)
        self.assertEqual(corrupt.read_bytes(), b"not sqlite")

    def test_singleton_is_kernel_held(self):
        first = Singleton(self.root / "singleton")
        try:
            with self.assertRaises(StateError):
                Singleton(self.root / "singleton")
        finally:
            first.close()

    def test_https_and_loopback_only(self):
        for origin in (
            "http://ss.delo.sh",
            "https://user:secret@ss.delo.sh",
            "https://ss.delo.sh/upload",
        ):
            with self.assertRaises(ValueError):
                parse_origin(origin)
        self.assertEqual(parse_origin("http://127.0.0.1:13143"), "http://127.0.0.1:13143")

    def test_pinned_origin_and_copy_claim_survive_restart(self):
        capture = self.ready(self.capture())
        self.store.claim_copy(capture.uuid)
        self.store.close()
        self.store = Store(self.root / "state/ledger.sqlite")
        restored = self.store.get(capture.uuid)
        self.assertEqual(restored.origin, "https://ss.delo.sh")
        self.assertTrue(restored.copy_consumed)
        self.assertIsNone(self.store.claim_copy(capture.uuid))


if __name__ == "__main__":
    unittest.main()
