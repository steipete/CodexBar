# Koliko (ne)vrijedi screenshot potrošnje — demonstracija

> Kratki ogled o tome zašto je screenshot "potrošnje na AI-u" iz menu-bar
> aplikacije **trivijalno lažirati**, i kako razlikovati lažirano polje od
> stvarnog signala koji se čita s diska.

## Povod

Povod je [ovaj tweet](https://x.com/steipete/status/2055346265869721905) koji
prikazuje CodexBar (macOS menu-bar app, čiji je ovo fork) s impresivnim
brojkama na **OpenAI API** kartici:

| Polje | Iznos sa screenshota |
|---|---|
| Today | $19.985,84 |
| 7d spend | $249.661,09 |
| 30d spend | $1.305.088,81 |
| 30d tokens | 603B |
| 30d requests | 7,6M |

Brojke djeluju nestvarno velike, pa se nameće pitanje: **je li to stvarna
potrošnja, ili marketinški hook?** Cilj ovog dokumenta nije nikoga prozivati —
aplikacija je tehnički odlična — nego pokazati jednu jednostavnu istinu:

> **Brojka na takvom screenshotu nije dokaz ni o čemu. To je samo lokalno
> renderirani UI. Tko kontrolira izvor podataka, kontrolira screenshot.**

## Kako podaci teku kroz aplikaciju

CodexBar za svaki provider ima isti tok:

```
fetch strategija  →  UsageSnapshot (obični Double brojevi)  →  SwiftUI kartica
```

Za Claude provider, izvor podataka bira se u
`Sources/CodexBarCore/Providers/Claude/ClaudeProviderDescriptor.swift`, funkcija
`resolveStrategies(...)`. Ona vraća listu strategija (OAuth, Web, Admin API,
CLI), a pipeline uzme prvu dostupnu. Rezultat je `UsageSnapshot` — struktura
običnih brojeva — koju onda `MenuCardView` samo iscrta.

Anthropic ni OpenAI ni na koji način ne "potpisuju" te brojke. Ne postoji
provjera autentičnosti. Ako podmetneš vlastiti snapshot, kartica će pokazati što
god mu kažeš.

## Što je napravljeno za demonstraciju

Dodan je lokalni, **env-gated i potpuno reverzibilan** demo izvor podataka:

- `Sources/CodexBarCore/Providers/Claude/ClaudeDemoUsage.swift` — generator koji
  sintetizira `ClaudeAdminAPIUsageSnapshot` s napuhanim iznosima. Kao baseline
  uzima **točne brojke s tweeta** i množi ih multiplikatorom.
- `ClaudeDemoFetchStrategy` (u `ClaudeProviderDescriptor.swift`) + rana grana u
  `resolveStrategies(...)` — zaobilazi **sve** provjere kredencijala. Ne treba
  nikakav Anthropic ključ.

Aktivacija (provjerava se kod svakog fetcha):

1. Env varijabla `CODEXBAR_DEMO_CLAUDE_SPEND` (vrijednost = multiplikator), ili
2. Marker datoteka `~/.codexbar-demo-claude` (sadržaj = multiplikator).

Marker datoteka je pouzdaniji put jer se app pokreće preko `open`, koji ne
nasljeđuje shell okolinu.

Uz multiplikator **3** ("trošim 3× više od originalnog screenshota, i to u
Anthropic Claude kreditima") kartica prikazuje:

| Polje | Demo iznos | = 3 × tweet |
|---|---|---|
| Today | $59.957,52 | 3 × 19.985,84 |
| 7d spend | $748.983,27 | 3 × 249.661,09 |
| 30d spend | $3.915.266,43 | 3 × 1.305.088,81 |
| 30d tokens | 1,81T | 3 × 603B |
| Top model | claude-opus-4-8 | — |

Brojke prolaze kroz **isti pravi pipeline** kao i stvarni podaci (potvrđeno i
preko ugrađenog CLI-ja `CodexBarCLI usage --provider claude`), a ne kroz neki
hardkodirani UI mock. Drugim riječima: za ~30 minuta u codebaseu može se
napisati koja god brojka.

![Overview kartica + dashboard s napuhanim Claude podacima](images/01-overview-dashboard.png)

## Ključna distinkcija: lažirano polje vs. stvarni signal s diska

Najzanimljiviji dio je da u **istom** popoveru istovremeno postoje i lažni i
stvarni podaci:

| Što vidiš | Izvor | Status |
|---|---|---|
| Plava kartica: `Today $59.957`, `30d $3.915.266`, bar chart | demo Admin-API injekcija | **LAŽNO** |
| `Est. total (Last 30 days): $4.933,83` + breakdown po modelima | `CostUsageScanner` čita `~/.claude/projects/**/*.jsonl` | **STVARNO, s diska** |

Donji dio (`Est. total` + razrada po modelima, npr. `claude-fable-5`,
`claude-opus-4-8`, `claude-haiku-4-5`) dolazi iz potpuno **odvojenog**
podsustava:

- `Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner+Claude.swift`
  skenira lokalne session logove (`~/.claude/projects` i
  `~/.config/claude/projects`), zbraja tokene po modelu po danu, i množi ih s
  javnim API cjenovnikom (`CostUsagePricing.claudeCostUSD`).
- Redak `Est. total (%@): %@` iscrtava se u
  `Sources/CodexBar/CostHistoryChartMenuView.swift`.

Moja demo injekcija **nije dotaknula** taj scanner. Najjači dokaz da su to dvije
različite stvari: breakdown pokazuje **`claude-fable-5`** — model koji
sintetički generator **nikad ne proizvodi** (generira samo opus/sonnet/haiku) —
i iznos je realnih ~$4,9K, a ne izmišljenih $3,9M.

![Cost history detalj sa stvarnim Est. total iznosom](images/02-cost-history-detail.png)

### Što taj stvarni broj znači

`Est. total: $4.933,83` = **koliko bi stvarna lokalna potrošnja tokena KOŠTALA
da se plaća po pay-as-you-go API cjenovniku.** To je hipotetski (notional)
iznos.

Korisnik je na **Claude Max paušalu (~90 EUR/mj)** s daily/weekly limitima — i
**ne plaća tih $4.933**. Plaća 90 EUR. Ta brojka zapravo pokazuje **koliku
vrijednost izvlači iz paušala**: ~$4.933 API-ekvivalenta za 90 EUR znači da se
Max plan ovaj mjesec isplatio ~50×.

> Napomena: to je *procjena*. Scanner primjenjuje cjenovnik iz lokalne pricing
> tablice na tokene iz logova, pa cache pricing i nove cijene modela mogu malo
> odstupati. Ali baza (broj tokena po modelu) je 100% stvarna potrošnja s diska.

## Zaključak

U istom kadru sad stoje jedno **lažirano** polje ($3,9M, izmišljeno u pola sata)
i jedno **stvarno** ($4.933, iz vlastitih logova). To točno ilustrira poantu:

- Headline "spend" brojke u ovakvim aplikacijama su trivijalno lažabilne —
  nema potpisa, nema verifikacije, samo lokalni `Double`.
- Jedini realni signal (`Est. total` iz lokalnih logova) je skroman i temeljen
  na stvarnoj potrošnji.

Screenshot velike potrošnje, sam za sebe, **ne dokazuje ništa**.

## Kako reproducirati / ugasiti

```bash
# Uključi demo (multiplikator 3):
echo 3 > ~/.codexbar-demo-claude
# pa u aplikaciji: Refresh (⌘R)

# Promijeni faktor:
echo 10 > ~/.codexbar-demo-claude    # pa Refresh

# Ugasi demo (vraća prave podatke, bez rebuilda):
rm ~/.codexbar-demo-claude           # pa Refresh
```

## Napomena o privatnosti screenshotova

Screenshotovi u `images/` su procijenjeni prije objave: ne sadrže API ključeve,
tokene, lozinke ni privatne putanje. Jedini PII je autorov Gmail (ionako javan u
git history). Terminalski sadržaj je u niskoj rezoluciji i nečitljiv. Sigurni za
javnu objavu.
