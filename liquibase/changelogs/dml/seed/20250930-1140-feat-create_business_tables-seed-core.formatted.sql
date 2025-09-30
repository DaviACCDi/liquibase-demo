-- liquibase formatted sql
-- changeset ${deployer}:20250930-1140 context:seed labels:core
-- comment: Dados mínimos para subir a aplicação


-- Customers
INSERT INTO app_core.customer (name, email, status) VALUES
('Acme Corp','contact@acme.io','active'),
('Umbrella Inc','ops@umbrella.io','active');
-- rollback DELETE FROM app_core.customer WHERE email IN ('contact@acme.io','ops@umbrella.io');


-- Products
INSERT INTO app_core.product (sku, name, price) VALUES
('SKU-001','USB-C Cable',9.90),
('SKU-002','Wireless Mouse',24.50);
-- rollback DELETE FROM app_core.product WHERE sku IN ('SKU-001','SKU-002');