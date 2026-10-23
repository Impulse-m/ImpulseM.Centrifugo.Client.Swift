import Foundation

// The instance of a client: an id the server keeps apart per client. It is validated when the
// client is created, sent in the connect request when it is set, and shown only as
// `instanceRedaction` in the debug log. It is never generated, persisted or put in an error text.

/// Shortest instance the server accepts, in characters. All allowed characters are ASCII.
internal let instanceMinLength: Int = 22

/// Longest instance the server accepts, in characters.
internal let instanceMaxLength: Int = 64

/// What the debug log shows in place of the instance.
internal let instanceRedaction: String = "<redacted>"


/// The configuration error of an instance, or nil when the instance is absent or valid.
///
/// A valid instance matches `^[A-Za-z0-9_-]{22,64}$`. The check runs on the UTF-8 bytes, so a
/// non-ASCII character fails it, and the message never contains the instance.
internal func instanceConfigurationError(_ instance: String?) -> CentrifugeError? {
    guard let value: String = instance else {
        return nil
    }
    let bytes: [UInt8] = Array(value.utf8)
    let lengthIsValid: Bool = bytes.count >= instanceMinLength && bytes.count <= instanceMaxLength
    let charactersAreValid: Bool = bytes.allSatisfy { (byte: UInt8) -> Bool in
        return isInstanceByte(byte)
    }
    if lengthIsValid && charactersAreValid {
        return nil
    }
    return CentrifugeError.configurationError(
        message: "instance must be 22 to 64 characters of A-Z, a-z, 0-9, _ or -"
    )
}


/// One byte of an instance: A-Z, a-z, 0-9, `_` or `-`.
private func isInstanceByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A, 0x5F, 0x2D:
        return true
    default:
        return false
    }
}
