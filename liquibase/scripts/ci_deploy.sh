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

# URL do ambiente (vem do Environment dev/test/prod)
if [[ -z "${JDBC_URL:-}" ]]; then
  echo "ERRO: JDBC_URL não encontrada no ambiente."
  exit 2
fi

# Conversor postgres:// -> jdbc:postgresql:// (mantém se já for jdbc:)
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
TAG_PRE="${TAG_PRE:-}"   # se definido, tag usado para rollback exato

run_liquibase () {
  local PROPS="$1"; local URL="$2"; local WHAT="$3"
  echo "+ liquibase $WHAT (props=$PROPS)"
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

  echo "===== [$ENV_NAME] STATUS ====="
  run_liquibase "$PROPS" "$URL" status --verbose || true

  # Marca ponto de restauração antes do update (se solicitado)
  if [[ -n "$TAG_PRE" ]]; then
    echo "===== [$ENV_NAME] TAG PRE ====="
    run_liquibase "$PROPS" "$URL" tag "$TAG_PRE" || true
  fi

  echo "===== [$ENV_NAME] DRY-RUN (updateSQL) ====="
  if ! run_liquibase "$PROPS" "$URL" updateSQL > "plan_${ENV_NAME}.sql"; then
    echo "!!! updateSQL retornou erro (continuando para log)."
  fi
  tail -n 50 "plan_${ENV_NAME}.sql" || true

  echo "===== [$ENV_NAME] UPDATE ====="
  if ! run_liquibase "$PROPS" "$URL" update; then
    echo "!!! Falhou em $ENV_NAME"
    if [[ -n "$TAG_PRE" ]]; then
      echo ">>> Rollback para tag $TAG_PRE"
      run_liquibase "$PROPS" "$URL" rollbackToTag "$TAG_PRE" || true
    else
      echo ">>> Rollback de 1 changeset"
      run_liquibase "$PROPS" "$URL" rollbackCount 1 || true
    fi
    exit 1
  fi

  echo "===== [$ENV_NAME] HISTORY ====="
  run_liquibase "$PROPS" "$URL" history || true
}

echo "### Contexto"
echo "ENV: $ENV_ARG"
echo "TAG_PRE: ${TAG_PRE:-<none>}"
echo "JDBC_URL (mascarada):"
echo "$URL_EFETIVA" | sed -E 's#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/(password=)[^&]+/\1****/'

case "$ENV_ARG" in
  DEV)  promote "DEV"  "liquibase-dev.properties"  "$URL_EFETIVA" ;;
  TEST) promote "TEST" "liquibase-test.properties" "$URL_EFETIVA" ;;
  PROD) promote "PROD" "liquibase-prod.properties" "$URL_EFETIVA" ;;
  *)    echo "Ambiente inválido: $ENV_ARG"; exit 2 ;;
esac

echo "✓ Fim do $ENV_ARG"
