namespace CodexBar.Windows.Tests;

public sealed class WindowsBuildScriptTests
{
    [Fact]
    public void BuildScript_InvokesInnoResolverAfterWingetInstall()
    {
        var root = FindRepositoryRoot();
        var scriptPath = Path.Combine(root, "Scripts", "build_windows.ps1");
        var script = File.ReadAllText(scriptPath);

        Assert.Contains("return (Resolve-InnoCompiler)", script);
        Assert.DoesNotContain("return Resolve-InnoCompiler", script);
    }

    private static string FindRepositoryRoot()
    {
        var directory = AppContext.BaseDirectory;
        while (!string.IsNullOrEmpty(directory))
        {
            if (File.Exists(Path.Combine(directory, "Package.swift")))
            {
                return directory;
            }

            directory = Directory.GetParent(directory)?.FullName;
        }

        throw new DirectoryNotFoundException("Could not find CodexBar repository root.");
    }
}
