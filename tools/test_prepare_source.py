import importlib.util
import tempfile
import json
from unittest.mock import patch
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

    def test_skm_rejects_patch_drift_before_apply(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "patches").mkdir()
            (root / "patches/skm-workspace.patch").write_bytes(b"modified")
            with patch.object(module, "run") as command:
                with self.assertRaises(ValueError):
                    module.apply_skm(root, root, {"skm_patch_sha256": "0" * 64})
                command.assert_not_called()

    def test_skm_applies_exact_delta_and_verifies_entire_tree(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp) / "recipe"
            root = Path(temp) / "source"
            (repo / "patches").mkdir(parents=True)
            root.mkdir()
            content = b"SKM reference only\n"
            patch_path = repo / "patches/skm-workspace.patch"
            patch_path.write_bytes(b"--- /dev/null\n+++ b/scene.txt\n@@ -0,0 +1 @@\n+SKM reference only\n")
            (repo / "patches/skm-workspace.files.json").write_text(json.dumps({"scene.txt": {"sha256": module.sha(content)}}))
            (root / "scene.txt").write_bytes(content)
            expected, count = module.tree_inventory(root)
            (root / "scene.txt").unlink()
            lock = {"skm_patch_sha256": module.sha(patch_path.read_bytes()), "skm_tree_sha256": expected, "skm_tree_files": count}
            self.assertEqual(module.apply_skm(root, repo, lock), (expected, count))
            (root / "scene.txt").unlink()
            lock["skm_tree_sha256"] = "0" * 64
            with self.assertRaises(ValueError):
                module.apply_skm(root, repo, lock)

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

