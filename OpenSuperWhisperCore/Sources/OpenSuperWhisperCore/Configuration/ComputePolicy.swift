/// Where whisper and llama may run. `.automatic` is the macOS behaviour: whisper on Metal, llama
/// with every layer offloaded. `.cpuOnly` creates the whisper context with `use_gpu = false` and
/// loads llama with no layer offloaded, for an iPhone app working in the background, where Metal
/// is refused. It does not yet stop llama from initialising its Metal backend or offloading
/// large-batch ops (`op_offload` is left at its default); see the follow-ups in
/// docs/core-extraction.md. FluidAudio (Core ML) is not affected.
public enum ComputePolicy: Equatable, Sendable {
    case automatic
    case cpuOnly
}
