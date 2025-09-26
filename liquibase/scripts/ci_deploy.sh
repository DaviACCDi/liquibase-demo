#!/usr/bin/env bash
set -euo pipefail

# ===== Variáveis de contexto =====
LB_DIR="${LB_DIR:-liquibase}"
WORKDIR="${GITHUB_WORKSPACE:-$PWD}"
DEPLOYER="${GITHUB_ACTOR:-ci-runner}"

ENV_ARG="${1:-}"
if [[ -z "${ENV_ARG}" ]]; then
  echo "Uso: $0 <DEV|TEST|PROD>"
  exit 2
fi

# URLs (services do workflow; em prod/test reais, ajuste aqui ou via env)
DEV_URL="${DEV_URL:-jdbc:postgresql://127.0.0.1:5432/appdb_dev}"
TEST_URL="${TEST_URL:-jdbc:postgresql://127.0.0.1:5433/appdb_test}"
PROD_URL="${PROD_URL:-jdbc:postgresql://127.0.0.1:5434/appdb_prod}"

# ===== Helpers =====
run_liquibase () {
  local PROPS="$1"; local URL="$2"; local WHAT="$3"
  echo "+ liquibase $WHAT (props=$PROPS url=$URL)"
  docker run --rm --network host \
    -w /workspace \
    -e "JAVA_OPTS=-Ddeployer=${DEPLOYER}" \
    -v "$WORKDIR/$LB_DIR:/workspace" \
    liquibase/liquibase \
    --defaultsFile="/workspace/conf/$PROPS" \
    --url="$URL" \
    --searchPath="/workspace" \
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

# ===== Logs de contexto (debug) =====
echo "### Contexto do Runner"
echo "Actor/Deployer: $DEPLOYER"
echo "Workspace: $WORKDIR"
echo "LB_DIR: $LB_DIR"
echo "ENV alvo: $ENV_ARG"
docker --version || true
echo
docker info --format '{{json .ServerVersion}}' 2>/dev/null || docker info || true
echo
echo "Diretórios no workspace:"
ls -la "$WORKDIR" || true
echo
echo "Arquivos Liquibase relevantes:"
ls -la "$WORKDIR/$LB_DIR" || true
ls -la "$WORKDIR/$LB_DIR/conf" || true
ls -la "$WORKDIR/$LB_DIR/changelogs" || true

echo
echo "Sanity check dos changelogs:"
test -f "$WORKDIR/$LB_DIR/changelogs/db.changelog-master.xml" || { echo "Master não encontrado"; exit 2; }
test -f "$WORKDIR/$LB_DIR/changelogs/changes/person.xml" || { echo "person.xml não encontrado"; exit 2; }

echo
echo "Preview de properties (até 100 linhas por arquivo):"
for f in "$WORKDIR/$LB_DIR"/conf/*.properties; do
  echo "---- $f ----"
  # mascara password no log
  sed -n '1,100p' "$f" | sed 's/^password=.*/password=****/' || true
done

echo
echo "Preview do master changelog:"
sed -n '1,200p' "$WORKDIR/$LB_DIR/changelogs/db.changelog-master.xml" || true
echo

# ===== Dispatch por ambiente =====
case "$ENV_ARG" in
  DEV)
    promote "DEV" "liquibase-dev.properties" "$DEV_URL"
    ;;
  TEST)
    promote "TEST" "liquibase-test.properties" "$TEST_URL"
    ;;
  PROD)
    promote "PROD" "liquibase-prod.properties" "$PROD_URL"
    ;;
  *)
    echo "Ambiente inválido: $ENV_ARG (use DEV|TEST|PROD)"
    exit 2
    ;;
esac

echo "✓ Fim do $ENV_ARG"
