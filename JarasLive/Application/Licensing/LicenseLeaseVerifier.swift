import Foundation
import CryptoKit
public struct LicenseLeaseVerifier: Sendable {
    public let publicKey: Data
    public init(publicKey: Data) { self.publicKey = publicKey }
    public func verify(_ entitlement: Entitlement, account: UUID, installation: UUID) -> Bool {
        guard let proof = entitlement.proof,
              let payload = Data(base64Encoded: proof.payload), payload.count < 16384,
              let signature = Data(base64Encoded: proof.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else { return false }
        struct Identity: Decodable { let version: Int; let accountId: UUID; let installationId: UUID }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: text) else { throw BackendFailure.invalidSession }; return date
        }
        guard let identity = try? decoder.decode(Identity.self, from: payload), identity.version == 1,
              identity.accountId == account, identity.installationId == installation,
              let signed = try? decoder.decode(Entitlement.self, from: payload), signed.serverTime != nil else { return false }
        var candidate = entitlement; candidate.proof = nil
        return signed == candidate
    }
    public static let production = LicenseLeaseVerifier(publicKey: Data(base64Encoded: "eKtq54IOoeNi6MEagLPmAmT1AoEauwuzJotpLysRp+o=")!)
}
