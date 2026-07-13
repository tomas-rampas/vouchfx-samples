-- migrations/from-specflow/ported/fixtures/reset-sku.sql
--
-- Applied by environment.seed AFTER the topology (including orders-api's own health gate,
-- which only turns green once its DatabaseInitializer has run CREATE TABLE IF NOT EXISTS
-- orders — see samples/orders-dotnet/app/DatabaseInitializer.cs) is healthy, and BEFORE
-- step 1 runs. This is the declarative equivalent of the source project's
-- [BeforeScenario] hook (PlaceOrderSteps.ResetFixturesAsync), which hand-rolls the same
-- DELETE to satisfy the feature file's Background: "the orders service has no existing
-- order for sku ...".
DELETE FROM orders WHERE sku = 'WIDGET-SPEC-1';
