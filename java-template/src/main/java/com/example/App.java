package com.example;

import java.io.PrintStream;

/** Entry point for this template. Prints a greeting for the first argument, or for "World". */
public final class App {

    public static void main(String[] args) {
        System.exit(run(args, System.out));
    }

    /** The app without System.out and System.exit, so tests can run it. Returns the exit code. */
    static int run(String[] args, PrintStream out) {
        String name = args.length > 0 ? args[0] : null;
        out.println(new Greeter().greet(name));
        return 0;
    }

    private App() {}
}
