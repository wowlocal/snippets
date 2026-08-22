package httpapi

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/wowlocal/snippets/server/internal/api"
	"github.com/wowlocal/snippets/server/internal/auth"
	"github.com/wowlocal/snippets/server/internal/config"
	"github.com/wowlocal/snippets/server/internal/domain"
)

type fakeValidator struct {
	principal    domain.Principal
	requirements []auth.Requirement
}

type panicValidator struct{}

func (panicValidator) Validate(context.Context, string, auth.Requirement) (domain.Principal, error) {
	panic("test panic")
}

func (v *fakeValidator) Validate(_ context.Context, token string, requirement auth.Requirement) (domain.Principal, error) {
	v.requirements = append(v.requirements, requirement)
	if token != "valid-token" {
		return domain.Principal{}, domain.NewError(domain.AuthenticationRequired)
	}
	return v.principal, nil
}

func TestDiscoveryIsProtocolTwoAndUsesSeparateOriginResource(t *testing.T) {
	server, _, _, _ := testHTTPServer(t)
	response := perform(t, server, http.MethodGet, "/.well-known/snippets-sync", "", "")
	if response.Code != 200 {
		t.Fatalf("status %d: %s", response.Code, response.Body.String())
	}
	var value map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	if value["protocolMajor"] != float64(2) || value["apiBase"] != "https://sync.example.test/v2" {
		t.Fatalf("bad discovery: %#v", value)
	}
	oidc := value["oidc"].(map[string]any)
	if oidc["resource"] != "https://sync.example.test" {
		t.Fatalf("bad resource: %#v", oidc)
	}
	capabilities := value["capabilities"].([]any)
	if !containsJSONValue(capabilities, "oauth-refresh-token-rotation") {
		t.Fatalf("refresh-token rotation capability missing: %#v", capabilities)
	}
}

func TestBatchRequiresAndAppliesExpectedScope(t *testing.T) {
	server, store, principal, _ := testHTTPServer(t)
	space, err := store.CreateSpace(context.Background(), principal, nil)
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(map[string]any{
		"expectedScope": map[string]any{
			"serverInstanceId": "00000000-0000-4000-8000-000000000001",
			"spaceId":          space.Scope.SpaceID, "scopeBinding": space.Scope.ScopeBinding,
			"datasetGeneration": space.Scope.DatasetGeneration, "feedEpoch": space.Scope.FeedEpoch,
		},
		"items": []any{map[string]any{
			"record": map[string]any{
				"id": uuid.New(), "rev": "1", "deleted": false, "blob": []byte("opaque"),
			},
			"expectedRecordVersion": nil,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	path := "/v2/spaces/" + space.Scope.SpaceID.String() + "/records/batch"
	response := perform(t, server, http.MethodPost, path, string(body), "valid-token")
	if response.Code != http.StatusOK {
		t.Fatalf("submit %d: %s", response.Code, response.Body.String())
	}
	var wrongInstance map[string]any
	if err := json.Unmarshal(body, &wrongInstance); err != nil {
		t.Fatal(err)
	}
	wrongInstance["expectedScope"].(map[string]any)["serverInstanceId"] = uuid.New()
	wrongBody, err := json.Marshal(wrongInstance)
	if err != nil {
		t.Fatal(err)
	}
	wrongResponse := perform(t, server, http.MethodPost, path, string(wrongBody), "valid-token")
	assertProblem(t, wrongResponse, http.StatusForbidden, domain.Forbidden)

	missingScope := perform(t, server, http.MethodPost, path, `{"items":[]}`, "valid-token")
	assertProblem(t, missingScope, http.StatusBadRequest, domain.InvalidRequest)
}

func TestCreateAndListSpacesUseNestedScope(t *testing.T) {
	server, _, _, _ := testHTTPServer(t)
	request := httptest.NewRequest(http.MethodPost, "https://local/v2/spaces", nil)
	request.Header.Set("Authorization", "Bearer valid-token")
	request.Header.Set("Idempotency-Key", "7b28d156-77fd-4f7f-bdf3-234f7d97ac91")
	created := httptest.NewRecorder()
	server.ServeHTTP(created, request)
	if created.Code != 201 {
		t.Fatalf("create %d: %s", created.Code, created.Body.String())
	}
	var value map[string]any
	if err := json.Unmarshal(created.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	scope, ok := value["scope"].(map[string]any)
	if !ok || scope["serverInstanceId"] != "00000000-0000-4000-8000-000000000001" ||
		scope["spaceId"] == nil || value["role"] != "owner" {
		t.Fatalf("flat/invalid response: %#v", value)
	}
	listed := perform(t, server, http.MethodGet, "/v2/spaces", "", "valid-token")
	if listed.Code != 200 || !strings.Contains(listed.Body.String(), `"scope"`) {
		t.Fatalf("list %d: %s", listed.Code, listed.Body.String())
	}
}

func TestAuthenticationRunsBeforeBodyParsing(t *testing.T) {
	server, _, _, _ := testHTTPServer(t)
	path := "/v2/spaces/00000000-0000-4000-8000-000000000001/records/batch"
	response := perform(t, server, http.MethodPost, path, "{", "")
	assertProblem(t, response, 401, domain.AuthenticationRequired)
}

func TestAuthenticationRunsBeforeResponseMemoryAdmission(t *testing.T) {
	service, _, _, _ := testServer(t)
	service.configuration.HTTP.ResponseMemoryBudget = 1
	service.responseBytes.Store(1)
	path := "/v2/spaces/00000000-0000-4000-8000-000000000001/changes?limit=1"
	response := perform(t, service.Handler(), http.MethodGet, path, "", "")
	assertProblem(t, response, http.StatusUnauthorized, domain.AuthenticationRequired)
}

func TestResponseMemoryReservationUsesActualPageAndBatchCardinality(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "https://local/v2/spaces/00000000-0000-4000-8000-000000000001/changes?limit=1", nil)
	request = request.WithContext(withOperationPolicy(request.Context(), policyForRequest(request.Method, request.URL.Path)))
	oneRecord := responseMemoryReservation(request)

	request = httptest.NewRequest(http.MethodGet, "https://local/v2/spaces/00000000-0000-4000-8000-000000000001/changes", nil)
	request = request.WithContext(withOperationPolicy(request.Context(), policyForRequest(request.Method, request.URL.Path)))
	fullPage := responseMemoryReservation(request)

	request = httptest.NewRequest(http.MethodPost, "https://local/v2/spaces/00000000-0000-4000-8000-000000000001/records/batch", nil)
	request = request.WithContext(withOperationPolicy(request.Context(), policyForRequest(request.Method, request.URL.Path)))
	request = request.WithContext(withResponseRecordCount(request.Context(), 2))
	twoConflicts := responseMemoryReservation(request)

	if oneRecord <= 0 || twoConflicts <= oneRecord || twoConflicts > oneRecord*2 ||
		fullPage != maximumRecordResponseReservation || twoConflicts >= fullPage {
		t.Fatalf("non-proportional reservations: one=%d two=%d full=%d", oneRecord, twoConflicts, fullPage)
	}
}

func TestStrictJSONRejectsDuplicateUnknownMissingAndNoncanonicalBase64(t *testing.T) {
	server, store, principal, _ := testHTTPServer(t)
	space, err := store.CreateSpace(context.Background(), principal, nil)
	if err != nil {
		t.Fatal(err)
	}
	path := "/v2/spaces/" + space.Scope.SpaceID.String() + "/records/batch"
	expectedScope, err := json.Marshal(map[string]any{
		"serverInstanceId": "00000000-0000-4000-8000-000000000001",
		"spaceId":          space.Scope.SpaceID, "scopeBinding": space.Scope.ScopeBinding,
		"datasetGeneration": space.Scope.DatasetGeneration, "feedEpoch": space.Scope.FeedEpoch,
	})
	if err != nil {
		t.Fatal(err)
	}
	cases := []string{
		`{"items":[],"items":[]}`,
		`{"items":[],"unexpected":true}`,
		`{"expectedScope":` + string(expectedScope) + `,"items":[{"record":{"id":"00000000-0000-4000-8000-000000000001","rev":"r","deleted":false,"blob":""}}]}`,
		`{"expectedScope":` + string(expectedScope) + `,"items":[{"record":{"id":"00000000-0000-4000-8000-000000000001","rev":"r","deleted":false,"blob":"YQ==\n"},"expectedRecordVersion":null}]}`,
		`{"expectedScope":` + string(expectedScope) + `,"items":[{"record":{"id":"00000000-0000-4000-8000-000000000001","rev":"r","deleted":false,"blob":"YQ==","Blob":"Yg=="},"expectedRecordVersion":null}]}`,
		`{"expectedScope":` + string(expectedScope) + `,"items":[],"Items":[]}`,
		`{"expectedScope":` + string(expectedScope) + `,"ExpectedScope":` + string(expectedScope) + `,"items":[]}`,
	}
	for _, body := range cases {
		response := perform(t, server, http.MethodPost, path, body, "valid-token")
		assertProblem(t, response, 400, domain.InvalidRequest)
	}
}

func TestBodylessOperationsRejectBodiesAndUnknownRoutesAreClosedProblems(t *testing.T) {
	server, _, _, _ := testHTTPServer(t)
	withBody := perform(t, server, http.MethodGet, "/v2/spaces", "{}", "valid-token")
	assertProblem(t, withBody, 400, domain.InvalidRequest)
	unknown := perform(t, server, http.MethodGet, "/v1/spaces", "", "")
	assertProblem(t, unknown, 404, domain.NotFound)
}

func TestHealthChecksBypassUserConcurrencyAdmission(t *testing.T) {
	service, _, _, _ := testServer(t)
	for index := 0; index < cap(service.concurrent); index++ {
		service.concurrent <- struct{}{}
	}
	defer func() {
		for index := 0; index < cap(service.concurrent); index++ {
			<-service.concurrent
		}
	}()
	for _, path := range []string{"/health/live", "/health/ready"} {
		response := perform(t, service.Handler(), http.MethodGet, path, "", "")
		if response.Code != http.StatusOK {
			t.Fatalf("%s was rejected by user admission: %d %s", path, response.Code, response.Body.String())
		}
	}
}

func TestRecordResponsesShareIndependentMemoryAdmissionBudget(t *testing.T) {
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		service, store, principal, _ := testServer(t)
		space, err := store.CreateSpace(context.Background(), principal, nil)
		if err != nil {
			t.Fatal(err)
		}
		path := "/v2/spaces/" + space.Scope.SpaceID.String() + "/changes"
		body := ""
		if method == http.MethodPost {
			path = "/v2/spaces/" + space.Scope.SpaceID.String() + "/records/batch"
			encoded, err := json.Marshal(map[string]any{
				"expectedScope": map[string]any{
					"serverInstanceId":  service.configuration.ServerInstanceID,
					"spaceId":           space.Scope.SpaceID,
					"scopeBinding":      space.Scope.ScopeBinding,
					"datasetGeneration": space.Scope.DatasetGeneration,
					"feedEpoch":         space.Scope.FeedEpoch,
				},
				"items": []any{map[string]any{
					"record":                map[string]any{"id": uuid.New(), "rev": "r", "deleted": false, "blob": ""},
					"expectedRecordVersion": nil,
				}},
			})
			if err != nil {
				t.Fatal(err)
			}
			body = string(encoded)
		}
		service.configuration.HTTP.ResponseMemoryBudget = maximumRecordResponseReservation
		service.responseBytes.Store(maximumRecordResponseReservation)
		response := perform(t, service.Handler(), method, path, body, "valid-token")
		assertProblem(t, response, http.StatusTooManyRequests, domain.RateLimited)
	}
}

func TestPanicRecoveryUsesCorrelatedRequestID(t *testing.T) {
	service, _, _, _ := testServer(t)
	service.validator = panicValidator{}
	response := perform(t, service.Handler(), http.MethodGet, "/v2/spaces", "", "valid-token")
	assertProblem(t, response, http.StatusInternalServerError, domain.InternalError)
}

func TestOperationPoliciesMatchOpenAPIContract(t *testing.T) {
	document, err := api.GetSwagger()
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]string{
		"getDiscovery": "discovery", "getLiveness": "liveness", "getReadiness": "readiness",
		"revokeCurrentSession": "revoke_session", "listSpaces": "list_spaces", "createSpace": "create_space",
		"getSpace": "get_space", "getChanges": "get_changes", "submitRecords": "submit_records",
		"getRecoveryEnvelope": "get_recovery_envelope", "putRecoveryEnvelope": "put_recovery_envelope",
		"createPairing": "create_pairing", "getPairing": "get_pairing", "cancelPairing": "cancel_pairing",
		"approvePairing": "approve_pairing", "claimPairing": "claim_pairing",
	}
	seen := 0
	for path, pathItem := range document.Paths.Map() {
		concretePath := strings.ReplaceAll(strings.ReplaceAll(path, "{space}", "00000000-0000-4000-8000-000000000001"), "{pairing}", "00000000-0000-4000-8000-000000000002")
		for method, operation := range pathItem.Operations() {
			policy := policyForRequest(method, concretePath)
			operationID := operation.OperationID
			if operationID != "" {
				operationID = strings.ToLower(operationID[:1]) + operationID[1:]
			}
			expectedName, exists := names[operationID]
			if !exists || policy.name != expectedName {
				t.Errorf("%s %s policy name %q does not match operationId %q", method, path, policy.name, operation.OperationID)
			}
			public := operation.Security != nil && len(*operation.Security) == 0
			if policy.public != public || policy.hasBody != (operation.RequestBody != nil) {
				t.Errorf("%s %s policy metadata drifted: %#v", method, path, policy)
			}
			requirement := auth.Standard
			if operation.Extensions["x-snippets-auth-requirement"] == "recent-phishing-resistant" {
				requirement = auth.RecentPhishingResistant
			}
			if policy.requirement != requirement {
				t.Errorf("%s %s authentication requirement drifted", method, path)
			}
			seen++
		}
	}
	if seen != len(names) {
		t.Fatalf("checked %d operations, expected %d", seen, len(names))
	}
}

func TestStepUpIsRequiredForRecoveryWrites(t *testing.T) {
	server, store, principal, validator := testHTTPServer(t)
	space, _ := store.CreateSpace(context.Background(), principal, nil)
	path := "/v2/spaces/" + space.Scope.SpaceID.String() + "/recovery-envelope"
	body := `{"expectedVersion":null,"keyEpoch":1,"algorithm":"snippets-recovery-hkdf-sha256-aes256gcm-v1","ciphertext":""}`
	response := perform(t, server, http.MethodPut, path, body, "valid-token")
	if response.Code != 200 {
		t.Fatalf("put %d: %s", response.Code, response.Body.String())
	}
	if len(validator.requirements) != 1 || validator.requirements[0] != auth.RecentPhishingResistant {
		t.Fatalf("authentication requirement: %#v", validator.requirements)
	}
}

func TestResourceLogoutImmediatelyDeniesCredential(t *testing.T) {
	server, _, _, _ := testHTTPServer(t)
	logout := perform(t, server, http.MethodDelete, "/v2/session", "", "valid-token")
	if logout.Code != 204 {
		t.Fatalf("logout %d: %s", logout.Code, logout.Body.String())
	}
	after := perform(t, server, http.MethodGet, "/v2/spaces", "", "valid-token")
	assertProblem(t, after, 401, domain.AuthenticationRequired)
}

func TestPairingEnvelopeIsReleasedOnlyByAtomicClaim(t *testing.T) {
	server, store, principal, _ := testHTTPServer(t)
	space, err := store.CreateSpace(context.Background(), principal, nil)
	if err != nil {
		t.Fatal(err)
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicKey := elliptic.Marshal(elliptic.P256(), privateKey.X, privateKey.Y)
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	createBody, _ := json.Marshal(map[string]any{
		"recipientPublicKey": publicKey,
		"nonce":              nonce,
		"expiresInSeconds":   300,
	})
	basePath := "/v2/spaces/" + space.Scope.SpaceID.String() + "/pairings"
	created := perform(t, server, http.MethodPost, basePath, string(createBody), "valid-token")
	if created.Code != http.StatusCreated {
		t.Fatalf("create %d: %s", created.Code, created.Body.String())
	}
	var createResponse struct {
		Pairing struct {
			PairingID uuid.UUID `json:"pairingId"`
		} `json:"pairing"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &createResponse); err != nil || createResponse.Pairing.PairingID == uuid.Nil {
		t.Fatalf("invalid create response: %v %s", err, created.Body.String())
	}
	digest := sha256.Sum256(publicKey)
	approveBody, _ := json.Marshal(map[string]any{
		"recipientKeyHash": digest[:],
		"algorithm":        domain.PairingAlgorithm,
		"ciphertext":       []byte{1, 2, 3},
	})
	pairingPath := basePath + "/" + createResponse.Pairing.PairingID.String()
	approved := perform(t, server, http.MethodPut, pairingPath+"/approval", string(approveBody), "valid-token")
	if approved.Code != http.StatusOK {
		t.Fatalf("approve %d: %s", approved.Code, approved.Body.String())
	}
	var approvedObject map[string]any
	if err := json.Unmarshal(approved.Body.Bytes(), &approvedObject); err != nil {
		t.Fatal(err)
	}
	approvedPairing := approvedObject["pairing"].(map[string]any)
	if approvedPairing["state"] != "approved" || approvedPairing["algorithm"] != nil || approvedPairing["ciphertext"] != nil {
		t.Fatalf("approval leaked envelope metadata: %#v", approvedPairing)
	}
	polled := perform(t, server, http.MethodGet, pairingPath, "", "valid-token")
	if polled.Code != http.StatusOK || strings.Contains(polled.Body.String(), "algorithm") || strings.Contains(polled.Body.String(), "ciphertext") {
		t.Fatalf("poll leaked envelope: %d %s", polled.Code, polled.Body.String())
	}
	claimed := perform(t, server, http.MethodPost, pairingPath+"/claim", "", "valid-token")
	if claimed.Code != http.StatusOK || !strings.Contains(claimed.Body.String(), domain.PairingAlgorithm) || !strings.Contains(claimed.Body.String(), `"ciphertext":"AQID"`) {
		t.Fatalf("claim did not release envelope: %d %s", claimed.Code, claimed.Body.String())
	}
	replay := perform(t, server, http.MethodPost, pairingPath+"/claim", "", "valid-token")
	if replay.Code != http.StatusOK || !strings.Contains(replay.Body.String(), `"ciphertext":"AQID"`) {
		t.Fatalf("claim retry was not idempotent: %d %s", replay.Code, replay.Body.String())
	}
}

func testHTTPServer(t *testing.T) (http.Handler, *domain.MemoryStore, domain.Principal, *fakeValidator) {
	service, store, principal, validator := testServer(t)
	return service.Handler(), store, principal, validator
}

func testServer(t *testing.T) (*Server, *domain.MemoryStore, domain.Principal, *fakeValidator) {
	t.Helper()
	base, _ := url.Parse("https://sync.example.test")
	issuer, _ := url.Parse("https://identity.example.test/")
	jwks, _ := url.Parse("https://identity.example.test/jwks")
	configuration := config.Server{Environment: config.Testing, PublicBaseURL: base, ServerInstanceID: uuid.MustParse("00000000-0000-4000-8000-000000000001"), ServerVersion: "test", OIDC: config.OIDC{Issuer: issuer, Audience: base.String(), ClientID: "test-client", Scopes: []string{"openid", "offline_access"}, JWKSURL: jwks, MaximumTokenAge: 300 * time.Second, StepUpMaximumAge: 300 * time.Second, StepUpAMR: map[string]struct{}{"webauthn": {}}, StepUpACR: map[string]struct{}{}}, HTTP: config.HTTP{ReadinessTimeout: time.Second, BodyTimeout: time.Second, MaximumConcurrent: 32, BodyMemoryBudget: 64 * 1024 * 1024, GlobalRate: 1000, GlobalBurst: 1000, PrincipalRate: 1000, PrincipalBurst: 1000}}
	store, err := domain.NewMemoryStore(configuration.ServerInstanceID, make([]byte, 32), domain.ProductionQuota)
	if err != nil {
		t.Fatal(err)
	}
	var identity, credential [32]byte
	identity[0] = 1
	credential[0] = 2
	principal := domain.Principal{IdentityDigest: identity, CredentialDigest: credential, ExpiresAt: time.Now().Add(time.Hour)}
	validator := &fakeValidator{principal: principal}
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	return NewServer(configuration, store, validator, logger), store, principal, validator
}

func perform(t *testing.T, handler http.Handler, method, path, body, token string) *httptest.ResponseRecorder {
	t.Helper()
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	request := httptest.NewRequest(method, "https://local"+path, reader)
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func containsJSONValue(values []any, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}
func assertProblem(t *testing.T, response *httptest.ResponseRecorder, status int, code domain.ErrorCode) {
	t.Helper()
	if response.Code != status {
		t.Fatalf("status %d, want %d: %s", response.Code, status, response.Body.String())
	}
	if response.Header().Get("Content-Type") != "application/problem+json" {
		t.Fatalf("content type: %s", response.Header().Get("Content-Type"))
	}
	var value map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &value); err != nil {
		t.Fatal(err)
	}
	if value["code"] != string(code) || value["status"] != float64(status) || value["type"] != "urn:snippets:error:"+string(code) || value["requestId"] == nil || value["detail"] != nil {
		t.Fatalf("problem shape: %#v", value)
	}
	if requestID, ok := value["requestId"].(string); !ok || requestID == "" || response.Header().Get("X-Request-ID") != requestID {
		t.Fatalf("uncorrelated request ID: header=%q body=%#v", response.Header().Get("X-Request-ID"), value["requestId"])
	}
}
