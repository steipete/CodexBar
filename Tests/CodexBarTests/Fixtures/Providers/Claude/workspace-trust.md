# Workspace trust dialog fixtures

`workspace-trust-dialog.ansi` is the first frame Claude Code 2.1.282 writes to a 160x50 PTY when it starts in an untrusted folder with CodexBar's probe arguments. Only the workspace path is replaced with a synthetic one; the frame was byte-identical across three captures. `❯` marks the preselected `No, exit` option, and the gaps between words are cursor moves, not space characters.

`workspace-trust-select-down.ansi` is the redraw that followed one Down arrow: it erases the marker on `No, exit` and draws it on `Yes, I trust this folder`.
