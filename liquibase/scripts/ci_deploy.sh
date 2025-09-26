#!/usr/bin/env bash
set -euo pipefail

# vai aparecer no author dos changeSets como quem aplicou
DEPLOYER="${GITHUB_ACTOR:-ci-runner}"

run_liquibase () {
  local PROPS="$1"; local URL="$2"; local WHAT="$3"

  docker run --rm --network host \
    -e LIQUIBASE_PARAMETER_deployer="$DEPLOYER" \
    -v "$GITHUB_WORKSPACE/liquibase:/workspace" \
    liquibase/liquibase \
    --defaultsFile="/workspace/conf/$PROPS" \
    --url="$URL" \
    $WHAT
}


promote () {
  local ENV_NAME="$1"
  local PROPS="$2"
  local URL="$3"

  echo "===== [$ENV_NAME] VALIDATE"
  run_liquibase "$PROPS" "$URL" validate

  echo "===== [$ENV_NAME] UPDATE SQL (dry-run)"
  run_liquibase "$PROPS" "$URL" updateSQL > "plan_${ENV_NAME}.sql" || true
  tail -n 30 "plan_${ENV_NAME}.sql" || true

  echo "===== [$ENV_NAME] UPDATE (aplicar)"
  if ! run_liquibase "$PROPS" "$URL" update; then
    echo "!!! Falhou em $ENV_NAME. Executando rollbackCount 1"
    run_liquibase "$PROPS" "$URL" rollbackCount 1 || true
    exit 1
  fi

  echo "===== [$ENV_NAME] HISTORY"
  run_liquibase "$PROPS" "$URL" history || true
}

# URLs para os services do Actions (localhost + portas distintas)
DEV_URL="jdbc:postgresql://127.0.0.1:5432/appdb_dev"
TEST_URL="jdbc:postgresql://127.0.0.1:5433/appdb_test"
PROD_URL="jdbc:postgresql://127.0.0.1:5434/appdb_prod"

promote "DEV"  "liquibase-dev.properties"  "$DEV_URL"
promote "TEST" "liquibase-test.properties" "$TEST_URL"

# gate de aprovação manual do próprio Actions (via environments) é configurado no passo do workflow
promote "PROD" "liquibase-prod.properties" "$PROD_URL"
