# Stage 1: Download models using a Python image
FROM python:3.11-slim AS model-downloader

# Install Hugging Face CLI
RUN pip install --no-cache-dir "huggingface_hub[cli]"

# Create models directory
RUN mkdir -p /app/models

# Download all 4 classification models
ENV HF_HUB_CACHE=/tmp/hf_cache

RUN set -e && \
    echo "Downloading category classifier..." && \
    huggingface-cli download LLM-Semantic-Router/category_classifier_modernbert-base_model \
      --local-dir /app/models/category_classifier_modernbert-base_model \
      --cache-dir $HF_HUB_CACHE && \
    echo "Downloading PII classifier..." && \
    huggingface-cli download LLM-Semantic-Router/pii_classifier_modernbert-base_model \
      --local-dir /app/models/pii_classifier_modernbert-base_model \
      --cache-dir $HF_HUB_CACHE && \
    echo "Downloading jailbreak classifier..." && \
    huggingface-cli download LLM-Semantic-Router/jailbreak_classifier_modernbert-base_model \
      --local-dir /app/models/jailbreak_classifier_modernbert-base_model \
      --cache-dir $HF_HUB_CACHE && \
    echo "Downloading PII token classifier..." && \
    huggingface-cli download LLM-Semantic-Router/pii_classifier_modernbert-base_presidio_token_model \
      --local-dir /app/models/pii_classifier_modernbert-base_presidio_token_model \
      --cache-dir $HF_HUB_CACHE && \
    echo "Models downloaded successfully"

# Stage 2: Final image with semantic router binary + models
FROM ghcr.io/vllm-project/semantic-router/extproc:latest

# Switch to root to copy models and set permissions
USER root

# Copy downloaded models from the first stage
COPY --from=model-downloader /app/models /app/models

# Set proper permissions for OpenShift (group 0, user 1001)
RUN chown -R 1001:0 /app/models && \
    chmod -R g+rwX /app/models

# Switch back to non-root user
USER 1001

# The CMD from the base image will be used (the semantic router binary)