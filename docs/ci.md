# CI and TestFlight

Nov 1, 2026 · How the spike app gets built, tested and onto the iPhone. Researched against Apple's and GitHub's
documentation on this date; the claims that rest only on forum reports are marked.

## Summary

| Job | Where | Trigger | Secrets |
| --- | --- | --- | --- |
| PTPKit tests on Linux | GitHub Actions, `ubuntu-latest` in `swift:6.4-noble` (`.github/workflows/ptpkit.yml`) | PRs touching `Packages/PTPKit` | none |
| Spike compile check + PTPKit tests on macOS | GitHub Actions, `xcode-27` runner (`.github/workflows/spike-build.yml`) | PRs touching `Spike/` or `Packages/PTPKit` | none |
| Archive → TestFlight (internal testing) | **Xcode Cloud** | manual, or pushes to a branch you choose | none in the repo; Apple manages signing |

**Why Xcode Cloud for TestFlight.** It is the proposal's CI decision, it signs with Apple-managed certificates
so no signing key or App Store Connect API key ever sits in this **public** repository, and the Apple Developer
Program includes 25 compute hours a month (paid tiers from US$49.99 for 100 h). At an estimated 8–12 minutes per
archive-only build (not yet measured), that is well over 100 builds a month.

**Why GitHub's `xcode-27` runner too.** It is free and unlimited for public repositories (the standard label;
`xcode-27-xlarge` is billed even on public repos), it has Xcode 27.0, 27.1 (default) and the 27.2 release
candidate, and it gives every PR a real Xcode 27 compile of the spike, which nothing else in the repo can do.
The image is still marked *preview*: no SLA, occasional queueing, weekly changes.

## What the repo already does for TestFlight

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

## One-time setup (Shamil; about 30 minutes, needs the Mac)

These steps live in Apple's and GitHub's consoles, not in git. An agent can't do them.

1. **Agreements.** App Store Connect → Business: accept any pending agreements (Account Holder).
2. **App ID with capabilities.** On the Mac: `make spike && make open`, set your team in Signing & Capabilities,
   and run the app on the iPhone once. Automatic signing registers `com.ubiquitousbear.shutterbridge.spike` with
   Hotspot Configuration. Check in the developer portal (Certificates, IDs & Profiles → Identifiers) that the
   capability is ticked: cloud signing during export will not add capabilities to an App ID.
3. **App record.** App Store Connect → Apps → + → New App: iOS, name e.g. "Shutter Bridge Spike" (don't spend the
   product name; no Sony marks), primary language English (UK), bundle ID
   `com.ubiquitousbear.shutterbridge.spike`, SKU `shutterbridge-spike`. The bundle ID can't change after the
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

## Not set up: TestFlight from GitHub Actions

It is possible, but needs more trust than the spike warrants. For the record, if Xcode Cloud ever can't be used:

- Archive ad-hoc signed so entitlements stay in the signature:
  `CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<team>`
  (`CODE_SIGNING_ALLOWED=NO` drops entitlements). Xcode Cloud's own archive command uses these flags; for GitHub
  runners it rests on a developer-forum report, so verify the archive's entitlements.
- Export and upload with `xcodebuild -exportArchive -allowProvisioningUpdates -authenticationKeyPath …
  -authenticationKeyID … -authenticationKeyIssuerID …` and an ExportOptions.plist with `method`
  `app-store-connect`, `destination` `upload`, `signingStyle` `automatic`, `teamID`,
  `manageAppVersionAndBuildNumber` false, `testFlightInternalTestingOnly` true (key names from Xcode 27.0's
  `xcodebuild -help`; re-check on the Mac).
- Cloud-managed distribution certificates need a **Team API key with the Admin role**: that key could sign and
  upload as you, so it must live in a GitHub Environment (`testflight`) with you as required reviewer, the
  workflow must be `workflow_dispatch` only (never `pull_request`/`pull_request_target`), and the `.p8` must be
  written to `$RUNNER_TEMP` with `umask 077` and deleted on exit.
- Build numbers from `CURRENT_PROJECT_VERSION=${{ github.run_number }}`.

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
