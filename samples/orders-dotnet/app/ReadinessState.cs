namespace Orders.Api;

/// <summary>
/// Tracks whether startup initialisation (the Postgres retry-loop + <c>CREATE TABLE IF NOT
/// EXISTS</c>) has completed. <c>GET /</c> reads this to decide between 503 and 200 — this
/// IS the vouchfx engine's health gate, which polls <c>GET /</c> on <c>httpPort</c> and waits
/// for a 2xx before letting any step run.
/// </summary>
internal sealed class ReadinessState
{
    private volatile bool _isReady;

    public bool IsReady => _isReady;

    public void MarkReady() => _isReady = true;
}
