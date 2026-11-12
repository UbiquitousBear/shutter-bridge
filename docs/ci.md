# CI and TestFlight

Nov 1, 2026 (updated 8 Nov for the production app, and 9 Nov for the wireless switch-on) · How the apps get built, tested and onto the iPhone. Researched against Apple's and GitHub's
documentation on this date; the claims that rest only on forum reports are marked.

## Summary

| Job | Where | Trigger | Secrets |
| --- | --- | --- | --- |
| Every package's `swift build` and `swift test` on Linux | GitHub Actions, `ubuntu-latest` in `swift:6.4-noble` (`.github/workflows/packages-linux.yml`, one matrix job per package; replaced `ptpkit.yml` on 8 Nov; each job stops after 20 minutes, #105) | PRs touching `Packages/` | none |
| App build (unsigned, iOS Simulator and device) + the app's UI tests of the screens that need no camera in the iOS Simulator (I18) + every package's tests in the iOS Simulator (AppUI's one at a time, #109), built once from `AllPackages.xcworkspace` (12 Nov) | GitHub Actions, `xcode-27` runner (`.github/workflows/app.yml`) | PRs touching `Packages/` or `App/` | none |
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
- **Privacy manifest:** `App/ShutterBridge/PrivacyInfo.xcprivacy` declares UserDefaults (CA92.1: the import settings, the
  reminder's holds and the Wi-Fi cameras' records) and file timestamps (C617.1). The 9 Nov sweep removed disk space
  (E174.1): nothing in the app asks for free space, so declaring it was unused. Add an entry when a new
  required-reason API is called, with its reason code.
- **Export compliance:** `ITSAppUsesNonExemptEncryption = false` in `App/Info.plist`.
- **Versions:** `MARKETING_VERSION` 0.1 and `CURRENT_PROJECT_VERSION` 1 in the project; `Info.plist` reads both from
  build settings, so CI sets the build number.
- **Entitlements (from Iteration 3, W12; iCloud from 12 Nov):** `App/ShutterBridge.entitlements` holds Hotspot
  Configuration (joining the camera's network) and iCloud Documents for the container `iCloud.net.shamil.shutter-bridge`
  (staging in iCloud Drive), both ticked on the App ID. Like `Info.plist` it sits outside the synchronised `ShutterBridge/` folder, and the target
  points at it with `CODE_SIGN_ENTITLEMENTS = ShutterBridge.entitlements` in Debug and Release: the build setting, not a
  generator's entitlements key (the lesson of the spike's XcodeGen rewrite above). Two checks keep it there:
  `app.yml` fails a PR whose app target lacks the setting in either configuration, whose file holds anything but
  those keys, or whose Info.plist doesn't declare the same container (its unsigned builds can't see entitlements), and
  `testflight.yml` fails a production archive that isn't signed with them, before anything is uploaded. Multicast
  Networking stays out until Apple grants it and it is ticked on the App ID; adding it means ticking it first, then
  adding the key and updating `app.yml`'s list. *iCloud for staging* below records how iCloud was added.
- **Local Network:** `NSLocalNetworkUsageDescription` in `App/Info.plist`, asked at the first connection to the
  camera over Wi-Fi. No `NSBonjourServices` (the camera advertises no `_ptp._tcp`) and no ATS exception (the SSDP
  description fetch stays off).
- **Bluetooth and background keys (from W10, W13 and W17):** `NSBluetoothAlwaysUsageDescription`; the
  `bluetooth-central` and `fetch` background modes (state restoration for the camera's one Core Bluetooth central, and
  the app-refresh task that restarts the proximity scan); and `BGTaskSchedulerPermittedIdentifiers` for the continued
  import task and the proximity refresh task (`net.shamil.shutter-bridge.import`, `.proximity-refresh`). Registering a
  task identifier missing from that list raises an exception at launch, so the list must match the code. CI compiles
  the code that needs these keys but can't run it: the wireless path is first proved on the bench iPhone
  ([iteration-3-4-bench.md](iteration-3-4-bench.md)). No Live Activity key: the app has no Live Activity.

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
  is added to the matrix by hand (all eight are in it). Each job stops after 20 minutes: a package takes about two
  minutes, and a hung test run (a Swift Testing time limit can't end a wait that ignores cancellation) otherwise runs
  to GitHub's six-hour default (#105).
- **`app.yml`:** two jobs on the `xcode-27` runner with `DEVELOPER_DIR` pinned as in `spike-build.yml`. The `build`
  job checks the app target's entitlements wiring (see *Entitlements* above), which the unsigned builds can't, then
  builds `App/ShutterBridge.xcodeproj` unsigned for `generic/platform=iOS Simulator` (Debug) and
  `generic/platform=iOS` (Release). Then it runs the app's UI tests in the iOS Simulator (I18, decision D14 (c)):
  `xcodebuild test -scheme ShutterBridge -only-testing:ShutterBridgeUITests` on the simulator
  `pick-iphone-simulator.sh` picks, booted and waited for first, signed to run locally (ad hoc, no team or
  profile) rather than unsigned like the builds, with each test limited to three minutes
  (`-default-test-execution-time-allowance 180`) and the job's limit raised to 45 minutes for it. The
  `ShutterBridgeUITests` target (`App/ShutterBridgeUITests/`, a synchronised folder, in the shared scheme's
  TestAction) launches the Debug app with `-UITestFixture`, which composes it over an in-memory catalogue seeded with
  three job records, four staged JPEGs of one day and their marks (AppUI's `UITestFixture`, compiled into Debug builds
  only), with no camera discovery, no Wi-Fi or Bluetooth, Photos access read as allowed and staging on this iPhone in
  a temporary folder. It tests History, Settings and the Staging tab's cull screen; the "Browse → select → import →
  History" path needs a camera and waits for Iteration 5's review-build simulator mode, so no `PTPSimulator` is linked
  into the app. On a failure the step's raw lines (test, assertion, compile error) and the result bundle's failures
  are printed after it. Unsigned, the runner never started on the first run (12 Nov, #139: timed out waiting for
  the accessibility "AX loaded" notification), hence the ad-hoc signature and the boot beforehand. A failing UI test
  is run once more (`-retry-tests-on-failure`): on #139 the runner's Simulator left the app's threads unscheduled for
  about a minute, so waits timed out with the app idle; a test must still pass in one of its two runs, and the result
  bundle (with the screenshots) is kept as the `ui-tests-xcresult` artifact when the step fails. On the Mac, the
  same tests run from the ShutterBridge scheme's Test action. The `packages` job tests every package in the iOS
  Simulator through
  `AllPackages.xcworkspace` at the root, which holds the eight packages, and its shared `AllPackageTests` scheme,
  which lists their ten test targets: one `xcodebuild build-for-testing`, so each module and Apple's SDK modules are
  compiled once, then `test-without-building` twice, AppUI's tests with `-parallel-testing-enabled NO` and the rest as
  usual. The simulator is a standard iPhone model (an "iPhone 18" before an "iPhone 18 Pro", either before a model
  such as "iPhone Duo", which on 12 Nov showed the tabs as a side strip and stalled the UI tests) on the newest iOS
  runtime the pinned Xcode can run (from 27.0, the deployment target, up to its iOS Simulator SDK;
  `.github/scripts/pick-iphone-simulator.sh`, which lists every candidate in the log). Indexing while building
  is off (`COMPILER_INDEX_STORE_ENABLE=NO`; nothing on CI reads the index). Measured on 12 Nov: the packages job about
  9 minutes (#131), where testing each package one after another took about 33 and five parallel jobs that each
  compiled their packages' dependencies again took 12.6 for the slowest and five runners (#130). The label is free for
  public repositories; two jobs a run leave room under GitHub's five macOS jobs at once (unverified for this plan) for
  a second run. A new package must be added to the workspace and its test targets to the scheme (on the Mac, open the
  workspace and edit the scheme, or add the `FileRef` and `TestableReference` by hand):
  `.github/scripts/check-all-packages-workspace.py` fails the `packages` job until they are, and checks that AppUI's
  tests stay not parallelisable (#109: nearly all of them are main-actor bound and Swift Testing starts every test at
  once, so in the Simulator they queued for the main actor and the wait counted against each test's own time limit; a
  passing run of about 240 tests already had a slowest of 56 s against the 60 s limits). The `packages` job's limit
  is 30 minutes, the `build` job's 45. This is where the code behind `canImport` is compiled and tested, the wireless
  screens and live wiring (W16) included. The project has no remote packages, so there is no `Package.resolved` to
  commit; the first remote dependency (none is planned: Apple frameworks only) would need one. On the Mac,
  `open AllPackages.xcworkspace` gives every package in one window, and its *AllPackageTests* scheme runs every
  package's tests.

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
   **Access Wi-Fi Information**. From Iteration 3 (W12) the app signs with Hotspot Configuration, and cloud signing
   won't add a capability to an App ID, so a build without it ticked fails at signing or export. Access Wi-Fi
   Information is ticked but unused (only "only when on home Wi-Fi" would need it, and that is left out); ticking a
   capability the app doesn't sign with does no harm. Tick **Multicast Networking**
   too when Apple grants the request (reference 7BDQ7FRVM8, submitted 8 Nov); it has to be on the App ID before any
   build that signs with it.
2. **App record.** App Store Connect → Apps → + → New App: iOS, name **"Shutter Bridge"**, primary language
   **English (UK)**, bundle ID `net.shamil.shutter-bridge`, SKU e.g. `shutterbridge`, Full Access. If the name is
   taken on the App Store, use a variant for the record (a short suffix; no Sony marks): the name under the icon is
   `CFBundleDisplayName`, which stays "Shutter Bridge". The bundle ID can't change after the first upload.
3. **Internal testers.** The app → TestFlight → Internal Testing → + a group (e.g. "Bench"), add yourself, and turn
   on automatic distribution.

### iCloud for staging (prepared 11 Nov; the App ID got iCloud and the change was applied on 12 Nov)

*Applied:* Shamil created the container and ticked iCloud on the App ID with it assigned (12 Nov), and the change in
step 2 below landed as written. What follows is kept as the record of the steps and the reasons; step 3 is still to
run.

*Stage* (Shamil, 11 Nov) copies the camera's originals into the app's iCloud Drive folder (iCloud Drive › Shutter
Bridge › Staging › camera › capture day) when iCloud Drive is available, and into On My iPhone › Shutter Bridge ›
Staging otherwise. The code is in (`UbiquityStagingLocator` and `UbiquitousFileMover` in PhotosBridge, wired in
`LiveRoot`), but the entitlements are not: the App ID doesn't have iCloud yet, and a build that signs with iCloud
entitlements before the App ID has the capability and the container fails at signing or export (cloud signing at
export won't add a capability, as for Hotspot Configuration above). Until the follow-up below lands, the Info.plist
doesn't declare the container (`NSUbiquitousContainers`), so `UbiquityStagingLocator` doesn't ask iCloud at all, and
every build stages on this iPhone and says so (Settings and the Import screen: "iCloud Drive isn't available to
Shutter Bridge, so staging is on this iPhone."). It checks the Info.plist rather than asking iCloud because
`ubiquityIdentityToken` is commonly reported nil for an app without the entitlement, which would read as "iCloud Drive
is off or you're not signed in" to a person signed in with it on (unverified; bench S1).

**1. Portal (Shamil, before the follow-up PR).** Certificates, IDs & Profiles:
- Identifiers → the filter's **iCloud Containers** → + → description "Shutter Bridge", identifier
  **`iCloud.net.shamil.shutter-bridge`** (it can't be renamed or deleted afterwards).
- Identifiers → App IDs → `net.shamil.shutter-bridge` → Capabilities → tick **iCloud**, choose iCloud Documents (no
  CloudKit support is needed), **Configure** → tick `iCloud.net.shamil.shutter-bridge` → Save. The portal's labels have
  moved over the years (unverified against today's portal); on the Mac, Signing & Capabilities → + iCloud → iCloud
  Documents → the container does the same with automatic signing. Check the App ID in the portal afterwards either way.
- The App ID's existing profiles become invalid; the next export makes new ones with the API key, as now.

**2. The follow-up PR (exact changes; say in the PR that only CI compiled and signed it).**

`App/ShutterBridge.entitlements`: the three keys, beside Hotspot Configuration, and the header comment says iCloud
must be on the App ID with the container assigned:

```xml
	<!-- The app's iCloud Drive folder for staging (iCloud Documents, no CloudKit; Shamil, 11 Nov). -->
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array>
		<string>iCloud.net.shamil.shutter-bridge</string>
	</array>
	<key>com.apple.developer.icloud-services</key>
	<array>
		<string>CloudDocuments</string>
	</array>
	<key>com.apple.developer.ubiquity-container-identifiers</key>
	<array>
		<string>iCloud.net.shamil.shutter-bridge</string>
	</array>
```

No `com.apple.developer.icloud-container-environment` (CloudKit only) and no key-value store.

`App/Info.plist`: the folder Files shows as iCloud Drive › Shutter Bridge (with the app's icon; no Sony mark). The key
must equal the container identifier exactly; `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` stay, for
On My iPhone. This entry is also what turns on `UbiquityStagingLocator`'s lookup, so it lands in the same PR as the
entitlements, never before them:

```xml
	<key>NSUbiquitousContainers</key>
	<dict>
		<key>iCloud.net.shamil.shutter-bridge</key>
		<dict>
			<key>NSUbiquitousContainerIsDocumentScopePublic</key>
			<true/>
			<key>NSUbiquitousContainerName</key>
			<string>Shutter Bridge</string>
			<key>NSUbiquitousContainerSupportedFolderLevels</key>
			<string>Any</string>
		</dict>
	</dict>
```

`.github/workflows/app.yml`, the step *Entitlements are wired into the app target*: the expected dictionary becomes
the four keys, and a check that the Info.plist names the same container:

```python
          container = "iCloud.net.shamil.shutter-bridge"
          expected = {
              "com.apple.developer.networking.HotspotConfiguration": True,
              "com.apple.developer.icloud-container-identifiers": [container],
              "com.apple.developer.icloud-services": ["CloudDocuments"],
              "com.apple.developer.ubiquity-container-identifiers": [container],
          }
          # ... the existing comparison with App/ShutterBridge.entitlements, then:
          with open("App/Info.plist", "rb") as f:
              info = plistlib.load(f)
          entry = info.get("NSUbiquitousContainers", {}).get(container)
          if entry != {"NSUbiquitousContainerIsDocumentScopePublic": True,
                       "NSUbiquitousContainerName": "Shutter Bridge",
                       "NSUbiquitousContainerSupportedFolderLevels": "Any"}:
              problems.append(f"App/Info.plist: NSUbiquitousContainers[{container}] is {entry!r}")
```

The step's comment then lists iCloud beside Hotspot Configuration as ticked on the App ID.

`.github/workflows/testflight.yml`, the production branch of step 2, after the Hotspot Configuration check:

```bash
            for key in com.apple.developer.ubiquity-container-identifiers com.apple.developer.icloud-services \
                       iCloud.net.shamil.shutter-bridge CloudDocuments; do
              grep -q "$key" <<<"$entitlements" \
                || problems+=("it is signed without $key (check iCloud on the App ID and App/ShutterBridge.entitlements)")
            done
            [ -n "$(plist NSUbiquitousContainers:iCloud.net.shamil.shutter-bridge:NSUbiquitousContainerName)" ] \
              || problems+=("Info.plist has no NSUbiquitousContainers entry for iCloud.net.shamil.shutter-bridge")
```

`App/ShutterBridge/PrivacyInfo.xcprivacy`: no new data type (the files go to the person's own iCloud Drive through
Apple's service; nothing is collected by the developer). Its comment can say so.

**3. After the first TestFlight build with it.** The bench checks in [iteration-3-4-bench.md](iteration-3-4-bench.md),
*Staging checks*, part B: the Shutter Bridge folder in iCloud Drive (it may need a build number bump, a reinstall, or a
first file in Documents before Files shows it), staging there, and the fallback when signed out or switched off.

### Running it

Actions → **App to TestFlight** → Run workflow (branch `main`, app `production` or `spike`, Xcode 27.1, archive
signing `adhoc`) → approve the `testflight` deployment when GitHub asks. The job checks the environment is complete,
then:

- **`production`:** reads the `ShutterBridge` target's bundle ID and `MARKETING_VERSION` from `xcodebuild
  -showBuildSettings` and stops unless the bundle ID is `net.shamil.shutter-bridge` (before the signing step, the only
  one given the secrets); archives with an ad-hoc signature; and stops before the upload unless the archived app has that bundle ID,
  that version, the run's build number, a `CFBundleIconName` with a compiled asset catalogue and a signature carrying
  the Hotspot Configuration entitlement (from Iteration 3, W12; the same `codesign` check as the spike's). No Homebrew
  or XcodeGen step runs.
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
  production: its step 1, the App ID `net.shamil.shutter-bridge` exists with Hotspot Configuration ticked).
- **"Signed without com.apple.developer.networking.HotspotConfiguration" (production):** the archive lost the
  entitlement; check `CODE_SIGN_ENTITLEMENTS` in both configurations and `App/ShutterBridge.entitlements` (`app.yml`
  checks both on every PR).
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
