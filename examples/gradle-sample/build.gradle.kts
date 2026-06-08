// Trivial sample project used to verify coo.ee/env's Gradle dependency
// prefetch (see .github/workflows/prefetch.yml). It declares one real external
// dependency from Maven Central so CI can assert the artifact JAR lands in the
// Gradle cache after `setup` runs.
plugins {
    `java-library`
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("com.google.guava:guava:33.0.0-jre")
}
