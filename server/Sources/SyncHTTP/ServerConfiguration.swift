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
    public let unknownKeyRefreshInterval: TimeInterval
    public let unknownKeyCacheTTL: TimeInterval
    /// Authentication methods that the identity provider maps to a
    /// phishing-resistant authenticator (normally a passkey/WebAuthn ceremony).
    public let stepUpAuthenticationMethods: Set<String>
    /// Optional provider-specific assurance contexts with the same meaning.
    public let stepUpAuthenticationContexts: Set<String>
    public let stepUpMaximumAge: TimeInterval

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
        jwksRefreshInterval: TimeInterval = 900,
        unknownKeyRefreshInterval: TimeInterval = 60,
        unknownKeyCacheTTL: TimeInterval = 300,
        stepUpAuthenticationMethods: Set<String> = ["webauthn"],
        stepUpAuthenticationContexts: Set<String> = [],
        stepUpMaximumAge: TimeInterval = 300
    ) throws {
        try Self.requireHTTPS(issuer)
        try Self.requireHTTPS(jwksURL)
        guard issuer.absoluteString.utf8.count <= 2_048,
              issuer.query == nil,
              jwksURL.absoluteString.utf8.count <= 2_048,
              !audience.isEmpty, audience.utf8.count <= 256,
              !clientID.isEmpty, clientID.utf8.count <= 256,
              !scopes.isEmpty, scopes.count <= 16,
              Set(scopes).count == scopes.count,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              !allowedAlgorithms.isEmpty,
              allowedAlgorithms.isSubset(of: ["RS256", "ES256"]),
              maximumTokenAge >= 60, maximumTokenAge <= 86_400,
              clockSkew >= 0, clockSkew <= 300,
              (32...64).contains(identityPepper.count),
              jwksRefreshInterval >= 60, jwksRefreshInterval <= 86_400,
              unknownKeyRefreshInterval >= 60, unknownKeyRefreshInterval <= jwksRefreshInterval,
              unknownKeyCacheTTL >= unknownKeyRefreshInterval, unknownKeyCacheTTL <= 3_600,
              !stepUpAuthenticationMethods.isEmpty || !stepUpAuthenticationContexts.isEmpty,
              stepUpAuthenticationMethods.count <= 16,
              stepUpAuthenticationContexts.count <= 16,
              stepUpAuthenticationMethods.allSatisfy(Self.validAssuranceValue),
              stepUpAuthenticationContexts.allSatisfy(Self.validAssuranceValue),
              stepUpMaximumAge >= 60, stepUpMaximumAge <= 3_600
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
        self.unknownKeyRefreshInterval = unknownKeyRefreshInterval
        self.unknownKeyCacheTTL = unknownKeyCacheTTL
        self.stepUpAuthenticationMethods = Set(stepUpAuthenticationMethods.map { $0.lowercased() })
        self.stepUpAuthenticationContexts = stepUpAuthenticationContexts
        self.stepUpMaximumAge = stepUpMaximumAge
    }

    private static func requireHTTPS(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.fragment == nil
        else { throw ConfigurationError.invalidValue }
    }

    private static func validAssuranceValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            }
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
    public let httpIdleTimeoutSeconds: Int
    public let httpBodyTimeoutSeconds: Int
    public let httpReadinessTimeoutSeconds: Int
    public let httpMaximumConnections: Int
    public let httpMaximumConcurrentRequests: Int
    public let httpBodyMemoryBudgetBytes: Int
    public let httpGlobalRequestsPerSecond: Int
    public let httpGlobalRequestBurst: Int
    public let httpPrincipalRequestsPerSecond: Int
    public let httpPrincipalRequestBurst: Int

    public init(
        environment: DeploymentEnvironment,
        bindHost: String,
        port: Int,
        publicBaseURL: URL,
        serverInstanceID: UUID,
        serverVersion: String,
        tokenSecret: Data,
        oidc: OIDCConfiguration,
        httpIdleTimeoutSeconds: Int = 30,
        httpBodyTimeoutSeconds: Int = 15,
        httpReadinessTimeoutSeconds: Int = 3,
        httpMaximumConnections: Int = 256,
        httpMaximumConcurrentRequests: Int = 128,
        httpBodyMemoryBudgetBytes: Int = 256 * 1_024 * 1_024,
        httpGlobalRequestsPerSecond: Int = 256,
        httpGlobalRequestBurst: Int = 512,
        httpPrincipalRequestsPerSecond: Int = 30,
        httpPrincipalRequestBurst: Int = 60
    ) throws {
        guard !bindHost.isEmpty, bindHost.utf8.count <= 255, (1...65_535).contains(port),
              !serverVersion.isEmpty, serverVersion.utf8.count <= 64,
              (32...64).contains(tokenSecret.count),
              publicBaseURL.absoluteString.utf8.count <= 2_048,
              !publicBaseURL.absoluteString.hasSuffix("/"),
              publicBaseURL.user == nil, publicBaseURL.password == nil,
              publicBaseURL.query == nil, publicBaseURL.fragment == nil,
              (5...300).contains(httpIdleTimeoutSeconds),
              (5...120).contains(httpBodyTimeoutSeconds),
              (1...30).contains(httpReadinessTimeoutSeconds),
              (16...10_000).contains(httpMaximumConnections),
              (8...httpMaximumConnections).contains(httpMaximumConcurrentRequests),
              (SyncLimits.maxRequestBytes...(4 * 1_024 * 1_024 * 1_024)).contains(httpBodyMemoryBudgetBytes),
              (1...100_000).contains(httpGlobalRequestsPerSecond),
              (httpGlobalRequestsPerSecond...200_000).contains(httpGlobalRequestBurst),
              (1...10_000).contains(httpPrincipalRequestsPerSecond),
              (httpPrincipalRequestsPerSecond...20_000).contains(httpPrincipalRequestBurst)
        else { throw ConfigurationError.invalidValue }
        if environment == .production {
            guard publicBaseURL.scheme == "https", publicBaseURL.host != nil,
                  oidc.audience == publicBaseURL.absoluteString,
                  oidc.audience != oidc.clientID,
                  oidc.maximumTokenAge <= 300,
                  Set(oidc.scopes).isSuperset(of: ["openid", "offline_access"]) else {
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
        self.httpIdleTimeoutSeconds = httpIdleTimeoutSeconds
        self.httpBodyTimeoutSeconds = httpBodyTimeoutSeconds
        self.httpReadinessTimeoutSeconds = httpReadinessTimeoutSeconds
        self.httpMaximumConnections = httpMaximumConnections
        self.httpMaximumConcurrentRequests = httpMaximumConcurrentRequests
        self.httpBodyMemoryBudgetBytes = httpBodyMemoryBudgetBytes
        self.httpGlobalRequestsPerSecond = httpGlobalRequestsPerSecond
        self.httpGlobalRequestBurst = httpGlobalRequestBurst
        self.httpPrincipalRequestsPerSecond = httpPrincipalRequestsPerSecond
        self.httpPrincipalRequestBurst = httpPrincipalRequestBurst
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
        func strictBool(_ key: String, default defaultValue: Bool) throws -> Bool {
            guard let raw = values[key] else { return defaultValue }
            switch raw.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: throw ConfigurationError.invalid(key)
            }
        }
        func optionalValuesSet(_ key: String) -> Set<String> {
            Set(values[key, default: ""].split(separator: " ").map(String.init))
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
        let configuredStepUpMethods = optionalValuesSet("OIDC_STEP_UP_AMR_VALUES")
        let configuredStepUpContexts = optionalValuesSet("OIDC_STEP_UP_ACR_VALUES")
        let stepUpMethods: Set<String>
        if values["OIDC_STEP_UP_AMR_VALUES"] != nil {
            stepUpMethods = configuredStepUpMethods
        } else if deployment == .production {
            stepUpMethods = []
        } else {
            stepUpMethods = ["webauthn"]
        }
        if deployment == .production,
           values["OIDC_STEP_UP_AMR_VALUES"] == nil,
           values["OIDC_STEP_UP_ACR_VALUES"] == nil {
            throw ConfigurationError.missing("OIDC_STEP_UP_AMR_VALUES or OIDC_STEP_UP_ACR_VALUES")
        }

        let oidc = try OIDCConfiguration(
            issuer: issuer,
            audience: required("OIDC_AUDIENCE"),
            clientID: required("OIDC_CLIENT_ID"),
            scopes: scopes,
            jwksURL: jwksURL,
            allowedAlgorithms: algorithms,
            maximumTokenAge: TimeInterval(try positiveInt("OIDC_MAX_TOKEN_AGE_SECONDS", default: 300)),
            clockSkew: TimeInterval(try positiveInt("OIDC_CLOCK_SKEW_SECONDS", default: 60)),
            identityPepper: secret("IDENTITY_PEPPER"),
            jwksRefreshInterval: TimeInterval(try positiveInt("OIDC_JWKS_REFRESH_SECONDS", default: 900)),
            unknownKeyRefreshInterval: TimeInterval(try positiveInt("OIDC_UNKNOWN_KID_REFRESH_SECONDS", default: 60)),
            unknownKeyCacheTTL: TimeInterval(try positiveInt("OIDC_UNKNOWN_KID_TTL_SECONDS", default: 300)),
            stepUpAuthenticationMethods: stepUpMethods,
            stepUpAuthenticationContexts: configuredStepUpContexts,
            stepUpMaximumAge: TimeInterval(try positiveInt("OIDC_STEP_UP_MAX_AGE_SECONDS", default: 300))
        )
        return try ServerConfiguration(
            environment: deployment,
            bindHost: values["BIND_HOST"] ?? "0.0.0.0",
            port: try positiveInt("PORT", default: 8_080),
            publicBaseURL: publicURL,
            serverInstanceID: instanceID,
            serverVersion: values["SERVER_VERSION"] ?? "dev",
            tokenSecret: secret("TOKEN_HMAC_SECRET"),
            oidc: oidc,
            httpIdleTimeoutSeconds: try positiveInt("HTTP_IDLE_TIMEOUT_SECONDS", default: 30),
            httpBodyTimeoutSeconds: try positiveInt("HTTP_BODY_TIMEOUT_SECONDS", default: 15),
            httpReadinessTimeoutSeconds: try positiveInt("HTTP_READINESS_TIMEOUT_SECONDS", default: 3),
            httpMaximumConnections: try positiveInt("HTTP_MAX_CONNECTIONS", default: 256),
            httpMaximumConcurrentRequests: try positiveInt("HTTP_MAX_CONCURRENT_REQUESTS", default: 128),
            httpBodyMemoryBudgetBytes: try positiveInt("HTTP_BODY_MEMORY_BUDGET_BYTES", default: 256 * 1_024 * 1_024),
            httpGlobalRequestsPerSecond: try positiveInt("HTTP_GLOBAL_REQUESTS_PER_SECOND", default: 256),
            httpGlobalRequestBurst: try positiveInt("HTTP_GLOBAL_REQUEST_BURST", default: 512),
            httpPrincipalRequestsPerSecond: try positiveInt("HTTP_PRINCIPAL_REQUESTS_PER_SECOND", default: 30),
            httpPrincipalRequestBurst: try positiveInt("HTTP_PRINCIPAL_REQUEST_BURST", default: 60)
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
