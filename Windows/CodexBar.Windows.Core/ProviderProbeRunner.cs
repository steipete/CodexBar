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
        return ProviderSnapshotJson.ParseSnapshot(json, provider);
    }

    private static async Task<ProviderSnapshot> LoadCommandAsync(
        ProviderProbeSettings provider,
        CancellationToken cancellationToken)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(provider.TimeoutSeconds));
        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);

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

        var stdoutTask = ReadToEndAsync(process.StandardOutput, linkedCancellation.Token);
        var stderrTask = ReadToEndAsync(process.StandardError, linkedCancellation.Token);
        try
        {
            await process.WaitForExitAsync(linkedCancellation.Token).ConfigureAwait(false);
            var stdout = await stdoutTask.ConfigureAwait(false);
            var stderr = await stderrTask.ConfigureAwait(false);
            if (process.ExitCode != 0)
            {
                var message = string.IsNullOrWhiteSpace(stderr) ? $"exit code {process.ExitCode}" : stderr.Trim();
                throw new InvalidOperationException($"{provider.Command} failed: {message}");
            }

            var payload = ExtractJsonPayload(stdout);
            return ProviderSnapshotJson.ParseSnapshot(payload, provider);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            await KillTimedOutProcessAsync(process, stdoutTask, stderrTask).ConfigureAwait(false);
            throw new TimeoutException($"{provider.Command} timed out after {provider.TimeoutSeconds} seconds.");
        }
    }

    private static async Task<string> ReadToEndAsync(TextReader reader, CancellationToken cancellationToken)
    {
        return await reader.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task KillTimedOutProcessAsync(
        Process process,
        Task<string> stdoutTask,
        Task<string> stderrTask)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
        }

        try
        {
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch
        {
        }

        await IgnoreReadFailureAsync(stdoutTask).ConfigureAwait(false);
        await IgnoreReadFailureAsync(stderrTask).ConfigureAwait(false);
    }

    private static async Task IgnoreReadFailureAsync(Task<string> task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch
        {
        }
    }

    private static string ExtractJsonPayload(string stdout)
    {
        var trimmed = stdout.Trim();
        if (IsCompleteJsonPayload(trimmed))
        {
            return trimmed;
        }

        var builder = new StringBuilder();
        foreach (var line in trimmed.Split('\n'))
        {
            var candidate = line.Trim();
            if (IsCompleteJsonPayload(candidate))
            {
                return candidate;
            }

            builder.AppendLine(candidate);
        }

        throw new InvalidOperationException($"Probe did not print a JSON object or array: {builder.ToString().Trim()}");
    }

    private static bool IsCompleteJsonPayload(string candidate)
    {
        return candidate.StartsWith('{') && candidate.EndsWith('}') ||
            candidate.StartsWith('[') && candidate.EndsWith(']');
    }
}
