# Template untuk service Go (binary statis di atas alpine).
# Dipakai bila projects/<nama>.yml berisi `build.template: go-service`.
#
# Build args:
#   GO_IMAGE  image Go untuk build            (default golang:1.24-alpine)
#   MAIN      package main yang di-build      (default ./cmd/api)
#   PORT      port yang di-expose             (default 8080)
#   EXTRA     folder tambahan yang ikut disalin ke /app (mis. "db"), opsional

ARG GO_IMAGE=golang:1.24-alpine

FROM ${GO_IMAGE} AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
ARG MAIN=./cmd/api
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/app ${MAIN}
ARG EXTRA=""
RUN mkdir -p /out/extra && for d in ${EXTRA}; do cp -R "$d" /out/extra/; done

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && adduser -D -u 10001 app
WORKDIR /app
COPY --from=build /out/app /app/app
COPY --from=build /out/extra/ /app/
USER app
ARG PORT=8080
ENV PORT=${PORT}
EXPOSE ${PORT}
ENTRYPOINT ["/app/app"]
