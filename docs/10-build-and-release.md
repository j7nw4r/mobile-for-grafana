# 10 — Build and release

Xcode project layout, code signing, TestFlight, App Store submission, and
CI. This doc is light on detail until we get closer to Phase 8 (TestFlight)
— the early phases don't need most of this. Captured here so the path is
known, not so we execute it on day one.

## Xcode project

A single Xcode project at the repo root: `GrafanaViewer.xcodeproj`.

**Why a project and not a workspace + Swift Package?** A single-target app
with zero third-party SPM dependencies doesn't need workspace overhead.
If we add SPM dependencies later we can resolve them inside the project
without a workspace; if dependencies grow large enough to warrant
multi-target separation we'll migrate then.

### Targets

| Target | Purpose |
| --- | --- |
| `GrafanaViewer` | The iOS app |
| `GrafanaViewerTests` | Unit tests |
| `GrafanaViewerUITests` | (Phase 8 onward) UI smoke tests |

### Schemes

| Scheme | Configuration | Use |
| --- | --- | --- |
| `GrafanaViewer` | Debug | Development on simulator + device |
| `GrafanaViewer (Release)` | Release | Local archive smoke-test |
| `GrafanaViewer (BetaTest)` | Release + `BETA=1` | TestFlight builds |

The `BetaTest` configuration sets a compile-time flag `BETA` we can read
to enable in-app "Send feedback" mailto link, slightly more verbose
logging, and a TestFlight badge in Settings.

### Bundle identifier

`com.grafanaviewer.app` (tentative — will be confirmed with the App Store
Connect account holder when registering).

### Capabilities + entitlements

- Keychain Sharing — disabled (single-app access only).
- App Sandbox — N/A on iOS.
- Network — outbound only, no specific entitlement required.
- No push notifications, no background fetch, no widgets, no Siri, no
  Sign in with Apple in v1.

### Info.plist essentials

- `LSApplicationCategoryType` — `public.app-category.developer-tools` (no
  better fit; "developer-tools" reads as observability-ish).
- `NSAppTransportSecurity` — leave defaults. We don't allow arbitrary
  HTTP, but we *do* need to allow self-signed certificates for self-
  hosted Grafana behind enterprise CAs. **Open question for the doc:**
  do we ship with a UI for accepting a self-signed cert pin, or just
  document "configure your enterprise CA in iOS settings"? Leaning
  toward the latter — phone-side cert pinning is gnarly UX.
- `UIRequiredDeviceCapabilities` — `["arm64"]`.
- `UISupportedInterfaceOrientations` — portrait only on phone; portrait +
  landscape on iPad if we ever ship an iPad build (not v1).
- `UILaunchScreen` — a SwiftUI launch view, dark background, app icon
  centered.

## Code signing

We use **`fastlane match`** with a private Git repo to share certificates
and provisioning profiles among devs and CI. This mirrors the reference
ArgoCD repo's setup.

### Initial setup (one-time, by the maintainer)

```bash
fastlane match init                # create the match repo
fastlane match development         # generate dev cert + profile
fastlane match adhoc               # for TestFlight builds (or appstore)
fastlane match appstore            # for App Store submissions
```

The match Git repo lives at `git@github.com:<owner>/grafanaviewer-match.git`
(private). Match's encryption passphrase is stored in 1Password (org
vault).

### Per-dev workflow

A new contributor runs:

```bash
fastlane match development --readonly
```

…which fetches the dev cert + profile from match. They never `match nuke`,
never `match force` — read-only access is enough for daily development.

### CI signing

GitHub Actions checks out the match repo with a deploy key, decrypts with
the passphrase from secrets, and signs the archive. Detailed in the CI
section below.

## TestFlight

### Build + upload

`fastlane/Fastfile`:

```ruby
lane :beta do
  match(type: "appstore", readonly: true)
  build_app(
    scheme: "GrafanaViewer (BetaTest)",
    export_method: "app-store",
    output_directory: "build/"
  )
  upload_to_testflight(
    skip_waiting_for_build_processing: true,
    changelog: read_changelog
  )
end
```

Run via `bundle exec fastlane beta` locally or via CI on a tag.

### Changelog source

We read `CHANGELOG.md`'s top section between the first `## ` and the
second `## `. Format:

```markdown
## 1.0.0-beta.3

- Fix: silence creation no longer requires an "instance" matcher
- New: long-press on timeseries chart shows value at timestamp
```

### Test groups

- **Internal** — the dev team. Auto-distributed on every successful
  TestFlight upload.
- **External (closed beta)** — manually invited Grafana operators.
  Distribution gated until App Review approves each beta build.

## App Store submission (v1.0.0)

Once TestFlight has shaken out for a few weeks:

```bash
bundle exec fastlane release
```

…which runs an `app-store` build and submits via App Store Connect API.

### Metadata

`fastlane/metadata/` holds the canonical metadata:

| File | Contents |
| --- | --- |
| `en-US/name.txt` | "Mobile for Grafana" (working title) |
| `en-US/subtitle.txt` | "Read your Grafana from your phone" |
| `en-US/description.txt` | Long description — emphasize self-hosted, viewing-focused |
| `en-US/keywords.txt` | "grafana, monitoring, observability, dashboards, alerts, devops, sre" |
| `en-US/marketing_url.txt` | Project website URL |
| `en-US/privacy_url.txt` | Privacy policy URL |
| `en-US/support_url.txt` | GitHub issues URL |
| `en-US/release_notes.txt` | What's new in this version |

Screenshots live in `fastlane/screenshots/en-US/iPhone-67/` (iPhone 6.7"
device class, App Review's required size). Generated from a real Grafana
demo instance — not faked, not hand-drawn.

### App Review prep

The submission must include:

- **Demo account credentials** to a public-ish Grafana for the reviewer
  to use. We'll spin up a `grafana.demo.grafanaviewer.app` with a
  read-only token and provide it in the App Review notes.
- **Privacy disclosures**: what data we collect (none, beyond what the
  user types in), what's stored (server URL + credential in Keychain),
  third parties (none), tracking (none).
- **Demo video** (optional but reduces reject-rate) showing the app
  login + dashboard view flow.

## Privacy policy + support pages

A small website mirroring the reference repo's `website/` directory:

```
website/
├── index.html         landing page
├── privacy.html       privacy policy
├── support.html       support / contact
└── assets/
```

Hosted on GitHub Pages from a `gh-pages` branch (or main `/website` —
whichever's easier). Free, no infra.

### Privacy policy essentials

We collect: nothing. We transmit: the user's chosen server URL and
credentials, to that user's chosen Grafana, over HTTPS. No analytics,
no crash reporting, no third-party SDKs.

This is short enough to fit in one screen. We write it accordingly.

## CI

GitHub Actions, modeled on the reference repo's
`.github/workflows/ios-build.yml`.

### `.github/workflows/ci.yml`

Triggered on PRs. Runs:

1. `bundle install` (Ruby for fastlane).
2. `xcodebuild -scheme GrafanaViewer test -destination 'platform=iOS Simulator,name=iPhone 15'`.
3. (Optional later) SwiftLint.

Does not sign or upload. Just verifies the code compiles and tests pass.

### `.github/workflows/ios-beta.yml`

Triggered on tags matching `v*-beta.*`. Runs:

1. Checkout code.
2. Check out match repo via deploy key.
3. `bundle exec fastlane beta`.
4. Post a Slack notification when the build is on TestFlight (Phase 8+).

Secrets needed:
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_CONTENT` (base64)
- `MATCH_PASSWORD`
- `MATCH_GIT_PRIVATE_KEY` (deploy key for the match repo)

### `.github/workflows/ios-release.yml`

Triggered on tags matching `v[0-9]+.[0-9]+.[0-9]+` (no `-beta`). Same as
beta but uses `fastlane release` instead.

## Asset catalog + icons

`Assets.xcassets`:

```
Assets.xcassets/
├── AppIcon.appiconset/        ← all the iOS icon sizes
├── AccentColor.colorset
├── Colors/
│   ├── background.colorset
│   ├── surface.colorset
│   ├── primary.colorset
│   ├── textPrimary.colorset
│   ├── textSecondary.colorset
│   ├── textMuted.colorset
│   ├── alertCritical.colorset
│   ├── alertWarning.colorset
│   ├── alertOk.colorset
│   └── threshold.{green,yellow,red,orange,blue,purple}.colorset
├── Images/
│   └── grafana-logo.imageset   ← used on Login
```

Each color set has a dark + light variant. The threshold colors mirror
Grafana's web palette so users see roughly the same hues.

### App icon

A simple flat icon. The reference repo uses an "Argo octopus" — we want
something distinct. Open task for design; placeholder is the Grafana
orange "G" mark with a small "M" overlay (where "M" suggests mobile).
Replace before App Review.

## Versioning

- Marketing version: SemVer (`1.0.0`).
- Build number: monotonically incrementing integer (`1`, `2`, `3`, …)
  per upload. `fastlane increment_build_number` runs automatically in
  the `beta` and `release` lanes.

## Storage of secrets

- App Store Connect API key — in 1Password org vault, and in GitHub
  Actions secrets for CI.
- Match passphrase — same.
- Match repo deploy key — same.

No secrets in the repo, ever. `.gitignore` covers `fastlane/.env*` so a
developer's local `.env.local` (containing nothing sensitive, just
overrides like `MATCH_GIT_BRANCH=local-experiments`) doesn't get
committed.

## Phase 8 deliverables

Concretely, by the end of Phase 8 in [`11-roadmap.md`](11-roadmap.md):

- [ ] `GrafanaViewer.xcodeproj` with three schemes, two configurations.
- [ ] Asset catalog with app icon (any version) and color tokens.
- [ ] `fastlane/Fastfile`, `Appfile`, `Matchfile`.
- [ ] Match repo created + populated.
- [ ] `.github/workflows/ci.yml` passing on a PR.
- [ ] `.github/workflows/ios-beta.yml` producing a TestFlight build on
      tag push.
- [ ] First TestFlight build with internal testers.
- [ ] Privacy policy + support page live.
- [ ] Closed external beta invitations sent.

App Store submission is *not* a Phase 8 deliverable — it follows after
external beta feedback shakes out.

## Open question to resolve here

> Self-signed certificates + enterprise CAs — do we ship a UI for cert
> trust, or rely on iOS system settings?

**Rely on iOS system settings** (configure the CA in
*Settings → General → VPN & Device Management → Configuration Profiles*).
Reasons:

- Adding cert-pinning UI on a phone is a real footgun (a user who
  accepts a malicious cert has compromised their Grafana credential).
- Enterprise environments that *need* a self-signed CA already have an
  MDM-installed configuration profile that handles it for users.
- We document this in the Help section of the Login screen and on the
  support page.

We will revisit if external beta feedback shows real friction here.

---

Onward: [`11-roadmap.md`](11-roadmap.md).
