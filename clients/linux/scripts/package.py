from __future__ import annotations

import hashlib
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"


def payload(destination: Path) -> None:
    shutil.copytree(
        ROOT / "src/ssbnk_client",
        destination / "ssbnk_client",
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
    )
    launcher = destination / "ssbnk-client"
    launcher.write_text(
        "#!/usr/bin/python3\nimport sys\n"
        "sys.path.insert(0, '/usr/lib/ssbnk-client')\n"
        "from ssbnk_client.desktop import main\nmain()\n"
    )
    launcher.chmod(0o755)
    desktop = destination / "ssbnk-client.desktop"
    desktop.write_text(
        "[Desktop Entry]\nType=Application\nName=SSBNK Client\n"
        "Exec=ssbnk-client\nIcon=camera-photo-symbolic\nTerminal=false\n"
        "Categories=Utility;Graphics;\n"
    )


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in ("deb", "arch", "gnome"):
        raise SystemExit("Usage: package.py deb|arch|gnome")
    DIST.mkdir(exist_ok=True)
    kind = sys.argv[1]
    if kind == "gnome":
        if not shutil.which("gnome-extensions"):
            raise SystemExit("BLOCKED: gnome-extensions pack is required; no substitute bundle")
        subprocess.run(
            [
                "gnome-extensions",
                "pack",
                "--force",
                "--out-dir",
                str(DIST),
                str(ROOT / "gnome/ssbnk@delo.sh"),
            ],
            check=True,
        )
        return
    build = ROOT / "build" / kind
    if build.exists():
        shutil.rmtree(build)
    build.mkdir(parents=True)
    if kind == "deb":
        (build / "DEBIAN").mkdir()
        shutil.copy(ROOT / "packaging/control", build / "DEBIAN/control")
        library = build / "usr/lib/ssbnk-client"
        library.mkdir(parents=True)
        payload(library)
        binary = build / "usr/bin"
        binary.mkdir(parents=True)
        shutil.move(library / "ssbnk-client", binary / "ssbnk-client")
        desktop = build / "usr/share/applications"
        desktop.mkdir(parents=True)
        shutil.move(library / "ssbnk-client.desktop", desktop / "ssbnk-client.desktop")
        subprocess.run(
            [
                "dpkg-deb",
                "--root-owner-group",
                "--build",
                str(build),
                str(DIST / "ssbnk-client_0.1.0_all.deb"),
            ],
            check=True,
        )
        return
    if not shutil.which("makepkg"):
        raise SystemExit("BLOCKED: qualify Arch packaging with makepkg on a disposable Arch system")
    client = build / "client"
    client.mkdir()
    payload(client)
    archive = build / "client.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        output.add(client, arcname="client")
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = (ROOT / "packaging/PKGBUILD").read_text().replace("'SKIP'", f"'{checksum}'")
    (build / "PKGBUILD").write_text(manifest)
    subprocess.run(["makepkg", "--nodeps", "--cleanbuild", "--force"], cwd=build, check=True)
    for package in build.glob("*.pkg.tar.*"):
        shutil.copy(package, DIST / package.name)


if __name__ == "__main__":
    main()
