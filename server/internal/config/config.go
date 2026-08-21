package config

import (
	"encoding/base64"
	"errors"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type Environment string

const (
	Development                      Environment = "development"
	Testing                          Environment = "testing"
	Production                       Environment = "production"
	maximumRecordResponseReservation             = int64(domain.MaxResponseBytes + domain.MaxPageRecords*domain.MaxBlobBytes)
)

type OIDC struct {
	Issuer                    *url.URL
	Audience                  string
	ClientID                  string
	Scopes                    []string
	JWKSURL                   *url.URL
	AllowedAlgorithms         []string
	MaximumTokenAge           time.Duration
	ClockSkew                 time.Duration
	IdentityPepper            []byte
	JWKSRefreshInterval       time.Duration
	JWKSMaximumStaleness      time.Duration
	UnknownKeyRefreshInterval time.Duration
	UnknownKeyCacheTTL        time.Duration
	StepUpAMR                 map[string]struct{}
	StepUpACR                 map[string]struct{}
	StepUpMaximumAge          time.Duration
}

type HTTP struct {
	IdleTimeout          time.Duration
	BodyTimeout          time.Duration
	RequestTimeout       time.Duration
	ShutdownTimeout      time.Duration
	ReadinessTimeout     time.Duration
	MaximumConnections   int
	MaximumConcurrent    int
	BodyMemoryBudget     int64
	ResponseMemoryBudget int64
	GlobalRate           int
	GlobalBurst          int
	PrincipalRate        int
	PrincipalBurst       int
}

type Database struct {
	Host             string
	Port             int
	Name             string
	RuntimeUser      string
	RuntimePassword  string
	TLSMode          string
	TLSRootCert      string
	ChannelBinding   string
	RequireAuth      string
	ConnectTimeout   time.Duration
	StatementTimeout time.Duration
	LockTimeout      time.Duration
	MaxConnections   int32
}

type Server struct {
	Environment      Environment
	BindHost         string
	Port             int
	PublicBaseURL    *url.URL
	ServerInstanceID uuid.UUID
	ServerVersion    string
	TokenSecret      []byte
	OIDC             OIDC
	HTTP             HTTP
	Database         Database
}

func Load() (Server, error) {
	return LoadFrom(os.LookupEnv)
}

func LoadFrom(lookup func(string) (string, bool)) (Server, error) {
	required := func(key string) (string, error) {
		value, ok := lookup(key)
		if !ok || value == "" {
			return "", errors.New("missing " + key)
		}
		return value, nil
	}
	positive := func(key string, fallback int) (int, error) {
		raw, ok := lookup(key)
		if !ok {
			return fallback, nil
		}
		value, err := strconv.Atoi(raw)
		if err != nil || value <= 0 {
			return 0, errors.New("invalid " + key)
		}
		return value, nil
	}
	secret := func(key string) ([]byte, error) {
		raw, err := required(key)
		if err != nil {
			return nil, err
		}
		if len(raw) > 128 {
			return nil, errors.New("invalid " + key)
		}
		value, decodeErr := base64.RawURLEncoding.Strict().DecodeString(raw)
		if decodeErr != nil {
			value, decodeErr = base64.StdEncoding.Strict().DecodeString(raw)
		}
		if decodeErr != nil || len(value) < 32 || len(value) > 64 {
			return nil, errors.New("invalid " + key)
		}
		return value, nil
	}
	parseURL := func(key string) (*url.URL, error) {
		raw, err := required(key)
		if err != nil {
			return nil, err
		}
		value, err := url.Parse(raw)
		if err != nil {
			return nil, errors.New("invalid " + key)
		}
		return value, nil
	}

	environmentRaw, err := required("SNIPPETS_ENV")
	if err != nil {
		return Server{}, err
	}
	environment := Environment(environmentRaw)
	if environment != Development && environment != Testing && environment != Production {
		return Server{}, errors.New("invalid SNIPPETS_ENV")
	}
	publicBase, err := parseURL("PUBLIC_BASE_URL")
	if err != nil {
		return Server{}, err
	}
	if err := validateCanonicalOrigin(publicBase, environment == Production); err != nil {
		return Server{}, errors.New("invalid PUBLIC_BASE_URL")
	}
	instanceRaw, err := required("SERVER_INSTANCE_ID")
	if err != nil {
		return Server{}, err
	}
	instanceID, err := uuid.Parse(instanceRaw)
	if err != nil || instanceID == uuid.Nil {
		return Server{}, errors.New("invalid SERVER_INSTANCE_ID")
	}
	issuer, err := parseURL("OIDC_ISSUER")
	if err != nil {
		return Server{}, err
	}
	jwksURL, err := parseURL("OIDC_JWKS_URL")
	if err != nil {
		return Server{}, err
	}
	if err := validateHTTPSURL(issuer, false); err != nil {
		return Server{}, errors.New("invalid OIDC_ISSUER")
	}
	if err := validateHTTPSURL(jwksURL, true); err != nil {
		return Server{}, errors.New("invalid OIDC_JWKS_URL")
	}
	audience, err := required("OIDC_AUDIENCE")
	if err != nil {
		return Server{}, err
	}
	clientID, err := required("OIDC_CLIENT_ID")
	if err != nil {
		return Server{}, err
	}
	scopesRaw, err := required("OIDC_SCOPES")
	if err != nil {
		return Server{}, err
	}
	scopes := strings.Fields(scopesRaw)
	algorithmsRaw, err := required("OIDC_ALLOWED_ALGORITHMS")
	if err != nil {
		return Server{}, err
	}
	algorithms := strings.Split(algorithmsRaw, ",")
	if !uniqueAllowed(algorithms, map[string]bool{"RS256": true, "ES256": true}) {
		return Server{}, errors.New("invalid OIDC_ALLOWED_ALGORITHMS")
	}
	if len(scopes) == 0 || len(scopes) > 16 || !uniqueBounded(scopes, 64) {
		return Server{}, errors.New("invalid OIDC_SCOPES")
	}
	maximumTokenAge, err := positive("OIDC_MAX_TOKEN_AGE_SECONDS", 300)
	if err != nil {
		return Server{}, err
	}
	clockSkew, err := positive("OIDC_CLOCK_SKEW_SECONDS", 60)
	if err != nil {
		return Server{}, err
	}
	refresh, err := positive("OIDC_JWKS_REFRESH_SECONDS", 900)
	if err != nil {
		return Server{}, err
	}
	maximumStaleness, err := positive("OIDC_JWKS_MAX_STALENESS_SECONDS", 3600)
	if err != nil {
		return Server{}, err
	}
	unknownRefresh, err := positive("OIDC_UNKNOWN_KID_REFRESH_SECONDS", 60)
	if err != nil {
		return Server{}, err
	}
	unknownTTL, err := positive("OIDC_UNKNOWN_KID_TTL_SECONDS", 300)
	if err != nil {
		return Server{}, err
	}
	stepUpAge, err := positive("OIDC_STEP_UP_MAX_AGE_SECONDS", 300)
	if err != nil {
		return Server{}, err
	}
	pepper, err := secret("IDENTITY_PEPPER")
	if err != nil {
		return Server{}, err
	}
	stepAMRRaw, hasAMR := lookup("OIDC_STEP_UP_AMR_VALUES")
	stepACRRaw, hasACR := lookup("OIDC_STEP_UP_ACR_VALUES")
	if environment == Production && !hasAMR && !hasACR {
		return Server{}, errors.New("missing OIDC step-up assurance values")
	}
	if !hasAMR && environment != Production {
		stepAMRRaw = "webauthn"
	}
	stepAMR, stepACR := valueSet(strings.Fields(stepAMRRaw), true), valueSet(strings.Fields(stepACRRaw), false)
	if len(stepAMR)+len(stepACR) == 0 || len(stepAMR) > 16 || len(stepACR) > 16 {
		return Server{}, errors.New("invalid OIDC step-up assurance values")
	}
	if maximumTokenAge < 60 || maximumTokenAge > 86400 || clockSkew > 300 || refresh < 60 || refresh > 3600 || maximumStaleness < refresh || maximumStaleness > 86400 || unknownRefresh < 60 || unknownRefresh > refresh || unknownTTL < unknownRefresh || unknownTTL > 3600 || stepUpAge < 60 || stepUpAge > 3600 {
		return Server{}, errors.New("invalid OIDC timing")
	}
	if environment == Production {
		if audience != publicBase.String() || audience == clientID || maximumTokenAge > 300 || !contains(scopes, "openid") || !contains(scopes, "offline_access") {
			return Server{}, errors.New("invalid production OIDC configuration")
		}
	}
	tokenSecret, err := secret("TOKEN_HMAC_SECRET")
	if err != nil {
		return Server{}, err
	}
	port, err := positive("PORT", 8080)
	if err != nil {
		return Server{}, err
	}
	idle, err := positive("HTTP_IDLE_TIMEOUT_SECONDS", 30)
	if err != nil {
		return Server{}, err
	}
	body, err := positive("HTTP_BODY_TIMEOUT_SECONDS", 15)
	if err != nil {
		return Server{}, err
	}
	requestTimeout, err := positive("HTTP_REQUEST_TIMEOUT_SECONDS", 25)
	if err != nil {
		return Server{}, err
	}
	shutdownTimeout, err := positive("HTTP_SHUTDOWN_TIMEOUT_SECONDS", requestTimeout+10)
	if err != nil {
		return Server{}, err
	}
	ready, err := positive("HTTP_READINESS_TIMEOUT_SECONDS", 3)
	if err != nil {
		return Server{}, err
	}
	maxConnections, err := positive("HTTP_MAX_CONNECTIONS", 256)
	if err != nil {
		return Server{}, err
	}
	maxConcurrent, err := positive("HTTP_MAX_CONCURRENT_REQUESTS", 128)
	if err != nil {
		return Server{}, err
	}
	bodyBudget, err := positive("HTTP_BODY_MEMORY_BUDGET_BYTES", 256*1024*1024)
	if err != nil {
		return Server{}, err
	}
	responseBudget, err := positive("HTTP_RESPONSE_MEMORY_BUDGET_BYTES", 384*1024*1024)
	if err != nil {
		return Server{}, err
	}
	globalRate, err := positive("HTTP_GLOBAL_REQUESTS_PER_SECOND", 256)
	if err != nil {
		return Server{}, err
	}
	globalBurst, err := positive("HTTP_GLOBAL_REQUEST_BURST", 512)
	if err != nil {
		return Server{}, err
	}
	principalRate, err := positive("HTTP_PRINCIPAL_REQUESTS_PER_SECOND", 30)
	if err != nil {
		return Server{}, err
	}
	principalBurst, err := positive("HTTP_PRINCIPAL_REQUEST_BURST", 60)
	if err != nil {
		return Server{}, err
	}
	if port > 65535 || idle < 5 || idle > 300 || body < 5 || body > 120 || requestTimeout < body || requestTimeout > 120 || shutdownTimeout < requestTimeout+5 || shutdownTimeout > 300 || ready > 30 || maxConnections < 16 || maxConnections > 10000 || maxConcurrent < 8 || maxConcurrent > maxConnections || bodyBudget < domain.MaxRequestMemoryReservation || int64(bodyBudget) > 4*1024*1024*1024 || int64(responseBudget) < maximumRecordResponseReservation || int64(responseBudget) > 4*1024*1024*1024 || globalBurst < globalRate || principalBurst < principalRate {
		return Server{}, errors.New("invalid HTTP configuration")
	}
	dbPort, err := positive("DATABASE_PORT", 5432)
	if err != nil {
		return Server{}, err
	}
	dbMax, err := positive("DATABASE_MAX_CONNECTIONS", 16)
	if err != nil {
		return Server{}, err
	}
	dbConnectTimeout, err := positive("DATABASE_CONNECT_TIMEOUT_SECONDS", 5)
	if err != nil {
		return Server{}, err
	}
	dbStatementTimeout, err := positive("DATABASE_STATEMENT_TIMEOUT_SECONDS", 20)
	if err != nil {
		return Server{}, err
	}
	dbLockTimeout, err := positive("DATABASE_LOCK_TIMEOUT_SECONDS", 5)
	if err != nil {
		return Server{}, err
	}
	if dbPort > 65535 || dbMax > 512 || dbConnectTimeout > 30 || dbStatementTimeout > requestTimeout || dbLockTimeout > dbStatementTimeout {
		return Server{}, errors.New("invalid database configuration")
	}
	dbHost, err := required("DATABASE_HOST")
	if err != nil {
		return Server{}, err
	}
	dbName, err := required("DATABASE_NAME")
	if err != nil {
		return Server{}, err
	}
	dbUser, err := required("DATABASE_RUNTIME_USER")
	if err != nil {
		return Server{}, err
	}
	dbPassword, err := required("DATABASE_RUNTIME_PASSWORD")
	if err != nil {
		return Server{}, err
	}
	tlsMode := "verify-full"
	if environment != Production {
		tlsMode = "require"
	}
	if value, ok := lookup("DATABASE_TLS_MODE"); ok {
		tlsMode = value
	}
	if (environment == Production && tlsMode != "verify-full") || (environment != Production && tlsMode != "disable" && tlsMode != "require" && tlsMode != "verify-full") {
		return Server{}, errors.New("invalid DATABASE_TLS_MODE")
	}
	tlsRootCert, hasTLSRootCert := lookup("DATABASE_TLS_ROOT_CERT")
	if (tlsMode == "verify-full" && (!hasTLSRootCert || tlsRootCert == "")) || len(tlsRootCert) > 4096 || strings.ContainsRune(tlsRootCert, '\x00') {
		return Server{}, errors.New("invalid DATABASE_TLS_ROOT_CERT")
	}
	channelBinding := "prefer"
	if environment == Production {
		channelBinding = "require"
	}
	if value, ok := lookup("DATABASE_CHANNEL_BINDING"); ok {
		channelBinding = value
	}
	if (environment == Production && channelBinding != "require") || (channelBinding != "disable" && channelBinding != "prefer" && channelBinding != "require") {
		return Server{}, errors.New("invalid DATABASE_CHANNEL_BINDING")
	}
	requireAuth := ""
	if environment == Production {
		requireAuth = "scram-sha-256"
	}
	if value, ok := lookup("DATABASE_REQUIRE_AUTH"); ok {
		requireAuth = value
	}
	if environment == Production && requireAuth != "scram-sha-256" {
		return Server{}, errors.New("invalid DATABASE_REQUIRE_AUTH")
	}
	serverVersion := "dev"
	if value, ok := lookup("SERVER_VERSION"); ok {
		serverVersion = value
	}
	bindHost := "0.0.0.0"
	if value, ok := lookup("BIND_HOST"); ok {
		bindHost = value
	}
	if bindHost == "" || len(bindHost) > 255 || serverVersion == "" || len(serverVersion) > 64 {
		return Server{}, errors.New("invalid server identity")
	}
	return Server{
		Environment: environment, BindHost: bindHost, Port: port, PublicBaseURL: publicBase, ServerInstanceID: instanceID, ServerVersion: serverVersion, TokenSecret: tokenSecret,
		OIDC:     OIDC{Issuer: issuer, Audience: audience, ClientID: clientID, Scopes: scopes, JWKSURL: jwksURL, AllowedAlgorithms: algorithms, MaximumTokenAge: time.Duration(maximumTokenAge) * time.Second, ClockSkew: time.Duration(clockSkew) * time.Second, IdentityPepper: pepper, JWKSRefreshInterval: time.Duration(refresh) * time.Second, JWKSMaximumStaleness: time.Duration(maximumStaleness) * time.Second, UnknownKeyRefreshInterval: time.Duration(unknownRefresh) * time.Second, UnknownKeyCacheTTL: time.Duration(unknownTTL) * time.Second, StepUpAMR: stepAMR, StepUpACR: stepACR, StepUpMaximumAge: time.Duration(stepUpAge) * time.Second},
		HTTP:     HTTP{IdleTimeout: time.Duration(idle) * time.Second, BodyTimeout: time.Duration(body) * time.Second, RequestTimeout: time.Duration(requestTimeout) * time.Second, ShutdownTimeout: time.Duration(shutdownTimeout) * time.Second, ReadinessTimeout: time.Duration(ready) * time.Second, MaximumConnections: maxConnections, MaximumConcurrent: maxConcurrent, BodyMemoryBudget: int64(bodyBudget), ResponseMemoryBudget: int64(responseBudget), GlobalRate: globalRate, GlobalBurst: globalBurst, PrincipalRate: principalRate, PrincipalBurst: principalBurst},
		Database: Database{Host: dbHost, Port: dbPort, Name: dbName, RuntimeUser: dbUser, RuntimePassword: dbPassword, TLSMode: tlsMode, TLSRootCert: tlsRootCert, ChannelBinding: channelBinding, RequireAuth: requireAuth, ConnectTimeout: time.Duration(dbConnectTimeout) * time.Second, StatementTimeout: time.Duration(dbStatementTimeout) * time.Second, LockTimeout: time.Duration(dbLockTimeout) * time.Second, MaxConnections: int32(dbMax)},
	}, nil
}

func validateCanonicalOrigin(value *url.URL, requireHTTPS bool) error {
	if value == nil || value.Host == "" || value.User != nil || value.Path != "" || value.RawPath != "" || value.RawQuery != "" || value.Fragment != "" || len(value.String()) > 2048 {
		return errors.New("not an origin")
	}
	if (requireHTTPS && value.Scheme != "https") || (!requireHTTPS && value.Scheme != "https" && value.Scheme != "http") {
		return errors.New("invalid scheme")
	}
	if strings.HasSuffix(value.String(), "/") || value.String() != value.Scheme+"://"+value.Host {
		return errors.New("not canonical")
	}
	return nil
}

func validateHTTPSURL(value *url.URL, allowQuery bool) error {
	if value == nil || value.Scheme != "https" || value.Host == "" || value.User != nil || value.Fragment != "" || (!allowQuery && value.RawQuery != "") || len(value.String()) > 2048 {
		return errors.New("invalid HTTPS URL")
	}
	return nil
}

func uniqueAllowed(values []string, allowed map[string]bool) bool {
	if len(values) == 0 {
		return false
	}
	seen := map[string]bool{}
	for _, value := range values {
		if !allowed[value] || seen[value] {
			return false
		}
		seen[value] = true
	}
	return true
}

func uniqueBounded(values []string, bound int) bool {
	seen := map[string]bool{}
	for _, value := range values {
		if value == "" || len(value) > bound || seen[value] {
			return false
		}
		seen[value] = true
	}
	return true
}
func valueSet(values []string, lower bool) map[string]struct{} {
	result := map[string]struct{}{}
	for _, value := range values {
		if lower {
			value = strings.ToLower(value)
		}
		if value != "" && len(value) <= 256 && !strings.ContainsAny(value, " \t\r\n") {
			result[value] = struct{}{}
		}
	}
	return result
}
func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
