#!/bin/sh
# Tier B runner. Builds the throwaway-HOME image and runs the install-mechanics
# assertions inside it. Exit 0 = pass, 1 = failure, 2 = nothing proven.
set -eu

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
ONBOARDING_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
IMAGE=${COSIFT_TIERB_IMAGE:-cosift-onboarding-tests:latest}
SOURCE_DIR=$ONBOARDING_DIR
BUILD=yes
NOCACHE=
MODE=run

usage() {
    cat <<'EOF'
Usage: run.sh [options]

  --no-build     use the existing image, do not rebuild
  --no-cache     rebuild the image from scratch (re-resolves the npm CLIs)
  --self-test    run against the reference mock installer in fixtures/mock
                 instead of onboarding/, to check the assertions themselves
  --shell        drop into a shell in the container with the same mounts
  --image NAME   image tag to build and run (default cosift-onboarding-tests:latest)
  -h, --help     this text
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
    --no-build) BUILD=no ;;
    --no-cache) NOCACHE=--no-cache ;;
    --self-test) SOURCE_DIR=$SCRIPT_DIR/fixtures/mock ;;
    --shell) MODE=shell ;;
    --image)
        shift
        [ $# -gt 0 ] || {
            echo "run.sh: --image needs a value" >&2
            exit 64
        }
        IMAGE=$1
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "run.sh: unknown option: $1" >&2
        usage >&2
        exit 64
        ;;
    esac
    shift
done

command -v docker >/dev/null 2>&1 || {
    echo "run.sh: docker is not on PATH" >&2
    exit 69
}

if [ "$BUILD" = yes ]; then
    echo "==> building $IMAGE (npm reaches the network here; the test run does not)"
    # shellcheck disable=SC2086
    docker build $NOCACHE -t "$IMAGE" "$SCRIPT_DIR"
fi

echo
echo "==> harness CLIs in this image"
REPORT=$(docker run --rm --network none --entrypoint sh "$IMAGE" -c 'cat "$CLI_REPORT"' 2>/dev/null || true)
if [ -z "$REPORT" ]; then
    echo "!!  no CLI report in the image. Rebuild with --no-cache."
else
    printf '%s\n' "$REPORT" | awk -F'\t' '{printf "    %-6s %-8s %s\n", $1, $2, $4}'
    STUBBED=$(printf '%s\n' "$REPORT" | awk -F'\t' '$1=="stub"{print $2}' | tr '\n' ' ')
    if [ -n "$STUBBED" ]; then
        echo
        echo "!!  STUBBED CLIs: $STUBBED"
        echo "!!  Their npm packages would not install when this image was built."
        echo "!!  Every assertion that needs them reports SKIP, never PASS."
    fi
fi
echo

MOUNTS="-v $SOURCE_DIR:/opt/onboarding:ro -v $SCRIPT_DIR/fixtures:/opt/fixtures:ro"
[ "$SOURCE_DIR" = "$ONBOARDING_DIR" ] || echo "==> SELF-TEST: source is the mock installer at $SOURCE_DIR"

if [ "$MODE" = shell ]; then
    # shellcheck disable=SC2086
    exec docker run --rm -it --network none $MOUNTS "$IMAGE" sh
fi

echo "==> running assertions (container network: none)"
RC=0
# shellcheck disable=SC2086
docker run --rm --network none $MOUNTS "$IMAGE" || RC=$?

echo
case $RC in
0) echo "==> Tier B: PASS" ;;
2) echo "==> Tier B: NOTHING PROVEN (inputs missing; see SKIP-ALL lines above)" ;;
*) echo "==> Tier B: FAIL (exit $RC)" ;;
esac
exit $RC
