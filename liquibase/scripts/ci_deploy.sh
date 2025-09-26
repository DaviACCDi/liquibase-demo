#!/usr/bin/env bash
set -euo pipefail

# ===================== Config & helpers =====================
LB_DIR="${LB_DIR:-liquibase}"
WORKDIR="${GITHUB_WORKSPACE:-$PWD}"
DEPLOYER="${GITHUB_ACTOR:-ci-runner}"
LIQUIBASE_LOG_LEVEL="${LIQUIBASE_LOG_LEVEL:-info}"  # ajuste se quiser: info|debug|trace

ENV_ARG="${1:-}"
if [[ -z "$ENV_ARG" ]]; then
  echo "Uso: $0 <DEV|TEST|PROD>"
  exit 2
fi

# Secret obrigatório
if [[ -z "${JDBC_URL:-}" ]]; then
  echo "::error::JDBC_URL não encontrada no Environment. Configure o secret JDBC_URL no environment correspondente."
  exit 2
fi

# Mask de URLs para log (esconde user/pass/host/db)
mask_url() {
  # esconde user:pass@host:port/db  e password=... em query
  sed -E 's#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/(password=)[^&]+/\1****/' <<<"$1"
}

# Conversor postgres:// -> jdbc:postgresql:// (mantém se já for jdbc:)
to_jdbc () {
  local RURL="$1"
  if [[ "$RURL" =~ ^postgres(ql)?:// ]]; then
    # Ex.: postgres://user:pass@host:5432/db?sslmode=require
    local REST="${RURL#postgres*://}"       # user:pass@host:port/db?query
    local CREDS="${REST%%@*}"               # user:pass
    local HOSTPORT_DBQ="${REST#*@}"         # host:port/db?query
    local HOSTPORT="${HOSTPORT_DBQ%%/*}"    # host:port
    local DBQ="${HOSTPORT_DBQ#*/}"          # db?query
    local USER="${CREDS%%:*}"
    local PASS="${CREDS#*:}"
    local HOST="${HOSTPORT%%:*}"
    local PORT="${HOSTPORT#*:}"; [[ "$PORT" == "$HOST" ]] && PORT="5432"
    local DB="${DBQ%%\?*}"
    local QUERY=""; [[ "$DBQ" == *\?* ]] && QUERY="${DBQ#*?}"

    # QUERY padrão garante sslmode se não vier nada
    [[ -z "$QUERY" ]] && QUERY="sslmode=require"

    # Monta query final adicionando user/password no fim
    # (se já existirem user/password na query, não duplica)
    local SEP="&"; [[ -z "$QUERY" ]] && SEP=""
    if [[ "$QUERY" != *"user="* ]]; then QUERY="${QUERY}${SEP}user=${USER}"; SEP="&"; fi
    if [[ "$QUERY" != *"password="* ]]; then QUERY="${QUERY}${SEP}password=${PASS}"; fi

    echo "jdbc:postgresql://${HOST}:${PORT}/${DB}?${QUERY}"
  else
    echo "$RURL"
  fi
}

# Verificações de sanidade da URL
if echo "$JDBC_URL" | grep -Eqi '\.internal|\.svc|RENDER_DEFAULT_DB'; then
  echo "::error::A URL parece ser INTERNA do provider (ex.: *.internal) ou DEFAULT. Use a EXTERNAL URL (a mesma que funciona no DBeaver)."
  exit 2
fi

URL_EFETIVA="$(to_jdbc "$JDBC_URL")"

if [[ ! "$URL_EFETIVA" =~ ^jdbc:postgresql:// ]]; then
  echo "::error::URL efetiva não é JDBC PostgreSQL válida: $(mask_url "$URL_EFETIVA")"
  exit 2
fi

# ===================== Funções Liquibase =====================
run_liquibase () {
  local PROPS="$1"; local URL="$2"; local WHAT="$3"

  echo "+ liquibase $WHAT (props=$PROPS)"
  echo "  - defaultsFile: /workspace/conf/$PROPS"
  echo "  - url:          $(mask_url "$URL")"
  echo "  - log-level:    $LIQUIBASE_LOG_LEVEL"

  # Sanity: conteúdo montado no container
  docker run --rm --network host -w /workspace \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    bash -lc 'echo "[container] /workspace:"; ls -la /workspace; echo "[container] /workspace/changelogs:"; ls -la /workspace/changelogs || true; echo "[container] /workspace/conf:"; ls -la /workspace/conf || true'

  # Execução
  docker run --rm --network host -w /workspace \
    -e "JAVA_OPTS=-Ddeployer=${DEPLOYER}" \
    -e "LIQUIBASE_LOG_LEVEL=${LIQUIBASE_LOG_LEVEL}" \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    --defaultsFile="/workspace/conf/$PROPS" \
    --log-level="${LIQUIBASE_LOG_LEVEL}" \
    --url="$URL" \
    $WHAT
}

promote () {
  local ENV_NAME="$1"; local PROPS="$2"; local URL="$3"

  # Confirma existência do arquivo de props
  if [[ ! -f "$WORKDIR/$LB_DIR/conf/$PROPS" ]]; then
    echo "::error::Arquivo de propriedades não encontrado: $WORKDIR/$LB_DIR/conf/$PROPS"
    exit 2
  fi

  echo "===== [$ENV_NAME] VALIDATE ====="
  run_liquibase "$PROPS" "$URL" validate

  echo "===== [$ENV_NAME] STATUS ====="
  run_liquibase "$PROPS" "$URL" status --verbose || true

  # Marca ponto de restauração antes do update (se solicitado)
  if [[ -n "${TAG_PRE:-}" ]]; then
    echo "===== [$ENV_NAME] TAG PRE ====="
    run_liquibase "$PROPS" "$URL" tag "$TAG_PRE" || true
  fi

  echo "===== [$ENV_NAME] DRY-RUN (updateSQL) ====="
  if ! run_liquibase "$PROPS" "$URL" updateSQL > "plan_${ENV_NAME}.sql"; then
    echo "!!! updateSQL retornou erro (continuando para log)."
  fi
  echo "----- Últimas linhas de plan_${ENV_NAME}.sql -----"
  tail -n 80 "plan_${ENV_NAME}.sql" || true
  echo "--------------------------------------------------"

  echo "===== [$ENV_NAME] UPDATE ====="
  if ! run_liquibase "$PROPS" "$URL" update; then
    echo "!!! UPDATE falhou em $ENV_NAME"
    if [[ -n "${TAG_PRE:-}" ]]; then
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

# ===================== Contexto =====================
echo "### Contexto"
echo "ENV: $ENV_ARG"
echo "TAG_PRE: ${TAG_PRE:-<none>}"
echo "JDBC_URL bruto (mascarada): $(mask_url "$JDBC_URL")"
echo "URL_EFETIVA JDBC (mascarada): $(mask_url "$URL_EFETIVA")"

# ===================== Dispatch =====================
case "$ENV_ARG" in
  DEV)  promote "DEV"  "liquibase-dev.properties"  "$URL_EFETIVA" ;;
  TEST) promote "TEST" "liquibase-test.properties" "$URL_EFETIVA" ;;
  PROD) promote "PROD" "liquibase-prod.properties" "$URL_EFETIVA" ;;
  *)    echo "Ambiente inválido: $ENV_ARG (use DEV|TEST|PROD)"; exit 2 ;;
esac

echo "✓ Fim do $ENV_ARG"
