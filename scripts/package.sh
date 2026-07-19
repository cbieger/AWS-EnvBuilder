#!/usr/bin/env bash
# Build a portable source archive for attaching this infrastructure kit to
# another application repository. The allowlist below deliberately excludes
# credentials, local profiles, logs, state, plans, caches, and real variables.

set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OUTPUT_DIRECTORY="${WORKSPACE_ROOT}/dist"
PACKAGE_VERSION="$(date -u +'%Y%m%dT%H%M%SZ')"

usage() {
  cat <<'USAGE'
Usage: ./scripts/package.sh [--output DIRECTORY] [--version LABEL]

Options:
  --output DIRECTORY   Archive destination (default: ./dist).
  --version LABEL      Safe label placed in the archive/file name; defaults to
                       the current UTC timestamp.
  --help               Show this explanation.

The command creates aws-envbuilder-LABEL.tar.gz and a matching .sha256 file.
It packages source and documentation only. It never includes AWS credentials,
the local service-profile marker, Terraform state/plans, real variables,
downloaded providers, runtime logs, Git history, or unrelated workspace files.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value."
      OUTPUT_DIRECTORY="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value."
      PACKAGE_VERSION="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown package option: $1"
      ;;
  esac
done

[[ "${PACKAGE_VERSION}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
  || die "--version must be 1-64 safe letters, digits, dots, underscores, or hyphens."

begin_logged_run "package"
require_command python3 "Install Python 3.9 or newer using docs/WORKSTATION_SETUP.md."

mkdir -p "${OUTPUT_DIRECTORY}"
OUTPUT_DIRECTORY="$(cd "${OUTPUT_DIRECTORY}" && pwd)"
archive_path="${OUTPUT_DIRECTORY}/aws-envbuilder-${PACKAGE_VERSION}.tar.gz"
checksum_path="${archive_path}.sha256"

[[ ! -e "${archive_path}" && ! -e "${checksum_path}" ]] \
  || die "Package output already exists. Choose a different --version or --output; nothing was overwritten."

log_info "Creating a source-only package from ${WORKSPACE_ROOT}."
log_info "Package destination: ${archive_path}"

python3 - "${WORKSPACE_ROOT}" "${archive_path}" "${PACKAGE_VERSION}" <<'PY'
import fnmatch
import gzip
import hashlib
import os
from pathlib import Path
import stat
import sys
import tarfile

source_root = Path(sys.argv[1]).resolve()
archive_path = Path(sys.argv[2]).resolve()
version = sys.argv[3]
package_root = f"aws-envbuilder-{version}"

# Only these finished, reusable artifact types are eligible. Adding a new file
# type requires a deliberate review here, so a future secret-like file is not
# silently swept into a release by a broad directory archive.
root_files = {".gitignore", "LICENSE", "README.md"}
directory_patterns = {
    "docs": ("*.md",),
    "scripts": ("*.sh", "*.py"),
    "terraform": ("*.tf", "*.tftpl", "*.example", ".terraform.lock.hcl"),
    "tests": ("test_*.py",),
}


def eligible(relative_path):
    if len(relative_path.parts) == 1:
        return relative_path.name in root_files
    top_level = relative_path.parts[0]
    patterns = directory_patterns.get(top_level)
    return bool(patterns and any(fnmatch.fnmatch(relative_path.name, pattern) for pattern in patterns))


candidates = []
for root_file in sorted(root_files):
    path = source_root / root_file
    if path.is_symlink():
        raise SystemExit(f"Refusing package symlink: {path.relative_to(source_root)}")
    if not path.is_file():
        raise SystemExit(f"Required package file is missing: {path}")
    candidates.append(path)

for directory in sorted(directory_patterns):
    directory_path = source_root / directory
    if not directory_path.is_dir():
        raise SystemExit(f"Required package directory is missing: {directory_path}")
    for path in sorted(directory_path.rglob("*")):
        relative_path = path.relative_to(source_root)
        if path.is_symlink():
            raise SystemExit(f"Refusing package symlink: {relative_path}")
        if path.is_file() and eligible(relative_path):
            candidates.append(path)

# Empty log directories are represented by harmless tracked marker files. No
# transcript is ever eligible for packaging.
for retention_class in ("active", "errors", "success", "inventory"):
    marker = source_root / "logs" / retention_class / ".gitkeep"
    if marker.is_symlink():
        raise SystemExit(f"Refusing package symlink: {marker.relative_to(source_root)}")
    if marker.is_file():
        candidates.append(marker)

# Write via a temporary file in the destination so interruption never leaves a
# partially named release. Normalize owner names and gzip timestamp to avoid
# embedding local usernames or the packaging time in archive metadata.
temporary_archive = archive_path.with_name(f".{archive_path.name}.temporary-{os.getpid()}")
try:
    with open(temporary_archive, "wb") as raw_output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_output, mtime=0) as gzip_output:
            with tarfile.open(fileobj=gzip_output, mode="w") as archive:
                for path in sorted(set(candidates), key=lambda item: str(item.relative_to(source_root))):
                    relative_path = path.relative_to(source_root)
                    archive_name = f"{package_root}/{relative_path.as_posix()}"
                    information = archive.gettarinfo(str(path), arcname=archive_name)
                    information.uid = 0
                    information.gid = 0
                    information.uname = "root"
                    information.gname = "root"
                    information.mtime = 0
                    # Preserve executable scripts, but remove group/other write
                    # bits from every distributed source file.
                    source_mode = stat.S_IMODE(path.stat().st_mode)
                    information.mode = source_mode & ~0o022
                    with open(path, "rb") as source:
                        archive.addfile(information, source)
    os.replace(temporary_archive, archive_path)
except BaseException:
    try:
        temporary_archive.unlink()
    except FileNotFoundError:
        pass
    raise

digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
checksum_path = Path(f"{archive_path}.sha256")
checksum_path.write_text(f"{digest}  {archive_path.name}\n", encoding="utf-8")
os.chmod(checksum_path, 0o644)
print(f"Included {len(set(candidates))} reviewed source files.")
print(f"SHA-256: {digest}")
PY

log_info "Package created successfully: ${archive_path}"
log_info "Checksum created successfully: ${checksum_path}"
log_info "Before distribution, extract it into a temporary directory and follow docs/PACKAGING.md."
