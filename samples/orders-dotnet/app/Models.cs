namespace Orders.Api;

/// <summary>Request body for <c>POST /orders</c>.</summary>
internal sealed record CreateOrderRequest(string Sku, int Quantity, string? CallbackUrl);

/// <summary>Response body for <c>POST /orders</c> and the 200 branch of <c>GET /orders/{id}</c>.</summary>
internal sealed record OrderResponse(Guid Id, string Sku, int Quantity, string Status);

/// <summary>Full row projection returned by <c>GET /orders/{id}</c>.</summary>
internal sealed record OrderDetail(Guid Id, string Sku, int Quantity, string Status, DateTime CreatedAt);

/// <summary>The JSON value published to the <c>order-events</c> Kafka topic.</summary>
internal sealed record OrderEvent(Guid Id, string Sku, int Quantity, string Status);

/// <summary>The JSON body POSTed to a caller-supplied <c>callbackUrl</c>.</summary>
internal sealed record WebhookPayload(Guid OrderId, string Status);
