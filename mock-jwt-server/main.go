package main

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	jwt "github.com/golang-jwt/jwt/v5"
)

var (
	privateKey *rsa.PrivateKey
	issuerURL  string
)

func main() {
	issuerURL = os.Getenv("ISSUER_URL")
	if issuerURL == "" {
		issuerURL = "http://localhost:8080"
	}

	var err error
	privateKey, err = rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		log.Fatalf("failed to generate RSA keypair: %v", err)
	}
	log.Println("RSA 2048 keypair generated")

	http.HandleFunc("GET /.well-known/openid-configuration", handleOIDCDiscovery)
	http.HandleFunc("GET /jwks", handleJWKS)
	http.HandleFunc("POST /token", handleToken)

	log.Printf("mock-jwt-server listening on :8080 (issuer=%s)", issuerURL)
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func handleOIDCDiscovery(w http.ResponseWriter, r *http.Request) {
	log.Printf("%s %s", r.Method, r.URL.Path)
	doc := map[string]interface{}{
		"issuer":                                issuerURL,
		"jwks_uri":                              issuerURL + "/jwks",
		"token_endpoint":                        issuerURL + "/token",
		"id_token_signing_alg_values_supported": []string{"RS256"},
		"response_types_supported":              []string{"id_token"},
		"subject_types_supported":               []string{"public"},
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(doc)
}

func handleJWKS(w http.ResponseWriter, r *http.Request) {
	log.Printf("%s %s", r.Method, r.URL.Path)

	jwk := jose.JSONWebKey{
		Key:       &privateKey.PublicKey,
		KeyID:     "mock-key-1",
		Algorithm: "RS256",
		Use:       "sig",
	}

	jwks := jose.JSONWebKeySet{Keys: []jose.JSONWebKey{jwk}}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(jwks)
}

func handleToken(w http.ResponseWriter, r *http.Request) {
	log.Printf("%s %s", r.Method, r.URL.Path)

	if err := r.ParseForm(); err != nil {
		http.Error(w, fmt.Sprintf("bad form data: %v", err), http.StatusBadRequest)
		return
	}

	sub := r.FormValue("sub")
	if sub == "" {
		http.Error(w, `"sub" is required`, http.StatusBadRequest)
		return
	}

	now := time.Now()
	claims := jwt.MapClaims{
		"iss": issuerURL,
		"sub": sub,
		"iat": now.Unix(),
		"exp": now.Add(time.Hour).Unix(),
	}

	// Add every other form/query parameter as a claim.
	for k, vals := range r.Form {
		if k == "sub" {
			continue
		}
		if len(vals) == 1 {
			claims[k] = vals[0]
		} else {
			claims[k] = vals
		}
	}

	token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	token.Header["kid"] = "mock-key-1"

	signed, err := token.SignedString(privateKey)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to sign token: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"token": signed})
}
