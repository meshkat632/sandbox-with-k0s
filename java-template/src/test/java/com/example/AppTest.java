package com.example;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;

/** Runs the app end to end through App.run: arguments in, output and exit code out. */
class AppTest {

    private static String run(String... args) {
        var buffer = new ByteArrayOutputStream();
        int exitCode = App.run(args, new PrintStream(buffer, true, StandardCharsets.UTF_8));
        assertThat(exitCode).isZero();
        return buffer.toString(StandardCharsets.UTF_8);
    }

    @Test
    void greetsTheWorldWithoutArguments() {
        assertThat(run()).isEqualTo("Hello, World!" + System.lineSeparator());
    }

    @Test
    void greetsTheFirstArgument() {
        assertThat(run("Ada")).isEqualTo("Hello, Ada!" + System.lineSeparator());
    }
}
