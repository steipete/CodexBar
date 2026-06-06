using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace CodexBar.Windows.Core;

public sealed class ProviderProbeRunner
{
    private const int MaxProbeStreamCharacters = 1024 * 1024;

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
            FileName = Environment.ExpandEnvironmentVariables(provider.Command!),
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        if (!string.IsNullOrWhiteSpace(provider.WorkingDirectory))
        {
            startInfo.WorkingDirectory = Environment.ExpandEnvironmentVariables(provider.WorkingDirectory);
        }

        foreach (var argument in provider.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo) ??
            throw new InvalidOperationException($"Unable to start {provider.Command}.");

        var stdoutTask = ReadBoundedAsync(process.StandardOutput, linkedCancellation.Token);
        var stderrTask = ReadBoundedAsync(process.StandardError, linkedCancellation.Token);
        try
        {
            var exitTask = process.WaitForExitAsync(linkedCancellation.Token);
            var firstCompleted = await Task.WhenAny(exitTask, stdoutTask, stderrTask).ConfigureAwait(false);
            await firstCompleted.ConfigureAwait(false);
            await exitTask.ConfigureAwait(false);

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
        catch (ProbeOutputLimitExceededException exception)
        {
            await KillTimedOutProcessAsync(process, stdoutTask, stderrTask).ConfigureAwait(false);
            throw new InvalidOperationException($"{provider.Command} {exception.Message}");
        }
    }

    private static async Task<string> ReadBoundedAsync(TextReader reader, CancellationToken cancellationToken)
    {
        var buffer = new char[4096];
        var builder = new StringBuilder();
        while (true)
        {
            var read = await reader.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return builder.ToString();
            }

            if (builder.Length + read > MaxProbeStreamCharacters)
            {
                throw new ProbeOutputLimitExceededException(
                    $"output exceeded {MaxProbeStreamCharacters} characters.");
            }

            builder.Append(buffer, 0, read);
        }
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
        if (IsCompleteJsonPayload(trimmed) && CanParseJson(trimmed))
        {
            return trimmed;
        }

        for (var index = 0; index < trimmed.Length; index++)
        {
            var start = trimmed[index];
            if (start != '{' && start != '[')
            {
                continue;
            }

            var candidate = ReadBalancedJson(trimmed, index);
            if (candidate is not null && CanParseJson(candidate))
            {
                return candidate;
            }
        }

        throw new InvalidOperationException(
            $"Probe did not print a JSON object or array. Output preview: {FormatOutputPreview(trimmed)}");
    }

    private static bool IsCompleteJsonPayload(string candidate)
    {
        return candidate.StartsWith('{') && candidate.EndsWith('}') ||
            candidate.StartsWith('[') && candidate.EndsWith(']');
    }

    private static string? ReadBalancedJson(string text, int startIndex)
    {
        var stack = new Stack<char>();
        var inString = false;
        var escaped = false;

        for (var index = startIndex; index < text.Length; index++)
        {
            var character = text[index];
            if (inString)
            {
                if (escaped)
                {
                    escaped = false;
                }
                else if (character == '\\')
                {
                    escaped = true;
                }
                else if (character == '"')
                {
                    inString = false;
                }

                continue;
            }

            if (character == '"')
            {
                inString = true;
                continue;
            }

            if (character == '{')
            {
                stack.Push('}');
                continue;
            }

            if (character == '[')
            {
                stack.Push(']');
                continue;
            }

            if ((character == '}' || character == ']') && (stack.Count == 0 || stack.Pop() != character))
            {
                return null;
            }

            if (stack.Count == 0)
            {
                return text[startIndex..(index + 1)];
            }
        }

        return null;
    }

    private static bool CanParseJson(string candidate)
    {
        try
        {
            using var document = JsonDocument.Parse(candidate);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static string FormatOutputPreview(string output)
    {
        const int MaxPreviewLength = 512;
        var compact = output.Replace('\r', ' ').Replace('\n', ' ').Trim();
        if (compact.Length <= MaxPreviewLength)
        {
            return compact;
        }

        return $"{compact[..MaxPreviewLength]}...";
    }

    private sealed class ProbeOutputLimitExceededException(string message) : Exception(message);
}
