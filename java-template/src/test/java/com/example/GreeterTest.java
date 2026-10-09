package com.example;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/** Pure unit test. Fast; test all logic this way. */
class GreeterTest {

    private final Greeter greeter = new Greeter();

    @Test
    void greetsByName() {
        assertThat(greeter.greet("Ada")).isEqualTo("Hello, Ada!");
    }

    @Test
    void stripsSurroundingWhitespace() {
        assertThat(greeter.greet("  Ada ")).isEqualTo("Hello, Ada!");
    }

    @Test
    void fallsBackToWorldWhenNameIsMissing() {
        assertThat(greeter.greet(null)).isEqualTo("Hello, World!");
        assertThat(greeter.greet("   ")).isEqualTo("Hello, World!");
    }
}
