# Semantic Router Deployment Guide

This guide walks you through building and deploying the semantic router with baked-in classification models.

## Prerequisites

- OpenShift cluster access with `oc` CLI configured
- Podman or Docker installed locally
- Namespace created: `vllm-semantic-router-system`

## Step 1: Build the Custom Image

```bash
# Navigate to the directory containing your Dockerfile
cd /path/to/your/semantic-router-project

# Build the image with Podman
podman build -t semantic-router-with-models:v1.0.0 -f Dockerfile .

# Note: Build time will be ~10-15 minutes due to model downloads
# The final image will be ~2-4GB depending on model sizes
```

## Step 2: Push to Github Registry

```bash
# Log into OpenShift
oc login --token=<your-token> --server=<your-api-server>
oc project vllm-semantic-router-system

podman build -t semantic-router-with-models:v1.0.0 -f Containerfile .
podman login ghcr.io
podman tag semantic-router-with-models:v1.0.0  ghcr.io/thesteve0/semantic-router-with-models:v1.0.0


# Push the image
podman p podman push ghcr.io/thesteve0/semantic-router-with-models:v1.0.0
```

## Step 3: Create Kubernetes Resources

Apply the manifests in this order:

```bash
# Create the PVC first (for runtime caching)
oc apply -f pvc.yaml

# Create the ConfigMaps
oc apply -f envoy-config.yaml
oc apply -f semantic-router-config.yaml

# Create the Deployment
oc apply -f deployment.yaml

# Create the Service
oc apply -f service.yaml
```

## Step 4: Verify Deployment

```bash
# Check pod status
oc get pods -l app=semantic-router

# Expected output:
# NAME                               READY   STATUS    RESTARTS   AGE
# semantic-router-xxxxxxxxxx-xxxxx   2/2     Running   0          2m

# Check logs - semantic router
oc logs -f deploy/semantic-router -c semantic-router

# Check logs - envoy proxy
oc logs -f deploy/semantic-router -c envoy-proxy
```

## Step 5: Test the Deployment

### Test 1: Check the /v1/models endpoint

```bash
# Port-forward to access the service
oc port-forward svc/semantic-router-service 8080:80

# In another terminal, test the models endpoint
curl http://localhost:8080/v1/models
```

### Test 2: Send a classification request

```bash
# Send a math query
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "test",
    "messages": [
      {"role": "user", "content": "What is 2+2?"}
    ]
  }'

# Check the Envoy logs to see the routing decision
oc logs -f deploy/semantic-router -c envoy-proxy | jq
```

Expected log output will show:
- `router_category`: "math"
- `router_confidence`: "0.95" (or similar)
- `selected_endpoint`: "placeholder-model-a-service"
- The request will fail (connection refused) because backends don't exist yet

### Test 3: Check metrics

```bash
# Access Prometheus metrics
curl http://localhost:8080:9190/metrics
```

## Step 6: Access Admin Interfaces

### Envoy Admin Interface

```bash
# Port-forward to Envoy admin
oc port-forward svc/semantic-router-service 19000:19000

# View cluster status
curl http://localhost:19000/clusters

# View config dump
curl http://localhost:19000/config_dump
```

## Troubleshooting

### Pod won't start

```bash
# Describe the pod
oc describe pod -l app=semantic-router

# Check events
oc get events --sort-by='.lastTimestamp'
```

### Models not loading

```bash
# Check if models are in the image
oc exec deploy/semantic-router -c semantic-router -- ls -la /app/models

# Should show:
# category_classifier_modernbert-base_model/
# pii_classifier_modernbert-base_model/
# jailbreak_classifier_modernbert-base_model/
# pii_classifier_modernbert-base_presidio_token_model/
```

### Classification not working

```bash
# Check semantic router logs for errors
oc logs deploy/semantic-router -c semantic-router | grep -i error

# Verify config is mounted correctly
oc exec deploy/semantic-router -c semantic-router -- cat /app/config/config.yaml
```

## Next Steps

### Deploy LLM Backend Services

When you're ready to deploy actual LLM services:

1. Create separate Deployments for your LLM models
2. Create Services to expose them
3. Update `semantic-router-config.yaml`:
   ```yaml
   vllm_endpoints:
     - name: "model-a-endpoint"
       address: "model-a-service.vllm-semantic-router-system.svc.cluster.local"
       port: 8000
   ```
4. Apply the updated config:
   ```bash
   oc apply -f semantic-router-config.yaml
   oc rollout restart deploy/semantic-router
   ```

### Enable External Access

To expose the service outside the cluster:

```bash
# Create a Route
oc expose svc/semantic-router-service

# Get the URL
oc get route semantic-router-service
```

## Configuration Updates

To update the semantic router configuration without rebuilding the image:

```bash
# Edit the ConfigMap
oc edit configmap semantic-router-config

# Restart the deployment to pick up changes
oc rollout restart deploy/semantic-router
```

## Cleanup

To remove everything:

```bash
oc delete -f service.yaml
oc delete -f deployment.yaml
oc delete -f semantic-router-config.yaml
oc delete -f envoy-config.yaml
oc delete -f pvc.yaml
```
