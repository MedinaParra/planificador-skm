import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("prepare_source", Path(__file__).with_name("prepare_source.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareSourceTests(unittest.TestCase):
    def test_rejects_escaping_paths(self):
        for path in ("", "../outside", "/absolute", "C:/absolute", "a\\b", "a/../b"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                module.checked_path(Path("root"), path)

    def test_verifies_bytes_and_rejects_drift(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            file = root / "test.rs"
            file.write_bytes(b"fn main() {}\n")
            manifest = {"test.rs": {"sha256": module.sha(file.read_bytes())}}
            module.verify_files(root, manifest)
            first = module.tree_inventory(root)
            file.write_bytes(b"changed")
            with self.assertRaises(ValueError):
                module.verify_files(root, manifest)
            self.assertNotEqual(first, module.tree_inventory(root))

    def test_inventory_ignores_only_git_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "src").mkdir()
            (root / "src/main.rs").write_text("fn main() {}")
            first = module.tree_inventory(root)
            (root / ".git").mkdir()
            (root / ".git/HEAD").write_text("unborn")
            self.assertEqual(first, module.tree_inventory(root))
            self.assertEqual(first[1], 1)


if __name__ == "__main__":
    unittest.main()
