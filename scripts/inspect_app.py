#!/usr/bin/env python3
"""Inspect an application directory before Docker is allowed to ingest it.

The scanner uses only Python's standard library. It validates common manifests,
checks the container contract, inventories dependency ecosystems, and reports
possible secret files or credential-shaped text without ever printing a secret.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable


IGNORED_DIRECTORIES = {
    ".git",
    ".terraform",
    ".venv",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "target",
    "vendor",
}

MANIFEST_TO_TOOL = {
    "package.json": "Node.js package manager (inside the Docker build)",
    "requirements.txt": "Python pip (inside the Docker build)",
    "pyproject.toml": "Python build tool declared by the project",
    "Pipfile": "Python Pipenv (inside the Docker build)",
    "poetry.lock": "Python Poetry (inside the Docker build)",
    "go.mod": "Go modules (inside the Docker build)",
    "Cargo.toml": "Rust Cargo (inside the Docker build)",
    "Gemfile": "Ruby Bundler (inside the Docker build)",
    "pom.xml": "Maven (inside the Docker build)",
    "build.gradle": "Gradle (inside the Docker build)",
}

SENSITIVE_FILE_NAMES = {
    ".env",
    ".env.local",
    ".env.production",
    "credentials",
    "id_dsa",
    "id_ed25519",
    "id_rsa",
    "terraform.tfstate",
}

# The scanner identifies only strong credential shapes. It prints the file path
# and pattern name, never the matching value.
SECRET_PATTERNS = {
    "AWS access-key-shaped value": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "private key header": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "assigned AWS secret access key": re.compile(
        r"(?i)aws_secret_access_key\s*[:=]\s*[^\s#]{20,}"
    ),
}

TEXT_SUFFIXES = {
    "",
    ".cfg",
    ".conf",
    ".css",
    ".env",
    ".go",
    ".gradle",
    ".html",
    ".ini",
    ".java",
    ".js",
    ".json",
    ".jsx",
    ".md",
    ".py",
    ".rb",
    ".rs",
    ".sh",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}


@dataclass
class InspectionReport:
    """Serializable result used by both humans and automated publishing."""

    application_path: str
    files_examined: int = 0
    manifests: list[str] = field(default_factory=list)
    dependency_tools: list[str] = field(default_factory=list)
    observations: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """An inspection is deployable only when no blocking error exists."""

        return not self.errors


def iter_candidate_files(root: Path) -> Iterable[Path]:
    """Yield ordinary, reasonably small text candidates without build caches."""

    for current_root, directory_names, file_names in os.walk(root):
        directory_names[:] = sorted(
            name for name in directory_names if name not in IGNORED_DIRECTORIES
        )
        current = Path(current_root)
        for file_name in sorted(file_names):
            path = current / file_name
            try:
                if path.is_symlink() or not path.is_file() or path.stat().st_size > 2_000_000:
                    continue
            except OSError:
                continue
            yield path


def dockerignore_patterns(path: Path) -> list[str]:
    """Return meaningful Docker ignore lines for simple safety checks."""

    if not path.is_file():
        return []
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def is_obviously_ignored(relative_path: str, patterns: list[str]) -> bool:
    """Recognize conservative exact/prefix ignore rules; no false assurance."""

    normalized = relative_path.lstrip("./")
    for pattern in patterns:
        candidate = pattern.lstrip("./")
        if candidate in {"*", "**"}:
            return True
        if candidate.endswith("/") and normalized.startswith(candidate):
            return True
        if candidate == normalized:
            return True
        if candidate == ".env*" and Path(normalized).name.startswith(".env"):
            return True
        if candidate == "*.pem" and normalized.endswith(".pem"):
            return True
    return False


def inspect_application(root: Path) -> InspectionReport:
    """Perform static, non-mutating checks against one application directory."""

    resolved = root.expanduser().resolve()
    report = InspectionReport(application_path=str(resolved))

    if not resolved.exists():
        report.errors.append("Application path does not exist.")
        return report
    if not resolved.is_dir():
        report.errors.append("Application path is not a directory.")
        return report

    dockerfile = resolved / "Dockerfile"
    dockerignore = resolved / ".dockerignore"
    if not dockerfile.is_file():
        report.errors.append(
            "Dockerfile is missing. This workspace deploys applications as containers."
        )
    if not dockerignore.is_file():
        report.errors.append(
            ".dockerignore is missing. Add it before Docker is allowed to ingest the directory."
        )

    patterns = dockerignore_patterns(dockerignore)
    for important_pattern in (".git", ".env*"):
        if patterns and important_pattern not in patterns:
            report.warnings.append(
                f".dockerignore does not explicitly contain '{important_pattern}'."
            )

    if dockerfile.is_file():
        docker_text = dockerfile.read_text(encoding="utf-8", errors="replace")
        if not re.search(r"(?im)^\s*FROM\s+\S+", docker_text):
            report.errors.append("Dockerfile has no FROM instruction.")
        if re.search(r"(?im)^\s*FROM\s+\S+:latest(?:\s|$)", docker_text):
            report.warnings.append(
                "Dockerfile uses a floating ':latest' base tag; pin a version or digest for repeatability."
            )
        exposed = re.findall(r"(?im)^\s*EXPOSE\s+([^\r\n#]+)", docker_text)
        if exposed:
            report.observations.append("Dockerfile EXPOSE value(s): " + ", ".join(exposed))
        else:
            report.warnings.append(
                "Dockerfile has no EXPOSE instruction; document the listening port in terraform.tfvars."
            )
        if not re.search(r"(?im)^\s*USER\s+(?!root\b)\S+", docker_text):
            report.warnings.append(
                "Dockerfile does not visibly select a non-root runtime USER."
            )

    files = list(iter_candidate_files(resolved))
    report.files_examined = len(files)
    for path in files:
        relative = path.relative_to(resolved).as_posix()
        if path.name in MANIFEST_TO_TOOL:
            report.manifests.append(relative)
            tool = MANIFEST_TO_TOOL[path.name]
            if tool not in report.dependency_tools:
                report.dependency_tools.append(tool)

        if path.name == "package.json":
            try:
                package_data = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(package_data, dict):
                    raise ValueError("top level must be an object")
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
                report.errors.append(f"Invalid {relative}: {error}")

        sensitive_name = (
            path.name in SENSITIVE_FILE_NAMES
            or path.suffix.lower() in {".key", ".p12", ".pem"}
        )
        if sensitive_name and not is_obviously_ignored(relative, patterns):
            report.errors.append(
                f"Possible secret file is inside the Docker build context and not clearly ignored: {relative}"
            )

        if path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            content = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for label, expression in SECRET_PATTERNS.items():
            if expression.search(content) and not is_obviously_ignored(relative, patterns):
                report.errors.append(
                    f"Possible {label} found in non-ignored file: {relative}"
                )

    report.manifests = sorted(set(report.manifests))
    report.dependency_tools = sorted(set(report.dependency_tools))

    if (resolved / "package.json").is_file() and not any(
        (resolved / name).is_file()
        for name in ("package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb")
    ):
        report.warnings.append(
            "package.json has no recognized lock file; dependency versions may drift."
        )

    if not report.manifests:
        report.observations.append(
            "No common dependency manifest was detected; Dockerfile remains the dependency source of truth."
        )

    if shutil.which("docker") is None:
        report.warnings.append(
            "Docker is not installed on this workstation; static inspection works, but publish_app.sh cannot build."
        )
    else:
        report.observations.append("Docker executable is available on this workstation.")

    return report


def print_human_report(report: InspectionReport) -> None:
    """Display concise categories without leaking matched credential content."""

    print(f"Application: {report.application_path}")
    print(f"Files examined: {report.files_examined}")
    print("Dependency manifests: " + (", ".join(report.manifests) or "none detected"))
    print("Dependency tooling:")
    for value in report.dependency_tools or ["Dockerfile only"]:
        print(f"  - {value}")
    for heading, values in (
        ("Observations", report.observations),
        ("Warnings", report.warnings),
        ("Errors", report.errors),
    ):
        print(f"{heading}:")
        if values:
            for value in values:
                print(f"  - {value}")
        else:
            print("  - none")
    print("Result: PASS" if report.ok else "Result: FAIL")


def main() -> int:
    """Parse arguments and return a shell-friendly pass/fail status."""

    parser = argparse.ArgumentParser(
        description="Inspect app files and dependencies before a Docker build."
    )
    parser.add_argument("application_path", type=Path)
    parser.add_argument(
        "--json", action="store_true", help="emit the complete report as JSON"
    )
    args = parser.parse_args()

    report = inspect_application(args.application_path)
    if args.json:
        print(json.dumps({**asdict(report), "ok": report.ok}, indent=2, sort_keys=True))
    else:
        print_human_report(report)
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
