"""The VoxType config template in main.swift must be valid TOML with the managed defaults.

Pinned VoxType ignores unknown keys silently, so a typo here would not fail at runtime.
"""
import pathlib
import re
import tomllib
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]

def template():
    source = (ROOT / 'Sources/BellowFlow/main.swift').read_text()
    match = re.search(r'func initialConfig\(\) -> String \{.*?"""\n(.*?)\n\s*"""', source, re.S)
    def placeholder(interpolation):
        # Mirror the shape of each Swift interpolation without evaluating it.
        return '"exec \'/placeholder/VoxClean\'"' if '"exec "' in interpolation.group(0) else '"/placeholder/whisper.bin"'
    body = re.sub(r'\\\(.*\)$', placeholder, match.group(1), flags=re.M)
    return tomllib.loads('\n'.join(line.strip() for line in body.splitlines()))

class ConfigTemplateTests(unittest.TestCase):
    def test_template_parses_and_keeps_managed_defaults(self):
        config = template()
        self.assertEqual(config['engine'], 'whisper')
        self.assertEqual(config['state_file'], 'auto')
        # BellowFlow owns the shortcut and overlay; upstream defaults would enable both.
        self.assertFalse(config['hotkey']['enabled'])
        self.assertFalse(config['osd']['enabled'])
        # Whisper stays resident for the whole session.
        whisper = config['whisper']
        self.assertEqual((whisper['mode'], whisper['language'], whisper['translate']), ('local', 'en', False))
        self.assertFalse(whisper['on_demand_loading']); self.assertFalse(whisper['gpu_isolation'])
        self.assertEqual((whisper['max_loaded_models'], whisper['cold_model_timeout_secs']), (1, 0))
        # No transcript leaves the app through notifications or an unexpected Enter keystroke.
        self.assertEqual(set(config['output']['notification'].values()), {False})
        self.assertFalse(config['output']['auto_submit'])
        self.assertEqual(config['output']['mode'], 'type')
        self.assertTrue(config['output']['fallback_to_clipboard'])
        post = config['output']['post_process']
        self.assertTrue(post['command'].startswith('exec '))
        self.assertTrue(post['fallback_on_empty'])
        # VoxClean gives up (56 s) before VoxType kills it, so the raw transcript is still typed.
        self.assertGreater(post['timeout_ms'], 56000)
