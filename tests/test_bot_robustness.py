import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BOT_PATH = ROOT / "src" / "bot" / "telegram_bot.py"


class TelegramBotRobustnessTests(unittest.TestCase):
    def load_module(self):
        spec = importlib.util.spec_from_file_location("telegram_bot_under_test", BOT_PATH)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

    def test_load_settings_handles_missing_token(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            os.environ.pop("TELEGRAM_TOKEN", None)
            os.environ.pop("LLAMA_API", None)
            os.environ["CERBERUS_ASIST_BASE"] = tmpdir
            module = self.load_module()
            cfg = module.load_settings()
            self.assertIsNone(cfg.token)
            self.assertTrue(cfg.errors)
            self.assertIn("TELEGRAM_TOKEN", cfg.errors[0])

    def test_safe_chat_completion_returns_friendly_error_when_model_unavailable(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            os.environ["CERBERUS_ASIST_BASE"] = tmpdir
            os.environ["LLAMA_API"] = "http://127.0.0.1:1"
            module = self.load_module()
            cfg = module.load_settings()
            ok, text = module.safe_chat_completion("test", cfg)
            self.assertFalse(ok)
            self.assertIn("Layanan model", text)


if __name__ == "__main__":
    unittest.main()
