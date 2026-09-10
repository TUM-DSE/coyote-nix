"""Verify immutable subdivision inputs; this does not qualify a DFX boundary."""
import hashlib
import sys
from pathlib import Path


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(checkpoint, checkpoint_sha256, static, static_sha256, current_static):
    for label, path, expected in (
        ("subdivision checkpoint", checkpoint, checkpoint_sha256),
        ("reference static checkpoint", static, static_sha256),
        ("current static checkpoint", current_static, static_sha256),
    ):
        if digest(path) != expected:
            raise ValueError(f"{label}: SHA256 mismatch")


if __name__ == "__main__":
    verify(*sys.argv[1:])
