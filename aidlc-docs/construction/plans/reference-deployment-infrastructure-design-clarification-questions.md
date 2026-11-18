# Infrastructure Design Clarification Questions: reference-deployment

These are follow-ups to `reference-deployment-infrastructure-design-plan.md`. You answered:

- Q1 `x, use /32 operator cidr, but use https`
- Q2 `b`
- Q3 `a`
- Q4 `c`

Q2, Q3 and Q4 are clear. Q1 conflicts with the approved scope, and it has to be resolved before I write the design.

---

## Contradiction 1: HTTPS against the approved scope

Q1 asks for HTTPS. Three approved documents say otherwise:

- `docs/vision.md` §5 Out of scope lists "A load balancer, and any stable public hostname or **TLS certificate**".
- `requirements.md` FR-1.2 and FR-2.4 (plain HTTP on 8080), together with §4 Out of Scope, were approved at 2026-11-18T06:36:50Z.
- Your constraint 4 says that if something excluded is needed, I should say so and stop rather than add it.

HTTPS needs a certificate, and every way of getting one here runs into an exclusion:

| Route | What it needs | Conflicts with |
|---|---|---|
| A publicly trusted certificate (ACM, or Let's Encrypt) | A DNS hostname, plus an ALB, or an exportable certificate installed in the container | Excludes "stable public hostname", "load balancer", and secrets management (vision §6) |
| A self-signed certificate made at image build time | A private key baked into the image in ECR | Puts a private key in a registry artifact. I would not recommend it. |
| A self-signed certificate made when the container starts | `openssl` in the image; nginx listens on 8443 with TLS | Excludes "TLS certificate". The traffic is encrypted, but the server is **not authenticated**: clients must skip verification (`curl -k`, browser warning), so it stops passive eavesdropping but not an active man-in-the-middle. |

### Clarification Question 1
How should the endpoint's protocol be resolved?

A) Keep **plain HTTP on 8080** from the single `/32`, as the vision and the approved requirements specify. This is the exposure go-ahead from the original Q1 option A, and needs no scope change.

B) **Amend the scope** for HTTPS with a self-signed certificate generated when the container starts:
- nginx listens on 8443 with TLS only, and port 8080 is not opened.
- The security group allows 8443 from the `/32`.
- The private key never leaves the running task.
- Clients use `curl -k`.

This changes vision §5 and requirements FR-1.2, FR-1.3 and FR-2.4. I would update `requirements.md` and log the amendment before continuing.

C) **Amend the scope** for HTTPS with a publicly trusted certificate. This needs a hostname, and either an ALB or a certificate-distribution path. It is the largest change, and I do not think it fits in today.

X) Other (please describe after [Answer]: tag below)

[Answer]: A  (given in chat, 2026-11-18T15:37:29Z)

---

## Note on Q2 and Q4

Superseded at 2026-11-18T15:35:38Z. At your request, Q2 changed to A (the deploy workflow automatically checks that the endpoint refuses other addresses) and Q4 changed to A (`scan_on_push`, with findings printed but not gating). The manual-denial note above no longer applies.
