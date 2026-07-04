using System.Text.Json;
using Confluent.Kafka;
using Npgsql;
using Orders.Api;

var builder = WebApplication.CreateBuilder(args);

// Plain, single-line stdout logging — the engine's health gate and reporting only care
// about the HTTP surface, but readable container logs matter for the smoke test / troubleshooting.
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(options =>
{
    options.SingleLine = true;
    options.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ ";
});

// Listen on 0.0.0.0:8080 explicitly (the vouchfx health gate polls GET / on httpPort: 8080).
builder.WebHost.ConfigureKestrel(options => options.ListenAnyIP(8080));

// An unhandled DatabaseInitializer failure (Postgres never reachable within the retry
// budget) stops the whole host rather than leaving a zombie container stuck at 503.
builder.Services.Configure<HostOptions>(options =>
    options.BackgroundServiceExceptionBehavior = BackgroundServiceExceptionBehavior.StopHost);

// ConnectionStrings__orders -> "ConnectionStrings:orders" via the standard double-underscore
// environment-variable configuration convention.
var connectionString = builder.Configuration.GetConnectionString("orders")
    ?? throw new InvalidOperationException(
        "Configuration 'ConnectionStrings:orders' (env ConnectionStrings__orders) is required.");

var kafkaBootstrap = builder.Configuration["KAFKA_BOOTSTRAP"]
    ?? throw new InvalidOperationException("Configuration 'KAFKA_BOOTSTRAP' is required.");

builder.Services.AddSingleton<ReadinessState>();

builder.Services.AddSingleton(_ =>
{
    var dataSourceBuilder = new NpgsqlDataSourceBuilder(connectionString);
    return dataSourceBuilder.Build();
});

builder.Services.AddSingleton<IProducer<string, string>>(_ =>
    new ProducerBuilder<string, string>(new ProducerConfig
    {
        BootstrapServers = kafkaBootstrap,
        // librdkafka's default message.timeout.ms is 300000 (5 minutes) — an unreachable
        // broker would otherwise hang ProduceAsync (and so the POST /orders request) for up
        // to 5 minutes before the produce is finally reported as failed. Bounding it to 10s
        // keeps a Kafka outage from ever blocking the HTTP response for more than that.
        MessageTimeoutMs = 10_000,
    }).Build());

builder.Services.AddHttpClient<WebhookNotifier>();
builder.Services.AddHostedService<DatabaseInitializer>();

var app = builder.Build();

app.MapGet("/", (ReadinessState readiness) =>
    readiness.IsReady
        ? Results.Ok(new { status = "ready" })
        : Results.Json(new { status = "starting" }, statusCode: StatusCodes.Status503ServiceUnavailable));

app.MapPost("/orders", async (
    CreateOrderRequest request,
    NpgsqlDataSource dataSource,
    IProducer<string, string> producer,
    WebhookNotifier webhookNotifier,
    ILogger<Program> logger,
    CancellationToken cancellationToken) =>
{
    if (string.IsNullOrWhiteSpace(request.Sku) || request.Quantity <= 0)
    {
        return Results.BadRequest(new { error = "'sku' and a positive 'quantity' are required." });
    }

    var id = Guid.NewGuid();
    const string status = "CONFIRMED";

    await using (var connection = await dataSource.OpenConnectionAsync(cancellationToken))
    await using (var command = connection.CreateCommand())
    {
        command.CommandText = """
            INSERT INTO orders (id, sku, quantity, status)
            VALUES (@id, @sku, @quantity, @status);
            """;
        command.Parameters.AddWithValue("id", id);
        command.Parameters.AddWithValue("sku", request.Sku);
        command.Parameters.AddWithValue("quantity", request.Quantity);
        command.Parameters.AddWithValue("status", status);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    // Publish the order-created event. ProduceAsync's returned Task completes only once the
    // broker has acknowledged (or rejected) delivery, so awaiting it is the "flush/await
    // delivery" the event really needs — but a broker hiccup must not fail an otherwise
    // successful order confirmation, so a produce failure is logged and swallowed (see
    // README "Troubleshooting" for why this degrades gracefully instead of failing the request).
    var eventPayload = JsonSerializer.Serialize(
        new OrderEvent(id, request.Sku, request.Quantity, status), JsonDefaults.Options);
    try
    {
        // Defence in depth alongside ProducerConfig.MessageTimeoutMs above: whatever the
        // broker does, this request is never held open by Kafka for more than ~15s.
        await producer.ProduceAsync(
                "order-events",
                new Message<string, string> { Key = id.ToString(), Value = eventPayload },
                cancellationToken)
            .WaitAsync(TimeSpan.FromSeconds(15), cancellationToken);
        logger.LogInformation("Published order-events for order {OrderId}.", id);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Failed to publish order-events for order {OrderId}; continuing.", id);
    }

    if (!string.IsNullOrWhiteSpace(request.CallbackUrl))
    {
        _ = webhookNotifier.NotifyInBackgroundAsync(request.CallbackUrl, id, status);
    }

    return Results.Created($"/orders/{id}", new OrderResponse(id, request.Sku, request.Quantity, status));
});

app.MapGet("/orders/{id:guid}", async (Guid id, NpgsqlDataSource dataSource, CancellationToken cancellationToken) =>
{
    await using var connection = await dataSource.OpenConnectionAsync(cancellationToken);
    await using var command = connection.CreateCommand();
    command.CommandText = """
        SELECT id, sku, quantity, status, created_at
        FROM orders
        WHERE id = @id;
        """;
    command.Parameters.AddWithValue("id", id);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken))
    {
        return Results.NotFound();
    }

    var order = new OrderDetail(
        reader.GetGuid(0),
        reader.GetString(1),
        reader.GetInt32(2),
        reader.GetString(3),
        reader.GetDateTime(4));
    return Results.Ok(order);
});

app.Run();
