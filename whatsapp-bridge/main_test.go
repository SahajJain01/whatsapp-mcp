package main

import "testing"

func TestRESTAPIPortUses8081(t *testing.T) {
	if restAPIPort != 8081 {
		t.Fatalf("restAPIPort = %d, want 8081", restAPIPort)
	}
}
