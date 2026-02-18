This `helm/` directory contains simple Helm charts converted from the repository's `docker-compose.yaml`.

Charts included (one per service):

- `httpd` — simple Apache httpd deployment and service
- `fluentd` — Fluentd deployment, includes a `ConfigMap` for `fluent.conf`
- `elasticsearch` — single-node Elasticsearch
- `kibana` — Kibana configured to talk to `elasticsearch`

Notes:

- `portainer` was intentionally omitted as requested.
- These charts are minimal starters. Edit `values.yaml` in each chart to suit your cluster.

Quick install example:

1. Install Elasticsearch first:

```bash
helm install elasticsearch ./helm/elasticsearch
```

2. Install Kibana (it expects service name `elasticsearch`):

```bash
helm install kibana ./helm/kibana
```

3. Install Fluentd and httpd:

```bash
helm install fluentd ./helm/fluentd
helm install httpd ./helm/httpd
```

Adjust `--namespace` or `values.yaml` as needed.
