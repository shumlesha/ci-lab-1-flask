import argparse
import re
from pathlib import Path

import yaml

IMAGE = re.compile(
    r"ghcr\.io/[a-z0-9][a-z0-9._/-]*-staging:"
    r"sha-[0-9a-f]{12}-run-[0-9]+-[0-9]+@sha256:[0-9a-f]{64}"
)


def update(path: Path, image: str, revision: str) -> bool:
    if IMAGE.fullmatch(image) is None:
        raise ValueError("Expected the published staging tag AND a sha256 digest")
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("Expected a full Git source revision")
    if f":sha-{revision[:12]}-run-" not in image:
        raise ValueError("Image tag and source revision disagree")
    original = path.read_text(encoding="utf-8")
    data = yaml.safe_load(original)
    if not isinstance(data, dict) or data.get("kind") != "Deployment":
        raise ValueError("Expected one Deployment document")
    if data.get("apiVersion") != "apps/v1":
        raise ValueError("Expected apps/v1")
    metadata = data["metadata"]
    if metadata.get("name") != "ci-lab-flask" or metadata.get("namespace") != "staging":
        raise ValueError("Unexpected deployment identity")
    pod = data["spec"]["template"]["spec"]
    for collection, name in (("containers", "app"), ("initContainers", "schema-init")):
        found = [item for item in pod[collection] if item.get("name") == name]
        if len(found) != 1 or "image" not in found[0]:
            raise ValueError(f"Expected exactly one {collection}/{name} image")
        found[0]["image"] = image
    annotations = data["spec"]["template"]["metadata"].setdefault("annotations", {})
    annotations["lab3/source-revision"] = revision

    text = yaml.safe_dump(data, sort_keys=False, allow_unicode=True, width=160)
    if yaml.safe_load(text) != data:
        raise ValueError("Manifest serialization changed its meaning")
    if text == original:
        return False
    path.write_text(text, encoding="utf-8", newline="\n")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    print("Manifest changed" if update(args.manifest, args.image, args.revision)
          else "Manifest already has the requested image")


if __name__ == "__main__":
    main()
