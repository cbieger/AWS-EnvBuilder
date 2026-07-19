# Package AWS-EnvBuilder for another project

`scripts/package.sh` creates a portable source-only archive. Use it when another
application repository needs a reviewed copy of this infrastructure kit. The
command does not contact AWS and does not commit, push, or open a pull request.

## Build the archive

From the AWS-EnvBuilder top folder, first validate the exact source:

```bash
./scripts/workspace.sh validate
```

Then create a versioned archive:

```bash
./scripts/package.sh --version 1.0.0
```

The default destination is `dist/`. To place it elsewhere:

```bash
./scripts/package.sh \
  --version customer-demo-1.0.0 \
  --output /absolute/path/to/release-folder
```

Square brackets shown by `./scripts/package.sh --help` mean an option is
optional; do not type the brackets. If `--version` is omitted, the label is the
current UTC timestamp. Existing output is never overwritten.

The command creates two files:

```text
aws-envbuilder-LABEL.tar.gz
aws-envbuilder-LABEL.tar.gz.sha256
```

The first is the archive. The second records its SHA-256 fingerprint.

## What is included

The packager uses a documented file-type allowlist:

- root `README.md`, `LICENSE`, and `.gitignore`;
- Markdown guides under `docs/`;
- Bash/Python helpers under `scripts/`;
- Terraform source, templates, example variables, and provider lock checksums;
- Python tests; and
- empty log-directory marker files.

The archive never intentionally includes:

- `.git/` history or branches;
- `AGENTS.md`, `sources/`, handoff ZIPs, or unrelated workspace material;
- `.workspace/` or its saved local AWS profile name;
- AWS credentials/config files, keys, tokens, or environment files;
- Terraform downloaded providers, state, plans, `backend.hcl`, real
  `terraform.tfvars`, or generated application variables;
- runtime success/error logs; or
- a previously generated `dist/` archive.

Symbolic links are rejected so a link cannot quietly pull a file from outside
the reviewed source tree.

## Verify before distributing

Move to the folder containing the two generated files and run one matching
checksum command.

macOS:

```bash
shasum -a 256 -c aws-envbuilder-LABEL.tar.gz.sha256
```

Linux:

```bash
sha256sum -c aws-envbuilder-LABEL.tar.gz.sha256
```

Then inspect the names without extracting:

```bash
tar -tzf aws-envbuilder-LABEL.tar.gz
```

Confirm the list begins beneath one `aws-envbuilder-LABEL/` directory and does
not contain a credential, `.workspace`, `.terraform`, state, plan, real variable,
or `.log` file.

## Attach it to another application repository

Do this in a clean review branch of the destination project. The exact folder
name is a project-owner decision; `infrastructure/aws-envbuilder` is a clear
default.

```bash
mkdir -p /absolute/path/to/application/infrastructure
tar -xzf aws-envbuilder-LABEL.tar.gz \
  -C /absolute/path/to/application/infrastructure
mv /absolute/path/to/application/infrastructure/aws-envbuilder-LABEL \
  /absolute/path/to/application/infrastructure/aws-envbuilder
cd /absolute/path/to/application/infrastructure/aws-envbuilder
```

Now read `README.md`, then complete [FIRST_RUN.md](FIRST_RUN.md). Do not copy a
`.workspace` marker or AWS credentials from the source machine. Each operator
must deliberately select an approved credential/profile for the destination.

To deploy the parent application, inspect it by absolute path:

```bash
./scripts/inspect_app.sh /absolute/path/to/application
```

After the infrastructure smoke test exists, use `publish_app.sh` with the same
absolute application path. The application remains outside the infrastructure
archive; Docker ingests it only after the scanner and exact confirmation.

## Updating a previously attached copy

Do not extract a new release directly over an edited old copy. Instead:

1. extract the new archive beside the old directory;
2. compare source with `diff -ru` or the destination project's Git diff;
3. preserve destination-specific `terraform.tfvars`, `backend.hcl`, state, and
   `.workspace` data outside the replacement operation;
4. review release source and Terraform provider-lock changes;
5. replace only reviewed source files;
6. run `./scripts/workspace.sh validate`; and
7. preview Terraform with `plan` before any `apply`.

Never package or move state as if it were source code. A backend/state migration
is a separate change requiring a backup and an explicit Terraform state plan.
