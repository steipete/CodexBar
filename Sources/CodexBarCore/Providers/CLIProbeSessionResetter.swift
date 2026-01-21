import Foundation

public enum CLIProbeSessionResetter {
    public static func resetAll() async {
        await ClaudeCLISession.shared.reset()
        await CodexCLISession.shared.reset()
    }
}
