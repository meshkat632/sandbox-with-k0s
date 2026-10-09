package com.example;

import org.apache.flink.api.common.RuntimeExecutionMode;
import org.apache.flink.api.common.typeinfo.Types;
import org.apache.flink.api.java.tuple.Tuple2;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;

/**
 * Reference job for this template. Runs embedded from the IDE and on a session cluster via `flink
 * run` - getExecutionEnvironment() auto-detects both.
 */
public final class WordCountJob {

    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.setRuntimeMode(RuntimeExecutionMode.BATCH); // bounded sample data -> batch

        DataStream<String> text =
                env.fromData("hello flink", "hello templates", "tdd ready", "ship it");

        buildPipeline(text).print();

        env.execute("WordCountJob");
    }

    /** The dataflow without source and sink, so tests can run it on their own input. */
    static DataStream<Tuple2<String, Integer>> buildPipeline(DataStream<String> text) {
        return text.flatMap(new Tokenizer())
                .returns(Types.TUPLE(Types.STRING, Types.INT))
                .keyBy(t -> t.f0)
                .sum(1);
    }

    private WordCountJob() {}
}
