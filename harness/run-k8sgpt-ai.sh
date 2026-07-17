#!/usr/bin/env bash
# k8sgpt adapter with an AI backend (OpenAI-compatible endpoint; the model
# is disclosed in results). Requires `k8sgpt auth add --backend openai` to
# have been configured beforehand.
set -euo pipefail
exec k8sgpt analyze --namespace demo --explain --backend openai
