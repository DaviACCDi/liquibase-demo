#!/usr/bin/env bash
set -euo pipefail

LB_DIR="${LB_DIR:-liquibase}"
WORKDIR="${GITHUB_WORKSPACE:-$PWD}"
DEPLOYER="${GITHUB_ACTOR:-ci-runner}"
ENV_ARG="${1:-}"
MODE="${MODE:-apply}"     # apply | plan

if [[ -z "${ENV_ARG}" ]]; then
  echo "Uso: $0 <DEV|TEST|PROD>"
  exit 2
fi

# ===== URL do ambiente (obrigatória) =====
if [[ -z "${JDBC_URL:-}" ]]; then
  echo "::error::JDBC_URL não encontrada no Environment do GitHub (dev/test/prod)."
  exit 2
fi

# ===== Parse seguro da URL (postgresql://user:pass@host[:port]/db?query) =====
DB_USER=""; DB_PASS=""; DB_HOST=""; DB_PORT="5432"; DB_NAME=""; DB_QUERY=""
JDBC_URL_NOAUTH=""

parse_pg_url() {
  local RURL="$1"

  if [[ "$RURL" =~ ^postgres(ql)?:// ]]; then
    local REST="${RURL#postgres*://}"         # user:pass@host:port/db?query
    # exige credenciais (para não precisar por na query)
    if [[ "$REST" != *"@"* ]]; then
      echo "::error::URL sem credenciais: esperava postgresql://user:pass@host/db"; exit 2
    fi
    local CREDS="${REST%%@*}"                 # user:pass
    local HOSTPORT_DBQ="${REST#*@}"           # host:port/db?query
    local HOSTPORT="${HOSTPORT_DBQ%%/*}"      # host:port
    local DBQ="${HOSTPORT_DBQ#*/}"            # db?query (ou vazio)

    DB_USER="${CREDS%%:*}"
    DB_PASS="${CREDS#*:}"

    DB_HOST="${HOSTPORT%%:*}"
    local PORT_PART="${HOSTPORT#*:}"
    [[ "$PORT_PART" != "$HOSTPORT" ]] && DB_PORT="$PORT_PART" || DB_PORT="5432"

    DB_NAME="${DBQ%%\?*}"
    [[ "$DBQ" == *\?* ]] && DB_QUERY="${DBQ#*?}" || DB_QUERY=""

    # limpa user/password da query e garante sslmode=require
    local out_q=""; local have_ssl="0"
    if [[ -n "$DB_QUERY" ]]; then
      IFS='&' read -r -a parts <<<"$DB_QUERY"
      for kv in "${parts[@]}"; do
        [[ -z "$kv" ]] && continue
        case "$kv" in
          user=*|password=*) ;;               # ignora credenciais na query
          sslmode=*) have_ssl="1"; out_q="${out_q:+$out_q&}$kv" ;;
          *) out_q="${out_q:+$out_q&}$kv" ;;
        esac
      done
    fi
    [[ "$have_ssl" == "0" ]] && out_q="${out_q:+$out_q&}sslmode=require"

    JDBC_URL_NOAUTH="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}?${out_q}"
  else
    echo "::error::A secret JDBC_URL deve ser a EXTERNAL URL do Render, no formato postgresql://user:pass@host/db"
    exit 2
  fi
}

parse_pg_url "$JDBC_URL"

# ===== util =====
mask() {
  # mascara host/db e senha
  local s="$1"
  echo "$s" \
    | sed -E 's#//([^:@/]+):[^@/]+@#//\1:****@#; s#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/(password=)[^&]+/\1****/g'
}

log_ctx() {
  echo "### Contexto"
  echo "ENV: $ENV_ARG"
  echo "MODE: $MODE"
  echo "Actor: $DEPLOYER"
  echo "Workspace: $WORKDIR"
  echo "LB_DIR: $LB_DIR"
  echo "JDBC_URL (entrada, mascarada): $(mask "$JDBC_URL")"
  echo "JDBC_URL efetiva (sem auth, mascarada): $(mask "$JDBC_URL_NOAUTH")"
  echo "Host/Port/DB (masc): $(mask "jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}")"
}

tcp_probe() {
  echo "[tcp] testando ${DB_HOST}:${DB_PORT} ..."
  docker run --rm --network host bash:5 bash -lc "timeout 5 bash -c '</dev/tcp/${DB_HOST}/${DB_PORT}'" \
    && echo "[tcp] OK" || { echo "::error::[tcp] Falha ao abrir TCP em ${DB_HOST}:${DB_PORT}"; exit 3; }
}

run_liquibase() {
  local PROPS="$1"; local WHAT="$2"
  echo "+ liquibase $WHAT (props=$PROPS)"
  # lista conteúdo (debug)
  docker run --rm --network host -w /workspace \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    bash -lc 'echo "[container] /workspace:"; ls -la /workspace; ls -la /workspace/changelogs || true'

  # executa
  docker run --rm --network host -w /workspace \
    -e "JAVA_OPTS=-Ddeployer=${DEPLOYER}" \
    -v "$WORKDIR/$LB_DIR:/workspace" liquibase/liquibase \
    --defaultsFile="/workspace/conf/$PROPS" \
    --log-level=info \
    --url="$JDBC_URL_NOAUTH" \
    --username="$DB_USER" \
    --password="$DB_PASS" \
    $WHAT
}

promote() {
  local ENV_NAME="$1"; local PROPS="$2"

  echo "===== [$ENV_NAME] VALIDATE ====="
  run_liquibase "$PROPS" validate

  echo "===== [$ENV_NAME] STATUS ====="
  run_liquibase "$PROPS" status --verbose || true

  if [[ "$MODE" == "plan" ]]; then
    echo "===== [$ENV_NAME] DRY-RUN (updateSQL) ====="
    if ! run_liquibase "$PROPS" updateSQL > "plan_${ENV_NAME}.sql"; then
      echo "!!! updateSQL retornou erro (mantendo logs)."
    fi
    tail -n 60 "plan_${ENV_NAME}.sql" || true
    return 0
  fi

  # tag de restauração opcional
  if [[ -n "${TAG_PRE:-}" ]]; then
    echo "===== [$ENV_NAME] TAG_PRE ====="
    run_liquibase "$PROPS" tag "$TAG_PRE" || true
  fi

  echo "===== [$ENV_NAME] DRY-RUN (updateSQL) ====="
  run_liquibase "$PROPS" updateSQL > "plan_${ENV_NAME}.sql" || true
  tail -n 60 "plan_${ENV_NAME}.sql" || true

  echo "===== [$ENV_NAME] UPDATE ====="
  if ! run_liquibase "$PROPS" update; then
    echo "!!! Falhou em $ENV_NAME"
    if [[ -n "${TAG_PRE:-}" ]]; then
      echo ">>> Rollback para tag $TAG_PRE"
      run_liquibase "$PROPS" rollbackToTag "$TAG_PRE" || true
    else
      echo ">>> Rollback de 1 changeset"
      run_liquibase "$PROPS" rollbackCount 1 || true
    fi
    exit 1
  fi

  echo "===== [$ENV_NAME] HISTORY ====="
  run_liquibase "$PROPS" history || true
}

# ===== Logs iniciais e sanity =====
log_ctx
echo
echo "Sanity dos arquivos:"
test -f "$WORKDIR/$LB_DIR/changelogs/db.changelog-master.xml" || { echo "::error::master changelog ausente"; exit 2; }
for f in "$WORKDIR/$LB_DIR"/conf/*.properties; do
  echo "---- $f ----"
  sed -n '1,120p' "$f" | sed 's/^password=.*/password=****/' || true
done
echo

# teste de rede (explicita erro antes do Java)
tcp_probe

# ===== despacha por ambiente =====
case "$ENV_ARG" in
  DEV)  promote "DEV"  "liquibase-dev.properties"  ;;
  TEST) promote "TEST" "liquibase-test.properties" ;;
  PROD) promote "PROD" "liquibase-prod.properties" ;;
  *)    echo "Ambiente inválido: $ENV_ARG (use DEV|TEST|PROD)"; exit 2 ;;
esac

echo "✓ Fim do $ENV_ARG ($MODE)"
