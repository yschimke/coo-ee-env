package sample;

import com.google.common.base.Joiner;

/** Trivial class that uses the external dependency, so it's genuinely needed. */
public final class Sample {
    public static String greeting() {
        return Joiner.on(' ').join("hello", "from", "coo.ee/env");
    }

    private Sample() {}
}
