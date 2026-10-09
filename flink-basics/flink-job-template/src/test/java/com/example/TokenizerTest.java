package com.example;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import org.apache.flink.api.java.tuple.Tuple2;
import org.apache.flink.util.Collector;
import org.junit.jupiter.api.Test;

/** Pure unit test - no cluster, no Flink runtime. Fast; test all UDF logic this way. */
class TokenizerTest {

    private static List<Tuple2<String, Integer>> tokenize(String line) {
        List<Tuple2<String, Integer>> out = new ArrayList<>();
        Collector<Tuple2<String, Integer>> collector =
                new Collector<>() {
                    @Override
                    public void collect(Tuple2<String, Integer> record) {
                        out.add(record);
                    }

                    @Override
                    public void close() {}
                };
        new Tokenizer().flatMap(line, collector);
        return out;
    }

    @Test
    void splitsLowercasesAndCounts() {
        assertThat(tokenize("Hello, Flink World!"))
                .containsExactlyInAnyOrder(
                        Tuple2.of("hello", 1), Tuple2.of("flink", 1), Tuple2.of("world", 1));
    }

    @Test
    void skipsBlankInput() {
        assertThat(tokenize("   ")).isEmpty();
    }
}
