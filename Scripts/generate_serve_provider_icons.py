#!/usr/bin/env python3
"""Regenerate Sources/CodexBarCLI/CLIServeProviderIcons.swift from the app's
ProviderIcon SVGs. The serve web dashboard embeds these because the CLI is
deployed as a standalone binary without a SwiftPM resource bundle."""
import base64, glob, os
os.chdir(os.path.join(os.path.dirname(__file__), ".."))
files = sorted(glob.glob("Sources/CodexBar/Resources/ProviderIcon-*.svg"))
out = [
    "// Generated from Sources/CodexBar/Resources/ProviderIcon-*.svg — do not edit by hand.",
    "// Regenerate with: python3 scripts/generate_serve_provider_icons.py",
    "// Embedded (not Bundle.module) because the CLI ships as a standalone binary",
    "// without a SwiftPM resource bundle next to it.",
    "",
    "enum CLIServeProviderIcons {",
    "    static let base64ByResourceName: [String: String] = [",
]
for f in files:
    name = os.path.basename(f)[:-4]
    data = base64.b64encode(open(f, "rb").read()).decode()
    out.append(f'        "{name}": "{data}",')
out += ["    ]", "}"]
open("Sources/CodexBarCLI/CLIServeProviderIcons.swift", "w").write("\n".join(out) + "\n")
print(f"generated {len(files)} icons")
