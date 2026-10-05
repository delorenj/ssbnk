import json
import unittest
from pathlib import Path

from ssbnk_client.store import Capture, Identity
from ssbnk_client.upload import parse_receipt


class SharedFixturesTests(unittest.TestCase):
    def test_all_receipt_states_use_shared_protocol_fixture(self):
        fixture = Path(__file__).resolve().parents[2] / "protocol/fixtures/receipts.json"
        for receipt in json.loads(fixture.read_text())["receipts"]:
            capture = Capture(
                receipt["uuid"],
                Identity("/capture", receipt["size"], 0, 0, 0),
                receipt["kind"],
                0,
                1,
                "https://ss.delo.sh",
                receipt["profile"],
                "queued",
                "/stage",
                receipt["sha256"],
                0,
                1,
                0,
                None,
                None,
                False,
                False,
                None,
            )
            parsed = parse_receipt(receipt, capture)
            self.assertEqual("result" in parsed, parsed["state"] == "ready")


if __name__ == "__main__":
    unittest.main()
