JAR := target/java-template-1.0-SNAPSHOT.jar

.PHONY: help test run package run-jar clean format verify

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

test: ## Run all tests, with coverage report
	mvn test
	@echo "Coverage report: target/site/jacoco/index.html"

run: ## Run the app from sources (pass arguments with ARGS="Ada")
	mvn -q compile exec:java -Dexec.args="$(ARGS)"

package: ## Build the runnable jar
	mvn clean package -DskipTests

run-jar: package ## Build the jar and run it (pass arguments with ARGS="Ada")
	java -jar $(JAR) $(ARGS)

verify: ## Full gate: format check + tests + package
	mvn clean verify

format: ## Auto-format all Java sources (google-java-format)
	mvn spotless:apply

clean: ## mvn clean
	mvn clean
