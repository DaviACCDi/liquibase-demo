#!/usr/bin/env bash
set -euo pipefail

LB_DIR="${LB_DIR:-liquibase}"
WORKDIR="${GITHUB_WORKSPACE:-$PWD}"
DEPLOYER="${GITHUB_ACTOR:-ci-runner}"

ENV_ARG="${1:-}"
if [[ -z "${ENV_ARG}" ]]; then
  echo "Uso: $0 <DEV|TEST|PROD>"
  exit 2
fi

if [[ -z "${JDBC_URL:-}" ]]; then
  echo "ERRO: JDBC_URL não encontrada no ambiente. Defina-a no Environment do GitHub (dev/test/prod)."
  exit 2
fi

# Converte postgres://user:pass@host:port/db?x=y -> jdbc:postgresql://host:port/db?x=y&user=user&password=pass
to_jdbc () {
  local RURL="$1"
  if [[ "$RURL" =~ ^postgres(ql)?:// ]]; then
    local REST="${RURL#postgres*://}"           # user:pass@host:port/db?query
    local CREDS="${REST%%@*}"                   # user:pass
    local HOSTPORT_DBQ="${REST#*@}"             # host:port/db?query
    local HOSTPORT="${HOSTPORT_DBQ%%/*}"        # host:port
    local DBQ="${HOSTPORT_DBQ#*/}"              # db?query
    local USER="${CREDS%%:*}"
    local PASS="${CREDS#*:}"
    local HOST="${HOSTPORT%%:*}"
    local PORT="${HOSTPORT#*:}"; [[ "$PORT" == "$HOST" ]] && PORT="5432"
    local DB="${DBQ%%\?*}"
    local QUERY=""; [[ "$DBQ" == *\?* ]] && QUERY="${DBQ#*?}"
    [[ -z "$QUERY" ]] && QUERY="sslmode=require"
    echo "jdbc:postgresql://${HOST}:${PORT}/${DB}?${QUERY}&user=${USER}&password=${PASS}"
  else
    echo "$RURL"
  fi
}

URL_EFETIVA="$(to_jdbc "$JDBC_URL")"

run_liquibase () {
  local PROPS="$1"; local URL="$2"; local WHAT="$3"
  echo "+ liquibase $WHAT (props=$PROPS)"
  # sanity (dentro do container)
  docker run --rm --network host -w /workspace \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    bash -lc 'echo "[container] /workspace:"; ls -la /workspace; ls -la /workspace/changelogs || true'

  docker run --rm --network host -w /workspace \
    -e "JAVA_OPTS=-Ddeployer=${DEPLOYER}" \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    --defaultsFile="/workspace/conf/$PROPS" \
    --url="$URL" \
    $WHAT
}

promote () {
  local ENV_NAME="$1"; local PROPS="$2"; local URL="$3"

  echo "===== [$ENV_NAME] VALIDATE ====="
  run_liquibase "$PROPS" "$URL" validate

  echo "===== [$ENV_NAME] DRY-RUN (updateSQL) ====="
  if ! run_liquibase "$PROPS" "$URL" updateSQL > "plan_${ENV_NAME}.sql"; then
    echo "!!! updateSQL retornou erro (continuando para fins de log)."
  fi
  echo "----- Últimas 50 linhas de plan_${ENV_NAME}.sql -----"
  tail -n 50 "plan_${ENV_NAME}.sql" || true
  echo "-----------------------------------------------------"

  echo "===== [$ENV_NAME] UPDATE ====="
  if ! run_liquibase "$PROPS" "$URL" update; then
    echo "!!! Falhou em $ENV_NAME → rollbackCount 1"
    run_liquibase "$PROPS" "$URL" rollbackCount 1 || true
    exit 1
  fi

  echo "===== [$ENV_NAME] HISTORY ====="
  run_liquibase "$PROPS" "$URL" history || true
}

echo "### Contexto do Runner"
echo "Actor/Deployer: $DEPLOYER"
echo "ENV alvo: $ENV_ARG"
echo "JDBC_URL (entrada, mascarada):"
echo "$JDBC_URL" | sed -E 's#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/(password=)[^&]+/\1****/'
echo "URL efetiva p/ JDBC (mascarada):"
echo "$URL_EFETIVA" | sed -E 's#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/(password=)[^&]+/\1****/'
echo

case "$ENV_ARG" in
  DEV)  promote "DEV"  "liquibase-dev.properties"  "$URL_EFETIVA" ;;
  TEST) promote "TEST" "liquibase-test.properties" "$URL_EFETIVA" ;;
  PROD) promote "PROD" "liquibase-prod.properties" "$URL_EFETIVA" ;;
  *)    echo "Ambiente inválido: $ENV_ARG (use DEV|TEST|PROD)"; exit 2 ;;
esac

echo "✓ Fim do $ENV_ARG"
