import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

class V06Tests(unittest.TestCase):
    def test_native_memory_privacy(self):
        text = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/LocalDecisionMemory.kt').read_text()
        self.assertIn('pushok_ai_feedback_v1', text)
        self.assertIn('coerceAtMost(100000L)', text)
        self.assertIn('fun clear()', text)
        self.assertNotIn('INTERNET', text)

    def test_bridge_consistency(self):
        android = (ROOT / 'native/android/app/src/main/kotlin/shop/pushok/flow/MainActivity.kt').read_text()
        dart = (ROOT / 'lib/ai/pushok_ai_memory.dart').read_text()
        for method in ('aiFeedbackRecord', 'aiFeedbackSummary', 'aiFeedbackClear'):
            self.assertIn(method, android)
            self.assertIn(method, dart)

    def test_bootstrap_includes_native_module(self):
        self.assertIn('LocalDecisionMemory.kt', (ROOT / 'tools/bootstrap_android.sh').read_text())

    def test_ui_distinguishes_local_feedback_from_training(self):
        ui = (ROOT / 'lib/main.dart').read_text()
        self.assertIn('Pushok ИИ', ui)
        self.assertIn('Помогло', ui)
        self.assertIn('Не помогло', ui)
        self.assertIn('Очистить память', ui)

if __name__ == '__main__': unittest.main()