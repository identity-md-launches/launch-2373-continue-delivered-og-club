"""Validate the delivered constructor-only Sepolia manifest against compiler ABIs."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LaunchManifestTest(unittest.TestCase):
    def test_exact_deployment_order_owners_and_dependencies(self):
        manifest = json.loads((ROOT / "launch.json").read_text())
        self.assertEqual(set(manifest), {"kind", "contracts", "notes"})
        self.assertEqual(manifest["kind"], "evm_contracts")
        self.assertIsInstance(manifest["notes"], str)
        self.assertLessEqual(len(manifest["notes"]), 4000, "launch notes exceed the manifest limit")
        expected = [
            ("MockOG", ["$owner"]),
            ("OGClubFurniture", ["$owner", "$owner"]),
            ("OGClubFarmVault", ["$contract:MockOG", "$owner"]),
            ("OGClubStaking", ["$contract:MockOG", "$contract:OGClubFarmVault", "$owner", "1000000000000000000"]),
            ("OGClubRaffle", ["$contract:OGClubStaking", "$contract:OGClubFurniture", "$owner", "0"]),
            ("MockSwarmPepe", []),
            ("OGClubClubs", [
                "$contract:MockOG", "$contract:OGClubFarmVault", "100000000000000000000000",
                "$contract:OGClubFurniture", "$owner", "$owner",
                "$contract:MockSwarmPepe", "0x00000000000000447e69651d841bD8D104Bed493",
                "200000000000000000000000", "400000000000000000000000", "800000000000000000000000",
            ]),
        ]
        self.assertEqual([(c["contract"], c["constructorArgs"]) for c in manifest["contracts"]], expected)
        seen = set()
        for name, args in expected:
            abi = json.loads(subprocess.check_output(["forge", "inspect", name, "abi", "--json"], cwd=ROOT, text=True))
            constructor = next(entry for entry in abi if entry["type"] == "constructor")
            self.assertEqual(constructor["stateMutability"], "nonpayable")
            # The factory flattens static structs, not fixed arrays. This catches the
            # previous attempt's nine-input uint256[3] / eleven-word mismatch.
            def flatten(fields):
                for field in fields:
                    if field["type"] == "tuple":
                        yield from flatten(field["components"])
                    else:
                        self.assertNotIn("[", field["type"], "factory constructor arrays are unsupported")
                        yield field
            fields = list(flatten(constructor["inputs"]))
            self.assertEqual(len(args), len(fields))
            self.assertLessEqual(len(args), 16)
            self.assertLessEqual(len(name), 32)
            for arg, field in zip(args, fields):
                self.assertIn(field["type"], {"address", "uint256"})
                if arg.startswith("$contract:"):
                    self.assertEqual(field["type"], "address")
                    self.assertIn(arg.split(":", 1)[1], seen)
                elif arg == "$owner":
                    self.assertEqual(field["type"], "address")
                else:
                    self.assertGreaterEqual(int(arg, 16) if arg.startswith("0x") else int(arg), 0)
            seen.add(name)
        self.assertIn("FIRST grant", manifest["notes"])
        self.assertIn("604800", manifest["notes"])
        self.assertNotIn("OGClubBox", seen)
        self.assertIn("sale closed", manifest["notes"])
        self.assertIn("285", manifest["notes"])
        self.assertIn("Sepolia-only", manifest["notes"])
        self.assertIn("DEPLOYER_KEY", manifest["notes"])


if __name__ == "__main__":
    unittest.main()
