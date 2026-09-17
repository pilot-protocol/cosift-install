#!/bin/sh
# shellcheck -s sh over the shipped installer, from the host binary or a container.
#
#   tools/shellcheck.sh install.sh
#
# Set COSIFT_SHELLCHECK to point at any other shellcheck-compatible command. With
# neither a binary nor docker the check reports a loud SKIP: the POSIX-syntax
# invariant is then unproven for that run, and `sh -n` is all that ran.
set -u

TARGET=${1:-install.sh}
IMAGE=${COSIFT_SHELLCHECK_IMAGE:-koalaman/shellcheck:stable}

# Pre-existing findings in code this repository has shipped since v0.1.0. Anything
# outside this list is a new finding and fails the check.
EXCLUDE=SC2048,SC2209,SC2012,SC2129,SC2329,SC2034

if [ -n "${COSIFT_SHELLCHECK:-}" ]; then
	# shellcheck disable=SC2086
	exec $COSIFT_SHELLCHECK -s sh -e "$EXCLUDE" "$TARGET"
fi

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -s sh -e "$EXCLUDE" "$TARGET" || exit 1
	printf '%s: shellcheck clean\n' "$TARGET"
	exit 0
fi

if command -v docker >/dev/null 2>&1; then
	_dir=$(cd -- "$(dirname -- "$TARGET")" && pwd) || exit 2
	_base=$(basename -- "$TARGET")
	docker run --rm -v "$_dir:/mnt:ro" "$IMAGE" -s sh -e "$EXCLUDE" "$_base" || exit 1
	printf '%s: shellcheck clean (via %s)\n' "$TARGET" "$IMAGE"
	exit 0
fi

printf '#### SKIPPED: no shellcheck and no docker; %s was only checked by sh -n ####\n' \
	"$TARGET" >&2
exit 0
