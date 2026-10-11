# Building whisper.cpp and llama.cpp

The app no longer builds whisper.cpp by hand. `Scripts/build-native.sh` configures `libwhisper/`
(the whisper.cpp and llama.cpp submodules, sharing one ggml) once per platform with CMake, builds it
in Release with generic CPU kernels, and merges the archives into
`OpenSuperWhisperCore/Binaries/OSWNative.xcframework`, which the core package links statically.

```sh
Scripts/build-native.sh            # macOS arm64 + x86_64 (what ./run.sh build runs)
Scripts/build-native.sh all        # plus iOS and the iOS Simulator
FORCE=1 Scripts/build-native.sh    # rebuild from a clean configure
RELEASE=1 Scripts/build-native.sh  # forced, and only from the pinned, clean submodules
```

It skips the build when nothing it depends on changed (submodule commits and local changes, the
CMake file, the script, the toolchain). The full design is in the "Native binaries" section of
[`core-extraction.md`](core-extraction.md).
