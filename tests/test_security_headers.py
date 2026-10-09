"""Security headers on every response (found missing by the ZAP DAST scan)."""
from test_api import client, signup_and_signin  # noqa: F401  (client is a fixture)

EXPECTED = {
    "x-content-type-options": "nosniff",
    "cache-control": "no-store",
    "x-frame-options": "DENY",
    "cross-origin-resource-policy": "same-origin",
    "referrer-policy": "no-referrer",
}


def csp_directives(policy):
    """Parse a Content-Security-Policy into {directive: [sources]}."""
    parts = (d.split() for d in policy.split(";"))
    return {p[0]: p[1:] for p in parts if p}


def assert_headers(response):
    for name, value in EXPECTED.items():
        assert response.headers.get(name) == value, name


def test_public_endpoint_has_security_headers(client):
    response = client.get("/health")
    assert_headers(response)
    assert response.headers["content-security-policy"] == "default-src 'none'; frame-ancestors 'none'"


def test_authenticated_response_is_not_cacheable(client):
    headers = signup_and_signin(client, "alex@example.com")
    response = client.get("/appointments", headers=headers)
    assert response.status_code == 200
    assert_headers(response)


def test_error_responses_have_security_headers(client):
    assert_headers(client.get("/appointments"))           # 401
    assert_headers(client.get("/no-such-path"))           # 404
    assert_headers(client.post("/auth/signin", json={}))  # 422


def test_api_docs_get_a_csp_that_allows_swagger_ui(client):
    response = client.get("/docs")
    assert response.status_code == 200
    directives = csp_directives(response.headers["content-security-policy"])
    assert "https://cdn.jsdelivr.net" in directives["script-src"]
    assert directives["frame-ancestors"] == ["'none'"]
    assert_headers(response)
