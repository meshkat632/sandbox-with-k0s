package com.example;

import org.apache.flink.api.common.functions.FlatMapFunction;
import org.apache.flink.api.java.tuple.Tuple2;
import org.apache.flink.util.Collector;

/** Splits lines into lowercase (word, 1) tuples. Pure function: unit-testable without a cluster. */
public final class Tokenizer implements FlatMapFunction<String, Tuple2<String, Integer>> {

    @Override
    public void flatMap(String line, Collector<Tuple2<String, Integer>> out) {
        for (String word : line.toLowerCase().split("\\W+")) {
            if (!word.isEmpty()) {
                out.collect(Tuple2.of(word, 1));
            }
        }
    }
}
