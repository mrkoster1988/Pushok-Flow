import hashlib
import tempfile
import unittest
from pathlib import Path
from tools.check_updates import is_update, version_tuple, check_sha256, validate_rules_update

class UpdatesTests(unittest.TestCase):
    def test_upgrade(self):
        self.assertTrue(is_update('0.1.0', '0.1.1'))
        self.assertFalse(is_update('0.1.1', '0.1.0'))
        self.assertFalse(is_update('0.1.0', '0.1.0'))
    def test_invalid_version(self):
        with self.assertRaises(ValueError): version_tuple('0.1.0-preview')
    def test_checksum(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'data'
            path.write_bytes(b'pushok')
            self.assertTrue(check_sha256(path, hashlib.sha256(b'pushok').hexdigest()))
            self.assertFalse(check_sha256(path, '0'*64))
    def test_rules_rollback(self):
        self.assertTrue(validate_rules_update(1, 2))
        self.assertFalse(validate_rules_update(2, 1))

if __name__ == '__main__': unittest.main()