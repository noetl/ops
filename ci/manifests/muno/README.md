# Muno GKE Manifests

This manifest set deploys the Adiona/Muno frontend to GKE at
`muno.mestumre.dev`.

The image is built in the `noetl/muno` repository with Auth0 SPA values from
the shared `auth0_client` secret and the restricted Google Maps browser key.
No secrets are stored in these manifests.

The deployment expects an image pull secret named `ghcr-pull` in the `muno`
namespace when the GHCR package is private.

Apply:

```bash
kubectl -n muno create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<github-token>
kubectl apply -f ci/manifests/muno/
kubectl -n muno rollout status deployment/muno
kubectl -n muno get ingress muno
```

After the Ingress address appears, create the Cloudflare `A` record:

- Name: `muno`
- Content: the GKE Ingress IP
- Proxy: enable after the GKE managed certificate is active

If the managed certificate stays in `Provisioning`, temporarily set the DNS
record to DNS-only until `kubectl -n muno get managedcertificate muno` reports
`Active`, then enable the Cloudflare proxy.
