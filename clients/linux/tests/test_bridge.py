import json
import unittest
from pathlib import Path
from types import SimpleNamespace

from ssbnk_client.gnome_bridge import GNOMEBridge


class FakeGLib:
    @staticmethod
    def Variant(signature, value):
        return SimpleNamespace(signature=signature, unpack=lambda: value)


class FakeInvocation:
    def __init__(self):
        self.value = None
        self.error = None

    def return_value(self, value):
        self.value = value.unpack()

    def return_dbus_error(self, name, message):
        self.error = (name, message)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.bridge = GNOMEBridge.__new__(GNOMEBridge)
        self.bridge.GLib = FakeGLib
        self.bridge.companion_owner = ":1.42"
        self.bridge.generation = 3
        self.bridge.tokens = {
            "token": {
                "uuid": "capture-id",
                "url": "https://ss.delo.sh/capture.png",
                "consumed": False,
                "generation": 3,
            }
        }
        self.commands = []
        self.bridge.worker = SimpleNamespace(submit=lambda *args: self.commands.append(args))

    def call(self, method, values, sender=":1.42"):
        invocation = FakeInvocation()
        self.bridge.method_call(
            None, sender, "", "", method, SimpleNamespace(unpack=lambda: values), invocation
        )
        return invocation

    def test_stale_generation_and_second_claim_are_rejected(self):
        stale = self.call("ClaimCopy", ("token", 2))
        self.assertIsNotNone(stale.error)
        claimed = self.call("ClaimCopy", ("token", 3))
        self.assertEqual(claimed.value, ("https://ss.delo.sh/capture.png",))
        self.assertTrue(self.bridge.tokens["token"]["consumed"])
        self.assertIsNotNone(self.call("ClaimCopy", ("token", 3)).error)

    def test_acknowledgement_distinguishes_unknown_and_write_issued(self):
        self.call("ClaimCopy", ("token", 3))
        acknowledged = self.call("AcknowledgeCopy", ("token", 3, "unknown"))
        self.assertIsNone(acknowledged.error)
        self.assertEqual(self.commands, [("copy_ack", ("capture-id", "unknown"))])
        self.assertEqual(self.bridge.tokens, {})

    def test_snapshot_interface_is_credential_free(self):
        xml = Path(__file__).parents[1] / "src/ssbnk_client/client1.xml"
        value = xml.read_text().lower()
        self.assertNotIn("credential", value)
        self.assertNotIn("upload-key", value)
        self.bridge.snapshot = {"version": 1, "revision": 4, "rows": []}
        result = self.call("GetSnapshot", ())
        self.assertEqual(json.loads(result.value[0])["revision"], 4)


if __name__ == "__main__":
    unittest.main()
