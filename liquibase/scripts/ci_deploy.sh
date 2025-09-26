#!/usr/bin/env bash
set -euo pipefail

# ===================== Config =====================
LB_DIR="${LB_DIR:-liquibase}"
WORKDIR="${GITHUB_WORKSPACE:-$PWD}"
DEPLOYER="${GITHUB_ACTOR:-ci-runner}"
LIQUIBASE_LOG_LEVEL="${LIQUIBASE_LOG_LEVEL:-info}"  # info|debug|trace
MODE="${MODE:-apply}"   # apply | plan

ENV_ARG="${1:-}"
if [[ -z "$ENV_ARG" ]]; then
  echo "Uso: $0 <DEV|TEST|PROD>"
  exit 2
fi

if [[ -z "${JDBC_URL:-}" ]]; then
  echo "::error::JDBC_URL não encontrada no Environment"
  exit 2
fi

# ===================== Helpers =====================
mask_url() {
  # esconde user:pass e host/db, e password= na query
  sed -E 's#//([^:@/]+):[^@/]+@#//\1:****@#; s#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/([?&]password=)[^&]+/\1****/g' <<<"$1"
}

# Globals extraídas do parser
DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT="5432"; DB_NAME=""; DB_QUERY=""
JDBC_URL_NOAUTH=""

parse_pg_url() {
  local RURL="$1"

  # aceita postgres:// ou postgresql:// (sem regex)
  if [[ "$RURL" == postgres://* ]]; then
    :
  elif [[ "$RURL" == postgresql://* ]]; then
    :
  else
    echo "::error::URL não começa com postgres:// ou postgresql://"; return 1
  fi

  # remove o prefixo até "://"
  local REST="${RURL#*://}"               # user:pass@host:port/db?query
  local CREDS="${REST%%@*}"               # user:pass
  local HOSTPORT_DBQ="${REST#*@}"         # host:port/db?query
  local HOSTPORT="${HOSTPORT_DBQ%%/*}"    # host:port
  local DBQ="${HOSTPORT_DBQ#*/}"          # db?query

  DB_USER="${CREDS%%:*}"
  DB_PASS="${CREDS#*:}"
  DB_HOST="${HOSTPORT%%:*}"
  local PORT_PART="${HOSTPORT#*:}"
  [[ "$PORT_PART" != "$HOSTPORT" ]] && DB_PORT="$PORT_PART" || DB_PORT="5432"

  DB_NAME="${DBQ%%\?*}"
  DB_QUERY=""
  if [[ "$DBQ" == *\?* ]]; then
    DB_QUERY="${DBQ#*?}"
  fi

  # garante sslmode=require na query (sem duplicar) — sem regex
  if [[ -z "$DB_QUERY" ]]; then
    DB_QUERY="sslmode=require"
  else
    case "$DB_QUERY" in
      *sslmode=*) : ;;  # já tem
      *) DB_QUERY="${DB_QUERY}&sslmode=require" ;;
    esac
  fi

  JDBC_URL_NOAUTH="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}?${DB_QUERY}"
}

to_jdbc_and_creds() {
  local RURL="$1"
  if [[ "$RURL" == postgres://* || "$RURL" == postgresql://* ]]; then
    parse_pg_url "$RURL"
  elif [[ "$RURL" == jdbc:postgresql://* ]]; then
    JDBC_URL_NOAUTH="$RURL"
    # tenta extrair user/pass da query se houver (opcional)
    case "$RURL" in
      *"?user="*|*"&user="* ) DB_USER="$(sed -n 's/.*[?&]user=\([^&]*\).*/\1/p' <<<"$RURL")" ;; *) : ;;
    esac
    case "$RURL" in
      *"?password="*|*"&password="* ) DB_PASS="$(sed -n 's/.*[?&]password=\([^&]*\).*/\1/p' <<<"$RURL")" ;; *) : ;;
    esac
  else
    echo "::error::Formato de URL não reconhecido: $(mask_url "$RURL")" >&2
    return 1
  fi
}

# ===================== Liquibase =====================
run_liquibase () {
  local PROPS="$1"; local URL="$2"; local WHAT="$3"
  echo "+ liquibase $WHAT"
  echo "  - props: /workspace/conf/$PROPS"
  echo "  - url:   $(mask_url "$URL")"
  echo "  - user:  ${DB_USER:+****}  (pass oculto)"
  echo

  # Conteúdo útil para debug
  docker run --rm --network host -w /workspace \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    bash -lc 'echo "[container] /workspace"; ls -la /workspace; echo "[container] /workspace/conf"; ls -la /workspace/conf; echo "[container] /workspace/changelogs"; ls -la /workspace/changelogs'

  # Execução
  docker run --rm --network host -w /workspace \
    -e "JAVA_OPTS=-Ddeployer=${DEPLOYER}" \
    -e "LIQUIBASE_LOG_LEVEL=${LIQUIBASE_LOG_LEVEL}" \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    --defaultsFile="/workspace/conf/$PROPS" \
    --log-level="${LIQUIBASE_LOG_LEVEL}" \
    --url="$URL" \
    ${DB_USER:+--username="$DB_USER"} \
    ${DB_PASS:+--password="$DB_PASS"} \
    $WHAT
}

promote () {
  local ENV_NAME="$1"; local PROPS="$2"; local URL="$3"

  [[ -f "$WORKDIR/$LB_DIR/conf/$PROPS" ]] || { echo "::error::Arquivo de propriedades ausente: $LB_DIR/conf/$PROPS"; exit 2; }

  echo "===== [$ENV_NAME] VALIDATE ====="
  run_liquibase "$PROPS" "$URL" validate

  echo "===== [$ENV_NAME] STATUS ====="
  run_liquibase "$PROPS" "$URL" status --verbose || true

  if [[ "$MODE" == "plan" ]]; then
    echo "===== [$ENV_NAME] DRY-RUN (updateSQL) ====="
    if ! run_liquibase "$PROPS" "$URL" updateSQL > "plan_${ENV_NAME}.sql"; then
      echo "!!! updateSQL retornou erro (seguindo para logs)."
    fi
    tail -n 80 "plan_${ENV_NAME}.sql" || true
    return 0
  fi

  if [[ -n "${TAG_PRE:-}" ]]; then
    echo "===== [$ENV_NAME] TAG PRE ====="
    run_liquibase "$PROPS" "$URL" tag "$TAG_PRE" || true
  fi

  echo "===== [$ENV_NAME] DRY-RUN (updateSQL) ====="
  if ! run_liquibase "$PROPS" "$URL" updateSQL > "plan_${ENV_NAME}.sql"; then
    echo "!!! updateSQL retornou erro (seguindo para logs)."
  fi
  tail -n 80 "plan_${ENV_NAME}.sql" || true

  echo "===== [$ENV_NAME] UPDATE ====="
  if ! run_liquibase "$PROPS" "$URL" update; then
    echo "!!! UPDATE falhou em $ENV_NAME"
    if [[ -n "${TAG_PRE:-}" ]]; then
      echo ">>> Rollback para tag $TAG_PRE"
      run_liquibase "$PROPS" "$URL" rollbackToTag "$TAG_PRE" || true
    else
      echo ">>> RollbackCount 1"
      run_liquibase "$PROPS" "$URL" rollbackCount 1 || true
    fi
    exit 1
  fi

  echo "===== [$ENV_NAME] HISTORY ====="
  run_liquibase "$PROPS" "$URL" history || true
}

# ===================== Contexto + URL =====================
if echo "$JDBC_URL" | grep -Eqi '\.internal|RENDER_DEFAULT_DB'; then
  echo "::error::URL interna detectada. Use a EXTERNAL URL do Render (pooler) com sslmode=require."
  exit 2
fi

to_jdbc_and_creds "$JDBC_URL"

echo "### Contexto"
echo "ENV: $ENV_ARG"
echo "MODE: $MODE"
echo "TAG_PRE: ${TAG_PRE:-<none>}"
echo "JDBC_URL (masc.):  $(mask_url "$JDBC_URL")"
echo "JDBC efetiva (masc.): $(mask_url "$JDBC_URL_NOAUTH")"
echo

case "$ENV_ARG" in
  DEV)  promote "DEV"  "liquibase-dev.properties"  "$JDBC_URL_NOAUTH" ;;
  TEST) promote "TEST" "liquibase-test.properties" "$JDBC_URL_NOAUTH" ;;
  PROD) promote "PROD" "liquibase-prod.properties" "$JDBC_URL_NOAUTH" ;;
  *) echo "Ambiente inválido: $ENV_ARG"; exit 2 ;;
esac

echo "✓ Fim do $ENV_ARG ($MODE)"
