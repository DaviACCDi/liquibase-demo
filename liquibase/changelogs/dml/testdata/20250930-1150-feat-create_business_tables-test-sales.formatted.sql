-- liquibase formatted sql
-- changeset ${deployer}:20250930-1150 context:testdata labels:sales
-- comment: Gera uma venda de teste referenciando seeds


WITH c AS (
SELECT id FROM app_core.customer WHERE email='contact@acme.io' LIMIT 1
), p AS (
SELECT id, price FROM app_core.product WHERE sku='SKU-001' LIMIT 1
)
INSERT INTO app_core.sales (customer_id, product_id, quantity, unit_price, total)
SELECT c.id, p.id, 3, p.price, 3 * p.price FROM c, p;


-- rollback
DELETE FROM app_core.sales s
USING app_core.customer c, app_core.product p
WHERE s.customer_id=c.id AND c.email='contact@acme.io'
AND s.product_id=p.id AND p.sku='SKU-001';