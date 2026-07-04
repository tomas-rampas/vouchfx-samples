using Npgsql;

namespace Orders.Api;

/// <summary>
/// Startup gate: retries the Postgres connection for up to <see cref="RetryBudget"/>
/// (~60 s) until it is reachable, then creates the <c>orders</c> table if it does not
/// already exist and flips <see cref="ReadinessState"/> so <c>GET /</c> starts returning 200.
/// </summary>
/// <remarks>
/// If Postgres never becomes reachable within the retry budget this throws, and — because
/// <c>Program.cs</c> configures <see cref="Microsoft.Extensions.Hosting.BackgroundServiceExceptionBehavior.StopHost"/>
/// — that stops the whole host. A container that can never reach its database exiting with
/// a clear log line is more useful than one silently serving 503 forever; the vouchfx health
/// gate that polls <c>GET /</c> will time out either way (an Environment error, not a defect).
/// In the vouchfx topology this path is rarely exercised: the engine's <c>WaitFor</c> targets
/// the database resource itself before starting this service's container.
/// </remarks>
internal sealed class DatabaseInitializer : BackgroundService
{
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan RetryBudget = TimeSpan.FromSeconds(60);

    private readonly NpgsqlDataSource _dataSource;
    private readonly ReadinessState _readiness;
    private readonly ILogger<DatabaseInitializer> _logger;

    public DatabaseInitializer(
        NpgsqlDataSource dataSource,
        ReadinessState readiness,
        ILogger<DatabaseInitializer> logger)
    {
        _dataSource = dataSource;
        _readiness = readiness;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var deadline = DateTime.UtcNow + RetryBudget;
        Exception? lastError = null;

        while (DateTime.UtcNow < deadline)
        {
            try
            {
                await using var connection = await _dataSource.OpenConnectionAsync(stoppingToken);
                await using var command = connection.CreateCommand();
                command.CommandText = """
                    CREATE TABLE IF NOT EXISTS orders (
                        id uuid PRIMARY KEY,
                        sku text NOT NULL,
                        quantity int NOT NULL,
                        status text NOT NULL,
                        created_at timestamptz DEFAULT now()
                    );
                    """;
                await command.ExecuteNonQueryAsync(stoppingToken);

                _readiness.MarkReady();
                _logger.LogInformation("Postgres reachable; orders table ready.");
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                lastError = ex;
                _logger.LogWarning(
                    ex, "Postgres not yet reachable; retrying in {DelaySeconds}s.", RetryDelay.TotalSeconds);
                await Task.Delay(RetryDelay, stoppingToken);
            }
        }

        throw new InvalidOperationException(
            "Postgres was not reachable within the 60s startup retry budget.", lastError);
    }
}
