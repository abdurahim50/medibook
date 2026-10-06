# Signed releases through GitHub OIDC

Date: 2026-10-05 (America/Chicago). AWS account ID replaced with `111122223333`.

## What was built

| Part | Location | Purpose |
| --- | --- | --- |
| Account baseline | separate repository `aws-account-baseline` | GitHub Actions OIDC identity provider, one per AWS account, shared by all projects |
| Bootstrap stack | [`infra/bootstrap/`](../../../infra/bootstrap/) | ECR repository (immutable tags, scan on push) and the release role |
| Release workflow | [`.github/workflows/release.yml`](../../../.github/workflows/release.yml) | Build, Trivy gate, push by digest, CycloneDX SBOM, keyless signing and SBOM attestation, self-verification |
| Deploy-side check | [`scripts/verify-image.sh`](../../../scripts/verify-image.sh) | Verifies signature and attestation before a digest is deployed |

No AWS access keys are stored in GitHub. The workflow exchanges its OIDC token for credentials that last at most one hour.

## Release role trust policy

```json
"Condition": {
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub": "repo:abdurahim50@45608947/medibook@1396824993:ref:refs/heads/main"
  }
}
```

Only workflows running on `main` of this repository can assume the role. Pull requests, other branches, forks and other repositories are refused. Permissions: `ecr:GetAuthorizationToken` (cannot be scoped) and push/pull on the `medibook/api` repository only.

## Finding: first release refused (Release #1)

**Symptom.** Release #1 ([run 37413859036](https://github.com/abdurahim50/medibook/actions/runs/37413859036)) failed at "Assume AWS release role":

```
aws: [ERROR]: An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation:
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**Diagnosis.** `AccessDenied` (not `InvalidIdentityToken`) meant AWS trusted the token's issuer but a trust policy condition did not match. CloudTrail recorded the subject GitHub sent:

```
$ aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity ...
{
  "time": "2026-10-06T04:28:53Z",
  "error": "AccessDenied",
  "sub": "repo:abdurahim50@45608947/medibook@1396824993:ref:refs/heads/main",
  "provider": "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
}
```

| | Subject |
| --- | --- |
| Trust policy expected | `repo:abdurahim50/medibook:ref:refs/heads/main` |
| GitHub sent | `repo:abdurahim50@45608947/medibook@1396824993:ref:refs/heads/main` |

GitHub includes the immutable owner and repository IDs in the subject.

**Fix.** [PR #9](https://github.com/abdurahim50/medibook/pull/9): the trust policy matches the subject with IDs exactly. The policy was not loosened with wildcards. Matching the IDs is stronger than matching names: a deleted and re-created repository, or a released username registered by someone else, has different IDs and cannot assume the role. Plan: 1 to change (the `sub` condition only); applied before merge.

## Result: signed release (Release #2)

Release #2 on merge commit `916ff97` passed in 1 min 12 s.

| | |
| --- | --- |
| Commit | `916ff9709a8350f908753239b3c6699c6204b98f` |
| Tag | `916ff9709a83` |
| Digest | `sha256:8782b73629d165bf1313c2e3ed55fd50773779ab9ecce31361c3f8d317ebaa04` |
| Signed by | `.github/workflows/release.yml@refs/heads/main` |

## Independent verification (local)

Cosign 3.1.3 installed locally from the release binary, checksum verified.

**Positive test**: the digest was signed by the release workflow on `main` and carries an SBOM attestation.

```
$ scripts/verify-image.sh sha256:8782b73629d165bf1313c2e3ed55fd50773779ab9ecce31361c3f8d317ebaa04
Verification for 111122223333.dkr.ecr.us-east-1.amazonaws.com/medibook/api@sha256:8782b736... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
(same checks for the CycloneDX attestation)
OK: sha256:8782b73629d165bf1313c2e3ed55fd50773779ab9ecce31361c3f8d317ebaa04 was signed by release.yml on main and has a CycloneDX SBOM attestation.
```

**Negative test**: the same image checked against a different signer identity (`refs/heads/dev`) is rejected.

```
$ cosign verify --certificate-identity "https://github.com/abdurahim50/medibook/.github/workflows/release.yml@refs/heads/dev" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com "$REG/medibook/api@$DIGEST"
Error: no matching attestations: failed to verify certificate identity: no matching CertificateIdentity found,
last error: expected SAN value "https://github.com/abdurahim50/medibook/.github/workflows/release.yml@refs/heads/dev",
got "https://github.com/abdurahim50/medibook/.github/workflows/release.yml@refs/heads/main"
exit code: 1
```

Verification checks who signed the image, not only that a signature exists.

## Limitations and follow-ups

- **Verification is a manual step before deploy.** Terraform deploys any digest it is given. Enforcing signatures at deploy time (admission policy) is planned for the Kubernetes project.
- **Public transparency log.** Keyless signatures are recorded in the public Sigstore Rekor log, which reveals the repository and workflow identity. Accepted: the repository is planned to be public.
- **Release does not wait for the post-merge CI run.** Both start on push to `main`. Accepted because the ruleset requires all CI checks on the pull request before merge.
- **Local ECR login token** is written to `~/.docker/config.json` unencrypted until logout (12-hour validity). The script logs out on exit; a credential helper would remove the file entirely.
