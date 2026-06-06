namespace CodexBar.Windows.Tests;

public sealed class WindowsBuildScriptTests
{
    [Fact]
    public void BuildScript_InvokesInnoResolverAfterWingetInstall()
    {
        var root = RepositoryRoot.Find();
        var scriptPath = Path.Combine(root, "Scripts", "build_windows.ps1");
        var script = File.ReadAllText(scriptPath);

        Assert.Contains("return (Resolve-InnoCompiler)", script);
        Assert.DoesNotContain("return Resolve-InnoCompiler", script);
    }
}
