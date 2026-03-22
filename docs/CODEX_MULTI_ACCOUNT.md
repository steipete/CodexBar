# Codex multi-account feature

## Goal
Add support for **multiple Codex / ChatGPT accounts** for the Codex provider, so multiple accounts can be shown together in the menu with their own separate usage state.

## User problem / motivation
My use case was simple: I often have more than one Codex account available, and I wanted to see them together in the menu bar, with each account's usage/limits visible at the same time.

The goal here is not to aggregate all accounts into one total. The goal is to keep accounts separate while making them visible together.

## What this implementation does
For Codex, this turns the menu from a single-account usage view into a multi-account view.

In practice, it adds three things:
- multiple Codex accounts shown together in the menu, each with its own usage card
- account identity shown using the Codex account email and whether the account is personal vs team/workspace-backed
- sorting for the account cards

Sorting matters because once multiple accounts are visible together, it becomes useful to answer practical questions like:
- which account resets soonest?
- which account still has the most usage left?

## Technical direction
The implementation reuses CodexBar's existing token-account architecture rather than inventing a separate Codex-only account system.

That direction was chosen because:
- token account storage already exists
- token-account selection / show-all behavior already exists
- Codex already had some token-override-aware logic
- reusing existing abstractions keeps the implementation smaller and easier to reason about

## Implementation strategy
The basic route is:
1. Add Codex to the token-account support catalog.
2. Reuse token-account overrides to fetch Codex usage per stored account.
3. Thread enough account identity through the fetch pipeline to distinguish results in the UI.
4. Store per-account snapshots separately instead of collapsing everything into one Codex snapshot.
5. Render those account-scoped snapshots together in the Codex menu.
6. Add sorting and refresh behavior needed to keep the multi-account view usable.

This means the feature is built by making Codex participate in the existing token-account flow, not by creating a completely separate multi-account subsystem.

## Current scope
This implementation is intentionally limited.

Included:
- multi-account Codex support using the existing token-account path
- stacked per-account Codex cards in the menu
- account identity/context in the menu
- sorting for multi-account Codex display

Not included:
- aggregated totals across accounts
- broader refactors of global Codex/OpenAI dashboard state
- generalized multi-account support across every provider

## Related research
I also looked at `lukilabs/craft-agents-oss`, because it already supports multiple ChatGPT/Codex accounts.

The useful conclusion from that comparison was that it solves a **different layer** of the problem.

Its model is based on:
- multiple named LLM connections
- separate auth per connection
- OAuth-based ChatGPT/Codex auth

CodexBar's model here is different:
- provider usage snapshots
- quota / credits tracking
- menu-card rendering
- per-provider account display

So that project was useful as inspiration, especially for future OAuth-backed ideas, but not as a drop-in implementation source for this codebase.

## Possible improvements
Potential future improvements include:
- allowing manual labels for accounts instead of relying only on detected account identity/context
- exploring richer OAuth-backed multi-account Codex support
- evaluating whether the same general pattern should be extended to other providers that fit the token-account/session model
