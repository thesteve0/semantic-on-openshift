# Semantic Router Deployment Guide

This guide walks you through deploying the semantic router on OpenShift with automatic model downloads at startup.

## Prerequisites

- OpenShift cluster access with `oc` CLI configured
- Namespace created: `vllm-semantic-router-system`
- vLLM backend services deployed and accessible (optional for testing classification only)

## Architecture Overview

The deployment consists of:
- **Semantic Router**: Official image `ghcr.io/vllm-project/semantic-router/extproc:latest`
- **Init Container**: Downloads 4 ModernBERT classification models from HuggingFace to PVC
- **Envoy Proxy**: Sidecar container for routing and observability
- **Persistent Storage**: 10Gi for models, 5Gi for cache

Models are downloaded once and persisted to PVC for fast subsequent startups.

## Step 1: Create Kubernetes Resources

Apply the manifests in this order:

```bash
# Log into OpenShift
oc login --token=<your-token> --server=<your-api-server>
oc project vllm-semantic-router-system

# Create the PVCs first (for models and cache)
oc apply -f openshift/pvc.yaml

# Create the ConfigMaps
oc apply -f openshift/envoy-configmap.yaml
oc apply -f openshift/semantic-router-config.yaml

# Create the Deployment
oc apply -f openshift/deployment.yaml

# Create the Service
oc apply -f openshift/service.yaml
```

## Step 2: Monitor Model Download

The init container will download 4 ModernBERT classification models from HuggingFace. This takes 2-5 minutes on first deployment.

```bash
# Watch the init container download models
oc logs -f deployment/semantic-router -c model-downloader

# You should see output like:
# Downloading category classifier model...
# Downloading PII classifier model...
# Downloading jailbreak classifier model...
# Downloading PII token classifier model...
# All classifier models downloaded successfully!
```

## Step 3: Verify Deployment

```bash
# Check pod status (should show 2/2 containers running)
oc get pods -l app=semantic-router

# Expected output:
# NAME                               READY   STATUS    RESTARTS   AGE
# semantic-router-xxxxxxxxxx-xxxxx   2/2     Running   0          5m

# Check logs - semantic router
oc logs -f deployment/semantic-router -c semantic-router

# Check logs - envoy proxy (JSON format)
oc logs -f deployment/semantic-router -c envoy-proxy
```

## Step 4: Test the Deployment

### Port-Forward Setup

```bash
# Port-forward to Envoy proxy (main entry point)
oc port-forward deployment/semantic-router 8080:8801
```

### Test 1: Philosophy Query (Qwen with Reasoning)

This query should be classified as "philosophy" and routed to the qwen-14b-quant model with reasoning enabled.

```bash
curl http://localhost:8080/v1/chat/completions \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [
      {"role": "user", "content": "Please write 3 paragraphs comparing the epistemology of Immanuel Kant and Willard Van Orman Quine on how well we can actually understand shared experiences with other humans."}
    ],
    "temperature": 0.7,
    "max_tokens": 2000
  }'
```

Expected behavior:
- Category: `philosophy`
- Model: `qwen-14b-quant`
- Reasoning: enabled
- Response includes `<thinking>` tags

### Test 2: Simple Math Query

```bash
curl http://localhost:8080/v1/chat/completions \
  -v -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [
      {"role": "user", "content": "What is 2 + 2."}
    ],
    "temperature": 0.7,
    "max_tokens": 2000
  }'
```

Expected behavior:
- Category: `other`
- Model: `mistral-small-24b-instruct-2501-fp8-dynamic-150`
- Quick response

### Test 3: Medical Query (Specialized Model)

```bash
curl http://localhost:8080/v1/chat/completions \
  -v -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto",
    "messages": [
      {"role": "user", "content": "For diffuse B-Cell non-Hodgkins lymphoma, what is the likelihood of curing a 40 year old male and what are the latest advances in treatment"}
    ],
    "temperature": 0.7,
    "max_tokens": 2000
  }'
```

Expected behavior:
- Category: `health`
- Model: `medtron3-phi4-14b`
- Detailed evidence-based medical response

### Test 4: Check Routing Decisions

```bash
# View Envoy access logs to see routing decisions
oc logs deployment/semantic-router -c envoy-proxy --tail=10

# Look for JSON fields:
# - "selected_model": which model was chosen
# - "selected_endpoint": IP:port of target backend
# - "upstream_cluster": which cluster handled the request
# - "response_code": HTTP status code
```

### Test 5: Check Metrics

```bash
# Access Prometheus metrics from semantic router
curl http://localhost:9190/metrics
```

## Step 5: Access Admin Interfaces

### Envoy Admin Interface

```bash
# Port-forward to Envoy admin
oc port-forward deployment/semantic-router 19000:19000

# In another terminal:
# View cluster status
curl http://localhost:19000/clusters

# View config dump
curl http://localhost:19000/config_dump | jq

# View stats
curl http://localhost:19000/stats
```

## Troubleshooting

### Init container fails to download models

```bash
# Check init container logs
oc logs deployment/semantic-router -c model-downloader

# Common issues:
# - Network connectivity to huggingface.co
# - Insufficient PVC storage (need 10Gi)
# - Rate limiting from HuggingFace
```

### Pod stuck in Init state

```bash
# Describe the pod to see init container status
oc describe pod -l app=semantic-router

# Check events
oc get events --sort-by='.lastTimestamp' | grep semantic-router

# Verify PVC is bound
oc get pvc
```

### Models not loading in semantic router

```bash
# Check if models are on the PVC
oc exec deployment/semantic-router -c semantic-router -- ls -la /app/models

# Should show:
# category_classifier_modernbert-base_model/
# pii_classifier_modernbert-base_model/
# jailbreak_classifier_modernbert-base_model/
# pii_classifier_modernbert-base_presidio_token_model/

# Check model file permissions
oc exec deployment/semantic-router -c semantic-router -- find /app/models -type f -name "*.safetensors"
```

### Classification not working

```bash
# Check semantic router logs for errors
oc logs deployment/semantic-router -c semantic-router | grep -i error

# Verify config is mounted correctly
oc exec deployment/semantic-router -c semantic-router -- cat /app/config/config.yaml

# Look for model loading messages in logs
oc logs deployment/semantic-router -c semantic-router | grep -i "loading model"
```

### Routing to wrong backend

```bash
# Check Envoy logs to see routing decisions
oc logs deployment/semantic-router -c envoy-proxy --tail=50 | jq '.selected_endpoint'

# Verify vLLM endpoints are accessible
oc get svc

# Test direct connection to vLLM backend
oc run test-curl --rm -it --image=curlimages/curl -- curl http://<vllm-service-ip>/v1/models
```

### Cache issues

The semantic cache is stored in memory and persisted to PVC. To clear the cache:

```bash
# Restart the deployment
oc rollout restart deployment/semantic-router

# Or delete the cache PVC (will recreate on next start)
oc delete pvc semantic-router-cache
oc apply -f openshift/pvc.yaml
```

## Configuration

### Configured vLLM Backends

The semantic router is currently configured to route to three vLLM backends:

1. **mistral-small-24b-instruct-2501-fp8-dynamic-150** (172.30.95.11:80)
   - General purpose model
   - Used for "other" category queries
   - Default fallback model

2. **qwen-14b-quant** (172.30.68.65:80)
   - Reasoning-capable model
   - Used for philosophy, engineering, computer science
   - Supports `<thinking>` mode

3. **medtron3-phi4-14b** (172.30.118.1:80)
   - Medical fine-tuned model
   - Used for health category queries
   - Evidence-based responses

### Configured Categories

The router classifies queries into 5 main categories:

- **computer science**: Routes to qwen-14b-quant
- **engineering**: Routes to qwen-14b-quant
- **philosophy**: Routes to qwen-14b-quant with reasoning enabled
- **health**: Routes to medtron3-phi4-14b
- **other**: Routes to mistral-small (default)

### Updating Configuration

To update the semantic router configuration:

```bash
# Edit the ConfigMap
oc edit configmap semantic-router-config

# Or apply changes from file
oc apply -f openshift/semantic-router-config.yaml

# Restart the deployment to pick up changes
oc rollout restart deployment/semantic-router
```

### Adding New vLLM Backends

1. Deploy your vLLM service and get its ClusterIP
2. Update `semantic-router-config.yaml`:
   ```yaml
   vllm_endpoints:
     - name: "new-model-name"
       address: 172.30.x.x  # ClusterIP of the vLLM service
       port: 80
       weight: 1
   ```
3. Add model configuration:
   ```yaml
   model_config:
     "new-model-name":
       preferred_endpoints: ["new-model-name"]
       pii_policy:
         allow_by_default: true
         pii_types_allowed: ["EMAIL_ADDRESS"]
   ```
4. Update category to use the new model:
   ```yaml
   categories:
     - name: your-category
       system_prompt: "Your prompt..."
       model_scores:
         - model: new-model-name
           score: 0.7
           use_reasoning: false
   ```

### Enable External Access

To expose the service outside the cluster:

```bash
# Create a Route
oc expose svc/semantic-router-service --port=http

# Get the URL
oc get route semantic-router-service
```

## Cleanup

To remove everything:

```bash
oc delete -f openshift/service.yaml
oc delete -f openshift/deployment.yaml
oc delete -f openshift/semantic-router-config.yaml
oc delete -f openshift/envoy-configmap.yaml
oc delete -f openshift/pvc.yaml
```

## Additional Resources

- **Semantic Router Documentation**: https://vllm-semantic-router.com/docs/overview/semantic-router-overview
- **GitHub Repository**: https://github.com/vllm-project/semantic-router
- **Supported Categories**: https://vllm-semantic-router.com/docs/overview/categories/supported-categories
- **HuggingFace Models**: https://huggingface.co/LLM-Semantic-Router
