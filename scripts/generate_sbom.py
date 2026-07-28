#!/usr/bin/env python3
"""Generate a small SPDX 2.3 JSON SBOM from the repository lock inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path


PROJECT_VERSION = "2.0.0"
LICENSES = {
    "altgraph": "MIT",
    "certifi": "MPL-2.0",
    "charset-normalizer": "MIT",
    "idna": "BSD-3-Clause",
    "jaraco-classes": "MIT",
    "jaraco-context": "MIT",
    "jaraco-functools": "MIT",
    "requests": "Apache-2.0",
    "pyyaml": "MIT",
    "keyring": "MIT",
    "more-itertools": "MIT",
    "packaging": "Apache-2.0 OR BSD-2-Clause",
    "pefile": "MIT",
    "pyinstaller": "GPL-2.0-or-later WITH Bootloader-exception",
    "pywin32-ctypes": "BSD-3-Clause",
    "pillow": "HPND",
    "setuptools": "MIT",
    "swift-testing": "Apache-2.0",
    "swift-syntax": "Apache-2.0",
    "urllib3": "MIT",
}


def normalized_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value.strip()).lower()


def parse_requirements(path: Path) -> list[tuple[str, str]]:
    packages: list[tuple[str, str]] = []
    if not path.is_file():
        return packages
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line or line.startswith("-r"):
            continue
        requirement = line.split(maxsplit=1)[0]
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+!-]+)", requirement)
        if not match:
            raise ValueError(f"dependency is not exactly pinned in {path.name}: {raw_line}")
        packages.append((match.group(1), match.group(2)))
    return packages


def parse_swift_resolved(path: Path) -> list[tuple[str, str]]:
    if not path.is_file():
        return []
    payload = json.loads(path.read_text(encoding="utf-8"))
    packages: list[tuple[str, str]] = []
    for pin in payload.get("pins", []):
        identity = str(pin.get("identity") or "").strip()
        state = pin.get("state") or {}
        version = str(state.get("version") or state.get("revision") or "").strip()
        if identity and version:
            packages.append((identity, version))
    return packages


def git_revision(root: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return "NOASSERTION"
    return result.stdout.strip() if result.returncode == 0 else "NOASSERTION"


def created_timestamp() -> str:
    source_epoch = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
    if source_epoch.isdigit():
        value = datetime.fromtimestamp(int(source_epoch), tz=timezone.utc)
    else:
        value = datetime.now(timezone.utc)
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def package_record(name: str, version: str, *, ecosystem: str) -> dict[str, object]:
    normalized = normalized_name(name)
    spdx_id = "SPDXRef-Package-" + re.sub(r"[^A-Za-z0-9.-]", "-", normalized)
    namespace = "pypi" if ecosystem == "pypi" else "github"
    return {
        "SPDXID": spdx_id,
        "name": name,
        "versionInfo": version,
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "licenseConcluded": LICENSES.get(normalized, "NOASSERTION"),
        "licenseDeclared": LICENSES.get(normalized, "NOASSERTION"),
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:{namespace}/{normalized}@{version}",
            }
        ],
    }


def generate(root: Path, platform: str) -> dict[str, object]:
    dependencies: list[tuple[str, str, str]] = []
    if platform == "windows":
        dependencies.extend(
            (name, version, "pypi")
            for name, version in parse_requirements(root / "requirements-windows.lock")
        )
    else:
        dependencies.extend(
            (name, version, "swift")
            for name, version in parse_swift_resolved(root / "macos" / "Package.resolved")
        )
    unique = sorted(set(dependencies), key=lambda item: (normalized_name(item[0]), item[1]))
    revision = git_revision(root)
    namespace_seed = f"SZU-Campus-Network:{PROJECT_VERSION}:{platform}:{revision}"
    namespace_hash = hashlib.sha256(namespace_seed.encode("utf-8")).hexdigest()
    document_id = "SPDXRef-DOCUMENT"
    root_id = "SPDXRef-Package-SZU-Campus-Network"
    packages = [
        {
            "SPDXID": root_id,
            "name": "SZU Campus Network",
            "versionInfo": PROJECT_VERSION,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "supplier": "Person: Fonsi479",
        }
    ]
    packages.extend(package_record(name, version, ecosystem=kind) for name, version, kind in unique)
    relationships = [
        {"spdxElementId": document_id, "relationshipType": "DESCRIBES", "relatedSpdxElement": root_id}
    ]
    relationships.extend(
        {"spdxElementId": root_id, "relationshipType": "DEPENDS_ON", "relatedSpdxElement": package["SPDXID"]}
        for package in packages[1:]
    )
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": document_id,
        "name": f"SZU-Campus-Network-{platform}-{PROJECT_VERSION}",
        "documentNamespace": f"https://local.invalid/spdx/{namespace_hash}",
        "creationInfo": {"created": created_timestamp(), "creators": ["Tool: scripts/generate_sbom.py"]},
        "packages": packages,
        "relationships": relationships,
        "annotations": [
            {
                "annotationType": "OTHER",
                "annotator": "Tool: scripts/generate_sbom.py",
                "annotationDate": created_timestamp(),
                "comment": f"platform={platform}; gitRevision={revision}",
            }
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("macos", "windows"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    try:
        payload = generate(root, args.platform)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    output = args.output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
