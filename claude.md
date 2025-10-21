# vLLM Semantic Router - OpenShift Deployment Project

## Project Overview

This project deploys the vLLM Semantic Router as an intelligent request classifier and router for Large Language Models (LLMs). The semantic router analyzes incoming requests, classifies them by category (computer science, philosophy, health, etc.), detects security issues (PII, jailbreaks), and routes them to appropriate backend models.

**Purpose:** Production deployment with intelligent routing to specialized models
**Environment:** Red Hat OpenShift AI cluster
**Current Phase:** Fully operational with 3 vLLM backends

## System Status

### ✅ FULLY OPERATIONAL
- ✅ Semantic router deployed with official image
- ✅ Init container downloads ModernBERT classification models to PVC
- ✅ Envoy proxy integrated for routing and observability
- ✅ 3 vLLM backends deployed and accessible
- ✅ Classification working across 5 categories
- ✅ Reasoning mode enabled for philosophy queries
- ✅ End-to-end inference working

## Architecture Overview

### Components
1. **Semantic Router Pod** (2 containers)
   - semantic-router: `ghcr.io/vllm-project/semantic-router/extproc:latest`
   - envoy-proxy: `envoyproxy/envoy:v1.35.3`
2. **Init Container**: Downloads 4 ModernBERT models from HuggingFace
3. **PVCs**: 10Gi for models, 5Gi for cache
4. **vLLM Backends**: 3 separate model services

### Request Flow
```
Client → Envoy (8801) → ExtProc (semantic-router:50051) → Envoy routing → vLLM backend
```

## Critical Architectural Decisions

### ✅ CORRECT Approach (What We're Doing)
1. **Use official image:** No custom Dockerfile, use `ghcr.io/vllm-project/semantic-router/extproc:latest`
2. **Init container for models:** Downloads models to PVC on first start, idempotent checks for subsequent starts
3. **No GPU for router:** Semantic router uses CPU-based Rust/Candle inference
4. **Separate pods:** Router in one pod, each LLM in its own pod
5. **PVC persistence:** Models downloaded once, reused across restarts
6. **Dynamic routing:** Envoy uses ORIGINAL_DST cluster with header-based destination

### ❌ INCORRECT Approach (What to Avoid)
1. ❌ Don't build custom Docker images (use official image)
2. ❌ Don't put LLMs in the same pod as semantic router
3. ❌ Don't request GPU nodes for semantic router
4. ❌ Don't write Python server code (semantic router is a pre-built Go/Rust binary)
5. ❌ Don't share PVCs between router and LLMs

## Key Technical Details

### Semantic Router Architecture
- **What it is:** Envoy ExtProc (External Processor) service written in Go + Rust
- **Base image:** `ghcr.io/vllm-project/semantic-router/extproc:latest`
- **Classification models:** 4 ModernBERT models for category, PII, jailbreak, PII-token detection
- **Model location:** `/app/models/` on PVC (downloaded by init container)
- **Communication:** gRPC on port 50051 (ExtProc), HTTP on port 8080 (classify API)
- **Metrics:** Prometheus metrics on port 9190

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
- **Timeouts:** 300s for both classification and routing to LLM
- **Headers set by router:** `x-gateway-destination-endpoint`, `x-selected-model`
- **Logging:** Extensive JSON access logs show all routing decisions
- **Routing mechanism:** ORIGINAL_DST cluster with `use_http_header: true`
- **Entry point:** Envoy listens on port 8801

### vLLM Backends (Deployed)

The system currently has 3 vLLM backends deployed:

1. **mistral-small-24b-instruct-2501-fp8-dynamic-150**
   - Address: 172.30.95.11:80
   - Purpose: General purpose, default fallback
   - Used for: "other" category queries

2. **qwen-14b-quant**
   - Address: 172.30.68.65:80
   - Purpose: Reasoning-capable model
   - Used for: computer science, engineering, philosophy
   - Supports: Chain-of-thought reasoning (`<thinking>` mode)

3. **medtron3-phi4-14b** (medical fine-tune)
   - Address: 172.30.118.1:80
   - Purpose: Medical domain specialist
   - Used for: health category queries
   - Configured for: Evidence-based, detailed medical responses

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
semantic-on-openshift/
├── openshift/
│   ├── deployment.yaml                 # Pod with init container, semantic-router + envoy
│   ├── service.yaml                    # Exposes ports 80, 8080, 9190, 19000
│   ├── pvc.yaml                        # 10Gi for models, 5Gi for cache
│   ├── envoy-configmap.yaml           # ExtProc integration config
│   └── semantic-router-config.yaml    # 5 categories, safety features, 3 backends
├── README.md                           # Deployment guide
└── claude.md                           # This file - project context
```

## Current Status

### ✅ Everything Working
- ✅ All manifests deployed successfully
- ✅ Init container downloads models successfully
- ✅ Models persisted to PVC (10Gi)
- ✅ OpenShift-compatible security contexts
- ✅ Configuration matches semantic router's expected schema
- ✅ Classification working across all 5 categories
- ✅ Routing to correct vLLM backends
- ✅ Reasoning mode enabled for philosophy queries
- ✅ End-to-end inference working
- ✅ Semantic caching operational

### Key Learnings
1. **Init container approach works well:** Models download once, persist to PVC, fast subsequent starts
2. **ORIGINAL_DST cluster:** Envoy's ORIGINAL_DST cluster type with `use_http_header: true` enables dynamic routing
3. **Header-based routing:** Semantic router sets `x-gateway-destination-endpoint` to specify target backend
4. **Port forwarding:** Use `oc port-forward deployment/semantic-router 8080:8801` to access via Envoy
5. **Model download time:** First deployment takes 2-5 minutes for model downloads

## Important URLs and Documentation

- **Semantic Router Docs:** https://vllm-semantic-router.com/docs/overview/semantic-router-overview
- **GitHub:** https://github.com/vllm-project/semantic-router
- **System Architecture:** https://vllm-semantic-router.com/docs/architecture/system-architecture/
- **HuggingFace Models:** https://huggingface.co/LLM-Semantic-Router

## Configuration Highlights

### 5 Active Classification Categories
The router classifies queries into these domains:
- **computer science:** Routes to qwen-14b-quant without reasoning
- **engineering:** Routes to qwen-14b-quant without reasoning
- **philosophy:** Routes to qwen-14b-quant WITH reasoning enabled
- **health:** Routes to medtron3-phi4-14b (medical specialist)
- **other:** Routes to mistral-small (general purpose fallback)

Each category has a detailed system prompt and model scoring (which model to use, whether to enable reasoning).

### Safety Features
- **PII Detection:** Identifies personally identifiable information
- **Jailbreak Guard:** Detects prompt injection and jailbreak attempts (threshold: 0.7)
- **Semantic Caching:** Caches responses based on semantic similarity (0.95 threshold)
- **PII Policy:** Configured per-model, allows EMAIL_ADDRESS by default

### Reasoning Families
Supports Chain-of-Thought reasoning for different model families:
- **qwen3:** `enable_thinking` parameter
- **deepseek:** `thinking` parameter
- **gpt/gpt-oss:** `reasoning_effort` parameter

Philosophy queries enable reasoning by default. Default reasoning effort: high.

## Use Cases and Benefits

### Intelligent Routing
1. Routes queries to specialized models based on content
2. Philosophy queries get reasoning-capable model with `<thinking>` mode
3. Medical queries route to domain-specific fine-tuned model
4. Simple queries use general-purpose model (cost optimization)

### Safety and Compliance
- PII detection prevents leaking sensitive information
- Jailbreak guard blocks prompt injection attempts
- Per-model PII policies for granular control

### Performance Optimization
- Semantic caching reduces redundant inference (0.95 similarity threshold)
- CPU-based classification adds minimal latency (15-50ms)
- Smart routing optimizes cost vs. quality tradeoff

## Working with This Project

### Deploy Commands
```bash
# Deploy in order
oc apply -f openshift/pvc.yaml
oc apply -f openshift/envoy-configmap.yaml
oc apply -f openshift/semantic-router-config.yaml
oc apply -f openshift/deployment.yaml
oc apply -f openshift/service.yaml

# Watch init container download models (first deployment only)
oc logs -f deployment/semantic-router -c model-downloader
```

### Debugging Commands
```bash
# Check pod status (should show 2/2 Ready)
oc get pods -l app=semantic-router

# View semantic router logs
oc logs -f deployment/semantic-router -c semantic-router

# View Envoy logs (JSON format, shows routing decisions)
oc logs -f deployment/semantic-router -c envoy-proxy

# Check if models are downloaded to PVC
oc exec deployment/semantic-router -c semantic-router -- ls -la /app/models

# Verify config
oc exec deployment/semantic-router -c semantic-router -- cat /app/config/config.yaml

# Port forward for testing (to Envoy proxy)
oc port-forward deployment/semantic-router 8080:8801

# Access Envoy admin interface
oc port-forward deployment/semantic-router 19000:19000
```

### Test Queries

#### Philosophy Query (Reasoning Enabled)
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

Expected: Routes to qwen-14b-quant with reasoning, response includes `<thinking>` tags

#### Simple Math Query
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

Expected: Routes to mistral-small (other category), quick response

#### Medical Query
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

Expected: Routes to medtron3-phi4-14b (health category), detailed evidence-based response

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
- ⚠️ **No custom Dockerfile** - Use official image `ghcr.io/vllm-project/semantic-router/extproc:latest`
- ⚠️ **Init container handles models** - Models download to PVC on first start, idempotent checks on restarts
- ⚠️ **Port forward to 8801** - Envoy listens on 8801, use `oc port-forward deployment/semantic-router 8080:8801`
- ⚠️ **Check official docs** - Refer to https://vllm-semantic-router.com for latest configuration options
- ⚠️ **OpenShift security is strict** - All containers have security contexts with dropped capabilities
- ⚠️ **Model download time** - First deployment takes 2-5 minutes, subsequent starts are fast
- ⚠️ **ORIGINAL_DST cluster** - Envoy uses ORIGINAL_DST with header-based routing, not static clusters
- ⚠️ **3 vLLM backends deployed** - Mistral (general), Qwen (reasoning), Medtron (medical)