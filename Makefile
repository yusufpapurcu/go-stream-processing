.PHONY: test
default: test

#=========== Setup ====================
setup:
	go install github.com/daixiang0/gci@v0.6.3
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.51.0
	go install github.com/matryer/moq@v0.2.7
	go install github.com/actgardner/gogen-avro/v10/cmd/...@latest

	brew install -q ctlptl helm kind kubernetes-cli tilt yq

#=========== Linting ====================
lint:
	golangci-lint run --timeout=5m

lf: lintfix
lintfix:
	@golangci-lint run ./... --fix

#============== Support Commands =================
generate:
	@go generate ./...

fix-imports:
	@gci write --skip-generated -s standard -s default -s "prefix(github.com/yusufpapurcu/go-stream-processing)" $$(find . -type f -name '*.go' -not -path "./vendor/*")

#============== Test Commands =================
t: test
test: vendor lint unit-tests docker-down docker-tests

unit-tests:
	go fmt ./...
	go test -shuffle=on --tags=unit ./...

## test-race: run tests with race detection
vendor:
	go mod vendor -v

race-condition-tests:
	go test -v -race ./...

integration-tests: wait-for-kafka setup-registry
	go test -count=1 -timeout 600s --tags=integration ./...

acceptance-tests: wait-for-kafka setup-registry
	go test -count=1 -timeout 600s --tags=acceptance ./...

wait-for-kafka:
	@go run local/wait-for-kafka/main.go

setup-registry:
	@go run local/setup-registry/main.go

#============== Docker Commands =================
docker-down:
	docker-compose down

docker-tests:
	docker-compose build
	docker-compose run --rm integration-tests
	docker-compose run --rm acceptance-tests
	docker-compose down

docker-dev:
	docker-compose build go-stream-processing
	docker-compose kill go-stream-processing
	docker-compose run --rm go-stream-processing

#============== Tilt Commands =================
dev:
	ctlptl apply -f ./local/k8s/kind-cluster.yaml
	tilt up

stop:
	@tilt down

cluster:
	@ctlptl apply -f ./local/k8s/kind-cluster.yaml

tilt-deps: cluster
	-@kubectl delete job wait-for-kafka > /dev/null 2>&1 # we want ensure kafka is healthy by rerunning the wait-for-kafka job
	@make remove-pih									 # we only want to run the dependencies therefore remove ISB deployment

	@echo " 🎬 Starting dependencies..."
	@echo " 👀 Watch progress here: http://localhost:10350/"
	@tilt ci dependencies > /dev/null

	@echo " ✨  Successfully started dependencies"

tilt-up: cluster
	@echo " 🚀 Deploying Handler..."
	@echo " 👀 Watch progress here: http://localhost:10350/"
	@tilt ci pih-service > /dev/null
	@echo " 🍻 All services running"

tilt-down:
	@echo " 🛑️ Stopping services..."
	@tilt down > /dev/null

remove-app:
	@if kubectl get deployment go-stream-processing > /dev/null 2>&1; then \
  		echo " 💀 Removing Handler..." ;\
        kubectl delete deployment go-stream-processing > /dev/null ;\
     	while kubectl rollout status deployment go-stream-processing --timeout=30s > /dev/null 2>&1; do sleep 1; done ;\
    fi

expose-app:
	@kubectl port-forward service/go-stream-processing 8080

expose-kafka:
	@kubectl port-forward service/kafka-headless  9092 9093

tilt-purge-topic:
	@echo " 🔖 Moving offsets to end of topic..."

	 -@kubectl exec -it deploy/kafka-client -- kafka-consumer-groups.sh --group go-stream-processing-payout-instruction-groupId --reset-offsets --to-latest --topic go-stream-processing-payout-instruction --bootstrap-server  kafka-headless.default.svc.cluster.local:9092 --execute