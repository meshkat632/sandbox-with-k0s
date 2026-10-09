package com.example;

/** Builds the greeting. Pure function: unit-testable without running the app. */
public final class Greeter {

    static final String DEFAULT_NAME = "World";

    public String greet(String name) {
        String who = name == null || name.isBlank() ? DEFAULT_NAME : name.strip();
        return "Hello, " + who + "!";
    }
}
