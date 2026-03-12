# ---- build stage ----
FROM node:22-bookworm-slim AS build
WORKDIR /app

# CI-friendly env - but allow devDependencies for build
ENV HUSKY=0
ENV CI=true
# Don't set NODE_ENV=production here - we need devDependencies to build

# Use pnpm
RUN corepack enable && corepack prepare pnpm@9.15.9 --activate

# Ensure git is available for build and runtime scripts
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

# Accept (optional) build-time public URL for Remix/Vite (Coolify can pass it)
ARG VITE_PUBLIC_APP_URL
ENV VITE_PUBLIC_APP_URL=${VITE_PUBLIC_APP_URL}

# Install deps efficiently
COPY package.json pnpm-lock.yaml* ./
RUN pnpm fetch

# Copy source and build
COPY . .
# install ALL deps (including devDependencies needed for build)
# Ignore scripts to prevent husky issues in production builds
RUN pnpm install --offline --frozen-lockfile --ignore-scripts

# Build the Remix app (SSR + client)
RUN NODE_OPTIONS=--max-old-space-size=4096 pnpm run build

# ---- production dependencies stage ----
FROM build AS prod-deps
WORKDIR /app

# Don't add or install anything - keep build's node_modules as is
# Just prune to remove devDependencies
RUN pnpm prune --prod --ignore-scripts


# ---- production stage ----
FROM node:22-bookworm-slim AS bolt-ai-production
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=5173
ENV HOST=0.0.0.0

# Non-sensitive build arguments
ARG VITE_LOG_LEVEL=debug
ARG DEFAULT_NUM_CTX

# Set non-sensitive environment variables
ENV VITE_LOG_LEVEL=${VITE_LOG_LEVEL} \
    DEFAULT_NUM_CTX=${DEFAULT_NUM_CTX} \
    RUNNING_IN_DOCKER=true \
    NODE_TLS_REJECT_UNAUTHORIZED=1

# Note: API keys should be provided at runtime via docker run -e or docker-compose
# Example: docker run -e OPENAI_API_KEY=your_key_here ...

# Enable corepack for pnpm (needed for node runtime)
RUN corepack enable && corepack prepare pnpm@9.15.9 --activate

# Install curl for healthchecks and ca-certificates for SSL
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy built files and production dependencies from prod-deps stage
COPY --from=prod-deps /app/build /app/build
COPY --from=prod-deps /app/node_modules /app/node_modules
COPY --from=prod-deps /app/package.json /app/package.json

# Create a standalone Node.js server for Remix
RUN echo 'import { createRequestHandler } from "@remix-run/node";\n\
    import { broadcastDevReady, installGlobals } from "@remix-run/node";\n\
    import http from "http";\n\
    import { fileURLToPath } from "url";\n\
    import { dirname, join } from "path";\n\
    \n\
    const __filename = fileURLToPath(import.meta.url);\n\
    const __dirname = dirname(__filename);\n\
    \n\
    installGlobals();\n\
    \n\
    const BUILD_PATH = join(__dirname, "build", "server", "index.js");\n\
    \n\
    const build = await import(BUILD_PATH);\n\
    \n\
    const requestHandler = createRequestHandler({ build, mode: process.env.NODE_ENV });\n\
    \n\
    const server = http.createServer(async (req, res) => {\n\
    try {\n\
    const request = new Request(`http://${req.headers.host}${req.url}`, {\n\
    method: req.method,\n\
    headers: Object.fromEntries(\n\
    Object.entries(req.headers).filter(([key, value]) => value !== undefined)\n\
    ),\n\
    body: req.method !== "GET" && req.method !== "HEAD" ? req : undefined,\n\
    });\n\
    \n\
    const response = await requestHandler(request);\n\
    \n\
    res.statusCode = response.status;\n\
    for (const [key, value] of response.headers.entries()) {\n\
    res.setHeader(key, value);\n\
    }\n\
    \n\
    if (response.body) {\n\
    const reader = response.body.getReader();\n\
    while (true) {\n\
    const { done, value } = await reader.read();\n\
    if (done) break;\n\
    res.write(value);\n\
    }\n\
    }\n\
    \n\
    res.end();\n\
    } catch (error) {\n\
    console.error("Error handling request:", error);\n\
    res.statusCode = 500;\n\
    res.end("Internal Server Error");\n\
    }\n\
    });\n\
    \n\
    const port = process.env.PORT || 5173;\n\
    const host = process.env.HOST || "0.0.0.0";\n\
    \n\
    server.listen(port, host, () => {\n\
    console.log(`✅ Remix server listening on http://${host}:${port}`);\n\
    if (process.env.NODE_ENV === "development") {\n\
    broadcastDevReady(build);\n\
    }\n\
    });' > /app/server.mjs

EXPOSE 5173

# Healthcheck for deployment platforms
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
    CMD curl -fsS http://localhost:5173/ || exit 1

# Run the standalone server
CMD ["node", "server.mjs"]


# ---- development stage ----
FROM build AS development

# Non-sensitive development arguments
ARG VITE_LOG_LEVEL=debug
ARG DEFAULT_NUM_CTX

# Set non-sensitive environment variables for development
ENV VITE_LOG_LEVEL=${VITE_LOG_LEVEL} \
    DEFAULT_NUM_CTX=${DEFAULT_NUM_CTX} \
    RUNNING_IN_DOCKER=true

# Note: API keys should be provided at runtime via docker run -e or docker-compose
# Example: docker run -e OPENAI_API_KEY=your_key_here ...

RUN mkdir -p /app/run
CMD ["pnpm", "run", "dev", "--host", "0.0.0.0"]
