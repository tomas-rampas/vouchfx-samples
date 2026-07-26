# Extra TLS trust anchors (optional)

This directory is **empty by design**. Use it only if your network terminates TLS
at an inspecting proxy that presents its own CA — otherwise leave it alone and
the image builds exactly as it always has.

Without this, Maven fails every artefact download with:

```
PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException:
unable to find valid certification path to requested target
```

## What to put here

Two accepted inputs, checked in this order by [`../Dockerfile`](../Dockerfile):

1. **`truststore.p12`** — a ready-made PKCS12 truststore. **Reach for this
   first.** It is what a corporate or CI environment normally provides, and it
   carries the whole anchor set rather than a guess at which one matters. If its
   password is not `changeit`, pass `--build-arg TRUSTSTORE_PASSWORD=…`.
2. **`*.crt`** — individual PEM-encoded anchors, added to a copy of the JDK's own
   `cacerts` so all the public roots Maven Central needs are retained.

Maven is then pointed at the result explicitly via `MAVEN_OPTS`.

Everything here except this README is ignored by git (see the repository
`.gitignore`), so a machine-specific trust anchor is never committed by accident.

## Three traps

Each of these makes an import *look* successful while Maven keeps failing PKIX:

1. **One CA per PEM file.** `keytool -importcert` reads only the **first**
   certificate in a PEM file and silently ignores every one after it. Handing it
   a concatenated bundle prints `Certificate was added to keystore` while
   trusting only that first anchor. Split a bundle first:

   ```bash
   csplit -z -f proxy-ca- -b '%02d.crt' /path/to/ca-bundle.crt '/BEGIN CERTIFICATE/' '{*}'
   ```

2. **Importing into the JDK's own `cacerts` is not enough.** `keytool -cacerts`
   reports success and `keytool -list` shows the alias, yet Maven still fails.
   The store has to be passed explicitly via `-Djavax.net.ssl.trustStore`.

3. **One root may not be the whole chain.** An inspecting proxy can present a
   chain that needs intermediates beyond its own root, so importing just that
   root still fails. If a single anchor does not work, supply the full
   `truststore.p12` instead of guessing which certificate is missing.

`~/.mavenrc` is not a usable hook for any of this — Maven 3.9's launcher does not
source it.
