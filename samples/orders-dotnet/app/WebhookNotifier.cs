using System.Text;
using System.Text.Json;

namespace Orders.Api;

/// <summary>
/// Delivers the outbound order-confirmation webhook in the background (fire-and-forget from
/// the caller's perspective, exactly as <c>POST /orders</c> is specified), with 5 attempts and
/// a 2 s fixed backoff between them.
/// </summary>
/// <remarks>
/// The target URL is <c>{callbackUrl}/callbacks/{orderId}</c> — this exact
/// "<c>&lt;base&gt;callbacks/&lt;id&gt;</c>" composition mirrors vouchfx's own reference
/// scenario (<c>examples/reference/reference.e2e.yaml</c>, step <c>webhook-trigger</c>), so a
/// suite's <c>webhook-listen.http</c> step can assert <c>match.path: "/callbacks/{orderId}"</c>
/// against exactly what this app sends — see samples/orders-dotnet/tests/orders.e2e.yaml.
/// </remarks>
internal sealed class WebhookNotifier
{
    private const int MaxAttempts = 5;
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(2);

    private readonly HttpClient _httpClient;
    private readonly ILogger<WebhookNotifier> _logger;

    public WebhookNotifier(HttpClient httpClient, ILogger<WebhookNotifier> logger)
    {
        _httpClient = httpClient;
        _logger = logger;
    }

    /// <summary>
    /// Schedules delivery on the thread pool and returns immediately; the caller (the
    /// <c>POST /orders</c> handler) does not await this, matching the "deliver in the
    /// background" contract.
    /// </summary>
    public Task NotifyInBackgroundAsync(string callbackUrl, Guid orderId, string status)
        => Task.Run(() => NotifyAsync(callbackUrl, orderId, status));

    private async Task NotifyAsync(string callbackUrl, Guid orderId, string status)
    {
        var target = $"{callbackUrl.TrimEnd('/')}/callbacks/{orderId}";
        var payload = JsonSerializer.Serialize(new WebhookPayload(orderId, status), JsonDefaults.Options);

        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                using var content = new StringContent(payload, Encoding.UTF8, "application/json");
                using var response = await _httpClient.PostAsync(target, content);
                if (response.IsSuccessStatusCode)
                {
                    _logger.LogInformation(
                        "Webhook callback for order {OrderId} delivered on attempt {Attempt}/{MaxAttempts}.",
                        orderId, attempt, MaxAttempts);
                    return;
                }

                _logger.LogWarning(
                    "Webhook callback for order {OrderId} returned {StatusCode} on attempt {Attempt}/{MaxAttempts}.",
                    orderId, (int)response.StatusCode, attempt, MaxAttempts);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(
                    ex,
                    "Webhook callback for order {OrderId} failed on attempt {Attempt}/{MaxAttempts}.",
                    orderId, attempt, MaxAttempts);
            }

            if (attempt < MaxAttempts)
            {
                await Task.Delay(RetryDelay);
            }
        }

        _logger.LogError(
            "Webhook callback for order {OrderId} exhausted all {MaxAttempts} attempts; giving up.",
            orderId, MaxAttempts);
    }
}
