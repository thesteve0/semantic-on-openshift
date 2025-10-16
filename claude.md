# vLLM Semantic Router - Kubernetes Deployment Project

## Project Overview

This project deploys the vLLM Semantic Router as an intelligent request classifier and router for Large Language Models (LLMs). The semantic router analyzes incoming requests, classifies them by category (math, science, business, etc.), detects security issues (PII, jailbreaks), and routes them to appropriate backend models.

**Purpose:** Demo for booth presentation at a conference/trade show  
**Environment:** Red Hat OpenShift AI cluster  
**Current Phase:** Phase 1 - Getting semantic router infrastructure working (no LLM backends yet)

## Multi-Phase Project Plan

### Phase 1: Semantic Router Infrastructure (CURRENT)
- ✅ Build custom image with baked-in ModernBERT classification models
- 🔄 Deploy semantic-router + Envoy proxy pod
- 🔄 Verify classification and routing decisions work
- 🔄 Test all safety features (PII detection, jailbreak guard)
- **Goal:** Router classifies requests and shows routing decisions, even without backends

### Phase 2: LLM Backend Deployment (FUTURE)
- Deploy actual LLM models (likely using vLLM, KServe, or llm-d)
- Create separate Deployments and Services for model-a and model-b
- Update semantic router config to point to real services
- End-to-end testing with real inference

### Phase 3: Demo Polish (FUTURE)
- Monitoring dashboards (Grafana)
- Demo scripts and test queries
- Documentation for booth staff
- Performance optimization

## Critical Architectural Decisions

### ✅ CORRECT Approach (What We're Doing)
1. **Bake models into image:** Classification models downloaded at build time, not runtime
2. **No GPU for router:** Semantic router uses CPU-based Rust/Candle inference, doesn't need GPUs
3. **Separate pods:** Router in one pod, LLMs will be in separate pods (Phase 2)
4. **No initContainer:** Models are in the image, so no download needed at pod start
5. **Multi-stage Dockerfile:** Python stage downloads models, then copy to semantic router base image

### ❌ INCORRECT Approach (What to Avoid)
1. ❌ Don't put LLMs in the same pod as semantic router (tight coupling, can't scale independently)
2. ❌ Don't use initContainer for model downloads (slow startup, unreliable)
3. ❌ Don't request GPU nodes for semantic router (wastes resources)
4. ❌ Don't write Python server code (semantic router is a pre-built Go/Rust binary)
5. ❌ Don't share PVCs between router and LLMs (blast radius, permissions issues)

## Key Technical Details

### Semantic Router Architecture
- **What it is:** Envoy ExtProc (External Processor) service written in Go + Rust
- **Base image:** `ghcr.io/vllm-project/semantic-router/extproc:latest`
- **Classification models:** 4 ModernBERT models for category, PII, jailbreak, PII-token detection
- **Model location in image:** `/app/models/` with specific subdirectories
- **Communication:** gRPC on port 50051 (ExtProc), HTTP on port 8080 (classify API)

### Two Separate Projects Named "Semantic Router"
⚠️ **IMPORTANT:** There are TWO different projects called "semantic-router":
1. **aurelio-labs/semantic-router** - Python library for decision routing (NOT what we're using)
2. **vllm-project/semantic-router** - Go/Rust ExtProc for Envoy (WHAT WE'RE USING)

Don't confuse them! We use the vLLM project version.

### ModernBERT Classification Models
Located at `LLM-Semantic-Router/` on HuggingFace:
- `category_classifier_modernbert-base_model` - Classifies queries into 15 categories
- `pii_classifier_modernbert-base_model` - Detects personally identifiable information
- `jailbreak_classifier_modernbert-base_model` - Detects jailbreak/prompt injection attempts
- `pii_classifier_modernbert-base_presidio_token_model` - Token-level PII detection

These models run on CPU using Rust/Candle for fast inference (~15-50ms total overhead).

### Configuration Schema
The semantic router expects a SPECIFIC configuration format:
- Uses `vllm_endpoints` (not just `endpoints`)
- Has `categories` array with `model_scores` objects
- Requires `reasoning_families` section for Chain-of-Thought models
- Needs `classifier` section pointing to model paths and mapping files

**Reference config:** See `semantic-router-config.yaml` - this is the CORRECT schema

### Envoy Integration
- **Pattern:** Envoy calls semantic router via ExtProc on every request
- **Timeouts:** 5s for classification, 120s for routing to LLM
- **Headers set by router:** `x-gateway-destination-endpoint`, `x-router-category`, `x-router-confidence`, `x-selected-model`
- **Logging:** Extensive JSON access logs show all routing decisions

## OpenShift-Specific Requirements

### Security Contexts (CRITICAL)
```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
    - ALL
  seccompProfile:
    type: RuntimeDefault
```
All containers MUST have these security settings for OpenShift.

### User Permissions
- Base semantic router image runs as non-root user (UID 1001)
- OpenShift assigns random UIDs but same GID (0)
- Use `chown -R 1001:0` and `chmod -R g+rwX` for shared files

### No GPU Node Selectors
The semantic router does NOT need:
- `nodeSelector` for GPU nodes
- `tolerations` for GPU taints
- `nvidia.com/gpu` resource requests

Only the LLM containers (Phase 2) will need GPU resources.

## Project Structure

```
semantic-router/
├── Dockerfile                          # Multi-stage build with models
├── openshift/
│   ├── deployment.yaml                 # Pod with semantic-router + envoy
│   ├── service.yaml                    # Exposes ports 80, 8080, 9190, 19000
│   ├── pvc.yaml                        # 5Gi for runtime caching
│   ├── envoy-config.yaml              # ExtProc integration config
│   └── semantic-router-config.yaml    # 15 categories, safety features
├── README.md                 # Deployment guide
└── claude.md                           # This file - project context
```

## Current Status and Known Issues

### What's Working
- ✅ Dockerfile builds successfully (multi-stage with model downloads)
- ✅ All manifests follow Kubernetes best practices
- ✅ OpenShift-compatible security contexts
- ✅ Configuration matches semantic router's expected schema

### Current Issue
There's an error when trying to start the project. The error details are not yet specified.

### What to Check When Troubleshooting
1. **Image build:** Did models download completely? Check image layers
2. **Model paths:** Are models at `/app/models/category_classifier_modernbert-base_model/` etc.?
3. **Permissions:** Can UID 1001 read the model files?
4. **Config mounting:** Is the ConfigMap mounted correctly at `/app/config/`?
5. **gRPC port:** Is semantic router listening on 50051?
6. **Envoy connectivity:** Can Envoy reach semantic router on localhost:50051?

## Important URLs and Documentation

- **Semantic Router Docs:** https://vllm-semantic-router.com/docs/overview/semantic-router-overview
- **GitHub:** https://github.com/vllm-project/semantic-router
- **System Architecture:** https://vllm-semantic-router.com/docs/architecture/system-architecture/
- **HuggingFace Models:** https://huggingface.co/LLM-Semantic-Router

## Configuration Highlights

### 15 Classification Categories
The router classifies queries into these domains:
- **STEM:** math, physics, chemistry, biology, computer science, engineering
- **Social Sciences:** business, economics, law, psychology, philosophy, history
- **Health:** medical and wellness information
- **Other:** general fallback category

Each category has a detailed system prompt and model scoring (which model to use, whether to enable reasoning).

### Safety Features
- **PII Detection:** Blocks or masks personally identifiable information
- **Jailbreak Guard:** Detects prompt injection and jailbreak attempts
- **Semantic Caching:** Caches responses based on semantic similarity (0.8 threshold)
- **Content Filtering:** Configurable topic blocking

### Reasoning Families
Supports Chain-of-Thought reasoning for different model families:
- **qwen3:** `enable_thinking` parameter
- **deepseek:** `thinking` parameter
- **gpt/gpt-oss:** `reasoning_effort` parameter

Math, physics, and chemistry queries enable reasoning by default.

## Demo Requirements

### Booth Presentation Goals
1. Show intelligent routing based on query content
2. Demonstrate safety features (PII detection, jailbreak blocking)
3. Highlight 15-category classification with confidence scores
4. Display routing decisions in real-time (logs/headers)
5. Explain cost optimization (routing simple queries to smaller models)

### Phase 1 Demo (Current)
- Show classification working (category, confidence, routing target)
- Display logs showing "would route to Model-A" even without backends
- Demonstrate PII detection blocking sensitive information
- Test jailbreak guard with injection attempts

### Phase 2 Demo (Future)
- End-to-end inference with actual LLM responses
- Side-by-side comparison of specialized vs general models
- Performance metrics (latency, cost savings)

## Working with This Project

### Build Commands
```bash
podman build -t semantic-router-with-models:v1.0.0 .
# Push to Github container registry
```

### Deploy Commands
```bash
oc apply -f openshift/pvc.yaml
oc apply -f openshift/envoy-config.yaml
oc apply -f openshift/semantic-router-config.yaml
oc apply -f openshift/deployment.yaml
oc apply -f openshift/service.yaml
```

### Debugging Commands
```bash
# Check pod status
oc get pods -l app=semantic-router

# View semantic router logs
oc logs -f deploy/semantic-router -c semantic-router

# View Envoy logs (JSON format, pipe through jq)
oc logs -f deploy/semantic-router -c envoy-proxy | jq

# Check if models are in image
oc exec deploy/semantic-router -c semantic-router -- ls -la /app/models

# Verify config
oc exec deploy/semantic-router -c semantic-router -- cat /app/config/config.yaml

# Port forward for testing
oc port-forward svc/semantic-router-service 8080:80
```

### Test Queries
```bash
# Math query (should route to Model-A with reasoning)
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "test", "messages": [{"role": "user", "content": "What is 2+2?"}]}'

# Business query (should route to Model-B without reasoning)
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "test", "messages": [{"role": "user", "content": "How do I improve quarterly revenue?"}]}'

# PII test (should be blocked)
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "test", "messages": [{"role": "user", "content": "My SSN is 123-45-6789"}]}'
```

## User Preferences & Communication Style

I work best with:
- **Concise, specific responses** - I'll ask for expansion if needed
- **Breaking down complex tasks** - Helps overcome analysis paralysis
- **Learning by doing** - Simple and quick first, then iterate
- **Analogies** - Comfortable giving and receiving them for complex topics

When I get stuck, remind me:
1. Learning new things is uncomfortable but gets better
2. Start simple and build incrementally
3. Break large tasks into smaller pieces

## Important Reminders

- ⚠️ **No PyTorch needed** - Router uses Rust/Candle, not Python ML frameworks
- ⚠️ **Check official docs** - LLM hallucinations are common with CLI flags
- ⚠️ **Don't assume localhost LLMs yet** - Phase 1 has no backends running
- ⚠️ **This is a demo** - Focus on "wow factor" and clear explanation over production optimization
- ⚠️ **OpenShift security is strict** - Always test security contexts before deploying