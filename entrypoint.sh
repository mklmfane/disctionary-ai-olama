#!/bin/sh
set -eu

MODEL="${OLLAMA_MODEL:-tinyllama}"

ollama serve &
SERVER_PID="$!"

echo "Waiting for Ollama server..."
for i in $(seq 1 60); do
  if ollama list >/dev/null 2>&1; then
    echo "Ollama server is ready."
    break
  fi
  sleep 2
done

if ollama list | awk 'NR > 1 {print $1}' | grep -qx "$MODEL"; then
  echo "Model $MODEL already exists."
else
  echo "Pulling model: $MODEL"
  ollama pull "$MODEL"
fi

wait "$SERVER_PID"