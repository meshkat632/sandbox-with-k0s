JM := flink-jobmanager
TM := flink-taskmanager
JAR := target/flink-job-template-1.0-SNAPSHOT.jar

.PHONY: help test run package deploy logs clean format verify

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

test: ## Run all tests (unit + MiniCluster), with coverage report
	mvn test
	@echo "Coverage report: target/site/jacoco/index.html"

run: ## Run the job embedded (local mini-cluster in your JVM)
	mvn compile exec:java -Dexec.mainClass=com.example.WordCountJob

package: ## Build the fat jar for deployment
	mvn clean package -DskipTests

verify: ## Full gate: format check + tests + package
	mvn clean verify

deploy: package ## Deploy fat jar to the Docker session cluster
	docker cp $(JAR) $(JM):/opt/flink/usrlib/app.jar
	docker exec $(JM) flink run -Dexecution.runtime-mode=BATCH /opt/flink/usrlib/app.jar

logs: ## Tail TaskManager logs (print() output lands here)
	docker logs -f $(TM)

format: ## Auto-format all Java sources (google-java-format)
	mvn spotless:apply

clean: ## mvn clean
	mvn clean
