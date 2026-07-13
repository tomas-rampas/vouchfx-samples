using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Threading.Tasks;
using Confluent.Kafka;
using Npgsql;
using TechTalk.SpecFlow;
using Xunit;

namespace Orders.Specs;

/// <summary>
/// Step definitions for PlaceOrder.feature — hand-rolled HttpClient/Npgsql/Kafka plumbing
/// threaded through <see cref="ScenarioContext"/>, exactly the way a team's SpecFlow suite
/// actually accumulates this kind of code over time. See ../../README.md for the mapping
/// onto ../../ported/place-order.e2e.yaml, and ../../from-xunit for the near-identical
/// hand-rolled Kafka poll this step class duplicates — that duplication across test
/// projects is itself part of the pain vouchfx removes.
/// </summary>
[Binding]
public sealed class PlaceOrderSteps
{
    private readonly ScenarioContext _scenarioContext;
    private readonly HttpClient _httpClient;
    private readonly string _connectionString;
    private readonly string _kafkaBootstrap;

    public PlaceOrderSteps(ScenarioContext scenarioContext)
    {
        _scenarioContext = scenarioContext;

        var baseUrl = Environment.GetEnvironmentVariable("ORDERS_API_BASE_URL")
            ?? throw new InvalidOperationException(
                "ORDERS_API_BASE_URL must be set (see README.md next to this project).");
        _httpClient = new HttpClient { BaseAddress = new Uri(baseUrl) };

        _connectionString = Environment.GetEnvironmentVariable("ORDERS_DB_CONNECTION_STRING")
            ?? throw new InvalidOperationException(
                "ORDERS_DB_CONNECTION_STRING must be set (see README.md next to this project).");

        _kafkaBootstrap = Environment.GetEnvironmentVariable("KAFKA_BOOTSTRAP")
            ?? throw new InvalidOperationException(
                "KAFKA_BOOTSTRAP must be set (see README.md next to this project).");
    }

    [BeforeScenario]
    public async Task ResetFixturesAsync()
    {
        // Background: "the orders service has no existing order for sku ...". A hand-rolled
        // hook doing exactly what a seed fixture does declaratively — see
        // ../../ported/fixtures/reset-sku.sql and ../../README.md.
        await using var connection = new NpgsqlConnection(_connectionString);
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM orders WHERE sku = @sku";
        command.Parameters.AddWithValue("sku", "WIDGET-SPEC-1");
        await command.ExecuteNonQueryAsync();
    }

    [Given(@"the orders service has no existing order for sku ""(.*)""")]
    public void GivenTheOrdersServiceHasNoExistingOrderForSku(string sku)
    {
        // Enforced by the [BeforeScenario] hook above; this step exists purely so the
        // Background reads naturally in the feature file — there is nothing further to do.
        _scenarioContext["sku"] = sku;
    }

    [Given(@"a customer wants to order (.*) units of sku ""(.*)""")]
    public void GivenACustomerWantsToOrderUnitsOfSku(int quantity, string sku)
    {
        _scenarioContext["quantity"] = quantity;
        _scenarioContext["sku"] = sku;
    }

    [When(@"the customer places the order")]
    public async Task WhenTheCustomerPlacesTheOrder()
    {
        var sku = (string)_scenarioContext["sku"];
        var quantity = (int)_scenarioContext["quantity"];

        // A real callback listener a hand-rolled test needs to stand up and tear down
        // itself — see CallbackListener.cs and ../../README.md for why this whole class
        // exists only to replace one 'webhook-listen.http' step in the ported suite.
        var listener = new CallbackListener();
        var callbackUrl = await listener.StartAsync();
        _scenarioContext["callbackListener"] = listener;

        var response = await _httpClient.PostAsJsonAsync("/orders", new
        {
            sku,
            quantity,
            callbackUrl,
        });

        _scenarioContext["response"] = response;
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        _scenarioContext["orderId"] = body.GetProperty("id").GetGuid();
        _scenarioContext["status"] = body.GetProperty("status").GetString();
    }

    [Then(@"the order is confirmed")]
    public void ThenTheOrderIsConfirmed()
    {
        var response = (HttpResponseMessage)_scenarioContext["response"];
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
    }

    [Then(@"the order is persisted with status ""(.*)""")]
    public async Task ThenTheOrderIsPersistedWithStatus(string expectedStatus)
    {
        var orderId = (Guid)_scenarioContext["orderId"];

        await using var connection = new NpgsqlConnection(_connectionString);
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT status FROM orders WHERE id = @id";
        command.Parameters.AddWithValue("id", orderId);
        var actualStatus = (string)await command.ExecuteScalarAsync();

        Assert.Equal(expectedStatus, actualStatus);
    }

    [Then(@"an order-placed event is published to the order-events topic")]
    public async Task ThenAnOrderPlacedEventIsPublished()
    {
        // Hand-rolled poll — near-identical to migrations/from-xunit's test, which is the
        // point: this exact ~20 lines gets re-typed into every test project that needs to
        // observe a Kafka side effect. ../../ported/place-order.e2e.yaml replaces it with
        // one mq-expect.kafka step and verifyMode: RETRY.
        var orderId = (Guid)_scenarioContext["orderId"];

        using var consumer = new ConsumerBuilder<Ignore, string>(new ConsumerConfig
        {
            BootstrapServers = _kafkaBootstrap,
            GroupId = $"orders-specs-{Guid.NewGuid()}",
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
        Assert.True(found, $"Expected an order-placed event for {orderId} within 20s.");
    }

    [Then(@"the customer's callback URL receives a confirmation webhook")]
    public async Task ThenTheCustomersCallbackUrlReceivesAConfirmationWebhook()
    {
        var listener = (CallbackListener)_scenarioContext["callbackListener"];
        try
        {
            var received = await listener.WaitForCallbackAsync(TimeSpan.FromSeconds(20));
            Assert.True(received, "Expected a callback within 20s.");
        }
        finally
        {
            listener.Stop();
        }
    }
}
