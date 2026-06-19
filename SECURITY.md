# Security Policy

## Supported versions

| Branch | Supported |
|--------|-----------|
| `main` | ✅ Yes    |
| older  | ❌ No     |

`aegis-core-deploy` is a portfolio project. The `main` branch receives all security-relevant updates; no backport releases are planned.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/BinHsu/aegis-core-deploy/security/advisories/new) to disclose a security issue confidentially. GitHub routes the report directly to the maintainer without public exposure.

Please include:

- A clear description of the vulnerability and its impact
- Steps to reproduce or a proof-of-concept
- The affected file paths or manifest sections

The maintainer will acknowledge receipt within 5 business days and aim to resolve confirmed issues within 30 days.

## Scope

This repository contains Kubernetes manifests only. Vulnerabilities in the application code should be reported to [aegis-core](https://github.com/BinHsu/aegis-core/security/advisories/new).
