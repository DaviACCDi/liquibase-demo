#!/usr/bin/env bash
set -euo pipefail

LB_DIR="${LB_DIR:-liquibase}"
WORKDIR="${GITHUB_WORKSPACE:-$PWD}"
DEPLOYER="${GITHUB_ACTOR:-ci-runner}"
ENV_ARG="${1:-}"                  # DEV|TEST|PROD
shift || true
EXTRA_ARGS=("$@")                 # e.g. --contexts=reset,ddl
MODE="${MODE:-apply}"             # apply | plan

[[ -z "${ENV_ARG}" ]] && { echo "Usage: $0 <DEV|TEST|PROD> [--contexts=...]"; exit 2; }
[[ -z "${JDBC_URL:-}" ]] && { echo "::error::JDBC_URL not found in Environment (dev/test/prod)."; exit 2; }

# ------------ secure parsing of URL postgresql://user:pass@host[:port]/db?query ------------
DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT="5432"; DB_NAME=""; DB_QUERY=""
JDBC_URL_NOAUTH=""
parse_pg_url() {
  local RURL="$1"
  [[ "$RURL" =~ ^postgres(ql)?:// ]] || { echo "::error::Use EXTERNAL URL (postgresql://user:pass@host/db)"; exit 2; }
  local REST="${RURL#postgres*://}"                # user:pass@host:port/db?query
  [[ "$REST" == *"@"* ]] || { echo "::error::URL without credentials (expected user:pass@)"; exit 2; }

  local CREDS="${REST%%@*}"                        # user:pass
  local HOSTPORT_DBQ="${REST#*@}"                  # host:port/db?query
  local HOSTPORT="${HOSTPORT_DBQ%%/*}"             # host:port
  local DBQ="${HOSTPORT_DBQ#*/}"                   # db?query

  DB_USER="${CREDS%%:*}"
  DB_PASS="${CREDS#*:}"

  DB_HOST="${HOSTPORT%%:*}"
  local PORT_PART="${HOSTPORT#*:}"
  [[ "$PORT_PART" != "$HOSTPORT" ]] && DB_PORT="$PORT_PART" || DB_PORT="5432"

  DB_NAME="${DBQ%%\?*}"
  DB_QUERY=""
  [[ "$DBQ" == *\?* ]] && DB_QUERY="${DBQ#*?}"

  # sanitize user/password from query and enforce sslmode=require
  local out_q=""; local have_ssl="0"
  if [[ -n "$DB_QUERY" ]]; then
    IFS='&' read -r -a parts <<<"$DB_QUERY"
    for kv in "${parts[@]}"; do
      [[ -z "$kv" ]] && continue
      case "$kv" in
        user=*|password=*) ;;                    # do not replicate credentials in URL
        sslmode=*) have_ssl="1"; out_q="${out_q:+$out_q&}$kv" ;;
        *) out_q="${out_q:+$out_q&}$kv" ;;
      esac
    done
  fi
  [[ "$have_ssl" == "0" ]] && out_q="${out_q:+$out_q&}sslmode=require"
  JDBC_URL_NOAUTH="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}?${out_q}"
}
parse_pg_url "$JDBC_URL"

# ------------ helpers/log ------------
mask() {
  sed -E 's#//([^:@/]+):[^@/]+@#//\1:****@#; s#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/(password=)[^&]+/\1****/g' <<<"$1"
}
log_ctx() {
  echo "### Context"
  echo "ENV: $ENV_ARG"
  echo "MODE: $MODE"
  echo "Actor: $DEPLOYER"
  echo "Workspace: $WORKDIR"
  echo "LB_DIR: $LB_DIR"
  echo "JDBC_URL (masked input): $(mask "$JDBC_URL")"
  echo "JDBC_URL effective (no auth, masked): $(mask "$JDBC_URL_NOAUTH")"
}
tcp_probe() {
  echo "[tcp] testing ${DB_HOST}:${DB_PORT} ..."
  docker run --rm --network host bash:5 bash -lc "timeout 5 bash -c '</dev/tcp/${DB_HOST}/${DB_PORT}'" \
    && echo "[tcp] OK" || { echo "::error::[tcp] Cannot open TCP connection to ${DB_HOST}:${DB_PORT}"; exit 3; }
}

# Simple classification of deploy type based on updateSQL
classify_plan() {
  local f="$1"
  local U; U="$(tr '[:lower:]' '[:upper:]' < "$f" 2>/dev/null || true)"
  [[ -z "$U" ]] && { echo "other"; return; }
  if   grep -Eq '\bDROP\s+(TABLE|COLUMN|INDEX|CONSTRAINT)\b' <<<"$U"; then echo "schema:drop"
  elif grep -Eq '\bCREATE\s+TABLE\b'                        <<<"$U"; then echo "schema:create-table"
  elif grep -Eq '\bALTER\s+TABLE\b.*\bADD\s+COLUMN\b'       <<<"$U"; then echo "schema:add-column"
  elif grep -Eq '\bALTER\s+TABLE\b'                         <<<"$U"; then echo "schema:alter"
  elif grep -Eq '\b(INSERT|UPDATE|DELETE|MERGE)\b'          <<<"$U"; then echo "data:mutation"
  else  echo "other"
  fi
}

# Run liquibase inside container
run_liquibase() {
  local PROPS="$1"; shift
  echo "+ liquibase $* (props=$PROPS)"
  # debug contents
  docker run --rm --network host -w /workspace \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    bash -lc 'echo "[container] /workspace:"; ls -la /workspace; ls -la /workspace/changelogs || true'

  # expose useful properties to changeSets
  docker run --rm --network host -w /workspace \
    -e "JAVA_OPTS=-Ddeployer=${DEPLOYER} -DdeployKind=${DEPLOY_KIND:-unknown} -DgitSha=${GITHUB_SHA:-unknown} -DgitRef=${GITHUB_REF_NAME:-unknown}" \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    --defaultsFile="/workspace/conf/$PROPS" \
    --log-level=info \
    --url="$JDBC_URL_NOAUTH" \
    --username="$DB_USER" \
    --password="$DB_PASS" \
    "$@" "${EXTRA_ARGS[@]}"
}

promote() {
  local ENV_NAME="$1"; local PROPS="$2"
  local PLAN_FILE="plan_${ENV_NAME}.sql"

  echo "===== [$ENV_NAME] VALIDATE ====="
  run_liquibase "$PROPS" validate

  echo "===== [$ENV_NAME] STATUS ====="
  run_liquibase "$PROPS" status --verbose || true

  echo "===== [$ENV_NAME] DRY-RUN (updateSQL) ====="
  if ! run_liquibase "$PROPS" updateSQL > "$PLAN_FILE"; then
    echo "!!! updateSQL failed (keeping logs)."
  fi
  tail -n 80 "$PLAN_FILE" || true

  # classify type of changes
  DEPLOY_KIND="$(classify_plan "$PLAN_FILE")"
  echo "[kind] $DEPLOY_KIND"

  if [[ "$MODE" == "plan" ]]; then
    return 0
  fi

  # detect if reset context is enabled
  local IS_RESET="false"
  if [[ " ${EXTRA_ARGS[*]} " == *"--contexts=reset"* ]]; then
    IS_RESET="true"
    echo "[ci_deploy] Reset mode detected → will skip TAG_POST creation."
  fi

  # define TAG_PRE/TAG_POST if not passed from outside
  local SHA_SHORT="${GITHUB_SHA:-unknown}"; SHA_SHORT="${SHA_SHORT:0:7}"
  if [[ -z "${TAG_PRE:-}" ]]; then
    TAG_PRE="auto-${ENV_NAME,,}-${SHA_SHORT}-pre"
  fi
  TAG_POST="${TAG_PRE%-pre}-post-${DEPLOY_KIND//[^a-zA-Z0-9:_-]/_}"

  # TAG before (restore point)
  echo "===== [$ENV_NAME] TAG_PRE ($TAG_PRE) ====="
  run_liquibase "$PROPS" tag "$TAG_PRE" || true

  echo "===== [$ENV_NAME] UPDATE ====="
  if ! run_liquibase "$PROPS" update; then
    echo "!!! Failed in $ENV_NAME → rollback"
    run_liquibase "$PROPS" rollbackToTag "$TAG_PRE" || true
    exit 1
  fi

  # TAG after (only if not reset)
  if [[ "$IS_RESET" == "false" ]]; then
    echo "===== [$ENV_NAME] TAG_POST ($TAG_POST) ====="
    run_liquibase "$PROPS" tag "$TAG_POST" || true
    echo "===== [$ENV_NAME] HISTORY ====="
    run_liquibase "$PROPS" history || true
  fi
}

# ------------ logs and sanity checks ------------
log_ctx
echo
echo "Files sanity:"
test -f "$WORKDIR/$LB_DIR/changelogs/db.changelog-master.yaml" || { echo "::error::master changelog missing"; exit 2; }
for f in "$WORKDIR/$LB_DIR"/conf/*.properties; do
  echo "---- $f ----"
  sed -n '1,100p' "$f" | sed 's/^password=.*/password=****/' || true
done
echo

tcp_probe

# ------------ dispatch by environment ------------
case "$ENV_ARG" in
  DEV)  promote "DEV"  "liquibase-dev.properties"  ;;
  TEST) promote "TEST" "liquibase-test.properties" ;;
  PROD) promote "PROD" "liquibase-prod.properties" ;;
  *)    echo "Invalid environment: $ENV_ARG (use DEV|TEST|PROD)"; exit 2 ;;
esac

echo "✓ Finished $ENV_ARG ($MODE) – kind=${DEPLOY_KIND:-unknown}"
