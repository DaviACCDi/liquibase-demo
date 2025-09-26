#!/usr/bin/env bash
set -euo pipefail

LB_DIR="${LB_DIR:-liquibase}"
WORKDIR="${GITHUB_WORKSPACE:-$PWD}"
DEPLOYER="${GITHUB_ACTOR:-ci-runner}"
LIQUIBASE_LOG_LEVEL="${LIQUIBASE_LOG_LEVEL:-info}"

ENV_ARG="${1:-}"; [[ -z "$ENV_ARG" ]] && { echo "Uso: $0 <DEV|TEST|PROD>"; exit 2; }
[[ -z "${JDBC_URL:-}" ]] && { echo "::error::JDBC_URL não encontrada no Environment"; exit 2; }

mask_url() {
  sed -E 's#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/([?&]password=)[^&]+/\1****/; s#//([^:@/]+):[^@/]+@#//\1:****@#' <<<"$1"
}

# Variáveis globais preenchidas pelo parser
DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT="5432"; DB_NAME=""; DB_QUERY=""
JDBC_URL_NOAUTH=""

parse_pg_url() {
  local RURL="$1"
  # aceita postgres:// ou postgresql://
  local REST="${RURL#postgres*://}"           # user:pass@host:port/db?query
  local CREDS="${REST%%@*}"                   # user:pass
  local HOSTPORT_DBQ="${REST#*@}"             # host:port/db?query
  local HOSTPORT="${HOSTPORT_DBQ%%/*}"        # host:port
  local DBQ="${HOSTPORT_DBQ#*/}"              # db?query

  DB_USER="${CREDS%%:*}"
  DB_PASS="${CREDS#*:}"
  DB_HOST="${HOSTPORT%%:*}"
  local PORT_PART="${HOSTPORT#*:}"
  [[ "$PORT_PART" != "$HOSTPORT" ]] && DB_PORT="$PORT_PART" || DB_PORT="5432"

  DB_NAME="${DBQ%%\?*}"
  DB_QUERY=""
  [[ "$DBQ" == *\?* ]] && DB_QUERY="${DBQ#*?}"

  # garante sslmode=require
  if [[ -z "$DB_QUERY" ]]; then
    DB_QUERY="sslmode=require"
  elif [[ ! "$DB_QUERY" =~ (^|&)sslmode= ]]; then
    DB_QUERY="${DB_QUERY}&sslmode=require"
  fi

  JDBC_URL_NOAUTH="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}?${DB_QUERY}"
}

to_jdbc_and_creds() {
  local RURL="$1"
  if [[ "$RURL" =~ ^postgres(ql)?:// ]]; then
    parse_pg_url "$RURL"
    echo "$JDBC_URL_NOAUTH"
  elif [[ "$RURL" =~ ^jdbc:postgresql:// ]]; then
    # já é JDBC; extrair user/pass de query se existirem
    JDBC_URL_NOAUTH="$RURL"
    if [[ "$RURL" =~ [\?&]user=([^&]+) ]]; then DB_USER="${BASH_REMATCH[1]}"; fi
    if [[ "$RURL" =~ [\?&]password=([^&]+) ]]; then DB_PASS="${BASH_REMATCH[1]}"; fi
    echo "$JDBC_URL_NOAUTH"
  else
    echo "::error::Formato de URL não reconhecido: $(mask_url "$RURL")" >&2
    return 1
  fi
}

run_liquibase () {
  local PROPS="$1"; local URL="$2"; local WHAT="$3"
  echo "+ liquibase $WHAT"
  echo "  - props: /workspace/conf/$PROPS"
  echo "  - url:   $(mask_url "$URL")"
  echo "  - user:  ${DB_USER:+****}  (pass oculto)"

  # listar conteúdo útil
  docker run --rm --network host -w /workspace \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    bash -lc 'echo "[container] /workspace"; ls -la /workspace; echo "[container] /workspace/conf"; ls -la /workspace/conf; echo "[container] /workspace/changelogs"; ls -la /workspace/changelogs'

  # executar
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

  echo "===== [$ENV_NAME] VALIDATE ====="
  run_liquibase "$PROPS" "$URL" validate

  echo "===== [$ENV_NAME] STATUS ====="
  run_liquibase "$PROPS" "$URL" status --verbose || true

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

# ========= Contexto + URL =========
URL_EFETIVA="$(to_jdbc_and_creds "$JDBC_URL")" || exit 2

echo "### Contexto"
echo "ENV: $ENV_ARG"
echo "TAG_PRE: ${TAG_PRE:-<none>}"
echo "JDBC_URL (bruto, mascarada): $(mask_url "$JDBC_URL")"
echo "JDBC (sem auth, mascarada):  $(mask_url "$URL_EFETIVA")"

case "$ENV_ARG" in
  DEV)  promote "DEV"  "liquibase-dev.properties"  "$URL_EFETIVA" ;;
  TEST) promote "TEST" "liquibase-test.properties" "$URL_EFETIVA" ;;
  PROD) promote "PROD" "liquibase-prod.properties" "$URL_EFETIVA" ;;
  *) echo "Ambiente inválido: $ENV_ARG"; exit 2 ;;
esac

echo "✓ Fim do $ENV_ARG"
