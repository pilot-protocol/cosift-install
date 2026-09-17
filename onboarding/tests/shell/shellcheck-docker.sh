#!/bin/sh
# Lint helper for 20-structural.sh: run shellcheck from a container when the
# host has no shellcheck binary. Not part of the shipped install path.
set -u

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
IMAGE=${COSIFT_SHELLCHECK_IMAGE:-koalaman/shellcheck:stable}

if ! command -v docker >/dev/null 2>&1; then
	printf 'shellcheck-docker.sh: docker is not on PATH\n' >&2
	exit 127
fi

# The onboarding root is mounted at its own absolute path so the caller can pass
# absolute file names unchanged.
exec docker run --rm -v "$ROOT:$ROOT:ro" -w "$ROOT" "$IMAGE" "$@"
