"""Reconstruct the pinned public tree plus verified planner/portable patches.

Build helper only: no credentials, pushes, installation or user files. New output
directories are required. The exported source gets an unborn local Git repository
so build scripts cannot mistake the private recipe repository's commit for upstream.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import shutil
import subprocess
import tarfile
from pathlib import Path, PurePosixPath


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def checked_path(root: Path, relative: str) -> Path:
    p = PurePosixPath(relative)
    if not relative or p.is_absolute() or ".." in p.parts or "\\" in relative or ":" in relative:
        raise ValueError(f"Unsafe source path: {relative!r}")
    return root.joinpath(*p.parts)


def run(*args: str, cwd: Path | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def verify_files(root: Path, manifest: dict) -> None:
    for relative, entry in manifest.items():
        file = checked_path(root, relative)
        if file.is_symlink() or not file.is_file() or sha(file.read_bytes()) != entry["sha256"]:
            raise ValueError(f"Source hash mismatch: {relative}")


def tree_inventory(root: Path) -> tuple[str, int]:
    rows = []
    for file in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix()):
        relative = file.relative_to(root)
        if relative.parts[0] == ".git":
            continue
        if file.is_symlink():
            raise ValueError(f"Unexpected source symlink: {relative}")
        if file.is_file():
            rows.append(f"{sha(file.read_bytes())}  {relative.as_posix()}\n")
    return sha("".join(rows).encode("utf-8")), len(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("build-source"))
    parser.add_argument("--upstream", type=Path, default=Path("upstream-git"))
    parser.add_argument("--evidence", type=Path, default=Path("build-evidence"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    lock = json.loads((repo / "source-lock.json").read_text(encoding="utf-8"))
    out, upstream, evidence = (p.resolve() for p in (args.out, args.upstream, args.evidence))
    if any(p.exists() for p in (out, upstream)):
        raise ValueError("Source/upstream output must be new; refusing to overwrite")
    if shutil.disk_usage(repo).free < 9 * 1024**3:
        raise RuntimeError("Runner requires at least 9 GiB free before source reconstruction")
    delta = gzip.decompress((repo / "patches/planificador-05c.patch.gz").read_bytes())
    portable = (repo / "patches/portable.patch").read_bytes()
    if sha(delta) != lock["delta_sha256"] or sha(portable) != lock["portable_patch_sha256"]:
        raise ValueError("Patch checksum mismatch")
    base = lock["base_commit"]
    if len(base) != 40 or any(c not in "0123456789abcdef" for c in base):
        raise ValueError("Base must be an exact 40-character commit")
    if lock["upstream"] != "https://github.com/tangency-labs/solidcraft.git":
        raise ValueError("Unexpected upstream")
    evidence.mkdir(parents=True, exist_ok=True)
    upstream.mkdir()
    run("git", "init", "--bare", "--quiet", str(upstream))
    # git archive applies working-tree conversion; Windows defaults can emit CRLF.
    # Preserve pinned blob bytes so patch and complete-tree hashes remain strict.
    run("git", "-C", str(upstream), "config", "core.autocrlf", "false")
    run("git", "-C", str(upstream), "config", "core.eol", "lf")
    run("git", "-C", str(upstream), "-c", "credential.helper=", "fetch", "--depth=1", lock["upstream"], base)
    fetched = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "FETCH_HEAD"], text=True).strip()
    if fetched != base:
        raise ValueError("Fetched public commit does not match the source lock")
    out.mkdir()
    proc = subprocess.Popen(["git", "-C", str(upstream), "archive", "--format=tar", base], stdout=subprocess.PIPE)
    try:
        assert proc.stdout is not None
        with tarfile.open(fileobj=proc.stdout, mode="r|") as archive:
            for member in archive:
                checked_path(out, member.name.rstrip("/"))
                if not (member.isfile() or member.isdir()):
                    raise ValueError(f"Unsupported archive entry: {member.name}")
                archive.extract(member, out, filter="data")
        if proc.wait() != 0:
            raise RuntimeError("git archive failed")
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait()
    run("git", "init", "--quiet", str(out))
    run("git", "-C", str(out), "config", "core.autocrlf", "false")
    delta_path = evidence / "planner.patch"
    delta_path.write_bytes(delta)
    run("git", "-C", str(out), "apply", "--check", "--binary", str(delta_path))
    run("git", "-C", str(out), "apply", "--binary", str(delta_path))
    manifest = json.loads((repo / "patches/planificador-05c.files.json").read_text(encoding="utf-8"))
    verify_files(out, manifest)
    before, before_count = tree_inventory(out)
    if before != lock["planner_tree_sha256"] or before_count != lock["planner_tree_files"]:
        raise ValueError("Full planner tree differs from the verified snapshot")
    portable_path = (repo / "patches/portable.patch").resolve()
    run("git", "-C", str(out), "apply", "--check", str(portable_path))
    run("git", "-C", str(out), "apply", str(portable_path))
    portable_manifest = json.loads((repo / "patches/portable.files.json").read_text(encoding="utf-8"))
    verify_files(out, portable_manifest)
    final, count = tree_inventory(out)
    if final != lock["portable_tree_sha256"] or count != lock["portable_tree_files"]:
        raise ValueError("Full portable source tree differs from the reviewed snapshot")
    receipt = dict(lock, status="PASS", verified_delta_files=len(manifest),
                   verified_portable_files=len(portable_manifest), reconstructed_tree_sha256=final,
                   reconstructed_tree_files=count, embedded_git_commit="unknown; cache trust remains disabled")
    (evidence / "source-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
