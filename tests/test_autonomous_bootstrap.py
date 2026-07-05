import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.maintenance import autonomous_bootstrap as ab


class AutonomousBootstrapTests(unittest.TestCase):
    def test_plan_recovery_actions_when_network_and_services_are_down(self):
        plan = ab.plan_recovery_actions(
            internet_available=False,
            services_active={"bot": False, "dashboard": False, "llama": False},
            project_ready_flag=False,
        )
        self.assertIn("adaptive_recovery", plan)
        self.assertIn("service_restart", plan)
        self.assertIn("bootstrap_project", plan)

    def test_plan_recovery_actions_when_system_is_healthy(self):
        plan = ab.plan_recovery_actions(
            internet_available=True,
            services_active={"bot": True, "dashboard": True, "llama": True},
            project_ready_flag=True,
        )
        self.assertEqual(plan, [])

    def test_discover_installed_components_uses_path_lookup(self):
        with patch("scripts.maintenance.autonomous_bootstrap.shutil.which", side_effect=lambda name: f"/usr/bin/{name}" if name in {"python3", "bash"} else None):
            components = ab.discover_installed_components(["python3", "bash", "missing-tool"])
        self.assertEqual([c["name"] for c in components], ["python3", "bash"])
        self.assertEqual(components[0]["path"], "/usr/bin/python3")

    def test_build_sync_plan_uses_project_state_paths(self):
        components = [{"name": "python3", "path": "/usr/bin/python3", "kind": "binary"}]
        plan = ab.build_sync_plan(components, base_dir=Path("/tmp/cerberus"))
        self.assertEqual(plan[0]["target"], Path("/tmp/cerberus/state/discovered/usr/bin/python3"))

    def test_is_supported_environment_requires_linux_ubuntu_headless(self):
        self.assertTrue(ab.is_supported_environment(system_name="Linux", default_target="multi-user.target", os_release={"ID": "ubuntu"}))
        self.assertFalse(ab.is_supported_environment(system_name="Windows", default_target="multi-user.target", os_release={"ID": "ubuntu"}))
        self.assertFalse(ab.is_supported_environment(system_name="Linux", default_target="graphical.target", os_release={"ID": "ubuntu"}))
        self.assertFalse(ab.is_supported_environment(system_name="Linux", default_target="multi-user.target", os_release={"ID": "debian"}))

    def test_extract_learning_signals_from_ubuntu_docs(self):
        signals = ab.extract_learning_signals("Ubuntu Server Guide covers netplan, systemd, and SSH headless setup")
        self.assertIn("netplan", signals)
        self.assertIn("systemd", signals)
        self.assertIn("ssh", signals)

    def test_plan_recovery_actions_prefers_adaptive_recovery(self):
        plan = ab.plan_recovery_actions(
            internet_available=False,
            services_active={"bot": True, "dashboard": True, "llama": True},
            project_ready_flag=True,
        )
        self.assertIn("adaptive_recovery", plan)
        self.assertNotIn("wifi_recovery", plan)
        self.assertNotIn("tether_recovery", plan)

    def test_prioritize_recovery_actions_uses_learning_history(self):
        state = {"success_scores": {"adaptive_recovery": 3, "service_restart": 1}}
        prioritized = ab.prioritize_recovery_actions(["service_restart", "adaptive_recovery", "bootstrap_project"], state)
        self.assertEqual(prioritized[0], "adaptive_recovery")


if __name__ == "__main__":
    unittest.main()
