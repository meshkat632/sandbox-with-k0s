# java-template

Starter template for a plain Java application (Java 17, Maven).
TDD-ready: pure unit tests + an end-to-end test of the app out of the box.

## Layout

```
src/main/java/com/example/     App (entry point) + Greeter (pure logic)
src/test/java/com/example/     GreeterTest (logic) + AppTest (arguments in, output out)
pom.xml                        JUnit 5, AssertJ, Jacoco, Spotless, shade (runnable jar)
Makefile                       test / run / package / run-jar / verify / format
```

## Everyday commands

```bash
make test               # all tests, coverage at target/site/jacoco/index.html
make run                # run from sources: prints "Hello, World!"
make run ARGS="Ada"     # prints "Hello, Ada!"
make run-jar            # build the jar and run it with `java -jar`
make verify             # full gate: tests + package + format check
```

Plain Maven equivalents: `mvn test`, `mvn clean package` (runnable jar in `target/`),
`mvn verify` (adds the format check).

## TDD workflow

1. Write logic as a pure class (like `Greeter`) - test it directly (`GreeterTest` pattern).
2. Keep `main` thin: it only hands `args` and `System.out` to `App.run`. Cover the wiring
   with a test that calls `App.run` (`AppTest` pattern).
3. `make test` -> green -> refactor.

## Adopting the template

```bash
../scripts/new-java-project.sh io.acme billing              # new project in ../billing
../scripts/new-java-project.sh io.acme billing ~/code/bill  # ...or in a directory of your choice
```

The script copies the template, sets `groupId`/`artifactId`/`mainClass` in `pom.xml` and `JAR`
in the `Makefile`, and moves the `com.example` packages to the groupId. Then replace `Greeter`
with your own logic.

## Notes

- The jar is built with the shade plugin, so dependencies you add are bundled and
  `java -jar` keeps working.
- `mvn verify` enforces google-java-format (AOSP style, 4-space indent) via Spotless;
  run `make format` to fix.
