import Foundation
import Hummingbird
import OpenAPIHummingbird
import OpenAPIRuntime
import SyncDomain

public enum SyncApplicationFactory {
    public static func makeRouter(
        configuration: ServerConfiguration,
        store: any SyncStore,
        tokenValidator: any AccessTokenValidating
    ) throws -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)
        let handler = SyncAPIHandler(store: store, configuration: configuration)
        try handler.registerHandlers(
            on: router,
            serverURL: URL(string: "/")!,
            configuration: .init(jsonEncodingOptions: [.sortedKeys, .withoutEscapingSlashes]),
            middlewares: [RequestSecurityMiddleware(tokenValidator: tokenValidator)]
        )
        return router
    }
}
