-- liquibase formatted sql
-- changeset ${deployer}:20250930-1130 context:refdata labels:customer
-- comment: Referência mínima para status de customer (documental)
-- Mantém um registro-sentinela apenas para validar presença do status "active".
INSERT INTO app_core.customer (name, email, status)
VALUES ('__REFDATA__', 'ref@dummy.local', 'active')
ON CONFLICT DO NOTHING;
-- rollback DELETE FROM app_core.customer WHERE name='__REFDATA__' AND email='ref@dummy.local';