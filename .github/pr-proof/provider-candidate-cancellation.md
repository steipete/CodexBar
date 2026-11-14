# Provider candidate cancellation: executed runtime proof

Claim: after cancellation is observed, the shared provider retry runner must stop before another lazy candidate
read or attempt. Replicate, TypeSafe, Command Code and Ollama use this runner. Browser candidates can perform I/O
when their iterator advances.

Environment: Linux x86_64, Swift 6.3.3, Swift 6 language mode. The standalone executable compiles the actual
production runner with `provider-candidate-cancellation.swift`, without a test framework. It creates two owned
temporary profile files, reads their contents through a lazy sequence, cancels real Swift tasks, and prints the
operations that happened. Temporary files are deleted on exit.

Run from the repository root with a Swift 6.2+ toolchain:

```bash
proof_dir="$(mktemp -d)"
runner=Sources/CodexBarCore/Providers/ProviderCandidateRetryRunner.swift
fixture=.github/pr-proof/provider-candidate-cancellation.swift
git show "22f731375854ae739bec1395ff5b3f1d5116a243:$runner" > "$proof_dir/before.swift"
swiftc -swift-version 6 -parse-as-library "$proof_dir/before.swift" "$fixture" -o "$proof_dir/before"
"$proof_dir/before"
swiftc -swift-version 6 -parse-as-library "$runner" "$fixture" -o "$proof_dir/after"
"$proof_dir/after"
```

Captured baseline output:

```text
beforeStart: outcome=success(1) loaded=[1] attempted=[1] retried=[]
  cancel -> read-profile-1 -> attempt-1
duringLoad: outcome=success(1) loaded=[1] attempted=[1] retried=[]
  read-profile-1 -> cancel -> attempt-1
duringFailedAttempt: outcome=success(2) loaded=[1, 2] attempted=[1, 2] retried=[1]
  read-profile-1 -> attempt-1 -> cancel -> authentication-expired -> read-profile-2 -> attempt-2
normalRetry: outcome=success(2) loaded=[1, 2] attempted=[1, 2] retried=[1]
  read-profile-1 -> attempt-1 -> authentication-expired -> read-profile-2 -> attempt-2
```

Captured fixed output:

```text
beforeStart: outcome=cancelled loaded=[] attempted=[] retried=[]
  cancel
duringLoad: outcome=cancelled loaded=[1] attempted=[] retried=[]
  read-profile-1 -> cancel
duringFailedAttempt: outcome=cancelled loaded=[1] attempted=[1] retried=[]
  read-profile-1 -> attempt-1 -> cancel -> authentication-expired
normalRetry: outcome=success(2) loaded=[1, 2] attempted=[1, 2] retried=[1]
  read-profile-1 -> attempt-1 -> authentication-expired -> read-profile-2 -> attempt-2
```

Limits: these are synthetic profile files and authentication failures. This exercises the production retry runtime,
not the app bundle, browser-cookie database extraction, a provider HTTP endpoint, or macOS Keychain prompts.
It proves that this runner stops advancing candidates; it does not prove that an in-progress read can be interrupted
or that a cancellation occurring between a check and a read is atomic. No live accounts, credentials, or Keychain
APIs are used.
