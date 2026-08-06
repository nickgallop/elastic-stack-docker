path "secret/data/elastic" {
  capabilities = ["create", "read", "update"]
}

path "secret/metadata/elastic" {
  capabilities = ["read", "list"]
}
