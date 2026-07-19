# Attach an application safely

The infrastructure is deliberately application-agnostic. The only integration
contract is a Docker build plus a reachable HTTP health endpoint.

## Required contract

The application directory must contain:

1. `Dockerfile` with a pinned/versioned base image;
2. `.dockerignore` that at least excludes `.git` and `.env*`;
3. all dependency manifests and lock files needed by the Docker build;
4. a service listening on one documented TCP port;
5. a fast unauthenticated health route that returns HTTP 200-399;
6. useful stdout/stderr logs with no secrets or personal data.

The process must listen on `0.0.0.0`, not only `127.0.0.1`. The Terraform
`container_port` must equal the container's listening port.

## Example: static front-end

This multi-stage example builds Node assets and serves them with nginx. Adapt
commands and versions to the actual repository; do not copy a package manager
that the project does not use.

```dockerfile
FROM node:22-alpine AS build
WORKDIR /source
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /source/dist/ /usr/share/nginx/html/
EXPOSE 80
```

Example `.dockerignore`:

```text
.git
.env*
node_modules
coverage
dist
*.pem
*.key
```

This example uses `container_port = 80` and `health_check_path = "/"`.

## Inspect before Docker sees the directory

```bash
./scripts/inspect_app.sh /absolute/path/to/application
```

The scanner:

- skips caches such as `.git`, `node_modules`, `vendor`, and build outputs;
- parses `package.json` and inventories common language manifests;
- reports missing lock files, floating base tags, root container users, and
  missing `EXPOSE` as warnings;
- refuses missing Docker safety files, invalid JSON, unignored key-like files,
  private-key headers, or AWS credential-shaped values;
- never prints the possible secret itself.

This static scan cannot prove code is trustworthy. Review Dockerfile commands,
base-image provenance, install scripts, and application source before building.

## Build and push

Apply the default workspace once so ECR exists, then run:

```bash
./scripts/publish_app.sh /absolute/path/to/application \
  --profile YOUR_PROFILE_NAME \
  --region us-west-2
```

The helper repeats preflight, inspects files, displays the destination, and asks
for `BUILD AND PUSH APPLICATION IMAGE`. Docker pulls the current permitted base
layers and builds `linux/amd64`. ECR returns a `sha256` digest. The helper writes:

```json
{
  "container_image": "ACCOUNT.dkr.ecr.REGION.amazonaws.com/PROJECT@sha256:DIGEST"
}
```

to ignored `terraform/application.auto.tfvars.json`. No EC2 change occurs yet.

## Preview and roll out

```bash
./scripts/workspace.sh plan --profile YOUR_PROFILE_NAME --region us-west-2
./scripts/workspace.sh apply --profile YOUR_PROFILE_NAME --region us-west-2
```

The plan should show a new launch-template version and Auto Scaling instance
refresh. During the one-instance development refresh, brief unavailability is
possible because the cost-conscious default does not temporarily require two
healthy instances. Raise minimum/desired capacity to two only after approving
the extra cost.

## Dependency policy

The host does not run `npm install`, `pip install`, or equivalent against the
application. The Dockerfile owns exact dependency installation in an isolated
build. Commit lock files and use deterministic commands such as `npm ci` or
hash-checked Python requirements. Container scanning in ECR is enabled on push,
but findings do not automatically block this simple development workflow; review
them in ECR before promotion.

## Configuration and secrets

This generic module intentionally has no arbitrary environment-variable map,
because Terraform state would then retain values. Public configuration can be
baked into a front-end build only after recognizing that browsers can read it.
Private runtime secrets require an application-specific design using Secrets
Manager/Parameter Store, a narrow role policy, and retrieval at runtime. Never
put a secret in a front-end bundle.
