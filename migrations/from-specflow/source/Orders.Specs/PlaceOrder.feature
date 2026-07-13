Feature: Place order
  As a customer
  I want to place an order for a product
  So that I receive a confirmation and downstream systems are notified

Background:
  Given the orders service has no existing order for sku "WIDGET-SPEC-1"

Scenario: Placing a valid order confirms it and notifies downstream systems
  Given a customer wants to order 2 units of sku "WIDGET-SPEC-1"
  When the customer places the order
  Then the order is confirmed
  And the order is persisted with status "CONFIRMED"
  And an order-placed event is published to the order-events topic
  And the customer's callback URL receives a confirmation webhook
