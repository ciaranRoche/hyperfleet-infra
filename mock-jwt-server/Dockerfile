FROM golang:1.24 AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 go build -o /mock-jwt-server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /mock-jwt-server /mock-jwt-server
EXPOSE 8080
ENTRYPOINT ["/mock-jwt-server"]
