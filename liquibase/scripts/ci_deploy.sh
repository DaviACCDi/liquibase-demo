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

# ===== Logs de contexto (debug) =====
echo "### Contexto do Runner"
echo "Actor/Deployer: $DEPLOYER"
echo "Workspace: $WORKDIR"
echo "LB_DIR: $LB_DIR"
echo "ENV alvo: $ENV_ARG"
echo "JDBC_URL (host/db mascarados):"
echo "$JDBC_URL" | sed -E 's#(//)[^:/]+(:[0-9]+)?/[^?]+#\1***:****/***#; s/(password=)[^&]+/\1****/'

docker --version || true
docker info --format '{{json .ServerVersion}}' 2>/dev/null || docker info || true
echo
echo "Arquivos Liquibase relevantes:"
ls -la "$WORKDIR/$LB_DIR" || true
ls -la "$WORKDIR/$LB_DIR/conf" || true
ls -la "$WORKDIR/$LB_DIR/changelogs" || true

echo
echo "Sanity check dos changelogs:"
test -f "$WORKDIR/$LB_DIR/changelogs/db.changelog-master.xml" || { echo "Master não encontrado"; exit 2; }

echo
echo "Preview de properties:"
for f in "$WORKDIR/$LB_DIR"/conf/*.properties; do
  echo "---- $f ----"
  sed -n '1,100p' "$f" | sed 's/^password=.*/password=****/' || true
done
echo

# ===== Dispatch por ambiente (todos usam JDBC_URL do environment) =====
case "$ENV_ARG" in
  DEV)  promote "DEV"  "liquibase-dev.properties"  "$JDBC_URL" ;;
  TEST) promote "TEST" "liquibase-test.properties" "$JDBC_URL" ;;
  PROD) promote "PROD" "liquibase-prod.properties" "$JDBC_URL" ;;
  *)    echo "Ambiente inválido: $ENV_ARG (use DEV|TEST|PROD)"; exit 2 ;;
esac

echo "✓ Fim do $ENV_ARG"
