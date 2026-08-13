import Foundation
import SyncDomain

public enum DeploymentEnvironment: String, Sendable {
    case development
    case testing
    case production
}
public struct OIDCConfiguration: Sendable {
    public let issuer: URL
    public let audience: String
    public let clientID: String
    public let scopes: [String]
    public let jwksURL: URL
    public let allowedAlgorithms: Set<String>
    public let maximumTokenAge: TimeInterval
    public let clockSkew: TimeInterval
    public let identityPepper: Data
    public let jwksRefreshInterval: TimeInterval

    public init(
        issuer: URL,
        audience: String,
        clientID: String,
        scopes: [String],
        jwksURL: URL,
        allowedAlgorithms: Set<String>,
        maximumTokenAge: TimeInterval,
        clockSkew: TimeInterval,
        identityPepper: Data,
        jwksRefreshInterval: TimeInterval = 900
    ) throws {
        try Self.requireHTTPS(issuer)
        try Self.requireHTTPS(jwksURL)
        guard issuer.absoluteString.utf8.count <= 2_048,
              jwksURL.absoluteString.utf8.count <= 2_048,
              !audience.isEmpty, audience.utf8.count <= 256,
              !clientID.isEmpty, clientID.utf8.count <= 256,
              !scopes.isEmpty, scopes.count <= 16,
              Set(scopes).count == scopes.count,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              !allowedAlgorithms.isEmpty,
              allowedAlgorithms.isSubset(of: ["RS256", "ES256"]),
              maximumTokenAge > 0, maximumTokenAge <= 86_400,
              clockSkew >= 0, clockSkew <= 300,
              (32...64).contains(identityPepper.count),
              jwksRefreshInterval >= 60
        else { throw ConfigurationError.invalidValue }
        self.issuer = issuer
        self.audience = audience
        self.clientID = clientID
        self.scopes = scopes
        self.jwksURL = jwksURL
        self.allowedAlgorithms = allowedAlgorithms
        self.maximumTokenAge = maximumTokenAge
        self.clockSkew = clockSkew
        self.identityPepper = identityPepper
        self.jwksRefreshInterval = jwksRefreshInterval
    }

    private static func requireHTTPS(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.fragment == nil
        else { throw ConfigurationError.invalidValue }
    }
}

public struct ServerConfiguration: Sendable {
    public let environment: DeploymentEnvironment
    public let bindHost: String
    public let port: Int
    public let publicBaseURL: URL
    public let serverInstanceID: UUID
    public let serverVersion: String
    public let tokenSecret: Data
    public let oidc: OIDCConfiguration

    public init(
        environment: DeploymentEnvironment,
        bindHost: String,
        port: Int,
        publicBaseURL: URL,
        serverInstanceID: UUID,
        serverVersion: String,
        tokenSecret: Data,
        oidc: OIDCConfiguration
    ) throws {
        guard !bindHost.isEmpty, bindHost.utf8.count <= 255, (1...65_535).contains(port),
              !serverVersion.isEmpty, serverVersion.utf8.count <= 64,
              (32...64).contains(tokenSecret.count),
              publicBaseURL.absoluteString.utf8.count <= 2_048,
              publicBaseURL.user == nil, publicBaseURL.password == nil,
              publicBaseURL.query == nil, publicBaseURL.fragment == nil
        else { throw ConfigurationError.invalidValue }
        if environment == .production {
            guard publicBaseURL.scheme == "https", publicBaseURL.host != nil else {
                throw ConfigurationError.invalidValue
            }
        } else {
            guard ["https", "http"].contains(publicBaseURL.scheme), publicBaseURL.host != nil else {
                throw ConfigurationError.invalidValue
            }
        }
        self.environment = environment
        self.bindHost = bindHost
        self.port = port
        self.publicBaseURL = publicBaseURL
        self.serverInstanceID = serverInstanceID
        self.serverVersion = serverVersion
        self.tokenSecret = tokenSecret
        self.oidc = oidc
    }

    public static func load(environment values: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else { throw ConfigurationError.missing(key) }
            return value
        }
        func positiveInt(_ key: String, default defaultValue: Int) throws -> Int {
            guard let raw = values[key] else { return defaultValue }
            guard let value = Int(raw), value > 0 else { throw ConfigurationError.invalid(key) }
            return value
        }
        func secret(_ key: String) throws -> Data {
            let value = try required(key)
            guard value.utf8.count <= 128,
                  let data = Data(base64URL: value) ?? Data(base64Encoded: value),
                  (32...64).contains(data.count)
            else {
                throw ConfigurationError.invalid(key)
            }
            return data
        }

        let deployment = try DeploymentEnvironment(rawValue: required("SNIPPETS_ENV"))
            .unwrap(or: ConfigurationError.invalid("SNIPPETS_ENV"))
        let publicURL = try URL(string: required("PUBLIC_BASE_URL"))
            .unwrap(or: ConfigurationError.invalid("PUBLIC_BASE_URL"))
        let instanceID = try UUID(uuidString: required("SERVER_INSTANCE_ID"))
            .unwrap(or: ConfigurationError.invalid("SERVER_INSTANCE_ID"))
        let issuer = try URL(string: required("OIDC_ISSUER"))
            .unwrap(or: ConfigurationError.invalid("OIDC_ISSUER"))
        let jwksURL = try URL(string: required("OIDC_JWKS_URL"))
            .unwrap(or: ConfigurationError.invalid("OIDC_JWKS_URL"))
        let algorithms = Set(try required("OIDC_ALLOWED_ALGORITHMS").split(separator: ",").map(String.init))
        let scopes = try required("OIDC_SCOPES").split(separator: " ").map(String.init)

        let oidc = try OIDCConfiguration(
            issuer: issuer,
            audience: required("OIDC_AUDIENCE"),
            clientID: required("OIDC_CLIENT_ID"),
            scopes: scopes,
            jwksURL: jwksURL,
            allowedAlgorithms: algorithms,
            maximumTokenAge: TimeInterval(try positiveInt("OIDC_MAX_TOKEN_AGE_SECONDS", default: 3_600)),
            clockSkew: TimeInterval(try positiveInt("OIDC_CLOCK_SKEW_SECONDS", default: 60)),
            identityPepper: secret("IDENTITY_PEPPER")
        )
        return try ServerConfiguration(
            environment: deployment,
            bindHost: values["BIND_HOST"] ?? "0.0.0.0",
            port: try positiveInt("PORT", default: 8_080),
            publicBaseURL: publicURL,
            serverInstanceID: instanceID,
            serverVersion: values["SERVER_VERSION"] ?? "dev",
            tokenSecret: secret("TOKEN_HMAC_SECRET"),
            oidc: oidc
        )
    }
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case missing(String)
    case invalid(String)
    case invalidValue
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
