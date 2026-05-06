# Dictionary AI with Local Ollama, Docker Compose, PostgreSQL, Backend, and Frontend

This README explains how to run the `dictionary-ai` application locally using **Ollama instead of OpenAI/ChatGPT**.

The final setup runs these containers:

```text
Ollama      -> local LLM runtime, using llama3.2:1b
PostgreSQL  -> application database
Backend     -> Java / Helidon API
Frontend    -> Nuxt / Vue frontend
```

Final local endpoints:

```text
Frontend: http://localhost:3000
Backend:  http://localhost:8080
Ollama:   http://localhost:11434
Postgres: localhost:5432
```

---

## 1. Target Architecture

```text
Browser
  |
  v
Frontend container
  |
  v
Backend container
  |
  +--> PostgreSQL container
  |
  +--> Ollama container
          |
          v
       llama3.2:1b
```

The original project was designed to call OpenAI using an OpenAI API token and the `gpt-4o-mini` model.

This version changes it to call local Ollama using:

```text
Endpoint: http://ollama:11434/v1
Token:    ollama
Model:    llama3.2:1b
```

The token `ollama` is only a dummy compatibility value for the OpenAI-compatible Ollama API.

---

## 2. Hardware Used During This Setup

This setup was tested with:

```text
Laptop: NVIDIA GeForce MX250
GPU VRAM: 2 GB
System RAM assigned to Docker/Ollama: 8 GB
Model: llama3.2:1b
```

Because the GPU has only 2 GB VRAM, we selected a small model:

```text
llama3.2:1b
```

This is good enough for testing and small translations.

---

## 3. Prerequisites on a Clean Ubuntu System

Install Docker and Docker Compose plugin.

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release
```

Install Docker using Docker's official repository or your preferred installation method.

Verify Docker:

```bash
docker --version
docker compose version
```

Add your user to the Docker group:

```bash
sudo usermod -aG docker $USER
```

Then log out and log back in, or run:

```bash
newgrp docker
```

Verify Docker works:

```bash
docker run hello-world
```

---

## 4. NVIDIA GPU Prerequisites

If you want GPU acceleration, verify your NVIDIA driver first:

```bash
nvidia-smi
```

Then install and configure NVIDIA Container Toolkit.

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit
```

Configure Docker to use the NVIDIA runtime:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify Docker sees the NVIDIA runtime:

```bash
docker info | grep -i runtime
```

Test GPU access from Docker:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

If this command fails, fix the NVIDIA driver / NVIDIA Container Toolkit setup before continuing.

---

## 5. Clone the Repository

Create a working folder:

```bash
mkdir -p ~/ollama-dictionary-ai
cd ~/ollama-dictionary-ai
```

Clone the application repository:

```bash
git clone https://github.com/buttasam/dictionary-ai.git
```

Your folder should look like this:

```text
.
└── dictionary-ai
    ├── backend
    └── frontend
```

We will add the Ollama files at the root level:

```text
.
├── compose.yaml
├── Dockerfile
├── entrypoint.sh
└── dictionary-ai
    ├── backend
    └── frontend
```

---

## 6. Create the Ollama Dockerfile

Create this root-level file:

```bash
nano Dockerfile
```

Content:

```dockerfile
FROM ollama/ollama:latest

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 11434

ENTRYPOINT ["/entrypoint.sh"]
```

---

## 7. Create the Ollama Entrypoint Script

Create this root-level file:

```bash
nano entrypoint.sh
```

Content:

```sh
#!/bin/sh
set -eu

MODEL="${OLLAMA_MODEL:-llama3.2:1b}"

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
```

Make it executable:

```bash
chmod +x entrypoint.sh
```

This script starts Ollama and automatically pulls the configured model.

---

## 8. Replace Backend Dockerfile

The original backend Dockerfile expected a wrong JAR name.

Maven builds:

```text
target/dictionary-ai-backend.jar
```

So replace this file:

```text
dictionary-ai/backend/Dockerfile
```

with:

```dockerfile
FROM maven:3.9.9-eclipse-temurin-21 AS build

WORKDIR /helidon

COPY pom.xml .
RUN mvn -B dependency:go-offline

COPY src ./src
RUN mvn -B -DskipTests package

FROM eclipse-temurin:21-jre

WORKDIR /helidon

COPY --from=build /helidon/target/dictionary-ai-backend.jar ./dictionary-ai-backend.jar
COPY --from=build /helidon/target/libs ./libs

EXPOSE 8080

CMD ["java", "-jar", "dictionary-ai-backend.jar"]
```

This avoids requiring Maven on the host machine. Maven runs inside the Docker build stage.

---

## 9. Update Backend Source Code for Ollama

The original application hardcoded the OpenAI model:

```text
gpt-4o-mini
```

Ollama has:

```text
llama3.2:1b
```

So the backend must be changed to read the model from config using:

```text
openai.model
```

---

### 9.1 Replace `PromptModel.java`

File:

```text
dictionary-ai/backend/src/main/java/com/dictionaryai/model/PromptModel.java
```

Content:

```java
package com.dictionaryai.model;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

@JsonInclude(JsonInclude.Include.NON_NULL)
public record PromptModel(
        String model,

        @JsonProperty("response_format")
        ResponseFormat responseFormat,

        List<Message> messages,

        double temperature,

        @JsonProperty("max_tokens")
        Integer maxTokens,

        Integer seed
) {
    public record Message(String role, String content) {
    }

    public record ResponseFormat(String type) {
    }
}
```

This allows the backend to send:

```json
{
  "response_format": {"type": "json_object"},
  "max_tokens": 80,
  "seed": 1
}
```

---

### 9.2 Replace `OpenAIService.java`

File:

```text
dictionary-ai/backend/src/main/java/com/dictionaryai/service/OpenAIService.java
```

Content:

```java
package com.dictionaryai.service;

import com.dictionaryai.model.Language;
import com.dictionaryai.model.PromptModel;
import com.dictionaryai.model.TranslationResponse;
import com.dictionaryai.utils.Constants;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.client.Client;
import jakarta.ws.rs.client.ClientBuilder;
import jakarta.ws.rs.client.Entity;
import jakarta.ws.rs.client.WebTarget;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.util.List;
import java.util.logging.Logger;

@ApplicationScoped
public class OpenAIService {

    private static final Logger LOGGER = Logger.getLogger(OpenAIService.class.getName());

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Client client = ClientBuilder.newClient();

    private final WebTarget openAIWebTarget;
    private final String openAIToken;
    private final String openAIModel;

    @Inject
    public OpenAIService(
            @ConfigProperty(name = "openai.endpoint") String openAIApiEndpoint,
            @ConfigProperty(name = "openai.token") String openAIToken,
            @ConfigProperty(name = "openai.model", defaultValue = "llama3.2:1b") String openAIModel
    ) {
        this.openAIWebTarget = client.target(openAIApiEndpoint);
        this.openAIToken = openAIToken;
        this.openAIModel = openAIModel;
    }

    public TranslationResponse translate(String word, Language fromLang, Language toLang) {
        record OpenAITranslationResponse(List<String> translations) {
        }

        try (Response response = openAIWebTarget
                .path("/chat/completions")
                .request(MediaType.APPLICATION_JSON)
                .header(HttpHeaders.ACCEPT, MediaType.APPLICATION_JSON)
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + openAIToken)
                .post(Entity.json(getTranslationPrompt(word, fromLang, toLang)))) {

            JsonNode responseBody = response.readEntity(JsonNode.class);

            if (response.getStatus() < 200 || response.getStatus() >= 300) {
                throw new RuntimeException(
                        "AI provider returned HTTP "
                                + response.getStatus()
                                + ": "
                                + responseBody.toPrettyString()
                );
            }

            String content = responseBody
                    .at("/choices/0/message/content")
                    .asText("");

            if (content.isBlank()) {
                throw new RuntimeException(
                        "AI provider returned empty content: "
                                + responseBody.toPrettyString()
                );
            }

            LOGGER.info("AI raw content: " + content);

            OpenAITranslationResponse parsedResponse =
                    MAPPER.readValue(cleanJson(content), OpenAITranslationResponse.class);

            List<String> translations = parsedResponse.translations();

            if (translations == null) {
                translations = List.of();
            }

            translations = translations.stream()
                    .filter(t -> t != null && !t.isBlank())
                    .filter(t -> fromLang == toLang || !t.equalsIgnoreCase(word))
                    .distinct()
                    .toList();

            return new TranslationResponse(word, null, translations, fromLang, toLang);

        } catch (JsonProcessingException e) {
            throw new RuntimeException("Could not parse AI translation response", e);
        }
    }

    public PromptModel getTranslationPrompt(String text, Language from, Language to) {
        String userPrompt = """
                Translate this text.

                Source language: %s
                Target language: %s
                Text: %s

                Return only valid JSON using this exact schema:
                {"translations":["translated_text"]}
                """.formatted(from.toString(), to.toString(), text);

        var model = new PromptModel(
                openAIModel,
                new PromptModel.ResponseFormat("json_object"),
                List.of(
                        new PromptModel.Message("system", Constants.Prompts.translator(from, to)),
                        new PromptModel.Message("user", userPrompt)
                ),
                0.0,
                80,
                1
        );

        LOGGER.info(model.toString());
        return model;
    }

    private String cleanJson(String content) {
        String cleaned = content.trim();

        if (cleaned.startsWith("```json")) {
            cleaned = cleaned.substring("```json".length()).trim();
        }

        if (cleaned.startsWith("```")) {
            cleaned = cleaned.substring("```".length()).trim();
        }

        if (cleaned.endsWith("```")) {
            cleaned = cleaned.substring(0, cleaned.length() - "```".length()).trim();
        }

        return cleaned;
    }
}
```

Important changes:

```text
Model is configurable through openai.model
Ollama response errors are logged clearly
Prompt explicitly includes source and target languages
Temperature is set to 0
Response is cleaned if model returns markdown fences
Source text is filtered out if returned as translation
```

---

### 9.3 Replace `Constants.java`

File:

```text
dictionary-ai/backend/src/main/java/com/dictionaryai/utils/Constants.java
```

Content:

```java
package com.dictionaryai.utils;

import com.dictionaryai.model.Language;

public class Constants {

    public static final String MODEL_3_5_TURBO = "gpt-3.5-turbo";
    public static final String MODEL_4_O_MINI = "gpt-4o-mini";

    public static class Prompts {

        private static final String TRANSLATOR = """
                You are a strict translation API.

                Translate from %1$s to %2$s.

                Rules:
                - Return valid JSON only.
                - Do not use markdown.
                - Do not explain.
                - Do not include pronunciation.
                - Do not include transliteration.
                - Do not return the source text unless the source and target languages are the same.
                - Use this exact JSON schema:
                  {"translations":["translated_text"]}

                Examples:
                English to German, dog:
                  {"translations":["Hund"]}

                English to Czech, dog:
                  {"translations":["pes"]}

                English to Czech, I love dog:
                  {"translations":["Miluji psa"]}

                If you cannot translate the text, return:
                  {"translations":[]}
                """;

        public static String translator(Language from, Language to) {
            return String.format(TRANSLATOR, from, to);
        }
    }
}
```

---

### 9.4 Replace `WordsLimit.java`

The original frontend/backend behavior was dictionary-like and failed for `I love dog`.

File:

```text
dictionary-ai/backend/src/main/java/com/dictionaryai/model/validation/WordsLimit.java
```

Content:

```java
package com.dictionaryai.model.validation;

import jakarta.validation.Constraint;
import jakarta.validation.ConstraintValidator;
import jakarta.validation.ConstraintValidatorContext;
import jakarta.validation.Payload;

import java.lang.annotation.Documented;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Documented
@Constraint(validatedBy = WordsLimit.WordsLimitValidator.class)
@Target({
        ElementType.METHOD,
        ElementType.FIELD,
        ElementType.ANNOTATION_TYPE,
        ElementType.PARAMETER
})
@Retention(RetentionPolicy.RUNTIME)
public @interface WordsLimit {

    String message() default "Limit of words exceeded";

    Class<?>[] groups() default {};

    Class<? extends Payload>[] payload() default {};

    int limit() default 20;

    class WordsLimitValidator implements ConstraintValidator<WordsLimit, String> {

        private int limit;

        @Override
        public void initialize(WordsLimit constraintAnnotation) {
            limit = constraintAnnotation.limit();
        }

        @Override
        public boolean isValid(String value, ConstraintValidatorContext context) {
            if (value == null || value.isBlank()) {
                return false;
            }

            return value.trim().split("\\s+").length <= limit;
        }
    }
}
```

This allows short sentences like:

```text
I love dog
```

---

## 10. Update `application.yaml`

File:

```text
dictionary-ai/backend/src/main/resources/application.yaml
```

Make sure the OpenAI section points to Ollama:

```yaml
openai:
  endpoint: http://ollama:11434/v1
  token: ollama
  model: llama3.2:1b
```

Inside Docker Compose, use `http://ollama:11434/v1`, not `localhost`, because the backend container must reach the Ollama container by service name.

---

## 11. Create Root `compose.yaml`

Create this root-level file:

```bash
nano compose.yaml
```

Content:

```yaml
services:
  ollama:
    build:
      context: .
      dockerfile: Dockerfile

    image: local-ollama:llama3-2-1b
    container_name: ollama
    restart: unless-stopped

    ports:
      - "11434:11434"

    volumes:
      - ollama_data:/root/.ollama

    gpus: all

    environment:
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: compute,utility

      OLLAMA_MODEL: "llama3.2:1b"
      OLLAMA_HOST: "0.0.0.0:11434"
      OLLAMA_NUM_PARALLEL: "1"
      OLLAMA_MAX_LOADED_MODELS: "1"
      OLLAMA_KEEP_ALIVE: "5m"

    mem_limit: 8g

    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 15s
      timeout: 10s
      retries: 20
      start_period: 90s

  postgres:
    image: postgres:16-alpine
    container_name: dictionary-ai-postgres
    restart: unless-stopped

    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres

    ports:
      - "5432:5432"

    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./dictionary-ai/backend/init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro

    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 10

  backend:
    build:
      context: ./dictionary-ai/backend
      dockerfile: Dockerfile

    image: dictionary-ai-backend:local
    container_name: dictionary-ai-backend
    restart: unless-stopped

    depends_on:
      postgres:
        condition: service_healthy
      ollama:
        condition: service_healthy

    ports:
      - "8080:8080"

    environment:
      JAVA_TOOL_OPTIONS: >-
        -Dopenai.endpoint=http://ollama:11434/v1
        -Dopenai.token=ollama
        -Dopenai.model=llama3.2:1b
        -Djavax.sql.DataSource.postgres.dataSourceClassName=org.postgresql.ds.PGSimpleDataSource
        -Djavax.sql.DataSource.postgres.dataSource.url=jdbc:postgresql://postgres:5432/postgres
        -Djavax.sql.DataSource.postgres.dataSource.user=postgres
        -Djavax.sql.DataSource.postgres.dataSource.password=postgres

  frontend:
    image: node:22-alpine
    container_name: dictionary-ai-frontend
    restart: unless-stopped

    working_dir: /app

    depends_on:
      - backend

    ports:
      - "3000:3000"

    volumes:
      - ./dictionary-ai/frontend:/app

    environment:
      NUXT_HOST: "0.0.0.0"
      NUXT_PORT: "3000"
      VITE_API_URL: "http://localhost:8080"

    command: >
      sh -c "npm ci && npm run dev -- --host 0.0.0.0"

volumes:
  ollama_data:
  postgres_data:
```

---

## 12. Build and Start Everything

From the root folder:

```bash
docker compose down
```

Build and start:

```bash
docker compose up -d --build
```

Check containers:

```bash
docker ps -a
```

Expected containers:

```text
ollama
postgres
dictionary-ai-backend
dictionary-ai-frontend
```

---

## 13. Verify Ollama

Check the model:

```bash
docker exec -it ollama ollama list
```

Expected:

```text
llama3.2:1b
```

Check Ollama logs:

```bash
docker logs -f ollama
```

You should see the model pulled and loaded.

If GPU is working, logs should mention CUDA and your GPU.

Example:

```text
inference compute ... library=CUDA ... NVIDIA GeForce MX250
```

---

## 14. Verify Backend

Check backend logs:

```bash
docker logs -f dictionary-ai-backend
```

Expected startup message:

```text
Server started on http://localhost:8080
```

---

## 15. Test Ollama Directly

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ollama" \
  -d '{
    "model": "llama3.2:1b",
    "response_format": {
      "type": "json_object"
    },
    "messages": [
      {
        "role": "system",
        "content": "You are a strict bilingual dictionary API. Return only valid JSON. No explanations."
      },
      {
        "role": "user",
        "content": "Translate exactly this single English word to French. English word: dog. French translation: chien. Now return only this JSON object: {\"translations\":[\"chien\"]}"
      }
    ],
    "temperature": 0,
    "seed": 1,
    "max_tokens": 30
  }' | jq -r '.choices[0].message.content'
```

Expected:

```json
{
  "translations": ["chien"]
}
```

---

## 16. Test Backend Translation API

Clear old cached translations first:

```bash
docker exec -it dictionary-ai-postgres psql -U postgres -d postgres -c \
"TRUNCATE TABLE favorite_words, translations, words RESTART IDENTITY CASCADE;"
```

Test English to German:

```bash
curl -s http://localhost:8080/translator/translate \
  -H "Content-Type: application/json" \
  -d '{
    "word": "dog",
    "fromLang": "EN",
    "toLang": "DE"
  }' | jq
```

Expected:

```json
{
  "word": "dog",
  "wordId": 1,
  "translations": [
    "Hund"
  ],
  "fromLang": "EN",
  "toLang": "DE"
}
```

Test English to Czech:

```bash
curl -s http://localhost:8080/translator/translate \
  -H "Content-Type: application/json" \
  -d '{
    "word": "dog",
    "fromLang": "EN",
    "toLang": "CS"
  }' | jq
```

Expected:

```json
{
  "word": "dog",
  "wordId": 1,
  "translations": [
    "pes"
  ],
  "fromLang": "EN",
  "toLang": "CS"
}
```

Test sentence translation:

```bash
curl -s http://localhost:8080/translator/translate \
  -H "Content-Type: application/json" \
  -d '{
    "word": "I love dog",
    "fromLang": "EN",
    "toLang": "CS"
  }' | jq
```

Expected:

```json
{
  "word": "I love dog",
  "wordId": 1,
  "translations": [
    "Miluji psa"
  ],
  "fromLang": "EN",
  "toLang": "CS"
}
```

---

## 17. Open the Frontend

Open:

```text
http://localhost:3000
```

Test:

```text
Text: I love dog
From: English
To: Czech
```

Expected translation:

```text
Miluji psa
```

---

## 18. Troubleshooting

### Problem: `model 'gpt-4o-mini' not found`

Cause:

```text
The backend is still sending gpt-4o-mini instead of llama3.2:1b.
```

Fix:

```text
Make sure OpenAIService.java uses openAIModel instead of Constants.MODEL_4_O_MINI.
```

Also make sure Compose passes:

```text
-Dopenai.model=llama3.2:1b
```

---

### Problem: Backend returns old wrong translation

Cause:

```text
The translation was cached in PostgreSQL.
```

Fix:

```bash
docker exec -it dictionary-ai-postgres psql -U postgres -d postgres -c \
"TRUNCATE TABLE favorite_words, translations, words RESTART IDENTITY CASCADE;"
```

---

### Problem: Frontend says `Something went wrong`

Check backend first:

```bash
curl -s http://localhost:8080/translator/translate \
  -H "Content-Type: application/json" \
  -d '{
    "word": "I love dog",
    "fromLang": "EN",
    "toLang": "CS"
  }' | jq
```

If backend works, restart frontend:

```bash
docker restart dictionary-ai-frontend
```

Then hard refresh browser:

```text
CTRL + F5
```

---

### Problem: Maven build error about `unnamed classes`

Cause:

```text
OpenAIService.java was pasted incorrectly and does not start with the package declaration.
```

First line must be:

```java
package com.dictionaryai.service;
```

Check:

```bash
head -n 5 dictionary-ai/backend/src/main/java/com/dictionaryai/service/OpenAIService.java
```

---

### Problem: `mvn: command not found` during Docker build

Cause:

```text
The backend Dockerfile used a runtime JDK image without Maven.
```

Fix:

Use this build stage:

```dockerfile
FROM maven:3.9.9-eclipse-temurin-21 AS build
```

---

### Problem: `COPY failed: dictionary-ai.jar does not exist`

Cause:

```text
Maven builds dictionary-ai-backend.jar, not dictionary-ai.jar.
```

Fix backend Dockerfile:

```dockerfile
COPY --from=build /helidon/target/dictionary-ai-backend.jar ./dictionary-ai-backend.jar
```

---

### Problem: GPU error `could not select device driver "nvidia"`

Cause:

```text
Docker is not configured with NVIDIA runtime.
```

Fix:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Test:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

If you do not want GPU, remove these lines from the Ollama service:

```yaml
gpus: all
NVIDIA_VISIBLE_DEVICES: all
NVIDIA_DRIVER_CAPABILITIES: compute,utility
```

---

## 19. Useful Commands

Stop everything:

```bash
docker compose down
```

Start everything:

```bash
docker compose up -d
```

Rebuild everything:

```bash
docker compose up -d --build
```

Rebuild only backend:

```bash
docker compose build --no-cache backend
```

View backend logs:

```bash
docker logs -f dictionary-ai-backend
```

View Ollama logs:

```bash
docker logs -f ollama
```

View frontend logs:

```bash
docker logs -f dictionary-ai-frontend
```

Check containers:

```bash
docker ps -a
```

Check Ollama models:

```bash
docker exec -it ollama ollama list
```

Clear application translation cache:

```bash
docker exec -it dictionary-ai-postgres psql -U postgres -d postgres -c \
"TRUNCATE TABLE favorite_words, translations, words RESTART IDENTITY CASCADE;"
```

Remove stopped containers:

```bash
docker container prune
```

---

## 20. Final Result

The application now runs fully locally:

```text
No OpenAI API key required
No ChatGPT API call required
Ollama runs locally in Docker
Backend talks to Ollama using OpenAI-compatible API
PostgreSQL stores translations
Frontend works on localhost:3000
```

Tested successful backend outputs:

```json
{
  "word": "dog",
  "translations": ["Hund"],
  "fromLang": "EN",
  "toLang": "DE"
}
```

```json
{
  "word": "dog",
  "translations": ["pes"],
  "fromLang": "EN",
  "toLang": "CS"
}
```

```json
{
  "word": "I love dog",
  "translations": ["Miluji psa"],
  "fromLang": "EN",
  "toLang": "CS"
}
```