using System.Net.Http;

namespace CodexBarTray;

/// <summary>
/// Thin HTTP client over <c>codexbar serve</c>. Endpoints: <c>/health</c>,
/// <c>/usage</c>, <c>/cost</c>. Returns raw JSON for now; typed models will be
/// layered on once the popup UI consumes specific fields.
/// </summary>
public sealed class UsageClient : IDisposable
{
    private readonly HttpClient _http;

    public UsageClient(string baseUrl)
    {
        _http = new HttpClient
        {
            BaseAddress = new Uri(baseUrl),
            Timeout = TimeSpan.FromSeconds(30),
        };
    }

    /// <summary>Returns true when the server answers /health with HTTP 200.</summary>
    public async Task<bool> IsHealthyAsync(CancellationToken ct = default)
    {
        try
        {
            using var response = await _http.GetAsync("/health", ct).ConfigureAwait(false);
            return response.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Fetches usage JSON for the enabled providers (honors in-app toggles).</summary>
    public async Task<string> GetUsageJsonAsync(string? provider = null, CancellationToken ct = default)
    {
        var path = provider is null ? "/usage" : $"/usage?provider={Uri.EscapeDataString(provider)}";
        using var response = await _http.GetAsync(path, ct).ConfigureAwait(false);
        return await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
    }

    /// <summary>Fetches cost JSON (Claude/Codex local token-cost data).</summary>
    public async Task<string> GetCostJsonAsync(string? provider = null, CancellationToken ct = default)
    {
        var path = provider is null ? "/cost" : $"/cost?provider={Uri.EscapeDataString(provider)}";
        using var response = await _http.GetAsync(path, ct).ConfigureAwait(false);
        return await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
    }

    public void Dispose() => _http.Dispose();
}
