using System.Diagnostics;
using System.Text;

namespace CodexBar.Windows.Core;

public sealed class ProviderProbeRunner
{
    public async Task<IReadOnlyList<ProviderSnapshot>> LoadAsync(
        IReadOnlyList<ProviderProbeSettings> providers,
        CancellationToken cancellationToken)
    {
        var snapshots = new List<ProviderSnapshot>(providers.Count);
        foreach (var provider in providers.Where(provider => provider.Enabled))
        {
            snapshots.Add(await LoadProviderAsync(provider, cancellationToken).ConfigureAwait(false));
        }

        return snapshots;
    }

    public async Task<ProviderSnapshot> LoadProviderAsync(
        ProviderProbeSettings provider,
        CancellationToken cancellationToken)
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(provider.SnapshotPath))
            {
                return await LoadSnapshotFileAsync(provider, cancellationToken).ConfigureAwait(false);
            }

            if (!string.IsNullOrWhiteSpace(provider.Command))
            {
                return await LoadCommandAsync(provider, cancellationToken).ConfigureAwait(false);
            }

            return ProviderSnapshot.Unknown(provider.Id, provider.Name, "No snapshot path or command configured.");
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            return ProviderSnapshot.Failed(provider.Id, provider.Name, exception.Message);
        }
    }

    private static async Task<ProviderSnapshot> LoadSnapshotFileAsync(
        ProviderProbeSettings provider,
        CancellationToken cancellationToken)
    {
        var path = Environment.ExpandEnvironmentVariables(provider.SnapshotPath!);
        if (!File.Exists(path))
        {
            return ProviderSnapshot.Unknown(provider.Id, provider.Name, $"Snapshot not found: {path}");
        }

        var json = await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false);
        return ProviderSnapshotJson.Parse(json).ToSnapshot(provider);
    }

    private static async Task<ProviderSnapshot> LoadCommandAsync(
        ProviderProbeSettings provider,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(provider.TimeoutSeconds));

        var startInfo = new ProcessStartInfo
        {
            FileName = provider.Command!,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        if (!string.IsNullOrWhiteSpace(provider.WorkingDirectory))
        {
            startInfo.WorkingDirectory = provider.WorkingDirectory;
        }

        foreach (var argument in provider.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo) ??
            throw new InvalidOperationException($"Unable to start {provider.Command}.");

        var stdoutTask = process.StandardOutput.ReadToEndAsync(timeout.Token);
        var stderrTask = process.StandardError.ReadToEndAsync(timeout.Token);
        await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);

        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            var message = string.IsNullOrWhiteSpace(stderr) ? $"exit code {process.ExitCode}" : stderr.Trim();
            throw new InvalidOperationException($"{provider.Command} failed: {message}");
        }

        var payload = ExtractJsonObject(stdout);
        return ProviderSnapshotJson.Parse(payload).ToSnapshot(provider);
    }

    private static string ExtractJsonObject(string stdout)
    {
        var trimmed = stdout.Trim();
        if (trimmed.StartsWith('{') && trimmed.EndsWith('}'))
        {
            return trimmed;
        }

        var builder = new StringBuilder();
        foreach (var line in trimmed.Split('\n'))
        {
            var candidate = line.Trim();
            if (candidate.StartsWith('{') && candidate.EndsWith('}'))
            {
                return candidate;
            }

            builder.AppendLine(candidate);
        }

        throw new InvalidOperationException($"Probe did not print a JSON object: {builder.ToString().Trim()}");
    }
}
