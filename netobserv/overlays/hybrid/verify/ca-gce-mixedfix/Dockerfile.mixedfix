# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.25 AS build
WORKDIR /src
COPY cluster-autoscaler/ cluster-autoscaler/
WORKDIR /src/cluster-autoscaler
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download && \
    CGO_ENABLED=0 GOOS=linux GOARCH=$TARGETARCH go build -ldflags=-s -o /cluster-autoscaler .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /cluster-autoscaler /cluster-autoscaler
WORKDIR /
CMD ["/cluster-autoscaler"]
