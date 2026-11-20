# Template untuk Single Page App (Vue / React / Svelte / Vite / CRA ...).
# Dipakai Jenkinsfile bila projects/<nama>.yml berisi `build.template: vue-spa`.
# Jenkins menyalin folder ini ke <repo>/.ci-template/ lalu build dengan context = root repo.
#
# Build args:
#   NODE_IMAGE    image Node untuk build           (default node:22-alpine)
#   NGINX_IMAGE   image nginx runtime              (default nginx:1.28-alpine)
#   BUILD_SCRIPT  script npm untuk build           (default build)
#   DIST_DIR      folder hasil build               (default dist)
#
# Env runtime (bisa di-override di docker-compose):
#   API_UPSTREAM   host:port backend untuk proxy   (default api:8080)
#   PROXY_PATHS    regex path yang di-proxy        (default ^/(api|files)/)
#   NGINX_MAX_BODY batas upload                    (default 20m)

ARG NODE_IMAGE=node:22-alpine
ARG NGINX_IMAGE=nginx:1.28-alpine

FROM ${NODE_IMAGE} AS build
WORKDIR /src
COPY package.json package-lock.json* yarn.lock* pnpm-lock.yaml* ./
RUN if [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then npm ci --no-audit --no-fund; \
    else npm install --no-audit --no-fund; fi
COPY . .
ARG BUILD_SCRIPT=build
RUN npm run "${BUILD_SCRIPT}"

FROM ${NGINX_IMAGE}
ARG DIST_DIR=dist
ENV API_UPSTREAM=api:8080 \
    PROXY_PATHS="^/(api|files)/" \
    NGINX_MAX_BODY=20m \
    NGINX_RESOLVER=127.0.0.11
COPY .ci-template/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /src/${DIST_DIR}/ /usr/share/nginx/html/
EXPOSE 80
