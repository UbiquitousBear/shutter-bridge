# CI and TestFlight

Nov 1, 2026 (updated 8 Nov for the production app) · How the apps get built, tested and onto the iPhone. Researched against Apple's and GitHub's
documentation on this date; the claims that rest only on forum reports are marked.

## Summary

| Job | Where | Trigger | Secrets |
| --- | --- | --- | --- |
| Every package's `swift build` and `swift test` on Linux | GitHub Actions, `ubuntu-latest` in `swift:6.4-noble` (`.github/workflows/packages-linux.yml`, one matrix job per package; replaced `ptpkit.yml` on 8 Nov) | PRs touching `Packages/` | none |
| App build (unsigned, iOS Simulator and device) + every package's tests in the iOS Simulator | GitHub Actions, `xcode-27` runner (`.github/workflows/app.yml`) | PRs touching `Packages/` or `App/` | none |
| Spike compile check + PTPKit tests on macOS | GitHub Actions, `xcode-27` runner (`.github/workflows/spike-build.yml`), kept until the spike is retired | PRs touching `Spike/` or `Packages/PTPKit` | none |
| Archive → TestFlight (internal testing), **now**: the production app by default, or the spike | GitHub Actions, `xcode-27` runner (`.github/workflows/testflight.yml`, "App to TestFlight") | manual only, approved by Shamil per run | App Store Connect API key, in the `testflight` environment only |
| Archive → TestFlight (internal testing), **later** | **Xcode Cloud** | manual, or pushes to a branch you choose | none in the repo; Apple manages signing |

**Why GitHub for TestFlight first.** Shamil has no Mac until Thu 5 Nov, and Xcode Cloud's onboarding needs Xcode
on a Mac, while the spike's wired days need the app on the iPhone from day 1. Everything the GitHub route needs
can be set up from a phone's browser (below). On 8 Nov Shamil pointed the same route at the production app, so
TestFlight builds of Shutter Bridge start in Iteration 1 rather than waiting for Xcode Cloud. Once Xcode Cloud is
set up for the app it uploads, revoke the API key and delete the `testflight` environment.

**Why Xcode Cloud for TestFlight later.** It is the proposal's CI decision, it signs with Apple-managed certificates
so no signing key or App Store Connect API key ever sits in this **public** repository, and the Apple Developer
Program includes 25 compute hours a month (paid tiers from US$49.99 for 100 h). At an estimated 8–12 minutes per
archive-only build (not yet measured), that is well over 100 builds a month.

**Why GitHub's `xcode-27` runner too.** It is free and unlimited for public repositories (the standard label;
`xcode-27-xlarge` is billed even on public repos), it has Xcode 27.0, 27.1 (default) and the 27.2 release
candidate, and it gives every PR a real Xcode 27 compile of the spike, which nothing else in the repo can do.
The image is still marked *preview*: no SLA, occasional queueing, weekly changes.

## What the repo already does for TestFlight

For the spike:

- **App icon:** `Spike/Resources/Assets.xcassets/AppIcon.appiconset` (one opaque 1024 px PNG, no Sony marks).
  Uploads without one fail validation (ITMS-90713, missing `CFBundleIconName`).
- **Privacy manifest:** `Spike/Resources/PrivacyInfo.xcprivacy` declares the "required reason" APIs the spike
  uses: UserDefaults (CA92.1), disk space (E174.1, 85F4.1), file metadata (C617.1). Apple's article says apps
  without one aren't accepted; its April 2024 news post limited the hard block to third-party SDKs for now. Either
  way, the manifest avoids an ITMS-91053 warning or rejection.
- **Entitlements survive generation:** `project.yml` references `Spike.entitlements` through
  `CODE_SIGN_ENTITLEMENTS`. XcodeGen's `entitlements: path:` form rewrote the file as an empty dictionary on every
  `make spike`, silently dropping Hotspot Configuration from every build. The GitHub job checks this on every PR,
  and `Spike/ci_scripts/ci_post_xcodebuild.sh` fails an Xcode Cloud archive that lacks the entitlement.
- **Build numbers:** `CFBundleVersion` comes from `CURRENT_PROJECT_VERSION`. Xcode Cloud sets it per build
  (counting from 1); every upload needs a new number.
- **Export compliance:** `ITSAppUsesNonExemptEncryption = false` (only OS-provided cryptography: HTTPS, CryptoKit
  hashing, WPA2 via NEHotspotConfiguration), so TestFlight skips the questionnaire.
- **Project generation in CI:** `Spike/ci_scripts/ci_post_clone.sh` installs XcodeGen and generates the git-ignored
  project. Xcode Cloud only runs scripts from a `ci_scripts` folder next to the project, hence `Spike/ci_scripts/`.

For the production app (`App/ShutterBridge.xcodeproj`, committed, so nothing is generated in CI):

- **App icon:** `App/ShutterBridge/Assets.xcassets/AppIcon.appiconset` (one 1024 px PNG), named by
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`; `testflight.yml` fails before the upload if the archived app has
  no `CFBundleIconName` (ITMS-90713; on iOS it sits under `CFBundleIcons` › `CFBundlePrimaryIcon`) or no compiled
  asset catalogue.
- **Privacy manifest:** `App/ShutterBridge/PrivacyInfo.xcprivacy` (UserDefaults, disk space, file timestamps).
- **Export compliance:** `ITSAppUsesNonExemptEncryption = false` in `App/Info.plist`.
- **Versions:** `MARKETING_VERSION` 0.1 and `CURRENT_PROJECT_VERSION` 1 in the project; `Info.plist` reads both from
  build settings, so CI sets the build number.
- **No entitlements in Iteration 1:** the app has no entitlements file, so nothing checks for one. Hotspot
  Configuration (Iteration 3) and Multicast Networking get one, and a check like the spike's, when a build first
  signs with them.

## Xcode Cloud: one-time setup (Shamil; about 30 minutes, needs the Mac)

These steps live in Apple's and GitHub's consoles, not in git. An agent can't do them. Steps 1–4 are the same as
for the GitHub route below; skip the ones already done.

1. **Agreements.** App Store Connect → Business: accept any pending agreements (Account Holder).
2. **App ID with capabilities.** On the Mac: `make spike && make open`, set your team in Signing & Capabilities,
   and run the app on the iPhone once. Automatic signing registers `net.shamil.shutter-bridge.spike` with
   Hotspot Configuration. Check in the developer portal (Certificates, IDs & Profiles → Identifiers) that the
   capability is ticked: cloud signing during export will not add capabilities to an App ID.
3. **App record.** App Store Connect → Apps → + → New App: iOS, name e.g. "Shutter Bridge Spike" (don't spend the
   product name; no Sony marks), primary language English (UK), bundle ID
   `net.shamil.shutter-bridge.spike`, SKU `shutterbridge-spike`. The bundle ID can't change after the
   first upload. Apple asks that apps be created on the website, not through the API.
4. **Internal testers.** TestFlight → Internal Testing → + group "Spike", add yourself. Internal testing needs no
   Beta App Review; builds expire after 90 days.
5. **Check the archive locally (optional but cheap).** `xcodebuild -project Spike/Spike.xcodeproj
   -describeAllArchivableProducts -json` must list Spike (Xcode Cloud uses the same query), then Product →
   Archive. If you also upload from the Organizer, note its build number: Xcode Cloud starts at 1 and a duplicate
   is rejected, so set Xcode Cloud's next build number above it (App Store Connect → the app → Xcode Cloud →
   Settings → Build Number).
6. **Create the Xcode Cloud workflow.** In Xcode: Report navigator → Cloud → Get Started (or Integrate → Create
   Workflow), choose the Spike product and your team, then Grant Access. The browser opens App Store Connect to
   link GitHub: install Apple's Xcode Cloud GitHub app on **only** `UbiquitousBear/shutter-bridge`. The repo
   being public changes nothing; logs and builds stay private in App Store Connect.
7. **Workflow settings** (Integrate → Manage Workflows, or App Store Connect → the app → Xcode Cloud):
   - Name: Spike to TestFlight.
   - Environment: the Xcode 27.x that matches your Mac (27.1; 27.2 once listed); macOS: recommended.
   - Start condition: manual, or Branch Changes on the branches you want; add Files and Folders → ignore `docs/`
     so doc-only pushes don't spend compute.
   - Actions: Archive (iOS), deployment preparation **TestFlight (Internal Testing Only)**. Optionally Test
     (iOS Simulator, a current iPhone), which runs PTPKitTests through the Spike scheme.
   - Post-action: TestFlight Internal Testing → group "Spike" (Xcode Cloud builds are never added to groups
     automatically).
8. **First build.** Start it and read the logs in order: `ci_post_clone` (brew install xcodegen, xcodegen
   generate), Resolve Package Dependencies, Archive, `ci_post_xcodebuild` ("entitlements OK"), export and upload.
   Then install from the TestFlight app on the iPhone.

Record the workflow settings you chose in this file when they differ from the above.

### If the first Xcode Cloud build fails

- **"a resolved file is required when automatic dependency resolution is disabled"** at Resolve Packages: add
  `xcodebuild -resolvePackageDependencies -project Spike.xcodeproj -scheme Spike` to `ci_post_clone.sh` after
  `xcodegen generate`. (PTPKit is a local package with no dependencies, so this is unlikely.)
- **No products found / scheme missing:** XcodeGen writes shared schemes; check `ci_post_clone` ran at all (it
  must be in `Spike/ci_scripts/`, executable, with a shebang).
- **Onboarding fails with "no apps":** create the App Store Connect app record (step 3) first.
- **"Archive is missing the Hotspot Configuration entitlement":** the App ID lacks the capability (step 2), or
  `project.yml` regressed to XcodeGen's `entitlements:` key.

Apple warns that generated projects "may fail" in Xcode Cloud; its own docs generate files (CocoaPods) in
post-clone scripts, and the first build is the real test.

## The GitHub compile check

`.github/workflows/spike-build.yml` runs on `runs-on: xcode-27` with `DEVELOPER_DIR` pinned to Xcode 27.1:

1. `brew install xcodegen`, `make spike`.
2. Fails if `Spike/Spike.entitlements` changed during generation or lost Hotspot Configuration.
3. `xcodebuild build -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`: a full device compile with
   no signing.
4. `swift test` for PTPKit on macOS (the Linux job covers the same tests on Linux).

It has `permissions: contents: read` and no secrets, so it is safe on PRs from forks. Move `DEVELOPER_DIR` to
`Xcode_27.2.app` once the image carries the 27.2 release (it currently symlinks the release candidate there;
App Store Connect accepts builds from both).

## The production app's checks (from 8 Nov)

The workspace (backlog section 0) brought two workflows, both without secrets:

- **`packages-linux.yml`:** one job per package under `Packages/`, `swift build` then `swift test` in `swift:6.4-noble`.
  Apple-only code is behind `#if canImport(...)`, so this covers each package's transport-neutral part. A new package
  is added to the matrix by hand (BLEKit when its branch lands).
- **`app.yml`:** on the `xcode-27` runner with `DEVELOPER_DIR` pinned as in `spike-build.yml`, it builds
  `App/ShutterBridge.xcodeproj` unsigned for `generic/platform=iOS Simulator` (Debug) and `generic/platform=iOS`
  (Release), then runs `xcodebuild test` in every folder under `Packages/` that has a `Package.swift`, against the
  first iPhone simulator on the newest iOS runtime that the pinned Xcode can run (from 27.0, the deployment target,
  up to its iOS Simulator SDK; picked at run time from `xcrun simctl list -j`). This is where the code behind
  `canImport` is compiled and tested. The project has no remote packages, so there is no `Package.resolved` to
  commit; the first remote dependency (none is planned: Apple frameworks only) would need one.

If a ruleset on `main` requires status checks by name, replace the old `ptpkit.yml` check with these jobs.

**Bundle ID and app record.** The project sets `PRODUCT_BUNDLE_IDENTIFIER` to `net.shamil.shutter-bridge`, with
`DEVELOPMENT_TEAM` empty and automatic signing, as Shamil decided on 8 Nov for the production app (a new App ID and
app record named "Shutter Bridge", because the spike's are named for the spike). Shamil creates both on the Mac before
the first upload; the bundle ID can't change after it. From 8 Nov `testflight.yml` uploads the production app by
default (below).

## TestFlight from GitHub Actions (no Mac needed)

`.github/workflows/testflight.yml` ("App to TestFlight") archives an app on the `xcode-27` runner, signs it at
export with Apple-managed certificates and uploads it to TestFlight for internal testing. It runs only when started
by hand and approved, and only from `main`. Its `app` input picks which:

| `app` | Project and scheme | Bundle ID | App Store Connect record |
| --- | --- | --- | --- |
| `production` (default; Shamil, 8 Nov) | `App/ShutterBridge.xcodeproj`, `ShutterBridge` | `net.shamil.shutter-bridge` | "Shutter Bridge" |
| `spike` | `Spike/Spike.xcodeproj` (generated with XcodeGen in the job), `Spike` | `net.shamil.shutter-bridge.spike` | "Shutter Bridge Spike" |

The workflow was called "Spike to TestFlight" until 8 Nov. Its file is still `testflight.yml`, on purpose: the
`testflight` environment, any ruleset or required check that names the file, and the run numbers (the build
numbers, below) all follow the file, not the display name. Both apps use the same team API key.

Iteration 1 uploads the production app for Shamil's bench iPhone (the thin Browse grid with *Copy as JPEG* first;
backlog, section 6). Xcode Cloud stays the long-term route, and Iteration 2's internal TestFlight date (15 Jan
2027) stands for the wider tester group.

### One-time setup from a phone or any browser (about 45 minutes)

Use Safari's "Request Desktop Website" for the Apple pages. Steps 1–7 are the spike's and are already done; the
production app needs only the short list after them.

1. **Agreements.** App Store Connect → Business: accept any pending agreements (Account Holder).
2. **App ID.** developer.apple.com → Account → Certificates, IDs & Profiles → Identifiers → + → App IDs → App:
   description "Shutter Bridge Spike", Bundle ID **Explicit** `net.shamil.shutter-bridge.spike`, and under
   Capabilities tick **Hotspot Configuration**. (Apple-managed signing at export creates the profile but will not
   register an App ID or change its capabilities, so this step is manual.) Later, once Apple grants it, add
   Multicast Networking here too; optionally Access Wi-Fi Information (see the runbook).
3. **App record.** App Store Connect → Apps → + → New App: iOS, name e.g. "Shutter Bridge Spike" (don't spend the
   product name; no Sony marks), primary language English (UK), bundle ID `net.shamil.shutter-bridge.spike`, SKU
   `shutterbridge-spike`, Full Access. The bundle ID can't change after the first upload.
4. **Internal testers.** The app → TestFlight → Internal Testing → + group "Spike", add yourself, and turn on
   automatic distribution so each new build reaches the group.
5. **Team API key.** App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys
   (if it shows Request Access, the Account Holder accepts that once) → Generate API Key → name
   "GitHub TestFlight (spike)", Access **Admin** (Apple-managed signing needs Admin) → Generate. Note the
   **Issuer ID** (top of the page) and the key's **Key ID**, then Download API Key: the `.p8` downloads once only.
   On an iPhone, rename it to `.txt` in Files so it opens as text to copy.
6. **GitHub environment.** Repository → Settings → Environments → New environment `testflight`:
   - Required reviewers: Shamil. Leave "Prevent self-reviews" off, or you can't approve your own runs.
   - Deployment branches and tags: Selected branches and tags → `main`.
   - Environment secrets: `ASC_KEY_ID` (Key ID), `ASC_ISSUER_ID` (Issuer ID), `ASC_PRIVATE_KEY` (the whole `.p8`
     text, BEGIN and END lines included).
   - Environment variable: `APPLE_TEAM_ID` (the 10-character Team ID: developer.apple.com → Account →
     Membership details).
7. **Merge PR #1.** A manually started workflow only shows under Actions once it is on the default branch.

### The production app: one-time setup (Shamil, before its first run)

The API key, the `testflight` environment and the agreements above are reused as they are. On the Mac or in a
browser:

1. **App ID.** Certificates, IDs & Profiles → Identifiers → + → App IDs → App: description "Shutter Bridge",
   Bundle ID **Explicit** `net.shamil.shutter-bridge`, and under Capabilities tick **Hotspot Configuration** and
   **Access Wi-Fi Information**. Iteration 1 signs with neither (the app has no entitlements yet), but cloud signing
   won't add a capability to an App ID later, so they're ticked now for Iteration 3. Tick **Multicast Networking**
   too when Apple grants the request (reference 7BDQ7FRVM8, submitted 8 Nov); it has to be on the App ID before any
   build that signs with it.
2. **App record.** App Store Connect → Apps → + → New App: iOS, name **"Shutter Bridge"**, primary language
   **English (UK)**, bundle ID `net.shamil.shutter-bridge`, SKU e.g. `shutterbridge`, Full Access. If the name is
   taken on the App Store, use a variant for the record (a short suffix; no Sony marks): the name under the icon is
   `CFBundleDisplayName`, which stays "Shutter Bridge". The bundle ID can't change after the first upload.
3. **Internal testers.** The app → TestFlight → Internal Testing → + a group (e.g. "Bench"), add yourself, and turn
   on automatic distribution.

### Running it

Actions → **App to TestFlight** → Run workflow (branch `main`, app `production` or `spike`, Xcode 27.1, archive
signing `adhoc`) → approve the `testflight` deployment when GitHub asks. The job checks the environment is complete,
then:

- **`production`:** reads the `ShutterBridge` target's bundle ID and `MARKETING_VERSION` from `xcodebuild
  -showBuildSettings` and stops unless the bundle ID is `net.shamil.shutter-bridge` (before the signing step, the only
  one given the secrets); archives with an ad-hoc signature; and stops before the upload unless the archived app has that bundle ID,
  that version, the run's build number and a `CFBundleIconName` with a compiled asset catalogue. No entitlement is
  required. No Homebrew or XcodeGen step runs.
- **`spike`:** as before 8 Nov: installs XcodeGen, generates the project, archives with an ad-hoc signature and
  fails if the archive lost the Hotspot Configuration entitlement.

Then it exports and uploads. After a few minutes of processing on Apple's side the build appears in the TestFlight
app.

**Build numbers.** `CFBundleVersion` is the workflow's run number and attempt (`12.1`, or `12.2` after a re-run), so
a re-run never collides with an upload that already happened. The two apps share the run counter, so each app's
numbers rise with gaps where the other app ran; App Store Connect only needs each number to be new and higher
within the app and version. When Xcode Cloud later builds either app, set its next build number above the last
GitHub run number (App Store Connect → the app → Xcode Cloud → Settings → Build Number), since Xcode
Cloud counts from 1.

### If the first run fails

- **Archive fails with a signing or provisioning error:** the ad-hoc archive flags
  (`CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic`) are what Xcode Cloud's own
  archive uses, but on GitHub runners they rest on a developer-forum report. Paste the log here. Two fallbacks:
  - Archive signing **`cloud`**: Xcode signs the archive with an Apple-managed development certificate using the
    same key. Apple only creates the development profile it needs if the team has at least one registered device,
    so first register the iPhone (developer.apple.com → Devices → +, with its UDID; without a Mac the UDID is
    hard to read, which makes this fallback awkward until Thursday).
  - Manual signing with an Apple Distribution certificate and an App Store profile, neither of which needs a
    device: generate the key and CSR with `openssl` (a-Shell on the iPhone has it), create the certificate and
    profile in the developer portal, and store them as two more environment secrets. The workflow needs a third
    mode for this; ask for it if the ad-hoc run fails.
- **Export fails with a permission or "cloud signing" error:** the key must be a Team key with the Admin role.
- **Export fails over a capability or profile:** check the App ID (spike: step 2, Hotspot Configuration ticked;
  production: its step 1, the App ID `net.shamil.shutter-bridge` exists).
- **Export fails with no app record found (production):** create the "Shutter Bridge" record (its step 2) first.
- **"CFBundleIconName is missing" (production):** the archive has no app icon, which App Store Connect would
  reject (ITMS-90713); check `ASSETCATALOG_COMPILER_APPICON_NAME` and the AppIcon set in the asset catalogue.
- **Upload rejected as a duplicate:** a build with that number already exists; start a new run.

### Security

The key can sign and upload apps and manage the account, so: it lives only in the `testflight` environment
(limited to `main`, approval per run, and the job refuses to run from any other branch); the workflow never runs
on pushes or pull requests, so a fork's code never sees it; the job uses no third-party actions (it checks out
the commit with plain git) and its token can only read the repository; the secrets reach only the step that
signs and uploads (the first step only learns whether each is set), where the `.p8` is written with owner-only
permissions to the runner's temp folder and deleted when the step ends; nothing prints it.

Two residual risks:
- **Anyone who can push to `main` can change the workflow** and then run it; the approval prompt names the
  workflow and branch but shows no diff. Add a ruleset on `main` (Settings → Rules → Rulesets → New branch
  ruleset, target the default branch) that requires a pull request and blocks force pushes and deletion, and
  before approving a run check its commit is one you merged.
- **`brew install xcodegen` runs unpinned third-party code** in the same job before the signing step, now only
  in `spike` runs: the production app's project is committed, so a `production` run has no Homebrew or XcodeGen
  step. Homebrew checks the bottle against its formula's checksum, so the exposure is a compromise of Homebrew
  itself; pinning a checksummed XcodeGen release, or generating the project in a separate job without the
  environment, would close it.

Revoke the key in App Store Connect when Xcode Cloud takes over, or at once if it might have leaked.

## Sources

- Apple: [Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts),
  [Setting up your project to use Xcode Cloud](https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud),
  [Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference),
  [Xcode Cloud pricing](https://developer.apple.com/xcode-cloud/),
  [Configuring your app icon](https://developer.apple.com/documentation/xcode/configuring-your-app-icon),
  [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api),
  [Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/),
  [Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers),
  [App Store Connect release notes](https://developer.apple.com/app-store-connect/release-notes/).
- GitHub: [runner-images README and the xcode-27 image](https://github.com/actions/runner-images),
  [Xcode 27 preview announcement (#14404)](https://github.com/actions/runner-images/issues/14404), runner pricing
  and environments in [github/docs](https://github.com/github/docs).
- XcodeGen 2.46.0 source (`Plist.swift`, `FileWriter.swift`) for the entitlements rewrite;
  [ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md) for package test targets.
