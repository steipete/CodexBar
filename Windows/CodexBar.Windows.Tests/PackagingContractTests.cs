namespace CodexBar.Windows.Tests;

public sealed class PackagingContractTests
{
    [Fact]
    public void InstallerPinsSingleInstanceMutexAndStartupEntry()
    {
        var root = RepositoryRoot.Find();
        var installer = File.ReadAllText(Path.Combine(root, "installer.iss"));
        var program = File.ReadAllText(Path.Combine(root, "Windows", "CodexBar.Windows", "Program.cs"));

        Assert.Contains("AppMutex=CodexBar.Windows.Tray", installer);
        Assert.Contains("\"CodexBar.Windows.Tray\"", program);
        Assert.Contains("Name: \"startupicon\"", installer);
        Assert.Contains("CodexBar-Setup-{#MyAppArch}", installer);
    }

    [Fact]
    public void CiBuildsSignsAndUploadsWindowsArtifacts()
    {
        var root = RepositoryRoot.Find();
        var ci = File.ReadAllText(Path.Combine(root, ".github", "workflows", "ci.yml"));
        var release = File.ReadAllText(Path.Combine(root, ".github", "workflows", "release-cli.yml"));

        Assert.Contains("build-windows-tray", ci);
        Assert.Contains("azure/trusted-signing-action@v2", ci);
        Assert.Contains("certificate-profile-name: WindowsEdgeLight", ci);
        Assert.Contains("codexbar-windows-${{ matrix.rid }}", ci);

        Assert.Contains("build-windows", release);
        Assert.Contains("Require signing secrets for release assets", release);
        Assert.Contains("if: github.event_name == 'release' || inputs.tag != ''", release);
        Assert.Contains("0.0.0-dev", release);
        Assert.Contains("gh release upload $env:RELEASE_TAG", release);
    }
}
