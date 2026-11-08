"""Host-only checks for owned simulator creation and bounded cleanup."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

script = Path(__file__).parent / "ios_cpython/run_cpython_probe.py"
spec = importlib.util.spec_from_file_location("owned_simulator_probe", script)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

TEMPLATE = "11111111-1111-4111-8111-111111111111"
CREATED = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"


class BeforeBoot(Exception):
    pass


class OwnedSimulatorTests(unittest.TestCase):
    def setUp(self):
        self.commands = []

    def command(self, *args, **kwargs):
        self.commands.append(args)
        if args[2] == "list":
            return json.dumps({"devices": {RUNTIME: [{"udid": TEMPLATE,
                "name": "iPhone 16 Pro", "state": "Shutdown", "isAvailable": True,
                "deviceTypeIdentifier": DEVICE_TYPE}]}})
        if args[2] == "create":
            return CREATED
        if args[2] == "boot":
            raise BeforeBoot()
        raise AssertionError(args)

    def test_fresh_creation_uses_exact_runtime_and_type_then_owns_only_new_device(self):
        progress = {}
        with patch.object(probe, "run", side_effect=self.command), self.assertRaises(BeforeBoot):
            probe.simulator_run(Path("owned.app"), None, progress, fresh=True)
        self.assertEqual(progress["owned_simulator_udid"], CREATED)
        self.assertEqual(progress["simulator_udid"], CREATED)
        self.assertEqual(progress["simulator_template_udid"], TEMPLATE)
        create = next(c for c in self.commands if c[2] == "create")
        self.assertEqual(create[-2:], (DEVICE_TYPE, RUNTIME))
        self.assertEqual(self.commands[-1], ("xcrun", "simctl", "boot", CREATED))

    def test_explicit_device_is_never_owned_or_deleted(self):
        progress = {}
        with patch.object(probe, "run", side_effect=self.command), self.assertRaises(BeforeBoot):
            probe.simulator_run(Path("owned.app"), TEMPLATE, progress, fresh=True)
        self.assertNotIn("owned_simulator_udid", progress)
        with patch.object(probe.subprocess, "run") as command:
            probe.cleanup_owned_simulator(progress)
            command.assert_not_called()
        self.assertFalse(any(c[2] == "create" for c in self.commands))

    def test_cleanup_targets_only_owned_uuid_and_has_finite_timeouts(self):
        progress = {"owned_simulator_udid": CREATED, "simulator_udid": CREATED}
        with patch.object(probe.subprocess, "run") as command:
            probe.cleanup_owned_simulator(progress)
        self.assertEqual(progress["owned_simulator_cleanup"], "deleted")
        self.assertEqual([c.args[0] for c in command.call_args_list], [
            ["xcrun", "simctl", "shutdown", CREATED],
            ["xcrun", "simctl", "delete", CREATED]])
        self.assertTrue(all(c.kwargs["timeout"] == 30 for c in command.call_args_list))

    def test_cleanup_rejects_identity_mismatch_without_touching_a_device(self):
        with patch.object(probe.subprocess, "run") as command, self.assertRaises(ValueError):
            probe.cleanup_owned_simulator({"owned_simulator_udid": CREATED, "simulator_udid": TEMPLATE})
        command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
