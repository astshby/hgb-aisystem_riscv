"""Check locked downloads, cache integrity and failed-download cleanup without a network."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from asset_fetch import fetch


class AssetFetchTest(unittest.TestCase):
    def test_download_and_offline_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target = root / "source", root / "assets/target"
            source.write_bytes(b"locked model input")
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            fetch(source.as_uri(), target, digest)
            source.unlink()
            fetch(source.as_uri(), target, digest)
            self.assertEqual(target.read_bytes(), b"locked model input")

    def test_bad_download_not_published(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.write_bytes(b"wrong bytes")
            with self.assertRaisesRegex(ValueError, "download SHA256 mismatch"):
                fetch(source.as_uri(), root / "assets/model", "0" * 64)
            self.assertEqual(list((root / "assets").iterdir()), [])

    def test_existing_modified_file_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "model"
            target.write_bytes(b"local change")
            with self.assertRaisesRegex(ValueError, "inspect existing"):
                fetch("https://unused.invalid/model", target, "0" * 64)
            self.assertEqual(target.read_bytes(), b"local change")
