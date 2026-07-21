import Foundation

/// A macOS development bridge to Operon's experimental Rust C ABI.
///
/// This target links `target/release/liboperon_core.dylib` from this repository.
/// Package the static core library in an XCFramework before using it in an iOS
/// application.
#if os(macOS)
  public enum OperonCoreStep: Sendable, Equatable {
    /// A command for the host to execute. The payload is the ABI JSON envelope.
    case command(json: String)
    /// The session's terminal result. The payload is the ABI JSON envelope.
    case complete(json: String)
  }

  public enum OperonCoreError: Error, Sendable, Equatable, LocalizedError {
    case closed
    case core(String)
    case invalidResponse(String)

    public var errorDescription: String? {
      switch self {
      case .closed:
        return "The Operon core session has already been closed."
      case .core(let message), .invalidResponse(let message):
        return message
      }
    }
  }

  /// Owns one serial command/event session in the Rust core.
  ///
  /// Call `start()`, execute each returned command in the host application, and
  /// pass the corresponding JSON event back through `resume(eventJSON:)`.
  /// Instances are not safe to use concurrently.
  public final class OperonCoreSession {
    private var handle: OpaquePointer?

    public static var abiVersion: String {
      String(cString: operonABIVersion())
    }

    public init(query: String, configJSON: String? = nil) throws {
      var error: UnsafeMutablePointer<CChar>?
      let newHandle = query.withCString { queryPointer in
        if let configJSON {
          return configJSON.withCString { configPointer in
            operonSessionCreate(queryPointer, configPointer, &error)
          }
        }
        return operonSessionCreate(queryPointer, nil, &error)
      }

      guard let newHandle else {
        throw OperonCoreError.core(
          takeOwnedString(error) ?? "Operon core could not create a session."
        )
      }
      handle = newHandle
    }

    deinit {
      close()
    }

    public func close() {
      guard let handle else { return }
      operonSessionDestroy(handle)
      self.handle = nil
    }

    public func start() throws -> OperonCoreStep {
      guard let handle else { throw OperonCoreError.closed }
      return try invoke { output, error in
        operonSessionStart(handle, output, error)
      }
    }

    public func resume(eventJSON: String) throws -> OperonCoreStep {
      guard let handle else { throw OperonCoreError.closed }
      return try eventJSON.withCString { event in
        try invoke { output, error in
          operonSessionResume(handle, event, output, error)
        }
      }
    }

    private func invoke(
      _ operation: (
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
      ) -> Int32
    ) throws -> OperonCoreStep {
      var output: UnsafeMutablePointer<CChar>?
      var error: UnsafeMutablePointer<CChar>?
      let status = operation(&output, &error)
      let errorMessage = takeOwnedString(error)

      guard status == 0 else {
        throw OperonCoreError.core(
          errorMessage ?? "Operon core request failed (status \(status))."
        )
      }
      guard let json = takeOwnedString(output) else {
        throw OperonCoreError.invalidResponse("Operon core returned no JSON response.")
      }

      let kind: String
      do {
        kind = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).kind
      } catch {
        throw OperonCoreError.invalidResponse(
          "Operon core returned invalid JSON: \(error.localizedDescription)")
      }

      switch kind {
      case "command": return .command(json: json)
      case "complete": return .complete(json: json)
      default:
        throw OperonCoreError.invalidResponse("Operon core returned unknown step kind '\(kind)'.")
      }
    }
  }

  private struct Envelope: Decodable {
    let kind: String
  }

  private func takeOwnedString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { operonStringFree(pointer) }
    return String(cString: pointer)
  }

  @_silgen_name("operon_abi_version")
  private func operonABIVersion() -> UnsafePointer<CChar>

  @_silgen_name("operon_session_create")
  private func operonSessionCreate(
    _ query: UnsafePointer<CChar>,
    _ configJSON: UnsafePointer<CChar>?,
    _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  ) -> OpaquePointer?

  @_silgen_name("operon_session_start")
  private func operonSessionStart(
    _ handle: OpaquePointer,
    _ outStepJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  ) -> Int32

  @_silgen_name("operon_session_resume")
  private func operonSessionResume(
    _ handle: OpaquePointer,
    _ eventJSON: UnsafePointer<CChar>,
    _ outStepJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  ) -> Int32

  @_silgen_name("operon_session_destroy")
  private func operonSessionDestroy(_ handle: OpaquePointer)

  @_silgen_name("operon_string_free")
  private func operonStringFree(_ string: UnsafeMutablePointer<CChar>)
#endif
