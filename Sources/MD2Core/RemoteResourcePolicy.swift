/// Trusted caller permission for automatic document subresources. This is not
/// source metadata or a persisted rendering preference. Image permission covers
/// HTTP(S) image-class requests, including images produced by CSS and diagrams.
public enum RemoteResourcePolicy: Sendable, Equatable {
    case blocked
    case allowRemoteImages
}
