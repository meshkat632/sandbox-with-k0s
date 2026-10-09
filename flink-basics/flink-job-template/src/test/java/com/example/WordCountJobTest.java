package com.example;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import org.apache.flink.api.common.RuntimeExecutionMode;
import org.apache.flink.api.java.tuple.Tuple2;
import org.apache.flink.runtime.testutils.MiniClusterResourceConfiguration;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.test.junit5.MiniClusterExtension;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.RegisterExtension;

/**
 * Integration test on a MiniCluster (real Flink cluster inside the test JVM). Verifies the wired
 * dataflow of WordCountJob.buildPipeline: flatMap -> keyBy -> sum. Keep few of these; they cost
 * seconds each.
 */
class WordCountJobTest {

    @RegisterExtension
    static final MiniClusterExtension MINI_CLUSTER =
            new MiniClusterExtension(
                    new MiniClusterResourceConfiguration.Builder()
                            .setNumberSlotsPerTaskManager(2)
                            .build());

    @Test
    void countsWordsEndToEnd() throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.setParallelism(1);
        env.setRuntimeMode(
                RuntimeExecutionMode.BATCH); // same mode as WordCountJob: final counts only

        var results = new ArrayList<Tuple2<String, Integer>>();
        try (var it =
                WordCountJob.buildPipeline(env.fromData("hello flink", "hello tdd"))
                        .executeAndCollect()) {
            it.forEachRemaining(results::add);
        }

        assertThat(results)
                .containsExactlyInAnyOrder(
                        Tuple2.of("hello", 2), Tuple2.of("flink", 1), Tuple2.of("tdd", 1));
    }
}
