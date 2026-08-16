package api

import "testing"

func TestGeneratedContractHasOnlyVersionTwoDataPlane(t *testing.T) {
	document, err := GetSwagger()
	if err != nil {
		t.Fatal(err)
	}
	expected := map[string]bool{
		"/.well-known/snippets-sync": true, "/health/live": true, "/health/ready": true,
		"/v2/session": true, "/v2/spaces": true, "/v2/spaces/{space}": true,
		"/v2/spaces/{space}/changes": true, "/v2/spaces/{space}/records/batch": true,
		"/v2/spaces/{space}/recovery-envelope": true, "/v2/spaces/{space}/pairings": true,
		"/v2/spaces/{space}/pairings/{pairing}": true, "/v2/spaces/{space}/pairings/{pairing}/approval": true,
		"/v2/spaces/{space}/pairings/{pairing}/claim": true,
	}
	if document.Paths.Len() != len(expected) {
		t.Fatalf("unexpected path count: %d", document.Paths.Len())
	}
	for path := range expected {
		if document.Paths.Find(path) == nil {
			t.Errorf("missing %s", path)
		}
	}
	for path := range document.Paths.Map() {
		if !expected[path] {
			t.Errorf("unexpected path %s", path)
		}
	}
}
