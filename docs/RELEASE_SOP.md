# CCS Sleep Studio — Release & Pre-Commit Standard Operating Procedure (SOP)

This document defines the mandatory pre-release checklist, testing protocol, and workflow conventions required for every code update and release of **CCS Sleep Studio**.

---

## 1. Why Releases Failed Previously (Root Cause Analysis)

1. **Unchecked Unit & Widget Test Regressions**:
   - Adding new UI elements or altering default backend configurations (e.g., auto spectrogram limits) can silently break existing test assertions (`test/eeg_backend_wavelet_test.dart`) or cause layout overflows (`RenderFlex` overflow in `test/widget_test.dart`) when tested under narrow test viewports.
2. **CI Trigger Keyword Discrepancy**:
   - Pushing commits with `[build release]` failed to trigger CI because `.github/workflows/build.yml` was hardcoded to check for `[build desktop]`.

---

## 2. Mandatory Pre-Release Verification Protocol

Before pushing any commit or creating a release tag, you **MUST** run the following 4-step verification sequence locally:

### Step 1: Rust Backend Verification
Ensure native signal processing and CLI crates compile and pass tests:
```sh
cd bridge
cargo test
cd ../analyseNidra
cargo check
cargo test
```

### Step 2: Flutter Static Analysis
Verify that there are no Dart compilation errors, broken imports, or type mismatches:
```sh
cd frontend
flutter analyze
```

### Step 3: Complete Flutter Test Suite Execution
Run the full unit and widget test suite locally. **All tests must pass cleanly (0 failures)**:
```sh
cd frontend
flutter test
```
> [!IMPORTANT]
> Never skip `flutter test`. If a widget test fails due to a `RenderFlex` overflow or assertion mismatch, fix the widget layout (e.g., wrap `Row` text in `Expanded`) or update the test expectations before pushing.

### Step 4: Version & Release Log Alignment
Ensure version numbers and release logs are updated consistently across:
- `frontend/pubspec.yaml`
- `README.md`
- `frontend/README.md`

---

## 3. GitHub Actions Trigger Rules

The GitHub Actions workflow (`.github/workflows/build.yml`) builds cross-platform installers (macOS, Windows, Linux `.deb`/`.rpm`) when **ANY** of the following criteria are met:

1. **Commit Message Triggers**: Include either `[build desktop]` or `[build release]` in your commit message:
   ```sh
   git commit -m "feat: add feature X [build release]"
   ```
2. **Release Version Tags**: Push a Git tag matching `v*`:
   ```sh
   git tag v1.3.2
   git push origin v1.3.2
   ```
3. **Manual Trigger**: Trigger via **GitHub Actions -> Build desktop apps -> Run workflow** in the GitHub web UI (`workflow_dispatch`).

---

## 4. Release Checklist Quick-Reference

| Check | Command / Action | Expected Result |
|-------|------------------|-----------------|
| 1. Rust Tests | `cargo test` (in `bridge/`) | `test result: ok` |
| 2. Flutter Analysis | `flutter analyze` (in `frontend/`) | `No issues found!` |
| 3. Flutter Tests | `flutter test` (in `frontend/`) | `All tests passed!` |
| 4. Commit Keyword | Include `[build release]` or `[build desktop]` | Triggers CI build |
| 5. Git Tag | `git tag vX.Y.Z && git push origin vX.Y.Z` | Triggers CI release build |
