using System.Text.Json;

namespace Orders.Api;

/// <summary>
/// Shared <see cref="JsonSerializerOptions"/> for the handful of places this app serialises
/// JSON by hand (the Kafka event payload and the outbound webhook body) — outside ASP.NET
/// Core's own minimal-API request/response pipeline, which already applies
/// <see cref="JsonSerializerDefaults.Web"/> (camelCase, case-insensitive) automatically.
/// Using the same defaults here keeps every JSON shape the app emits consistent.
/// </summary>
internal static class JsonDefaults
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);
}
