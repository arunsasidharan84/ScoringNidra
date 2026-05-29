# ScoringNidra

**ScoringNidra** is a high-performance, cross-platform sleep EEG viewer and scorer. It is a recreation of the Python-based [ScoringHero](https://github.com/SvennoNito/ScoringHero) repository, rebuilt from the ground up using **Flutter** for a more lightweight and responsive UI and **Rust** for native-speed signal processing.

---

## ⚡ Speed & Architectural Enhancements

ScoringNidra is designed with a core focus on execution speed and seamless user experience, overcoming the bottlenecks of the original Python/PyQt implementation:

### 1. Hybrid Flutter + Rust FFI Pipeline
- **Parallel Computing**: Signal processing computations (Welch spectrograms, periodograms, Chebyshev/Butterworth filters, and Morlet wavelet transforms) are executed in a native Rust library (`rust_backend`) utilizing highly optimized SIMD operations and multi-threaded processing via `rayon`.
- **Background Isolates**: All heavy calculations run off the main Flutter UI thread in background Dart **Isolates**. The main interface remains highly responsive at a locked 60+ FPS, even when performing full-night calculations.
- **Zero-Copy Memory Access**: High-frequency array transfers between Dart and Rust leverage Direct Memory Access (`.asTypedList` and `setAll` pointer copies) to bypass slow double loops and avoid heap reallocation overhead.
  - *Performance Benchmarks*: Full-night spectrogram updates complete in just **19 ms**, and wavelet time-frequency updates finish in **113 ms**.

### 2. Standalone Binaries (No Dependency Hell)
- **ScoringHero (Python)**: Requires setting up a Python virtual environment and installing exact scientific versions of `numpy`, `scipy`, `pyqt5`, `pyedflib`, and `matplotlib`.
- **ScoringNidra**: Compiles into a single, standalone native application (`.app` on macOS, `.exe` on Windows). All dependencies and native libraries are self-contained. You can copy and share the app bundle directly.

### 3. Smart Configuration & Auto-Saving
- **Unsandboxed Access**: The app runs unsandboxed on macOS to automatically load and save scoring and channel configurations (`.json`) directly next to the opened `.edf` or `.mat` recording.
- **Robust Channel Binding**: Reordering channels persists dynamically using robust name-based matching. Re-opening a file bounds reordered channels to the correct signal data regardless of their index.

### 4. Advanced Waveform Stability & Filtering
- **Stable IIR Filters**: Includes safety clamps and NaN/Inf validation in Zero-Phase Second-Order Sections (SOS) Chebyshev/Butterworth filters. This prevents the "waveform flattening" or crashes typical in Python when setting cutoffs close to 0 Hz or the Nyquist frequency.
- **Contrast Wavelet Scaling**: Automated wavelet power auto-ranging and custom scale limits (`[-10, 15] dB`) mapped per display mode to provide high-contrast, readable wavelet plots.

---

## 🛠️ Folder Structure

- `/lib`: Flutter desktop application and UI code.
  - [lib/src/eeg_backend.dart](lib/src/eeg_backend.dart): Dart FFI bridge, isolate wrappers, and display filters.
  - [lib/src/app.dart](lib/src/app.dart): Main application viewport, layouts, and panels.
- `/rust_backend`: Rust `cdylib` library crate containing pure native signal processing.
- `/macos` & `/windows`: Native platform runner configurations and builds.

---

## 🚀 Running & Building Locally

### 1. Build the Rust Backend
Before running the app, compile the native library:

```sh
cd rust_backend
cargo build --release
```

### 2. Run the App
Start the app in development mode:

```sh
# Run on macOS
flutter run -d macos

# Run on Windows
flutter run -d windows
```

### 3. Compile Production Release
To compile the release packages:

```sh
# macOS Release (.app)
flutter build macos

# Windows Release (.exe)
flutter build windows
```

The resulting executables will be located under `build/macos/Build/Products/Release/ScoringNidra.app` (macOS) and `build/windows/x64/runner/Release/` (Windows).

---

## 🧪 Testing

Run the full suite of automated unit and performance integration tests:

```sh
flutter test
```
