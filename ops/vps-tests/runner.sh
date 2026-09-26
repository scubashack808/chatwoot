#!/usr/bin/env bash
# Remote runner for the maintained Chatwoot VPS backend test route (WOOT-32).
#
# Transferred with each snapshot and hashed by the client, so an obsolete host
# copy can never silently test with different rules. Runs on mre-comms; owns
# only resources under /opt/chatwoot-vps-tests and its own labelled containers.
#
# Contract: verify the submitted snapshot before doing anything, refuse loudly
# on any identity mismatch, and never let a failed stage look like success.

set -Eeuo pipefail

ROUTE_ROOT="/opt/chatwoot-vps-tests"
CACHES_DIR="${ROUTE_ROOT}/caches"
LOCK_FILE="${ROUTE_ROOT}/route.lock"
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-1800}"
LABEL="chatwoot-vps-tests"

RUN_DIR=""
SPECS=()
STAGE="startup"
EXIT_CODE=1
EXAMPLES=""
FAILURES=""
DEPENDENCY_KEY=""
ASSET_KEY=""
RUBY_VERSION=""
BUNDLER_VERSION=""
NODE_VERSION=""
CONTAINERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --) shift; SPECS=("$@"); break ;;
    *) echo "runner: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "${RUN_DIR}" ]] || { echo "runner: --run-dir is required" >&2; exit 2; }
[[ ${#SPECS[@]} -gt 0 ]] || { echo "runner: at least one spec selector is required" >&2; exit 2; }

LOG_DIR="${RUN_DIR}/logs"
mkdir -p "${LOG_DIR}"
RECEIPT="${RUN_DIR}/receipt.json"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

write_receipt() {
  cat >"${RECEIPT}" <<EOF
{
  "schema": "chatwoot.vps-tests.receipt/1",
  "runDir": $(json_escape "${RUN_DIR}"),
  "finishedAt": $(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)"),
  "stage": $(json_escape "${STAGE}"),
  "exitCode": ${EXIT_CODE},
  "specs": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${SPECS[@]}"),
  "examples": ${EXAMPLES:-null},
  "failures": ${FAILURES:-null},
  "image": { "id": $(json_escape "${IMAGE_ID:-}"), "platform": $(json_escape "${IMAGE_PLATFORM:-}") },
  "runtime": {
    "ruby": $(json_escape "${RUBY_VERSION}"),
    "bundler": $(json_escape "${BUNDLER_VERSION}"),
    "node": $(json_escape "${NODE_VERSION}")
  },
  "keys": {
    "dependency": $(json_escape "${DEPENDENCY_KEY}"),
    "asset": $(json_escape "${ASSET_KEY}")
  },
  "source": {
    "head": $(json_escape "${SRC_HEAD:-}"),
    "branch": $(json_escape "${SRC_BRANCH:-}"),
    "dirty": ${SRC_DIRTY:-null},
    "filesDigest": $(json_escape "${SRC_FILES_DIGEST:-}"),
    "archiveSha256": $(json_escape "${SRC_ARCHIVE_SHA:-}")
  }
}
EOF
}

# Any unexpected error still produces a durable receipt with a nonzero code, so
# a transport or shell failure cannot be mistaken for a pass.
on_error() {
  local code=$?
  EXIT_CODE=$(( code == 0 ? 1 : code ))
  echo "runner: failed during stage '${STAGE}' with exit ${EXIT_CODE}" >&2
  write_receipt
  cleanup_containers
  exit "${EXIT_CODE}"
}
trap on_error ERR

cleanup_containers() {
  for container in "${CONTAINERS[@]:-}"; do
    [[ -n "${container}" ]] && docker rm -f "${container}" >/dev/null 2>&1 || true
  done
}

fail() {
  STAGE="$1"; EXIT_CODE="${2:-1}"
  echo "runner: ${3:-failed}" >&2
  write_receipt
  cleanup_containers
  exit "${EXIT_CODE}"
}

# ---------------------------------------------------------------- verification
STAGE="verify-snapshot"
cd "${RUN_DIR}"

[[ -f manifest.json && -f snapshot.tar.gz ]] || fail "verify-snapshot" 2 "missing manifest or archive"

manifest_get() { python3 -c 'import json,sys; d=json.load(open("manifest.json")); v=d
for k in sys.argv[1].split("."):
    v = v[k]
print(v)' "$1"; }

SRC_HEAD="$(manifest_get source.head)"
SRC_BRANCH="$(manifest_get source.branch)"
SRC_DIRTY="$(python3 -c 'import json; print(str(json.load(open("manifest.json"))["source"]["dirty"]).lower())')"
SRC_FILES_DIGEST="$(manifest_get filesDigest)"
SRC_ARCHIVE_SHA="$(manifest_get archiveSha256)"

ACTUAL_ARCHIVE_SHA="$(sha256sum snapshot.tar.gz | awk '{print $1}')"
if [[ "${ACTUAL_ARCHIVE_SHA}" != "${SRC_ARCHIVE_SHA}" ]]; then
  fail "verify-snapshot" 2 "archive sha256 mismatch: expected ${SRC_ARCHIVE_SHA}, got ${ACTUAL_ARCHIVE_SHA}"
fi

# Refuse absolute paths and traversal before extracting anything.
if tar -tzf snapshot.tar.gz | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  fail "verify-snapshot" 2 "archive contains unsafe member paths"
fi

SRC_DIR="${RUN_DIR}/source"
rm -rf "${SRC_DIR}"; mkdir -p "${SRC_DIR}"
tar -xzf snapshot.tar.gz -C "${SRC_DIR}"

# Re-hash every extracted file against the manifest: this is what makes "the
# bytes I submitted are the bytes under test" a checked claim, not a promise.
python3 - "${SRC_DIR}" <<'PYTHON' || fail "verify-snapshot" 2 "extracted content does not match manifest"
import hashlib, json, os, sys
src = sys.argv[1]
manifest = json.load(open("manifest.json"))
bad = []
for entry in manifest["files"]:
    target = os.path.join(src, entry["path"])
    if entry["type"] == "symlink":
        if not os.path.islink(target) or os.readlink(target) != entry["target"]:
            bad.append(entry["path"])
        continue
    if not os.path.isfile(target):
        bad.append(entry["path"]); continue
    digest = hashlib.sha256(open(target, "rb").read()).hexdigest()
    if digest != entry["sha256"]:
        bad.append(entry["path"])
for deleted in manifest.get("deletions", []):
    if os.path.exists(os.path.join(src, deleted)):
        bad.append(f"deleted-but-present:{deleted}")
if bad:
    print("mismatched paths:", *bad[:20], sep="\n  ", file=sys.stderr)
    sys.exit(1)
print(f"verified {len(manifest['files'])} files against manifest")
PYTHON

# ------------------------------------------------------------------- runtime
STAGE="verify-runtime"
CONFIG="${SRC_DIR}/ops/vps-tests/runtime.json"
[[ -f "${CONFIG}" ]] || fail "verify-runtime" 2 "submitted snapshot has no ops/vps-tests/runtime.json"

cfg() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d
for k in sys.argv[2].split("."):
    v = v[k]
print(v)' "${CONFIG}" "$1"; }

IMAGE_ID="$(cfg image.id)"
IMAGE_PLATFORM="$(cfg image.platform)"
APP_PATH="$(cfg image.appPath)"
CPUS="$(cfg limits.cpus)"; MEMORY="$(cfg limits.memory)"
MEMORY_SWAP="$(cfg limits.memorySwap)"; PIDS="$(cfg limits.pids)"
NETWORK="$(cfg services.networkName)"
PG_IMAGE="$(cfg services.postgresImage)"; REDIS_IMAGE="$(cfg services.redisImage)"

docker image inspect "${IMAGE_ID}" >/dev/null 2>&1 || \
  fail "verify-runtime" 2 "pinned image ${IMAGE_ID} is not present; follow the refresh procedure in ops/vps-tests/README.md"

ACTUAL_PLATFORM="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${IMAGE_ID}")"
[[ "${ACTUAL_PLATFORM}" == "${IMAGE_PLATFORM}" ]] || \
  fail "verify-runtime" 2 "image platform ${ACTUAL_PLATFORM} != required ${IMAGE_PLATFORM}"

RUBY_VERSION="$(docker run --rm --platform "${IMAGE_PLATFORM}" "${IMAGE_ID}" ruby -e 'print RUBY_VERSION')"
REQUIRED_RUBY="$(tr -d '[:space:]' < "${SRC_DIR}/.ruby-version")"
if [[ "${RUBY_VERSION}" != "${REQUIRED_RUBY}" ]]; then
  fail "verify-runtime" 2 "image Ruby ${RUBY_VERSION} != snapshot .ruby-version ${REQUIRED_RUBY}; follow the documented refresh path"
fi
BUNDLER_VERSION="$(docker run --rm --platform "${IMAGE_PLATFORM}" "${IMAGE_ID}" bundle --version 2>/dev/null | awk '{print $3}')"
NODE_VERSION="$(docker run --rm --platform "${IMAGE_PLATFORM}" "${IMAGE_ID}" node --version 2>/dev/null || echo "")"

# Dependency key binds the image to the submitted lockfiles.
DEPENDENCY_KEY="$(python3 - "${SRC_DIR}" "${CONFIG}" "${IMAGE_ID}" <<'PYTHON'
import hashlib, json, os, sys
src, config_path, image = sys.argv[1], sys.argv[2], sys.argv[3]
config = json.load(open(config_path))
digest = hashlib.sha256()
digest.update(image.encode())
for name in config["dependencyKeyFiles"]:
    path = os.path.join(src, name)
    digest.update(name.encode())
    digest.update(hashlib.sha256(open(path, "rb").read()).digest() if os.path.isfile(path) else b"absent")
print(digest.hexdigest())
PYTHON
)"

# Asset key deliberately covers the entire submitted tree: predictable rebuilds
# beat an optimized key that misses a config change.
ASSET_KEY="$(python3 -c '
import hashlib,sys
print(hashlib.sha256((sys.argv[1]+sys.argv[2]).encode()).hexdigest())' "${SRC_FILES_DIGEST}" "${DEPENDENCY_KEY}")"

BUNDLE_CACHE="${CACHES_DIR}/bundle/${DEPENDENCY_KEY}"
NODE_CACHE="${CACHES_DIR}/node/${DEPENDENCY_KEY}"
ASSET_CACHE="${CACHES_DIR}/assets/${ASSET_KEY}"
mkdir -p "${BUNDLE_CACHE}" "${NODE_CACHE}" "${ASSET_CACHE}"

echo "runner: image ${IMAGE_ID} ruby ${RUBY_VERSION} deps ${DEPENDENCY_KEY:0:12} assets ${ASSET_KEY:0:12}"

# ---------------------------------------------------------------------- lock
STAGE="acquire-lock"
mkdir -p "$(dirname "${LOCK_FILE}")"
exec 9>"${LOCK_FILE}"
if ! flock -w "${LOCK_WAIT_SECONDS}" 9; then
  fail "acquire-lock" 75 "another run holds the route lock; retry later (EX_TEMPFAIL)"
fi
echo "runner: route lock acquired"

# ------------------------------------------------------------------ services
STAGE="start-services"
RUN_ID="$(basename "${RUN_DIR}")"
PG_NAME="${LABEL}-pg-${RUN_ID}"
REDIS_NAME="${LABEL}-redis-${RUN_ID}"
APP_NAME="${LABEL}-app-${RUN_ID}"
PG_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"

docker network inspect "${NETWORK}" >/dev/null 2>&1 || \
  docker network create --label "${LABEL}" --internal "${NETWORK}" >/dev/null

CONTAINERS+=("${PG_NAME}" "${REDIS_NAME}" "${APP_NAME}")

docker run -d --name "${PG_NAME}" --label "${LABEL}" --network "${NETWORK}" \
  --cpus "$(cfg services.postgresLimits.cpus)" --memory "$(cfg services.postgresLimits.memory)" \
  --pids-limit "$(cfg services.postgresLimits.pids)" \
  -e POSTGRES_USER=chatwoot_test -e POSTGRES_PASSWORD="${PG_PASSWORD}" -e POSTGRES_DB=chatwoot_test \
  "${PG_IMAGE}" >/dev/null

docker run -d --name "${REDIS_NAME}" --label "${LABEL}" --network "${NETWORK}" \
  --cpus "$(cfg services.redisLimits.cpus)" --memory "$(cfg services.redisLimits.memory)" \
  --pids-limit "$(cfg services.redisLimits.pids)" \
  "${REDIS_IMAGE}" >/dev/null

for _ in $(seq 1 60); do
  if docker exec "${PG_NAME}" pg_isready -U chatwoot_test -d chatwoot_test >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "${PG_NAME}" pg_isready -U chatwoot_test -d chatwoot_test >/dev/null 2>&1 || \
  fail "start-services" 1 "route-owned postgres did not become ready"

# -------------------------------------------------------------------- tests
STAGE="rspec"
set +e
docker run --rm --name "${APP_NAME}" --label "${LABEL}" --network "${NETWORK}" \
  --platform "${IMAGE_PLATFORM}" \
  --cpus "${CPUS}" --memory "${MEMORY}" --memory-swap "${MEMORY_SWAP}" --pids-limit "${PIDS}" \
  -v "${SRC_DIR}:${APP_PATH}:ro" \
  -v "${RUN_DIR}/work:${APP_PATH}/tmp" \
  -v "${BUNDLE_CACHE}:/bundle" \
  -v "${ASSET_CACHE}:${APP_PATH}/public/vite-test" \
  -w "${APP_PATH}" \
  -e RAILS_ENV=test -e NODE_ENV=test \
  -e BUNDLE_PATH=/bundle \
  -e POSTGRES_HOST="${PG_NAME}" -e POSTGRES_USERNAME=chatwoot_test \
  -e POSTGRES_PASSWORD="${PG_PASSWORD}" -e POSTGRES_DATABASE=chatwoot_test \
  -e REDIS_URL="redis://${REDIS_NAME}:6379" \
  -e RSPEC_JSON_OUT="${APP_PATH}/tmp/rspec_results.json" \
  "${IMAGE_ID}" \
  bash -lc '
    set -o pipefail
    bundle check >/dev/null 2>&1 || bundle install --quiet || exit 91
    bundle exec rails db:test:prepare >/dev/null || exit 92
    bundle exec rspec --format progress --format json --out "${RSPEC_JSON_OUT}" "$@"
  ' _ "${SPECS[@]}" 2>&1 | tee "${LOG_DIR}/rspec.log"
RSPEC_STATUS="${PIPESTATUS[0]}"
set -e

EXIT_CODE="${RSPEC_STATUS}"
case "${RSPEC_STATUS}" in
  91) STAGE="bundle-install" ;;
  92) STAGE="db-prepare" ;;
  *)  STAGE="rspec" ;;
esac

RESULTS="${RUN_DIR}/work/rspec_results.json"
if [[ -f "${RESULTS}" ]]; then
  cp "${RESULTS}" "${LOG_DIR}/rspec_results.json"
  EXAMPLES="$(python3 -c 'import json;print(json.load(open("'"${RESULTS}"'"))["summary"]["example_count"])' 2>/dev/null || echo "")"
  FAILURES="$(python3 -c 'import json;print(json.load(open("'"${RESULTS}"'"))["summary"]["failure_count"])' 2>/dev/null || echo "")"
  # A zero-example run is not a pass: it means the selector matched nothing.
  if [[ "${EXIT_CODE}" == "0" && "${EXAMPLES}" == "0" ]]; then
    STAGE="rspec"; EXIT_CODE=97
    echo "runner: spec selection matched zero examples; refusing to report success" >&2
  fi
elif [[ "${EXIT_CODE}" == "0" ]]; then
  STAGE="rspec"; EXIT_CODE=96
  echo "runner: rspec produced no JSON results; refusing to report success" >&2
fi

write_receipt
cleanup_containers
echo "runner: stage=${STAGE} exit=${EXIT_CODE} examples=${EXAMPLES:-n/a} failures=${FAILURES:-0}"
exit "${EXIT_CODE}"
