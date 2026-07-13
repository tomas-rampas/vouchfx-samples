using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Confluent.Kafka;
using Npgsql;
using Xunit;

namespace OrdersApi.IntegrationTests;

/// <summary>
/// Integration test for <c>POST /orders</c>: places an order over plain HTTP, then confirms
/// the row landed in Postgres and the <c>order-events</c> Kafka message was published — the
/// exact same three-part proof as
/// ../../ported/orders-integration.e2e.yaml, hand-rolled the way a team actually writes it.
/// </summary>
/// <remarks>
/// This is the kind of test vouchfx exists to replace with a declarative suite. It requires
/// a live stack (the orders-dotnet app, Postgres, and Kafka, all reachable) and three
/// environment variables — see the README next to this file for exactly how to stand that
/// up and run it. It is <strong>not</strong> executed by this repository's CI; only
/// compiled (<c>dotnet build</c>), to prove the hand-rolled shape below is genuine, working
/// C# and not a strawman.
/// </remarks>
public sealed class OrderPlacementTests : IAsyncLifetime
{
    private readonly HttpClient _httpClient = new();
    private string _connectionString = string.Empty;
    private string _kafkaBootstrap = string.Empty;

    public Task InitializeAsync()
    {
        // Hand-rolled environment wiring: three separate env vars the test author must
        // remember to set, matching whatever docker-compose/CI job happens to be running
        // the stack this test points at. Compare with the ported suite's environment:
        // block, which the engine owns end to end — nothing to configure here at all.
        var baseUrl = Environment.GetEnvironmentVariable("ORDERS_API_BASE_URL")
            ?? throw new InvalidOperationException(
                "ORDERS_API_BASE_URL must be set (see README.md next to this file).");
        _httpClient.BaseAddress = new Uri(baseUrl);

        _connectionString = Environment.GetEnvironmentVariable("ORDERS_DB_CONNECTION_STRING")
            ?? throw new InvalidOperationException(
                "ORDERS_DB_CONNECTION_STRING must be set (see README.md next to this file).");

        _kafkaBootstrap = Environment.GetEnvironmentVariable("KAFKA_BOOTSTRAP")
            ?? throw new InvalidOperationException(
                "KAFKA_BOOTSTRAP must be set (see README.md next to this file).");

        return Task.CompletedTask;
    }

    public Task DisposeAsync()
    {
        _httpClient.Dispose();
        return Task.CompletedTask;
    }

    [Fact]
    public async Task PlaceOrder_PersistsRowAndPublishesEvent()
    {
        // ── Act: place the order over a plain HttpClient ───────────────────────────────
        var response = await _httpClient.PostAsJsonAsync("/orders", new
        {
            sku = "WIDGET-1",
            quantity = 3,
        });

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        var orderId = body.GetProperty("id").GetGuid();
        Assert.Equal("WIDGET-1", body.GetProperty("sku").GetString());
        Assert.Equal("CONFIRMED", body.GetProperty("status").GetString());

        // ── Assert: the row landed in Postgres ──────────────────────────────────────────
        // Hand-rolled connection/command/reader plumbing every test author who reaches for
        // "assert the database, not just the response" ends up writing themselves.
        await using var connection = new NpgsqlConnection(_connectionString);
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT sku, status FROM orders WHERE id = @id";
        command.Parameters.AddWithValue("id", orderId);

        await using var reader = await command.ExecuteReaderAsync();
        Assert.True(await reader.ReadAsync(), "Expected exactly one order row.");
        Assert.Equal("WIDGET-1", reader.GetString(0));
        Assert.Equal("CONFIRMED", reader.GetString(1));
        await reader.CloseAsync();

        // ── Assert: the order-events Kafka message was published ───────────────────────
        // A hand-rolled poll: consume from the beginning of the topic and scan for up to
        // ~20s for a message whose "id" field matches. This is exactly the kind of
        // author-written retry/backoff loop the ported suite's mq-expect.kafka step with
        // verifyMode: RETRY replaces — no author-managed consumer group, deadline, or
        // Task.Delay tuning.
        using var consumer = new ConsumerBuilder<Ignore, string>(new ConsumerConfig
        {
            BootstrapServers = _kafkaBootstrap,
            GroupId = $"orders-integration-tests-{Guid.NewGuid()}",
            AutoOffsetReset = AutoOffsetReset.Earliest,
        }).Build();

        consumer.Subscribe("order-events");

        var deadline = DateTime.UtcNow.AddSeconds(20);
        var found = false;
        while (DateTime.UtcNow < deadline && !found)
        {
            var result = consumer.Consume(TimeSpan.FromSeconds(1));
            if (result?.Message?.Value is null)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(500));
                continue;
            }

            using var eventBody = JsonDocument.Parse(result.Message.Value);
            if (eventBody.RootElement.GetProperty("id").GetString() == orderId.ToString())
            {
                found = true;
            }
        }

        consumer.Close();
        Assert.True(found, $"Expected an order-events message for order {orderId} within 20s.");
    }
}
