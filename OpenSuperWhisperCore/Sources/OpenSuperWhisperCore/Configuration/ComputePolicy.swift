/// Where whisper and llama may run. `.automatic` is the macOS behaviour: whisper on Metal, llama
/// with every layer offloaded. `.cpuOnly` creates the whisper context with `use_gpu = false` and
/// loads llama with no layer offloaded. It is meant for an iPhone app working in the background,
/// where Metal is refused, but does not keep Metal out yet: ggml's backend registry still creates
/// the MTLDevice when whisper counts its devices, and llama still allocates a Metal context for
/// every context (`devices` and `op_offload` are left at their defaults).
///
/// The policy is part of the configuration a host installs once per process, and the shared
/// llama backend keeps the one it was built with, so a host cannot yet run on Metal in the
/// foreground and on the CPU only in the background. Both gaps are follow-ups in
/// docs/core-extraction.md. FluidAudio (Core ML) is not affected.
public enum ComputePolicy: Equatable, Sendable {
    case automatic
    case cpuOnly
}
