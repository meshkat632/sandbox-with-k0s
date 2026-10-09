# flink-job-template

Production-grade starter template for Apache Flink DataStream jobs (Java 17, Flink 2.3.0).
TDD-ready: pure UDF unit tests + MiniCluster integration test out of the box.

## Layout

```
src/main/java/com/example/     WordCountJob (reference job) + Tokenizer (pure UDF)
src/main/resources/log4j2.xml  quiet Flink logs locally, INFO for your code
src/test/java/com/example/     TokenizerTest (no cluster) + WordCountJobTest (MiniCluster)
pom.xml                        provided-scope Flink deps, JUnit 5, Jacoco, Spotless, shade
Makefile                       test / run / package / deploy / logs
```

## Everyday commands

```bash
make test       # unit + integration tests, coverage at target/site/jacoco/index.html
make run        # embedded run: mini-cluster inside your JVM, counts in console
make deploy     # fat jar -> Docker session cluster (needs `make cluster-up` from
                # your flink-session-cluster project)
```

Plain Maven equivalents: `mvn test`, `mvn clean package` (fat jar in `target/`),
`mvn verify` (adds format check + coverage gate).

## TDD workflow

1. Write logic as a pure function (like `Tokenizer`) - test it without a cluster
   (`TokenizerTest` pattern: call the UDF with a hand-written `Collector`).
2. Wire the dataflow in the job class; cover wiring with a MiniCluster test
   (`WordCountJobTest` pattern). Keep these few - each boots a cluster.
3. `make test` -> green -> refactor.

## Adopting the template

```bash
mkflink io.acme click-counter              # new job in ./click-counter
mkflink io.acme click-counter ~/code/cc    # ...or in a directory of your choice
```

`mkflink` is `scripts/new-flink-job.sh`, installed once with
`ln -s "$(realpath ../../scripts/new-flink-job.sh)" ~/.local/bin/mkflink`.

The script copies the template, sets `groupId`/`artifactId`/`mainClass` in `pom.xml` and the
`Makefile`, and moves the `com.example` packages to the groupId. Then replace `WordCountJob`
with your job; keep `Tokenizer` only if useful.

## Notes

- Flink deps are `provided`: the cluster supplies them at runtime, the IDE gets them
  via "Add dependencies with 'provided' scope to classpath" (Run Configuration ->
  Modify options) or via the test classpath.
- `mvn verify` enforces google-java-format via Spotless; run `make format` to fix.
- Flink version bumps: change `<flink.version>` in `pom.xml`, one place.
