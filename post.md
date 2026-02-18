# Kibana on Kubernetes: Deploying with Helm

## What is Kibana?

Kibana is an open-source data visualization and exploration platform built by Elastic, designed to work seamlessly with Elasticsearch. Think of it as the "face" of the Elastic Stack (formerly ELK Stack) — it transforms raw, indexed data stored in Elasticsearch into interactive dashboards, time-series charts, geo-maps, and real-time analytics.

At its core, Kibana provides:

| Feature | Description |
|---|---|
| Discover | query and explore your raw log data interactively |
| Visualize | build charts, histograms, pie graphs, and heat maps |
| Dashboard | combine visualizations into shareable, live-updating panels |
| Alerting & Monitoring | set threshold-based alerts on your metrics |
| Dev Tools | run Elasticsearch queries directly via a console |
| Machine Learning | detect anomalies and forecast trends in your data |
| Canvas | create pixel-perfect, infographic-style presentations of your data |
| Maps | visualize geospatial data with interactive maps |
| Reporting | generate PDF and CSV reports from your dashboards |
| Security | manage user access and permissions for your data |
| APM | monitor application performance and trace requests across services |
| Logs | centralize and analyze log data from all your applications and infrastructure |
| Metrics | collect and visualize system and application metrics in real-time |
| Uptime | monitor the availability and response times of your services |

***

## Why Do We Need Kibana?

Modern applications generate enormous volumes of logs, metrics, and events. Without a proper tool, finding the root cause of an outage means grepping through terabytes of text — slow, error-prone, and painful.

Kibana solves this by providing:

1. **Centralized observability** — all logs from every service, container, and node in one place.
2. **Real-time monitoring** — detect anomalies as they happen, not after the fact.
3. **Faster incident response** — drill from a dashboard spike directly into the offending log lines in seconds.
4. **Non-technical access** — product managers and support teams can explore data without writing queries.

In a Kubernetes environment, where ephemeral pods generate logs that vanish when they restart, Kibana backed by Elasticsearch becomes essential infrastructure.

---

## Deploying Kibana with Helm

Helm is the Kubernetes package manager. It templates complex manifests into reusable, version-controlled charts, making Kibana deployment repeatable and configurable.

**Add the Elastic Helm repository:**

```bash
helm repo add elastic https://helm.elastic.co
helm repo update
```

**Install Kibana:**

```bash
helm install kibana elastic/kibana \
  --namespace logging \
  --create-namespace \
  --set elasticsearchHosts="http://elasticsearch-master:9200" \
  --set service.type=ClusterIP \
  --set replicas=1
```

**Key `values.yaml` settings to customize:**

```yaml
elasticsearchHosts: "http://elasticsearch-master:9200"
replicas: 1

resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "1000m"
    memory: "2Gi"

service:
  type: LoadBalancer
  port: 5601

ingress:
  enabled: true
  hosts:
    - host: kibana.example.com
      paths:
        - path: /
```

Apply a custom values file:

```bash
helm install kibana elastic/kibana -f values.yaml -n logging
```

**Verify the deployment:**

```bash
kubectl get pods -n logging
kubectl port-forward svc/kibana-kibana 5601:5601 -n logging
```

Then open `http://localhost:5601` in your browser.

---

## Summary

Kibana turns Elasticsearch from a search engine into an operational intelligence platform. Deploying it via Helm on Kubernetes makes the entire setup declarative, version-controlled, and easy to reproduce across environments — from local development to production. Combined with Fluentd for log shipping and Elasticsearch for storage, Kibana completes a production-grade observability stack.
