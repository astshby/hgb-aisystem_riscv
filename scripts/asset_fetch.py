"""SHA256-locked downloads shared by model preparation tools (stdlib only)."""
import hashlib
from pathlib import Path
import tempfile
import urllib.request


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(url, path, expected):
    path = Path(path)
    if path.exists():
        if sha256(path) != expected:
            raise ValueError(f"SHA256 mismatch; inspect existing file before replacing it: {path}")
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            request = urllib.request.Request(url, headers={"User-Agent": "hgb-assets/1"})
            with urllib.request.urlopen(request, timeout=120) as response:
                while block := response.read(1024 * 1024):
                    output.write(block)
        if sha256(temporary) != expected:
            raise ValueError(f"download SHA256 mismatch: {url}")
        temporary.replace(path)
        return path
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
