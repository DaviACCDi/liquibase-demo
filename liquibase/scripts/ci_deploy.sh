#!/usr/bin/env bash
set -euo pipefail

LB_DIR="${LB_DIR:-liquibase}"
WORKDIR="${GITHUB_WORKSPACE:-$PWD}"
DEPLOYER="${GITHUB_ACTOR:-ci-runner}"

# ENV LIST (DEV|TEST|PROD), pode ser múltiplo: "DEV,TEST" ou "ALL"
ENV_LIST_RAW="${1:-}"; shift || true
[[ -z "$ENV_LIST_RAW" ]] && { echo "Usage: $0 <ENV|ENV1,ENV2|ALL> [--contexts=...]"; exit 2; }

# Args extras p/ Liquibase (ex.: --contexts=reset,ddl)
EXTRA_ARGS=("$@")

# apply | plan | tag
MODE="${MODE:-apply}"          # default: apply
TAG_NAME="${TAG_NAME:-}"       # usado quando MODE=tag

# ------------------------------------------------------------
# Util: máscara de dados e parsing de URL postgres externa
mask() {
  sed -E 's#//([^:@/]+):[^@/]+@#//\1:****@#; s#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/(password=)[^&]+/\1****/g' <<<"$1"
}

DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT="5432"; DB_NAME=""; DB_QUERY=""
JDBC_URL_NOAUTH=""; JDBC_URL_CURRENT=""

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

  local out_q=""; local have_ssl="0"
  if [[ -n "$DB_QUERY" ]]; then
    IFS='&' read -r -a parts <<<"$DB_QUERY"
    for kv in "${parts[@]}"; do
      [[ -z "$kv" ]] && continue
      case "$kv" in
        user=*|password=*) ;;                    # não replicar credenciais
        sslmode=*) have_ssl="1"; out_q="${out_q:+$out_q&}$kv" ;;
        *) out_q="${out_q:+$out_q&}$kv" ;;
      esac
    done
  fi
  [[ "$have_ssl" == "0" ]] && out_q="${out_q:+$out_q&}sslmode=require"
  JDBC_URL_NOAUTH="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}?${out_q}"
}

tcp_probe() {
  echo "[tcp] testing ${DB_HOST}:${DB_PORT} ..."
  docker run --rm --network host bash:5 bash -lc "timeout 5 bash -c '</dev/tcp/${DB_HOST}/${DB_PORT}'" \
    && echo "[tcp] OK" || { echo "::error::[tcp] Cannot open TCP connection to ${DB_HOST}:${DB_PORT}"; exit 3; }
}

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

run_liquibase() {
  local PROPS="$1"; shift
  echo "+ liquibase $* (props=$PROPS)"
  docker run --rm --network host -w /workspace \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    bash -lc 'echo "[container] /workspace:"; ls -la /workspace; ls -la /workspace/changelogs || true'

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

log_ctx() {
  echo "### Context"
  echo "ENV: $1"
  echo "MODE: $MODE"
  echo "Actor: $DEPLOYER"
  echo "Workspace: $WORKDIR"
  echo "LB_DIR: $LB_DIR"
  echo "JDBC_URL (masked input): $(mask "$JDBC_URL_CURRENT")"
  echo "JDBC_URL effective (no auth, masked): $(mask "$JDBC_URL_NOAUTH")"
}

env_props() {
  case "$1" in
    DEV)  echo "liquibase-dev.properties" ;;
    TEST) echo "liquibase-test.properties" ;;
    PROD) echo "liquibase-prod.properties" ;;
  esac
}

# Seleciona a URL do ambiente atual:
pick_jdbc_for_env() {
  local E="$1"
  local var="JDBC_URL_${E}"
  if [[ -n "${!var:-}" ]]; then
    JDBC_URL_CURRENT="${!var}"
  else
    JDBC_URL_CURRENT="${JDBC_URL:-}"
  fi
  [[ -z "$JDBC_URL_CURRENT" ]] && { echo "::error::JDBC_URL (ou $var) não definido para $E."; exit 2; }
  parse_pg_url "$JDBC_URL_CURRENT"
}

promote() {
  local ENV_NAME="$1"
  local PROPS; PROPS="$(env_props "$ENV_NAME")"

  log_ctx "$ENV_NAME"
  echo
  echo "Files sanity:"
  test -f "$WORKDIR/$LB_DIR/changelogs/db.changelog-master.yaml" || { echo "::error::master changelog missing"; exit 2; }
  for f in "$WORKDIR/$LB_DIR"/conf/*.properties; do
    echo "---- $f ----"
    sed -n '1,100p' "$f" | sed 's/^password=.*/password=****/' || true
  done
  echo

  tcp_probe

  # Se for reset: executa somente o contexto 'reset'
  if [[ " ${EXTRA_ARGS[*]} " == *"--contexts=reset"* ]]; then
    echo "[RESET] Rodando apenas o contexto 'reset' em $ENV_NAME…"
    local PLAN_FILE="plan_${ENV_NAME}.sql"
    if [[ "$MODE" == "plan" ]]; then
      # DRY RUN do reset
      run_liquibase "$PROPS" updateSQL > "$PLAN_FILE"
      tail -n 80 "$PLAN_FILE" || true
    else
      # apply do reset
      run_liquibase "$PROPS" update
    fi
    return 0
  fi


  echo "===== [$ENV_NAME] VALIDATE ====="
  run_liquibase "$PROPS" validate

  echo "===== [$ENV_NAME] STATUS ====="
  run_liquibase "$PROPS" status --verbose || true

  echo "===== [$ENV_NAME] DRY-RUN (updateSQL) ====="
  local PLAN_FILE="plan_${ENV_NAME}.sql"
  if ! run_liquibase "$PROPS" updateSQL > "$PLAN_FILE"; then
    echo "!!! updateSQL failed (keeping logs)."
  fi
  tail -n 80 "$PLAN_FILE" || true

  DEPLOY_KIND="$(classify_plan "$PLAN_FILE")"
  echo "[kind] $DEPLOY_KIND"

  [[ "$MODE" == "plan" ]] && return 0

  # tagging “pre”
  local SHA_SHORT="${GITHUB_SHA:-unknown}"; SHA_SHORT="${SHA_SHORT:0:7}"
  local TAG_PRE="auto-${ENV_NAME,,}-${SHA_SHORT}-pre"
  local TAG_POST="${TAG_PRE%-pre}-post-${DEPLOY_KIND//[^a-zA-Z0-9:_-]/_}"

  echo "===== [$ENV_NAME] TAG_PRE ($TAG_PRE) ====="
  run_liquibase "$PROPS" tag "$TAG_PRE" || true

  echo "===== [$ENV_NAME] UPDATE ====="
  if ! run_liquibase "$PROPS" update; then
    echo "!!! Failed in $ENV_NAME → rollback"
    # FIX: rollback correto
    run_liquibase "$PROPS" rollback --tag "$TAG_PRE" || true
    exit 1
  fi

  echo "===== [$ENV_NAME] TAG_POST ($TAG_POST) ====="
  run_liquibase "$PROPS" tag "$TAG_POST" || true
  echo "===== [$ENV_NAME] HISTORY ====="
  run_liquibase "$PROPS" history || true
}

tag_only() {
  local ENV_NAME="$1"
  local PROPS; PROPS="$(env_props "$ENV_NAME")"
  [[ -z "$TAG_NAME" ]] && { echo "::error::Para MODE=tag, defina TAG_NAME=..."; exit 2; }

  log_ctx "$ENV_NAME"
  echo "===== [$ENV_NAME] TAG ONLY ($TAG_NAME) ====="
  run_liquibase "$PROPS" tag "$TAG_NAME"
}

# ------------------------------------------------------------
# Normaliza lista de ambientes
if [[ "${ENV_LIST_RAW^^}" == "ALL" ]]; then
  ENV_LIST=("DEV" "TEST" "PROD")
else
  IFS=',' read -r -a ENV_LIST <<<"${ENV_LIST_RAW^^}"
fi

# Para cada ambiente, seleciona JDBC_URL adequado e executa a ação
for ENV in "${ENV_LIST[@]}"; do
  case "$ENV" in
    DEV|TEST|PROD) ;;
    *) echo "Invalid environment in list: $ENV (use DEV|TEST|PROD|ALL)"; exit 2 ;;
  esac

  # Seleciona URL por ambiente (JDBC_URL_DEV/TEST/PROD ou JDBC_URL)
  pick_jdbc_for_env "$ENV"

  case "$MODE" in
    tag)   tag_only "$ENV" ;;
    plan|apply) promote "$ENV" ;;
    *) echo "Invalid MODE=$MODE (use plan|apply|tag)"; exit 2 ;;
  esac
done

echo "✓ Finished ${ENV_LIST[*]} (MODE=$MODE)"
