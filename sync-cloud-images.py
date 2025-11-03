#!/usr/bin/env python3
"""Synchronise cloud images defined in conf/cloud-init.conf with checksum validation."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import urlopen


class ConfigError(RuntimeError):
    """Raised when the configuration file cannot be parsed."""


class SyncError(RuntimeError):
    """Raised when a release fails to synchronise."""


def debug(msg: str) -> None:
    print(msg, file=sys.stderr)


def strip_comments(line: str) -> str:
    in_single = False
    in_double = False
    result_chars: List[str] = []

    for char in line:
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        elif char == "#" and not in_single and not in_double:
            break
        result_chars.append(char)
    return "".join(result_chars)


def parse_scalar(value: str):
    value = value.strip()
    if not value:
        return ""
    if value.startswith(("'", '"')) and value.endswith(("'", '"')):
        return value[1:-1]

    lowered = value.lower()
    if lowered in {"true", "false"}:
        return lowered == "true"

    return value


def tokenize_yaml(text: str) -> List[Tuple[int, str, int]]:
    tokens: List[Tuple[int, str, int]] = []
    for lineno, raw_line in enumerate(text.splitlines(), 1):
        line = strip_comments(raw_line).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent and line[:indent].count(" ") != indent:
            raise ConfigError(f"Invalid indentation on line {lineno}")
        tokens.append((indent, line.strip(), lineno))
    return tokens


def parse_block(tokens: List[Tuple[int, str, int]], index: int, indent: int):
    result: Dict[str, object] = {}
    while index < len(tokens):
        current_indent, content, lineno = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            raise ConfigError(f"Unexpected indentation on line {lineno}")
        if content.startswith("- "):
            raise ConfigError(f"Unexpected list item on line {lineno}")

        if ":" not in content:
            raise ConfigError(f"Expected ':' on line {lineno}")
        key, _, remainder = content.partition(":")
        key = key.strip()
        remainder = remainder.strip()

        if not remainder:
            if index + 1 >= len(tokens) or tokens[index + 1][0] <= indent:
                result[key] = {}
                index += 1
                continue

            next_indent = tokens[index + 1][0]
            if tokens[index + 1][1].startswith("- "):
                value, index = parse_list(tokens, index + 1, next_indent)
            else:
                value, index = parse_block(tokens, index + 1, next_indent)
            result[key] = value
        else:
            result[key] = parse_scalar(remainder)
            index += 1
    return result, index


def parse_list(tokens: List[Tuple[int, str, int]], index: int, indent: int):
    items: List[object] = []
    while index < len(tokens):
        current_indent, content, lineno = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            raise ConfigError(f"Unexpected indentation on line {lineno}")
        if not content.startswith("- "):
            break
        item_content = content[2:].strip()
        index += 1
        if item_content:
            items.append(parse_scalar(item_content))
        else:
            if index >= len(tokens) or tokens[index][0] <= indent:
                items.append({})
                continue
            next_indent = tokens[index][0]
            if tokens[index][1].startswith("- "):
                value, index = parse_list(tokens, index, next_indent)
            else:
                value, index = parse_block(tokens, index, next_indent)
            items.append(value)
    return items, index


def load_simple_yaml(path: Path) -> Dict[str, object]:
    text = path.read_text(encoding="utf-8")
    tokens = tokenize_yaml(text)
    if not tokens:
        return {}
    result, index = parse_block(tokens, 0, tokens[0][0])
    if index != len(tokens):
        raise ConfigError("Unexpected trailing content in configuration")
    return result


def detect_hash_algorithm(checksum_file: str) -> str:
    lowered = checksum_file.lower()
    for algo in ("sha512", "sha384", "sha256", "sha1", "md5"):
        if algo in lowered:
            return algo
    raise SyncError(f"Cannot determine hash algorithm from checksum file '{checksum_file}'")


def parse_checksums(checksum_text: str) -> Dict[str, str]:
    mapping: Dict[str, str] = {}
    for raw_line in checksum_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        digest, filename = parts[0], parts[-1]
        if filename.startswith(("*", ".")):
            filename = filename.lstrip("*")
        mapping[filename] = digest
    return mapping


def fetch_text(url: str) -> str:
    try:
        with urlopen(url) as response:
            charset = response.headers.get_content_charset("utf-8")
            return response.read().decode(charset)
    except (HTTPError, URLError) as exc:
        raise SyncError(f"Failed to download {url}: {exc}") from exc


def download_file(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=destination.name + ".", dir=str(destination.parent))
    tmp_file = Path(tmp_path)
    try:
        with urlopen(url) as response, open(tmp_file, "wb") as output:
            shutil.copyfileobj(response, output)
        tmp_file.replace(destination)
    except (HTTPError, URLError, OSError) as exc:
        tmp_file.unlink(missing_ok=True)
        raise SyncError(f"Failed to download {url}: {exc}") from exc


def calculate_digest(path: Path, algorithm: str) -> str:
    try:
        digest = hashlib.new(algorithm)
    except ValueError as exc:
        raise SyncError(f"Unsupported hash algorithm '{algorithm}'") from exc
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass
class ReleaseContext:
    distro: str
    release: str
    base_url: str
    release_url: str
    checksum_file: str
    artifacts: Iterable[str]
    images_root: Path

    @property
    def release_dir(self) -> Path:
        return self.images_root / self.distro / self.release

    @property
    def checksum_url(self) -> str:
        parts = [
            self.base_url.rstrip("/"),
            self.release.strip("/"),
            self.release_url.strip("/"),
            self.checksum_file,
        ]
        return "/".join(part for part in parts if part)

    def artifact_url(self, artifact: str) -> str:
        return "/".join(
            [
                self.base_url.rstrip("/"),
                self.release.strip("/"),
                self.release_url.strip("/"),
                artifact,
            ]
        )


def sync_release(ctx: ReleaseContext, attempts: int) -> bool:
    checksum_text = fetch_text(ctx.checksum_url)
    checksums = parse_checksums(checksum_text)
    algorithm = detect_hash_algorithm(ctx.checksum_file)

    missing_artifacts = [artifact for artifact in ctx.artifacts if artifact not in checksums]
    if missing_artifacts:
        raise SyncError(
            f"{ctx.distro}/{ctx.release}: checksum file missing entries for {', '.join(missing_artifacts)}"
        )

    checksum_path = ctx.release_dir / "remote-checksum"
    if checksum_path.exists() and checksum_path.read_text(encoding="utf-8") == checksum_text:
        debug(f"[skip] {ctx.distro}/{ctx.release}: checksum unchanged")
        return False

    for artifact in ctx.artifacts:
        expected_digest = checksums[artifact].lower()
        destination = ctx.release_dir / artifact

        for attempt in range(1, attempts + 1):
            try:
                download_file(ctx.artifact_url(artifact), destination)
                actual_digest = calculate_digest(destination, algorithm)
                if actual_digest.lower() != expected_digest:
                    raise SyncError(
                        f"Checksum mismatch for {artifact} (expected {expected_digest}, got {actual_digest})"
                    )
                debug(
                    f"[ok] {ctx.distro}/{ctx.release}: {artifact} verified with {algorithm.upper()} {actual_digest}"
                )
                break
            except SyncError as exc:
                if attempt >= attempts:
                    raise SyncError(
                        f"{ctx.distro}/{ctx.release}: failed to download {artifact} after {attempts} attempts ({exc})"
                    ) from exc
                debug(
                    f"[retry] {ctx.distro}/{ctx.release}: {artifact} attempt {attempt}/{attempts} failed ({exc})"
                )
                destination.unlink(missing_ok=True)

    tmp_checksum = checksum_path.with_suffix(".tmp")
    tmp_checksum.parent.mkdir(parents=True, exist_ok=True)
    tmp_checksum.write_text(checksum_text, encoding="utf-8")
    tmp_checksum.replace(checksum_path)
    debug(f"[update] {ctx.distro}/{ctx.release}: checksum updated")
    return True


def load_config(path: Path) -> Dict[str, object]:
    if not path.is_file():
        raise ConfigError(f"Configuration file not found: {path}")
    config = load_simple_yaml(path)
    if not isinstance(config, dict) or "distros" not in config:
        raise ConfigError("Top-level 'distros' mapping missing in configuration")
    distros = config["distros"]
    if not isinstance(distros, dict):
        raise ConfigError("'distros' must map distro names to configuration blocks")
    return distros


def iter_release_contexts(
    distros: Dict[str, object],
    images_root: Path,
    distro_filter: Optional[Iterable[str]],
    release_filter: Optional[Iterable[str]],
) -> List[ReleaseContext]:
    distro_names = distro_filter if distro_filter else distros.keys()
    release_filter_set = set(release_filter) if release_filter else None

    contexts: List[ReleaseContext] = []
    for distro_name in distro_names:
        if distro_name not in distros:
            raise ConfigError(f"Distro '{distro_name}' not defined in configuration")
        distro_cfg = distros[distro_name]
        if not isinstance(distro_cfg, dict):
            raise ConfigError(f"Distro '{distro_name}' must map to a dictionary")

        base_url = distro_cfg.get("baseURL")
        releases = distro_cfg.get("releases")
        if not base_url or not isinstance(base_url, str):
            raise ConfigError(f"Distro '{distro_name}' is missing 'baseURL'")
        if not isinstance(releases, dict) or not releases:
            raise ConfigError(f"Distro '{distro_name}' must define at least one release")

        for release_name, release_cfg in releases.items():
            if release_filter_set and release_name not in release_filter_set:
                continue
            if not isinstance(release_cfg, dict):
                raise ConfigError(f"Release '{release_name}' under '{distro_name}' must map to a dictionary")
            release_url = release_cfg.get("releaseURL", "")
            checksum_file = release_cfg.get("remoteChecksums")
            artifacts = release_cfg.get("artifacts", [])
            if not checksum_file or not isinstance(checksum_file, str):
                raise ConfigError(
                    f"Release '{release_name}' under '{distro_name}' is missing 'remoteChecksums'"
                )
            if not isinstance(artifacts, list) or not artifacts:
                raise ConfigError(
                    f"Release '{release_name}' under '{distro_name}' must define a non-empty 'artifacts' list"
                )
            contexts.append(
                ReleaseContext(
                    distro=distro_name,
                    release=release_name,
                    base_url=base_url,
                    release_url=release_url if isinstance(release_url, str) else "",
                    checksum_file=checksum_file,
                    artifacts=[str(artifact) for artifact in artifacts],
                    images_root=images_root,
                )
            )
    return contexts


def main(argv: Optional[List[str]] = None) -> int:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Synchronise remote cloud images described in cloud-init.conf.")
    parser.add_argument(
        "--config",
        default=script_dir / "conf" / "cloud-init.conf",
        type=Path,
        help="Path to the YAML configuration file (default: %(default)s)",
    )
    parser.add_argument(
        "--images-dir",
        default=script_dir / "images",
        type=Path,
        help="Destination directory for images (default: %(default)s)",
    )
    parser.add_argument(
        "--distro",
        action="append",
        help="Only process the given distro (can be specified multiple times)",
    )
    parser.add_argument(
        "--release",
        action="append",
        help="Only process the given release (can be specified multiple times)",
    )
    parser.add_argument(
        "--retries",
        type=int,
        default=3,
        help="Download retries per artifact (default: %(default)s)",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress progress output (only errors will be printed)",
    )

    args = parser.parse_args(argv)

    if args.retries < 1:
        parser.error("--retries must be a positive integer")

    if args.quiet:
        def quiet_debug(_: str) -> None:
            pass

        globals()["debug"] = quiet_debug  # type: ignore

    try:
        distros = load_config(args.config)
        contexts = iter_release_contexts(distros, args.images_dir, args.distro, args.release)

        if not contexts:
            debug("No matching distros/releases found; nothing to do.")
            return 0

        updates = 0
        for ctx in contexts:
            updated = sync_release(ctx, args.retries)
            if updated:
                updates += 1

        debug(f"Completed image synchronisation ({updates} release(s) updated).")
        return 0
    except (ConfigError, SyncError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
