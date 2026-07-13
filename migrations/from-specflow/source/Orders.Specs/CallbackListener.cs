using System.Net;
using System.Net.Sockets;

namespace Orders.Specs;

/// <summary>
/// A minimal, hand-rolled HTTP callback listener — exactly the kind of host-owned
/// scaffolding a SpecFlow suite has to stand up and tear down itself so its own test
/// process can receive an outbound webhook. See ../../README.md: this entire class exists
/// only to replace ../../ported/place-order.e2e.yaml's single 'webhook-listen.http' step.
/// </summary>
/// <remarks>
/// Binding "http://+:{port}/" (rather than "http://localhost:{port}/") is what lets a
/// containerised orders-api reach this listener via host.docker.internal, but on Windows it
/// also requires either an administrator prompt or a one-time
/// <c>netsh http add urlacl url=http://+:{port}/ user=Everyone</c> reservation — exactly the
/// kind of host-networking plumbing vouchfx's host-owned listener (which needs none of this
/// from the suite author) exists to absorb.
/// </remarks>
internal sealed class CallbackListener
{
    private readonly HttpListener _listener = new();
    private readonly TaskCompletionSource<bool> _received =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Task _acceptLoop;

    public Task<string> StartAsync()
    {
        var port = GetFreeTcpPort();
        _listener.Prefixes.Add($"http://+:{port}/");
        _listener.Start();
        _acceptLoop = AcceptLoopAsync();
        return Task.FromResult($"http://host.docker.internal:{port}");
    }

    private async Task AcceptLoopAsync()
    {
        try
        {
            while (_listener.IsListening)
            {
                var context = await _listener.GetContextAsync();
                _received.TrySetResult(true);
                context.Response.StatusCode = 200;
                context.Response.Close();
            }
        }
        catch (HttpListenerException)
        {
            // The listener was stopped — expected during teardown.
        }
        catch (ObjectDisposedException)
        {
            // The listener was disposed — expected during teardown.
        }
    }

    public async Task<bool> WaitForCallbackAsync(TimeSpan timeout)
    {
        var completed = await Task.WhenAny(_received.Task, Task.Delay(timeout));
        return completed == _received.Task;
    }

    public void Stop()
    {
        _listener.Stop();
        _listener.Close();
    }

    private static int GetFreeTcpPort()
    {
        var socket = new TcpListener(IPAddress.Loopback, 0);
        socket.Start();
        var port = ((IPEndPoint)socket.LocalEndpoint).Port;
        socket.Stop();
        return port;
    }
}
